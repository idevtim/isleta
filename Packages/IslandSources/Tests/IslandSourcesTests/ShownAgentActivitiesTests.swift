import IslandActivities
import Testing

@testable import IslandSources

@Suite("Coding agent activities on the island")
struct ShownAgentActivitiesTests {

    private let first = ActivityID("builtin.codingAgent.claudeCode.aaa")
    private let second = ActivityID("builtin.codingAgent.claudeCode.bbb")

    /// The 2.9.0 orphan: a file's session id changed while its "needs your input" was up, and the
    /// dismissal was computed from the new id. Whatever the session is called now, the id that
    /// went up is the one that comes down.
    @Test("an activity comes down by the id it went up with")
    func takeDownByShownID() {
        var shown = ShownAgentActivities()
        shown.show(first, for: "24288.json")
        #expect(shown.isShowing("24288.json"))
        #expect(shown.takeDown("24288.json") == first)
        #expect(!shown.isShowing("24288.json"))
        #expect(shown.takeDown("24288.json") == nil)
    }

    @Test("showing a new id for the same session takes the old one down")
    func replacingAnIDReturnsTheStaleOne() {
        var shown = ShownAgentActivities()
        shown.show(first, for: "24288.json")
        #expect(shown.show(second, for: "24288.json") == first)
        #expect(shown.show(second, for: "24288.json") == nil)
        #expect(shown.all == [second])
    }

    @Test("two files resuming one conversation: the first to go leaves the other's activity up")
    func sharedIDSurvivesUntilTheLastKeyGoes() {
        var shown = ShownAgentActivities()
        shown.show(first, for: "7680.json")
        shown.show(first, for: "25865.json")
        #expect(shown.takeDown("7680.json") == nil)
        #expect(shown.isShown(first))
        #expect(shown.takeDown("25865.json") == first)
    }

    @Test("an activity the island retired is not re-said, and the next moment shows again")
    func retiredIsNotResaid() {
        var shown = ShownAgentActivities()
        shown.show(first, for: "24288.json")
        shown.retired(first)
        #expect(!shown.isShowing("24288.json"))
        // Nothing left to dismiss when the session later moves on or ends.
        #expect(shown.takeDown("24288.json") == nil)
        shown.show(first, for: "24288.json")
        #expect(shown.isShowing("24288.json"))
    }

    @Test("a click finds the session that put the activity up, whatever its id is now")
    func keysShowing() {
        var shown = ShownAgentActivities()
        shown.show(first, for: "24288.json")
        shown.show(second, for: "codex:bbb")
        #expect(shown.keys(showing: first) == ["24288.json"])
        #expect(shown.keys(showing: ActivityID("builtin.codingAgent.claudeCode.zzz")).isEmpty)
    }
}
