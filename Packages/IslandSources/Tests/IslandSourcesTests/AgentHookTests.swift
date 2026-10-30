import Foundation
import Testing

@testable import IslandSources

@Suite("Agent hook settings")
struct AgentHookSettingsTests {

    private let script = "/Users/someone/Library/Application Support/Isleta/agent-hook.pl"
    private var command: String { "'\(script)' claudeCode" }

    private func json(_ data: Data?) throws -> [String: Any] {
        try #require(data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }

    private func permissionGroups(_ data: Data?) throws -> [[String: Any]] {
        let root = try json(data)
        return ((root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
    }

    @Test("a Mac with no settings file gets one holding only Isleta's hook")
    func noFile() throws {
        let written = try AgentHookSettings.installing(into: nil, command: command, scriptPath: script, timeout: 3600)
        let groups = try permissionGroups(written)
        #expect(groups.count == 1)
        let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["command"] as? String == command)
        #expect(handler["timeout"] as? Int == 3600)
        #expect(AgentHookSettings.contains(written, scriptPath: script))
    }

    /// The shape a real settings file has: a status line, permissions, and other hooks — including
    /// someone else's on the same event.
    private let crowded = Data(#"""
    {
      "permissions": {"allow": ["Bash(git status)"], "defaultMode": "default"},
      "statusLine": {"type": "command", "command": "~/bin/status"},
      "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/audit"}]}],
        "PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/notify"}]}]
      }
    }
    """#.utf8)

    @Test("installing beside other hooks leaves every one of them, and everything else, alone")
    func crowdedFile() throws {
        let written = try AgentHookSettings.installing(into: crowded, command: command, scriptPath: script, timeout: 3600)
        let root = try json(written)
        #expect((root["statusLine"] as? [String: Any])?["command"] as? String == "~/bin/status")
        #expect(((root["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash(git status)"])
        #expect(((root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count == 1)
        let groups = try permissionGroups(written)
        #expect(groups.count == 2)
        #expect(groups.first?["matcher"] as? String == "Bash")
    }

    @Test("installing twice leaves one entry, and replaces an older build's")
    func idempotent() throws {
        let stale = try AgentHookSettings.installing(
            into: crowded, command: "'\(script)' claude", scriptPath: script, timeout: 60)
        let again = try AgentHookSettings.installing(into: stale, command: command, scriptPath: script, timeout: 3600)
        let twice = try AgentHookSettings.installing(into: again, command: command, scriptPath: script, timeout: 3600)
        let ours = try permissionGroups(twice).filter {
            (($0["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains(script) == true
        }
        #expect(ours.count == 1)
        #expect(((ours.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) == 3600)
    }

    @Test("removing takes exactly Isleta's hook away, and tidies what it emptied")
    func removal() throws {
        let installed = try AgentHookSettings.installing(into: crowded, command: command, scriptPath: script, timeout: 3600)
        let removed = try AgentHookSettings.removing(from: installed, scriptPath: script)
        #expect(!AgentHookSettings.contains(removed, scriptPath: script))
        let groups = try permissionGroups(removed)
        #expect(groups.count == 1)
        #expect(groups.first?["matcher"] as? String == "Bash")

        // A file that held only ours goes back to holding no hooks at all, rather than an empty
        // `PermissionRequest: []` the person never wrote.
        let alone = try AgentHookSettings.installing(into: Data("{}".utf8), command: command, scriptPath: script, timeout: 3600)
        let emptied = try json(try AgentHookSettings.removing(from: alone, scriptPath: script))
        #expect(emptied["hooks"] == nil)
    }

    @Test("a handler sharing a group with Isleta's survives its removal")
    func sharedGroup() throws {
        let shared = Data(#"""
        {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [
            {"type": "command", "command": "'\#(script)' claudeCode"},
            {"type": "command", "command": "~/bin/notify"}
        ]}]}}
        """#.utf8)
        let removed = try AgentHookSettings.removing(from: shared, scriptPath: script)
        let handlers = try #require(try permissionGroups(removed).first?["hooks"] as? [[String: Any]])
        #expect(handlers.map { $0["command"] as? String } == ["~/bin/notify"])
    }

    @Test("a file that is not a JSON object is refused, never rewritten", arguments: [
        "{\"hooks\": ", "[1, 2, 3]", "not json at all",
    ])
    func refusesNonJSON(_ contents: String) {
        #expect(throws: AgentHookSettings.Failure.notJSONObject) {
            try AgentHookSettings.installing(into: Data(contents.utf8), command: command, scriptPath: script, timeout: 3600)
        }
        #expect(throws: AgentHookSettings.Failure.notJSONObject) {
            try AgentHookSettings.removing(from: Data(contents.utf8), scriptPath: script)
        }
    }

    @Test("an empty file is nothing yet, not something broken")
    func emptyFile() throws {
        let written = try AgentHookSettings.installing(into: Data("\n".utf8), command: command, scriptPath: script, timeout: 3600)
        #expect(AgentHookSettings.contains(written, scriptPath: script))
    }

    @Test("removing from no file leaves no file")
    func removeNothing() throws {
        #expect(try AgentHookSettings.removing(from: nil, scriptPath: script) == nil)
    }
}

/// The script and the server against each other — the real Perl, the real socket.
@Suite("Agent hook round trip", .serialized)
@MainActor
struct AgentHookRoundTripTests {

    /// Short on purpose: a Unix socket path is capped at 104 bytes, and the test's temporary folder
    /// already spends half of that.
    private func makeFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ih-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(AgentHookScript.source.utf8).write(to: folder.appendingPathComponent("hook.pl"))
        return folder
    }

    private struct Run {
        let stdout: String
        let status: Int32
    }

    private func runHook(in folder: URL, socket: URL, input: String) async throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [folder.appendingPathComponent("hook.pl").path, "claudeCode"]
        process.environment = ["ISLETA_AGENT_SOCKET": socket.path, "HOME": folder.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        return Run(stdout: String(decoding: output, as: UTF8.self), status: process.terminationStatus)
    }

    private let permission = #"""
    {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash",
     "tool_input":{"command":"rm -rf build","description":"Remove the build folder"}}
    """#

    @Test("allow and deny come back as the decision the agent reads", arguments: [AgentHookDecision.allow, .deny])
    func answered(_ decision: AgentHookDecision) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }

        var received: AgentHookEvent?
        server.onEvent = { event, request in
            received = event
            request?.answer(decision)
        }
        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("s"), input: permission)

        #expect(run.status == 0)
        #expect(received?.sessionID == "s1")
        #expect(received?.toolName == "Bash")
        #expect(received?.summary == "Remove the build folder")
        #expect(received?.command == "rm -rf build")
        let output = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == decision.rawValue)
        // Never a rule change: the island allows this one call and nothing more.
        #expect((specific["decision"] as? [String: Any])?["updatedPermissions"] == nil)
    }

    @Test("closing without an answer leaves the agent's own prompt standing")
    func closed() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }
        server.onEvent = { _, request in request?.close() }

        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("s"), input: permission)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
    }

    @Test("with Isleta not listening, the hook is silent and succeeds")
    func notRunning() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("absent"), input: permission)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
    }

    @Test("an event that is not a permission request is delivered and not held")
    func notHeld() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }
        var held: Bool?
        server.onEvent = { _, request in held = request != nil }

        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("s"),
                                    input: #"{"hook_event_name":"Stop","session_id":"s1"}"#)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(held == false)
    }

    @Test("the socket is the user's alone")
    func permissions() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("s")
        let server = AgentHookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0)
    }

    @Test("a socket path too long for the kernel is refused, not truncated")
    func tooLong() {
        let server = AgentHookServer(socketURL: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120)))
        #expect(throws: AgentHookServer.Failure.pathTooLong) { try server.start() }
    }
}
