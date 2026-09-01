import CoreGraphics

/// Fixed layout constants and the panel/content frame arithmetic that follows from them.
///
/// The panel frame is computed **once per screen** and never animated (§4.2). Everything that grows
/// or shrinks does so inside this fixed rectangle, so the window server never has to resize a
/// window mid-animation — which is the difference between a morph and a stepped, tearing resize.
public enum IslandLayout {

    /// The largest body the island will ever present. The panel is sized to hold this and then
    /// left alone.
    /// The panel is built once at this size and never resized (§4.2), so it is the ceiling every
    /// content-driven height is clamped into.
    ///
    /// **400, not 200.** Three things had to fit that did not before: the switcher row, which the
    /// open island grows to reveal; the drop history, which is four rows of finished work plus a
    /// footer; and that list's header, which carries the two controls that dismiss it now that a
    /// click elsewhere does not (`DropHistoryLayout.headerHeight`). Clamped lower, any of them would be
    /// silently truncated — and a list cut off mid-row reads as a rendering fault rather than as a
    /// sizing decision. The panel grows by transparency only; it costs nothing, because
    /// `IslandHitTestView` rejects every point outside the shape, which `PassThroughSelfTest` and
    /// `ClickSelfTest` both check.
    public static let maxExpandedBodySize = CGSize(width: 560, height: 400)

    /// Slack on each side of the widest body. The island never draws outside its own body, so this
    /// is not needed for the shape — it is headroom for the shadow Isleta draws itself (§4.1 turns
    /// the system one off), and it costs nothing because the panel never resizes.
    public static let panelMargin: CGFloat = 24

    /// Radius of the island's bottom corners, matching the physical notch's own.
    ///
    /// Apple does not publish this and it cannot be read back from the framebuffer — a screenshot
    /// captures whatever is drawn in the notch region, not the shape of the cutout. So this is the
    /// one number in the geometry that has to be set by eye against real hardware. Everything else
    /// derives from measured values.
    ///
    /// The error is **not symmetric**, which is why it is set high rather than at the middle of the
    /// plausible range. The cutout is a hole: at rest the island is exactly the cutout's rectangle,
    /// so the only part of it that can be seen is the part lying *outside* the hole. Draw the corner
    /// squarer than the cutout's and that difference is black paint on lit pixels — two nubs at the
    /// bottom corners of the notch, which is precisely the "not as round as Apple's" tell. Draw it
    /// rounder and the difference falls *inside* the hole, where there is nothing to light and
    /// nothing to see. So an overshoot at rest is invisible and an undershoot is not.
    ///
    /// It stops being free the moment the island is wider or taller than the cutout — peek and the
    /// flanked forms put these corners on lit pixels in full — so this is a bias, not a license: 12
    /// reads as the cutout's own corner on a 32pt-tall island, where 20 would read as a lozenge.
    public static let notchBottomCornerRadius: CGFloat = 12

    /// Convex top corner radius at rest. Zero: at rest the island's top edge is flush against the
    /// bezel, so rounding it would open a sliver of lit pixels between island and bezel.
    public static let restTopCornerRadius: CGFloat = 0

    // MARK: - Peek
    //
    // At rest on a notched Mac the island is invisible — pure black filling exactly the notch, with
    // its bottom corners following the cutout's own. That leaves the user no way to discover it, so
    // arriving with the pointer has to announce itself. Peek swells the island just past the notch
    // on all three free edges, which reads as the notch itself growing rather than as a new object
    // appearing.
    //
    // Kept deliberately small. This is an invitation to click, not the click's result.

    // MARK: - Expanded

    /// The island's open size.
    ///
    /// The width is fixed and the height is a **default**: it is what the island opens to when
    /// nobody has said otherwise, and what the Now Playing player and the shelf — the two kinds
    /// that draw their own body against a known rectangle — always use. Everything else opens to
    /// its content, through `expandedHeight` below.
    ///
    /// Kept well inside `maxExpandedBodySize` so the panel never has to grow.
    public static let expandedBodySize = CGSize(width: 368, height: 176)

    /// The open island's default height with compactIsland on.
    ///
    /// **A height, and deliberately not also a width.** `NowPlayingExpandedLayout`'s seven-control
    /// transport row is computed against `expandedBodySize.width` as a *constant* rather than
    /// against the body it is handed, so a narrower island would draw its rows outside the mask in
    /// `IslandRootView` — where a button is visibly shaved and invisibly unhittable. Making the
    /// width adjustable is its own piece of work: it is that file, not this constant.
    ///
    /// **156, and the 20pt it takes off is measured rather than chosen.** The tallest thing the open
    /// island has to hold is the Now Playing player, whose rows are anchored to the bottom of the
    /// body: 176 less the 32pt cutout is 144pt of drawable height, less `topPadding` 6 and
    /// `bottomPadding` 8 leaves 130, against a header of 56, a scrubber row of 22 and a transport
    /// row of 32 — 110. The slack is 20pt exactly, and this spends all of it and not a point more.
    /// `CompactIslandTests` pins that arithmetic so a later change to any of those five numbers fails the
    /// build rather than clipping the transport row on somebody's Mac.
    ///
    /// Content-sized activities are **not** scaled by this. A content height is what an activity
    /// measured it needs (`ActivityExpandedHeight`), and shrinking it clips rows — which reads as a
    /// rendering fault rather than as a compact island. compactIsland changes the island's own default,
    /// which is the height the player and the shelf draw against and the one a user actually looks
    /// at all day.
    public static let miniExpandedBodyHeight: CGFloat = 156

