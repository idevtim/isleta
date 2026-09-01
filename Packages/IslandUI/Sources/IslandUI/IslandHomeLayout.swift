import CoreGraphics
import Foundation
import IslandActivities
import IslandKit

/// Where the home page's two columns go: what is playing on the left, the day on the right.
///
/// Pure arithmetic, in its own type for the reason `GlanceLayout` and `ActivitySlotLayout` are: the
/// split is the part with a decision in it, and it should be checkable without a renderer.
///
/// ## Why two columns rather than two pages
///
/// The music page and the weather page each answer one question, and a page that answered "what have
/// I got on" would have been a third of the same shape. Home is deliberately not that: it is the
/// page the island *opens* on, and the thing a person opens the notch to find out is some
/// combination of the time, the next thing in their day, and what is playing. Splitting it puts both
/// halves of that in one glance, which is the whole argument for the surface — a home page that made
/// you swipe to see the other half would be two pages wearing one name.
///
/// The music column is deliberately the **smaller** of the two. It is a reminder and a set of
/// transport controls, not the player: the player is one swipe away and has the artwork, the
/// scrubber and the times. What earns its place here is that the buttons are reachable without
/// leaving the page the calendar is on.
public enum IslandHomeLayout {

    // MARK: - The box

    /// Matches every other body in the island, so the two columns line up with the text column of
    /// whatever the user swiped away from.
    public static let horizontalPadding: CGFloat = ActivityExpandedHeight.horizontalPadding

    /// Air between the cutout and the content. The body starts below the hole, never against it.
    public static let topPadding: CGFloat = GlanceLayout.topPadding

    public static let bottomPadding: CGFloat = GlanceLayout.bottomPadding

    // MARK: - The split

    /// How wide the music column is, as a fraction of the space the two columns share.
    ///
    /// A fraction rather than a constant, so the split survives `IslandLayout.expandedBodySize.width`
    /// changing — which it has, and which is exactly the sort of change that leaves a hard-coded
    /// column looking centred on the old width.
    ///
    /// 0.42 rather than half. The calendar column carries three rows of text and has to be the wider
    /// of the two or its titles truncate at the point they stop being useful; the music column
    /// carries a 60pt cover and three transport buttons, both of which are fixed-size and neither of
    /// which gets better with more room.
    public static let musicColumnFraction: CGFloat = 0.42

    /// The hairline between the columns, and the air either side of it.
    ///
    /// A rule rather than a gap, because the two halves are different *subjects* rather than two
    /// paragraphs of one — and at this width a gap wide enough to read as a separation is width
    /// taken off the event titles. One point, at the lowest alpha that still separates them — see
    /// `IslandHomeLayerView`, which has the number and why it is that low.
    public static let dividerWidth: CGFloat = 1

    public static let dividerSpacing: CGFloat = 14

    /// The room the two columns share, once the padding and the rule have had theirs.
    public static func columnsWidth(bodyWidth: CGFloat) -> CGFloat {
        max(0, bodyWidth - 2 * horizontalPadding - dividerWidth - 2 * dividerSpacing)
    }

    public static func musicColumnWidth(bodyWidth: CGFloat) -> CGFloat {
        (columnsWidth(bodyWidth: bodyWidth) * musicColumnFraction).rounded()
    }

    public static func calendarColumnWidth(bodyWidth: CGFloat) -> CGFloat {
        columnsWidth(bodyWidth: bodyWidth) - musicColumnWidth(bodyWidth: bodyWidth)
    }

    // MARK: - The music column

    /// The cover, or the placeholder well where there is no cover.
    ///
    /// **52 — 44, then 60, then here, all on sight of it on 2026-08-28.** At 44 the cover was the
    /// smallest thing in the column and a record sleeve read as an icon; at 60 it was the largest
    /// and the two lines under it read as a caption on a picture rather than as what is playing.
    /// 52 is the size at which the cover and the words are plainly the same statement, and the 8pt
    /// it gave back went to the type rather than to the air.
    ///
    /// Bounded above by `musicColumnWidth` (~127pt) and, through `musicColumnHeight`, by the full
    /// calendar column — `HomeLayoutTests` asserts both.
    public static let artworkSide: CGFloat = 52

    /// Air under the cover, above the title.
    public static let artworkSpacing: CGFloat = 8

