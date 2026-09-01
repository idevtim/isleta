import CoreGraphics

/// Where the scrub bar and the three transport buttons sit inside the open island's body.
///
/// Pulled out of the view for one reason that is worth the file: **a control nobody can hit is a
/// control that does not exist**, and the only way to check that from outside SwiftUI is to be able
/// to name the point it occupies. `TransportSelfTest` synthesises a press at
/// `playButtonCenter(in:)` and asserts the command went out; `NowPlayingLayoutTests` asserts the
/// rows fit inside the body region on real hardware geometry. Both would be reduced to restating
/// the view's own arithmetic if these numbers lived only in the view.
///
/// Every value is a whole number of points, so the rows land on the pixel grid at 1x as well as 2x
/// (§6.6).
///
/// ## Why the two rows are measured from the bottom
///
/// The expanded body is a constant 380x140 minus the cutout — 108pt of drawable height — and the
/// title block above these rows is one or two lines depending on whether the track has an artist.
/// Laying the controls out from the *top* would move them by 15pt for a track with no artist tag,
/// which is a transport row that shifts under the pointer between songs. Anchored to the bottom they
/// are in the same place on every track, and the slack lands between the subtitle and the scrub bar
/// where nothing is looking at it.
public enum NowPlayingExpandedLayout {

    /// Matches `ActivityContentView.expanded`, so the open island's text starts on the same
    /// vertical line whichever renderer drew it.
    public static let horizontalPadding: CGFloat = 18

    public static let topPadding: CGFloat = 6

    // MARK: - The header row (artwork, title, equaliser)

    /// The cover in the open island's body.
    ///
    /// The body used to omit it, on the grounds that the leading flank is already showing the cover
    /// 40pt above and the real Dynamic Island does not repeat the collapsed pill's content. The
    /// reference the owner supplied settles it the other way: the expanded player leads with a large
    /// cover, and it is the first thing the eye lands on. The flank keeps its own copy for the
    /// collapsed state, which the reference does not cover.
    public static let artworkSide: CGFloat = 56

    /// Artwork to text.
    public static let headerSpacing: CGFloat = 10

    // MARK: - The title block
    //
    // The two lines beside the cover, and the one place in the open island where the text is
    // routinely wider than the room it has: a track title and an artist are whatever the record
    // says they are, and the column is ~230pt. They scroll (`MarqueeText`), which needs the room
    // stated rather than inferred — a layer-backed line has no intrinsic height for SwiftUI to
    // measure, so a `Text` that sized itself is replaced by a frame that has to be right.

    /// The title's line. 15pt bold, whose SF Pro line height is 18.
    public static let titleLineHeight: CGFloat = 18

    /// The artist's line — or the Up Next peek's, which takes the same row. 12pt, line height 15.
    public static let artistLineHeight: CGFloat = 15

    /// Between the two.
    public static let titleBlockSpacing: CGFloat = 2

    /// The format badge's line — a waveform and a word, under the artist.
    ///
    /// **Inside the header row rather than a fourth row in the body, and that is the whole reason
    /// this could be added at all.** `subtitleLine` spells out why the peek takes the artist's line
    /// instead of adding one: the body is three rows measured into a settled shape, and a fourth
    /// would move the island's bottom edge — and the region clicks are accepted in — under a pointer
    /// that may be resting on the transport. This line costs the island nothing, because the block
    /// beside a 56pt cover was only using 35 of it.
    ///
    /// **18, up from 13, and 18 is not a taste decision.** Apple's badges are 60×18 for Lossless,
    /// 57×18 for Hi-Res and 83×14 for Atmos, and at 13 they were being resampled down to about
    /// three-quarters — which on a wordmark is the difference between reading it and squinting at
    /// it. At 18 the two tall ones draw at exactly their design size and the short one is left at
    /// its own, so nothing is scaled and nothing is soft. See `AudioFormatBadge`.
    ///
    /// It is the ceiling as well as the size. The block with a badge is 55pt against a 56pt header
    /// row — one point of slack — and `NowPlayingTests` pins that, so the next increase fails the
    /// build rather than clipping a trademark on somebody's Mac.
    public static let formatLineHeight: CGFloat = 18

