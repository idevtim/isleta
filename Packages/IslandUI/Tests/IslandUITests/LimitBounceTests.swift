
import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The island leaning at the end of a range, and the hit region that has to follow it.
///
/// **Two presses, not one, since 2.3.0.** A level *arriving* at its end arms the rebound and moves
/// nothing; the press after it — the one asking for more of a level with none left to give — is what
/// leans the island. Everything below that used to reach the lean through `setActivity` alone now
/// goes through `reach(_:)` then `push(_:)`, which is the two presses spelled out.
///
/// The lean is decoration; the hit region is not. The window server derives the panel's event shape
/// from the alpha of what Isleta draws, so a translated island is opaque several points beyond the
/// shape `islandPath` accepts — drawn pixels we refuse, which is the one direction
/// `IslandHitTestView` is written around. Most of this suite is about that.
@Suite("Limit bounce")
@MainActor
struct LimitBounceTests {

    private static let cutout = CGSize(width: 185, height: 32)

    private static let screen = IslandScreen(
        id: 1, name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(
            kind: .hardware,
            rect: CGRect(x: 771.5, y: 1085, width: cutout.width, height: cutout.height)
        )
    )

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: Dictionary(
                uniqueKeysWithValues: IslandForm.allCases.map {
                    ($0, IslandLayout.metrics(for: $0, on: Self.screen))
                }
            ),
            notchKind: .hardware,
            cutoutSize: Self.cutout
        )
    }

    private func stage(_ limit: ActivityLimit?, level: Double) -> ActivityStage {
        ActivityStage(
            primary: BuiltInActivity.systemHUD(.volume, level: level, limit: limit),
            primaryFlank: .leading
        )
    }

    /// The press that runs a level to its end: a reading that lands on `limit`, which arms and
    /// moves nothing.
    private func reach(
        _ limit: ActivityLimit,
        on model: IslandScreenModel,
        change: ActivityChange = .presented("hud"),
        reduceMotion: Bool = false
    ) {
        model.setActivity(
            stage(limit, level: limit == .maximum ? 1 : 0),
            change: change,
            reduceMotion: reduceMotion
        )
    }

    /// The press after it: no reading at all, because nothing changed. This is the one that leans.
    private func push(_ limit: ActivityLimit, on model: IslandScreenModel, reduceMotion: Bool = false) {
        model.pushedAtLimit(limit, reduceMotion: reduceMotion)
    }

    /// Both, which is what a user does: run the volume to the bottom, then press again.
    private func reachAndPush(
        _ limit: ActivityLimit,
        on model: IslandScreenModel,
        reduceMotion: Bool = false
    ) {
        reach(limit, on: model, reduceMotion: reduceMotion)
        push(limit, on: model, reduceMotion: reduceMotion)
    }

    /// Which way is which. `ActivityLimit` says which end of the range; a level is drawn filling
    /// left to right, so the top of it is to the right — and that mapping lives in exactly one place.
    @Test("the top of a range leans right and the bottom leans left")
    func directionFollowsTheLimit() {
        let toTheTop = model()
        reachAndPush(.maximum, on: toTheTop)
        #expect(toTheTop.limitBounce == IslandLayout.limitBounceDistance)

        let toTheBottom = model()
        reachAndPush(.minimum, on: toTheBottom)
        #expect(toTheBottom.limitBounce == -IslandLayout.limitBounceDistance)
    }

    @Test("a level anywhere in the middle of its range does not lean")
    func noLimitNoLean() {
        let model = model()
        model.setActivity(stage(nil, level: 0.5), change: .presented("hud"), reduceMotion: false)
        #expect(model.limitBounce == 0)
    }

    // MARK: - The two presses

    /// **The whole of what 2.3.0 changed.** A level running out is the level answering the key —
    /// the bar is already drawn full or empty by the time the island could move — so the press that
    /// lands on an end moves nothing at all, however it reached the stage.
    @Test("reaching the end of a range does not lean the island", arguments: [
        ActivityChange.presented("hud"), .swapped(from: "music", to: "hud"), .contentChanged("hud"),
        .companionChanged("other"), .none, .dismissed("hud"),
    ])
    func arrivingAtALimitDoesNotLean(change: ActivityChange) {
        let model = model()
        reach(.maximum, on: model, change: change)
        #expect(model.limitBounce == 0)
    }

    /// The press after it, which is the one the user means: there is no more.
    @Test("the press after it leans", arguments: [ActivityLimit.maximum, .minimum])
    func theSecondPressLeans(limit: ActivityLimit) {
        let model = model()
        reach(limit, on: model)
        #expect(model.limitBounce == 0)
        push(limit, on: model)
        #expect(model.limitBounce != 0)
    }

    /// **And it keeps leaning.** Holding the key repeats about ten times a second, and every repeat
    /// after the first is a push at an end already reached — see `bounce(toward:)`, which strikes
    /// from zero so each one is its own beat.
    @Test("every press after that leans again")
    func furtherPressesKeepLeaning() {
        let model = model()
        reachAndPush(.maximum, on: model)
        #expect(model.limitBounce != 0)
        push(.maximum, on: model)
        #expect(model.limitBounce != 0)
    }

    /// **The race the source used to document, settled.** A press that lands on an end produces a
    /// reading *and* a key event, in either order; whichever arrives first can only arm, so the
    /// press cannot lean the island by winning.
    @Test("a push that arrives before the reading arms rather than leans")
    func aPushBeforeTheReadingArms() {
        let model = model()
        push(.minimum, on: model)
        #expect(model.limitBounce == 0)
        reach(.minimum, on: model)
        #expect(model.limitBounce == 0)
        push(.minimum, on: model)
        #expect(model.limitBounce != 0)
    }

    /// The two ends are armed separately: running a level to the top and immediately pushing at the
    /// bottom is a level being turned around, not a level with nothing left.
    @Test("being at one end does not arm the other")
    func endsArmSeparately() {
        let model = model()
        reach(.maximum, on: model)
        push(.minimum, on: model)
        #expect(model.limitBounce == 0)
    }

    /// A level that leaves its end disarms, so the next arrival there is a first press again.
    @Test("a level moving off its end disarms")
    func leavingAnEndDisarms() {
        let model = model()
        reach(.minimum, on: model)
        model.setActivity(stage(nil, level: 0.5), change: .contentChanged("hud"), reduceMotion: false)
        push(.minimum, on: model)
        #expect(model.limitBounce == 0)
    }

    /// So does the HUD leaving the stage. The island is not showing a level any more, so there is
    /// nothing it can be at the end of.
    @Test("the stage emptying disarms")
    func theStageEmptyingDisarms() {
        let model = model()
        reach(.maximum, on: model)
        model.setActivity(nil, change: .dismissed("hud"), reduceMotion: false)
        push(.maximum, on: model)
        #expect(model.limitBounce == 0)
    }

    /// **Reduce Motion drops it outright rather than substituting a crossfade** (§6.3). Everything
    /// else in this codebase substitutes because the movement is *carrying* something and the
    /// information has to land either way; nothing is carried here. The bar is already drawn full or
    /// empty, and this is the flourish on top of it.
    @Test("Reduce Motion leaves the island where it is")
    func reduceMotionSkipsIt() {
        let model = model()
        reachAndPush(.maximum, on: model, reduceMotion: true)
        #expect(model.limitBounce == 0)
    }

    /// It comes home on its own, on the same token that took it out.
    @Test("the lean returns to zero without anything else happening")
    func leanComesHome() async throws {
        let model = model()
        reachAndPush(.maximum, on: model)
        #expect(model.limitBounce != 0)
        try await Task.sleep(for: Motion.nudgeDuration + .milliseconds(150))
        #expect(model.limitBounce == 0)
    }

    /// The one gesture that produces two leans: a level run to the bottom and straight back up.
    /// The second must replace the first outright — including its scheduled return, or the first
    /// return lands mid-second-lean and pulls the island home while it is still going out.
    @Test("a second limit reached replaces the first, return and all")
    func secondLeanReplacesTheFirst() async throws {
        let model = model()
        reachAndPush(.minimum, on: model)
        #expect(model.limitBounce < 0)

        reach(.maximum, on: model, change: .contentChanged("hud"))
        push(.maximum, on: model)
        #expect(model.limitBounce > 0)

        // Past when the *first* return would have fired, and well short of the second's.
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.limitBounce > 0, "the first lean's return must not have pulled this one home")
    }

    /// **What a person actually sees move: the bar, and nothing else.** The island's edge is black on
    /// black; the bar is not. It **stretches** rather than travelling, because sliding a bar takes
    /// its far end with it and reads as the bar being shoved rather than running out of room — and
    /// it does so at *both* ends, growing toward whichever one is being pushed.
    @Test("the bar stretches toward the end being pushed, and nothing else moves")
    func theBarAnswersBothEnds() {
        let model = model()

        reachAndPush(.maximum, on: model)
        // It grows to the right, from a fixed left end — and the travel is the magnitude, with the
        // end that stays put said separately so no spring can interpolate its way across the bar.
        #expect(model.bounceStretch(for: .trailing) == model.limitLean)
        #expect(model.bounceStretch(for: .trailing) > 0)
        #expect(model.bounceStretchAnchor == .leading)
        // The sliver holding the glyph and the word holds still, both ways.
        #expect(model.bounceStretch(for: .leading) == 0)
        #expect(model.bounceOffset(for: .leading) == 0)
        #expect(model.bounceOffset(for: .trailing) == 0)

        reach(.minimum, on: model, change: .contentChanged("hud"))
        push(.minimum, on: model)
        // The same bar and the same travel, growing the other way from a fixed right end. The
        // *anchor* is what changed, and only the anchor.
        #expect(model.bounceStretch(for: .trailing) == model.limitLean)
        #expect(model.bounceStretch(for: .trailing) > 0)
        #expect(model.bounceStretchAnchor == .trailing)
        #expect(model.bounceStretch(for: .leading) == 0)
        #expect(model.bounceOffset(for: .leading) == 0)
    }

    /// The two are exclusive by construction: a slot never both moves and grows, which would double
    /// the travel on the one thing anybody is looking at.
    @Test("nothing both stretches and moves", arguments: [ActivityLimit.maximum, .minimum])
    func stretchAndOffsetAreExclusive(limit: ActivityLimit) {
        let model = model()
        reachAndPush(limit, on: model)
        for slot in ActivitySlot.allCases {
            #expect(model.bounceOffset(for: slot) == 0 || model.bounceStretch(for: slot) == 0)
        }
    }

    /// A resting island moves nothing, which is what keeps every frame that is not a rebound exactly
    /// the frame it was before this existed.
    @Test("nothing moves when nothing is rebounding")
    func nothingMovesAtRest() {
        let model = model()
        for slot in ActivitySlot.allCases {
            #expect(model.bounceOffset(for: slot) == 0)
            #expect(model.bounceStretch(for: slot) == 0)
        }
    }

    /// **The artifact this suite exists to keep out**, said at the model's end of it: the travel is
    /// a magnitude and the side is a separate fact, so there is nothing here that can change sides
    /// by passing through zero.
    ///
    /// **This is half the guarantee, and the smaller half.** The model only ever holds the two
    /// endpoints of an animation — the values in between are SwiftUI's, and a check on this side
    /// cannot see them. That is why the version of this test that watched a signed `limitBounce`
    /// for a sign flip passed while hardware went on showing one. The frames are pinned in
    /// `IslandShapeTests.leanMovesOneEdge`, which walks the geometry through the negative values an
    /// underdamped return actually passes through.
    @Test("the lean is a magnitude and its side never changes while it settles")
    func returnKeepsItsSide() async throws {
        let model = model()
        reachAndPush(.maximum, on: model)
        #expect(model.limitLean > 0)
        #expect(model.limitLeansTrailing)
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(20))
            #expect(model.limitLean >= 0)
            #expect(model.limitLeansTrailing, "the lean changed sides while coming home")
        }
        #expect(model.limitLean == 0)
    }

    // MARK: - The hit region

    /// **The failure this exists to prevent.** The lean moves the drawn island and therefore the
    /// panel's opaque pixels; the region we accept clicks in has to contain the whole travel, or
    /// clicks on lit island are dropped on the floor rather than falling through to the app below.
    @Test("the hit region contains the island at either end of its travel")
    func hitRegionContainsTheTravel() {
        let model = model()
        model.setActivity(stage(.maximum, level: 1), change: .presented("hud"), reduceMotion: false)

        let drawn = model.metrics.bodySize.width
        let accepted = model.hitRegionMetrics.bodySize.width
        // Symmetric, so one answer covers a lean in either direction.
        #expect(accepted == drawn + 2 * IslandLayout.limitBounceDistance)
        // Which is to say: the island displaced by the full travel is still inside it.
        #expect(drawn / 2 + IslandLayout.limitBounceDistance <= accepted / 2)
    }

    /// The height is untouched. The lean is sideways, and a region grown downward would be a claim
    /// about a direction the island never moves in.
    @Test("the allowance is width and nothing else")
    func allowanceIsWidthOnly() {
        let model = model()
        model.setActivity(stage(.minimum, level: 0), change: .presented("hud"), reduceMotion: false)
        #expect(model.hitRegionMetrics.bodySize.height == model.metrics.bodySize.height)
        #expect(model.hitRegionMetrics.bottomCornerRadius == model.metrics.bottomCornerRadius)
        #expect(model.hitRegionMetrics.topFlareRadius == model.metrics.topFlareRadius)
    }

    /// **Gated on the activity, not on `limitBounce` being non-zero**, and the difference is a
    /// timing bug. The region is set once, when a change settles; the lean is still travelling at
    /// that point, and a region computed from a value that has already sprung back to zero would
    /// tighten under a moving island.
    @Test("the allowance outlives the movement")
    func allowanceIsNotGatedOnTheLiveValue() {
        let model = model()
        model.setActivity(stage(.maximum, level: 1), change: .presented("hud"), reduceMotion: true)
        // Reduce Motion means the island never actually moved.
        #expect(model.limitBounce == 0)
        // The allowance is there regardless, which is the cheap and safe direction: a superset over
        // transparent pixels is one the window server never routes to us in the first place.
        #expect(model.hitRegionMetrics.bodySize.width > model.metrics.bodySize.width)
    }

    /// Every island that is not showing a level at its end accepts clicks in exactly its own shape.
    /// An allowance left on permanently would be a second, wider definition of the island for no
    /// reason.
    @Test("an ordinary island's hit region is its own shape")
    func ordinaryIslandIsUnchanged() {
        let model = model()
        #expect(model.hitRegionMetrics == model.metrics)

        model.setActivity(
            ActivityStage(primary: BuiltInActivity.nowPlaying(title: "All Blues"), primaryFlank: .leading),
            change: .presented("music"),
            reduceMotion: false
        )
        #expect(model.hitRegionMetrics == model.metrics)
    }

    /// The travel is bounded at both ends, and both bounds have been hit.
    ///
    /// **Too large** and the stretch reads as the island sitting crooked on its notch rather than
    /// springing — it is measured against the *wide* flank because only a HUD rebounds and a HUD is
    /// always wide-flanked. **Too small** and it is not there at all: at 8pt it was reported from
    /// hardware as never happening, because a black edge moving against a black menu bar moves
    /// nothing anybody can see. Clearing the peek's own sideways growth is the floor — a movement
    /// smaller than the one the island makes just because a pointer arrived is not a movement.
    @Test("the travel is big enough to see and small enough to read as a spring")
    func travelIsBoundedAtBothEnds() {
        #expect(IslandLayout.limitBounceDistance < IslandLayout.wideFlankedFlankWidth / 4)
        #expect(IslandLayout.limitBounceDistance > IslandLayout.peekWidthGrowth)
    }
}