    /// One line for the track, one for the artist. Two lines rather than the player's three: there is
    /// no album here, which is the field that is most often absent and least often looked for.
    ///
    /// **16 and 14, up from 15 and 13 with the type inside them**, 2026-08-28. The words were a
    /// point smaller than the player's on the argument that this column has a third of the width to
    /// say the same thing in — and that was the wrong lever: the width problem is answered by
    /// `MarqueeText`, which scrolls, and shrinking the type on top of it made the one line a person
    /// actually reads the quietest thing on the page. The title goes to 13 and the artist to 12,
    /// which is the player's own artist size exactly; the title stays under the player's 15 because
    /// this one is a reminder beside a calendar and that one is the page about the track. These two
    /// heights are the line boxes that hold them.
    public static let titleLineHeight: CGFloat = 16

    public static let artistLineHeight: CGFloat = 14

    /// The type inside the two lines above. The player's sizes exactly — see `titleLineHeight`.
    public static let titleFontSize: CGFloat = 13

    public static let artistFontSize: CGFloat = 12

    public static let titleBlockSpacing: CGFloat = 1

    public static var titleBlockHeight: CGFloat {
        titleLineHeight + titleBlockSpacing + artistLineHeight
    }

    /// The audio badge's own row, under the artist.
    ///
    /// **18, because Apple's badges are 18 and a trademark is not ours to shrink** — see
    /// `AudioFormatBadge`, which borrows them from Music rather than shipping a copy.
    ///
    /// **Counted only when there is a badge**, which is the awkward half of putting it on a row of
    /// its own and is why `musicColumnHeight` takes a parameter rather than being a constant. The
    /// alternatives were both worse: reserving the row always leaves an empty 20pt strip under the
    /// artist and pushes the transport down for a line that never arrives, and sharing the artist's
    /// row — which is what the track lip does — costs the artist 60pt of a 127pt column.
    ///
    /// What it buys, and the cost is real: the open island's height now depends on whether *this*
    /// track's format is known. In practice it is known for every Apple Music track, so the height
    /// is stable in use; where it is not, the change lands on a track change rather than under a
    /// resting pointer, and the transition widens the hit region before it moves and tightens after.
    public static let formatLineHeight: CGFloat = 18

    public static let formatLineSpacing: CGFloat = 2

    /// Air between the words and the buttons.
    public static let transportSpacing: CGFloat = 10

    /// The row's height, matching the player's own (`NowPlayingExpandedLayout.transportButtonSize`).
    public static let transportRowHeight: CGFloat = 30

    /// One transport button's box.
    ///
    /// **The player's own 38×30, which is the ceiling and not a coincidence.** The first version was
    /// 30×26 on the argument that this is a secondary control on a page about something else — and
    /// that was wrong twice: it is the control people reach for without leaving their day, which
    /// makes it the *most* used transport in the app, and a button smaller than the one a swipe away
    /// reads as a different, lesser control rather than the same one. It went to 36×30 on that, and
    /// to the full 38 on 2026-08-28 once the cover above it grew — under a 60pt cover the row was
    /// visibly the smallest thing in the column.
    ///
    /// **The row is now within a point of the column, and that is the constraint to read before
    /// touching either number here.** Three buttons at 38 plus two 6pt gaps is 126pt against
    /// `musicColumnWidth`'s 127. Widening further means narrowing `transportButtonSpacing` by the
    /// same amount, exactly as `NowPlayingExpandedLayout` documents for its own row — and the row is
    /// *centred*, so one too wide does not overflow visibly, it silently stops being centred.
    /// `transportRowWidth` is asserted against the column so that cannot ship.
    ///
    /// The height is the player's and is asserted equal to it. It is what makes the two rows read as
    /// one control in two places rather than a control and a lesser copy, and it is the reason this
    /// grew sideways and in the glyph rather than in every direction.
    public static let transportButtonSize = CGSize(width: 38, height: 30)

    /// Tighter than the player's 12: the column is half an island wide and the player's row is laid
    /// out across a whole one, with four secondary controls in it that this row does not carry.
    ///
    /// It is now the only slack the row has — see `transportButtonSize`, which cannot widen again
    /// without this narrowing.
    public static let transportButtonSpacing: CGFloat = 6

    /// The corner the hover wash is drawn with — the player's own number, because it is the same
    /// control and a different radius on it would read as a different one.
    public static let transportHoverCornerRadius: CGFloat = NowPlayingExpandedLayout.transportHoverCornerRadius