    public static let formatLineSpacing: CGFloat = 2

    /// What the block comes to, which has to fit inside `headerRowHeight` beside a cover of exactly
    /// that height. 50 against 56 — the block is centred in the row, as it was when both lines sized
    /// themselves. `NowPlayingTests` pins the comparison so a later type change fails the build
    /// rather than clipping a descender on somebody's Mac.
    ///
    /// **The badge's line is not counted here**, and that is a correction. It was, on the argument
    /// that a block sizing itself would walk the title and the artist up and down as a playlist
    /// crossed between a track whose format is known and one whose is not. What that actually did
    /// was leave 15pt of nothing under the artist on every track — which is most of them — and push
    /// the two lines that *are* always there up off the centre of the cover to make room for a line
    /// that never came. A gap held open for an absent thing is worse than the movement it prevents.
    public static var titleBlockHeight: CGFloat {
        titleLineHeight + titleBlockSpacing + artistLineHeight
    }

    /// The block with a badge under it. Still inside `headerRowHeight` — 50 against 56 — which is
    /// what let the badge exist without becoming a fourth row in the body and moving the island's
    /// bottom edge. See `NowPlayingSlotView.subtitleLine` for why a fourth row is not available.
    public static var titleBlockHeightWithFormat: CGFloat {
        titleBlockHeight + formatLineSpacing + formatLineHeight
    }

    /// The header is as tall as the artwork; the title block centers against it.
    public static var headerRowHeight: CGFloat { artworkSide }

    public static let bottomPadding: CGFloat = 8

    /// Tall enough for a 30x26 button target. The glyphs are 15 and 19pt; the rest is the target.
    public static let transportRowHeight: CGFloat = 32

    /// The scrub bar draws 4pt and grabs 20. See `NowPlayingScrubberView` — the drawn thing and the
    /// grabbable thing are deliberately different sizes.
    public static let scrubberRowHeight: CGFloat = 22

    /// Fixed, so the buttons stay centerd on the island rather than sliding sideways as a track
    /// crosses from "9:59" to "10:00".
    public static let timeLabelWidth: CGFloat = 38

    /// 42x30 — 34, then 38, then here, each time paid for out of `transportButtonSpacing`.
    ///
    /// The frame is the press target *and* the wash, so its width is a visible dimension rather than
    /// only a hittable one — see `transportHoverCornerRadius`. At this size the gap between two lit
    /// washes still reads as a gap, and 34pt of glyph with 8pt of air around it is a better target
    /// than 26 with 16.
    ///
    /// **The height is 30 and cannot simply follow the width.** `transportRowHeight` is 32, and the
    /// player is a fixed layout measured into a rectangle it agreed on in advance
    /// (`fits(in:)`) — a taller button is a taller row is a taller island, which is a different
    /// piece of work in `IslandLayout` rather than a number here.
    public static let transportButtonSize = CGSize(width: 42, height: 30)

    /// Gap between the buttons.
    ///
    /// 8, down from 12, which was down from 16, which was down from 24. The row grew from five
    /// controls to seven — a heart at the leading edge and Up Next at the trailing one — and at 24
    /// those seven need 382pt inside a 344pt column. The arithmetic that has to hold is written out because it is the thing
    /// a later change breaks silently: three primary buttons at `transportButtonSize.width` plus
    /// four secondary ones at `NowPlayingTransportView.secondaryWidth`, plus six gaps, must fit
    /// `expandedBodySize.width - horizontalPadding * 2`. `NowPlayingLayoutTests` asserts it, because
    /// a row that overflows is not merely ugly: it is clipped by the mask in `IslandRootView`, so a
    /// button is visibly shaved *and* invisibly unhittable.
    ///
    /// **This number and `transportButtonSize.width` must move in opposite directions by the same
    /// amount.** `skipButtonCenter` is one button plus one gap from the middle, so their *sum* is
    /// what places the previous/next controls — 50pt, unchanged across every version of this row,
    /// which is what leaves `playButtonCenter`, `skipButtonCenter` and the presses
    /// `TransportSelfTest` synthesises at those points describing the same buttons they always did.
    /// Widening the buttons without narrowing the gap would move two of the three targets the
    /// self-test aims at, and it would find them: it asserts the command went out, so the failure
    /// would be real rather than cosmetic.
    public static let transportButtonSpacing: CGFloat = 8