    /// The shortest the open island is allowed to be.
    ///
    /// Content-driven heights are still bounded at both ends, because the thing being sized is not
    /// a text box — it is a shape hanging off the bezel that has to read as the notch having opened.
    /// Below this the island is a strip, and a strip under the notch reads as a bar rather than as
    /// something the cutout grew into. 108 is the cutout's 32 plus a 44pt symbol well and its
    /// insets, which is the smallest thing the open island ever actually draws.
    public static let minimumExpandedHeight: CGFloat = 108

    /// The open island's body height on one screen, given how much drawable content it has to hold
    /// *below the cutout*.
    ///
    /// The override is a **content** height rather than a body height, and that is what lets one
    /// value be correct on every display at once. The same greeting needs the same 76pt of drawing
    /// room on a MacBook and on a Studio Display; what differs is that the MacBook has a 32pt hole
    /// at the top of the body that nothing can be drawn in. Asking callers for a body height would
    /// make them add that themselves, per screen, which is the sort of arithmetic that ends up done
    /// once and then not again in the second place that needs it — and the second place here is the
    /// hit region.
    ///
    /// `nil` — nobody asked — is the default height. Everything else is clamped into
    /// `minimumExpandedHeight ... maxExpandedBodySize.height`: the panel is created once at the
    /// maximum and never resized (§4.2), so a body taller than it would be drawn clipped and, worse,
    /// hit-tested against a path that runs off the bottom of the window.
    /// - Parameter pageIndicatorHeight: the strip the switcher row takes at the bottom of the open
    ///   island, or 0 when there is no row. Its own parameter rather than folded into
    ///   `contentHeight`, because the two are different things: `contentHeight` is what *this
    ///   activity* needs and is nil when the activity does not size the island, while the row is a
    ///   constant the island wears regardless of what is on stage. Folding them would mean
    ///   resolving the nil default to a number in the caller — and that number differs per screen,
    ///   which is exactly what keeping `contentHeight` cutout-free avoids.
    /// - Parameter compactIsland: whether the *default* — the `nil` branch, and only that branch — takes
    ///   `miniExpandedBodyHeight` instead. See that constant for why a content height is left alone.
    public static func expandedHeight(
        contentHeight: CGFloat?,
        cutoutHeight: CGFloat,
        pageIndicatorHeight: CGFloat = 0,
        compactIsland: Bool = false
    ) -> CGFloat {
        let base: CGFloat = if let contentHeight {
            max(contentHeight + cutoutHeight, minimumExpandedHeight)
        } else {
            compactIsland ? miniExpandedBodyHeight : expandedBodySize.height
        }
        return min(base + pageIndicatorHeight, maxExpandedBodySize.height)
    }

    /// The open island's width, given what the surface on it asked for.
    ///
    /// **The width was a constant until 2026-08-28, and the reason it could stop being one is that
    /// it only ever grows.** `expandedBodySize.width` is the floor here, not the default-and-also-
    /// the-minimum: `NowPlayingExpandedLayout` computes its seven-control transport row against
    /// that constant rather than against the body it is handed (`IslandSizing.widthAdjustment` says
    /// so), so a *narrower* island draws that row outside the mask, where a button is visibly
    /// shaved and invisibly unhittable. Clamping up rather than down is what keeps this parameter
    /// from reaching that file at all.
    ///
    /// Clamped into `maxExpandedBodySize.width` at the top for `expandedHeight`'s reason: the panel
    /// is created once at that size and never resized (§4.2), so a body wider than it would be
    /// drawn clipped and hit-tested against a path that runs off the side of the window.
    ///
    /// **The ceiling is a guard rail, not a size to design to.** Measured on the 1728pt built-in
    /// display, 2026-08-28: the open island's top flare curves 24.46pt past its own body on each
    /// side, against a `panelMargin` of 24 — so a body at the full 560 puts half a point of that
    /// curve outside the panel, where it is clipped. Nothing asks for it: the widest surface in the
    /// app is `GlanceScheduleLayout.bodyWidth` at 440, which leaves 59pt of panel each side. It is
    /// clipping rather than the subset bug `IslandHitTestView` documents — the drawn path and the
    /// hit-tested path are the same path — but a surface that wants the last twenty points should
    /// take the margin up with it rather than discover this.
    ///
    /// It does not disturb the ordering `metrics` depends on. Only the expanded form reads it, and
    /// the expanded form stays the widest in the family at every value this can take — so
    /// `IslandShapeMetrics.union` of any two forms still contains everything between them.
    ///
    /// `nil` — nobody asked — is the default width, which is what every surface but the month grid
    /// uses.
    public static func expandedWidth(contentWidth: CGFloat?) -> CGFloat {
        guard let contentWidth else { return expandedBodySize.width }
        return min(max(contentWidth, expandedBodySize.width), maxExpandedBodySize.width)
    }

    /// Bottom radius when open.
    ///
    /// Larger than the notch's. At peek the island is meant to read as the cutout growing, so it
    /// keeps the cutout's radius; open, it is plainly a panel hanging below the notch, and holding
    /// the cutout's own radius on a 176pt-tall body would read as stiff rather than as continuous.
    ///
    /// Raised from 22 by eye on hardware, 2026-08-28: at 22 the open island still read as a
    /// rectangle with rounded corners, and the softer 28 is what makes the bottom edge read as one
    /// continuous curve across the width rather than as two corners on a straight run.
    public static let expandedBottomCornerRadius: CGFloat = 28

