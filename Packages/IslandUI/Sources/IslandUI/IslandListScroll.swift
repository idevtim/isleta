import CoreGraphics
import IslandActivities
import IslandKit

/// How far a list inside the island is scrolled, and the one gesture in Isleta that is a scroll.
///
/// Generic on purpose. It was `RecentsScroll`, written for the notification list and borrowed by
/// the drop history through a `typealias`; the list went with notifications and the borrower is now
/// the only caller, so the type takes the name it always deserved rather than keeping a subject it
/// no longer has.
///
/// ## Why the gesture is ours even though the list is drawn in a `ScrollView`
///
/// A scroll view here would never be sent a scroll event: `IslandHitTestView.scrollWheel` handles
/// the event and **deliberately does not call `super`** — the panel is never key, and walking the
/// responder chain from a non-key panel can reach `NSApp` and provoke activation — so nothing
/// reaches `NSHostingView`. An enabled one would also take the vertical axis inside the list's
/// rectangle only, leaving `IslandStowGesture` and `IslandCloseGesture` reading a different set of
/// samples depending on where the pointer happened to be. So the scroll view in
/// `DropHistoryLayerView`'s viewport is `scrollDisabled` and is there for its clipping alone; this
/// is where a scroll is interpreted, and it tells that view where to sit.
///
/// ## This is the one place natural scrolling is obeyed rather than undone
///
/// `IslandScrollSample.upwardDeltaY` exists for the gestures: swiping up to put something away is a
/// direction in the world, so it has to mean the same thing on two Macs configured differently.
/// **A list is the opposite case.** It is a document being moved under a window, which is exactly
/// what the user's "natural scrolling" preference is about, so this reads `deltaY` — already
/// carrying the setting — and never `upwardDeltaY`. Getting this backwards would make the island's
/// list the only scrollable thing on the machine that runs the wrong way.
///
/// Pure, like the three gestures, so the clamping and the wheel conversion are testable with no
/// trackpad and no window.
public struct IslandListScroll: Equatable, Sendable {

    /// Points the content has been moved up by. Zero is the newest row; `extent` is the oldest one
    /// the list still holds.
    public private(set) var offset: CGFloat = 0

    public init() {}

    /// Takes one sample and returns where the list now sits.
    ///
    /// - Parameter extent: how far this list *can* scroll — `DropHistoryLayout.scrollExtent(rowCount:)`.
    ///   Passed in on every sample rather than stored because rows arrive while the list is open:
    ///   the extent grows under the reader, and a stored copy would be one row stale at exactly the
    ///   moment the list got longer.
    @discardableResult
    public mutating func consume(_ sample: IslandScrollSample, extent: CGFloat) -> CGFloat {
        switch sample.phase {
        case .began:
            // Not a reset. A gesture starting is not a request to go back to the top, and the
            // trackpad routinely reports (0, 0) here anyway.
            break

        case .changed, .momentum, .discrete:
            // Momentum counts here, unlike in every gesture in this package. There it is the
            // trackpad's inertia arriving after a verdict has already been reached and refused;
            // here the verdict *is* the movement, and a list that stopped dead the instant the
            // fingers lifted would be the only one on the machine that did.
            let travel = sample.isPrecise ? sample.deltaY : sample.deltaY * SwipeMetrics().lineTravel
            // Subtracted: a positive `deltaY` is content moving down the screen, which is the list
            // moving *back towards* its newest row.
            offset -= travel

        case .ended, .canceled, .momentumEnded:
            break
        }
        return clamped(to: extent)
    }

    /// Pull the offset back inside a list that has changed size, and report it.
    ///
    /// Called on every sample and again whenever the entries change, because both can invalidate
    /// it: clearing the list, or clicking the row that was holding it open, can leave the offset
    /// pointing past the end at nothing.
    @discardableResult
    public mutating func clamped(to extent: CGFloat) -> CGFloat {
        offset = min(max(0, offset), max(0, extent))
        return offset
    }

    /// Back to the newest. What opening and closing the list both do — a list reopened where it was
    /// left is a list that opens on nothing new, which is the one thing it exists to show.
    public mutating func reset() { offset = 0 }
}


/// Where the list should be sitting, and whether it should travel there or simply be there.
///
/// A value rather than a bare `CGFloat` because the two cases are genuinely different and the view
/// cannot tell them apart from the number alone. A **drag** must land un-animated on every sample:
/// a spring between the fingers and the rows is a list that lags the hand, which is the one thing a
/// scroll must never do. An **arrival** — a row landing while the list is open — must
/// travel, with the bounce `Motion.nudge` carries, because the whole point is that the user sees
/// something new appear rather than finding the list silently rearranged.
///
/// `sequence` is what makes a repeat reach the view. Two arrivals in a row both target zero, and an
/// `onChange` watching the offset alone would see no change and play nothing for the second.
public struct IslandListScrollTarget: Equatable, Sendable {

    public var offset: CGFloat

    /// Whether getting there should be animated. False for every sample of a gesture.
    public var isAnimated: Bool

    /// Bumped on every push, so an unchanged offset still arrives as a change.
    public var sequence: Int

    public init(offset: CGFloat = 0, isAnimated: Bool = false, sequence: Int = 0) {
        self.offset = offset
        self.isAnimated = isAnimated
        self.sequence = sequence
    }

    /// The next target for a scroll gesture: here, now, no animation.
    public func dragged(to offset: CGFloat) -> Self {
        Self(offset: offset, isAnimated: false, sequence: sequence + 1)
    }

    /// The next target for a row arriving: the top, traveling.
    public func revealingNewest() -> Self {
        Self(offset: 0, isAnimated: true, sequence: sequence + 1)
    }
}

extension IslandListScroll {

    /// Whether a change to the list is a *new row* rather than one leaving.
    ///
    /// The head changed, **and the entry that used to be the head is still in the list** — pushed
    /// down by something that arrived above it. That second clause is doing the work: clicking the
    /// top row also changes the head, by removing it, and springing the list to the top to show the
    /// user the thing they just dismissed is both wrong and impossible to explain. Clearing leaves
    /// no head at all and is not an arrival either.
    ///
    /// **Not "the list got longer"**, which is the obvious rule and is wrong twice. It was wrong
    /// when the list behind this was a fixed-size ring — an arrival on a full list dropped the
    /// oldest and the count did not move, so that version shipped for one build and revealed
    /// nothing on exactly the list busy enough to need revealing. It is wrong on an unbounded list
    /// too, because a click removes a row and a length that fell by one and rose by one across the
    /// same two frames is an arrival the rule would miss. Asking about the *head* answers both
    /// without knowing which happened.
    public static func isArrival(
        previousHead: ActivityID?,
        head: ActivityID?,
        entries: [ActivityID]
    ) -> Bool {
        guard let head, head != previousHead else { return false }
        guard let previousHead else { return true }
        return entries.contains(previousHead)
    }
}
