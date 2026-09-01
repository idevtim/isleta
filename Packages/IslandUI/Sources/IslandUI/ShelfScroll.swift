import CoreGraphics
import IslandKit

/// How far the shelf's grid is scrolled.
///
/// The second scroll in Isleta, and it is a separate value from `RecentsScroll` rather than a
/// shared one for two reasons that are both about what a scroll *means* here:
///
/// - **The two lists run in opposite directions.** Recents is newest-first, so an arrival is
///   revealed by going back to zero. The shelf appends, so what just landed is at the *end* and the
///   reveal is a scroll to the extent — a number that depends on the layout and did not exist as a
///   concept in the other one.
/// - **The shelf only owns the vertical axis while it can use it.** The drop history takes the axis
///   unconditionally, which it can afford because it carries its own exits (Clear All, the ✕,
///   Escape). The shelf has none of those, so a shelf whose contents fit hands the axis back to
///   `IslandCloseGesture` and stays closable with a flick — see `SwipeController`.
///
/// What they do share is the physics, which is `IslandScrollSample`'s, and this file's one job:
/// clamping. Pure, like the three gestures, so both are testable with no trackpad and no window.
///
/// ## Natural scrolling is obeyed here, exactly as it is in every other list in the island
///
/// `IslandScrollSample.upwardDeltaY` exists for the gestures, where "up" is a direction in the
/// world and has to mean the same thing on two Macs configured differently. A grid is the opposite
/// case: it is a document being moved under a window, which is precisely what the user's "natural
/// scrolling" preference is about — so this reads `deltaY`, which already carries the setting, and
/// never `upwardDeltaY`.
public struct ShelfScroll: Equatable, Sendable {

    /// Points the grid has been moved up by. Zero is the first thing dropped on the shelf; `extent`
    /// is the most recent.
    public private(set) var offset: CGFloat = 0

    public init() {}

    /// Takes one sample and returns where the grid now sits.
    ///
    /// - Parameter extent: how far this grid *can* scroll — `ShelfLayout.scrollExtent`. Passed in on
    ///   every sample rather than stored, because a drop can land while the user is scrolling and
    ///   the extent grows underneath them; a stored copy would be one file stale at exactly the
    ///   moment the shelf got longer.
    @discardableResult
    public mutating func consume(_ sample: IslandScrollSample, extent: CGFloat) -> CGFloat {
        switch sample.phase {
        case .began:
            // Not a reset. A gesture starting is not a request to go back to the top, and the
            // trackpad routinely reports (0, 0) here anyway.
            break

        case .changed, .momentum, .discrete:
            // Momentum counts, as it does in every list and unlike in the three gestures.
            // There it is the trackpad's inertia arriving after a verdict has been reached and
            // refused; here the verdict *is* the movement, and a grid that stopped dead the instant
            // the fingers lifted would be the only scrollable thing on the machine that did.
            let travel = sample.isPrecise ? sample.deltaY : sample.deltaY * SwipeMetrics().lineTravel
            // Subtracted: a positive `deltaY` is content moving down the screen, which is the grid
            // moving back towards the file that was dropped first.
            offset -= travel

        case .ended, .canceled, .momentumEnded:
            break
        }
        return clamped(to: extent)
    }

    /// Pull the offset back inside a grid that has changed size, and report it.
    ///
    /// Called on every sample and again whenever the contents change, because both can invalidate
    /// it: removing the last two files, or a search narrowing thirty tiles to one, leaves the offset
    /// pointing past the end at a viewport of nothing — which reads as the shelf having been
    /// emptied by whatever the user just did.
    @discardableResult
    public mutating func clamped(to extent: CGFloat) -> CGFloat {
        offset = min(max(0, offset), max(0, extent))
        return offset
    }

    /// Back to the first thing on the shelf. What opening a search does: a filtered grid the user is
    /// looking at halfway down is a grid whose matches are mostly above the fold.
    public mutating func reset() { offset = 0 }

    /// To the end, where a drop lands.
    public mutating func revealEnd(extent: CGFloat) {
        offset = max(0, extent)
    }
}

/// Where the grid should be sitting, and whether it should travel there or simply be there.
///
/// A value rather than a bare `CGFloat` for the reason `RecentsScrollTarget` is one, and the two
/// cases are the same two: a **drag** must land un-animated on every sample, because a spring
/// between the fingers and the tiles is a grid that lags the hand; an **arrival** — a file dropped
/// while the shelf is open and scrolled — must travel, so the user sees where it went rather than
/// finding the grid silently rearranged.
///
/// `sequence` is what makes a repeat reach the view. Two drops in a row both target the end, and an
/// `onChange` watching the offset alone would play nothing for the second.
public struct ShelfScrollTarget: Equatable, Sendable {

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

    /// The next target for a file landing: the end of the grid, traveling.
    public func revealing(_ offset: CGFloat) -> Self {
        Self(offset: max(0, offset), isAnimated: true, sequence: sequence + 1)
    }
}
