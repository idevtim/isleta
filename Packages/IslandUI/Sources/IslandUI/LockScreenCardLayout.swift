import CoreGraphics
import Foundation
import IslandKit

/// The music card on the lock screen: how big it is and where it sits.
///
/// Pure and free of AppKit for the reason every layout type in this package is — the arithmetic
/// where display-arrangement bugs hide should be testable with no running app. That matters more
/// here than anywhere else in the codebase: this surface only exists while the screen is locked, so
/// it can never be checked by glancing at a build.
///
/// ## Two surfaces, not one
///
/// The lock screen carries a **card** — this — and a **padlock at the notch**
/// (`LockScreenNotchLayout`). An earlier version collapsed them into a single island-shaped pill
/// hanging under the cutout, and on hardware it read as neither: too small to be a player, too far
/// from the bezel to be the island. They are separate because they are answering different
/// questions — "what is playing" and "is this Mac locked" — in different places.
///
/// ## Where the numbers come from
///
/// The proportions follow the reference the owner supplied and the shipping implementation they
/// pointed at: a card a little under 400pt wide and 180 tall, artwork at 60pt, sitting below the
/// system's own clock rather than beside it. Those are dimensions read off a design, not code taken
/// from one — the app they came from is GPL-3 and none of it is in this file.
/// The three controls the lock-screen card carries.
///
/// Three, out of the seven the open island draws. Shuffle, repeat and favorite are settings and
/// statements about a track; previous, play/pause and next are the only ones somebody walking past a
/// locked Mac reaches for, and every control on this surface costs a rectangle the user has to aim
/// at without a cursor to tell them they have arrived. See `LockScreenCardView` for why any of them
/// can be pressed at all.
public enum LockScreenTransportControl: CaseIterable, Equatable, Sendable {
    /// **Declaration order is the row's order, leading to trailing.** `transportFrame` walks
    /// `allCases` to place them, so re-ordering these cases moves the buttons — which is the point:
    /// one list, and the drawn row and the hit-tested row cannot disagree about it.
    case toggleShuffle
    case previousTrack
    case playPause
    case nextTrack
    case toggleRepeat

    /// What pressing it sends. The same commands the island's own transport row sends, through the
    /// same `NowPlayingController`, so a route that refuses one refuses it in both places.
    public var command: NowPlayingControlCommand {
        switch self {
        case .toggleShuffle: .toggleShuffle
        case .previousTrack: .previousTrack
        case .playPause: .togglePlayPause
        case .nextTrack: .nextTrack
        case .toggleRepeat: .toggleRepeat
        }
    }

    /// Whether it is a skip. `NowPlayingController.canSkip` gates these two and nothing else — a
    /// player that prohibits skipping still stops, shuffles and repeats.
    public var isSkip: Bool { self == .previousTrack || self == .nextTrack }

    /// Whether it changes how the queue behaves, which is what a radio station refuses.
    /// `NowPlayingController.canChangeQueueBehavior` gates these two.
    public var changesQueueBehavior: Bool {
        self == .toggleShuffle || self == .toggleRepeat
    }

    /// **Secondary, in the row's own sense**: it says something about the queue rather than about
    /// what is playing now. Drawn narrower and dimmer, and the eye should land on play first — the
    /// same hierarchy `NowPlayingTransportView` draws its outer controls with.
    public var isSecondary: Bool { changesQueueBehavior }
}

public enum LockScreenCardLayout {

    // MARK: - The card

    /// 390x180. Wide enough for a real track title beside the cover, and tall enough for the title
    /// block, the progress row and the transport row without any of the three being cramped.
    ///
    /// **216 to 180, and every term of `stackedHeight` gave something up.** The card grew to 216
    /// when the transport row arrived, by adding a row to a layout whose other numbers had been
    /// tuned for a readout — and a readout has air where a player has controls. Reported on
    /// hardware as simply too tall. What came off: 12pt of cover, 4 of padding at each end, 6 of
    /// the gap above the progress line, 6 of the gap below it, and 4 off each button. Nothing is
    /// cramped by it because nothing was at its floor.
    public static let size = CGSize(width: 390, height: 180)

