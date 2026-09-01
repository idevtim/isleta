import CoreGraphics
import Foundation
import IslandKit

/// Whether the queue has anywhere to go in each direction (§5).
///
/// Passed in per sample rather than held by the tracker, because it can change *during* a gesture:
/// a HUD arriving while the user's fingers are still on the glass puts a new entry in the queue.
/// A tracker holding a stale copy would resist a swipe that had somewhere to go, or let one run
/// past an end that had just appeared.
public struct SwipeBounds: Equatable, Sendable {

    /// Whether there is an activity one step further along the queue.
    public var canAdvance: Bool

    /// Whether there is one back the other way.
    public var canRetreat: Bool

    public init(canAdvance: Bool, canRetreat: Bool) {
        self.canAdvance = canAdvance
        self.canRetreat = canRetreat
    }

    public static let closed = SwipeBounds(canAdvance: false, canRetreat: false)
}

/// The numbers a swipe is measured against. One place, so nothing reaches for a literal.
public struct SwipeMetrics: Equatable, Sendable {

    /// How far the content may slide when the swipe has somewhere to go — **one page**.
    ///
    /// **56 until 2026-08-28, and the 56 was the whole of what was wrong with the gesture.** The
    /// content slid a fixed 56pt however far the finger went, and the page committed on its own at
    /// `commitDistance` while the fingers were still down — so the surface moved a fraction of an
    /// inch, decided, and flew the remaining 300pt by itself. Reported as the pages "auto
    /// changing", which is exactly what it was: the gesture was a trigger wearing a drag's clothes.
    ///
    /// A page-width travel makes it a real carousel — the outgoing page leaves and the incoming one
    /// arrives under the finger, all the way, and the commit happens on release. Set by the shell
    /// to `IslandLayout.expandedBodySize.width`, because the tracker knows no geometry; the default
    /// is a page-ish number so a tracker nobody configured still behaves.
    ///
    /// Within this distance the content follows the finger **1:1** — see `displacement`, where the
    /// rubber band moved to the far side of it.
    public var travel: CGFloat = 368

    /// How far it may slide when it does not. This is §5's resistance, and it is a *quarter* of
    /// `travel` for a reason: the difference has to be legible as "there is nothing there" within
    /// the first few millimetres, not after the user has already committed to the gesture.
    public var resistance: CGFloat = 14

    /// Finger travel that commits a cycle on its own, with no flick — a **floor**, and normally not
    /// the number that decides it. See `commitThreshold`.
    public var commitDistance: CGFloat = 34

    /// The share of one page a slow drag has to cover to carry, measured on release.
    ///
    /// **Half, which is the only fraction that does not have to be learned.** Past the middle the
    /// incoming page is the one occupying most of the island, so letting go completes what the eye
    /// already reads as done; before it, the outgoing page still is. Every paged surface on the
    /// platform draws the line there.
    ///
    /// It is a fraction and not a distance because it is a fraction of what the *user* sees move:
    /// at the old fixed 34pt against a 368pt page a drag committed at 9% of the way across, which
    /// is a flick threshold pretending to be a distance one. The flick still exists and still
    /// commits on speed alone — this is the other half of the test, for a deliberate slow drag.
    public var commitFraction: CGFloat = 0.5

    /// Points per second that commits a cycle regardless of distance. This is the flick.
    public var flickVelocity: CGFloat = 320

    /// A flick still has to be a gesture rather than a twitch, so it needs this much travel too.
    public var minimumFlickDistance: CGFloat = 6

    /// What one mouse-wheel notch is worth when the deltas arrive in lines rather than points.
    public var lineTravel: CGFloat = 16

    /// How long a gap between wheel notches ends a discrete gesture.
    ///
    /// This is why a mouse wheel needs no timer: the *next* event carries the timestamp that
    /// retires the previous accumulation, so nothing has to be running in between. A tracker that
    /// scheduled a reset would put a timer on the §9 budget for a gesture that has already stopped.
    public var discreteGap: TimeInterval = 0.35

    public init() {}
}