    /// The glyph inside the outer two buttons, and the middle one.
    ///
    /// **A step below the player's 18 and 24, and it was briefly a step above.** At rest a transport
    /// button *is* its glyph — the frame is a press target and the wash only appears under the
    /// pointer — so this row was raised from the player's own 15 and 19 when the cover above it grew
    /// and left it reading small. The player was then raised past it on the same argument, which is
    /// the right way round: this row is a reminder beside a calendar, and that one is the page about
    /// the track.
    ///
    /// Bounded by the box rather than by taste: a 22pt `play.fill` inside a 38×30 frame still keeps
    /// several points of air on every side, which is what stops the wash reading as a button with a
    /// glyph jammed into it.
    public static let transportGlyphSize: CGFloat = 17

    public static let playGlyphSize: CGFloat = 22

    /// How wide the three buttons and their gaps come to.
    ///
    /// Pinned against `musicColumnWidth` by a test rather than checked by eye: the row is centred, so
    /// one too wide does not overflow visibly — it silently stops being centred, which is the kind
    /// of thing that ships.
    public static var transportRowWidth: CGFloat {
        transportButtonSize.width * 3 + transportButtonSpacing * 2
    }

    /// How tall the music column wants to be.
    ///
    /// - Parameter hasAudioFormat: whether the playing track has a badge to draw under the artist.
    ///   See `formatLineHeight` for why this is a parameter and not a constant.
    public static func musicColumnHeight(hasAudioFormat: Bool = false) -> CGFloat {
        artworkSide
            + artworkSpacing
            + titleBlockHeight
            + (hasAudioFormat ? formatLineSpacing + formatLineHeight : 0)
            + transportSpacing
            + transportRowHeight
    }

    // MARK: - The calendar column

    /// The weekday, over the date. Two lines, the way a calendar icon is two lines, because that is
    /// the shape a person recognises without reading it.
    public static let weekdayHeight: CGFloat = 13

    public static let dateHeight: CGFloat = 40

    public static let dateBlockSpacing: CGFloat = 0

    public static var dateBlockHeight: CGFloat { weekdayHeight + dateBlockSpacing + dateHeight }

    /// Air under the date, above the events.
    public static let dateSpacing: CGFloat = 8

    /// One event, drawn as a pill rather than as the glance's time-plus-title row.
    ///
    /// The column is too narrow for a fixed time gutter — `GlanceLayout.timeColumnWidth` is 58pt of
    /// a 368pt body, which is most of this column — so the time goes inside the pill with the title,
    /// and the calendar's colour becomes the pill rather than a dot beside it.
    ///
    /// **24, up from 22, for the badge.** A capsule has to be taller than the disc it carries by
    /// enough to read as carrying it; at 22 an 18pt badge was a disc with a hairline of pill around
    /// it. See `eventBadgeSide`.
    public static let eventHeight: CGFloat = 24

    public static let eventSpacing: CGFloat = 4

    /// The disc at the pill's leading edge, in the calendar's own colour at full strength.
    ///
    /// **A disc rather than the 7pt dot it replaced, 2026-08-28.** The dot was the calendar's colour
    /// used the way a legend uses it — a mark you check when you are already asking which calendar
    /// this is. A pill three of which stack in a 127pt column is not read that way: the eye takes
    /// the row as one object, and the colour has to be part of the object rather than a note
    /// attached to it. At 18pt in a 24pt capsule the disc is the thing that gives the row its
    /// identity from across the room, which is what a glance surface is for.
    ///
    /// It is also what makes the *ground* safe to keep dim. The colour is now stated once at full
    /// strength, so the capsule behind it does not have to carry the identity and can stay at the
    /// alpha that keeps three stacked pills from reading as three coloured bars.
    public static let eventBadgeSide: CGFloat = 18

    /// The glyph knocked out of the disc, where the event has a meeting to join.
    ///
    /// Only there. An event with no link gets a plain disc rather than a generic calendar glyph:
    /// a symbol that is the same on every row says nothing, and it would spend the one piece of
    /// information the badge can hold on repeating the surface's own name.
    public static let eventBadgeGlyphSize: CGFloat = 9

    /// Air between the disc and the leading edge of the capsule, and between the disc and the words.
    ///
    /// The inset is `(eventHeight - eventBadgeSide) / 2` by construction rather than by choice —
    /// anything else puts the disc off the capsule's vertical centre while looking deliberate.
    public static var eventBadgeInset: CGFloat { (eventHeight - eventBadgeSide) / 2 }

    public static let eventBadgeSpacing: CGFloat = 6

