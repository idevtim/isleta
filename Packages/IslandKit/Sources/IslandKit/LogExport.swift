import Darwin
import Foundation

/// One log file on disk, as the export sees it.
public struct LogExportFile: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let size: Int
    public let modified: Date

    public init(url: URL, name: String, size: Int, modified: Date) {
        self.url = url
        self.name = name
        self.size = size
        self.modified = modified
    }
}

/// Assembling "Export Logs…" — everything about it that needs no save panel.
///
/// The menu item, the `NSSavePanel` and the alert are the app shell's (`LogExporter`); what goes
/// *in* the file is here, pure, so it can be tested without a log directory. The shape copies what
/// has worked elsewhere: one text file, an environment header so the export is self-describing
/// without a follow-up question, the diagnostics report the status item already knows how to write,
/// then every log file concatenated oldest first under its own banner. One file rather than a folder
/// because one file is what gets attached to an email in a single step.
public enum LogExport {

    /// Every log file in `directory`, oldest first, so the bundle reads chronologically. Collects
    /// whatever is actually there — by name pattern, not by the rotation's indices — so a file left
    /// by an earlier layout is still included rather than silently skipped. A missing or unreadable
    /// directory is "nothing to export", which the caller reports, not an error.
    public static func collectFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [LogExportFile] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var files: [LogExportFile] = []
        for name in names where LogFileSink.isLogFileName(name) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = attributes[.modificationDate] as? Date ?? Date.distantPast
            files.append(LogExportFile(url: url, name: name, size: size, modified: modified))
        }
        // Modification time, then name — two files rotated in the same second keep a deterministic
        // order rather than whichever the directory listing happened to give.
        files.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
            return lhs.name > rhs.name
        }
        return files
    }

    /// `Isleta-logs-2026-08-21-10-18-03.log`. Dashes throughout: a colon is awkward in a Finder
    /// name and illegal wherever the file ends up if it is forwarded to a Windows machine.
    public static func fileName(exportedAt: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: exportedAt)
        return String(
            format: "Isleta-logs-%04d-%02d-%02d-%02d-%02d-%02d.log",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// The complete export.
    ///
    /// - Parameters:
    ///   - environment: Label/value rows for the header, in the order given.
    ///   - sections: Titled blocks placed between the header and the files — the diagnostics report.
    ///   - files: What `collectFiles(in:)` returned.
    ///   - read: How to get a file's text. Injected so a test needs no disk, and so a file that
    ///     cannot be read (deleted mid-export, rotated under us) is noted inline instead of costing
    ///     the user the whole bundle.
    public static func bundle(
        environment: [(label: String, value: String)],
        sections: [(title: String, body: String)] = [],
        files: [LogExportFile],
        timeZone: TimeZone = .current,
        read: (URL) throws -> String
    ) -> String {
        var out = header(environment: environment, fileCount: files.count)

        for section in sections {
            out += "\n=== \(section.title) ===\n"
            out += section.body
            if !out.hasSuffix("\n") { out += "\n" }
        }

        for file in files {
            let stamp = LogLine.timestamp(file.modified, timeZone: timeZone)
            out += "\n=== \(file.name) (\(formatBytes(file.size)), modified \(stamp)) ===\n"
            do {
                out += try read(file.url)
            } catch {
                out += "[Could not read this file: \(error.localizedDescription)]\n"
            }
            if !out.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    /// The banner at the top. Label column padded to the widest label so the values line up.
    static func header(environment: [(label: String, value: String)], fileCount: Int) -> String {
        var rows = environment
        rows.append((label: "Files included", value: "\(fileCount)"))
        let width = rows.map(\.label.count).max() ?? 0
        var lines = [
            "=========================================",
            " Isleta — Log Export",
            "=========================================",
        ]
        for row in rows {
            lines.append("\(row.label):".padding(toLength: width + 3, withPad: " ", startingAt: 0) + row.value)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// `12 bytes`, `3.4 KB`, `1.2 MB`.
    public static func formatBytes(_ bytes: Int) -> String {
        switch bytes {
        case ..<1024: "\(bytes) bytes"
        case ..<(1024 * 1024): String(format: "%.1f KB", Double(bytes) / 1024)
        default: String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

/// What this Mac is, for the launch line and the export header.
///
/// Read from the kernel rather than from anything that needs AppKit, so IslandKit's tests and the
/// logger itself can use it. None of it identifies the user: a model identifier and an OS build are
/// what every crash report already carries.
public enum HostDescription {

    /// `27.0 (26A5416b)` — the marketing version and the build, the two numbers a bug report needs.
    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion != 0 { version += ".\(v.patchVersion)" }
        if let build = sysctlString("kern.osversion") {
            version += " (\(build))"
        }
        return version
    }

    /// `Mac16,6` — the model identifier, or `unknown` where the kernel will not say.
    public static var hardwareModel: String {
        sysctlString("hw.model") ?? "unknown"
    }

    /// `arm64`. Isleta builds for one architecture, and the line is there so a report from a
    /// machine that somehow is not says so.
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end], as: UTF8.self)
    }
}
