import CoreGraphics
import Foundation

/// Where the drop history draws inside the open island.
///
/// ## A constant height
///
/// A list that sized itself to its contents would be reserving space it does not need, and would let
/// the resize stand in as feedback when a row lands. Neither is right here.
///
/// This list grows while it is open — a conversion the user started before opening it finishes and
/// appends a row — and it is a **record being read** rather than news arriving, so the island
/// changing height under a reader would be the surface moving its own bottom edge out from under a
/// pointer that is on it. That is `NowPlayingQueueLayout`'s exact situation and it takes
/// `NowPlayingQueueLayout`'s answer: a fixed rectangle, and the rows scroll inside it.
///
/// The obligation that comes with it, which `GlanceLayout` and `NowPlayingQueueLayout` both state:
/// **agree a height and hold it.** `IslandController.expandedContentHeight` is read *before* the
/// transition by `widenHitRegionForTransition`, so a height that moved afterwards would leave the
/// island painting pixels the hit test rejects. `ActivityKind.sizesOpenIslandToContent` already
/// answers false for `.fileAction`, describing "a scrolling record of what was converted" — this is
/// that record, and it sizes itself here rather than being measured from an activity's text.
public enum DropHistoryLayout {

    public static let horizontalPadding: CGFloat = ActivityExpandedHeight.horizontalPadding

    /// Air above the header, below the cutout, so the list does not start against the hole.
    public static let topPadding: CGFloat = 12

    /// The strip above the rows: what the list is, and the two controls that dismiss it.
    ///
    /// 22pt, which is the height every strip of chrome in the island carries its controls at, so
    /// the eye reads them as one piece rather than as several.
    public static let headerHeight: CGFloat = 22

    public static let headerSpacing: CGFloat = 6

    /// One row: a glyph well, two lines of text, an age.
    ///
    /// 44, and the number is set by what the second line can hold: the detail is a file name or a
    /// count, and both are one line by construction (`DropHistoryEntry.detail`), so this row never
    /// needs the extra couple of points a list of free-form text would.
    public static let rowHeight: CGFloat = 44

    public static let rowSpacing: CGFloat = 4

    /// The glyph well on each row.
    public static let symbolSide: CGFloat = 28

    public static let symbolSpacing: CGFloat = 10

    /// How many rows are on screen at once.
    ///
    /// Four. The list this one replaces on screen is usually the shelf, whose body is 178pt, and
    /// the surface a user opens *from the shelf* should not be half as tall again as the thing they
    /// opened it from. Four rows plus the header is 236pt, well inside
    /// `IslandLayout.maxExpandedBodySize`.
    public static let visibleRows = 4

    /// The rows' own rectangle: what is on screen at once, and what `DropHistoryScroll` moves behind.
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
    /// and the gesture both disappear on a short list without either asking.
    public static func scrollExtent(rowCount: Int) -> CGFloat {
        max(0, contentExtent(rowCount: rowCount) - viewportHeight)
    }

    /// Air below the last row, so it does not sit against the switcher row beneath it.
    public static let bottomPadding: CGFloat = 8

    /// What the open island opens to for this surface, below the cutout. **A constant** — see the
    /// note on the type.
    public static var contentHeight: CGFloat {
        topPadding + headerHeight + headerSpacing + viewportHeight + bottomPadding
    }

    /// How much of a given content height is left for rows, once the header and the padding have had
    /// theirs.
    ///
    /// The inverse of `contentHeight`, and it exists so the view can *ask* rather than assume. A
    /// view that recomputed the arithmetic instead agrees with this right up until it does not, and
    /// the way that fails on screen is the last row sliced in half by the island's own bottom edge
    /// while every test still passes.
    public static func rowsHeight(inContentHeight content: CGFloat) -> CGFloat {
        max(0, content - topPadding - headerHeight - headerSpacing - bottomPadding)
    }

    /// The scroll indicator down the trailing edge: a thumb whose length says how much list there is
    /// and whose position says where in it you are. Nil when everything fits.
    public static func indicator(offset: CGFloat, rowCount: Int) -> (length: CGFloat, top: CGFloat)? {
        let extent = scrollExtent(rowCount: rowCount)
        guard extent > 0 else { return nil }
        let content = contentExtent(rowCount: rowCount)
        // Proportional with a floor: forty rows in a four-row viewport would otherwise draw a thumb
        // a few points long, which reads as a speck of dust on a black island rather than as a
        // control.
        let length = max(indicatorMinimumLength, viewportHeight * (viewportHeight / content))
        let travel = viewportHeight - length
        let progress = min(max(0, offset / extent), 1)
        return (length, travel * progress)
    }

    public static let indicatorWidth: CGFloat = 2

    public static let indicatorMinimumLength: CGFloat = 24

    /// The gutter the rows leave clear for the indicator.
    ///
    /// Reserved on every row whether or not the list scrolls today: a gutter that appeared once the
    /// list passed four rows would shift the age column sideways as work finishes.
    public static let indicatorLane: CGFloat = 12

    /// The ✕ in the header, square, so it reads as the same control every other header draws.
    public static let headerControlSide: CGFloat = headerHeight

    /// The trailing button on a row — "Run again", or "Copy Link".
    public static let rowButtonSize = CGSize(width: 30, height: 26)
}
