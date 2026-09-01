import CoreGraphics
import Foundation
import IslandKit
import Testing

@testable import IslandUI

/// The gesture's physics, answered synchronously. A spring judged by feel on hardware is a spring
/// nobody can change later without re-judging it, so every threshold §5 asks for is pinned here.
@Suite("Swipe recognition")
struct SwipeTrackerTests {

    private let open = SwipeBounds(canAdvance: true, canRetreat: true)

    /// Drives a whole gesture and returns every outcome, so a test can assert on the shape of the
    /// gesture rather than on one sample of it.
    private func gesture(
        _ deltas: [CGFloat],
        bounds: SwipeBounds,
        interval: TimeInterval = 1.0 / 60,
        reduceMotion: Bool = false,
        end: Bool = true
    ) -> [SwipeTracker.Outcome] {
        var tracker = SwipeTracker()
        var outcomes: [SwipeTracker.Outcome] = []
        var time: TimeInterval = 0

        outcomes.append(
            tracker.consume(
                IslandScrollSample(phase: .began, deltaX: 0, timestamp: time),
                bounds: bounds,
                reduceMotion: reduceMotion
            )
        )
        for delta in deltas {
            time += interval
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(phase: .changed, deltaX: delta, timestamp: time),
                    bounds: bounds,
                    reduceMotion: reduceMotion
                )
            )
        }
        if end {
            time += interval
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(phase: .ended, deltaX: 0, timestamp: time),
                    bounds: bounds,
                    reduceMotion: reduceMotion
                )
            )
        }
        return outcomes
    }

    private func commits(_ outcomes: [SwipeTracker.Outcome]) -> [Int] {
        outcomes.compactMap { if case .commit(let steps) = $0 { steps } else { nil } }
    }

    private func offsets(_ outcomes: [SwipeTracker.Outcome]) -> [CGFloat] {
        outcomes.compactMap { if case .tracking(let offset) = $0 { offset } else { nil } }
    }

    // MARK: - Committing

    /// Content pushed left brings the next activity in from the right, matching every other list on
    /// the machine. Getting this backwards is not subtle, but it is exactly the kind of thing that
    /// gets flipped during a refactor and only noticed on hardware.
    @Test("a long drag left advances, a long drag right goes back")
    func directions() {
        #expect(commits(gesture(Array(repeating: -8, count: 6), bounds: open)) == [1])
        #expect(commits(gesture(Array(repeating: 8, count: 6), bounds: open)) == [-1])
    }

    @Test("a short slow drag does not commit")
    func shortDragSettles() {
        let outcomes = gesture([-4, -4, -4], bounds: open, interval: 0.2)
        #expect(commits(outcomes).isEmpty)
        #expect(outcomes.last == .settle)
    }

    /// §5's momentum, at the point it is actually decided: a gesture that covered nowhere near
    /// `commitDistance` still carries, because of how fast it was going when the fingers left.
    @Test("a short fast flick carries")
    func flickCarries() {
        // 18pt total — half the commit distance — at 1080 pt/s.
        let outcomes = gesture([-6, -6, -6], bounds: open, interval: 1.0 / 180)
        #expect(commits(outcomes) == [1])
        #expect(outcomes.last == .commit(steps: 1))
    }

    /// The other side of the same threshold: the same distance traveled slowly is a nudge, not a
    /// flick, and must leave the island where it was.
    @Test("the same distance traveled slowly does not")
    func slowDoesNotFlick() {
        #expect(commits(gesture([-6, -6, -6], bounds: open, interval: 0.25)).isEmpty)
    }

    /// A twitch is not a flick however fast it is, or a resting hand on the trackpad would cycle
    /// activities.
    @Test("a fast twitch of a couple of points is not a flick")
    func twitchIsNotAFlick() {
        #expect(commits(gesture([-2], bounds: open, interval: 1.0 / 240)).isEmpty)
    }

    /// A gesture that reversed under the finger: it has traveled left overall but is moving right
    /// when it lifts. Committing on the velocity's direction would cycle the opposite way from the
    /// one the content visibly moved.
    @Test("a gesture that reverses before lifting does not flick the other way")
    func reversedFlick() {
        #expect(commits(gesture([-10, -8, 6, 9], bounds: open, interval: 1.0 / 120)).isEmpty)
    }

    @Test("one gesture commits at most once")
    func oneCommitPerGesture() {
        #expect(commits(gesture(Array(repeating: -20, count: 8), bounds: open)) == [1])
    }

    /// **Nothing commits while the fingers are still down**, and this is the regression guard for
    /// the whole point of the carousel.
    ///
    /// Until 2026-08-28 a drag past `commitDistance` fired the cycle mid-gesture: the page changed
    /// on its own part way through a movement the user was still making, and the rest of the
    /// gesture landed on an island that had already turned. Reported as the pages "auto changing",
    /// which is exactly what it was.
    ///
    /// Twenty-four samples of 20pt is 480pt — well past a page — driven slowly enough that the
    /// flick cannot be what carries it. Every outcome before the lift must be `.tracking`.
    @Test("a page never turns under the finger, however far the drag goes")
    func nothingCommitsWhileTracking() {
        let outcomes = gesture(Array(repeating: -20, count: 24), bounds: open, interval: 0.1)
        let beforeTheLift = outcomes.dropLast()
        #expect(beforeTheLift.allSatisfy { if case .tracking = $0 { true } else { false } })
        #expect(outcomes.last == .commit(steps: 1))
    }

    /// A deliberate slow drag carries on **distance**, and the distance is half a page rather than
    /// the old fixed 34pt — which against a 368pt page was a commit at 9% of the way across.
    @Test("a slow drag carries once it is past the middle of the page and not before")
    func slowDragCarriesPastTheMiddle() {
        let span = SwipeMetrics().travel
        let threshold = SwipeTracker().commitThreshold
        #expect(threshold == span / 2)

        // Slow enough that no flick is involved, and just short of half a page.
        let short = Int((threshold - 20) / 10)
        #expect(commits(gesture(Array(repeating: -10, count: short), bounds: open, interval: 0.1)).isEmpty)

        let long = Int((threshold + 20) / 10)
        #expect(commits(gesture(Array(repeating: -10, count: long), bounds: open, interval: 0.1)) == [1])
    }

    // MARK: - Tracking a whole page

    /// **The content follows the finger 1:1 within a page.** The old curve asymptoted from the
    /// origin, so a 56pt band never quite kept up — right for a nudge, wrong for a carousel, where
    /// the surface under your fingers is the surface you are moving.
    @Test("the content keeps up with the finger for the width of a page")
    func trackingIsOneToOneWithinAPage() {
        let outcomes = gesture([-40, -40, -40], bounds: open, interval: 0.1)
        #expect(offsets(outcomes) == [0, -40, -80, -120])
    }

    /// Past a page there is nothing more to show — the carousel draws two neighbours and no further
    /// — so the overshoot is damped and saturates. Asymptotic, so there is no corner where the
    /// content stops dead under a finger that is still moving.
    @Test("dragging past one page is damped rather than clamped")
    func trackingBandsPastAPage() {
        let span = SwipeMetrics().travel
        let outcomes = gesture(Array(repeating: -100, count: 8), bounds: open, interval: 0.1)
        let travelled = offsets(outcomes).map(abs)

        // It gets past a whole page…
        #expect(travelled.contains { $0 > span })
        // …but never past the page plus its band, and never stops moving on the way.
        #expect(travelled.allSatisfy { $0 <= span * 1.2 })
        #expect(zip(travelled, travelled.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: - Rubber-banding

    /// §5's resistance. The swipe still travels — silence would read as a dead island — but it
    /// travels a quarter as far and never commits.
    @Test("a swipe past the end of the queue resists and does not commit")
    func rubberBandsAtTheEnd() {
        let closed = SwipeBounds(canAdvance: false, canRetreat: true)
        let outcomes = gesture(Array(repeating: -12, count: 8), bounds: closed)

        #expect(commits(outcomes).isEmpty)
        #expect(outcomes.last == .settle)

        let traveled = offsets(outcomes).map(abs).max() ?? 0
        #expect(traveled > 0)
        #expect(traveled < SwipeMetrics().resistance)
    }

    /// The two curves differ by enough to feel, which is the whole point of having two.
    @Test("resisted travel is a fraction of free travel for the same finger movement")
    func resistanceIsLegible() {
        let deltas = Array(repeating: CGFloat(-4), count: 4)
        let free = offsets(gesture(deltas, bounds: open, end: false)).map(abs).max() ?? 0
        let closed = SwipeBounds(canAdvance: false, canRetreat: true)
        let resisted = offsets(gesture(deltas, bounds: closed, end: false)).map(abs).max() ?? 0

        #expect(resisted < free / 2)
    }

    /// No corner anywhere: the content never stops dead under a finger that is still moving, and
    /// it never runs away either.
    @Test("the rubber band is monotonic and bounded by its limit")
    func rubberBandShape() {
        var previous: CGFloat = 0
        for step in stride(from: CGFloat(1), through: 400, by: 7) {
            let banded = SwipeTracker.rubberBand(-step, limit: 56, coefficient: 1)
            #expect(abs(banded) > abs(previous))
            #expect(abs(banded) < 56)
            previous = banded
        }
        #expect(SwipeTracker.rubberBand(0, limit: 56, coefficient: 1) == 0)
        // Symmetric, so a swipe feels the same in both directions.
        #expect(SwipeTracker.rubberBand(30, limit: 56, coefficient: 1)
            == -SwipeTracker.rubberBand(-30, limit: 56, coefficient: 1))
    }

    /// A queue with nothing either side still has to be swipeable without cycling anything —
    /// resistance in both directions is the island saying "there is only this".
    @Test("with nothing either way, both directions resist")
    func closedBothWays() {
        for direction in [CGFloat(-12), 12] {
            let outcomes = gesture(Array(repeating: direction, count: 8), bounds: .closed)
            #expect(commits(outcomes).isEmpty)
            #expect(outcomes.last == .settle)
        }
    }

    // MARK: - What must not become a swipe

    @Test("a vertical gesture is ignored entirely")
    func verticalIsIgnored() {
        var tracker = SwipeTracker()
        var outcomes: [SwipeTracker.Outcome] = []
        var time: TimeInterval = 0

        _ = tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, timestamp: time), bounds: open)
        for _ in 0..<8 {
            time += 1.0 / 60
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(phase: .changed, deltaX: -3, deltaY: -20, timestamp: time),
                    bounds: open
                )
            )
        }
        outcomes.append(
            tracker.consume(IslandScrollSample(phase: .ended, deltaX: 0, timestamp: time + 0.01), bounds: open)
        )
        #expect(outcomes.allSatisfy { $0 == .ignored })
    }

    /// The axis is decided by the first sample that moved. `.began` routinely carries (0, 0), and
    /// deciding on that would settle the axis of every gesture by a coin toss.
    @Test("an axis is locked by the first moving sample, not by the phase that opened the gesture")
    func axisLocksOnMovement() {
        var tracker = SwipeTracker()
        _ = tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, deltaY: 0, timestamp: 0), bounds: open)
        var outcomes: [SwipeTracker.Outcome] = []
        for step in 1...8 {
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(phase: .changed, deltaX: -8, deltaY: -1, timestamp: Double(step) / 60),
                    bounds: open
                )
            )
        }
        // The lift, because that is the only place a commit comes from now — a page does not turn
        // under the finger. See `nothingCommitsWhileTracking`.
        outcomes.append(
            tracker.consume(IslandScrollSample(phase: .ended, deltaX: 0, timestamp: 9 / 60), bounds: open)
        )
        #expect(commits(outcomes) == [1])
    }

    /// The glide after a flick is read at lift-off and then ignored — accumulating it would put the
    /// content back out under a spring already on its way home.
    @Test("momentum after a committed flick does not commit again or move the content")
    func momentumIsNotAccumulated() {
        var tracker = SwipeTracker()
        var time: TimeInterval = 0
        _ = tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, timestamp: time), bounds: open)
        for _ in 0..<3 {
            time += 1.0 / 180
            _ = tracker.consume(IslandScrollSample(phase: .changed, deltaX: -6, timestamp: time), bounds: open)
        }
        time += 1.0 / 180
        #expect(tracker.consume(IslandScrollSample(phase: .ended, deltaX: 0, timestamp: time), bounds: open)
            == .commit(steps: 1))

        var glide: [SwipeTracker.Outcome] = []
        for _ in 0..<10 {
            time += 1.0 / 60
            glide.append(
                tracker.consume(IslandScrollSample(phase: .momentum, deltaX: -30, timestamp: time), bounds: open)
            )
        }
        glide.append(
            tracker.consume(IslandScrollSample(phase: .momentumEnded, deltaX: 0, timestamp: time), bounds: open)
        )
        #expect(glide.allSatisfy { $0 == .ignored })
    }

    /// A gesture that begins after a flick has to start clean, even if the momentum it interrupted
    /// never reported an end.
    @Test("a new gesture starts clean after an interrupted glide")
    func newGestureAfterGlide() {
        var tracker = SwipeTracker()
        var time: TimeInterval = 0
        _ = tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, timestamp: time), bounds: open)
        time += 1.0 / 180
        _ = tracker.consume(IslandScrollSample(phase: .changed, deltaX: -20, timestamp: time), bounds: open)
        time += 1.0 / 180
        _ = tracker.consume(IslandScrollSample(phase: .ended, deltaX: 0, timestamp: time), bounds: open)

        time += 0.5
        var outcomes: [SwipeTracker.Outcome] = []
        outcomes.append(
            tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, timestamp: time), bounds: open)
        )
        for _ in 0..<6 {
            time += 1.0 / 60
            outcomes.append(
                tracker.consume(IslandScrollSample(phase: .changed, deltaX: -8, timestamp: time), bounds: open)
            )
        }
        // The lift: the commit lives there now, not under the finger.
        time += 1.0 / 60
        outcomes.append(
            tracker.consume(IslandScrollSample(phase: .ended, deltaX: 0, timestamp: time), bounds: open)
        )
        #expect(commits(outcomes) == [1])
    }

    @Test("a canceled gesture springs back and commits nothing")
    func canceledGesture() {
        var tracker = SwipeTracker()
        _ = tracker.consume(IslandScrollSample(phase: .began, deltaX: 0, timestamp: 0), bounds: open)
        _ = tracker.consume(IslandScrollSample(phase: .changed, deltaX: -10, timestamp: 0.02), bounds: open)
        #expect(tracker.consume(IslandScrollSample(phase: .canceled, deltaX: 0, timestamp: 0.04), bounds: open)
            == .settle)
    }

    // MARK: - Mouse wheel

    /// A mouse has no gesture phases at all. A tracker written only against `NSEvent.Phase` would
    /// silently ignore every mouse user, which is the sort of thing that ships.
    @Test("a mouse wheel cycles without any gesture around it")
    func discreteWheel() {
        var tracker = SwipeTracker()
        var outcomes: [SwipeTracker.Outcome] = []
        for step in 0..<4 {
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(
                        phase: .discrete,
                        deltaX: -1,
                        isPrecise: false,
                        timestamp: Double(step) * 0.05
                    ),
                    bounds: open
                )
            )
        }
        #expect(commits(outcomes) == [1])
    }

    /// The gap between notches ends a discrete gesture, and it does so on the *next* event's
    /// timestamp — which is why the mouse path needs no timer and costs nothing at rest (§9).
    @Test("wheel notches far apart in time do not accumulate into a swipe")
    func discreteWheelForgets() {
        var tracker = SwipeTracker()
        var outcomes: [SwipeTracker.Outcome] = []
        for step in 0..<6 {
            outcomes.append(
                tracker.consume(
                    IslandScrollSample(
                        phase: .discrete,
                        deltaX: -1,
                        isPrecise: false,
                        timestamp: Double(step) * 2
                    ),
                    bounds: open
                )
            )
        }
        #expect(commits(outcomes).isEmpty)
    }

    // MARK: - Reduce motion

    /// §6.3 is a correctness requirement, and "degrades to something still usable" is the test: the
    /// gesture still cycles on exactly the same thresholds. What goes away is the part that is
    /// motion — nothing follows the finger and nothing springs back.
    @Test("reduce motion keeps the swipe and drops the drag")
    func reduceMotionKeepsTheGesture() {
        let long = gesture(Array(repeating: -8, count: 6), bounds: open, reduceMotion: true)
        #expect(commits(long) == [1])
        #expect(offsets(long).isEmpty)

        let flick = gesture([-6, -6, -6], bounds: open, interval: 1.0 / 180, reduceMotion: true)
        #expect(commits(flick) == [1])
    }

    /// A swipe with nowhere to go under reduce motion has nothing to say and must say it silently
    /// rather than opening a transaction to animate zero to zero.
    @Test("reduce motion turns a rejected swipe into nothing at all")
    func reduceMotionRejectedSwipe() {
        let outcomes = gesture(Array(repeating: -12, count: 8), bounds: .closed, reduceMotion: true)
        #expect(outcomes.allSatisfy { $0 == .ignored })
    }
}