/// Recognizes a swipe across the island and says what should happen (§5).
///
/// A pure value type with no clock, no AppKit and no view. Everything it decides is a function of
/// the samples handed to it and the bounds it is given, so rubber-banding and momentum are
/// answerable by synchronous tests — which matters more here than usual, because the alternative is
/// judging a spring by feel on hardware and calling it done.
///
/// **It decides, it does not animate.** The caller applies `Outcome`, and the curve it applies is a
/// `Motion` token. There is no fifth token and this did not need one: tracking the finger is not an
/// animation at all, a rejected swipe is `Motion.nudge` — "an attention nudge that does not change
/// state" is a description of a rubber-band release — and a committed one settles on
/// `Motion.contentSwap`, the same curve everything else that follows the container travels on.
public struct SwipeTracker: Sendable {

    /// What the caller should do with this sample.
    public enum Outcome: Equatable, Sendable {

        /// Nothing to do. A vertical gesture, a resting finger, or a sample after this gesture has
        /// already committed.
        case ignored

        /// The finger is moving: put the content here, with no animation. Animating a tracked value
        /// is what makes a drag feel like it is being pulled through treacle — the spring is always
        /// interpolating towards a position the finger has already left.
        case tracking(offset: CGFloat)

        /// Cycle by this many steps, then settle the offset back to zero.
        case commit(steps: Int)

        /// The swipe did not carry. Spring the offset back to zero.
        case settle
    }

    public var metrics = SwipeMetrics()

    /// Accumulated finger travel for this gesture, before any resistance is applied. Resistance is
    /// a rendering decision; the commit thresholds are measured against what the finger actually
    /// did, or a swipe past the end of the queue could never be recognized as a swipe at all.
    private var traveled: CGFloat = 0

    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval?

    /// Set when a gesture is decided to be vertical, cleared when it ends. Nothing on the island
    /// scrolls vertically, so a vertical two-finger gesture must not slide the content sideways by
    /// whatever horizontal jitter it happened to carry.
    private var isVertical = false

    /// Set once a gesture has committed, so a gesture cannot commit twice under one finger.
    private var hasCommitted = false

    /// Set when the fingers leave the glass, cleared when the system stops sending momentum.
    ///
    /// Momentum deltas are *read* — they are what a flick is made of — but they are read at the
    /// moment the fingers lift, out of the velocity accumulated up to that point, and the glide
    /// that follows is then deliberately ignored. Accumulating it instead would put the content
    /// back out under a spring that has already been released and is on its way home, so a flick
    /// would show the island snapping back, jumping out again, and snapping back a second time.
    private var isCoasting = false

    public init() {}

    /// Feeds one scroll event in.
    ///
    /// - Parameter bounds: what the queue can do *now* — see `SwipeBounds`.
    /// - Parameter reduceMotion: §6.3. The swipe still works; it simply stops being a drag. Nothing
    ///   follows the finger, nothing springs back, and the commit thresholds are unchanged — so a
    ///   user who has asked for less motion still cycles activities with the same gesture, and the
    ///   change they cycle to arrives on the crossfade `Motion.respectingReduceMotion` substitutes.
    public mutating func consume(
        _ sample: IslandScrollSample,
        bounds: SwipeBounds,
        reduceMotion: Bool = false
    ) -> Outcome {
        let outcome = decide(sample, bounds: bounds)
        guard reduceMotion else { return outcome }
        switch outcome {
        case .commit, .ignored: return outcome
        // Neither has anything to do when nothing ever left zero, and `.settle` would open an
        // animation transaction to travel from zero to zero.
        case .tracking, .settle: return .ignored
        }
    }

