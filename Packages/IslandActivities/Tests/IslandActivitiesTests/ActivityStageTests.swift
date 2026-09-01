import Foundation
import Testing

@testable import IslandActivities

/// The pair: who owns which sliver, and who is not allowed on one at all.
///
/// Every test here is synchronous and clock-free, which is the reason this logic lives in a pure
/// value type. The failures this guards against — a companion stealing a flank the primary needed,
/// an island narrowing while something still has content — are invisible on screen until they are
/// on hardware, and trivially visible here.
@Suite("Activity stage")
struct ActivityStageTests {

    /// An activity with something in both slivers. Built here rather than on `TestActivity` so the
    /// existing helper's defaults keep meaning what the other suites assume they mean.
    private func flanked(
        _ id: ActivityID,
        kind: ActivityKind = .nowPlaying,
        priority: ActivityPriority = .ambient,
        expiry: ActivityExpiry = .never,
        leading: String? = "L",
        trailing: String? = "T"
    ) -> TestActivity {
        var activity = TestActivity(id, priority: priority, expiry: expiry)
        activity.kind = kind
        activity.presentations = ActivityPresentations(
            leading: leading.map { ActivityContent(title: $0) } ?? .empty,
            trailing: trailing.map { ActivityContent(title: $0) } ?? .empty,
            compact: ActivityContent(title: id.rawValue),
            expanded: ActivityContent(title: id.rawValue)
        )
        return activity
    }

    private func stack(_ activities: [any IslandActivity], at now: Date = Date()) -> ActivityStack {
        var stack = ActivityStack()
        for activity in activities { stack.insert(activity, at: now) }
        return stack
    }

    // MARK: - The unpaired case is the old behavior

    @Test("an empty stack has no stage")
    func emptyStackHasNoStage() {
        #expect(ActivityStack().stage == nil)
    }

    /// The state users spend the most time in. A pair that quietly narrowed the single-activity
    /// island to one sliver would be a regression in the common case, not an edge case.
    @Test("a lone activity owns both flanks, exactly as before the pair existed")
    func loneActivityKeepsBothFlanks() throws {
        let stage = try #require(stack([flanked("music")]).stage)

        #expect(stage.isPaired == false)
        #expect(stage.companion == nil)
        #expect(stage.content(on: .leading).title == "L")
        #expect(stage.content(on: .trailing).title == "T")
        #expect(stage.activity(on: .leading).id == "music")
        #expect(stage.activity(on: .trailing).id == "music")
    }

    // MARK: - Pairing

    @Test("two shareable activities of different kinds pair, primary on its own affinity flank")
    func twoShareableActivitiesPair() throws {
        let stage = try #require(
            stack([
                flanked("music", kind: .nowPlaying),
                flanked("shelf", kind: .shelf, priority: .standard),
            ]).stage
        )

