import AppKit
import IslandKit
import IslandSettings
import UniformTypeIdentifiers

/// "Export Logs…" — the status item's other diagnostics path.
///
/// The diagnostics report alone is a snapshot of *now*; this is that report plus the history, in a
/// file. It writes one text file — environment header, the same diagnostics report, then every log
/// file oldest first — to a place the user picks, and offers to show it in the Finder. One file
/// rather than revealing the log folder, because one file is what gets attached to a bug report in a
/// single step, and because the diagnostics report travels with the logs instead of arriving in a
/// second email.
///
/// The panel is an `NSSavePanel` from an accessory app, which has the same problem the settings
/// window has: nothing yields activation to a status-item click, so without
/// `activate(ignoringOtherApps:)` the panel arrives behind the frontmost app without key focus —
/// see `SettingsWindowController.show()` for the six-variant measurement. Everything that decides
/// what the file *contains* is `LogExport`, in IslandKit, and tested there.
@MainActor
enum LogExporter {

    /// Present the save panel and, if the user confirms, write the bundle.
    /// - Parameters:
    ///   - diagnostics: The "Copy Diagnostics" text, taken at the moment of export.
    ///   - destination: Where to write *without asking* — the `--export-logs <path>` flag, which is
    ///     how the bundle is checked headlessly. Nil, the normal case, shows the panel and the
    ///     alert; a path shows neither and prints the outcome to stdout instead.
    static func run(diagnostics: String, destination: URL? = nil) {
        guard let sink = IslandLog.sink else {
            report(
                destination,
                style: .warning,
                appText("logExport.notRunning.title", "Logging is not running."),
                detail: appText(
                    "logExport.notRunning.detail",
                    "No log file is attached in this build, so there is nothing to export."
                ),
                diagnostic: "logging is not running — no log file is attached in this build"
            )
            return
        }
        // Every line handed over before this click is on disk before the directory is read.
        sink.drain()

        let files = LogExport.collectFiles(in: sink.directory)
        guard !files.isEmpty else {
            report(
                destination,
                style: .informational,
                appText("logExport.noFiles.title", "No log files were found."),
                detail: appText("logExport.noFiles.detail", "Nothing has been written to:\n\(sink.directory.path)"),
                diagnostic: "no log files were found in \(sink.directory.path)"
            )
            return
        }

        let exportedAt = Date()
        if let destination {
            write(files: files, diagnostics: diagnostics, exportedAt: exportedAt, to: destination, from: sink, silently: true)
            return
        }

        let panel = NSSavePanel()
        panel.title = appText("logExport.panel.title", "Export Logs")
        panel.prompt = appText("logExport.panel.prompt", "Export")
        panel.nameFieldStringValue = LogExport.fileName(exportedAt: exportedAt)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.log, .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let destination = panel.url else {
                    IslandLog.app.info("log export canceled")
                    return
                }
                write(files: files, diagnostics: diagnostics, exportedAt: exportedAt, to: destination, from: sink)
            }
        }
    }

    private static func write(
        files: [LogExportFile],
        diagnostics: String,
        exportedAt: Date,
        to destination: URL,
        from sink: LogFileSink,
        silently: Bool = false
    ) {
        let bundle = LogExport.bundle(
            environment: [
                (label: "Exported", value: "\(LogLine.timestamp(exportedAt)) \(LogLine.utcOffset(exportedAt))"),
                (label: "App version", value: "\(AppVersion.marketing ?? "development") (\(AppVersion.build ?? "—"))"),
                (label: "macOS", value: HostDescription.macOSVersion),
                (label: "Hardware", value: "\(HostDescription.hardwareModel) (\(HostDescription.architecture))"),
                (label: "Log directory", value: sink.directory.path),
                (label: "Log level", value: IslandLog.minimumLevel.label.trimmingCharacters(in: .whitespaces).lowercased()),
            ],
            sections: [(title: "Diagnostics", body: diagnostics)],
            files: files
        ) { url in
            try String(contentsOf: url, encoding: .utf8)
        }

        do {
            try bundle.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            IslandLog.app.error("log export failed: \(error.localizedDescription)")
            report(
                silently ? destination : nil,
                style: .critical,
                appText("logExport.failed.title", "Could not export the logs."),
                detail: error.localizedDescription,
                diagnostic: "could not export the logs: \(error.localizedDescription)"
            )
            return
        }

        // The destination is the user's own choice on their own disk, written by them, into their
        // own log — not somebody else's file name arriving in ours.
        IslandLog.app.info("exported \(files.count) log file(s) to \(destination.path)")
        if silently {
            print("log export: \(files.count) file(s) → \(destination.path)")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = appText("logExport.done.title", "Logs exported.")
        alert.informativeText = appText(
            "logExport.done.detail",
            "\(files.count) log files and the diagnostics report were written to:\n\(destination.path)"
        )
        alert.addButton(withTitle: appText("common.showInFinder", "Show in Finder"))
        alert.addButton(withTitle: appText("common.ok", "OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    /// An alert for a person, or a line on stdout for the headless flag.
    ///
    /// **Two channels, two languages, and that is the point of `diagnostic` being a separate
    /// argument.** `message` and `detail` are what a person reads and are translated; `diagnostic`
    /// is what `--export-logs` prints and is English always, for the reason every `IslandLog` line
    /// is: it is read by whoever is debugging, it is what a bug report is checked against, and a
    /// German copy of it would break every grep written for it. Deriving one from the other would
    /// have made the headless check speak whatever language the machine running it happens to be
    /// set to.
    private static func report(
        _ headless: URL?,
        style: NSAlert.Style,
        _ message: String,
        detail: String,
        diagnostic: String
    ) {
        if headless != nil {
            print("log export: \(diagnostic)")
            return
        }
        alert(style: style, message, detail: detail)
    }

    private static func alert(style: NSAlert.Style, _ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: appText("common.ok", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
