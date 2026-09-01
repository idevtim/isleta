import AppKit
import IslandKit
import IslandSources

/// Explicit entry point.
///
/// `@main` on an `NSApplicationDelegate` resolves to `NSApplicationMain`, which discovers its
/// delegate from the main nib. Isleta has no nib, so nothing ever set the delegate and
/// `applicationDidFinishLaunching` was never called — the process just sat in its run loop with no
/// island and no status item. Constructing the application and its delegate by hand is explicit,
/// and skips nib loading entirely, which the 300ms cold-launch budget cares about.
@main
enum IsletaMain {

    /// `NSApplication.delegate` is a weak reference, so the delegate has to be owned here.
    @MainActor
    private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        // **Before everything, including the log file.** A conversion runs in a child process, and
        // that child is this same binary with one flag on it (see `FileActionWorker`): it must not
        // build an `AppDelegate`, must not attach a second writer to the rotating log — two
        // processes appending to one file is how a log ends up interleaved mid-line — must not stand
        // up a status item, a panel or Sparkle, and must not connect to the window server for a
        // process whose whole life is a few hundred milliseconds of file work. `main()` there reads
        // one request from stdin, does the work, and exits; it never returns.
        if FileActionWorker.isWorker() {
            FileActionWorker.main()
        }

        // The log file first, before the delegate exists. `AppDelegate`'s property initializers
        // construct `SettingsStore`, which reads and migrates the configuration blob and logs if it
        // cannot — so the file has to be attached before the first line of the delegate runs, or the
        // first thing a launch can say is held in the backlog until it is. Attaching costs nothing
        // until the first line: the file is opened lazily, on the sink's own queue.
        configureLogging()

        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    /// `~/Library/Logs/Isleta/isleta.log` at `info`, or at `debug` for `--verbose-logging` or
    /// `defaults write com.tryisleta.isleta VerboseLogging -bool YES`.
    ///
    /// The default rather than a setting in the window: verbose logging is something support asks a
    /// user to switch on for one reproduction, and a switch in Settings is a switch somebody leaves
    /// on. A `defaults write` is reversible in the same breath it was given in, and a tester who can
    /// run the app from Terminal gets the flag.
    @MainActor
    private static func configureLogging() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--verbose-logging") || UserDefaults.standard.bool(forKey: "VerboseLogging") {
            IslandLog.minimumLevel = .debug
        }
        IslandLog.attach(LogFileSink())
    }
}
