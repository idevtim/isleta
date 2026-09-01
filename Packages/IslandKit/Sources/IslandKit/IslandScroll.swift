import AppKit

/// One scroll event, reduced to the four facts a swipe needs.
///
/// A value type rather than an `NSEvent` handed upward, for the same reason `IslandDebugInfo` is
/// one: the physics of the swipe live in IslandUI, and IslandUI has no business holding an AppKit
/// event — nor any way to construct one in a test. Everything about `SwipeTracker` is exercisable
/// by building these by hand.
public struct IslandScrollSample: Equatable, Sendable {

    /// Where in a gesture this event falls.
    ///
    /// A trackpad gesture is `began` → `changed`… → `ended`, and then, if the user flicked,
    /// `momentum`… → `momentumEnded` after the fingers have left the glass. A mouse wheel has no
    /// phases at all and arrives as `discrete`, which is why this is one enum rather than the two
    /// `NSEvent.Phase` values kept side by side: a tracker that switched on `phase` alone would
    /// silently ignore every mouse user, and one that switched on `momentumPhase` alone would
    /// ignore every trackpad user who did not flick.
    public enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case canceled
        /// Fingers are off the glass and the system is still sending deltas. This is the flick.
        case momentum
        case momentumEnded
        /// A mouse wheel notch: no gesture around it, so it is its own beginning and end.
        case discrete
    }

    public var phase: Phase

    /// Points, already carrying the user's "natural scrolling" preference — AppKit inverts
    /// `scrollingDeltaX` for us. Deliberately *not* corrected with `isDirectionInvertedFromDevice`:
    /// that would undo the setting the user chose, so a swipe would travel the opposite way from
    /// every other scrollable thing on their Mac.
    public var deltaX: CGFloat

    /// Points, with the same sign convention as `deltaX`: what a scroll view would scroll by.
    ///
    /// Read two ways. `SwipeTracker` and `IslandStowGesture` use it only to lock the axis and then
    /// ignore the gesture; `IslandCloseGesture` reads `upwardDeltaY`, below, because it needs the
    /// direction the *fingers* went.
    public var deltaY: CGFloat

    /// Whether the user has "natural" scrolling on — `NSEvent.isDirectionInvertedFromDevice`.
    ///
    /// Carried because the deltas above have already had it applied, and one gesture needs it back.
    /// A scroll follows the setting by definition; a **gesture** does not. Swiping three fingers up
    /// opens Mission Control on every Mac, whichever way that user's scrolling is set, and swiping
    /// up to put something away is the same kind of movement — a direction in the world rather than
    /// a request to move a document. Without this, the same flick would close the island on one
    /// machine and do nothing on the next, which is exactly the disagreement that made
    /// `IslandStowGesture` direction-agnostic.
    public var isDirectionInverted: Bool

    /// True for a trackpad (deltas are already points), false for a wheel notch (deltas are lines).
    public var isPrecise: Bool

    /// Seconds on the same monotonic base for every sample in a gesture, which is all velocity
    /// needs. `NSEvent.timestamp` is process uptime, not a wall clock.
    public var timestamp: TimeInterval

    public init(
        phase: Phase,
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        isPrecise: Bool = true,
        timestamp: TimeInterval = 0,
        isDirectionInverted: Bool = false
    ) {
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.timestamp = timestamp
        self.isDirectionInverted = isDirectionInverted
    }

    /// How far the fingers moved **up** the glass, in points. Negative means down.
    ///
    /// With "natural" scrolling on — the default — AppKit reports a finger moving up as a negative
    /// `scrollingDeltaY`, because the content is being pushed up with it. With the setting off the
    /// deltas are already inverted and the same finger reports positive. Undoing the setting here is
    /// what makes "swipe up" one movement rather than two opposite ones, and it is deliberately the
    /// only place in Isleta that undoes it: everything else in the app either follows the user's
    /// scrolling preference or does not care which way it points.
    public var upwardDeltaY: CGFloat {
        isDirectionInverted ? -deltaY : deltaY
    }
}

extension IslandScrollSample {

    /// Reads a scroll event, or nil for the phases a swipe has nothing to do with.
    ///
    /// `.mayBegin` is the user resting two fingers on the trackpad without moving them, and
    /// `.stationary` is the same thing mid-gesture; both are dropped here rather than in the
    /// tracker, so a gesture that never moves never opens one.
    public init?(_ event: NSEvent) {
        let phase: Phase
        if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.cancelled) {
            phase = .canceled
        } else if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
            phase = .momentum
        } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            phase = .momentumEnded
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            phase = .discrete
        } else {
            return nil
        }

        self.init(
            phase: phase,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp,
            isDirectionInverted: event.isDirectionInvertedFromDevice
        )
    }
}