    private mutating func decide(_ sample: IslandScrollSample, bounds: SwipeBounds) -> Outcome {
        switch sample.phase {
        case .began:
            reset()
            accumulate(sample)
            return .tracking(offset: displacement(bounds: bounds))

        case .changed:
            guard !hasCommitted, !isCoasting else { return .ignored }
            accumulate(sample)
            guard !isVertical else { return .ignored }
            // **Nothing commits under the finger.** This branch used to fire a cycle the moment the
            // travel passed `commitDistance`, which is what made the pages change on their own part
            // way through a gesture the user was still making. A page is a surface you drag *to*,
            // and the decision belongs at the moment the fingers leave — see `.ended`, which is now
            // the only place a commit can come from.
            return .tracking(offset: displacement(bounds: bounds))

        case .ended:
            // The decision point, and the one place velocity counts. This is where "a flick must
            // carry" is honored: a short, fast gesture commits on the speed it was traveling at
            // when the fingers left, without having covered `commitDistance`.
            let committed = hasCommitted
            let vertical = isVertical
            let steps = committed || vertical ? nil : committedSteps(bounds: bounds, requireDistance: false)
            reset()
            isCoasting = true
            if let steps { return .commit(steps: steps) }
            return committed || vertical ? .ignored : .settle

        case .momentum:
            // Already accounted for at `.ended` — see `isCoasting`.
            return .ignored

        case .momentumEnded:
            isCoasting = false
            return .ignored

        case .canceled:
            let wasTracking = !isVertical && !hasCommitted && traveled != 0
            reset()
            return wasTracking ? .settle : .ignored

        case .discrete:
            // A mouse wheel: no gesture around the notches, so the gap between them is what ends
            // one. Each notch is a fresh decision and there is no spring to release, so a notch
            // that does not commit reports its offset and nothing else.
            if let last = lastTimestamp, sample.timestamp - last > metrics.discreteGap { reset() }
            accumulate(sample)
            guard !isVertical else { return .ignored }
            // **The one place a commit still happens without an `.ended`, because a wheel has none.**
            // A mouse wheel delivers notches with no gesture around them: there is no lift to decide
            // at, so each accumulation has to decide for itself. `commitDistance` is the floor that
            // makes that bearable — a wheel user is not dragging a page across the island, they are
            // asking for the next one, and half a page of notches to get there would be absurd.
            if let steps = committedSteps(bounds: bounds, requireDistance: true, isDiscrete: true) {
                reset()
                return .commit(steps: steps)
            }
            // **A notch under the threshold reports nothing at all**, where it used to report its
            // displacement. Tracking a wheel made sense while the content slid 56pt and sprang
            // back: the rubber band was the feedback. It stopped making sense when the travel
            // became a page — a notch is 16pt of a 368pt page, which is a twitch nobody asked to
            // see — and it became a *bug*, because a wheel has no `.ended`: the accumulation that
            // began a drag would have had nothing to settle it, and the island would sit part way
            // toward a page it never turned to, with both neighbours drawn, until the next notch.
            // A wheel flips pages; it does not drag them.
            return .ignored
        }
    }

    // MARK: - Accumulation

    private mutating func accumulate(_ sample: IslandScrollSample) {
        let deltaX = sample.isPrecise ? sample.deltaX : sample.deltaX * metrics.lineTravel
        let deltaY = sample.isPrecise ? sample.deltaY : sample.deltaY * metrics.lineTravel

        // The axis is locked by the first sample that actually moved, not by the phase that opened
        // the gesture: `.began` routinely carries (0, 0), and locking on that would decide the axis
        // of every gesture by a coin toss.
        if traveled == 0, !isVertical, deltaX != 0 || deltaY != 0 {
            isVertical = abs(deltaY) > abs(deltaX)
        }

        if let last = lastTimestamp {
            let interval = sample.timestamp - last
            if interval > 0 {
                // Smoothed, because a single frame's delta is noisy enough that a slow drag can
                // show one 400pt/s sample and commit a flick the user did not make.
                let instant = deltaX / CGFloat(interval)
                velocity += (instant - velocity) * 0.5
            }
        }
        lastTimestamp = sample.timestamp
        traveled += deltaX
    }

    private mutating func reset() {
        traveled = 0
        velocity = 0
        lastTimestamp = nil
        isVertical = false
        hasCommitted = false
        isCoasting = false
    }

    // MARK: - Decisions

    /// Which way this gesture is going, or nil if it has not moved. Negative travel means the
    /// content has been pushed left and the next activity is coming in from the right, matching
    /// every other list on the machine.
    private var steps: Int? {
        if traveled < 0 { return 1 }
        if traveled > 0 { return -1 }
        return nil
    }

