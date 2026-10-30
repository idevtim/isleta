import Foundation

/// Adding Isleta's hook to Claude Code's `~/.claude/settings.json`, and taking exactly it away again.
///
/// Pure over `Data` so the whole matrix — no file, an empty file, a file full of somebody else's
/// hooks, a file that is not JSON — is testable against fixtures, and so the one function that
/// touches the disk (`write(_:to:)`) is small enough to read in full.
///
/// # The rules
///
/// - **Only `PermissionRequest`.** Everything else this feature needs — that a session is waiting,
///   that it moved on, that a turn finished — Claude Code already writes to its session file
///   (`CodingAgentSource`), so the hook does the one thing a file cannot: carry an answer back.
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

    static let event = "PermissionRequest"

    /// Whether `data` already carries a handler running the script at `scriptPath`.
    public static func contains(_ data: Data?, scriptPath: String) -> Bool {
        guard let data, let root = try? object(from: data),
              let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]]
        else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { isOurs($0, scriptPath: scriptPath) } ?? false
        }
    }

    /// `data` with Isleta's handler added once. `nil` data is a file that does not exist yet.
    ///
    /// - Parameters:
    ///   - command: the command line to register.
    ///   - scriptPath: what identifies a handler as Isleta's — the path inside `command`.
    public static func installing(into data: Data?, command: String, scriptPath: String, timeout: Int) throws -> Data {
        var root = try data.map(object(from:)) ?? [:]
        // Removed first, so a stale entry from an older build — a different timeout, a different
        // agent argument — is replaced rather than joined.
        root = removing(scriptPath, from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": command, "timeout": timeout]],
        ])
        hooks[event] = groups
        root["hooks"] = hooks
        return try serialized(root)
    }

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

    private static func removing(_ scriptPath: String, from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return root }
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let remaining = handlers.filter { !isOurs($0, scriptPath: scriptPath) }
            guard remaining.count != handlers.count else { return group }
            if remaining.isEmpty { return nil }
            var group = group
            group["hooks"] = remaining
            return group
        }
        hooks[event] = kept.isEmpty ? nil : kept
        var root = root
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    private static func isOurs(_ handler: [String: Any], scriptPath: String) -> Bool {
        (handler["command"] as? String)?.contains(scriptPath) == true
    }
}
