import CoreGraphics
import Foundation
import IslandActivities
import IslandKit

/// Where the glance draws inside the open island, and how tall it asks the island to be.
///
/// ## Why this type exists rather than `ActivityExpandedHeight` answering
///
/// `ActivityKind.glance.sizesOpenIslandToContent` is **false**, and the reason is written on that
/// table: the generic measurement can see a title, a subtitle and a value, and the glance draws a
/// day — a header, a weather chip, and up to three rows with their own time column and color dot.
/// Measured generically the island would be sized to a caption and clip the thing the caption is
/// about.
///
/// The obligation that comes with taking that escape hatch is the one `NowPlayingExpandedLayout`
/// carries and states: **agree a height and hold it.** `IslandController.expandedContentHeight` is
/// read *before* the transition, by `widenHitRegionForTransition`, so a body that decided its own
/// height while it was drawing would leave the island accepting clicks in a region that is a
/// **subset** of what is painted — clicks landing on lit island, reaching us, and being dropped.
/// Everything below is therefore arithmetic on a row count, and the row count is fixed at the moment
/// the activity is published.
///
/// ## Two heights, because there are two kinds
///
/// `.glance` is the day. `.meeting` is one event and a button, and it opens the island unasked —
/// so it gets a shape of its own rather than a day list with two empty rows in it.
public enum GlanceLayout {

    /// Matches the text column every other body draws against.
    public static let horizontalPadding: CGFloat = ActivityExpandedHeight.horizontalPadding

    /// Air between the cutout and the header. The body starts below the hole, never against it.
    public static let topPadding: CGFloat = 12

    /// The strip carrying the day on the left and the weather on the right.
    ///
    /// One strip for both, rather than a weather card of its own beneath the events. A separate card
    /// would push the third event out of a 400pt ceiling to say two things — a glyph and a number —
    /// that fit beside "Today" with room to spare, and it would make the weather look like the point
    /// of a surface whose point is the calendar.
    public static let headerHeight: CGFloat = 22

    public static let headerSpacing: CGFloat = 8

    public static let rowHeight: CGFloat = 34

    public static let rowSpacing: CGFloat = 4

    public static let bottomPadding: CGFloat = 10

    /// The time column — "10:30", or "All day", which is the longer of the two and what this is
    /// sized for. Fixed rather than sized to its contents so the titles start at the same x on every
    /// row; a ragged left edge on three rows reads as a layout fault.
    public static let timeColumnWidth: CGFloat = 58

    public static let timeSpacing: CGFloat = 8

    /// The calendar's color, as a dot. Small: it is an index into a week the user already knows,
    /// not a status light.
    public static let dotSide: CGFloat = 6

    public static let dotSpacing: CGFloat = 7

    /// How many events the open island lists.
    ///
    /// Three, matching `GlancePolicy.maximumEvents`, and the ceiling is the island rather than the
    /// day: past three rows this stops reading as the notch having opened and starts reading as a
    /// calendar window bolted to one. It is also what keeps the glance shorter than the recents
    /// list, which is the other surface a user *reads* and is deliberately the taller of the two.
    public static let maximumRows = GlancePolicy.maximumEvents

    /// The Join button on a row, and the wide one on a `.meeting`.
    public static let joinButtonHeight: CGFloat = 22

    public static let joinButtonCornerRadius: CGFloat = 11

    /// How tall a list of `rowCount` events needs to be, below the cutout and above the switcher row.
    ///
    /// Clamped to at least one row's worth, because the empty state is a line of text that needs the
    /// same room — an island that shrank to its header to say "Calendar access is off" would put the
    /// sentence outside itself.
    public static func contentHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, min(rowCount, maximumRows))
        return topPadding
            + headerHeight
            + headerSpacing
            + rowsExtent(rowCount: rows)
            + bottomPadding
    }

    /// What the empty glance is worth: the header, and one row's worth of room for one sentence.
    public static var emptyContentHeight: CGFloat { contentHeight(rowCount: 0) }

    /// The height every row takes together.
    public static func rowsExtent(rowCount: Int) -> CGFloat {
        let rows = max(0, rowCount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    /// How much of a given content height is left for rows, once the header and padding have had
    /// theirs.
    ///
    /// The inverse of `contentHeight`, and it exists so the view can **ask** rather than assume. The
    /// two answer the same question in opposite directions and are pinned against each other by
    /// `GlanceLayoutTests`; where they ever disagree the drawn list has to give, because the island
    /// has already been sized and cannot grow to cover the difference. `DropHistoryLayout` learned this
    /// by slicing its fifth row in half with the island's own bottom edge while every test passed.
    public static func rowsHeight(inContentHeight content: CGFloat) -> CGFloat {
        max(0, content - topPadding - headerHeight - headerSpacing - bottomPadding)
    }

    // MARK: - The meeting

    /// The title and the "Starting now" under it.
    public static let meetingTitleHeight: CGFloat = 40

    public static let meetingSpacing: CGFloat = 10

    /// The wide Join button. Taller than the one on a row, because this is the only control on a
    /// surface that opened itself and the click is the entire reason it is there.
    public static let meetingButtonHeight: CGFloat = 32

    /// A single joinable meeting: a line of title, a line of when, and one button across the body.
    public static var meetingContentHeight: CGFloat {
        topPadding + meetingTitleHeight + meetingSpacing + meetingButtonHeight + bottomPadding
    }

    /// The height to open to for whichever of the two kinds is on stage, or nil for anything else.
    ///
    /// One entry point, so the app shell has a single question to ask and cannot answer it two ways.
    /// Nil rather than a default, matching `ActivityExpandedHeight.contentHeight` — a kind that does
    /// not size the island says so, instead of arriving at the default by a different route and
    /// leaving nobody able to tell a decision from a coincidence.
    public static func contentHeight(for kind: ActivityKind?, rowCount: Int) -> CGFloat? {
        switch kind {
        case .glance: contentHeight(rowCount: rowCount)
        case .meeting: meetingContentHeight
        default: nil
        }
    }
}
