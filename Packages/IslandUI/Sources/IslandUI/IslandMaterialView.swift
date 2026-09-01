import IslandKit
import SwiftUI

/// What the island is made of, drawn.
///
/// Split out of `IslandRootView` because there are now three materials and a shadow behind one
/// `switch`, and because the two traps below are the sort that get re-introduced by somebody
/// simplifying a view they are only passing through.
///
/// ## `glassEffect(_:in:)` renders nothing against a custom `Shape`
///
/// Zero alpha, not merely invisible, on macOS 26.5/27.0. It works only with SwiftUI's own shape
/// types, and filling the shape first does not rescue it. Measured: the same view with
/// `RoundedRectangle` renders and with a custom conformance it does not, even when that
/// conformance's path fills the whole rect. The island looked fine either way — and the window
/// server saw no pixels and passed every click straight through it.
///
/// So the glass is rendered against a built-in shape and then `.mask`ed to ours. The compromise is
/// that the glass computes its edge treatment for the `RoundedRectangle`, so the rim highlight does
/// not follow the concave corners.
///
/// ## The glass goes *under* the content, never behind it with `.background(_:)`
///
/// `content.background(RoundedRectangle().glassEffect(...))` composites the glass **above** the
/// content, so every label and control draws blurred and unreadable through it — and it looks
/// deliberate enough to be mistaken for the design. That is why this is a sibling *below* the
/// activity layers in `IslandRootView`'s `ZStack` rather than a modifier on them.
///
/// ## Nothing here redraws per frame, and that is a hard requirement
///
/// Measured 2026-08-23: per-frame drawing from this process through SwiftUI's `Canvas`/
/// `TimelineView` costs **17.7% of a core and 279MB**, and it is *not* a function of how big the
/// animating view or its panel is — a 40×32pt panel measured the same as a 608×200pt one. Six
/// `CALayer`s with a `CABasicAnimation` doing the same job measured 0.007%. So a pulsing rim, an
/// animated gradient or a shimmer does not belong in this file at any size; if one is ever wanted,
/// it is CoreAnimation on the render server, not a SwiftUI redraw. Every material below is
/// **static** — SwiftUI draws it once and the window server composites it from then on.
struct IslandMaterialView: View {

    let material: IslandMaterial
    let shape: IslandShape

    /// The user's opacity for a *synthesized* island. 1 on a hardware notch, where §6.4's pure
    /// black is a correctness requirement rather than a style and there is nothing to dim.
    let opacity: Double

    /// Whether the island casts a shadow onto the screen below it.
    let showsShadow: Bool

    /// How tall the island is right now, in points, so `SemiGlassUnderlay` can put its fade a fixed
    /// distance from the bottom edge.
    ///
    /// **Handed in rather than read from a `GeometryReader`**, which the first version of this did.
    /// The reader was not what broke pass-through — see `semiGlassUnderlay`, which records what was
    /// — but the model already knows this number, `IslandShapeMetrics` is publishing it on the
    /// spring anyway, and a full-panel `GeometryReader` inside `NSHostingView` is a thing this file
    /// would then have to keep proving innocent every time the self-test moved.
    let height: CGFloat

    /// The height the island has when it is closed — the screen's cutout, real or synthesized.
    ///
    /// The reference `SemiGlassUnderlay` measures growth against, so the glass tip can be absent on
    /// a closed island and present on an open one. A constant would not do: a cutout is 32pt on this
    /// machine and is a property of the display, and a synthesized island is whatever
    /// `NotchResolver` made up for that screen.
    let restingHeight: CGFloat