        // `.shelf` is `.standard` and `.nowPlaying` is `.ambient`, so the shelf is the primary.
        #expect(stage.primary.id == "shelf")
        #expect(stage.companion?.id == "music")
        #expect(stage.primaryFlank == ActivityKind.shelf.flankAffinity)
        #expect(stage.companionFlank == stage.primaryFlank.opposite)
    }

    /// Each half draws the content its own kind wrote for that sliver — not the primary's pair of
    /// them with one swapped out.
    @Test("each half of a pair draws its own content for the flank it holds")
    func eachHalfDrawsItsOwnContent() throws {
        let stage = try #require(
            stack([
                flanked("primary", kind: .shelf, priority: .standard, leading: "PL", trailing: "PT"),
                flanked("companion", kind: .nowPlaying, leading: "CL", trailing: "CT"),
            ]).stage
        )

        #expect(stage.content(on: stage.primaryFlank).title == "PL")
        #expect(stage.content(on: stage.companionFlank).title == "CT")
    }

    /// The property the whole affinity table exists for: the side each kind sits on does not depend
    /// on which of the two happens to own the body. Asserted on `ActivityStage` directly because no
    /// built-in kind prefers `.trailing` yet — the timer is the first, and this is the rule it will
    /// arrive into.
    @Test("a primary that prefers the trailing flank leaves the leading one to its companion")
    func trailingPrimaryLeavesLeadingToCompanion() {
        let stage = ActivityStage(
            primary: flanked("timer", leading: "TL", trailing: "4:20"),
            companion: flanked("music", leading: "note", trailing: "bar"),
            primaryFlank: .trailing
        )

        #expect(stage.companionFlank == .leading)
        #expect(stage.content(on: .trailing).title == "4:20")
        #expect(stage.content(on: .leading).title == "note")
    }

    @Test("the two flanks are each other's opposite, and nothing else is")
    func flanksAreOpposites() {
        #expect(ActivityFlank.leading.opposite == .trailing)
        #expect(ActivityFlank.trailing.opposite == .leading)
        for flank in ActivityFlank.allCases { #expect(flank.opposite.opposite == flank) }
    }

    // MARK: - Who may not share

    /// A HUD's glyph and its level are the two flanks. Handing one away leaves a speaker icon next
    /// to nothing — and a momentary interruption has no business being ambient furniture.
    @Test("an interrupting activity neither takes a companion nor becomes one")
    func interruptingNeverPairs() throws {
        let asPrimary = try #require(
            stack([
                flanked("hud", kind: .systemHUD, priority: .interrupting),
                flanked("music", kind: .nowPlaying),
            ]).stage
        )
        #expect(asPrimary.primary.id == "hud")
        #expect(asPrimary.companion == nil)

        // And the other way round: an interrupting activity below the primary is not eligible
        // either. Ranked below by giving it an older arrival than the ambient primary cannot be
        // done — interrupting always sorts first — so this asserts the predicate directly.
        #expect(ActivityStack.maySharePair(flanked("hud", priority: .interrupting)) == false)
    }

    /// Something with a deadline is asking to be read, and a 40pt sliver is not where anything is
    /// read. This is the rule that keeps notifications off the flanks.
    @Test("an activity that expires never shares the island")
    func expiringNeverPairs() throws {
        let stage = try #require(
            stack([
                flanked("music", kind: .nowPlaying),
                flanked("note", kind: .calendarAlert, priority: .prominent, expiry: .after(.seconds(5))),
            ]).stage
        )

        #expect(stage.primary.id == "note")
        #expect(stage.companion == nil)
        #expect(ActivityStack.maySharePair(flanked("note", expiry: .after(.seconds(5)))) == false)
        #expect(ActivityStack.maySharePair(flanked("note", expiry: .at(Date()))) == false)
        #expect(ActivityStack.maySharePair(flanked("music")))
    }

    @Test("two activities of the same kind do not pair")
    func sameKindDoesNotPair() throws {
        let stage = try #require(
            stack([
                flanked("a", kind: .shelf, priority: .standard),
                flanked("b", kind: .shelf, priority: .standard),
            ]).stage
        )
        #expect(stage.companion == nil)
    }

    /// A companion with nothing to put in the sliver it would be given is not a companion, and the
    /// search continues rather than stopping — otherwise one silent candidate hides every eligible
    /// one behind it.
    @Test("a candidate with no content for the companion flank is skipped, not fatal")
    func emptyCompanionFlankIsSkipped() throws {
        let stage = try #require(
            stack([
                flanked("primary", kind: .shelf, priority: .standard),
                flanked("silent", kind: .calendarAlert, trailing: nil),
                flanked("music", kind: .nowPlaying),
            ]).stage
        )

        #expect(stage.primary.id == "primary")
        #expect(stage.companion?.id == "music")
    }

    // MARK: - The union

    /// Asked of the primary alone — which is what IslandUI does today — this island narrows back to
    /// the bare cutout while the companion still has something to say, and the companion is then
    /// drawn into a sliver that no longer exists.
    @Test("flank content is the union of the pair, not the primary's alone")
    func flankContentIsTheUnion() throws {
        let stage = try #require(
            stack([
                flanked("primary", kind: .shelf, priority: .standard, leading: nil, trailing: nil),
                flanked("music", kind: .nowPlaying),
            ]).stage
        )

        #expect(stage.companion?.id == "music")
        #expect(stage.primary.presentations.leading.isEmpty)
        #expect(stage.primary.presentations.trailing.isEmpty)
        #expect(stage.hasFlankContent)
    }

    @Test("a stage with nothing in either sliver reports no flank content")
    func emptyFlanksReportNothing() throws {
        let stage = try #require(stack([flanked("quiet", leading: nil, trailing: nil)]).stage)
        #expect(stage.hasFlankContent == false)
    }

    // MARK: - Ordering

    /// The companion is whatever the order puts next, so a pin that moves the primary moves the
    /// companion with it. Nothing here is special-cased for the pin; it falls out of walking
    /// `entries` in presented order.
    @Test("pinning swaps which half of a pair is primary")
    func pinSwapsThePair() throws {
        let now = Date()
        var stack = self.stack([
            flanked("music", kind: .nowPlaying),
            flanked("shelf", kind: .shelf, priority: .standard),
        ], at: now)

        #expect(stack.stage?.primary.id == "shelf")
        #expect(stack.stage?.companion?.id == "music")

        stack.pin("music", at: now)

        #expect(stack.stage?.primary.id == "music")
        #expect(stack.stage?.companion?.id == "shelf")
    }

    // MARK: - What a flank change reports

    /// The guard for the trap `ActivityChange` documents. A companion arriving must not report
    /// `.swapped` or `.contentChanged` — those fire `Motion.expand`, morphing the whole island for
    /// a change confined to one 40pt sliver.
    @Test("a companion arriving is a flank change, never a body change")
    func companionArrivingIsAFlankChange() {
        let now = Date()
        var stack = ActivityStack()
        stack.insert(flanked("shelf", kind: .shelf, priority: .standard), at: now)

        let change = stack.insert(flanked("music", kind: .nowPlaying), at: now)

        #expect(change == .companionChanged("music"))
        #expect(stack.stage?.companion?.id == "music")
    }

    @Test("a companion leaving reports the flank emptying")
    func companionLeavingReportsNil() {
        let now = Date()
        var stack = self.stack([
            flanked("shelf", kind: .shelf, priority: .standard),
            flanked("music", kind: .nowPlaying),
        ], at: now)

        #expect(stack.remove("music") == .companionChanged(nil))
        #expect(stack.stage?.companion == nil)
    }

    @Test("a companion's content moving on is a flank change")
    func companionContentChangeIsAFlankChange() {
        let now = Date()
        var stack = self.stack([
            flanked("shelf", kind: .shelf, priority: .standard),
            flanked("music", kind: .nowPlaying, trailing: "first"),
        ], at: now)

        let change = stack.insert(flanked("music", kind: .nowPlaying, trailing: "second"), at: now)

        #expect(change == .companionChanged("music"))
    }

    /// The rule that lets `ActivityChange` stay one value instead of a pair of them: a body change
    /// already redraws the whole island, companion included, so there is nothing left for the flank
    /// case to say.
    @Test("a body change wins over a simultaneous companion change")
    func bodyChangeWinsOverCompanionChange() {
        let now = Date()
        var stack = self.stack([
            flanked("shelf", kind: .shelf, priority: .standard),
            flanked("music", kind: .nowPlaying),
        ], at: now)

        // A HUD is interrupting, so it takes the body *and* — being ineligible to share — clears
        // the companion in the same mutation. Exactly one change is reported, and it is the body's.
        let change = stack.insert(
            flanked("hud", kind: .systemHUD, priority: .interrupting, expiry: .after(.seconds(2))),
            at: now
        )

        #expect(change == .swapped(from: "shelf", to: "hud"))
        #expect(stack.stage?.companion == nil)
    }

    /// A body that holds still while nothing else moves either is still `.none`. The flank case must
    /// not fire on every unrelated mutation, or the island crossfades a sliver on each volume tick.
    @Test("a stack that did not move reports nothing")
    func unchangedStackReportsNone() {
        let now = Date()
        var stack = self.stack([flanked("music", kind: .nowPlaying)], at: now)
        #expect(stack.insert(flanked("music", kind: .nowPlaying), at: now) == .none)
    }
}