    /// How far the open island's top corners curve out into the ceiling of the screen.
    ///
    /// Zero at rest and at peek: there the top edge is flush against the bezel and there is nothing
    /// to curve into. Open, the island hangs 140pt below the ceiling and a square top corner reads
    /// as a panel stuck on the screen rather than as something the edge grew — so the corners take
    /// the bottom corners' curve, reversed. Deliberately smaller than the bottom's 28pt: the flare
    /// paints *outside* the body, and a deep one starts eating the menu bar either side of the
    /// island rather than reading as a join.
    ///
    /// Raised from 12 alongside the bottom's own, 2026-08-28, and for the same reason: the flare is
    /// the bottom corner's curve reversed, so leaving it behind while the bottom softened would put
    /// two different curves on one outline.
    public static let expandedTopFlareRadius: CGFloat = 16

    /// How far a *flanked* island's top corners curve out into the ceiling.
    ///
    /// The same idea as the open island's, and for the same reason: once the island is wider than
    /// the cutout it has two square corners sitting against the top of the screen, and a square
    /// corner there reads as a black rectangle laid over the bezel rather than as the notch having
    /// grown. Curving them is what keeps it reading as one shape with the cutout.
    ///
    /// Smaller than the open island's 16pt because there is less island to curve: a flanked island
    /// is the cutout's own 32pt tall, and `flareExtent` clamps a flare to half the height anyway, so
    /// a larger radius here would silently resolve to the same curve while implying it had not.
    public static let flankedTopFlareRadius: CGFloat = 9

    // MARK: - The blur
    //
    // A soft blur of the desktop, drawn in a ring around the **open** island and nowhere else. It
    // is a visual and a hit region at the same time, and the second is the load-bearing half: the
    // pointer may sit in it without closing the island, and a click in it closes the island rather
    // than falling on the floor.

    /// How far the blur reaches past the open island's outline, on every side that has screen to
    /// reach into.
    ///
    /// **24, and it is bounded by `panelMargin` rather than chosen freely.** The panel is the
    /// widest body plus that margin each side and is never resized (§4.2), so a blur wider than the
    /// margin would be clipped at the panel edge on an island the user has sized to the maximum —
    /// and clipped asymmetrically, because the island is centerd on the notch and the notch is not
    /// always centerd on the display. A ring that is 24pt on one side and 9pt on the other reads as
    /// a rendering fault. Equal to the margin, the blur always fits, whatever width the user has
    /// asked for.
    ///
    /// It is not reached *above* the island. The island hangs from the top edge of the screen, so
    /// there are no pixels up there to blur.
    public static let blurSpread: CGFloat = 24

    /// How soft the blur's outer edge is.
    ///
    /// Deliberately most of `blurSpread`: the ring has to end in nothing rather than in an edge,
    /// because an edge would draw a second outline around the island — and the island's own outline
    /// is the shape the whole app is judged on. A blur radius equal to the spread would put half the
    /// feather outside the region the pointer is allowed to rest in; 18 against 24 keeps the visible
    /// bloom inside the region that holds the island open.
    public static let blurSoftness: CGFloat = 18

    /// The blur's own shape: the island's, grown by `blurSpread` on the two sides and the bottom.
    ///
    /// The top edge is left where it is. The island's top is the top of the screen, so growing it
    /// upward would only push the shape off the display — and the corner radii have to grow with the
    /// body or the ring would be thinner at the corners than along the edges, which reads as the
    /// blur being squeezed rather than offset.
    public static func blurMetrics(for metrics: IslandShapeMetrics) -> IslandShapeMetrics {
        IslandShapeMetrics(
            bodySize: CGSize(
                width: metrics.bodySize.width + blurSpread * 2,
                height: metrics.bodySize.height + blurSpread
            ),
            topCornerRadius: metrics.topCornerRadius,
            bottomCornerRadius: metrics.bottomCornerRadius + blurSpread,
            topFlareRadius: metrics.topFlareRadius
        )
    }