    /// Air between the words and the capsule's trailing edge. More than the leading inset, because
    /// the words end in a truncation more often than not and text running to the curve reads as
    /// clipped by the shape rather than by the column.
    public static let eventTextInset: CGFloat = 10

    /// How many events fit before the column starts saying "and N more".
    ///
    /// Three, matching `GlanceLayout.maximumRows`, so swiping between the day here and the month
    /// grid does not change how much of the day is on screen.
    public static let maximumEvents = GlanceLayout.maximumRows

    /// The "+N more" line under the events, when there are more than fit.
    public static let overflowHeight: CGFloat = 18

    public static let overflowSpacing: CGFloat = 4

    // MARK: - When there is no calendar to read

    /// The sentence under the date when Isleta cannot read the calendar, and the button under it.
    ///
    /// **A day with no events and a calendar Isleta was refused look identical, and the column has
    /// to say which.** An empty column under a date is a person's clear afternoon; it is also every
    /// refused install, and shipping the first reading of the second is the app quietly pretending
    /// to work. `CalendarAccess` is the only thing that can tell them apart — see its
    /// `emptyStateMessage`, which is where the words are.
    ///
    /// Two lines, because every sentence but `granted`'s is longer than this column is wide.
    public static let accessMessageLineHeight: CGFloat = 13

    public static let accessMessageLines = 2

    public static var accessMessageHeight: CGFloat {
        CGFloat(accessMessageLines) * accessMessageLineHeight
    }

    /// The one control: the prompt where it can still be raised, the pane where it cannot.
    public static let accessButtonHeight: CGFloat = 20

    public static let accessButtonSpacing: CGFloat = 7

    /// How much the notice adds under the date, for a given state of the permission.
    ///
    /// **Zero for `granted`, and a height *without* the button for the states that have none.** A
    /// constant that reserved the button everywhere would leave 27pt of nothing under the sentence
    /// on a managed Mac — which is the one configuration where the user can do least about it and
    /// so the one where a gap reads most like a bug.
    public static func accessNoticeHeight(for access: CalendarAccess) -> CGFloat {
        guard !access.isReadable else { return 0 }
        var height = dateSpacing + accessMessageHeight
        if access == .notDetermined || access.canBeGrantedInSettings {
            height += accessButtonSpacing + accessButtonHeight
        }
        return height
    }

    /// How tall the calendar column wants to be, for a given number of events.
    ///
    /// - Parameter access: what the calendar is *allowed* to say. Its own parameter rather than
    ///   inferred from `eventCount == 0`, for the reason `accessNoticeHeight` states: no events and
    ///   no permission are the same number and different columns.
    public static func calendarColumnHeight(
        eventCount: Int,
        hasOverflow: Bool,
        access: CalendarAccess = .granted
    ) -> CGFloat {
        let shown = min(max(0, eventCount), maximumEvents)
        var height = dateBlockHeight
        if shown > 0 {
            height += dateSpacing
            height += CGFloat(shown) * eventHeight + CGFloat(shown - 1) * eventSpacing
        }
        if hasOverflow {
            height += overflowSpacing + overflowHeight
        }
        return height + accessNoticeHeight(for: access)
    }

    // MARK: - The height the island opens to

    /// How much drawable body the home page needs, below the cutout.
    ///
    /// The **taller** of the two columns, which is what makes the divider run the full height of the
    /// content rather than stopping short of one side. Both columns are laid out from the top, so
    /// the shorter one simply has air beneath it — deliberately, because centring the music column
    /// against a calendar whose height moves with the day would make the transport buttons drift up
    /// and down as events come and go.
    ///
    /// A **settled** number for a given day, like every other body in this island: `islandPath`
    /// tracks a shape that has stopped changing, so a height that followed anything live would move
    /// the island's bottom edge — and the clickable region with it — while somebody was reading it.
    public static func contentHeight(
        eventCount: Int,
        hasOverflow: Bool,
        access: CalendarAccess = .granted,
        hasAudioFormat: Bool = false
    ) -> CGFloat {
        let columns = max(
            musicColumnHeight(hasAudioFormat: hasAudioFormat),
            calendarColumnHeight(
                eventCount: eventCount, hasOverflow: hasOverflow, access: access
            )
        )
        return topPadding + columns + bottomPadding
    }

    /// The height with nothing in the calendar at all — the music column's, which is the floor.
    public static var emptyContentHeight: CGFloat {
        contentHeight(eventCount: 0, hasOverflow: false)
    }
}