@Suite("Swipe offset")
@MainActor
struct SwipeOffsetTests {

    @Test("tracking moves the content and settling brings it home")
    func trackAndSettle() {
        let swipe = IslandSwipeModel()
        #expect(swipe.offset == 0)

        swipe.track(-18)
        #expect(swipe.offset == -18)

        swipe.settle(reduceMotion: false)
        #expect(swipe.offset == 0)
    }

    @Test("settling from zero is a no-op rather than an empty transaction")
    func settlingFromRest() {
        let swipe = IslandSwipeModel()
        swipe.settle(reduceMotion: true)
        #expect(swipe.offset == 0)
    }

    /// The neighbours are on screen for the length of a gesture and not one frame longer, which is
    /// §9: the music page owns a `CALayer` equaliser and the weather page a precipitation view.
    @Test("the pages either side exist only while a gesture is live")
    func neighboursAreOnlyDrawnWhilePaging() {
        let swipe = IslandSwipeModel()
        #expect(!swipe.isPaging)
        #expect(swipe.incoming == nil)

        let incoming = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 278), topCornerRadius: 0, bottomCornerRadius: 28
        )
        swipe.beginPaging(toward: incoming, span: 368)
        #expect(swipe.isPaging)

        swipe.endPaging()
        #expect(!swipe.isPaging)
        #expect(swipe.incoming == nil)
    }

    /// **The arithmetic that makes a quick second swipe possible.** A committed turn steps the page
    /// first and re-expresses the offset against it, so nothing moves at the instant of the swap:
    /// content that was 184pt short of the next page is 184pt past the page it just left, and what
    /// is left to travel is a tail rather than most of a page.
    ///
    /// The tail itself cannot be watched from here — `withAnimation` writes its final value at once
    /// and only a view interpolates — so this pins the step, and `SwipeSelfTest` walks the rest of
    /// it on a real panel.
    @Test("a committed turn is measured from the page it arrived at, not the one it left")
    func landingRebasesTheOffset() {
        // Half way across, forward: 368 to go became 184 already travelled.
        #expect(IslandSwipeModel.rebased(offset: -184, by: -368) == 184)
        // A flick that barely moved still has almost the whole page to settle through.
        #expect(IslandSwipeModel.rebased(offset: -20, by: -368) == 348)
        // And backwards is the same statement with the signs the other way up.
        #expect(IslandSwipeModel.rebased(offset: 184, by: 368) == -184)
    }

    /// The outline has to keep interpolating from somewhere while the tail travels, and after the
    /// swap that somewhere is the page being *left*: lerping the old shape at `1 - progress` is the
    /// height it was already at. So `landTurn` takes the departing page's shape, not the arriving
    /// one's.
    @Test("a landing turn interpolates the outline back toward the page it left")
    func landingTakesTheDepartingShape() {
        let swipe = IslandSwipeModel()
        let arriving = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 144), topCornerRadius: 0, bottomCornerRadius: 28
        )
        let departing = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 278), topCornerRadius: 0, bottomCornerRadius: 28
        )
        swipe.beginPaging(toward: arriving, span: 368)
        swipe.track(-184)

        var reportedBack = false
        swipe.landTurn(by: -368, incoming: departing, reduceMotion: true) { reportedBack = true }
        #expect(swipe.incoming == departing)
        #expect(reportedBack)
        #expect(swipe.offset == 0)
    }

    /// The finger writes its own half of the offset and nothing else, which is what lets a gesture
    /// start while the last turn is still easing home: the tail goes on decaying underneath it
    /// rather than being seized the instant a finger touches the glass.
    @Test("the finger writes its own half of the offset and leaves the tail alone")
    func trackingWritesOnlyTheFingersHalf() {
        let swipe = IslandSwipeModel()
        swipe.beginPaging(toward: nil, span: 368)
        swipe.track(-24)
        #expect(swipe.drag == -24)
        #expect(swipe.landing == 0)
        #expect(swipe.offset == -24)

        swipe.clearOffsetWithoutAnimation()
        #expect(swipe.offset == 0)
        #expect(swipe.drag == 0)
    }

    /// Progress is clamped, because the offset is not: the band past a page is deliberate, and an
    /// island that kept growing past the page it is arriving at would overshoot its own height.
    @Test("progress runs to one page and stops")
    func progressIsClamped() {
        let swipe = IslandSwipeModel()
        #expect(swipe.progress == 0)

        swipe.beginPaging(toward: nil, span: 200)
        swipe.track(-100)
        #expect(abs(swipe.progress - -0.5) < 0.001)

        swipe.track(-260)
        #expect(swipe.progress == -1)

        swipe.track(140)
        #expect(swipe.progress == 0.7)
    }

    /// An offset with no page behind it moves nothing about the island — which is every swipe that
    /// is not a page turn, and every frame of a preview.
    ///
    /// This was once unconditional and is deliberately no longer: see the test below, and
    /// `IslandSwipeModel` for why the pages are the exception.
    @Test("an offset with no page behind it changes nothing about the island's metrics")
    func swipeDoesNotMoveTheOutline() {
        let model = IslandScreenModel(
            metricsByForm: [.rest: IslandShapeMetrics(bodySize: CGSize(width: 185, height: 32), topCornerRadius: 0, bottomCornerRadius: 8)],
            notchKind: .hardware
        )
        let before = model.metrics
        model.swipe.track(-24)
        #expect(model.metrics == before)
        #expect(model.form == .rest)
    }

    /// **A page being dragged carries the island's outline with it**, and this is the arithmetic
    /// that makes the carousel possible at all: the three pages are 144, 153–185 and 278pt tall, so
    /// a strip that slid across a stationary outline would drag the weather through a music-shaped
    /// window.
    ///
    /// Half way through, the island is half way between the two heights. All the way through, it is
    /// exactly the incoming page's — which is what lets the swap at the end move nothing at all.
    @Test("an island being dragged between two pages is the shape of neither and then of the second")
    func theOutlineFollowsTheDrag() {
        let here = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 144), topCornerRadius: 0, bottomCornerRadius: 28
        )
        let there = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 278), topCornerRadius: 0, bottomCornerRadius: 28
        )
        let model = IslandScreenModel(metricsByForm: [.rest: here], notchKind: .hardware)

        model.swipe.beginPaging(toward: there, span: 368)
        #expect(model.metrics == here)

        model.swipe.track(-184)
        #expect(abs(model.metrics.bodySize.height - 211) < 0.001)

        model.swipe.track(-368)
        #expect(model.metrics == there)

        // And past the page it is arriving at, it stops growing rather than overshooting.
        model.swipe.track(-440)
        #expect(model.metrics == there)

        model.swipe.endPaging()
        #expect(model.metrics == here)
    }
}
