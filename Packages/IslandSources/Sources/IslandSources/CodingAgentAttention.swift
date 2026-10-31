import Foundation
import IslandActivities

/// One running Claude Code session, as `~/.claude/sessions/<pid>.json` describes it.
///
/// Claude Code writes the file for every session it runs, rewrites it when the session's state
/// changes, and **leaves it behind when the process dies** — so a record is a claim about a pid, and
/// the source checks the pid is alive before believing it. Measured on Claude Code 2.1.314; see
/// `docs/PLATFORM-CONSTRAINTS.md` for the fields and what moves them.
///
/// Decoded leniently, every field but the three this feature cannot work without optional: the
/// file is another program's private format, and a field it drops in a later release should cost
/// that field, not the session.
struct ClaudeSessionRecord: Equatable, Sendable, Decodable {

    /// What the session says it is doing. `other` keeps a status a later release adds from reading
    /// as one of these three — an unknown word is not evidence of anything.
    enum Status: Equatable, Sendable {
        case busy
        case waiting
        case idle
        case other
    }

    let pid: Int32
    let sessionID: String
    let status: Status
    let name: String?
    let cwd: String?

    /// Why a `waiting` session is waiting, in the file's own words: `permission prompt`,
    /// `input needed`, and others a later release may add (`docs/PLATFORM-CONSTRAINTS.md`).
    let waitingFor: String?

    /// `interactive` for a session in a terminal. A `claude -p` run, a hook's helper session and an
    /// SDK process are something else, and none of them has a person at a prompt to wait on.
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case pid
        case sessionID = "sessionId"
        case status
        case name
        case cwd
        case kind
        case waitingFor
    }

    init(
        pid: Int32, sessionID: String, status: Status, name: String? = nil, cwd: String? = nil,
        kind: String? = "interactive", waitingFor: String? = nil
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.status = status
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.waitingFor = waitingFor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        let raw = try container.decodeIfPresent(String.self, forKey: .status)
        // `shell` is what the file says while a Bash tool runs — seen live, and not in the list read
        // out of the binary — and it is the session working, so it is `busy` here. Missing it made
        // every turn whose last step was a command end in `shell → idle`, which is not a turn
        // finishing to anything that only knows `busy`.
        status = switch raw {
        case "busy", "shell": .busy
        case "waiting": .waiting
        case "idle": .idle
        default: .other
        }
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        waitingFor = try? container.decodeIfPresent(String.self, forKey: .waitingFor)
    }

    /// What the person is being asked for. A permission prompt is the one reason worth naming;
    /// every other — a question, a dialog, a reason a later release adds — is "your input".
    var wait: CodingAgentWait? {
        guard status == .waiting else { return nil }
        return waitingFor == "permission prompt" ? .permission : .input
    }

    static func decode(_ data: Data) -> ClaudeSessionRecord? {
        try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Whether this is a session a person is sitting at.
    ///
    /// Hooks and plugins start short-lived helper sessions with a working directory in the system's
    /// temporary folder, and they are not anything the user is running.
    var isPersonAtPrompt: Bool {
        guard kind == nil || kind == "interactive" else { return false }
        guard let cwd else { return true }
        return !(cwd.hasPrefix("/private/var/folders/") || cwd.hasPrefix("/var/folders/"))
    }
}