    /// Continuous, never circular — §6.4's rule, the same as the island's outline and the player
    /// bar's. Large, because at this size a small radius reads as a dialog rather than as a card.
    public static let cornerRadius: CGFloat = 34

    public static let horizontalPadding: CGFloat = 22

    /// 22, and it is arithmetic rather than taste: `stackedHeight` has to come out at exactly
    /// `size.height`, and this is the term that closes it. See `stackedHeight`.
    ///
    /// Down from 28 when the transport row arrived, and from 22 when the card was tightened. A card
    /// with a row of controls at the bottom wants less air below them than one that ended in a
    /// progress rule: the buttons carry their own tap area, most of which is space around a glyph,
    /// and padding stacked on top of that reads as the row having slipped off the bottom.
    public static let verticalPadding: CGFloat = 18

    /// The cover. Larger than the open island's 56pt well: this is the only artwork on screen and
    /// it is being looked at from across a room, which is the whole situation a lock screen is for.
    ///
    /// 64, and no longer the 76 it was. The
    /// cover is what sets the header row's height, so it is the biggest single term in a card that
    /// had to come down, and at 64 the three lines beside it still have five points to spare.
    public static let artworkSide: CGFloat = 64


    /// Artwork to text column.
    public static let artworkSpacing: CGFloat = 14

    /// Title to artist.
    public static let titleSpacing: CGFloat = 2

    /// The room the title's line takes.
    ///
    /// Explicit because the title is a `MarqueeText`, which is an `NSView` and has no intrinsic
    /// height to lay out against — the same reason `NowPlayingExpandedLayout.titleLineHeight`
    /// exists. 21pt for a 17pt face: the ascender and descender with a point of air, so a title
    /// with a "g" in it is not clipped by the layer's own bounds.
    public static let titleLineHeight: CGFloat = 20

    /// The artist's, for a 14pt face.
    public static let subtitleLineHeight: CGFloat = 17

    /// The header row to the progress row.
    public static let progressSpacing: CGFloat = 16

    /// The progress line. A **readout**, drawn as a rule rather than as a track with a handle —
    /// nothing on this surface can be dragged, so nothing on it may look draggable.
    public static let progressHeight: CGFloat = 4

    /// What the line grows to while the pointer is on it or a scrub is in progress.
    ///
    /// 6 against 4. Bounded rather than chosen: the row is `timeLabelHeight` (14) tall and the line
    /// is centred in it, so anything up to 14 changes no layout — and past about 6 a "rule" starts
    /// reading as a "bar", which is a different object arriving under the pointer rather than the
    /// same one responding.
    public static let progressHoverHeight: CGFloat = 6

    /// Elapsed and remaining, either end of the line. Fixed width so the line does not change length
    /// as a track crosses from "9:59" to "10:00" — `NowPlayingExpandedLayout.timeLabelWidth`'s
    /// reasoning at this card's size.
    public static let timeLabelWidth: CGFloat = 42

    public static let timeLabelSpacing: CGFloat = 10

    public static let timeLabelHeight: CGFloat = 14

    /// The progress row to the transport row.
    public static let transportSpacing: CGFloat = 10

    /// The tap target for each transport button.
    ///
    /// 40, and it is a floor rather than a preference: the pointer on this surface is aimed with no
    /// cursor change and no hover cursor, often from across a room, so the target has to forgive an
    /// approach that has no feedback until it lands. It came down from 44 with the rest of the card
    /// and stops here — 40 is the smallest this can be and still be aimed at blind.
    ///
    /// It is also what `LockScreenCardLayout.transportFrame` hit-tests, so the drawn button and the
    /// clickable region are the same rectangle by construction rather than by two constants
    /// agreeing.
    public static let transportButtonSize: CGFloat = 40

