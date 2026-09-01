import AppKit
import IslandKit
import SwiftUI

/// The desktop, blurred, in a soft band around the **open** island.
///
/// ## It is a region first and a picture second
///
/// The island now closes when the pointer leaves it, and a 368pt panel whose edge is a hair trigger
/// is unusable — a pointer traveling to a control near the rim would close the thing it was aiming
/// at. So there is 24pt of forgiveness around the island (`IslandLayout.blurSpread`), and this draws
/// it. That is the whole argument for it existing: the grace region is made **visible**, so it is
/// something the user can see rather than something they have to discover by losing the island a few
/// times.
///
/// The three facts about that band therefore have to agree, and each lives in exactly one place:
///
/// - what is **drawn** is here,
/// - what the pointer may rest in without closing is `IslandLayout.hoverRegion` for an open island,
/// - what a click in it does is `IslandHitTestView.blurRegion` and `onBlurClick` — it closes, which
///   is what a click anywhere else outside the island already did.
///
/// ## Blur and black, and nothing else
///
/// No glow, no color, no rim: the band is the user's own desktop, blurred and darkened, and every
/// visible property beyond those two is a property somebody has to defend against §6.4's bezel.
/// That is also why it is `NSVisualEffectView` and not `glassEffect` — Liquid Glass is mostly its
/// *edge*, and this band has no edge to give it, because the whole point is that it ends in
/// nothing. `NSVisualEffectView` has no zero-tint material, so the choice is which one tints least:
/// `.fullScreenUI` pinned to dark appearance, measured against `.hudWindow` and
/// `.underWindowBackground` on hardware. See `BackdropBlurView` for what each of those looked like
/// and why the appearance is pinned rather than followed.
///
/// The darkening is `Self.darkening`, and it is there because no material can go darker than its
/// own floor — see it for the halo that costs.
///
/// ## It draws nothing at rest, and that is not an optimisation
///
/// `presence` is `IslandMaterialView.openPresence`, the same ramp Liquid Glass and the shadow arrive
/// on, so a closed island and a peek have no blur at all — and the view is not merely transparent
/// there, it is **absent**. Two reasons, and the first is the one that would have bitten:
///
/// - An `NSVisualEffectView` with behind-window blending is work the *window server* does on our
///   behalf, and it does not stop doing it because a layer above is at zero opacity. §9's idle
///   budget is measured on a closed island, which is the state Isleta is in essentially always, so
///   this has to not exist there rather than be invisible there.
/// - At rest the island *is* the cutout, and a cutout is a hole. A band of blur around a hole is a
///   smudge on the bezel — the same verdict the shadow got from hardware on 2026-08-24, which is
///   why it moved onto this ramp in the first place.
///
/// ## Where the alpha goes
///
/// The band paints **outside** `islandPath`, so the window server starts routing clicks in it to us
/// — a shadow at 10pt/0.34 measured under that threshold, and a blur this size is plainly not going
/// to. That is why `IslandHitTestView.blurRegion` exists and accepts, rather than this being drawn
/// and hoped about. See `IslandLayout.blurRegion`.
struct IslandBlurView: View {

    /// The island's **animated** metrics, so the blur travels with the shape rather than snapping to
    /// where it is going. The same rule `islandPath` and the semi-glass fade both follow.
    let metrics: IslandShapeMetrics

    /// How open the island is, 0 through 1 — `IslandMaterialView.openPresence`.
    let presence: Double

    /// Whether the user has asked the system for less transparency. §6.3 makes honoring it a
    /// correctness requirement rather than a courtesy, and this band is a material by definition: it
    /// is nothing *but* the desktop, blurred.
    ///
    /// So under reduce transparency it is **not drawn at all**, rather than replaced with a tinted
    /// stand-in. A dark bloom would be the obvious substitute and it is the wrong one twice over: it
    /// puts color around an island whose edge has to be invisible against the bezel, and it is a
    /// decoration nobody asked for offered to the one user who has explicitly asked for fewer of
    /// them. Nothing about the *behavior* changes — the grace region and the click that closes are
    /// `IslandLayout.hoverRegion` and `IslandHitTestView.blurRegion`, neither of which is drawn.
    let reduceTransparency: Bool

    /// How much of the blur is actually shown, at a fully open island.
    ///
    /// **The blur is meant to be noticed only if you look for it.** Drawn at full strength it reads
    /// as a slab of frosted glass laid over the desktop — a second object beside the island, which
    /// is the opposite of the job: the island is the thing on screen, and this is the edge of its
    /// authority made faintly visible. Judged against Alcove's, which is the reference this was
    /// asked to match: a soft, barely-there softening of what is behind, not a panel.
    ///
    /// It is a **look** and nothing else — raising it cannot cost a click, and lowering it cannot
    /// buy one. That was measured the hard way: with the blur drawn in the island's own panel,
    /// `--click-test` swept the band at 2, 6, 12 and 20pt out across strengths of 0.34, 0.20, 0.12
    /// and 0.06 and found it *claimed at every point and every strength* — an `NSVisualEffectView`
    /// is opaque to the window server wherever its mask reaches, however faint it looks. That is why
    /// the blur lives in `IslandBlurPanel` now, and why this number is free to be chosen by eye.
    static let strength: Double = 0.34

