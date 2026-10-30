import Foundation
import IslandActivities
import Testing

@testable import IslandSources

@Suite("Coding agent session file")
struct ClaudeSessionRecordTests {

    /// The shape Claude Code 2.1.314 writes, trimmed of the fields this feature does not read.
    private func record(_ fields: String) -> ClaudeSessionRecord? {
        ClaudeSessionRecord.decode(Data("""
        {"pid":81581,"sessionId":"668ed576","cwd":"/Users/someone/Sites/isleta",\
        "version":"2.1.314","kind":"interactive","entrypoint":"cli","name":"isleta-6a",\
        "updatedAt":1793395764741,"statusUpdatedAt":1793395764741\(fields)}
        """.utf8))
    }

    @Test("the three statuses decode, and a word a later release adds is not mistaken for one")
    func statuses() {
        #expect(record(#","status":"busy""#)?.status == .busy)
        // A Bash tool running. Working, for every purpose this feature has.
        #expect(record(#","status":"shell""#)?.status == .busy)
        #expect(record(#","status":"waiting","waitingFor":"permission prompt""#)?.status == .waiting)
        #expect(record(#","status":"idle""#)?.status == .idle)
        #expect(record(#","status":"compacting""#)?.status == .other)
        #expect(record("")?.status == .other)
    }

    @Test("the fields the island uses come through")
    func fields() throws {
        let decoded = try #require(record(#","status":"idle""#))
        #expect(decoded.pid == 81581)
        #expect(decoded.sessionID == "668ed576")
        #expect(decoded.name == "isleta-6a")
        #expect(decoded.isPersonAtPrompt)
    }

    @Test("a file that is not a session is refused rather than half-read")
    func malformed() {
        #expect(ClaudeSessionRecord.decode(Data("{".utf8)) == nil)
        #expect(ClaudeSessionRecord.decode(Data(#"{"sessionId":"x","status":"idle"}"#.utf8)) == nil)
    }

    @Test("helper sessions and non-interactive runs have nobody at the prompt")
    func helpers() {
        #expect(!ClaudeSessionRecord(pid: 1, sessionID: "s", status: .idle, kind: "print").isPersonAtPrompt)
        #expect(!ClaudeSessionRecord(
            pid: 1, sessionID: "s", status: .idle, cwd: "/private/var/folders/xy/T/hook"
        ).isPersonAtPrompt)
        #expect(ClaudeSessionRecord(pid: 1, sessionID: "s", status: .idle, cwd: "/Users/someone").isPersonAtPrompt)
    }
}

@Suite("Coding agent attention")
struct CodingAgentAttentionTests {

    private func tracking(_ status: ClaudeSessionRecord.Status) -> CodingAgentAttention {
        var attention = CodingAgentAttention()
        _ = attention.update("s", status: status, isFrontmost: false)
        return attention
    }

    @Test("the first sighting is a baseline, whatever the session is doing")
    func baseline() {
        for status in [ClaudeSessionRecord.Status.busy, .waiting, .idle] {
            var attention = CodingAgentAttention()
            #expect(attention.update("s", status: status, isFrontmost: false).isEmpty)
        }
    }

    @Test("a turn ending while the person is elsewhere is announced, and is not while they are watching")
    func finished() {
        var away = tracking(.busy)
        #expect(away.update("s", status: .idle, isFrontmost: false) == [.present(.finished)])

        var watching = tracking(.busy)
        #expect(watching.update("s", status: .idle, isFrontmost: true).isEmpty)
    }

    @Test("a waiting session is shown, retracted when answered, and not shown twice")
    func waiting() {
        var attention = tracking(.busy)
        #expect(attention.update("s", status: .waiting, isFrontmost: false) == [.present(.needsInput)])
        // The same state re-read — an FSEvents rescan, an unrelated app switch — says nothing new.
        #expect(attention.update("s", status: .waiting, isFrontmost: false).isEmpty)
        #expect(attention.update("s", status: .waiting, isFrontmost: false, cause: .activated).isEmpty)
        // Answered in the terminal: the session is busy again and the island lets go.
        #expect(attention.update("s", status: .busy, isFrontmost: false) == [.dismiss])
    }

