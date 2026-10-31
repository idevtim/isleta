import Foundation

/// Adding Isleta's hook to a coding agent's hook settings — Claude Code's `~/.claude/settings.json`,
/// Codex's `~/.codex/hooks.json` — and taking exactly it away again.
///
/// Pure over `Data` so the whole matrix — no file, an empty file, a file full of somebody else's
/// hooks, a file that is not JSON — is testable against fixtures, and so the one function that
/// touches the disk (`write(_:to:)`) is small enough to read in full.
///
/// # The rules
///
/// - **Only the events the agent needs.** Claude Code: `PermissionRequest` alone — that a session
///   is waiting, moved on or finished is already in its session file, so the hook does the one
///   thing a file cannot: carry an answer back. Codex keeps no such file, so its turn comes
///   through hooks too (`codexEvents`). The same functions write `~/.codex/hooks.json`.
/// - **Ours is recognised by the script's path and nothing else**, whatever argument or quoting an
///   older build wrote the command with. Removal takes every handler whose command names
///   `AgentHookScript.installedURL` and leaves every other hook, matcher and key
///   alone; a matcher group left empty by that goes too, and so does an event left empty.
/// - **A file that is not a JSON object is refused**, never rewritten. The person's settings are
///   theirs, and "repaired" is not a thing Isleta gets to decide.
/// - **Idempotent.** Installing twice leaves one entry, so the switch can be re-applied on every
///   launch without the file growing.
///
/// Key order is not preserved — `JSONSerialization` does not keep it — but every key and value is.
public enum AgentHookSettings {

    public enum Failure: Error, Equatable {
        /// The file exists and is not a JSON object.
        case notJSONObject
    }

    /// One event an agent runs hooks on, and whether its handlers are grouped under a tool matcher.
    public struct Event: Equatable, Sendable {
        public let name: String
        /// True for the tool events. The others take no matcher, and Codex warns on one it cannot use.
        public let matchesTools: Bool

        public static let permissionRequest = Event(name: "PermissionRequest", matchesTools: true)
        public static let postToolUse = Event(name: "PostToolUse", matchesTools: true)
        public static let userPromptSubmit = Event(name: "UserPromptSubmit", matchesTools: false)
        public static let stop = Event(name: "Stop", matchesTools: false)
        public static let sessionStart = Event(name: "SessionStart", matchesTools: false)
        public static let sessionEnd = Event(name: "SessionEnd", matchesTools: false)
    }

    /// Claude Code: the permission request alone. Everything else is in its session file.
    public static let claudeCodeEvents: [Event] = [.permissionRequest]

    /// Codex keeps no state file, so its whole turn arrives through hooks
    /// (`docs/PLATFORM-CONSTRAINTS.md`): a session starting and ending, a turn starting, a tool
    /// having run — which is also a prompt answered — the permission request, and the turn ending.
    public static let codexEvents: [Event] = [
        .sessionStart, .userPromptSubmit, .permissionRequest, .postToolUse, .stop, .sessionEnd,
    ]

    /// Whether `data` carries a handler running the script at `scriptPath` on every one of `events`.
    public static func contains(_ data: Data?, scriptPath: String, events: [Event] = claudeCodeEvents) -> Bool {
        guard let data, let root = try? object(from: data),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return events.allSatisfy { event in
            ((hooks[event.name] as? [[String: Any]]) ?? []).contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { isOurs($0, scriptPath: scriptPath) } ?? false
            }
        }
    }

    /// `data` with Isleta's handler added once. `nil` data is a file that does not exist yet.
    ///
    /// - Parameters:
    ///   - command: the command line to register.
    ///   - scriptPath: what identifies a handler as Isleta's — the path inside `command`.
    ///
    /// - Parameters:
    ///   - timeout: for the permission request, which waits on the person. Every other event only
    ///     sends and exits, and gets `briefTimeout`.
    public static func installing(
        into data: Data?, command: String, scriptPath: String, timeout: Int,
        events: [Event] = claudeCodeEvents
    ) throws -> Data {
        var root = try data.map(object(from:)) ?? [:]
        // Removed first, so a stale entry from an older build — a different timeout, a different
        // agent argument — is replaced rather than joined.
        root = removing(scriptPath, from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event.name] as? [[String: Any]] ?? []
            let handler: [String: Any] = [
                "type": "command", "command": command,
                "timeout": event == .permissionRequest ? timeout : briefTimeout,
            ]
            var group: [String: Any] = ["hooks": [handler]]
            if event.matchesTools { group["matcher"] = "*" }
            groups.append(group)
            hooks[event.name] = groups
        }
        root["hooks"] = hooks
        return try serialized(root)
    }

    /// Seconds an event that only reports is given. The script connects, writes a line and exits in
    /// milliseconds; this bounds a Mac under load, not the ordinary case.
    static let briefTimeout = 10

    /// `data` with every handler that runs Isleta's script taken out. `nil` stays `nil`.
    public static func removing(from data: Data?, scriptPath: String) throws -> Data? {
        guard let data else { return nil }
        let root = try object(from: data)
        return try serialized(removing(scriptPath, from: root))
    }

    /// Write atomically, keeping the previous file beside it as `settings.json.isleta-backup`.
    public static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("isleta-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: -

    private static func object(from data: Data) throws -> [String: Any] {
        // An empty file is the one non-JSON shape that means "nothing here yet" rather than
        // "something here Isleta does not understand".
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSONObject
        }
        return root
    }

    private static func serialized(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Ours out of **every** event, whichever an older build registered.
    private static func removing(_ scriptPath: String, from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (name, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { !isOurs($0, scriptPath: scriptPath) }
                guard remaining.count != handlers.count else { return group }
                if remaining.isEmpty { return nil }
                var group = group
                group["hooks"] = remaining
                return group
            }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        var root = root
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    private static func isOurs(_ handler: [String: Any], scriptPath: String) -> Bool {
        (handler["command"] as? String)?.contains(scriptPath) == true
    }
}
