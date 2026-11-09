import Foundation
import IslandActivities
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

    @Test("Codex gets every event its turn needs, matchers only where a tool is matched")
    func codexEvents() throws {
        let events = AgentHookSettings.codexEvents
        let written = try AgentHookSettings.installing(
            into: nil, command: "'\(script)' codex", scriptPath: script, timeout: 3600, events: events)
        let hooks = try #require(try json(written)["hooks"] as? [String: Any])
        for event in events {
            let groups = try #require(hooks[event.name] as? [[String: Any]], "\(event.name)")
            #expect(groups.count == 1)
            #expect((groups.first?["matcher"] != nil) == event.matchesTools, "\(event.name)")
            let timeout = (groups.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int
            // Only the permission request waits on a person.
            #expect(timeout == (event == .permissionRequest ? 3600 : AgentHookSettings.briefTimeout), "\(event.name)")
        }
        #expect(AgentHookSettings.contains(written, scriptPath: script, events: events))

        // An older install missing an event is not "installed", so the next apply completes it.
        let partial = try AgentHookSettings.installing(into: nil, command: command, scriptPath: script, timeout: 3600)
        #expect(!AgentHookSettings.contains(partial, scriptPath: script, events: events))

        // Removal takes ours out of every event, and leaves a file with nothing of ours in it.
        let removed = try AgentHookSettings.removing(from: written, scriptPath: script)
        #expect(try json(removed)["hooks"] == nil)
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
    {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","cwd":"/Users/someone/site",
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
        #expect(received?.cwd == "/Users/someone/site")
        let output = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == decision.line)
        // Never a rule change: the island allows this one call and nothing more.
        #expect((specific["decision"] as? [String: Any])?["updatedPermissions"] == nil)
    }

    /// Two questions, the first with whitespace the script collapses on the way to the island — so
    /// an answer keyed by the text Isleta was sent would miss the agent's own key.
    private let question = #"""
    {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[
       {"question":"Which number\ncounts?","header":"Perf metric","multiSelect":false,
        "options":[{"label":"Received","description":"Offers marked received"},{"label":"Printed","description":"Labels printed"}]},
       {"question":"Pick colors","header":"Colors","multiSelect":true,
        "options":[{"label":"Red","description":"r"},{"label":"Green","description":"g"},{"label":"Blue","description":"b"}]}]}}
    """#

    private func decision(_ run: Run) throws -> [String: Any] {
        let output = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        return try #require(specific["decision"] as? [String: Any])
    }

    @Test("a question reaches the island as its text and option labels, and its answers go back as the tool's own")
    func question() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }

        var received: AgentHookEvent?
        server.onEvent = { event, request in
            received = event
            request?.answer(.answers(["Printed", "Red, Blue"]))
        }
        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("s"), input: question)

        #expect(run.status == 0)
        let questions = try #require(received?.questions)
        #expect(questions.count == 2)
        #expect(questions[0] == AgentHookEvent.Question(
            question: "Which number counts?", header: "Perf metric", multiSelect: false, options: ["Received", "Printed"]))
        #expect(questions[1].multiSelect == true)
        #expect(questions[1].options == ["Red", "Green", "Blue"])

        let decision = try decision(run)
        #expect(decision["behavior"] as? String == "allow")
        let input = try #require(decision["updatedInput"] as? [String: Any])
        // Keyed by the agent's own text, newline and all, and the questions sent back untouched.
        #expect(input["answers"] as? [String: String] == ["Which number\ncounts?": "Printed", "Pick colors": "Red, Blue"])
        let original = try #require(input["questions"] as? [[String: Any]])
        #expect((original.first?["options"] as? [[String: Any]])?.first?["description"] as? String == "Offers marked received")
        #expect(decision["updatedPermissions"] == nil)
    }

    @Test("answers that do not cover every question send nothing, and the terminal keeps it",
          arguments: [[String](), ["Printed"], ["Printed", ""], ["Printed", "Red", "Blue"]])
    func partialAnswers(_ answers: [String]) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }
        server.onEvent = { _, request in request?.answer(.answers(answers)) }

        let run = try await runHook(in: folder, socket: folder.appendingPathComponent("s"), input: question)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
    }

    @Test("a question past the agent's own limits is sent without its questions")
    func tooManyOptions() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentHookServer(socketURL: folder.appendingPathComponent("s"))
        try server.start()
        defer { server.stop() }
        var received: AgentHookEvent?
        server.onEvent = { event, request in
            received = event
            request?.close()
        }
        let options = (1...5).map { #"{"label":"\#($0)"}"# }.joined(separator: ",")
        let input = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":["# + options + "]}]}}"
        _ = try await runHook(in: folder, socket: folder.appendingPathComponent("s"), input: input)
        #expect(received?.toolName == "AskUserQuestion")
        #expect(received?.questions == nil)
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

@Suite("Answering a coding agent's prompt")
@MainActor
struct CodingAgentAnswerTests {

    private func event(tool: String, questions: [AgentHookEvent.Question]? = nil) -> AgentHookEvent {
        AgentHookEvent(agent: "claudeCode", event: "PermissionRequest", sessionID: "s1", toolName: tool,
                       summary: "Remove the build folder", command: "rm -rf build", questions: questions)
    }

    private let colors = AgentHookEvent.Question(
        question: "Pick colors", header: "Colors", multiSelect: true, options: ["Red", "Green", "Blue"])
    private let fruit = AgentHookEvent.Question(question: "Pick a fruit", options: ["Apple", "Banana"])

    @Test("a permission is offered as one, with the command for a shell call")
    func permission() {
        let prompt = CodingAgentSource.prompt(for: event(tool: "Bash"))
        #expect(prompt == CodingAgentPrompt(toolName: "Bash", detail: "rm -rf build"))
        #expect(prompt?.isQuestion == false)
    }

    @Test("a question is offered as its options, and never as a permission")
    func question() throws {
        let prompt = try #require(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [fruit, colors])))
        #expect(prompt.questions == [
            ActivityQuestion(text: "Pick a fruit", options: ["Apple", "Banana"]),
            ActivityQuestion(text: "Pick colors", header: "Colors", allowsMultiple: true, options: ["Red", "Green", "Blue"]),
        ])
        // Nothing the island could answer is left to the terminal alone, not put up as Allow/Deny.
        #expect(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion")) == nil)
        #expect(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [])) == nil)
        let missing = AgentHookEvent.Question(question: "Q", options: ["A", nil])
        #expect(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [missing])) == nil)
        let twice = AgentHookEvent.Question(question: "Q", options: ["A", "A"])
        #expect(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [twice])) == nil)
    }

    @Test("choices go back one per question, a multi-select's in the asker's order")
    func choices() throws {
        let prompt = try #require(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [fruit, colors])))
        #expect(CodingAgentSource.decision(for: .choices([["Banana"], ["Blue", "Red"]]), to: prompt)
                == .answers(["Banana", "Red, Blue"]))
    }

    @Test("an answer that does not fit what was asked is no answer", arguments: [
        CodingAgentAnswer.allow, .deny,
        .choices([["Banana"]]),
        .choices([["Banana", "Apple"], ["Red"]]),
        .choices([["Banana"], []]),
        .choices([["Cherry"], ["Red"]]),
    ])
    func misfit(_ answer: CodingAgentAnswer) throws {
        let prompt = try #require(CodingAgentSource.prompt(for: event(tool: "AskUserQuestion", questions: [fruit, colors])))
        #expect(CodingAgentSource.decision(for: answer, to: prompt) == nil)
    }

    @Test("a session is named by its folder and the one it is in", arguments: [
        ("/Users/someone/Sites/itsworthmore-inventory", "Sites/itsworthmore-inventory"),
        ("/Users/someone/Sites/itsworthmore-inventory/", "Sites/itsworthmore-inventory"),
        ("/Users/someone/Projects", "~/Projects"),
        ("/Users/someone", "~"),
        ("/tmp", "tmp"),
    ])
    func folderLabel(_ cwd: String, _ label: String) {
        #expect(CodingAgentSource.folderLabel(for: cwd, home: "/Users/someone") == label)
    }

    @Test("a permission takes Allow or Deny and nothing else")
    func permissionAnswers() throws {
        let prompt = try #require(CodingAgentSource.prompt(for: event(tool: "Bash")))
        #expect(CodingAgentSource.decision(for: .allow, to: prompt) == .allow)
        #expect(CodingAgentSource.decision(for: .deny, to: prompt) == .deny)
        #expect(CodingAgentSource.decision(for: .choices([["Yes"]]), to: prompt) == nil)
    }
}
