import CoreGraphics
import IslandKit

/// Recognizes the two-finger swipe **up** that closes an open island.
///
/// The counterpart to `IslandStowGesture`, and deliberately disjoint from it in both of the ways
/// that matter: that one is horizontal and only ever acts on a *collapsed* island; this one is
/// vertical and only ever acts on an *open* one. So the two can both watch every sample without a
/// gesture ever having two meanings — which is the trap `IslandStowGesture` documents from the time
/// swipe-to-cycle and swipe-to-stow shared an axis.
///
/// The answer is "the same thing every other way out does": the island closes through
/// `AppDelegate.collapseAll()`, so it takes the widen-then-tighten hit-region protocol, drops the
/// Escape hot key and the outside-click monitor, and hands the island back to the user in exactly
/// the state Escape leaves it in. A second way of closing that closed it *differently* would be a
/// second state machine.
///
/// Pure, like every other gesture here: it takes samples and returns a verdict, so the whole thing
/// is testable without a trackpad.
public struct IslandCloseGesture: Sendable {

    public enum Outcome: Equatable, Sendable {
        /// Nothing to do — still tracking, wrong axis, wrong direction, or too small to mean
        /// anything.
        case none
        /// Close the island, as a click on it would.
        case close
    }

    /// How far the fingers must travel upward before the gesture counts.
    ///
    /// Shorter than `IslandStowGesture.commitDistance` (28), because the two are protecting against
    /// different mistakes. Stowing acts on an island the user has *not* asked for and takes its
    /// content away, so a false positive there is indistinguishable from a crash. Closing acts on an
    /// island the user opened a moment ago and does the one thing they can already do by moving the
    /// pointer off it, pressing Escape or clicking anywhere else — a false positive costs a click to
    /// undo. 24pt is still far enough that no incidental scroll crossing the notch reaches it.
    public static let commitDistance: CGFloat = 24

    /// Upward travel so far, in points, in the **user's** frame rather than the scroll wheel's —
    /// see `IslandScrollSample.upwardDeltaY`.
    private var traveled: CGFloat = 0

    private var isHorizontal = false
    private var hasCommitted = false

    public init() {}

    /// - Parameter isExpanded: whether the island is open. A collapsed island ignores this gesture
    ///   entirely: there is nothing to close, and the same fingers moving on the same glass are how
    ///   `IslandStowGesture` is offered a stow.
    public mutating func consume(_ sample: IslandScrollSample, isExpanded: Bool) -> Outcome {
        guard isExpanded else {
            reset()
            return .none
        }
        switch sample.phase {
        case .began:
            reset()
            return .none

        case .changed:
            accumulate(sample)
            return .none

        case .ended, .canceled:
            defer { reset() }
            guard !isHorizontal, !hasCommitted else { return .none }
            return verdict()

        case .momentum, .momentumEnded:
            // The trackpad's inertia, not the user's intent — the same reasoning as
            // `IslandStowGesture`. A flick that has already been judged and refused must not get a
            // second, softer chance after the fingers have left the glass.
            return .none

        case .discrete:
            // A mouse wheel. "Two fingers" is not something a wheel can say, and a wheel notch over
            // an open island is a scroll gesture aimed at whatever is behind it.
            return .none
        }
    }

    private mutating func accumulate(_ sample: IslandScrollSample) {
        let deltaY = sample.isPrecise ? sample.upwardDeltaY : sample.upwardDeltaY * SwipeMetrics().lineTravel
        let deltaX = sample.isPrecise ? sample.deltaX : sample.deltaX * SwipeMetrics().lineTravel

        // Axis locked by the first sample that actually moved, matching the other two gestures:
        // `.began` routinely carries (0, 0), and locking on that decides the axis by a coin toss.
        if traveled == 0, !isHorizontal, deltaX != 0 || deltaY != 0 {
            isHorizontal = abs(deltaX) > abs(deltaY)
        }
        traveled += deltaY
    }

    /// Upward only, and this is the one gesture in Isleta where a direction is read at all.
    ///
    /// `IslandStowGesture` is direction-agnostic because it toggles, and a toggle needs no agreement
    /// about which way is left. Closing is not a toggle — down would have to mean "open", and the
    /// island is already open — so there is a direction, and it has to be the one the user's fingers
    /// actually moved rather than the one the scroll wheel reports. `upwardDeltaY` is where that
    /// correction is made and why.
    private mutating func verdict() -> Outcome {
        guard traveled >= Self.commitDistance else { return .none }
        hasCommitted = true
        return .close
    }

    private mutating func reset() {
        traveled = 0
        isHorizontal = false
        hasCommitted = false
    }
}