    /// The tap target for shuffle and repeat.
    ///
    /// Narrower than the three in the middle, exactly as the island's row is arranged: these are
    /// settings you change occasionally, not controls you press. It buys the width the two extra
    /// buttons cost without moving the three that were there — see `transportRowWidth`.
    public static let transportSecondaryButtonWidth: CGFloat = 34

    /// Between them, edge to edge.
    ///
    /// 8, down from 18. The row is one control cluster and should read as one — at 18 against 40pt
    /// buttons they were separate objects sharing a row, which is the arrangement a settings pane
    /// uses rather than a player. The gap still cannot be crossed by the hit regions, which is the
    /// only hard constraint on it.
    public static let transportButtonSpacing: CGFloat = 8

    /// Play/pause. The middle control is the one a hand goes to without looking, and it is drawn
    /// larger for that rather than for emphasis.
    public static let transportPrimaryGlyph: CGFloat = 26

    /// Previous and next.
    public static let transportSecondaryGlyph: CGFloat = 20

    /// Shuffle and repeat. Well below the other two, and deliberately: raising all five together
    /// would spend the size on flattening the hierarchy the row is arranged around.
    public static let transportQueueGlyph: CGFloat = 16

    /// **Zero: this card casts no shadow.**
    ///
    /// It had one, drawn in the view rather than by `NSWindow.hasShadow` so it would fade with the
    /// card. Withdrawn on sight of it on hardware: a shadow says the card is floating above the
    /// thing behind it, and Liquid Glass says the opposite — that what is behind is being seen
    /// *through* it. Drawing both is the surface claiming to be two materials at once, and the
    /// glass loses, because a dark halo around a translucent plate reads as a sticker.
    ///
    /// Kept as a named zero rather than deleted because `panelFrame` is arithmetic that has to say
    /// what it does not add. Nothing else references it.
    public static let shadowMargin: CGFloat = 0

    /// Room around the card for the arrival's overshoot.
    ///
    /// **`Motion.reveal` is a bounce, and a bounce needs somewhere to go.** The card's scale crosses
    /// 1 on its way to settling, and AppKit clips a window's contents to its bounds whatever SwiftUI
    /// drew — so a panel sized to exactly the card squares its own corners off for the two or three
    /// frames the overshoot lasts, which is the one frame anybody would be looking at. The headroom
    /// has to be in the *window*, which is what the notch surface already does by sizing its panel
    /// for the peeked island rather than the resting one (`LockScreenNotchLayout.panelSize`).
    ///
    /// 8pt. `reveal` overshoots ~11% of whatever travel it is given, and the arrival's travel is
    /// 10% of the card's size (`LockScreenCardView.arrivalScale`), so the peak is ~1.5% over — under
    /// 3pt on the wide axis, halved again by the top anchor. The rest is room to retune the arrival
    /// without coming back here.
    ///
    /// **Not folded into `shadowMargin`**, which is a named zero making a different claim: that this
    /// card casts no shadow. One is about a material, the other about an animation, and a single
    /// number would leave a later reader unable to change either without breaking the other.
    public static let overshootMargin: CGFloat = 8

    /// Everything the panel adds around the card. `panelFrame` and `cardFrame` are each other's
    /// inverse through this, which is the invariant `LockScreenCardTests` pins.
    public static var panelMargin: CGFloat { shadowMargin + overshootMargin }

    /// The panel's own size: the card and everything around it.
    ///
    /// The **root view takes this**, not `size` — see `LockScreenCardView.body`. A root view smaller
    /// than the window leaves the card's position to whatever `NSHostingView` does with the spare
    /// points, which is not a thing to find out about on a screen only the lock can show; a root
    /// that fills the window centres the card itself and the arithmetic here is the only answer.
    public static var panelSize: CGSize {
        CGSize(width: size.width + panelMargin * 2, height: size.height + panelMargin * 2)
    }

