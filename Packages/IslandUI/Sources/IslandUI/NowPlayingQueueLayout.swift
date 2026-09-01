import CoreGraphics
import Foundation
import IslandKit

/// Where the Up Next list draws inside the open island, and how far it can scroll.
///
/// A **fixed** body height, like `NowPlayingExpandedLayout` and `ShelfLayout` and unlike a
/// notification's. Two consequences, and both are load-bearing rather than tidy:
///
/// - The island does not resize as the queue window grows. The window *does* grow — a reader who
///   scrolls to the bottom causes a wider ask down the helper's control channel — and an island
///   that grew with it would move its own bottom edge under a pointer that is on it, through the
///   widen-then-tighten protocol, every time a page landed.
/// - **The two tabs are the same height.** Up Next and Output draw rows of the same geometry into
///   the same rectangle, so switching between them moves nothing. `islandPath` has to track a
///   settled shape, and a tab that resized the island would be a second reason for the outline to
///   move that has nothing to do with what is playing.
public enum NowPlayingQueueLayout {

    public static let horizontalPadding: CGFloat = NowPlayingExpandedLayout.horizontalPadding

    /// Air above the header. Below the cutout, so the list does not start against the hole.
    public static let topPadding: CGFloat = 12

    /// The strip carrying the two tabs, the speed chip and the ✕.
    ///
    /// The ✕ is not decoration here for the same reason the drop history's is not: this surface is
    /// a *task* — deciding what to listen to next — and the click that puts the caret back in the
    /// user's editor is part of that task rather than an answer to it. So it keeps its ground while
    /// the rest of the island does not, and the ways out are inside it: the ✕, Escape, and playing
    /// something.
    public static let headerHeight: CGFloat = 22

    public static let headerSpacing: CGFloat = 6

    /// One row: a title on top and the artist under it.
    ///
    /// 36 rather than the drop history's 44 because a queue row is two short lines and a
    /// notification row is a title plus two lines of body. Matching them would put three rows on
    /// screen where four fit.
    public static let rowHeight: CGFloat = 36

    public static let rowSpacing: CGFloat = 4

    /// The number well at the leading edge of a queue row, and the glyph well of an output row.
    ///
    /// One constant for both, which is what keeps the two tabs the same shape: the eye reads the
    /// list as one surface changing its contents rather than as two lists of different widths.
    public static let symbolSide: CGFloat = 22

    public static let symbolSpacing: CGFloat = 10

    /// How many rows are on screen at once.
    ///
    /// Four. The ceiling is the island rather than the queue — the window holds up to
    /// `NowPlayingQueuePaging.maximumWindow`, and the rest is reached by scrolling. Five rows would
    /// put the open island at 240pt of body, which is taller than the drop history and taller than
    /// anything else the island grows to for something the user did not ask to read.
    public static let visibleRows = 4