/// What the island should do about one session, given what it is doing and whether its owner is
/// already looking at it.
///
/// Pure, so the whole table is testable without a session, a terminal or a file. The source feeds
/// it three kinds of event through the one entry point — the session's state moved, an app came
/// forward, or a waiting session's grace ran out — because each is the same question asked again.
///
/// # The rule
///
/// The island speaks only when the session has stopped on the person **and the person is not
/// already looking at it** — `CONTRIBUTING.md`'s test, applied per session rather than per feature.
///
/// "Looking at it" can only be asked of the **app**: which window or tab holds the session would
/// take Accessibility or Screen Recording, and a session in one VS Code window while the person
/// works in another is the ordinary case, not the edge one. So a frontmost terminal buys a session
/// `grace` rather than silence. A prompt somebody is looking at is answered within it; one still
/// waiting when it runs out is shown anyway, because it is in a window they are not reading.
///
/// - A waiting session is shown at once when its app is not frontmost, and after `grace` when it is.
/// - A turn ending is shown only when its app is not frontmost. It is over and nothing is blocked,
///   so it is not worth announcing over the top of the app it ended in.
/// - Anything shown leaves when the session moves on, or when its app is *brought* forward — the
///   person going to it. A waiting session brought forward starts its grace again.
///
/// The first sighting of a session is a **baseline** and announces nothing, `PowerSource`'s rule:
/// a session that was idle when Isleta launched did not just finish.
struct CodingAgentAttention {

    /// How long a session waiting in the frontmost app goes unannounced. Six seconds is when Claude
    /// Code raises its own `permission_prompt` notification for an unanswered prompt, measured
    /// (`docs/PLATFORM-CONSTRAINTS.md`) — the agent's own answer to how long is too long.
    static let grace: TimeInterval = 6

    enum Cause: Equatable {
        /// The session's file changed, or was read again.
        case stateChanged
        /// An app came forward — the session's own, or another.
        case activated
        /// The grace armed for this session ran out.
        case graceElapsed
    }

    enum Effect: Equatable {
        case present(CodingAgentMoment)
        case dismiss
        /// Ask again with `.graceElapsed` after `grace`.
        case armGrace
    }

    private struct Entry {
        var status: ClaudeSessionRecord.Status
        var showing: CodingAgentMoment?
        var graceArmed = false
    }

    private var entries: [String: Entry] = [:]

    /// The sessions being tracked, for the source to re-ask on an app switch.
    var trackedKeys: [String] { Array(entries.keys) }

    /// What is on screen for `key`, for the source's bookkeeping and the tests.
    func showing(_ key: String) -> CodingAgentMoment? { entries[key]?.showing }

    /// - Parameters:
    ///   - status: what the session says now, or nil when it has gone — its file was removed or its
    ///     process exited.
    ///   - isFrontmost: whether the app that owns the session is the frontmost app.
    mutating func update(
        _ key: String,
        status: ClaudeSessionRecord.Status?,
        isFrontmost: Bool,
        cause: Cause = .stateChanged
    ) -> [Effect] {
        guard let status else {
            let was = entries.removeValue(forKey: key)
            return was?.showing == nil ? [] : [.dismiss]
        }
        guard var entry = entries[key] else {
            entries[key] = Entry(status: status, showing: nil)
            return []
        }
        let previous = entry.status
        entry.status = status
        if cause == .graceElapsed { entry.graceArmed = false }
        defer { entries[key] = entry }

        var effects: [Effect] = []
        // The person went to the app: whatever the island was saying about it, they can see it.
        if cause == .activated, isFrontmost, entry.showing != nil {
            entry.showing = nil
            effects.append(.dismiss)
        }

        switch status {
        case .waiting:
            guard entry.showing != .needsInput else { break }
            if !isFrontmost || cause == .graceElapsed {
                entry.showing = .needsInput
                effects.append(.present(.needsInput))
            } else if !entry.graceArmed {
                entry.graceArmed = true
                effects.append(.armGrace)
            }
        case .idle where previous == .busy:
            if isFrontmost {
                if entry.showing != nil {
                    entry.showing = nil
                    effects.append(.dismiss)
                }
            } else {
                entry.showing = .finished
                effects.append(.present(.finished))
            }
        case .idle, .busy, .other:
            // Busy again means somebody answered; idle from waiting means the question went away
            // without a turn finishing — a prompt dismissed, a dialog escaped. Neither is news.
            // A finished moment is left to its own dwell unless the session has started again.
            guard let showing = entry.showing else { break }
            if showing == .finished && status != .busy { break }
            entry.showing = nil
            effects.append(.dismiss)
        }
        return effects
    }
}