    // MARK: - Derived

    /// The bar row at the trailing end of the header.
    ///
    /// Larger than the island's 21×14 glyph box, and `NowPlayingEqualiserView.size` exists for it:
    /// this card is read from across a room, where that row is a smudge. Not so large that it
    /// competes with the cover — it answers "is this actually playing", which is a glance, not a
    /// subject.
    public static let equaliserSize = CGSize(width: 30, height: 20)

    /// The text column to the bars.
    public static let equaliserSpacing: CGFloat = 12

    public static var textColumnWidth: CGFloat {
        size.width - horizontalPadding * 2 - artworkSide - artworkSpacing
            - equaliserSize.width - equaliserSpacing
    }

    public static var progressRowWidth: CGFloat {
        size.width - horizontalPadding * 2
    }

    public static var progressLineWidth: CGFloat {
        progressRowWidth - (timeLabelWidth + timeLabelSpacing) * 2
    }

    public static var headerRowHeight: CGFloat { artworkSide }

    /// What the rows add up to, which must be exactly `size.height`.
    ///
    /// Written as arithmetic so a test can assert it. The first version of this card declared 104pt
    /// against rows totalling 120, and the assertion caught it on its first run — on a surface where
    /// a clipped cover would otherwise have shipped, because nobody is at the Mac to see it.
    public static var stackedHeight: CGFloat {
        verticalPadding
            + headerRowHeight
            + progressSpacing
            + max(progressHeight, timeLabelHeight)
            + transportSpacing
            + transportButtonSize
            + verticalPadding
    }

    /// How wide one button's target is.
    public static func transportWidth(of control: LockScreenTransportControl) -> CGFloat {
        control.isSecondary ? transportSecondaryButtonWidth : transportButtonSize
    }

    /// The width the five buttons and their four gaps take.
    ///
    /// Summed from the list rather than written as a product, because the buttons are two widths
    /// now — and because `transportFrame` walks the same list to place them, so the row's width and
    /// the buttons' positions cannot disagree about what is in it.
    public static var transportRowWidth: CGFloat {
        let buttons = LockScreenTransportControl.allCases.reduce(0) { $0 + transportWidth(of: $1) }
        let gaps = transportButtonSpacing
            * CGFloat(LockScreenTransportControl.allCases.count - 1)
        return buttons + gaps
    }

    // MARK: - Placement

    /// How far below the display's vertical center the card's top edge sits.
    ///
    /// The macOS lock screen puts the date and clock in the upper third. The card goes below them,
    /// in the band macOS itself leaves empty at every display size — which is where the reference
    /// the owner supplied puts it, and where the implementation they pointed at puts it.
    public static let centerOffset: CGFloat = 100

    /// Where the panel goes, shadow margin included.
    ///
    /// Takes the **full** `NSScreen.frame` rather than `visibleFrame`: there is no menu bar and no
    /// Dock on a locked screen, so `visibleFrame`'s insets describe furniture that is not there.
    public static func panelFrame(inScreenFrame screen: CGRect) -> CGRect {
        let panel = panelSize
        // The **card's** top edge is what `centerOffset` measures, not the panel's — so the margin
        // comes off the origin as well as being added to the size. Writing this as
        // `midY - centerOffset - height` is the version that moves the card down by one margin the
        // moment the margin stops being zero, which is exactly the off-by-one-margin bug
        // `LockScreenController.place` already records for the hosting view.
        return CGRect(
            x: screen.midX - panel.width / 2,
            y: screen.midY - centerOffset - size.height - panelMargin,
            width: panel.width,
            height: panel.height
        )
    }

