import CoreGraphics
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

@Suite("Presentation")
@MainActor
struct PresentationTests {

    private func makeModel() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(bodySize: CGSize(width: 185, height: 32), topCornerRadius: 0, bottomCornerRadius: 8),
                .peek: IslandShapeMetrics(bodySize: CGSize(width: 197, height: 40), topCornerRadius: 0, bottomCornerRadius: 8),
                .flankedRest: IslandShapeMetrics(bodySize: CGSize(width: 265, height: 32), topCornerRadius: 0, bottomCornerRadius: 8),
                .flankedPeek: IslandShapeMetrics(bodySize: CGSize(width: 277, height: 40), topCornerRadius: 0, bottomCornerRadius: 8),
                .expanded: IslandShapeMetrics(bodySize: CGSize(width: 380, height: 140), topCornerRadius: 0, bottomCornerRadius: 22),
            ],
            notchKind: .hardware
        )
    }

    /// Reduce motion is used throughout so transitions settle immediately; the animation curve is
    /// not what these tests are about.
    private func settle(_ body: (@escaping @MainActor () -> Void) -> Void) async {
        await withCheckedContinuation { continuation in
            body { continuation.resume() }
        }
    }

    @Test("hover grows to peek and back")
    func hover() async {
        let model = makeModel()
        #expect(model.presentation == .rest)

        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .peek)

        await settle { model.setHovering(false, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .rest)
    }

    @Test("clicking toggles expansion")
    func click() async {
        let model = makeModel()
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        await settle { model.toggleExpanded(reduceMotion: true, completion: $0) }
        #expect(model.presentation == .expanded)
        #expect(model.metrics.bodySize == CGSize(width: 380, height: 140))

        await settle { model.toggleExpanded(reduceMotion: true, completion: $0) }
        // The pointer never left, so closing lands on peek rather than dropping straight to rest.
        #expect(model.presentation == .peek)
    }

    /// The reason presentation is derived rather than stored. An open island must not shrink
    /// because the pointer wandered off, and must not grow when it comes back.
    @Test("hover does not disturb an expanded island")
    func hoverWhileExpanded() async {
        let model = makeModel()
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .expanded)

        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .expanded)

        await settle { model.setHovering(false, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .expanded)
    }

    /// The hover that happened while the island was open still has to be remembered, or closing
    /// jumps to rest under a pointer that is sitting right on the island — which then immediately
    /// re-triggers hover and produces a visible stutter.
    @Test("a hover recorded while expanded decides where a collapse lands")
    func hoverIsRememberedThroughExpansion() async {
        let model = makeModel()
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        await settle { model.setExpanded(false, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .peek)

        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        await settle { model.setHovering(false, reduceMotion: true, completion: $0) }
        await settle { model.setExpanded(false, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .rest)
    }

    /// The completion tightens the hit region back to the exact shape. If it were skipped when
    /// nothing changed, a redundant event would leave the region permanently widened.
    @Test("the completion fires even when nothing changes")
    func completionAlwaysFires() async {
        let model = makeModel()
        await settle { model.setHovering(false, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .rest)

        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        // Hover changing without moving the presentation still has to call back.
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.isHovering)
        #expect(model.presentation == .expanded)
    }

    @Test("metrics follow the form")
    func metricsFollowPresentation() async {
        let model = makeModel()
        #expect(model.metrics == model.metricsByForm[.rest])
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.metrics == model.metricsByForm[.peek])
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(model.metrics == model.metricsByForm[.expanded])
    }

    /// A model handed an incomplete table must degrade to the unflanked shape at the same
    /// presentation, not to `.rest` — dropping to rest would snap an open island shut mid-morph.
    @Test("a missing flanked entry falls back to the unflanked shape at the same presentation")
    func missingFlankedEntryFallsBack() {
        let model = makeModel()
        model.metricsByForm[.flankedRest] = nil
        model.setActivity(
            ActivityPresentations(leading: ActivityContent(symbol: "music.note")),
            change: .presented("a"),
            reduceMotion: true
        )
        #expect(model.form == .flankedRest)
        #expect(model.metrics == model.metricsByForm[.rest])
    }

    /// Which spring is used follows where the island ends up, not which input changed.
    @Test("growth and shrinkage are classified by destination")
    func growthDirection() {
        #expect(IslandScreenModel.isGrowing(from: .rest, to: .peek))
        #expect(IslandScreenModel.isGrowing(from: .peek, to: .expanded))
        #expect(IslandScreenModel.isGrowing(from: .rest, to: .expanded))
        #expect(!IslandScreenModel.isGrowing(from: .expanded, to: .peek))
        #expect(!IslandScreenModel.isGrowing(from: .peek, to: .rest))
        #expect(!IslandScreenModel.isGrowing(from: .expanded, to: .rest))
    }

    @Test("every presentation resolves from the two inputs")
    func resolution() {
        #expect(IslandPresentation.resolve(isHovering: false, isExpanded: false) == .rest)
        #expect(IslandPresentation.resolve(isHovering: true, isExpanded: false) == .peek)
        #expect(IslandPresentation.resolve(isHovering: false, isExpanded: true) == .expanded)
        #expect(IslandPresentation.resolve(isHovering: true, isExpanded: true) == .expanded)
    }

    // MARK: - The screen locking

    /// Both inputs, not just expansion. Clearing only `isExpanded` would leave the island peeked
    /// under a pointer that the lock shield has taken the events for, and a peek faded out by the
    /// window server is the same defect one size smaller.
    @Test("locking puts the island back in the notch")
    func collapseIntoNotchClearsBothInputs() async {
        let model = makeModel()
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .expanded)

        model.collapseIntoNotch()

        #expect(model.presentation == .rest)
        #expect(!model.isHovering)
        #expect(!model.isExpanded)
        #expect(model.metrics == model.metricsByForm[.rest])
    }

    /// The whole point of the method. `setExpanded(false, reduceMotion: true)` would also finish
    /// promptly, but through an animation — and the lock fade begins as the notification is posted,
    /// so anything still traveling is captured part-way and faded out at that size. This has to be
    /// finished by the time it returns, and the completion has to have fired, or `AppDelegate`
    /// leaves the hit region widened for the length of a spring that is not running.
    @Test("the collapse and its completion are synchronous")
    func collapseIntoNotchIsSynchronous() async {
        let model = makeModel()
        await settle { model.setExpanded(true, reduceMotion: false, completion: $0) }

        var completed = false
        model.collapseIntoNotch { completed = true }
        #expect(completed)
        // The content's 40ms follow is canceled rather than left to land, so the layout is already
        // the resting one rather than one frame of an expanded island still on its way in.
        #expect(model.contentForm == .rest)
        #expect(model.contentPresentation == .rest)
    }

    /// A stow is the user's own answer to "not now" (§5) and outlives a lock. Locking is the system
    /// taking the screen, not the user changing their mind about what the island is showing.
    @Test("locking leaves a stow and the activity alone")
    func collapseIntoNotchPreservesStow() async {
        let model = makeModel()
        model.setActivity(
            ActivityPresentations(leading: ActivityContent(symbol: "music.note")),
            change: .presented("a"),
            reduceMotion: true
        )
        await settle { model.setStowed(true, reduceMotion: true, completion: $0) }
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }

        model.collapseIntoNotch()

        #expect(model.isStowed)
        #expect(model.presentations != nil)
        #expect(model.presentation == .rest)
    }

    /// A swipe in progress when the screen goes is released without a rubber band. `settle` would
    /// animate it home on `Motion.nudge`, which is a bounce nobody is there to see and which the
    /// fade would catch mid-overshoot.
    @Test("locking drops a swipe in progress without animating it home")
    func collapseIntoNotchReleasesTheSwipe() {
        let model = makeModel()
        model.swipe.track(-42)
        model.collapseIntoNotch()
        #expect(model.swipe.offset == 0)
    }

    /// The shape collapsing is not the same as the island being gone. A resting island still draws
    /// — a synthesized pill, or a Now Playing glyph in the flank of a hardware notch — and that is
    /// what the lock fade would catch. `reentry` is what takes the content off screen, and it is the
    /// same value the return springs from, so the two are one mechanism rather than a hide and an
    /// unrelated bounce.
    @Test("locking takes the content off screen, not just the shape")
    func collapseIntoNotchHidesTheContent() {
        let model = makeModel()
        #expect(model.reentry == 1)

        model.collapseIntoNotch()

        #expect(model.reentry == 0)
        #expect(IslandScreenModel.reentryOpacity(model.reentry) == 0)
        // Genuinely absent rather than dimmed: a small, faint island still reads as present, which
        // is what would make the fade look like a blink rather than like nothing being there.
        #expect(IslandScreenModel.reentryScale(model.reentry) < 0.5)
    }

    /// The lock and the unlock are a shape moving, not a picture dissolving. `reentry` is the only
    /// value either of them animates, so this is where "the handover does not fade" is enforceable:
    /// the island is solid across the whole of the travel a person watches, and transparent only at
    /// the very bottom of it, where the shape is inside the cutout and there is nothing to see fade.
    @Test("the re-entry is a scale, not a fade")
    func reentryDoesNotFade() {
        #expect(IslandScreenModel.reentryOpacity(0) == 0, "absent while the island is away")

        // Solid by the time the shape has grown a sixth of its travel — everything past this point
        // is `reentryScale` alone, which is the whole of what the lock and the unlock look like.
        #expect(IslandScreenModel.reentryOpacity(IslandScreenModel.reentryFadeSpan) == 1)
        for reentry in stride(from: 0.2, through: 1.0, by: 0.1) {
            #expect(IslandScreenModel.reentryOpacity(reentry) == 1, "no fade at \(reentry)")
        }

        // The springs overshoot both ends of the travel and neither overshoot may be visible as a
        // flicker: past 1 it stays solid, and below 0 it stays gone.
        #expect(IslandScreenModel.reentryOpacity(1.12) == 1)
        #expect(IslandScreenModel.reentryOpacity(-0.08) == 0)
    }

    /// The return is the ordinary re-entry spring, not a second mechanism — the same one the island
    /// comes back from another space on. Reduce motion lands it outright, which is §6.3's
    /// substitution and is already `playReentry`'s job.
    @Test("the return springs out of the notch the island was put into")
    func returnPlaysTheReentry() {
        let model = makeModel()
        model.collapseIntoNotch()
        #expect(model.reentry == 0)

        model.playReentry(reduceMotion: true)
        #expect(model.reentry == 1)
    }

    /// Collapsing an island that is already at rest is a no-op that still reports completion — the
    /// caller uses it to tighten the hit region, and a skipped completion leaves the region widened.
    @Test("locking a resting island still completes")
    func collapseIntoNotchAtRest() {
        let model = makeModel()
        var completed = false
        model.collapseIntoNotch { completed = true }
        #expect(completed)
        #expect(model.presentation == .rest)
    }
}
