import Foundation

/// A command-line coding agent running in one of the user's terminals.
///
/// A closed list for the reason `ActivityKind` is one: each agent is read through a different file
/// on disk with a different shape, and a case is where that route is named. The raw value is the
/// prefix of every activity id the source mints, so it is persisted in nothing and matched on by
/// nothing outside this package.
public enum CodingAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// The program's own name. **Not localized** — it is a name another company chose, which
    /// `docs/LOCALIZATION.md` puts out of scope, and "Claude Code" in a German island is still
    /// "Claude Code".
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The agent's own mark, drawn where the island would otherwise draw a glyph.
    public var mark: ActivityMark {
        switch self {
        case .claudeCode: .claude
        case .codex: .openAI
        }
    }
}

/// What a session is doing that is worth the island's attention.
///
/// Two cases and no third for "working", and the absence is the design: an agent busy on a task is
/// a condition the user started and is not waiting on, and a condition that sat on the stage for as
/// long as it held would take the leading sliver from Now Playing for the length of every task —
/// the mistake the glance made through 2.0. The island speaks when the session stops and needs the
/// person, and goes when it does not.
public enum CodingAgentMoment: Equatable, Sendable {

    /// The session is stopped on a question — a permission prompt, a dialog, a reply it asked for.
    case needsInput

    /// The turn ended and nothing is pending. Momentary, like a finished timer.
    case finished
}

/// What a waiting session is asking the person for — the line the open island leads with.
public enum CodingAgentWait: Equatable, Sendable {
    /// A permission prompt: allow or deny a tool call.
    case permission
    /// Anything else it stopped for — a question, a dialog, a reply.
    case input
}

/// A permission prompt the island can answer itself, because the agent's hook is holding it open
/// (`AgentHookServer` in IslandSources). What it shows is **shown and never logged**: a command
/// line or a file path is the user's own text.
public struct CodingAgentPrompt: Equatable, Sendable {
    /// The agent's name for the tool — "Bash", "Write", "WebFetch". Not localized: the agent's word.
    public let toolName: String?
    /// The command for a shell call, else the agent's one line for the call — a file, a URL, a
    /// pattern, or its own description of it.
    public let detail: String?

    public init(toolName: String?, detail: String?) {
        self.toolName = toolName
        self.detail = detail
    }
}

/// How the person answered a permission prompt from the island. Allowing allows this one call and
/// changes no rule — the agent's settings are the place for that.
public enum CodingAgentAnswer: Equatable, Sendable {
    case allow
    case deny
}

/// One session, as the island needs it: which agent, what it is called, where it lives.
public struct CodingAgentSession: Equatable, Sendable {

    public let agent: CodingAgent

    /// The agent's own id for the session — opaque, and what keeps two sessions in one folder apart.
    public let sessionID: String

    /// The agent's name for the session, when it has one ("isleta-6a"), else the folder's.
    /// Shown on screen and **never logged**: it is derived from a path the user chose.
    public let name: String?

    /// The application that owns the terminal the session runs in — "Terminal", "iTerm2", "Ghostty"
    /// — or nil when the parent chain reaches launchd without passing one. Its icon is what the
    /// island draws, since it is the place a click takes the user.
    public let terminalApplicationName: String?

    /// What it is waiting for, when it is. Nil for a finished session.
    public let waitingFor: CodingAgentWait?

    /// The prompt the island can answer, when the hook is holding one for this session.
    public let prompt: CodingAgentPrompt?

    public init(
        agent: CodingAgent, sessionID: String, name: String?, terminalApplicationName: String?,
        waitingFor: CodingAgentWait? = nil, prompt: CodingAgentPrompt? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.name = name
        self.terminalApplicationName = terminalApplicationName
        self.waitingFor = waitingFor
        self.prompt = prompt
    }

    /// One island per session, and the same id for both moments of it — so a session that goes
    /// from needing input to finished is an *update* that crossfades, not a second island queued
    /// behind the first.
    public var activityID: ActivityID {
        ActivityID("builtin.codingAgent.\(agent.rawValue).\(sessionID)")
    }
}