    /// The card itself, in **global screen points** — the panel less everything the panel adds
    /// around it: no shadow, and `overshootMargin` of room for the arrival's bounce.
    ///
    /// Global, and that is the whole reason this exists rather than the view measuring itself. The
    /// only pointer this surface can read is `NSEvent.mouseLocation`, which is answered in screen
    /// coordinates by the window server; a `GeometryReader` inside the card would give view
    /// coordinates that nothing can convert, because the panel is never asked about an event and
    /// `convertPoint(fromScreen:)` needs a window the pointer was actually delivered to.
    public static func cardFrame(inScreenFrame screen: CGRect) -> CGRect {
        panelFrame(inScreenFrame: screen).insetBy(dx: panelMargin, dy: panelMargin)
    }

    /// One transport button, in global screen points.
    ///
    /// AppKit's y is up, so the transport row — visually the bottom of the card — is measured from
    /// `minY`. Getting that inverted puts the hit region where the title is, and on a surface that
    /// gives no cursor feedback the symptom is "the buttons don't work" with nothing to look at.
    public static func transportFrame(
        _ control: LockScreenTransportControl,
        inScreenFrame screen: CGRect
    ) -> CGRect {
        let card = cardFrame(inScreenFrame: screen)
        // Walked rather than indexed, because the widths differ: two of the five are narrower, so
        // a button's position is the sum of what is to the left of it and not a multiple of a step.
        var x = card.midX - transportRowWidth / 2
        for candidate in LockScreenTransportControl.allCases {
            let width = transportWidth(of: candidate)
            if candidate == control {
                return CGRect(
                    x: x,
                    y: card.minY + verticalPadding,
                    width: width,
                    height: transportButtonSize
                )
            }
            x += width + transportButtonSpacing
        }
        return .zero
    }

    /// How far above and below the progress row still counts as being on it.
    ///
    /// The line is 4pt tall and the row it sits in is 14. Neither is a target anybody can hit
    /// without a cursor to aim with, and this surface has none — so the region is the row plus 6pt
    /// each way. **Bounded by its neighbours rather than chosen**: `transportSpacing` is the room
    /// below, and this must stay under it or the region reaches a button. It came down from 8 when
    /// that gap came down from 16, and `LockScreenSurfaceTests` asserts the clearance rather than
    /// trusting the two numbers to be edited together.
    public static let progressHitSlop: CGFloat = 6

    /// The progress **line** — the rule itself, between the two time labels — in global screen
    /// points. This is what a fraction is measured against.
    public static func progressLineFrame(inScreenFrame screen: CGRect) -> CGRect {
        let card = cardFrame(inScreenFrame: screen)
        // Measured up from the bottom edge, past the transport row and its gap: AppKit's y is up,
        // and the row a person sees above the buttons is the one *after* them from `minY`.
        let rowBottom = card.minY + verticalPadding + transportButtonSize + transportSpacing
        let rowHeight = max(progressHeight, timeLabelHeight)
        return CGRect(
            x: card.minX + horizontalPadding + timeLabelWidth + timeLabelSpacing,
            y: rowBottom + (rowHeight - progressHeight) / 2,
            width: progressLineWidth,
            height: progressHeight
        )
    }

    /// The region the pointer has to be in for the line to answer — the line, grown to something a
    /// hand can find. See `progressHitSlop`.
    public static func progressFrame(inScreenFrame screen: CGRect) -> CGRect {
        let line = progressLineFrame(inScreenFrame: screen)
        let rowHeight = max(progressHeight, timeLabelHeight)
        return CGRect(
            x: line.minX,
            y: line.midY - rowHeight / 2 - progressHitSlop,
            width: line.width,
            height: rowHeight + progressHitSlop * 2
        )
    }

    /// Where along the track a pointer is, 0 through 1, clamped to the ends.
    ///
    /// Clamped rather than guarded because the pointer is sampled rather than delivered: a press
    /// that begins inside the region and is dragged past either end is a real gesture, and the
    /// honest answer to "past the start" is the start.
    public static func progressFraction(atX x: CGFloat, inScreenFrame screen: CGRect) -> Double {
        let line = progressLineFrame(inScreenFrame: screen)
        guard line.width > 0 else { return 0 }
        return min(1, max(0, Double((x - line.minX) / line.width)))
    }

