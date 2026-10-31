import AppKit
import CoreServices
import Foundation
import IslandActivities
import IslandKit

/// Coding agents in the user's terminals that have stopped and are waiting on them, or have just
/// finished — so the person who looked away from the terminal hears about it at the notch.
///
/// # The route, and why it needs nothing installed
///
/// Claude Code keeps `~/.claude/sessions/<pid>.json` for every running session, and its `status`
/// moves between `busy`, `waiting` (stopped on a permission prompt, a dialog or a question) and
/// `idle` (the turn is over). Reading that file is all this source does. It needs no permission, no
/// hook in the agent's settings and no change to anything the agent owns. The format is the agent's
/// private one — `ClaudeSessionRecord` decodes it leniently and the measurement it was built against
/// is in `docs/PLATFORM-CONSTRAINTS.md`.
///
/// # Why this source keeps no timer on the idle path
///
/// The folder is watched with an FSEvents stream, which the kernel feeds only when a file in it
/// changes — and Claude Code rewrites a session's file only when the session's state changes, not
/// while it works. An app switch is an `NSWorkspace` notification, and a session's process ending
/// is a `DispatchSource` on its pid. The one scheduled thing is a session's grace, a single
/// six-second work item armed only while that session waits in the frontmost app
/// (`CodingAgentAttention.grace`). An idle Mac with three sessions open costs three process sources
/// and one stream.
///
/// # What it does not do
///
/// It never shows an agent that is merely working (see `CodingAgentMoment`), never shows a session
/// whose terminal is frontmost (`CodingAgentAttention`), and never reads the transcript: what the
/// agent said is not needed to say that it stopped. Codex keeps no equivalent file — its rollouts
/// are compressed transcripts — so it reaches the island only through its hooks, which is a separate
/// route the user opts into.
@MainActor
public final class CodingAgentSource: ActivitySource {

    public static let sourceName = "Coding agents"

    /// Nothing to grant. A Mac without Claude Code is not being refused anything — the source is
    /// running and has nothing to watch, which the Settings row says in words (`isAgentInstalled`).
    public var authorization: SourceAuthorization { .notRequired }

    public var onActivity: ((any IslandActivity) -> Void)?
    public var onDismiss: ((ActivityID) -> Void)?

    public private(set) var isRunning = false

    /// How many moments have been published this launch, for the Settings row. Counts only.
    public private(set) var announcementCount = 0

    private let folder: URL
    private var stream: FSEventStreamRef?
    private var activationObserver: NSObjectProtocol?
    private var attention = CodingAgentAttention()

    /// What is known about each live session, keyed by its file's name (`<pid>.json`).
    private var sessions: [String: Tracked] = [:]

    private struct Tracked {
        var record: ClaudeSessionRecord
        let terminal: NSRunningApplication?
        let exit: any DispatchSourceProcess
        /// Armed only while the session waits in the frontmost app — see `CodingAgentAttention.grace`.
        /// The one scheduled thing in this source, and it exists only while somebody is being waited on.
        var grace: DispatchWorkItem?
    }