    /// §6.4's black, spelled in sRGB rather than as `Color.black` so it can never pick up a dynamic
    /// or appearance-sensitive variant and lift off the bezel by a shade.
    static let black = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)

    /// Where the black stops and the glass starts, under Semi-Liquid Glass.
    ///
    /// **This replaced a flat 0.55 across the whole island, and the flat version was wrong on
    /// hardware.** A uniform veil makes the *top* of the island — the part that has to be optically
    /// continuous with the bezel — a shade lighter than the bezel, which is the exact failure §6.4
    /// spells `Color.black` in sRGB to avoid. It also puts the glass where nobody can see it: at
    /// rest and at peek the top of the island is the cutout, and a cutout is a hole with no pixels
    /// in it.
    ///
    /// So the black is solid at the top and clears at the bottom tip. See `SemiGlassUnderlay`.
    static let semiGlassUnderlayOpacity: Double = SemiGlassUnderlay.topOpacity

    /// How far the island's own shadow reaches, and how dark it is.
    ///
    /// Small on purpose, and it is not only taste: the shadow paints alpha **outside** `islandPath`,
    /// and the window server derives the panel's event shape from the alpha of the backing store —
    /// so every point the shadow reaches is a point the window server may start routing to us, where
    /// `IslandHitTestView` will then reject it and the click will land nowhere. Whether the server's
    /// threshold actually catches a shadow this faint is a measurement rather than a guess: see
    /// PROGRESS.md, and `PassThroughSelfTest` is what answers it.
    static let shadowRadius: CGFloat = 10
    static let shadowOpacity: Double = 0.34
    static let shadowOffset: CGFloat = 3

    var body: some View {
        Group {
            switch material {
            case .opaque:
                shape.fill(Self.black).opacity(opacity)
            case .semiGlass:
                // **Glass underneath, black on top, and each masked to its own half.**
                //
                // The z-order is not a preference — it decides whether the island is see-through at
                // all. `glassEffect` samples what is *behind* it, and for a transparent panel that
                // is the desktop. Put the black fill behind the glass and the glass samples the
                // black: the tip renders as black-with-a-sheen over a white window, which is a
                // fully opaque island reported from hardware. So nothing opaque may sit behind the
                // glass anywhere the glass is meant to show through.
                //
                // The two masks are complements of one gradient, so the layers do not overlap: the
                // top is black and nothing else, the tip is glass and nothing else, and across the
                // transition their alphas sum to one. That is what keeps the closed island's edge
                // clean — at rest the tip's mask is zero everywhere, no glass is drawn, and there
                // is no second antialiased outline to leak a rim of light around the black.
                //
                // The top of the island has no rim, which is the right way round: on a hardware
                // notch the top *is* the cutout, and a rim drawn there is drawn on a hole.
                ZStack {
                    semiGlassTip
                    semiGlassBlack
                }
                .opacity(opacity)
            case .glass:
                // **Black at rest, glass once it opens** — the same rule Semi-Liquid Glass has
                // always had for its tip, applied to the style that never got it.
                //
                // At rest the island *is* the cutout, and a cutout is a hole with no pixels behind
                // it. Glass there does not reveal anything: it draws a visible pill around a hole,
                // with a hard edge where the black island has none, because the black island at
                // rest is invisible against the bezel by construction (§6.4). Reported from
                // hardware as the closed island not curving out the way the normal one does.
                //
                // Ordered so that at rest **no glass is drawn at all**, rather than drawn and
                // covered. Glass under an opaque fill antialiases against the same outline and
                // leaks a rim of light around the edge — the bug that put a hairline around the
                // closed island this morning.
                ZStack {
                    glass.opacity(glassPresence)
                    scrim.opacity(glassPresence)
                    shape.fill(Self.black).opacity(1 - glassPresence)
                }
                .opacity(opacity)
            }
        }
        // Applied outside the `switch` so all three styles cast the same shadow — a shadow that
        // differed by material would be a second thing changing when the user changes the first.
        //
        // **Only once the island is open**, and on the same ramp the glass arrives on. At rest the
        // island *is* the cutout, and a shadow under a hole is a smudge on the bezel around
        // something that is meant to be invisible there (§6.4) — reported from hardware as the
        // closed island having a halo. Everything about it scales together, so the shadow grows
        // with the island rather than switching on part-way through the opening spring.
        .shadow(
            color: Color.black.opacity(Self.shadowOpacity * shadowPresence),
            radius: Self.shadowRadius * CGFloat(shadowPresence),
            y: Self.shadowOffset * CGFloat(shadowPresence)
        )
    }

    /// Solid black down most of the island, clearing through the bottom tip.
    ///
    /// ## `shape.fill(LinearGradient)` widens the window's event shape, and `.mask` does not
    ///
    /// This is a solid fill with a gradient **mask**, and it reads as the long way round to write
    /// `shape.fill(gradient)`. It is not. Measured 2026-08-23, one variable at a time, on macOS 27:
    /// with `shape.fill(LinearGradient(...))` the pass-through self-test under Semi-Liquid Glass
    /// went from **12/12 to 7 ok, 5 FAILED** — `corner-left`, `corner-right`, `outside-left`,
    /// `outside-right` and `beside-top`, every one of them a point *outside* the island that must
    /// reach the app below. The same shape, the same gradient, the same stops, expressed as
    /// `shape.fill(solid).mask(gradient)`: **12/12**. A flat `shape.fill(black)` in the same
    /// position: 12/12. So it is the gradient *fill* and nothing else.
    ///
    /// Two things make it expensive to find. The alpha is **lower** than the solid fill it replaces,
    /// so every instinct says pass-through should get better rather than worse. And `ClickSelfTest`
    /// passes throughout — clicks on the island still work perfectly; what breaks is clicks on the
    /// desktop *beside* it, which land nowhere. Only `PassThroughSelfTest` can see it, and only when
    /// it is run against this style rather than the default.
    ///
    /// ## Why the fade needs a height at all
    ///
    /// It is a *distance from the bottom edge* rather than a fraction of the island — see
    /// `SemiGlassUnderlay`. A fixed fraction reads as a different design at every size: on a 200pt
    /// open island a quarter is a tip, and on a 40pt peek it is most of the island.
    /// The black that is the island everywhere the tip is not.
    ///
    /// A solid fill with a gradient **mask**, which reads as the long way round to write
    /// `shape.fill(gradient)`. It is not. Measured 2026-08-23, one variable at a time: with
    /// `shape.fill(LinearGradient(...))` the pass-through self-test under Semi-Liquid Glass went
    /// from **12/12 to 7 ok, 5 FAILED** — every one of them a point *outside* the island that has to
    /// reach the app below. The same shape, gradient and stops as `fill(solid).mask(gradient)`:
    /// 12/12. A flat `shape.fill(black)`: 12/12. So it is the gradient *fill* and nothing else.
    ///
    /// Two things make that expensive to find. The alpha is **lower** than the solid fill it
    /// replaces, so every instinct says pass-through should improve rather than break. And
    /// `ClickSelfTest` passes throughout: clicks on the island still work, and what stops working is
    /// clicks on the desktop beside it.
    private var semiGlassBlack: some View {
        shape.fill(Self.black).mask(fade { $0 })
    }

    /// The gradient both layers are masked by, **sized to the island rather than to the panel**.
    ///
    /// This is the bug semi-glass shipped with, and it made the whole style inert. `SemiGlassUnderlay`
    /// returns stop locations as fractions of the *island's* height, and a `LinearGradient` used as a
    /// mask spans whatever it is given — which here is the panel. The panel is 608×400 and never
    /// changes size (§4.2); an open glance is about 180pt of it. So a fade computed to begin at 0.61
    /// of the island began at 0.61 of the **panel**, 244pt down, and the island ended at 180. Every
    /// pixel of it fell in the gradient's flat opaque run, at every size the island ever takes. The
    /// tip was drawn correctly the whole time, into empty panel space below the island where there is
    /// nothing to draw.
    ///
    /// It survived because it fails in the direction that looks deliberate: solid black is exactly
    /// what the style is supposed to be for most of its height, and nobody can see a missing tip on a
    /// dark desktop. It took a striped background and a pixel probe to tell "no tip" from "a tip you
    /// cannot make out".
    ///
    /// The gradient is therefore given the island's height and pinned to the top, which is where
    /// `IslandLayout.bodyOrigin` puts the island — `((panel − body) / 2, 0)`. Below it the mask is
    /// empty, which hides nothing that is drawn: the shape does not reach there either.
    private func fade(_ transform: @escaping (Double) -> Double) -> some View {
        LinearGradient(
            stops: SemiGlassUnderlay.stops(inHeight: height, restingHeight: restingHeight).map {
                Gradient.Stop(color: .white.opacity(transform($0.opacity)), location: $0.location)
            },
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(0, height))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var semiGlassTip: some View {
        // `glass` is already masked to the island, so this second mask is the *intersection* — the
        // tip is glass inside the shape and nothing anywhere else.
        //
        // The stops describe how much **black** there is, which is what they have always described
        // and what `SemiGlassUnderlay`'s whole vocabulary is written in. Inverting them here rather
        // than adding a second set keeps one definition of where the tip starts: a file with both
        // `blackStops` and `glassStops` is a file where they can disagree by a stop.
        glass.mask(fade { 1 - $0 })
    }

    /// How far Liquid Glass is darkened so the island's own content stays legible on it.
    ///
    /// **The island cannot borrow contrast from the desktop, so it has to bring its own.**
    /// `Glass.regular` adapts to whatever is behind it — light over a white window, dark over a dark
    /// one — and white text on the light version is unreadable, which is how this style shipped and
    /// was reported. The obvious fix is to adapt the *text* as well, and it does not work here:
    ///
    /// - `.foregroundStyle(.primary)` inside a `glassEffect` genuinely does adapt, and was measured
    ///   doing it — a title drawn `.primary` came out black on light glass rather than white.
    /// - But it resolves from the environment's `colorScheme`, **not** from the backdrop. SwiftUI has
    ///   no mechanism to sample the desktop behind a transparent panel and re-resolve a foreground
    ///   style. So on a Mac in Light Appearance the text is black over *everything*, and a dark
    ///   window behind the island gives dark-adapted glass with black text on it — the same failure,
    ///   moved. AppKit's `NSVisualEffectView` vibrancy is the only thing that tracks a backdrop, and
    ///   it does not compose with `glassEffect`.
    ///
    /// A scrim between the glass and the content settles it in one place instead of at 136 call
    /// sites: the glass still refracts what is behind it, the island keeps a tone of its own, and
    /// white content is legible over any desktop. It is also what the design this was measured
    /// against does — its glass is plainly darker than the wallpaper it sits on.
    ///
    /// Above the glass rather than below it. Anything opaque *behind* the glass is sampled by it and
    /// comes back as the glass's own color, which is the bug that made Semi-Liquid Glass render as
    /// flat black.
    static let glassScrimOpacity: Double = 0.32

    /// How much of Liquid Glass is showing, 0 closed through 1 open.
    ///
    /// `SemiGlassUnderlay.fadePresence` by value rather than by coincidence: the two styles are
    /// answering the same question — "has the island grown enough that there are pixels behind it
    /// worth showing?" — and a peek must look like the closed island wearing a slightly larger
    /// shape in both. Because the height is the **animated** one, the glass arrives over the
    /// opening spring rather than appearing when it gets there.
    private var glassPresence: Double {
        Self.openPresence(inHeight: height, restingHeight: restingHeight)
    }

    /// How much shadow is cast, 0 closed through 1 open — and 0 throughout when the user has not
    /// asked for one.
    private var shadowPresence: Double {
        Self.shadowPresence(showsShadow: showsShadow, height: height, restingHeight: restingHeight)
    }

    /// How much shadow an island of this height casts, 0 through 1.
    ///
    /// Static so the rule can be tested without a view: a closed island casts nothing, whatever the
    /// setting says, because at rest the island is the cutout and the shadow would fall on the bezel
    /// around a hole.
    nonisolated static func shadowPresence(
        showsShadow: Bool, height: CGFloat, restingHeight: CGFloat
    ) -> Double {
        guard showsShadow else { return 0 }
        return openPresence(inHeight: height, restingHeight: restingHeight)
    }

    /// How open the island is, 0 at rest through 1 fully open, on the animated height.
    ///
    /// One question with one answer, asked by the glass and by the shadow: "has the island grown
    /// enough that what it draws outside the closed shape belongs on screen?" A peek answers no in
    /// both — it is an invitation to click, and it must look like the closed island wearing a
    /// slightly larger shape rather than one that has started casting.
    nonisolated static func openPresence(inHeight height: CGFloat, restingHeight: CGFloat) -> Double {
        SemiGlassUnderlay.fadePresence(inHeight: height, restingHeight: restingHeight)
    }

    /// The tone Liquid Glass carries so its content does not depend on the desktop.
    private var scrim: some View {
        shape.fill(Self.black.opacity(Self.glassScrimOpacity))
    }

    /// Liquid Glass, drawn against a shape SwiftUI will actually render and then masked to ours.
    ///
    /// ## The rect it is drawn against is the island's own, and that is the whole difference
    ///
    /// This used to be a full-panel rectangle with a zero corner radius, masked down to the island.
    /// The island is 368pt wide inside a panel of 608×200, so **every edge Apple drew was outside
    /// the mask**. Liquid Glass is mostly its edge — the rim highlight and the lensing that bends
    /// what is behind it are computed at the shape's boundary — so masking a panel-sized sheet threw
    /// all of it away and kept the interior, which is a blur and a tint. That is why the island read
    /// as "dark frosting" rather than as Apple's material, and it was invisible in isolation: the
    /// picture looks like glass until you put it beside something that is.
    ///
    /// So the glass is given a rect the size of the island, with the island's own bottom radius.
    /// `IslandLayout.bodyOrigin` is `((panel − body) / 2, 0)`, so a plain `.frame` inside a
    /// top-aligned, horizontally-centerd container lands exactly on the island — no `GeometryReader`,
    /// which this file has its own reasons to avoid.
    ///
    /// The mask stays, and still earns its place: it cuts the two **concave** corners where the
    /// island flares into the bezel, which no built-in shape can express. Those corners keep no rim.
    /// On a hardware notch that is right rather than a compromise — that edge is the cutout, and a
    /// rim highlight there is drawn on a hole.
    ///
    /// ## Why a built-in shape at all
    ///
    /// `glassEffect(_:in:)` renders **nothing** — zero alpha, not merely invisible — against a
    /// custom `Shape` conformance on macOS 26.5/27.0. Measured: the same view with
    /// `RoundedRectangle` renders and with `IslandShape` does not, even when its path fills the
    /// whole rect. Passing `shape` here directly is the obvious simplification and it silently
    /// produces an island with no pixels, which the window server then treats as nothing to route
    /// clicks to.
    private var glass: some View {
        Color.clear
            // **The bounding size, not the body size.** The top flare is the one part of the island
            // that paints *outside* `bodySize` — `IslandShapeGeometry` says so on `topFlareRadius`
            // — and a mask can only take away. Drawn at body width, the flare had no glass in it and
            // the island ended in a hard vertical edge exactly where the black one curves out into
            // the bezel.
            .frame(
                width: IslandShapeGeometry.boundingSize(for: shape.metrics).width,
                height: shape.metrics.bodySize.height
            )
            .glassEffect(
                .regular,
                // **Square at the top, rounded at the bottom.** A `RoundedRectangle` rounds all four
                // corners, and a mask can only take away — so the island's own top corners had no
                // glass drawn in them and what showed was the *rounded rectangle's* corner, floating
                // clear of the bezel. On a hardware notch the island's top edge is the top of the
                // screen and its top corners flare **outward** into the bezel; there is nothing
                // there to round. Reported from hardware as the island looking rounded at the top
                // instead of flanking out.
                //
                // `UnevenRoundedRectangle` is a built-in shape, so it is not the custom-`Shape`
                // trap below: `glassEffect` renders against it.
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: shape.metrics.bottomCornerRadius,
                    bottomTrailingRadius: shape.metrics.bottomCornerRadius,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(shape)
    }
}


/// How the black under Semi-Liquid Glass is distributed down the island.
///
/// Pure and separate from the drawing, for the reason every rule in this package is: "how much of a
/// 40pt peek is glass" has one answer and should be answerable without a window server.
///
/// ## A closed island has no glass tip at all
///
/// At rest the island **is** the cutout, and its bottom edge is the bottom of the notch. A glass rim
/// drawn there is a white line across the bottom of the hole — reported from hardware, and the
/// reason the fade is measured against how far the island has *grown* rather than against how tall
/// it is. Below `quietGrowth` there is no fade, and the tip grows in over the next `rampGrowth`
/// points. Because the height is the **animated** one, that ramp happens on the island's own spring:
/// the glass arrives as the island opens rather than appearing when it gets there.
///
/// ## The fade is a distance from the bottom, not a fraction of the island
///
/// The island is 32pt at rest, 40pt peeked and up to 200pt open, and "the bottom tip" has to mean
/// the same thing at the sizes where it is drawn at all. A fixed fraction does not: a quarter of an
/// open island is a tip, and a quarter of a peek is most of it. So the fade is `fadeHeight` points
/// tall — **capped** at `maximumFadeFraction` of the island, which is what stops a short island
/// being glass most of the way up.
///
/// ## The bottom really does reach zero
///
/// `bottomOpacity` is 0, so the last row of pixels is glass and nothing else. That is safe for the
/// reason the Liquid Glass style is safe: `glassEffect` paints real alpha, the window server derives
/// the panel's event shape from that alpha, and a fully glass island is clickable today.
/// `PassThroughSelfTest` and `ClickSelfTest` are run against this style rather than only against the
/// default, and the reason they have to be is in `IslandMaterialView.semiGlassUnderlay`.
enum SemiGlassUnderlay {

    /// Solid, and solid means solid. Anything less makes the top of the island lighter than the
    /// bezel it has to disappear into, which is the one thing §6.4 is written to prevent.
    static let topOpacity: Double = 1

    /// How much black is left at the very bottom edge.
    ///
    /// **Not zero.** It was, and a tip that reaches fully clear glass takes the desktop's own
    /// contrast with it: over a bright window the last centimetre of the island became whatever was
    /// behind it, white text included, and the island stopped having a bottom edge of its own. A
    /// floor keeps the tip reading as *the island, made of glass* rather than as a hole in it.
    ///
    /// 0.32 is enough to hold the edge and the text on it, and little enough that what is behind
    /// the island is plainly legible through the tip — which is the whole point of the style.
    static let bottomOpacity: Double = 0.32

    /// How tall the fade is, in points, on an island grown enough to afford all of it.
    ///
    /// **70, up from 46, and a design reference is what set it.** At 46 the glass was a lip along
    /// the bottom edge — visible, but reading as a highlight on a black island rather than as the
    /// island turning to glass. In the design this is measured against, the black is solid across
    /// the top half and what is behind the island is fully legible by the bottom edge.
    ///
    /// 70 rather than the 90 that would match that reference exactly on a 200pt island, because 90
    /// would put the *cap* in charge on everything shorter: 162 × 0.45 is 73, so a glance would fade
    /// over 73pt and a player over 90, and "the bottom tip" would mean two different distances on
    /// two islands the user sees minutes apart. At 70 the cap binds on neither, the tip is one
    /// distance everywhere, and it is 43% of a glance — inside the range the reference sits in.
    /// `theFadeIsAbsolute` is the test that holds this, and it is the reason these two numbers have
    /// to be chosen together rather than one at a time.
    static let fadeHeight: CGFloat = 70

    /// The most of an island the fade may ever take.
    ///
    /// 0.45, and with `fadeHeight` at 70 it binds on nothing the island normally opens to.
    ///
    /// That is the point of it. It was a third, and a third was small enough to take charge of the
    /// fade on ordinary islands, which made this a *styling* number when it was only ever meant to
    /// be a guard: the thing that stops a short island — a stubby synthesized cutout past the ramp
    /// — being glass most of the way up. It still does exactly that, on the sizes where it should.
    ///
    /// The risk it was written against is real: below about half, the island stops reading as
    /// "black with a glass tip" and starts reading as "glass with a dark top", which is the Liquid
    /// Glass style with a bruise. 0.45 keeps the top half solid at every size.
    static let maximumFadeFraction: Double = 0.45

    /// How far the island may grow before any glass shows at the bottom edge.
    ///
    /// `IslandLayout.peekHeightGrowth`, by value rather than by reference — a peek is an invitation
    /// to click and must look like the closed island wearing a slightly larger shape, not like a
    /// different material. The two numbers are the same for a reason and not by coincidence, and if
    /// the peek grows this should grow with it.
    static let quietGrowth: CGFloat = 8

    /// Over how much further growth the tip arrives at its full length.
    ///
    /// The island opens from the cutout to somewhere over 100pt, so this is most of the way through
    /// the opening animation rather than a step at the end of it.
    static let rampGrowth: CGFloat = 48

    /// How much of the tip is drawn, 0 through 1, for an island of this height.
    static func fadePresence(inHeight height: CGFloat, restingHeight: CGFloat) -> Double {
        let growth = Double(height - max(0, restingHeight))
        guard growth > Double(quietGrowth) else { return 0 }
        return min(1, (growth - Double(quietGrowth)) / Double(rampGrowth))
    }

    /// Where the fade begins, as a fraction from the top. 1 means there is no fade at all.
    static func fadeStart(inHeight height: CGFloat, restingHeight: CGFloat) -> Double {
        guard height > 0 else { return 1 }
        let presence = fadePresence(inHeight: height, restingHeight: restingHeight)
        let fade = min(Double(fadeHeight), Double(height) * maximumFadeFraction) * presence
        return max(0, min(1, 1 - fade / Double(height)))
    }

    /// How many stops the eased part of the fade is drawn with.
    ///
    /// A `LinearGradient` interpolates *linearly* between the stops it is given, so the curve below
    /// has to be sampled rather than described. Twelve is past the point where more stops change
    /// the picture: the fade is 70pt at most, so this is a step every 6pt, and the linear segments
    /// between them are shorter than the blur they are seen through.
    static let easedStopCount = 12

    /// The fade's shape, 0 at the top of the fade and 1 at the bottom edge.
    ///
    /// Smoothstep, which is flat at **both** ends. That is the whole reason it is here rather than
    /// a straight ramp, and it answers the two things a ramp got wrong:
    ///
    /// - **Where the fade begins.** A ramp meets the solid black run at an angle — the opacity is
    ///   constant, then abruptly falls at a fixed rate — and the eye reads that corner as an edge
    ///   across the island, which is exactly what the style is trying not to have. Smoothstep leaves
    ///   the flat run with zero slope, so there is no corner to find: the two runs share a tangent.
    /// - **Where it ends.** Arriving at the bottom edge still descending puts the fastest part of
    ///   the change against the island's own rim. Levelling off first lets the tip settle into its
    ///   final tint a few points before the edge.
    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    /// The gradient, as opacity-and-location pairs.
    ///
    /// A flat run and then a sampled curve. The flat run is not decoration: a gradient that eases
    /// the whole way down is black at exactly one row of pixels and lighter than the bezel
    /// everywhere else, which is the flat-veil bug §6.4 exists to prevent.
    static func stops(
        inHeight height: CGFloat,
        restingHeight: CGFloat
    ) -> [(opacity: Double, location: Double)] {
        let start = fadeStart(inHeight: height, restingHeight: restingHeight)
        // No tip: solid all the way down, and the last stop is black rather than clear. Expressed as
        // a gradient with no gradient in it rather than as a separate branch, so a closed island and
        // an opening one go through the same arithmetic and cannot disagree at the moment they meet.
        guard start < 1 else { return [(topOpacity, 0), (topOpacity, 1)] }
        var result: [(opacity: Double, location: Double)] = [(topOpacity, 0), (topOpacity, start)]
        for step in 1...easedStopCount {
            let t = Double(step) / Double(easedStopCount)
            result.append((
                opacity: topOpacity + (bottomOpacity - topOpacity) * ease(t),
                location: start + (1 - start) * t
            ))
        }
        return result
    }
}