    @Test("a question that goes away without the turn ending is retracted, not reported as finished")
    func dismissedPrompt() {
        var attention = tracking(.busy)
        _ = attention.update("s", status: .waiting, isFrontmost: false)
        #expect(attention.update("s", status: .idle, isFrontmost: false) == [.dismiss])
    }

    /// The case the first hardware run found: the session in one VS Code window, the person in
    /// another. Isleta can see the app and not the window, so the app being frontmost buys grace
    /// rather than silence.
    @Test("a session waiting in the frontmost app is shown once its grace runs out")
    func graceInTheFrontmostApp() {
        var attention = tracking(.busy)
        #expect(attention.update("s", status: .waiting, isFrontmost: true) == [.armGrace])
        // Re-reads while the grace is running arm nothing more.
        #expect(attention.update("s", status: .waiting, isFrontmost: true).isEmpty)
        #expect(attention.update("s", status: .waiting, isFrontmost: true, cause: .graceElapsed)
                == [.present(.needsInput)])
        // Shown despite the frontmost app, so a rescan in that app must not take it straight back.
        #expect(attention.update("s", status: .waiting, isFrontmost: true).isEmpty)
        #expect(attention.showing("s") == .needsInput)
    }

    @Test("a prompt answered inside its grace is never shown")
    func answeredInGrace() {
        var attention = tracking(.busy)
        _ = attention.update("s", status: .waiting, isFrontmost: true)
        #expect(attention.update("s", status: .busy, isFrontmost: true).isEmpty)
        // The grace firing late finds a session that is working, and says nothing.
        #expect(attention.update("s", status: .busy, isFrontmost: true, cause: .graceElapsed).isEmpty)
    }

    @Test("going to the app takes the island away and starts the grace again")
    func activated() {
        var attention = tracking(.busy)
        _ = attention.update("s", status: .waiting, isFrontmost: false)
        #expect(attention.update("s", status: .waiting, isFrontmost: true, cause: .activated)
                == [.dismiss, .armGrace])
        #expect(attention.update("s", status: .waiting, isFrontmost: false, cause: .activated)
                == [.present(.needsInput)])
    }

    @Test("a finished moment is left to its own dwell, and is retracted when the next turn starts")
    func finishedDwell() {
        var attention = tracking(.busy)
        _ = attention.update("s", status: .idle, isFrontmost: false)
        #expect(attention.update("s", status: .idle, isFrontmost: false).isEmpty)
        #expect(attention.update("s", status: .busy, isFrontmost: false) == [.dismiss])
    }

    @Test("going to the app a turn finished in takes the finished moment away")
    func finishedThenActivated() {
        var attention = tracking(.busy)
        _ = attention.update("s", status: .idle, isFrontmost: false)
        #expect(attention.update("s", status: .idle, isFrontmost: true, cause: .activated) == [.dismiss])
    }

    @Test("a session that goes away takes its island with it, and one with nothing showing says nothing")
    func vanished() {
        var showing = tracking(.busy)
        _ = showing.update("s", status: .waiting, isFrontmost: false)
        #expect(showing.update("s", status: nil, isFrontmost: false) == [.dismiss])
        #expect(showing.trackedKeys.isEmpty)

        var quiet = tracking(.idle)
        #expect(quiet.update("s", status: nil, isFrontmost: false).isEmpty)
    }

    @Test("two sessions are tracked apart")
    func twoSessions() {
        var attention = CodingAgentAttention()
        _ = attention.update("a", status: .busy, isFrontmost: false)
        _ = attention.update("b", status: .busy, isFrontmost: false)
        #expect(attention.update("a", status: .waiting, isFrontmost: false) == [.present(.needsInput)])
        #expect(attention.showing("b") == nil)
        #expect(attention.update("b", status: .idle, isFrontmost: false) == [.present(.finished)])
        #expect(attention.showing("a") == .needsInput)
    }
}