    /// The content column, inset from the body slot.
    ///
    /// - Parameter body: the body slot's rect, from `ActivitySlotLayout.frame(for: .expanded)`, in
    ///   the island body's own y-down space.
    public static func contentRect(in body: CGRect) -> CGRect {
        CGRect(
            x: body.minX + horizontalPadding,
            y: body.minY + topPadding,
            width: max(0, body.width - horizontalPadding * 2),
            height: max(0, body.height - topPadding - bottomPadding)
        )
    }

    /// The transport row: the bottom band of the content column.
    public static func transportRect(in body: CGRect) -> CGRect {
        let content = contentRect(in: body)
        return CGRect(
            x: content.minX,
            y: content.maxY - transportRowHeight,
            width: content.width,
            height: transportRowHeight
        )
    }

    /// The header row: artwork, title block, equaliser, across the top of the content column.
    public static func headerRect(in body: CGRect) -> CGRect {
        let content = contentRect(in: body)
        return CGRect(x: content.minX, y: content.minY, width: content.width, height: headerRowHeight)
    }

    /// The artwork well, at the leading edge of the header.
    public static func artworkRect(in body: CGRect) -> CGRect {
        let header = headerRect(in: body)
        return CGRect(x: header.minX, y: header.minY, width: artworkSide, height: artworkSide)
    }

    /// The scrub bar's **grabbable** row, centerd in the space between the header and the transport
    /// row.
    ///
    /// It used to sit immediately above the transport row, with all the slack collected above it.
    /// That was fine when the open island was 140pt tall and there was barely any slack; at 176 the
    /// bar ended up crowding the buttons with a gulf above it. Centring puts equal air on both
    /// sides, which is what the eye reads as deliberate.
    ///
    /// This rect is what a drag is measured against, so the view lays the row out the same way — two
    /// equal spacers — rather than by its own arithmetic. A bar drawn anywhere other than here is a
    /// bar that seeks from somewhere the pointer is not.
    public static func scrubberRect(in body: CGRect) -> CGRect {
        let content = contentRect(in: body)
        let header = headerRect(in: body)
        let transport = transportRect(in: body)
        let slack = max(0, transport.minY - header.maxY - scrubberRowHeight)
        // Inset by a time label at each end, because the view puts the elapsed and remaining times
        // either side of the bar. Measured, not assumed: the bar reports 240pt inside a 332pt
        // content column, which is exactly two labels and their gaps. This rect is what a drag is
        // measured against, so claiming the full column made a drag to 75% seek to 84%.
        let inset = timeLabelWidth + timeLabelSpacing
        return CGRect(
            x: content.minX + inset,
            y: header.maxY + slack / 2,
            width: max(0, content.width - inset * 2),
            height: scrubberRowHeight
        )
    }

    /// The full row the scrub bar and its two time labels share.
    /// The full row the bar and its two time labels share.
    public static func scrubberRowRect(in body: CGRect) -> CGRect {
        let content = contentRect(in: body)
        let bar = scrubberRect(in: body)
        return CGRect(x: content.minX, y: bar.minY, width: content.width, height: bar.height)
    }

    /// Gap between a time label and the bar.
    public static let timeLabelSpacing: CGFloat = 8

    /// The center of the play/pause button.
    ///
    /// The three buttons are centerd as a group in the space between the two time labels, which are
    /// pinned to the ends of the row. The middle button is therefore on the center line of that
    /// space — which is *not* the center line of the island, because the labels are equal width and
    /// so cancel. Written out rather than simplified to `midX`, because the day one label changes
    /// width the simplification is silently wrong and this is not.
    public static func playButtonCenter(in body: CGRect) -> CGPoint {
        // Centerd on the content column now that the time labels have moved up to flank the scrub
        // bar. Previously the labels sat at the ends of this row and the buttons centerd in the gap
        // between them; the reference puts the times with the bar they describe, which is both
        // truer to it and what gives the three glyphs room to be large.
        let row = transportRect(in: body)
        return CGPoint(x: row.midX, y: row.midY)
    }

