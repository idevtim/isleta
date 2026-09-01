import CoreGraphics
import IslandKit

/// Recognizes the two-finger horizontal swipe that sends the island's content back into the notch,
/// and the one that brings it out again.
///
/// **This replaced swipe-to-cycle on the same axis.** Both cannot live there: one gesture cannot
/// mean "show me the next activity" and "put them all away" and be predictable about which. Cycling
/// lost, by decision — the queue usually holds one thing, so the gesture spent most of its life
/// doing nothing, while stowing always has an answer. `ActivityCoordinator`'s pin, rubber-banding
/// and momentum are still there and still tested; nothing drives them any more.
///
/// It is a door, not a dial: no rubber-banding, no momentum, no bounds. Either it commits or the
/// island has not moved.
///
/// Pure, like everything the island's geometry depends on: it takes samples and returns a verdict,
/// so the whole gesture is testable without a trackpad.
public struct IslandStowGesture: Sendable {

    public enum Outcome: Equatable, Sendable {
        /// Nothing to do — still tracking, wrong axis, or too small to mean anything.
        case none
        /// Put the content away. The island returns to the bare cutout.
        case stow
        /// Bring it back.
        case unstow
    }

    /// How far the fingers must travel before the gesture counts.
    ///
    /// Generous, because the cost of a false positive is high: the island's content vanishing
    /// because someone scrolled a web page while the pointer happened to be crossing the notch is
    /// indistinguishable, to them, from the app having crashed. A deliberate swipe clears this
    /// easily; an incidental scroll does not.
    public static let commitDistance: CGFloat = 28

    /// The gesture is **direction-agnostic**: either way toggles.
    ///
    /// It started out directional — left away, right back — and that requires the app and the user
    /// to agree on which way is left, which they do not: `deltaX`'s sign depends on the trackpad's
    /// scroll direction setting, so the same flick means opposite things on two Macs. There is no
    /// reading of that constant which is right for everybody.
    ///
    /// Toggling needs no such agreement. The island is either showing something or it is not, the
    /// swipe reverses it, and the result is the same on every machine — which is also simply easier
    /// to use, because there is nothing to remember.

    private var traveled: CGFloat = 0
    private var isVertical = false
    private var hasCommitted = false

    public init() {}

    /// - Parameters:
    ///   - isStowed: whether the content is currently away.
    ///   - isExpanded: whether the island is open. An open island ignores the gesture entirely —
    ///     stowing is what you do to an island that is *in your way*, and an open one is one you
    ///     asked for. Swiping across a scrub bar or a transport row and having the whole thing
    ///     vanish is the sort of thing that stops people touching the island at all.
    public mutating func consume(
        _ sample: IslandScrollSample,
        isStowed: Bool,
        isExpanded: Bool
    ) -> Outcome {
        guard !isExpanded else {
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
            guard !isVertical, !hasCommitted else { return .none }
            return verdict(isStowed: isStowed)

        case .momentum, .momentumEnded:
            // Momentum is the trackpad's inertia, not the user's intent. Acting on it would give a
            // hard scroll that has already been judged and refused a second, softer chance to
            // succeed after the fingers have left the glass.
            return .none

        case .discrete:
            // A mouse wheel. One notch is not a two-finger swipe and never will be — a wheel has no
            // way to express "two fingers", so the gesture simply is not available on one.
            return .none
        }
    }

    private mutating func accumulate(_ sample: IslandScrollSample) {
        let deltaX = sample.isPrecise ? sample.deltaX : sample.deltaX * SwipeMetrics().lineTravel
        let deltaY = sample.isPrecise ? sample.deltaY : sample.deltaY * SwipeMetrics().lineTravel

        // Axis locked by the first sample that actually moved, matching `SwipeTracker`: `.began`
        // routinely carries (0, 0), and locking on that decides the axis by a coin toss.
        if traveled == 0, !isVertical, deltaX != 0 || deltaY != 0 {
            isVertical = abs(deltaY) > abs(deltaX)
        }
        traveled += deltaX
    }

    private mutating func verdict(isStowed: Bool) -> Outcome {
        guard abs(traveled) >= Self.commitDistance else { return .none }
        hasCommitted = true
        return isStowed ? .unstow : .stow
    }

    private mutating func reset() {
        traveled = 0
        isVertical = false
        hasCommitted = false
    }
}
