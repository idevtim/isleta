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
///
/// # Answering from the island
///
/// With `answersPrompts` on, Isleta's hook is registered in `~/.claude/settings.json` and the
/// island can answer a permission prompt itself (`AgentHookServer`). The session file is still
/// what says a session is waiting; the hook adds *what* it is asking and a connection to answer
/// down. A prompt the island is holding is released the moment the session stops waiting —
/// answered in the terminal, interrupted, or ended — because nothing else tells the hook
/// (`docs/PLATFORM-CONSTRAINTS.md`), and a hook left holding would wait out its whole timeout.
///
/// # Codex
///
/// Codex keeps no state file, so with the switch on its sessions are followed through hooks alone
/// (`AgentHookSettings.codexEvents`), on the same attention table. Its permission hook differs in
/// the way that matters: **Codex shows nothing in the terminal while the hook holds the request**
/// (measured — `docs/PLATFORM-CONSTRAINTS.md`). So a Codex prompt is held only while its terminal
/// is somewhere the person is not: it is let go at once when the terminal is frontmost, the moment
/// the terminal comes forward, and on a click through to it — and never held for a session whose
/// terminal could not be found, which could never come forward.
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

    private let settingsURL: URL
    private let hookServer: AgentHookServer

    /// The prompts the hook is holding, keyed by the agent's session id — which arrives on the hook
    /// before, or after, the session file says it is waiting.
    private var prompts: [String: HeldPrompt] = [:]

    private struct HeldPrompt {
        let request: AgentHookRequest
        let prompt: CodingAgentPrompt
    }

    /// Whether the person wants permission prompts answered from the island. The hook's place in
    /// the agent's settings follows this and nothing else — not launch or quit, which would rewrite
    /// somebody's settings file twice a day — and the socket follows this *and* `isRunning`.
    public private(set) var answersPrompts = false

    /// What the last attempt to follow `answersPrompts` found, for the Settings row.
    public private(set) var promptsState: AgentPromptsState = .off

    private let codexHooksURL: URL

    /// Codex sessions seen through their hooks, keyed by Codex's session id.
    private var codexSessions: [String: CodexTracked] = [:]

    private struct CodexTracked {
        var status: ClaudeSessionRecord.Status
        let cwd: String?
        let terminal: NSRunningApplication?
        let exit: (any DispatchSourceProcess)?
        var grace: DispatchWorkItem?
    }

    /// Whether Codex has ever run on this Mac, for the Settings caption.
    public var isCodexInstalled: Bool {
        FileManager.default.fileExists(atPath: codexHooksURL.deletingLastPathComponent().path)
    }

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

    public init(
        folder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true),
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        codexHooksURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json"),
        hookServer: AgentHookServer = AgentHookServer()
    ) {
        self.folder = folder
        self.settingsURL = settingsURL
        self.codexHooksURL = codexHooksURL
        self.hookServer = hookServer
        hookServer.onEvent = { [weak self] event, request in
            self?.received(event, request: request)
        }
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
        updateServer()
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
        for (id, codex) in codexSessions {
            codex.exit?.cancel()
            codex.grace?.cancel()
            if attention.showing(Self.codexKey(id)) != nil {
                onDismiss?(Self.codexSession(id, codex, prompt: nil).activityID)
            }
        }
        codexSessions = [:]
        attention = CodingAgentAttention()
        isRunning = false
        updateServer()
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
        if let (sessionID, codex) = codexSessions.first(where: {
            Self.codexSession($0.key, $0.value, prompt: nil).activityID == id
        }) {
            guard let terminal = codex.terminal, !terminal.isTerminated else { return false }
            // Before the raise: Codex's own prompt appears only once the hook lets go, and the
            // person is on their way to it.
            release(sessionID: sessionID)
            let names = TerminalWindow.names(
                cwd: codex.cwd, sessionName: nil, bundleIdentifier: terminal.bundleIdentifier)
            TerminalWindow.raise(terminal, names: names)
            return true
        }
        guard let tracked = sessions.values.first(where: { Self.activityID(for: $0.record) == id }),
              let terminal = tracked.terminal, !terminal.isTerminated
        else { return false }
        let names = TerminalWindow.names(
            cwd: tracked.record.cwd, sessionName: tracked.record.name,
            bundleIdentifier: terminal.bundleIdentifier)
        TerminalWindow.raise(terminal, names: names)
        return true
    }

    // MARK: - Answering from the island

    /// Follow the person's switch: register the hook in the agent's settings, or take exactly it
    /// back out, and open or close the socket. Idempotent, and it writes the settings file only
    /// when what is there disagrees with the switch — so calling it on every settings change costs
    /// one small read.
    public func setAnswersPrompts(_ wanted: Bool) {
        answersPrompts = wanted
        let scriptPath = AgentHookScript.installedURL.path
        let targets: [(agent: CodingAgent, url: URL, events: [AgentHookSettings.Event])] = [
            (.claudeCode, settingsURL, AgentHookSettings.claudeCodeEvents),
            (.codex, codexHooksURL, AgentHookSettings.codexEvents),
        ]
        var state: AgentPromptsState = wanted ? .agentNotInstalled : .off
        do {
            if wanted {
                // Rewritten every time: the copy on disk is always this build's (`AgentHookScript`).
                try AgentHookScript.install()
            }
            for target in targets {
                // A Mac that has never run an agent has no folder for it, and creating one would be
                // Isleta inventing the agent's configuration for it.
                guard FileManager.default.fileExists(atPath: target.url.deletingLastPathComponent().path) else {
                    continue
                }
                do {
                    try follow(target.url, wanted: wanted, agent: target.agent, events: target.events,
                               scriptPath: scriptPath)
                    if wanted, state == .agentNotInstalled { state = .on }
                } catch AgentHookSettings.Failure.notJSONObject {
                    IslandLog.sources.error("coding agents: \(target.agent.rawValue)'s hook settings are not a JSON object, left alone")
                    state = .settingsUnreadable
                }
            }
            if !wanted {
                try? FileManager.default.removeItem(at: AgentHookScript.installedURL)
            }
        } catch {
            IslandLog.sources.error("coding agents: could not update the hook: \(error.localizedDescription)")
            state = .failed
        }
        promptsState = state
        updateServer()
    }

    /// One agent's hook file brought in line with the switch, written only when it disagrees.
    private func follow(
        _ url: URL, wanted: Bool, agent: CodingAgent, events: [AgentHookSettings.Event], scriptPath: String
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? (try? Data(contentsOf: url)) : nil
        if wanted {
            guard !AgentHookSettings.contains(existing, scriptPath: scriptPath, events: events) else { return }
            let data = try AgentHookSettings.installing(
                into: existing, command: AgentHookScript.command(for: agent.rawValue),
                scriptPath: scriptPath, timeout: AgentHookScript.timeoutSeconds, events: events)
            try AgentHookSettings.write(data, to: url)
            IslandLog.sources.info("coding agents: hook added to \(agent.rawValue)'s settings")
        } else if AgentHookSettings.contains(existing, scriptPath: scriptPath, events: [.permissionRequest]),
                  let data = try AgentHookSettings.removing(from: existing, scriptPath: scriptPath) {
            try AgentHookSettings.write(data, to: url)
            IslandLog.sources.info("coding agents: hook removed from \(agent.rawValue)'s settings")
        }
    }

    /// Allow or deny the prompt the island is showing for this activity's session. The decision
    /// goes back on the connection that asked, and nowhere else.
    ///
    /// - Returns: whether there was a held prompt to answer — false when the terminal got there
    ///   first, which the caller treats the same way.
    @discardableResult
    public func answer(_ id: ActivityID, _ answer: CodingAgentAnswer) -> Bool {
        let sessionID = sessions.values.first(where: { Self.activityID(for: $0.record) == id })?.record.sessionID
            ?? codexSessions.first(where: { Self.codexSession($0.key, $0.value, prompt: nil).activityID == id })?.key
        guard let sessionID, let held = prompts.removeValue(forKey: sessionID), held.request.isOpen
        else { return false }
        held.request.answer(answer == .allow ? .allow : .deny)
        IslandLog.sources.info("coding agents: prompt \(answer == .allow ? "allowed" : "denied") from the island")
        return true
    }

    private func updateServer() {
        let wanted = isRunning && answersPrompts && promptsState == .on
        guard wanted != hookServer.isRunning else { return }
        if wanted {
            do {
                try hookServer.start()
            } catch {
                IslandLog.sources.error("coding agents: could not open the hook socket: \(String(describing: error))")
                promptsState = .failed
            }
        } else {
            hookServer.stop()
            for held in prompts.values { held.request.close() }
            prompts = [:]
        }
    }

    private func received(_ event: AgentHookEvent, request: AgentHookRequest?) {
        if event.agent == CodingAgent.codex.rawValue {
            receivedCodex(event, request: request)
            return
        }
        guard let request else { return }
        guard let sessionID = event.sessionID, answersPrompts else {
            request.close()
            return
        }
        prompts.removeValue(forKey: sessionID)?.request.close()
        let detail = (event.toolName == "Bash" ? event.command : nil) ?? event.summary ?? event.command
        prompts[sessionID] = HeldPrompt(
            request: request, prompt: CodingAgentPrompt(toolName: event.toolName, detail: detail))
        request.onPeerClosed = { [weak self, weak request] in
            guard let self, let request, self.prompts[sessionID]?.request === request else { return }
            self.prompts[sessionID] = nil
            self.refresh(sessionID: sessionID)
        }
        IslandLog.sources.info("coding agents: holding a permission prompt for the island")
        refresh(sessionID: sessionID)
    }

    /// Let go of a held prompt without answering it — the terminal's own prompt stands, or has
    /// already been answered.
    private func release(sessionID: String) {
        prompts.removeValue(forKey: sessionID)?.request.close()
    }

    /// Re-say what a waiting session's island says, now that a prompt has arrived or gone.
    private func refresh(sessionID: String) {
        if let codex = codexSessions[sessionID] {
            guard attention.showing(Self.codexKey(sessionID)) == .needsInput else { return }
            onActivity?(BuiltInActivity.codingAgent(
                Self.codexSession(sessionID, codex, prompt: prompts[sessionID]?.prompt), moment: .needsInput))
            return
        }
        guard let (name, tracked) = sessions.first(where: { $0.value.record.sessionID == sessionID }),
              attention.showing(name) == .needsInput
        else { return }
        onActivity?(BuiltInActivity.codingAgent(session(for: tracked), moment: .needsInput))
    }

    // MARK: - Codex, through its hooks

    private static func codexKey(_ sessionID: String) -> String { "codex:\(sessionID)" }

    private func isFrontmost(_ terminal: NSRunningApplication?) -> Bool {
        guard let terminal else { return false }
        return terminal.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func receivedCodex(_ event: AgentHookEvent, request: AgentHookRequest?) {
        guard answersPrompts, let sessionID = event.sessionID else {
            request?.close()
            return
        }
        if event.event == "SessionEnd" {
            request?.close()
            forgetCodex(sessionID)
            return
        }
        if codexSessions[sessionID] == nil {
            codexSessions[sessionID] = makeCodex(sessionID, cwd: event.cwd)
            // A baseline, as a Claude session's first reading is: Isleta launching mid-turn has not
            // just watched it finish.
            _ = attention.update(Self.codexKey(sessionID), status: .idle, isFrontmost: false)
        }
        let status: ClaudeSessionRecord.Status
        switch event.event {
        case "PermissionRequest":
            status = .waiting
        case "UserPromptSubmit", "PostToolUse":
            status = .busy
        case "Stop":
            status = .idle
        default:
            request?.close()
            return
        }
        // Whatever was held has been answered, whichever surface got there.
        if status != .waiting { release(sessionID: sessionID) }
        codexSessions[sessionID]?.status = status

        if let request {
            let terminal = codexSessions[sessionID]?.terminal
            if terminal == nil || isFrontmost(terminal) {
                // Codex's prompt waits on this hook: let go now, so it shows where the person is.
                request.close()
            } else {
                hold(request, for: sessionID, toolName: event.toolName,
                     detail: (event.toolName == "Bash" ? event.command : nil) ?? event.summary ?? event.command)
            }
        }
        applyCodex(sessionID)
    }

    private func hold(_ request: AgentHookRequest, for sessionID: String, toolName: String?, detail: String?) {
        prompts.removeValue(forKey: sessionID)?.request.close()
        prompts[sessionID] = HeldPrompt(request: request, prompt: CodingAgentPrompt(toolName: toolName, detail: detail))
        request.onPeerClosed = { [weak self, weak request] in
            guard let self, let request, self.prompts[sessionID]?.request === request else { return }
            self.prompts[sessionID] = nil
            self.refresh(sessionID: sessionID)
        }
        IslandLog.sources.info("coding agents: holding a permission prompt for the island")
    }

    /// A Codex session's terminal: Codex's hooks run under a shared process, so the hook's parent
    /// leads nowhere, and the session is found instead as the interactive `codex` running in the
    /// hook's folder. Once per session, on its first event.
    private func makeCodex(_ sessionID: String, cwd: String?) -> CodexTracked {
        let pid = cwd.flatMap(Self.codexProcess(in:))
        var exit: (any DispatchSourceProcess)?
        if let pid {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.forgetCodex(sessionID) }
            }
            source.resume()
            exit = source
        }
        return CodexTracked(
            status: .idle, cwd: cwd, terminal: pid.flatMap(ProcessAncestry.owningApplication(of:)), exit: exit)
    }

    private static func codexProcess(in cwd: String) -> pid_t? {
        let folder = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return ProcessAncestry.allProcesses().first { pid in
            guard let path = ProcessAncestry.executablePath(of: pid),
                  (path as NSString).lastPathComponent == "codex",
                  !path.contains("app-server"),
                  let directory = ProcessAncestry.workingDirectory(of: pid)
            else { return false }
            return URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == folder
        }
    }

    private func forgetCodex(_ sessionID: String) {
        guard let codex = codexSessions.removeValue(forKey: sessionID) else { return }
        release(sessionID: sessionID)
        codex.exit?.cancel()
        codex.grace?.cancel()
        if attention.update(Self.codexKey(sessionID), status: nil, isFrontmost: false).contains(.dismiss) {
            onDismiss?(Self.codexSession(sessionID, codex, prompt: nil).activityID)
        }
    }

    private func applyCodex(_ sessionID: String, cause: CodingAgentAttention.Cause = .stateChanged) {
        guard let codex = codexSessions[sessionID] else { return }
        let key = Self.codexKey(sessionID)
        let effects = attention.update(key, status: codex.status, isFrontmost: isFrontmost(codex.terminal), cause: cause)
        for effect in effects {
            switch effect {
            case .present(let moment):
                announcementCount += 1
                IslandLog.sources.info("coding agents: codex session \(moment == .needsInput ? "needs input" : "finished")")
                onActivity?(BuiltInActivity.codingAgent(
                    Self.codexSession(sessionID, codex, prompt: prompts[sessionID]?.prompt), moment: moment))
            case .dismiss:
                onDismiss?(Self.codexSession(sessionID, codex, prompt: nil).activityID)
            case .armGrace:
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.applyCodex(sessionID, cause: .graceElapsed) }
                }
                codexSessions[sessionID]?.grace?.cancel()
                codexSessions[sessionID]?.grace = work
                DispatchQueue.main.asyncAfter(deadline: .now() + CodingAgentAttention.grace, execute: work)
            }
        }
    }

    /// Codex only waits on a permission request, so a waiting Codex session is always asking one.
    private static func codexSession(_ sessionID: String, _ codex: CodexTracked, prompt: CodingAgentPrompt?) -> CodingAgentSession {
        CodingAgentSession(
            agent: .codex,
            sessionID: sessionID,
            name: codex.cwd.map { ($0 as NSString).lastPathComponent },
            terminalApplicationName: codex.terminal.flatMap(Self.applicationName),
            waitingFor: codex.status == .waiting ? .permission : nil,
            prompt: prompt
        )
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
            // Out of a wait means whatever the hook is holding was answered somewhere else.
            if tracked.record.status == .waiting, record.status != .waiting {
                release(sessionID: record.sessionID)
            }
            let reasonChanged = tracked.record.wait != record.wait
            tracked.record = record
            sessions[name] = tracked
            // A session can go from one reason to another without leaving `waiting` — a permission
            // prompt answered straight into a question — which the attention table rightly sees as
            // no change. The island's words are the reason, so they are refreshed in place.
            if reasonChanged, record.wait != nil, attention.showing(name) == .needsInput {
                onActivity?(BuiltInActivity.codingAgent(session(for: tracked), moment: .needsInput))
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
        release(sessionID: tracked.record.sessionID)
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
        for id in codexSessions.keys {
            // The person is at the terminal: Codex's own prompt can only appear once the hook lets go.
            if isFrontmost(codexSessions[id]?.terminal) { release(sessionID: id) }
            applyCodex(id, cause: .activated)
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
                onActivity?(BuiltInActivity.codingAgent(session(for: tracked), moment: moment))
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

    private func session(for tracked: Tracked) -> CodingAgentSession {
        let held = tracked.record.status == .waiting ? prompts[tracked.record.sessionID] : nil
        return CodingAgentSession(
            agent: .claudeCode,
            sessionID: tracked.record.sessionID,
            name: tracked.record.name,
            terminalApplicationName: tracked.terminal.flatMap(Self.applicationName),
            waitingFor: held != nil ? .permission : tracked.record.wait,
            prompt: held?.prompt
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

/// Where answering from the island stands, for the Settings row.
public enum AgentPromptsState: Equatable, Sendable {
    /// The switch is off, and the hook is not in the agent's settings.
    case off
    /// The hook is registered and the socket is open while the source runs.
    case on
    /// There is no `~/.claude` to register a hook in.
    case agentNotInstalled
    /// The agent's settings file is not JSON Isleta can read, so it was not touched.
    case settingsUnreadable
    /// Writing the script or the settings, or opening the socket, failed — the log says which.
    case failed
}