    /// Which control a pointer is on, or nil.
    ///
    /// The buttons do not touch — there are 18pt between them — so at most one frame can contain a
    /// point and `first` is the answer rather than a preference between overlapping regions.
    public static func transportControl(
        at point: CGPoint,
        inScreenFrame screen: CGRect
    ) -> LockScreenTransportControl? {
        LockScreenTransportControl.allCases.first {
            transportFrame($0, inScreenFrame: screen).contains(point)
        }
    }

    // MARK: - Progress

    /// How far along the line the playhead is, clamped.
    ///
    /// Clamped rather than trusted because a duration of zero is what a live stream reports, and an
    /// unclamped division would draw a `NaN` width — which SwiftUI renders as nothing at all,
    /// silently, on a surface no one is watching being built.
    public static func progressFraction(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite, duration.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
}

/// The padlock at the notch.
///
/// Separate from the card because it is placed against a different thing — the hardware cutout,
/// which `NotchResolver` measures per display — and because it says something different: *this Mac
/// is locked*, which is true whether or not there is music.
///
/// ## It is the island, flanked
///
/// The shape is `IslandLayout`'s own flanked rest metrics: the cutout plus `flankedWidthGrowth`,
/// hanging from the bezel at exactly the cutout's height. The padlock sits in the **leading flank**
/// — the slot the album artwork occupies when the island is showing Now Playing, which is where the
/// owner asked for it. Nothing is drawn in the trailing flank; a symmetric pair of marks would read
/// as two controls rather than as one state.
public enum LockScreenNotchLayout {

    /// The flanked island for this screen — resting, or peeked while the pointer is on it.
    ///
    /// `IslandForm` rather than `restMetrics` with the growth added by hand. They give the same body
    /// size, and the difference is the part that matters: only the real form carries
    /// `topFlareRadius`, the outward curve where the island meets the bezel. Adding width to the
    /// resting metrics produced a plain rounded rectangle — a pill stuck under the cutout rather
    /// than the cutout widening, which is exactly what it looked like on hardware.
    ///
    /// Going through `IslandLayout` also means the lock surface inherits the user's `IslandSizing`,
    /// their peek scale, and any future change to the island's shape, instead of drifting from it.
    public static func metrics(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard,
        hovered: Bool = false
    ) -> IslandShapeMetrics {
        IslandLayout.metrics(for: hovered ? .flankedPeek : .flankedRest, on: screen, sizing: sizing)
    }

    /// How much the island swells under a press.
    ///
    /// Lives here rather than in the model because **the panel has to be built big enough to hold
    /// it**. Sized to the peeked island exactly, a press scaled the content past the window's own
    /// bounds and the shape clipped — square corners appearing on a press, which is the one moment
    /// the user is looking straight at it.
    ///
    /// Small on purpose. §7's rule is that peek "is an invitation to click, never the click's
    /// result" — this *is* the result, so it must read as the same shape flexing rather than as a
    /// third size the island has.
    public static let pressScale: CGFloat = 1.04

