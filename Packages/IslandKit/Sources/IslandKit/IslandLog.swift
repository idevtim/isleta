import Foundation
import os

/// Isleta's log: a small fixed taxonomy of categories, one line format, and two outputs — the
/// unified log (Console.app, `log stream`) and a rotating file under `~/Library/Logs/Isleta` that
/// "Export Logs…" bundles for a bug report.
///
/// Why both. The unified log is the right place for a developer with the machine in front of them,
/// and the wrong place for a user: `info` and `debug` are held in memory and gone by the time anyone
/// asks, `log show` needs the exact subsystem and a time window, and nothing about a support request
/// ("the island stopped appearing on my second display yesterday") fits either. The file is what a
/// person can be asked for. It holds the previous run — the one that crashed — and every run before
/// it up to the rotation limit, which the unified log's process-scoped store
/// (`OSLogStore.currentProcessIdentifier`) cannot.
///
/// # The rules
///
/// - **Categories are concerns you follow across the app, never components.** `nowPlaying` is the
///   whole route from helper spawn to track change, wherever the code lives; `space` is everything
///   about the island surviving a space switch. A taxonomy that grows one entry per type is back to
///   reading the whole file. `grep '\[space\]'` should answer "what happened to the island during the
///   slide" on its own.
/// - **Nothing the user did not write themselves goes in.** No notification text, no track title or
///   artist, no file name dropped on the shelf, no window title. Counts, states, bundle identifiers,
///   pids, error codes and our own geometry are the vocabulary. The export is a file the user emails
///   to a stranger; the unified log is readable by every process on the machine. Both outputs get
///   the same string, marked `.public` for the unified log, so there is no second, redacted version to
///   keep honest — the one string has to be clean.
/// - **Not on the hot path, and not on the idle path.** A hover, a scroll sample, a display-link tick
///   and a CoreAudio callback are not log lines. Things that happen once per user action or once per
///   system event are. `debug` exists for the per-event detail a bug needs and a routine export does
///   not, and it costs nothing unless enabled: the message is an autoclosure that is never evaluated
///   below `minimumLevel`, for either output.
/// - **Nothing here waits.** The file write is `async` onto a utility queue; the caller returns after
///   formatting one string. `drain()` exists for the quit path, which returns into `exit()` and
///   therefore has to be synchronous through to the `write(2)` — see `applicationWillTerminate`.
///
/// # Before the file exists
///
/// There is deliberately no default sink. A package test must never write into the user's
/// `~/Library/Logs`, and several types log from their initializers — `SettingsStore` reads its blob
/// in `init`, which runs from `AppDelegate`'s property initializers before `main()` has done anything
/// — so lines can arrive before the app has attached one. Those go to the unified log at once and
/// into a bounded backlog that is replayed into the sink on `attach(_:)`, in order, so the file reads
/// the way the launch happened: the configuration load first, then the launch line.
public enum IslandLog {

    /// The `os.Logger` subsystem. One per app; the category is what varies.
    public static let subsystem = "com.tryisleta.isleta"

    // MARK: Categories

    /// Launch, quit, self-tests, the status item, the export itself.
    public static let app = LogCategory("app")
    /// Displays arriving and leaving, panels built and repositioned, the overlay space.
    public static let panel = LogCategory("panel")
    /// The island across a space switch: hidden, restored, and on which signal.
    public static let space = LogCategory("space")
    /// Sources starting and stopping, and what each is authorized to do.
    public static let sources = LogCategory("sources")
    /// The Now Playing route end to end: which provider, the helper's life, transport failures.
    public static let nowPlaying = LogCategory("nowplaying")
    /// The accessibility observer: attach, retry, scan counts. Never a notification's text.
    public static let notifications = LogCategory("notifications")
    /// CoreAudio registration and which properties the output device turned out to have.
    public static let audio = LogCategory("audio")
    /// Sleep, wake, lock and unlock, and what Welcome Back decided about them.
    public static let system = LogCategory("system")
    /// Configuration read, migrated, written and changed; launch at login.
    public static let settings = LogCategory("settings")
    /// Sparkle: started or not, found something or not.
    public static let updates = LogCategory("updates")
    /// Global hot keys: registered, refused, released.
    public static let hotKeys = LogCategory("hotkeys")
    /// Drops onto the shelf — counts and kinds, never names.
    public static let shelf = LogCategory("shelf")
    /// The calendar route: authorization, event and calendar **counts**, which boundary woke the
    /// source. Never a title, a note, a location, an attendee or a meeting URL.
    public static let calendar = LogCategory("calendar")
    /// Which weather provider was chosen and whether a refresh answered. Never a coordinate, never
    /// a place name — where somebody is standing is the most identifying thing in this file.
    public static let weather = LogCategory("weather")

    // MARK: Configuration

    /// Lines below this are dropped without evaluating their message. Defaults to `.info`; the app
    /// raises it to `.debug` for `--verbose-logging` or the `VerboseLogging` default.
    public static var minimumLevel: LogLevel {
        get { router.minimumLevel }
        set { router.minimumLevel = newValue }
    }

    /// Start writing to `sink`, after replaying whatever arrived before it existed.
    public static func attach(_ sink: LogFileSink) {
        router.attach(sink)
    }

    /// The sink currently attached, if any. For the export, which needs its directory.
    public static var sink: LogFileSink? { router.sink }

    /// Blocks until every line handed over so far is in the file. For the quit path only.
    public static func drain() {
        router.sink?.drain()
    }

    /// One line for the diagnostics report: where the file is and how it is doing.
    public static var status: String {
        guard let sink = router.sink else { return "no log file attached" }
        return sink.status
    }

