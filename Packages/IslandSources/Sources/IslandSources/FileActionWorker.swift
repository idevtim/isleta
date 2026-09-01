import Darwin
import Foundation
import IslandActivities

/// The child process that does the work. **This is Isleta's own binary, run again with one flag.**
///
/// ## Why re-exec ourselves rather than vendor a helper
///
/// The conversion routes need ImageIO, AVFoundation, AppKit's rich-text importer and Speech — all
/// of which are already linked into this binary and none of which is a dependency anyone would want
/// to ship twice. A separate helper target would be a second executable to sign inside-out, notarize
/// and keep in step, for code that is already here. `argv[0]` is the app's own executable, the flag
/// is a constant, and the whole protocol is one JSON line in and newline-delimited JSON out.
///
/// It also makes the identification rule in `FileActionOrphans` sharp: a stranded worker is *this
/// executable path* plus *this flag*, and nothing else on the machine looks like that.
///
/// ## What it deliberately does not do
///
/// **It attaches no log sink.** `IslandLog` has no default sink, so a line logged here goes to the
/// unified log and nowhere near `~/Library/Logs/Isleta/isleta.log` — two processes appending to one
/// rotating file is how a log ends up interleaved mid-line. The parent logs the outcome; the worker
/// logs nothing at all, which also means there is no path by which a file name could reach a log
/// from the one process that knows all of them.
///
/// **It never creates an `NSApplication`.** Nothing here draws, and `NSApplication.shared` would
/// connect to the window server for a process whose whole life is a few hundred milliseconds of
/// file work.
///
/// **It never opens a panel and never chooses a destination.** The parent decides where output goes,
/// because the parent is the one that can ask the user.
public enum FileActionWorker {

    /// The one argument that turns this binary into a worker. Checked before anything else in
    /// `IsletaMain`, so a worker never reaches the delegate, the status item or Sparkle.
    public static let flag = "--file-worker"

    public static func isWorker(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Reads one request from stdin, performs it, writes events to stdout, and exits.
    ///
    /// Exit codes carry only the coarse answer — 0 for "something was produced", 1 for "nothing
    /// was" — because the useful half is the `failed` event, which carries Isleta's own words. The
    /// parent reads the events and treats the status as a backstop for a worker that died without
    /// saying anything, which is the case no event can describe.
    public static func main() -> Never {
        guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty,
              let request = try? JSONDecoder().decode(FileConversionRequest.self, from: data) else {
            write(.failed(sourceText("fileAction.failed.notStarted", "The conversion could not be started")))
            exit(1)
        }

        let tally = Tally()
        // The engine is `async` and this process has no run loop, so main blocks on a semaphore
        // while the work runs on the concurrency pool. Nothing here is main-actor isolated —
        // deliberately, because every route was measured correct off the main thread and the one
        // that would not be (`NSTextView`) is not used at all.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await FileConversionEngine.run(request) { event in
                if case .produced = event { tally.markProduced() }
                write(event)
            }
            done.signal()
        }
        done.wait()

        exit(tally.produced ? 0 : 1)
    }

    /// One line of JSON, flushed.
    ///
    /// Flushed on every line rather than at exit, because the parent draws a progress island from
    /// these: a buffered pipe would deliver a smooth run of fractions all at once, at the end, to a
    /// bar that had sat at zero for the whole job.
    private static func write(_ event: FileConversionEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    /// The engine reports from whichever thread its route happens to be on, and two routes running
    /// over a list of files can report from two. One lock so a line cannot be spliced into another.
    private static let lock = NSLock()

    /// Whether anything was written. A class because the closure that sets it is `@Sendable` and
    /// crosses a thread; `@unchecked` on the same basis as everything else in this file — one lock,
    /// and nothing touches the value without it.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var produced: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func markProduced() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