    public init(folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)) {
        self.folder = folder
    }

    /// Whether Claude Code has ever run on this Mac, for the Settings row.
    public var isAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: folder.path)
    }

    public func start() {
        guard !isRunning else { return }
        guard isAgentInstalled else {
            IslandLog.sources.info("coding agents: no Claude Code sessions folder, source idle")
            return
        }
        isRunning = true
        // Watch first, then read, so a change landing between the two is seen twice rather than
        // never — reading a file twice is idempotent, and missing one is a session the island never
        // hears about until it changes again.
        startStream()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        rescan()
        IslandLog.sources.info("coding agents: watching \(self.sessions.count) session(s)")
    }

    public func stop() {
        guard isRunning else { return }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        for (key, tracked) in sessions {
            tracked.exit.cancel()
            tracked.grace?.cancel()
            if attention.showing(key) != nil {
                onDismiss?(Self.activityID(for: tracked.record))
            }
        }
        sessions = [:]
        attention = CodingAgentAttention()
        isRunning = false
        IslandLog.sources.info("coding agents: stopped")
    }

    /// Nothing outlives `stop()`: the stream is invalidated and every process source cancelled
    /// synchronously.
    public func stopAndWait() { stop() }

    /// Bring the terminal that owns this activity's session to the front — the window the session
    /// is in, on whatever Space it is on, when one can be told apart (`TerminalWindow`).
    ///
    /// `NSRunningApplication.activate` raises another app from an accessory one unconditionally —
    /// measured, and recorded in `docs/TRAPS.md` beside the call that does not — but not its Space.
    ///
    /// - Returns: whether there was a terminal to raise.
    @discardableResult
    public func bringForward(_ id: ActivityID) -> Bool {
        guard let tracked = sessions.values.first(where: { Self.activityID(for: $0.record) == id }),
              let terminal = tracked.terminal, !terminal.isTerminated
        else { return false }
        let names = TerminalWindow.names(
            cwd: tracked.record.cwd, sessionName: tracked.record.name,
            bundleIdentifier: terminal.bundleIdentifier)
        TerminalWindow.raise(terminal, names: names)
        return true
    }

    // MARK: - Reading

    private func rescan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let present = Set(names.filter { $0.hasSuffix(".json") })
        for gone in Set(sessions.keys).subtracting(present) {
            forget(gone)
        }
        for name in present {
            read(name)
        }
    }

    private func read(_ name: String) {
        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let record = ClaudeSessionRecord.decode(data),
              record.isPersonAtPrompt
        else {
            forget(name)
            return
        }

        if var tracked = sessions[name], tracked.record.pid == record.pid {
            let reasonChanged = tracked.record.wait != record.wait
            tracked.record = record
            sessions[name] = tracked
            // A session can go from one reason to another without leaving `waiting` — a permission
            // prompt answered straight into a question — which the attention table rightly sees as
            // no change. The island's words are the reason, so they are refreshed in place.
            if reasonChanged, record.wait != nil, attention.showing(name) == .needsInput {
                onActivity?(BuiltInActivity.codingAgent(Self.session(for: tracked), moment: .needsInput))
            }
        } else {
            forget(name)
            // A file outlives its process and pids are recycled, so the pid has to be alive *and*
            // still running something Claude-shaped — the native binary or the npm CLI under node.
            guard ProcessAncestry.isAlive(record.pid), Self.isClaude(record.pid) else { return }
            let exit = DispatchSource.makeProcessSource(identifier: record.pid, eventMask: .exit, queue: .main)
            exit.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.forget(name) }
            }
            exit.resume()
            sessions[name] = Tracked(
                record: record,
                terminal: ProcessAncestry.owningApplication(of: record.pid),
                exit: exit
            )
        }
        apply(name)
    }

    private func forget(_ name: String) {
        guard let tracked = sessions.removeValue(forKey: name) else { return }
        tracked.exit.cancel()
        tracked.grace?.cancel()
        if attention.update(name, status: nil, isFrontmost: false).contains(.dismiss) {
            onDismiss?(Self.activityID(for: tracked.record))
        }
    }

    private func frontmostChanged() {
        for name in sessions.keys {
            apply(name, cause: .activated)
        }
    }

    private func apply(_ name: String, cause: CodingAgentAttention.Cause = .stateChanged) {
        guard let tracked = sessions[name] else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isFrontmost = tracked.terminal.map { $0.processIdentifier == frontmost } ?? false
        let effects = attention.update(name, status: tracked.record.status, isFrontmost: isFrontmost, cause: cause)
        for effect in effects {
            switch effect {
            case .present(let moment):
                announcementCount += 1
                IslandLog.sources.info("coding agents: session \(moment == .needsInput ? "needs input" : "finished")")
                onActivity?(BuiltInActivity.codingAgent(Self.session(for: tracked), moment: moment))
            case .dismiss:
                onDismiss?(Self.activityID(for: tracked.record))
            case .armGrace:
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.apply(name, cause: .graceElapsed) }
                }
                sessions[name]?.grace?.cancel()
                sessions[name]?.grace = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + CodingAgentAttention.grace, execute: work)
            }
        }
    }

    private static func session(for tracked: Tracked) -> CodingAgentSession {
        CodingAgentSession(
            agent: .claudeCode,
            sessionID: tracked.record.sessionID,
            name: tracked.record.name,
            terminalApplicationName: tracked.terminal.flatMap(Self.applicationName),
            waitingFor: tracked.record.wait
        )
    }

    /// The name a person knows the app by. A running app's `localizedName` is its process's, which
    /// for VS Code is "Code"; the bundle's display name is "Visual Studio Code", and it is also a
    /// name `ApplicationIcons` resolves.
    private static func applicationName(_ application: NSRunningApplication) -> String? {
        guard let url = application.bundleURL else { return application.localizedName }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func activityID(for record: ClaudeSessionRecord) -> ActivityID {
        CodingAgentSession(agent: .claudeCode, sessionID: record.sessionID, name: nil, terminalApplicationName: nil)
            .activityID
    }

    private static func isClaude(_ pid: pid_t) -> Bool {
        guard let path = ProcessAncestry.executablePath(of: pid)?.lowercased() else { return false }
        let base = (path as NSString).lastPathComponent
        return path.contains("claude") || base == "node" || base == "bun"
    }

    // MARK: - The stream

    private func startStream() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<CodingAgentSource>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { source.rescan() }
        }
        // File-level events, because Claude Code rewrites a session's file in place as well as
        // creating and removing it, and a directory-level stream reports only the latter. The whole
        // folder is re-listed per callback rather than per path: it holds one small file per open
        // session, and re-reading four of them is cheaper to reason about than FSEvents' coalesced
        // path flags.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            IslandLog.sources.error("coding agents: could not create the folder stream")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