    /// How much black is laid over the blur, at a fully open island.
    ///
    /// **A material cannot go darker than its own floor, and over a dark window that floor is a
    /// halo.** `NSVisualEffectView` in dark appearance is a blur plus a gray, and the gray does not
    /// get out of the way when what is behind the window is already darker than it: over a black
    /// terminal or a dark editor the band came back *lighter* than the window it sat on — reported
    /// from hardware as the shadow around the island looking white. There is no material and no
    /// appearance that fixes it, because every one of them has the same floor; the only surface with
    /// no floor is one we draw ourselves.
    ///
    /// So the band is the blur with black over it. Black, not a dark gray and not a color: this
    /// hangs off a shape whose whole job is to be indistinguishable from the bezel (§6.4), and the
    /// one tint that can never be seen *as* a tint there is the bezel's own. Over a light desktop it
    /// reads as the soft shadow the band already looked like; over a dark one it reads as nothing,
    /// which is the entire point — a band that is darker than its surroundings is a shadow, and a
    /// band that is lighter is a glow around a hole.
    ///
    /// Its own number rather than a lower `strength`, because they are two different pictures:
    /// `strength` is how much the desktop behind is *softened*, this is how far down it is *pushed*.
    /// Turning one to fix the other is what makes the band read as frosted glass at one end of the
    /// dial and as a smudge at the other.
    static let darkening: Double = 0.22

    var body: some View {
        // **Absent, not transparent** — see the note above. `presence` crosses zero only once the
        // island has grown past `SemiGlassUnderlay.quietGrowth`, so a peek never builds one.
        if presence > 0, !reduceTransparency {
            ZStack {
                BackdropBlurView()
                    .mask(bandMask)
                    .opacity(presence * Self.strength)

                // Over the blur, and masked separately rather than the two being grouped and masked
                // once. A `compositingGroup()` around a behind-window `NSVisualEffectView` renders
                // it offscreen, and a backdrop taken offscreen has no backdrop to sample — the band
                // would come back empty. Two masks of the same shape is a cheap price for not
                // finding that out on hardware.
                Color.black
                    .mask(bandMask)
                    .opacity(presence * Self.darkening)
            }
        }
    }

    /// The island's outline grown by `blurSpread` and blurred, which is the band's whole shape.
    ///
    /// There is deliberately **no punch-out of the island itself**. This is the bottom layer of what
    /// is on screen — the island's own panel draws over the middle of it — so a `.destinationOut`
    /// pass to remove what is already covered would buy nothing but an offscreen compositing group
    /// on every frame of the opening spring.
    private var bandMask: some View {
        IslandShape(metrics: IslandLayout.blurMetrics(for: metrics))
            .fill(.white)
            .blur(radius: IslandLayout.blurSoftness)
    }

}

/// A plain behind-window blur of whatever is underneath the panel.
///
/// `.behindWindow` blending rather than `.withinWindow`: the panel is transparent, so there is
/// nothing within it to blur — the picture is the user's desktop, which lives behind the window and
/// is the window server's to sample.
private struct BackdropBlurView: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        // **Dark appearance, always, whatever the Mac is set to.** Not a style choice — measured
        // against three materials on hardware, 2026-08-26, over both a dark and a light desktop.
        // Left to follow the system, `NSVisualEffectView` renders its light variant in Light
        // Appearance and the band came back as a **white glow** around a pure black island: the one
        // shape in this app whose edge has to be invisible against the bezel, wearing a halo. Pinned
        // dark it is a soft darkening of whatever is behind it on either desktop, which is what a
        // blur under a black shape looks like.
        view.appearance = NSAppearance(named: .darkAqua)
        view.blendingMode = .behindWindow
        // `.active` rather than `.followsWindowActiveState`: the panel is never key and never main
        // (§4.1), so a blur that followed the window's active state would never be active at all.
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}


/// What `IslandBlurPanel` draws: the blur and nothing else.
///
/// A root view of its own rather than a layer inside `IslandRootView`, because the blur lives in a
/// **different window** — one that ignores mouse events, so a click in the band reaches the app
/// underneath. See `IslandBlurPanel` for the measurement that forced the split.
///
/// It reads the same `IslandScreenModel` the island does, so the two cannot disagree about how open
/// the island is or what shape it currently has: there is one animated `metrics` and both windows
/// are driven from it.
public struct IslandBlurRootView: View {

    private let model: IslandScreenModel

    public init(model: IslandScreenModel) {
        self.model = model
    }

    public var body: some View {
        IslandBlurView(
            // The *animated* metrics, like the material in `IslandRootView` — the blur travels with
            // the shape rather than snapping to where it is going.
            metrics: model.metrics,
            presence: IslandMaterialView.openPresence(
                inHeight: model.metrics.bodySize.height,
                restingHeight: model.cutoutSize.height
            ),
            reduceTransparency: model.reduceTransparency
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Nothing here is for VoiceOver: the blur says where the island's grace region ends, which
        // is a fact about the pointer and means nothing to somebody who is not using one.
        .accessibilityHidden(true)
    }
}