    /// The rows' own rectangle: what is on screen at once, and what the scroll moves behind.
    public static var viewportHeight: CGFloat {
        CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows - 1) * rowSpacing
    }

    /// The height every row would need if they were all drawn at once.
    public static func contentExtent(rowCount: Int) -> CGFloat {
        let rows = max(0, rowCount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    /// How far this list can scroll. Zero for a list that fits, which is what makes the indicator
    /// and the gesture both disappear on a short queue without either asking.
    public static func scrollExtent(rowCount: Int) -> CGFloat {
        max(0, contentExtent(rowCount: rowCount) - viewportHeight)
    }

    /// The deepest row the reader can currently see, given the scroll offset.
    ///
    /// This is what the paging is driven from — `NowPlayingQueuePaging.window(lastVisibleRow:isOpen:)`
    /// — so it lives beside the geometry it is derived from rather than in the app shell, where it
    /// would be a second copy of the row height that could disagree with this one.
    ///
    /// Rounded **down** and then bounded below by the viewport's own row count: a list scrolled to
    /// exactly the top still has four rows on screen, and a half-visible row at the bottom counts,
    /// because a reader can see enough of it to want the one after.
    public static func lastVisibleRow(offset: CGFloat, rowCount: Int) -> Int {
        let stride = rowHeight + rowSpacing
        guard stride > 0 else { return max(0, rowCount - 1) }
        let firstVisible = Int((max(0, offset) / stride).rounded(.down))
        let last = firstVisible + visibleRows
        return max(visibleRows - 1, last)
    }

    /// The height this surface needs below the cutout, excluding the switcher row underneath it.
    ///
    /// **Constant, and deliberately not sized to the row count**, which is the opposite of what the
    /// drop history does. That list is bounded and never gains a row while it is being
    /// read without the user having been sent something; this window *grows on its own* as the
    /// reader scrolls, so a height derived from the count would resize the island as a consequence
    /// of reading it.
    ///
    /// A queue shorter than four rows still reserves four. The alternative is an island that grows
    /// by a row as the user scrolls into the second page, which is precisely the case above.
    public static var contentHeight: CGFloat {
        topPadding + headerHeight + headerSpacing + viewportHeight + bottomPadding
    }

    /// How much of a given content height is left for rows, once the header and padding have had
    /// theirs. The inverse of `contentHeight`, so the view can ask the box how big it is rather
    /// than restate the arithmetic that sized it.
    public static func rowsHeight(inContentHeight content: CGFloat) -> CGFloat {
        max(0, content - topPadding - headerHeight - headerSpacing - bottomPadding)
    }

    public static let bottomPadding: CGFloat = 8

    /// The scroll indicator down the trailing edge. Nil when the list fits, so a short queue draws
    /// no chrome at all.
    public static func indicator(offset: CGFloat, rowCount: Int) -> (length: CGFloat, top: CGFloat)? {
        let extent = scrollExtent(rowCount: rowCount)
        guard extent > 0 else { return nil }
        let content = contentExtent(rowCount: rowCount)
        let length = max(indicatorMinimumLength, viewportHeight * (viewportHeight / content))
        let travel = viewportHeight - length
        let progress = min(max(0, offset / extent), 1)
        return (length, travel * progress)
    }

    public static let indicatorWidth: CGFloat = 2

    public static let indicatorMinimumLength: CGFloat = 24

    /// The gutter the rows leave clear for the indicator, whether or not there is one today. A
    /// gutter that appeared once the queue passed four rows would shift the duration column
    /// sideways as a page landed.
    public static let indicatorLane: CGFloat = 12
}

/// How far the Up Next list is scrolled.
///
/// ## Why this is not `RecentsScroll`
///
/// The arithmetic is nearly the same and the ownership is not. `RecentsScroll` clamps against an
/// extent that only changes when a notification arrives or the user clears one; this clamps against
/// an extent that **grows as a consequence of scrolling**, because reaching the bottom is what asks
/// the helper for another page. Sharing one type would mean one of the two carried a rule the other
/// must never apply, which is the shape of thing this codebase splits rather than parameterises —
/// see `IslandPresentation` on why two spellings of one state is the bug and not the fix.
///
/// What *is* shared, verbatim, is the mechanism in the view: a `ScrollView` with
/// `.scrollDisabled(true)` driven by `.scrollPosition(_:)`. That is not a preference. Inside the
/// island's hosting view a SwiftUI clip does not contain scrolled text, images or buttons — nine
/// combinations of `.clipped()`, `.clipShape`, `.mask`, `.compositingGroup()` and `.drawingGroup()`
/// were each measured letting rows draw straight over the header, while a plain `Rectangle`
/// overflowing the same container by the same amount was clipped exactly. A scroll view's clipping
/// is structural rather than a request.
///
/// Pure, like the gestures, so the clamping and the wheel conversion are testable with no trackpad
/// and no music.
public struct NowPlayingQueueScroll: Equatable, Sendable {

    /// Points the content has been moved up by. Zero is the track that is playing.
    public private(set) var offset: CGFloat = 0

    public init() {}

    /// Takes one sample and returns where the list now sits.
    ///
    /// **`deltaY`, never `upwardDeltaY`.** This is the second place in Isleta where the user's
    /// "natural scrolling" preference is obeyed rather than undone, and for the same reason as the
    /// first: a list is a document being moved under a window, which is exactly what that setting
    /// is about. The three *gestures* undo it because a flick to put something away is a direction
    /// in the world; a scroll is not.
    @discardableResult
    public mutating func consume(_ sample: IslandScrollSample, extent: CGFloat) -> CGFloat {
        switch sample.phase {
        case .began:
            break
        case .changed, .momentum, .discrete:
            let travel = sample.isPrecise ? sample.deltaY : sample.deltaY * SwipeMetrics().lineTravel
            offset -= travel
        case .ended, .canceled, .momentumEnded:
            break
        }
        return clamped(to: extent)
    }

    /// Pulls the offset back inside a list that has changed size.
    ///
    /// Called on every sample and again whenever the window changes, because both can invalidate
    /// it. Note the direction that matters here and not in the drop history: the extent normally
    /// *grows* under the reader, because reaching the bottom is what asked for more — so the common
    /// case is an offset that was legal and is now short of the end, which needs no correction at
    /// all. The clamp is for the other direction: a track change re-vends the window from the new
    /// current track, and a queue that got shorter would otherwise leave the viewport on nothing.
    @discardableResult
    public mutating func clamped(to extent: CGFloat) -> CGFloat {
        offset = min(max(0, offset), max(0, extent))
        return offset
    }

    /// Back to the current track. What opening the surface does, and what a track change does —
    /// index 0 has moved, so everything the reader was looking at means something else now.
    public mutating func reset() { offset = 0 }
}