    /// The panel is always sized for the **pressed, peeked** island — the largest shape it will ever
    /// hold — whatever is currently drawn.
    ///
    /// `LockScreenPanel`'s rule, inherited from `IslandPanel`: the frame never changes. Growing the
    /// window on hover or on a press would animate `NSWindow.setFrame`, which produces stepped,
    /// tearing motion — the single most common reason these apps feel cheap. So the window is built
    /// once at the maximum and the *content* grows inside it.
    ///
    /// Rounded up rather than exact: a shape a fraction of a point wider than its window does not
    /// warn, it clips, and the clip lands on the flare and the bottom corners — the two places the
    /// island's shape is doing all its work.
    public static func panelSize(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard
    ) -> CGSize {
        let peeked = metrics(for: screen, sizing: sizing, hovered: true)

        // **`boundingSize`, not `bodySize`.** The flare reaches past the body — sideways, at the
        // top, which is the geometry's own note on itself — so a panel built from `bodySize` is
        // narrower than the shape it holds at exactly the two corners the flare lives on. Sized that
        // way, a press clipped the flare flat while the bottom, which the flare does not touch,
        // looked perfect. That asymmetry is the tell.
        let bounding = IslandShapeGeometry.boundingSize(for: peeked)

        return CGSize(
            width: (bounding.width * pressScale).rounded(.up),
            height: (bounding.height * pressScale).rounded(.up)
        )
    }

    /// 16. Between the 13 that came back as "a tiny white square" and the 20 that was too heavy for
    /// a 32pt cutout — the padlock is a state, not a subject, and at 20 it dominated the flank it
    /// sits in. `LockScreenSurfaceTests` holds the floor at a third of the flank rather than a half,
    /// which is the range this actually lives in.
    public static let glyphPointSize: CGFloat = 16

    /// How far in from the leading edge the glyph's center sits: the middle of the leading flank.
    public static var glyphLeadingInset: CGFloat { IslandLayout.flankedFlankWidth / 2 }

    /// **Zero.** The island is black hanging off a black bezel — there is nothing for a shadow to
    /// fall on, and a margin above the screen's top edge is a margin AppKit will not honor anyway.
    /// Keeping it at zero is also what lets the surface's top edge *be* the screen's top edge, which
    /// is the difference between hanging from the bezel and floating below it.
    public static let shadowMargin: CGFloat = 0

    /// Where the panel goes: hanging from the top of the screen, centerd on the **notch**.
    ///
    /// Anchored to the cutout's own x, because `NotchResolver` measures its real position rather
    /// than assuming it is centerd — and on a display where those disagree, a shape centerd on the
    /// screen sits beside the thing it is meant to be part of.
    public static func panelFrame(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard
    ) -> CGRect {
        let size = panelSize(for: screen, sizing: sizing)
        let width = size.width + shadowMargin * 2
        let height = size.height + shadowMargin * 2
        return CGRect(
            x: screen.notch.rect.midX - width / 2,
            y: screen.frame.maxY - size.height - shadowMargin,
            width: width,
            height: height
        )
    }

    /// The region the pointer has to be inside for the island to peek, in **global** screen points.
    ///
    /// The resting shape, not the panel: the panel is peek-sized, so using its frame would mean the
    /// island reacts to a pointer that is beside it rather than on it — and worse, would latch,
    /// because once peeked the pointer would still be inside the region that made it peek.
    ///
    /// Grown by `hoverSlop` on the sides and bottom so the region is forgiving in the directions a
    /// pointer approaches from, and **not** at the top, where there is nothing above the bezel to
    /// approach from.
    public static func hoverRegion(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard
    ) -> CGRect {
        let body = metrics(for: screen, sizing: sizing).bodySize
        let rect = CGRect(
            x: screen.notch.rect.midX - body.width / 2,
            y: screen.frame.maxY - body.height,
            width: body.width,
            height: body.height
        )
        return CGRect(
            x: rect.minX - hoverSlop,
            y: rect.minY - hoverSlop,
            width: rect.width + hoverSlop * 2,
            height: rect.height + hoverSlop
        )
    }

    /// How far outside the resting island still counts as being on it.
    ///
    /// The island is 32pt tall against a menu bar the pointer crosses constantly, and a region with
    /// no slop means the peek flickers on and off as the pointer travels along the bezel. 4pt is the
    /// smallest value that stopped that in practice without the island reacting to a pointer that is
    /// plainly beside it.
    public static let hoverSlop: CGFloat = 4
}