    /// The center of the previous or next button, which flank the play button by one button width
    /// plus one gap.
    public static func skipButtonCenter(in body: CGRect, isNext: Bool) -> CGPoint {
        let center = playButtonCenter(in: body)
        let offset = transportButtonSize.width + transportButtonSpacing
        return CGPoint(x: center.x + (isNext ? offset : -offset), y: center.y)
    }

    /// The point on the scrub bar corresponding to a fraction through the track.
    public static func scrubberPoint(in body: CGRect, atFraction fraction: Double) -> CGPoint {
        let rect = scrubberRect(in: body)
        let clamped = min(max(0, fraction), 1)
        return CGPoint(x: rect.minX + rect.width * clamped, y: rect.midY)
    }

    /// Whether the two control rows actually fit in the body region they are being drawn into.
    ///
    /// False means the island is drawing controls that are clipped by the mask in `IslandRootView`
    /// — visible as buttons with their bottoms shaved off, and *invisible* as a hit region that no
    /// longer matches what a user can see. Asserted by the tests against real hardware geometry
    /// rather than trusted, because `IslandLayout.expandedBodySize` is a constant somebody may
    /// reasonably change.
    public static func fits(in body: CGRect) -> Bool {
        let needed = topPadding + bottomPadding + headerRowHeight + scrubberRowHeight + transportRowHeight
        let widthNeeded = horizontalPadding * 2 + artworkSide + headerSpacing
            + (timeLabelWidth + timeLabelSpacing) * 2
        return body.height >= needed && body.width > widthNeeded
            && transportRowWidth <= body.width - horizontalPadding * 2
    }

    /// How wide the seven-control transport row actually is.
    ///
    /// Written here rather than left implicit in the `HStack`, because it is the number that
    /// decides whether the row is clipped — and a clipped button is not merely shaved on screen, it
    /// is unhittable in the part that was cut. `NowPlayingLayoutTests` asserts it against real
    /// hardware geometry through `fits(in:)`.
    ///
    /// - three primary controls (previous-or-back-15, play/pause, next-or-forward-15)
    /// - four secondary ones (like, shuffle, repeat, Up Next)
    /// - six gaps
    ///
    /// 3x42 + 4x32 + 6x8 = 302pt inside the 344pt column, *down* from 314 — the row got shorter
    /// while every primary button in it got wider, because the gaps gave back more than the buttons
    /// took. That is the trade `transportButtonSpacing` describes, run one more time.
    public static var transportRowWidth: CGFloat {
        transportButtonSize.width * 3 + secondaryButtonWidth * 4 + transportButtonSpacing * 6
    }

    /// The outer four controls' width. Mirrors `NowPlayingTransportView.secondaryWidth`, which is
    /// where the view reads it; kept here as well so the arithmetic above is checkable without a
    /// view, which is the whole reason this file exists.
    ///
    /// 32, up from 28 with the same 4pt the primaries gained. The two widths move together or the
    /// row stops looking like one control set: a wash that is a different size on the heart than on
    /// play says the two are different kinds of thing, which they are not.
    public static let secondaryButtonWidth: CGFloat = 32

    /// The corner radius of the wash drawn behind the control the pointer is on.
    ///
    /// A **rounded rectangle and not a capsule**, deliberately. The narrowest control is 32x30, so
    /// a capsule's radius would be 15 — at that point the wash is a pill behind a 13pt glyph, which
    /// reads as a new object rather than as the target lighting up. 10 is enough curve to be
    /// obviously not a box and little enough to keep the wash reading as the button's own
    /// footprint. `NowPlayingQueueTests` holds it below half the shorter side, which is the line
    /// between the two shapes.
    ///
    /// The wash fills the whole 38x30 (or 32x30) frame rather than an inset of it, because that
    /// frame *is* the press target — `contentShape(Rectangle())` a line below it in the view — and
    /// a highlight smaller than the thing it highlights teaches the user to aim at the wrong size.
    /// It is also why the frame was widened rather than the wash: growing only what is drawn would
    /// have made the highlight the one thing in the row that is not the target.
    public static let transportHoverCornerRadius: CGFloat = 10
}