    // MARK: Plumbing

    static let router = LogRouter()

    static func emit(_ level: LogLevel, _ category: LogCategory, _ message: () -> String) {
        guard level >= router.minimumLevel else { return }
        let text = message()
        // The unified log gets every line the file does, at the matching type, marked public: the
        // rule that nothing personal goes in is enforced at the call site, not by redaction here.
        os.Logger(subsystem: subsystem, category: category.name)
            .log(level: level.osLogType, "\(text, privacy: .public)")
        router.write(LogLine.format(date: Date(), level: level, category: category, message: text))
    }
}

/// Severity, least to most. Comparable so a level can be a threshold.
public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// How the level prints. Five characters wide so the columns line up in the file.
    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO "
        case .warning: "WARN "
        case .error: "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    /// The inverse of `label`, tolerant of the padding and of case. For `--verbose-logging`-style
    /// arguments and tests; nil for anything that is not a level.
    public init?(label: String) {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = LogLevel.allCases.first(where: {
            $0.label.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }) else { return nil }
        self = match
    }
}

/// One of the fixed categories. Constructed only by `IslandLog`; call sites reach for
/// `IslandLog.sources.info(...)` rather than naming a string, so the taxonomy cannot grow by typo.
public struct LogCategory: Sendable, Hashable {

    public let name: String

    init(_ name: String) {
        self.name = name
    }

    /// Per-event detail a bug needs and a routine export does not. Off by default, and free when
    /// off: the message is never built.
    public func debug(_ message: @autoclosure () -> String) {
        IslandLog.emit(.debug, self, message)
    }

    /// Something happened that a reader of the file would want to know about.
    public func info(_ message: @autoclosure () -> String) {
        IslandLog.emit(.info, self, message)
    }

    /// Something is not as it should be, and the app carried on.
    public func warning(_ message: @autoclosure () -> String) {
        IslandLog.emit(.warning, self, message)
    }

    /// Something failed. The user may or may not have seen it.
    public func error(_ message: @autoclosure () -> String) {
        IslandLog.emit(.error, self, message)
    }
}

/// The one line format. Pure, so a test can pin it without a file or a clock.
public enum LogLine {

    /// `2026-08-21 10:18:03.123 INFO  [sources] message`.
    ///
    /// Local wall-clock time to the millisecond. Local, because the person reading the export is
    /// matching it against what they saw on their own clock; milliseconds, because the bugs this
    /// file is read for are ordering bugs — which signal arrived first across a space switch, whether
    /// the helper died before or after the settings change — and seconds cannot answer those. The
    /// UTC offset is stated once, in the launch line, rather than on every row.
    ///
    /// A message spanning several lines is indented from its second line on, so one grep hit is one
    /// event and a continuation can never be mistaken for a line with no timestamp.
    public static func format(
        date: Date,
        level: LogLevel,
        category: LogCategory,
        message: String,
        timeZone: TimeZone = .current
    ) -> String {
        let body = message.replacingOccurrences(of: "\n", with: "\n    ")
        return "\(timestamp(date, timeZone: timeZone)) \(level.label) [\(category.name)] \(body)"
    }

    /// `2026-08-21 10:18:03.123`, in the given zone.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        // Rounded, not truncated: a Date built from 0.123 s is 122_999_999 ns.
        let millis = min(999, ((c.nanosecond ?? 0) + 500_000) / 1_000_000)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
    }

    /// `+0200` / `-0400` for the given zone at the given instant. For the launch line.
    public static func utcOffset(_ date: Date, timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }
}

/// Where lines go before and after a sink exists. Internal; `IslandLog` is the API.
///
/// A lock rather than an actor because the call sites are synchronous and many of them are
/// `@MainActor` — a log line that needed an `await` would change the shape of every function that
/// wanted to write one.
final class LogRouter: @unchecked Sendable {

    /// How many lines are kept for a sink that has not been attached yet. Generous for a launch —
    /// the app attaches within its first milliseconds — and a hard cap, so a process that never
    /// attaches (a test bundle) holds a few kilobytes rather than growing for its lifetime.
    static let backlogLimit = 256

    private struct State {
        var sink: LogFileSink?
        var minimumLevel: LogLevel = .info
        var backlog: [String] = []
        var dropped = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var minimumLevel: LogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = newValue } }
    }

    var sink: LogFileSink? {
        state.withLock { $0.sink }
    }

    /// Lines waiting for a sink. For tests.
    var backlogCount: Int {
        state.withLock { $0.backlog.count }
    }

    func attach(_ sink: LogFileSink) {
        let replay: [String] = state.withLock { state in
            state.sink = sink
            var lines = state.backlog
            if state.dropped > 0 {
                lines.insert(
                    LogLine.format(
                        date: Date(), level: .warning, category: IslandLog.app,
                        message: "\(state.dropped) earlier line(s) were dropped before the log file was attached"
                    ),
                    at: 0
                )
            }
            state.backlog.removeAll()
            state.dropped = 0
            return lines
        }
        for line in replay {
            sink.write(line)
        }
    }

    func write(_ line: String) {
        let sink: LogFileSink? = state.withLock { state in
            if let sink = state.sink { return sink }
            if state.backlog.count < Self.backlogLimit {
                state.backlog.append(line)
            } else {
                state.dropped += 1
            }
            return nil
        }
        sink?.write(line)
    }

    /// Forget the sink. For tests; the app never detaches.
    func reset() {
        state.withLock { state in
            state.sink = nil
            state.backlog.removeAll()
            state.dropped = 0
            state.minimumLevel = .info
        }
    }
}
