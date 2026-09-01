import Foundation

/// The file half of `IslandLog`: an append-only `isleta.log` that rotates by size.
///
/// One serial utility queue owns the file handle, the running size and every rotation, so a line
/// from the main actor and one from the adapter's reader queue cannot interleave mid-row. Nothing
/// is buffered in this process: each line is one `write(2)` against a handle held open for the
/// life of the sink, which is what makes a crash lose at most the line being written rather than a
/// buffer's worth — and what makes `drain()` sufficient on the quit path, because once the queue is
/// empty the bytes are the kernel's.
///
/// # Rotation
///
/// `isleta.log` is the live file. When a write carries it past `maximumFileSize` the set shifts —
/// `isleta.2.log` → `isleta.3.log`, `isleta.1.log` → `isleta.2.log`, `isleta.log` → `isleta.1.log`
/// — and the oldest beyond `retainedFileCount` is deleted. Rotation happens *after* the write that
/// crossed the line, so a session boundary is never split across two files by a single row, and a
/// session is never lost to a rotation that happened a moment before it began. At the defaults
/// (2 MB × 4) the directory holds at most ~8 MB, which for an app that logs a few lines per user
/// action is weeks of history.
///
/// # Failure
///
/// A sink that cannot open or write its file **stops trying**, records why, and says so in
/// `status`, which the diagnostics report prints. It does not retry per line: the unified log is
/// still receiving every line, and a directory that refused once (permissions, a full disk, a
/// read-only home) is going to refuse the next ten thousand times, each as a syscall on the idle
/// path. The next launch tries again from scratch.
public final class LogFileSink: @unchecked Sendable {

    /// `~/Library/Logs/Isleta`. The conventional place — Console.app lists it under Log Reports,
    /// and a user told "look in Library/Logs" finds it where every other app's is.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Isleta", isDirectory: true)
    }

    public static let activeFileName = "isleta.log"
    public static let defaultMaximumFileSize = 2 * 1024 * 1024
    public static let defaultRetainedFileCount = 4

    /// `isleta.1.log` for 1, and so on. Index 0 is the live file.
    public static func rotatedFileName(_ index: Int) -> String {
        index == 0 ? activeFileName : "isleta.\(index).log"
    }

    /// Whether a directory entry is one of ours. The export collects by this rather than by
    /// enumerating indices, so a file left by an older layout is still bundled.
    public static func isLogFileName(_ name: String) -> Bool {
        name == activeFileName || (name.hasPrefix("isleta.") && name.hasSuffix(".log"))
    }

    public let directory: URL
    public let maximumFileSize: Int
    public let retainedFileCount: Int

    public var activeFileURL: URL {
        directory.appendingPathComponent(Self.activeFileName, isDirectory: false)
    }

    private let queue = DispatchQueue(label: "com.tryisleta.isleta.log", qos: .utility)
    private let fileManager = FileManager()

    // Queue-confined from here down.
    private var handle: FileHandle?
    private var size = 0
    private var hasOpened = false
    private var failure: String?

    public init(
        directory: URL = LogFileSink.defaultDirectory,
        maximumFileSize: Int = LogFileSink.defaultMaximumFileSize,
        retainedFileCount: Int = LogFileSink.defaultRetainedFileCount
    ) {
        self.directory = directory
        self.maximumFileSize = max(1024, maximumFileSize)
        self.retainedFileCount = max(1, retainedFileCount)
    }

    deinit {
        try? handle?.close()
    }

    /// Append one formatted line. Returns at once; the write happens on the sink's queue.
    public func write(_ line: String) {
        queue.async { [self] in
            append(line)
        }
    }

    /// Block until every line handed over before this call is on disk.
    public func drain() {
        queue.sync {}
    }

    /// Drain, then close the handle. The next `write` reopens.
    public func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
            hasOpened = false
        }
    }

    /// Why writing stopped, if it did. Nil while healthy.
    public var lastFailure: String? {
        queue.sync { failure }
    }

    /// One line for the diagnostics report: the directory, how many files, their total size, and
    /// the failure if there is one.
    public var status: String {
        let files = LogExport.collectFiles(in: directory)
        let bytes = files.reduce(0) { $0 + $1.size }
        var text = "\(directory.path) — \(files.count) file\(files.count == 1 ? "" : "s"), "
            + LogExport.formatBytes(bytes)
        if let failure = lastFailure {
            text += " — writing stopped: \(failure)"
        }
        return text
    }

    // MARK: - On the queue

    private func append(_ line: String) {
        guard failure == nil else { return }
        if !hasOpened { open() }
        guard let handle else { return }

        var data = Data(line.utf8)
        data.append(0x0A)

        do {
            try handle.write(contentsOf: data)
        } catch {
            fail("write failed: \(error.localizedDescription)")
            return
        }
        size += data.count
        if size >= maximumFileSize {
            rotate()
        }
    }

    private func open() {
        hasOpened = true
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = activeFileURL
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    fail("could not create \(url.path)")
                    return
                }
            }
            let opened = try FileHandle(forWritingTo: url)
            size = Int(try opened.seekToEnd())
            handle = opened
            if size > 0 {
                // A blank row between sessions. The launch line that follows names the session; the
                // gap is what lets an eye find it in a file holding several.
                try opened.write(contentsOf: Data([0x0A]))
                size += 1
            }
        } catch {
            fail("could not open \(activeFileURL.path): \(error.localizedDescription)")
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        hasOpened = false
        size = 0

        // Oldest first, so each move lands on a name that has just been vacated.
        let oldest = directory.appendingPathComponent(Self.rotatedFileName(retainedFileCount - 1))
        try? fileManager.removeItem(at: oldest)
        for index in stride(from: retainedFileCount - 2, through: 0, by: -1) {
            let from = directory.appendingPathComponent(Self.rotatedFileName(index))
            let to = directory.appendingPathComponent(Self.rotatedFileName(index + 1))
            guard fileManager.fileExists(atPath: from.path) else { continue }
            do {
                try fileManager.moveItem(at: from, to: to)
            } catch {
                // A rotation that cannot move a file is not worth stopping the log over: the live
                // file simply keeps growing past the limit until the next attempt succeeds.
                continue
            }
        }
    }

    private func fail(_ reason: String) {
        failure = reason
        try? handle?.close()
        handle = nil
    }
}