    /// The blur as a **rectangle** in the panel's y-down content space, for hit testing.
    ///
    /// A rectangle rather than the drawn ring's outline, and that is safe in the one direction that
    /// matters. It is a *superset* of what is drawn, so the only points it adds are the four corners
    /// — where nothing is painted, the panel's alpha is zero, and the window server therefore never
    /// routes a click to us in the first place. A subset would be the other thing entirely: drawn
    /// blur pixels the window server hands us and `hitTest` then refuses, which is the click that
    /// lands nowhere at all. See `IslandHitTestView`.
    ///
    /// Clamped to the panel, because a click outside it cannot reach us however wide this says.
    public static func blurRegion(
        isExpanded: Bool,
        on screen: IslandScreen,
        in panelSize: CGSize,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> CGRect {
        guard isExpanded else { return .zero }
        let island = bounds(
            for: pageIndicatorHeight > 0 ? .expandedWithPageIndicator : .expanded,
            on: screen,
            in: panelSize,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
        let grown = CGRect(
            x: island.minX - blurSpread,
            y: island.minY,
            width: island.width + blurSpread * 2,
            height: island.height + blurSpread
        )
        return grown.intersection(CGRect(origin: .zero, size: panelSize))
    }

    /// Total width added at peek, split evenly either side of the notch, at a `peekScale` of 1.
    public static let peekWidthGrowth: CGFloat = 12

    /// Height added at peek, all of it below the notch where there are lit pixels to show it in,
    /// at a `peekScale` of 1.
    public static let peekHeightGrowth: CGFloat = 8

    /// How much a peek grows, at the user's chosen scale, rounded to whole points.
    ///
    /// Rounded because §6.6 asks for layout snapped to the pixel grid at 1x and 2x, and a scale of
    /// 1.3 would otherwise put the island's edges on 15.6pt — a half-pixel at 1x, which reads as a
    /// soft edge on the one shape in Isleta whose job is to be indistinguishable from the bezel.
    /// Rounding here rather than at each call site is also what keeps the drawn shape and the hit
    /// region byte-identical: they are the same function of the same scale, so they cannot disagree
    /// by a rounding step and leave clicks landing on lit pixels that `islandPath` rejects.
    static func peekGrowth(scale: Double) -> CGSize {
        CGSize(
            width: (peekWidthGrowth * scale).rounded(),
            height: (peekHeightGrowth * scale).rounded()
        )
    }

    // MARK: - Flanked
    //
    // The collapsed island is the cutout, and the cutout is a *hole* — no pixels, nothing that can
    // be lit. So a presented activity has nowhere to be until someone clicks, and once Now Playing
    // lands, a track change would produce no visible signal at all. The island therefore has a
    // second resting size, used whenever what is on stage has something to say in the slivers
    // beside the cutout.
    //
    // Two *constants*, not sizing from the content. `islandPath` has to track a settled shape for
    // hit testing to stay exact (§4.2), and a body whose width follows a track title would move the
    // hit region on every scrub and never settle — which is the same reason `expandedBodySize` is a
    // constant. Constants also mean the widen-then-tighten protocol in `AppDelegate.transition`
    // covers this transition with nothing added: there are five shapes, not a continuum.

    /// Total width added when the island is carrying flank content, split evenly either side of
    /// the cutout — so each flank is exactly half of it, on every Mac.
    ///
    /// 80, giving a 40pt sliver each side. The floor is `ActivitySlotLayout.minimumFlankWidth`
    /// (34pt), below which a 13pt SF Symbol either clips against the cutout or touches the island's
    /// outer edge; 40 clears it by enough to hold the *widest* built-in glyph
    /// (`speaker.wave.2.fill` runs ~18pt at 13pt semibold) inside the flank's 10pt end insets
    /// rather than only the narrowest. Sitting on the 34pt floor would make the difference between
    /// "drawable" and "blind" a rounding error.
    ///
    /// Deliberately a constant added to the *cutout*, not a target body width: the flank a glyph
    /// gets is then the same 40pt on a machine whose notch measures 185pt and on one that measures
    /// 200pt, instead of quietly shrinking on the wider Mac.
    ///
    /// Not larger, because the island must still read as the notch itself growing. At 265pt on a
    /// 1728pt display this is 15% of the width against the cutout's 11%, hanging from the bezel at
    /// exactly the cutout's height — a wider notch. Push it much past this and it reads as a black
    /// bar that happens to contain the notch, which is the failure the whole shape language exists
    /// to avoid.
    public static let flankedWidthGrowth: CGFloat = 80

    /// Total width added when what is on stage **spells itself** in the slivers rather than only
    /// showing a glyph — the volume and brightness HUDs, today. Split evenly either side of the
    /// cutout like `flankedWidthGrowth`, so each flank is 108pt.
    ///
    /// **216, and every point of it is measured.** The leading sliver has to hold the widest built-in
    /// HUD glyph (`speaker.wave.2.fill`, 20pt at 13pt semibold), 4pt of spacing, and the word beside
    /// it, inside `ActivityContentView.flankPadding`'s 10pt at *each* end: 44pt of furniture, leaving
    /// 64. Measured in real SF Pro at 12pt medium on 2026-08-28, the longest label the four shipped
    /// languages produce is German's "Lautstärke" at 61.4pt, and the longest English one is "Volume"
    /// at 43. So no translation has to tighten — which is what `docs/LOCALIZATION.md` warns is the
    /// real danger, since the blow-ups in this corpus are the one-word labels, not the sentences.
    /// `WideFlankLayoutTests` re-measures all twelve on every run rather than trusting these figures,
    /// because a system font update moves them.
    ///
    /// **It is wider than the open island, and that is a departure argued rather than overlooked.**
    /// `flankedWidthGrowth`'s note sets the ceiling for the *glyph* island at "still reads as the
    /// notch itself growing" — 265pt, 15% of a 1728pt display — and this is 401pt, 23%. A shape
    /// carrying a word cannot be narrower than the word; the choice was between spelling the level
    /// and staying inside that figure, and the owner asked for the word (2026-08-28). What keeps it
    /// honest is that it is *momentary*: `ActivityKind.systemHUD` expires after 1.5s, so the island
    /// is this wide for the length of a keypress and back to the cutout after it. Nothing ambient is
    /// allowed on this axis — see `ActivityKind.flankSpan`, where the rule is kept.
    ///
    /// Because it exceeds `expandedBodySize.width`, the collapsed wide island is **not** contained by
    /// the open one, so the widen in `AppDelegate.transition` has to reach past `.expanded` and
    /// `.flankedPeekWithLip` in width. It names `.widerFlankedPeekWithLip` to do it, which contains
    /// this form — see `widerFlankedWidthGrowth`. That is the same accommodation the track lip
    /// already needed, for the same reason, in the other dimension.
    ///
    /// **No longer the widest island Isleta has**, since 2026-09-01: `widerFlankedWidthGrowth` is,
    /// and the figures either side of this paragraph are the HUD's alone.
    public static let wideFlankedWidthGrowth: CGFloat = 216

    /// Total width added when what is on stage spells itself in a **phrase** rather than a noun —
    /// power, and nothing else. Split evenly like the other two, so each flank is 137pt.
    ///
    /// **274, and every point of it is measured, the same way 216 was.** The leading sliver has to
    /// hold the widest battery glyph (all six `battery.*` symbols measure 23pt at 13pt semibold —
    /// wider than any HUD glyph, which is why this is not simply 216 plus the difference in words),
    /// 4pt of spacing, and the label, inside `ActivityContentView.flankPadding`'s 10pt at each end:
    /// 47pt of furniture, leaving 90. Measured in real SF Pro at 12pt medium on 2026-09-01, the
    /// longest label the four shipped languages produce is German's "Sparmodus aus" at 89.8pt, and
    /// the longest English one is "Low Power Off" at 84. `WideFlankLayoutTests` re-measures all
    /// twenty-four on every run rather than trusting these figures, because a system font update
    /// moves them.
    ///
    /// **Why power gets its own constant instead of widening the HUD's.** The two spans are sized to
    /// different words: the longest HUD label is 61pt and the longest power label is 90, so one
    /// shared constant would put "Volume" — 43pt of word — in a 90pt hole and grow the HUD island
    /// from 401pt to 459 to do it. `flankedWidthGrowth`'s note sets the standard the whole shape
    /// language is judged against ("a wider notch, not a black bar that happens to contain the
    /// notch"), and paying that cost on the kind that does not need the room is the wrong half of
    /// the trade. The owner chose the fourth span over the shared one, 2026-09-01.
    ///
    /// It is honest for the same reason 216 is: `ActivityKind.power` is `.prominent` with a 5s
    /// expiry, so the widest island Isleta has is on screen for the length of a charger being
    /// plugged in and is back to the cutout after it. Nothing ambient may reach this span — see
    /// `ActivityKind.flankSpan`, where the rule is kept for both of them.
    ///
    /// Like `wideFlankedWidthGrowth` it exceeds `expandedBodySize.width`, so the collapsed widest
    /// island is **not** contained by the open one and `AppDelegate.transition` names
    /// `.widerFlankedPeekWithLip` in its widen. That call replaced the wide one rather than joining
    /// it: this form contains it, and a union with a subset is the same union.
    public static let widerFlankedWidthGrowth: CGFloat = 274

    /// Height added when the island is carrying flank content: none.
    ///
    /// Zero on purpose, and load-bearing rather than an omission. The flanks are beside the cutout,
    /// so they need width and not height, and growing downward would cross
    /// `ActivitySlotLayout.minimumBodyHeight` (22pt) and afford the *body* slot as well — a strip
    /// of text hanging under the notch at rest, which is a panel, not a notch. Keeping the bottom
    /// edge exactly on the cutout's own is also what makes the widened shape read as one wider
    /// cutout instead of a shape pasted over it.
    public static let flankedHeightGrowth: CGFloat = 0

    /// The lit sliver each side of the cutout once the island is flanked. Derived, so it cannot
    /// drift from the growth it comes from.
    public static var flankedFlankWidth: CGFloat { flankedWidthGrowth / 2 }

    /// The same for a wide island: 108pt each side.
    public static var wideFlankedFlankWidth: CGFloat { wideFlankedWidthGrowth / 2 }

    /// And for the widest: 137pt each side.
    public static var widerFlankedFlankWidth: CGFloat { widerFlankedWidthGrowth / 2 }

    /// The width added for a given span. The one place the two constants are chosen between.
    public static func widthGrowth(for flanks: IslandFlanks) -> CGFloat {
        switch flanks {
        case .none: 0
        case .standard: flankedWidthGrowth
        case .wide: wideFlankedWidthGrowth
        case .wider: widerFlankedWidthGrowth
        }
    }

    // MARK: - The bounce at the end of a range

    /// How far the island leans when a level it is showing reaches the end of its range — see
    /// `IslandScreenModel.limitBounce`.
    ///
    /// **16, and the ceiling on it is the physical notch.** The island slides bodily rather than
    /// stretching, so on a notched Mac the drawn shape moves off the hole underneath it. That is
    /// invisible while the hole stays comfortably inside the island — at `wideFlankedWidthGrowth`
    /// there is 108pt of island either side of a 185pt cutout, so 16 is under a seventh of the
    /// margin — and it would read as the island being *misaligned* rather than springing if it were
    /// a large fraction of it.
    ///
    /// **It started at 8 and was doubled on sight of it**, which is the only instrument that settles
    /// a distance. At 8 the rebound was reported from hardware as never happening: the island is
    /// pure black against a menu bar that is very often black too, so 8pt of edge is 8pt of nothing.
    /// The fix was mostly to move the *content* on that side with the edge — see
    /// `IslandScreenModel.bounceOffset(for:)` — but the travel had to grow with it, because a bar
    /// that shifts by 2% of the island it sits in is a bar that has not moved.
    ///
    /// **It is not part of any form**, and deliberately: the bounce is a position, not a shape, so
    /// `IslandShapeMetrics` never learns about it and the ten-row shape table is untouched. What
    /// does have to learn about it is the hit region — the window server takes the panel's event
    /// shape from the alpha of what we draw, so a translated island is opaque 8pt beyond the region
    /// `islandPath` accepts unless the region is widened to cover the travel. That is
    /// `IslandScreenModel.hitRegionMetrics`, and it widens **symmetrically**, because a symmetric
    /// superset contains the lean in either direction and a superset over transparent pixels is
    /// unreachable anyway.
    public static let limitBounceDistance: CGFloat = 16

    // MARK: - The track lip

    /// Height added below the cutout while the pointer is on the album cover — the strip that says
    /// what is playing. See `IslandForm.showsTrackLip` for why this is allowed to hang under the
    /// notch when `flankedHeightGrowth` is not.
    ///
    /// **40, and every point of it is spent.** Two lines — the title at 14pt and the artist at 12pt
    /// — is 17 + 15 with a point between them, inside 3pt of padding top and bottom: 39, rounded up
    /// to an even number so the strip lands on the pixel grid at 1x and 2x (§6.6). It clears
    /// `ActivitySlotLayout.minimumBodyHeight` (22), which is the floor for the body region being
    /// afforded at all — below it the lip would grow the island and have nowhere to draw.
    ///
    /// **It started at 34 and was made bigger on sight of it**, which is the only instrument that
    /// settles a type size. The strip is read at a glance from a meter away in a notch, not on a
    /// page; 12pt over 10pt was legible and not *comfortable*, and the point of the lip is to save
    /// the click that would have opened the island — a strip somebody has to lean in for saves
    /// nothing.
    ///
    /// **This is the one collapsed shape the open island does not always contain.** The tallest a
    /// collapsed island can be with the lip on is the cutout (32) plus the height adjustment
    /// ceiling (24) plus the peek at 2× (16) plus this: 112, against `minimumExpandedHeight`'s 108.
    /// So `AppDelegate.transition` widens the hit region to this form **as well as** the open one —
    /// see the note there, and `TrackLipTests`, which pins the arithmetic rather than leaving it to
    /// be rediscovered by somebody with both sliders at the top of their range.
    /// **43, up from 40**, and the three points are the audio badge now sharing the artist's row —
    /// see `NowPlayingTrackLipLayout.artistLineHeight`. A constant three, on every track, which is
    /// why the badge went on that row rather than getting one of its own.
    public static let trackLipHeight: CGFloat = 43

    /// The bottom corners while the lip is out.
    ///
    /// Between the cutout's own 12 and the open island's 28, because the shape is between them: an
    /// 80pt-tall island wearing the notch's 12pt corner reads as a rectangle with the edges filed
    /// off, and wearing the open island's 28 reads as the island having opened — which is the one
    /// thing a peek must never look like.
    public static let trackLipBottomCornerRadius: CGFloat = 18

    /// The panel's frame on a given screen, in global (y-up) coordinates.
    ///
    /// Anchored to the top edge of the screen and centerd on the notch, clamped so it never leaves
    /// the display.
    public static func panelFrame(for screen: IslandScreen) -> CGRect {
        let width = min(screen.frame.width, maxExpandedBodySize.width + 2 * panelMargin)
        let height = min(screen.frame.height, maxExpandedBodySize.height)
        var x = screen.notch.rect.midX - width / 2
        x = min(max(x, screen.frame.minX), screen.frame.maxX - width)
        return CGRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// The island's geometry in a given form.
    ///
    /// The top radius stays zero in every state: the island's top edge is against the bezel, and
    /// rounding it would open a sliver of lit pixels between island and bezel.
    ///
    /// Flanked-ness widens rest and peek by the same constant and changes nothing else — not the
    /// radii, not the peek growth, not the expanded size. That is what keeps the whole family
    /// orderable in the one way hit testing depends on: every dimension is monotone in its own
    /// input, so `IslandShapeMetrics.union` of any two of these contains everything between them.
    /// - Parameter sizing: everything the user has said about how big the island is — the peek
    ///   amount, the two collapsed-body adjustments, and compactIsland. One record rather than four
    ///   parameters for the reason `IslandSizing` states: this arithmetic is evaluated twice, once
    ///   for the drawing and once for the hit region, and a dimension that reaches one and not the
    ///   other is clicks landing on lit island pixels and being dropped.
    ///
    ///   None of it disturbs the ordering the note above depends on. `peekScale` scales the peek
    ///   growth only; the two adjustments are added to the collapsed forms *identically*, so rest
    ///   and peek move together and peek stays the larger of the two; and compactIsland touches only the
    ///   expanded default, which stays taller than any collapsed body at every value it can take
    ///   (`miniExpandedBodyHeight` is 156 against a collapsed ceiling of the cutout plus 24).
    ///   Defaulted so the arithmetic stays callable — and testable — with no configuration at hand.
    /// - Parameter expandedContentHeight: how much drawable height the open island has to hold
    ///   below the cutout, or `nil` for the default size. It reaches the *drawn* shape here and the
    ///   *clickable* shape through `IslandController.expandedContentHeight`; the two must be given
    ///   the same value, for the reason `peekScale` must — see `IslandHitTestView` on subsets.
    ///
    ///   It does not disturb the ordering the note above depends on. Only the expanded form reads
    ///   it, and the expanded form is the largest in the family at every height it is allowed to
    ///   take: `minimumExpandedHeight` is taller than any collapsed body, so
    ///   `IslandShapeMetrics.union` of any two forms still contains everything between them.
    /// - Parameter expandedContentWidth: how wide the open island has to be for whatever it is
    ///   showing, or `nil` for the default width. The month grid is the one surface that asks —
    ///   see `GlanceScheduleLayout.bodyWidth`. It reaches the drawn shape and the clickable shape by
    ///   the same two routes `expandedContentHeight` does and carries the same obligation: the two
    ///   must be given the same value. `expandedWidth` says why it can only ever grow the island.
    public static func metrics(
        for form: IslandForm,
        on screen: IslandScreen,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> IslandShapeMetrics {
        let notch = screen.notch.rect.size
        let flankGrowth = form.isFlanked
            ? CGSize(width: widthGrowth(for: form.flanks), height: flankedHeightGrowth)
            : .zero
        let peekGrowth = peekGrowth(scale: sizing.peekScale)
        // The user's own size, added to the collapsed forms and to neither anything else nor
        // differently between them — see `IslandSizing.widthAdjustment`. Never below zero: a body
        // with a negative dimension is a `CGPath` with no area, and `IslandHitTestView` would then
        // reject every click on an island the renderer is still drawing.
        let adjust = sizing.collapsedGrowth
        func collapsed(_ width: CGFloat, _ height: CGFloat) -> CGSize {
            CGSize(width: max(0, width + adjust.width), height: max(0, height + adjust.height))
        }
        switch form.presentation {
        case .rest:
            return IslandShapeMetrics(
                bodySize: collapsed(
                    notch.width + flankGrowth.width,
                    notch.height + flankGrowth.height
                ),
                topCornerRadius: restTopCornerRadius,
                bottomCornerRadius: notchBottomCornerRadius,
                // Only while flanked — or while the user has made the island wider than the cutout,
                // which is the same condition arrived at from the settings window. Unflanked and
                // unadjusted, the island *is* the cutout and its top corners are the cutout's own:
                // there is nothing there to curve, and flaring would draw the island wider than the
                // hole it is pretending to be.
                topFlareRadius: (form.isFlanked || adjust.width > 0) ? flankedTopFlareRadius : 0
            )
        case .peek:
            // The lip is height and nothing else: it hangs below the cutout, so it needs no width,
            // and growing sideways as well would move the flanks the pointer is resting on.
            let lipGrowth = form.showsTrackLip ? trackLipHeight : 0
            return IslandShapeMetrics(
                bodySize: collapsed(
                    notch.width + flankGrowth.width + peekGrowth.width,
                    notch.height + flankGrowth.height + peekGrowth.height + lipGrowth
                ),
                topCornerRadius: restTopCornerRadius,
                bottomCornerRadius: form.showsTrackLip
                    ? trackLipBottomCornerRadius
                    : notchBottomCornerRadius,
                // Always, flanked or not. Peek is already wider and taller than the cutout, so it
                // has two square corners against the ceiling whatever else is going on — which is
                // the same condition that earns the flanked island and the open island theirs.
                // Rest is the only state without one, because unflanked rest *is* the cutout and
                // its corners are the hole's own.
                topFlareRadius: flankedTopFlareRadius
            )
        case .expanded:
            return IslandShapeMetrics(
                bodySize: CGSize(
                    width: Self.expandedWidth(contentWidth: expandedContentWidth),
                    height: Self.expandedHeight(
                        contentHeight: expandedContentHeight,
                        cutoutHeight: screen.notch.cutoutSize.height,
                        // Only the form that *shows* the row pays for it. The plain `.expanded`
                        // form is the island as it was before the row existed, which is what an
                        // open island with the pointer elsewhere still has to look like.
                        pageIndicatorHeight: form.showsPageIndicator ? pageIndicatorHeight : 0,
                        compactIsland: sizing.compactIsland
                    )
                ),
                topCornerRadius: restTopCornerRadius,
                bottomCornerRadius: expandedBottomCornerRadius,
                topFlareRadius: expandedTopFlareRadius
            )
        }
    }

    public static func restMetrics(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard
    ) -> IslandShapeMetrics {
        metrics(for: .rest, on: screen, sizing: sizing)
    }

    public static func peekMetrics(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard
    ) -> IslandShapeMetrics {
        metrics(for: .peek, on: screen, sizing: sizing)
    }

    public static func expandedMetrics(
        for screen: IslandScreen,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> IslandShapeMetrics {
        metrics(
            for: .expanded,
            on: screen,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
    }

    /// The bounding box of a form, in the panel's y-down content space.
    public static func bounds(
        for form: IslandForm,
        on screen: IslandScreen,
        in panelSize: CGSize,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> CGRect {
        let metrics = metrics(
            for: form,
            on: screen,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
        let origin = bodyOrigin(for: metrics, in: panelSize)
        return IslandShapeGeometry.path(metrics: metrics, bodyOrigin: origin).boundingBoxOfPath
    }

    /// The region watched for the pointer, given what the island is currently doing.
    ///
    /// This tracks the largest state reachable *without another click*, and that bound matters in
    /// both directions. Too small and the island growing under a stationary pointer hands itself a
    /// `mouseExited`, collapses, re-enters, and oscillates. Too large — the expanded footprint while
    /// merely resting — and the island stays peeked with the pointer 100pt away over transparent
    /// pixels, because the watchdog still considers it inside.
    ///
    /// Flanked-ness is part of that bound and not an optimisation. A flanked island peeks to
    /// 277pt on this machine against the unflanked 197pt, so tracking the unflanked peek would put
    /// 40pt of lit island either side *outside* the watched region: the pointer could sit on a
    /// visible flank and the 100ms watchdog would read it as having left, collapse, and — with the
    /// pointer still there — immediately re-enter. That is the oscillation, arrived at from the
    /// other direction. Widening to the flanked peek unconditionally has the opposite fault, and it
    /// is the one the comment above names: 40pt each side of dead transparent pixels holding a peek
    /// open on an island that has nothing in its flanks.
    ///
    /// `sizing` reaches here for the same reason it reaches the drawn shape: the region watched for
    /// the pointer is defined as the peek footprint, so a larger peek — or a wider island, or a
    /// shorter open one — that the tracking area did not know about would be an island that grows
    /// past the rect watching it, which is the oscillation described above arrived at from a third
    /// direction.
    public static func hoverRegion(
        isExpanded: Bool,
        flanks: IslandFlanks,
        on screen: IslandScreen,
        in panelSize: CGSize,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> CGRect {
        // **The open island's region is its blur, not its outline.** Leaving is what closes the
        // island now, so the region watched for the pointer leaving is the region the pointer is
        // allowed to be in — and that is the ring of blurred desktop the island draws around itself
        // (`blurRegion`). Without it the island would close the instant the pointer crossed its
        // edge, which on a 368pt panel a user is aiming controls inside is a hair trigger; with it
        // there is 24pt of forgiveness that is *visible*, so the grace is something the user can see
        // rather than something they have to discover.
        guard !isExpanded else {
            return blurRegion(
                isExpanded: true,
                on: screen,
                in: panelSize,
                sizing: sizing,
                expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
        }
        // The *largest state reachable without another click*, which for a closed island is its
        // peek. Sized to the resting form instead, the island would grow out from under the tracking
        // rect on hover, hand itself a `mouseExited`, shrink, and oscillate under a stationary
        // pointer.
        return bounds(
            for: IslandForm(presentation: .peek, flanks: flanks),
            on: screen,
            in: panelSize,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
    }

    /// Where the pointer has to be for a hover to **begin**, as opposed to where it has to leave.
    ///
    /// The island's *resting* shape while closed — so the pointer has to be on the island rather
    /// than near it. `hoverRegion` above stays the peeked shape, and the two together are the
    /// hysteresis: tight to arrive, generous to leave.
    ///
    /// **The open island's asymmetry is the blur**, and it is the same asymmetry as the closed
    /// island's rather than a second idea. Arriving means arriving on the island itself, so the
    /// switcher row is revealed by a pointer that is genuinely on the island — not by one hovering
    /// in the blur beside it. Leaving means leaving the blur too (`hoverRegion` above), so the
    /// island is not closed by a pointer that has only just crossed its edge.
    ///
    /// The form is the one *with* the row, because the row is what the arrival reveals: sized to the
    /// plain `.expanded` form, the island would grow under a stationary pointer and hand itself a
    /// `mouseExited` from the rect it had just outgrown.
    public static func hoverEnterRegion(
        isExpanded: Bool,
        flanks: IslandFlanks,
        on screen: IslandScreen,
        in panelSize: CGSize,
        sizing: IslandSizing = .standard,
        expandedContentHeight: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil,
        pageIndicatorHeight: CGFloat = 0
    ) -> CGRect {
        guard !isExpanded else {
            return bounds(
                for: pageIndicatorHeight > 0 ? .expandedWithPageIndicator : .expanded,
                on: screen,
                in: panelSize,
                sizing: sizing,
                expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
        }
        return bounds(
            for: IslandForm(presentation: .rest, flanks: flanks),
            on: screen,
            in: panelSize,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
    }

    /// Top-left corner of the island body inside the panel's y-down content space.
    ///
    /// The island always hangs from the top edge of the panel, horizontally centerd on the notch.
    public static func bodyOrigin(for metrics: IslandShapeMetrics, in panelSize: CGSize) -> CGPoint {
        bodyOrigin(bodyWidth: metrics.bodySize.width, in: panelSize)
    }

    /// The same corner, from the one dimension it is a function of.
    ///
    /// Its own spelling because the height is genuinely not read here, and a caller that has a width
    /// and no shape should not have to invent the rest of one. What that buys is written on
    /// `IslandScreenModel.contentBodyWidth`: a page that asks for the whole animated shape is
    /// re-laid-out on every frame of a drag for an origin that has not moved.
    public static func bodyOrigin(bodyWidth: CGFloat, in panelSize: CGSize) -> CGPoint {
        CGPoint(x: (panelSize.width - bodyWidth) / 2, y: 0)
    }
}

/// Which displays get an island.
///
/// Pure and free of AppKit so the rule can be tested against display arrangements that are awkward
/// to reproduce by hand.
public enum IslandPlacement {

    /// Isleta presents on displays with a real notch, and nowhere else.
    ///
    /// An external monitor has no notch to be continuous with, so an island there is a floating
    /// black rectangle stuck to the top of someone's screen — a different product. The island only
    /// makes sense where there is a cutout for it to be part of.
    ///
    /// The exception is a Mac with no notched display at all — a mini, a Studio, an iMac. There the
    /// synthesized island is the only way the app exists, so the primary display gets one. "Primary"
    /// means the display at the coordinate origin (the one holding the menu bar in Displays
    /// arrangement), not `NSScreen.main`, which follows keyboard focus and moves around.
    public static func displays(from screens: [IslandScreen]) -> [IslandScreen] {
        let notched = screens.filter { $0.notch.kind == .hardware }
        guard notched.isEmpty else { return notched }

        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary.map { [$0] } ?? []
    }
}