    private func canGo(_ steps: Int, bounds: SwipeBounds) -> Bool {
        steps > 0 ? bounds.canAdvance : bounds.canRetreat
    }

    /// How far a slow drag has to have travelled to carry.
    ///
    /// Half a page, floored at `commitDistance` so a hypothetical island narrow enough to make half
    /// a page smaller than a deliberate gesture cannot commit on a twitch.
    var commitThreshold: CGFloat {
        max(metrics.commitDistance, metrics.travel * metrics.commitFraction)
    }

    /// The commit test. `requireDistance` is false only at the end of a gesture, where a flick that
    /// covered very little ground still counts.
    ///
    /// - Parameter isDiscrete: a mouse wheel, which is measured against `commitDistance` alone. It
    ///   has no lift to decide at and is not dragging anything, so half a page of notches would be
    ///   the wrong ask — see the `.discrete` branch.
    private func committedSteps(
        bounds: SwipeBounds,
        requireDistance: Bool,
        isDiscrete: Bool = false
    ) -> Int? {
        guard let steps, canGo(steps, bounds: bounds) else { return nil }
        let distance = abs(traveled)
        if distance >= (isDiscrete ? metrics.commitDistance : commitThreshold) { return steps }
        guard !requireDistance else { return nil }
        let flicked = abs(velocity) >= metrics.flickVelocity && distance >= metrics.minimumFlickDistance
        // A flick whose momentum runs the opposite way to its travel is a gesture that reversed
        // under the finger; the direction the content actually moved is the one that counts.
        return flicked && (velocity < 0) == (steps > 0) ? steps : nil
    }

    /// Where the content should be drawn for the travel so far.
    ///
    /// Both the free case and the resisted case go through the same curve, so the transition
    /// between them — a queue that gains an entry mid-gesture — cannot produce a jump. What differs
    /// is the pair of numbers: free travel starts out following the finger 1:1 and saturates at
    /// `travel`; resisted travel is damped from the very first millimetre and saturates at
    /// `resistance`, a quarter of the distance.
    private func displacement(bounds: SwipeBounds) -> CGFloat {
        guard let steps else { return 0 }
        guard canGo(steps, bounds: bounds) else {
            // Nowhere to go: damped from the very first millimetre and saturating at a quarter of a
            // page, so "there is nothing that way" is legible before the user has committed to the
            // gesture. Unreachable for the pages, which wrap — see `SwipeController`.
            return Self.rubberBand(traveled, limit: metrics.resistance, coefficient: 0.55)
        }
        // **1:1 within the page, and banded only past it.** The old shape asymptoted from the
        // origin, so the content never quite kept up with the finger and never quite reached a full
        // page — which is fine for a 56pt nudge and wrong for a carousel, where the whole point is
        // that the surface under your fingers is the surface you are moving.
        //
        // The band has not gone; it has moved to where there is actually something to resist. Past
        // one page the next page along is not drawn — the carousel renders the two neighbours and
        // no further — so the overshoot is damped to a fifth of a page and saturates there. Still
        // asymptotic, so there is no corner for the eye to read as the app having lost the gesture.
        let magnitude = abs(traveled)
        guard magnitude > metrics.travel else { return traveled }
        let past = Self.rubberBand(
            magnitude - metrics.travel,
            limit: metrics.travel * 0.2,
            coefficient: 0.55
        )
        let banded = metrics.travel + past
        return traveled < 0 ? -banded : banded
    }

    /// The rubber band: `x` maps onto `(-limit, limit)`, with slope `coefficient` at the origin.
    ///
    /// Asymptotic rather than clamped, and that is the point of using a curve at all. A clamp has a
    /// corner in it — the content tracks the finger, then stops dead — and a corner is exactly what
    /// the eye reads as the app having lost the gesture. This has no corner anywhere.
    static func rubberBand(_ x: CGFloat, limit: CGFloat, coefficient: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let magnitude = abs(x)
        let banded = (1 - (1 / (magnitude * coefficient / limit + 1))) * limit
        return x < 0 ? -banded : banded
    }
}
