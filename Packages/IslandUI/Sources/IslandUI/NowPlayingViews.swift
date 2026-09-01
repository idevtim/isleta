import AppKit
import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import SwiftUI

/// The album cover, or the glyph that stands in for it.
///
/// A continuous-corner square, never a circle and never a plain rectangle — the same rule as the
/// island's own outline (§6.4), and the same rule Music itself follows. The corner radius is set
/// against the drawn size rather than fixed, because the artwork appears at two sizes (a 40pt flank
/// and a 48pt well in the open island) and a radius that reads as generous on one reads as a
/// rounded-off rectangle on the other.
///
/// ## When there is no cover, the player's own icon
///
/// Not every route to a player has artwork behind it — a browser tab playing audio frequently
/// reports a title and nothing else — and "music.note" in that case says only that this is music,
/// which the island's whole shape has already said. The player's application icon says *Chrome is
/// making this sound*, which is the fact the user wants and the one nothing else on the collapsed
/// island carries. It is drawn like a cover rather than like a glyph: full bleed, clipped to the
/// same continuous corner, scaled by `ApplicationIconMetrics.canvasScale` so the squircle fills the
/// box the way the sleeve would instead of floating inside macOS's icon margin.
///
/// The glyph well is still the fallback under *that* — it is the frame before a resolve returns,
/// and the permanent state for a player that has been uninstalled since it last spoke.
///
/// `.interpolation(.high)` matters here more than it usually does: the image has already been
/// downsampled to 256px by `NowPlayingArtworkLoader`, so this is drawing a 256px bitmap into a 96px
/// box at 2x, and the default interpolation on that ratio produces visible aliasing on the fine
/// concentric detail cover art is full of.
///
/// ## Paused draws the cover back
///
/// A paused cover shrinks a little and dims, and travels back to full size and full strength on
/// play. It is the same gesture Music's own artwork makes, and on the island it earns its keep
/// twice: at the 24pt flank the equaliser sinking to a row of dots is a small signal on the far side
/// of the cutout, and the cover changing size is the one that is legible at a glance. The two ride
/// the same curve length — `Motion.contentSwap`, which is what `EqualiserBarsView` settles the bars
/// on — so pausing reads as one movement across the whole island rather than two.
///
/// `scaleEffect` and `opacity`, not a smaller `frame`: the layout must not move. This view sits in a
/// flank the island's outline is measured against, and a cover that changed its *bounds* on pause
/// would move the title beside it in the open player and would change what `islandPath` is tracking
/// in the collapsed one.
struct NowPlayingArtworkView: View {

    let image: CGImage?
    let fallbackSymbol: String
    let side: CGFloat
    let tint: Color
    let increaseContrast: Bool

    /// The player application's icon, for a track with no cover. Nil is the ordinary state — most
    /// music has artwork, and this is nil for the frame before a resolve returns besides.
    var applicationIcon: CGImage? = nil

    /// True when the player is known to be paused. Deliberately not `!isPlaying`: a route that
    /// cannot report transport state — the scripting fallback — must draw the cover at rest in its
    /// ordinary form rather than permanently dimmed, so the caller passes false unless it *knows*.
    var isPaused: Bool = false

    /// Reduce Motion keeps the dim and drops the shrink — §6.3's substitution exactly: the state is
    /// still shown, and it is shown by a crossfade rather than by travel.
    var reduceMotion: Bool = false

    /// How far the cover draws back when paused. Small on purpose: this is the same square in the
    /// same place, quieter — at more of a step it reads as the artwork being replaced.
    static let pausedScale: CGFloat = 0.88

    /// How far it dims. Against `#000000` opacity *is* the dimming, and this is the floor at which a
    /// dark sleeve is still plainly a picture rather than an empty well.
    static let pausedOpacity: Double = 0.55

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let applicationIcon {
                // Scaled up rather than fitted: macOS draws an icon's squircle on a canvas larger
                // than the shape, so an icon dropped into this box at 1:1 sits visibly inside the
                // square a cover fills. `canvasScale` is the reciprocal of that inset, and it is the
                // same number the notification slivers already use for the same reason.
                Image(decorative: applicationIcon, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: side * ApplicationIconMetrics.canvasScale,
                        height: side * ApplicationIconMetrics.canvasScale
                    )
            } else {
                // The well, not a blank square. A hole where the artwork will be reads as a loading
                // failure; a tinted well with the activity's glyph in it reads as "this is where the
                // cover goes", which is what it is for the beat before the fetch returns.
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(tint.opacity(increaseContrast ? 0.24 : 0.14))
                Image(systemName: fallbackSymbol)
                    .font(.system(size: side * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        // The artwork is the one thing on the island that is not our own drawing, so it gets a hair
        // of edge: cover art is frequently near-black at its border and would otherwise dissolve
        // into the notch with no boundary at all.
        .overlay(
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(increaseContrast ? 0.35 : 0.12), lineWidth: 0.5)
        )
        // The cover changing is a content change in §6.2's sense and crossfades on whatever curve
        // opened the transaction, rather than snapping a frame ahead of the title beside it.
        .contentTransition(.opacity)
        // One modifier for both, so the shrink and the dim are a single animation rather than two
        // that happen to have been given the same token — §6.1's rule about the island's dimensions
        // traveling on one spring, applied to the smallest thing it can be applied to.
        .scaleEffect(restingScale)
        .opacity(restingOpacity)
        // Play and pause arrive from the player, outside any transaction this view is inside, so
        // without a value-scoped animation here the cover would snap.
        .animation(Motion.contentSwap, value: isPaused)
    }

    private var restingScale: CGFloat {
        isPaused && !reduceMotion ? Self.pausedScale : 1
    }

    /// Increase Contrast dims less far. A user who has asked the system for more contrast has
    /// answered the question of how much legibility a state indicator may cost — the same rule
    /// `NowPlayingController.accent(_:increaseContrast:)` follows — and the shrink already says
    /// "paused" on its own.
    private var restingOpacity: Double {
        guard isPaused else { return 1 }
        return increaseContrast ? 0.82 : Self.pausedOpacity
    }
}

/// The equaliser in the trailing flank: moving while playing, sinking to a line while paused.
///
/// ## Why this is six `CALayer`s and not a `Canvas`
///
/// It was a `Canvas` inside a `TimelineView(.animation)` until 2026-08-23, and that cost **17.7 % of
/// a core and 279 MB** — §9's whole animating budget four times over, and its memory budget four
/// times over. The correction in PERF.md is the part worth carrying: the cost is **not** a function
/// of how big the animating view or its panel is. A 40×32pt panel drawing the same six bars measured
/// 17.83 % against the 608×200pt panel's 17.72 %, with the same 279.5 MB, and `.drawingGroup()`
/// changed neither. So "make the animating thing smaller" is not a lever that exists, and rate
/// limiting does not reach budget either — 8 Hz still measured 5.28 %, and looked stepped for it.
///
/// Six `CALayer`s with a repeating animation measured **0.007–0.010 % and 14.6 MB** — the same bars
/// at the same 120 Hz in the same panel, ~2 400× cheaper in this process and *below* the footprint
/// of a static control. The reason is the whole rule: **the render server owns the animation and
/// this process draws zero frames.** Nothing here runs per frame; `layout()` runs when the geometry
/// or the backing scale changes, and the animation objects are handed over once.
///
/// **Do not turn this back into a SwiftUI redraw**, and do not add a per-frame `Canvas` anywhere
/// else on the island on the theory that a small one is cheap. It is not.
///
/// ## The pattern is still a pure function, and the keyframes are generated from it
///
/// `heights(at:playing:reduceMotion:)` survives the rewrite unchanged. It is no longer what draws —
/// but it is still the *specification*, it is what the tests assert against, and
/// `keyframeHeights(forBar:trackHeight:barWidth:)` is derived from the same `frames` table, so the
/// two cannot drift apart without a test failing.
///
/// Phase is anchored to the wall clock through `CAAnimation.timeOffset`, exactly as the pure
/// function anchored it to `timeIntervalSinceReferenceDate`. That is what keeps the indicator from
/// having any state of its own to drift: a view rebuild, a track change, or a second equaliser
/// appearing in the open island all land on the same phase as the first one.
///
/// ## The bars
///
/// Modelled on the indicator in iOS's expanded Dynamic Island player: thin, vertically centerd bars
/// with rounded caps. Centerd rather than bottom-aligned is what separates it from a generic level
/// meter, and it is what makes the paused state a row of dots on one line instead of six stubs
/// standing on a floor.
///
/// ## The bars wear the album's accent, leaning
///
/// White is the fallback, not the design. The row is drawn in the **same color the played portion
/// of the scrub bar is** — `NowPlayingController.accent(_:increaseContrast:)` — fading slightly
/// toward the leading end, which is `AlbumColor.row(_:count:)`. One color rather than six read off
/// the sleeve: a row of unrelated hues beside a scrub bar drawn in one is two answers to the same
/// question, and the lean is what keeps a single tint from reading as a flat block. `colors` is nil
/// whenever the cover gave no accent, the user has switched album color off, or Increase Contrast
/// is on, and nil is the white row this shipped with.
struct NowPlayingEqualiserView: View {

    /// Paused sinks the bars to a line, as the reference shows — not bars frozen mid-pattern.
    let isPlaying: Bool

    let reduceMotion: Bool

    /// One color per bar, or nil for white. A count that does not match `count` is ignored rather
    /// than padded: a palette read for a different number of bars is a caller bug, and half a
    /// colored row is worse than none.
    var colors: [AlbumColor]?

    /// The box the bars are drawn in.
    ///
    /// `trackSize` everywhere in the island, which is what a 40pt flank affords. The lock screen
    /// card passes its own, larger number: that surface is read from across a room and a 21×14 row
    /// there is a smudge. **Still fixed per caller, which is the point of the comment on
    /// `trackSize`** — the bars resolve their geometry from bounds, so a row whose size genuinely
    /// changed would rebuild its keyframes on every layout pass. Two callers with two constants is
    /// not that.
    var size: CGSize = NowPlayingEqualiserView.trackSize

    /// Six bars. The reference reads as eight or nine at its size; six is what fits the glyph box a
    /// 40pt flank affords without the bars becoming sub-point slivers that alias at 1x.
    nonisolated static let count = 6

    /// The height a bar collapses to, as a fraction of the track. Never zero: a bar of no height is
    /// a gap, and a gap reads as a rendering fault rather than as a quiet band. In points it is
    /// floored again at the bar's own width, so the dot is a circle rather than a squashed capsule.
    nonisolated static let minimumHeight: Double = 0.16

    /// The designed profile the bars step between: specific highs and lows across the row, fuller
    /// through the middle and shorter at the ends, like a waveform rather than six independent
    /// oscillators. Hand-set rather than generated so the silhouette is deliberate at every step and
    /// no two adjacent bars ever peak together — bars rising in step are the one thing that makes a
    /// synthesized equaliser look synthesized.
    nonisolated static let frames: [[Double]] = [
        [0.30, 0.62, 0.95, 0.78, 0.45, 0.22],
        [0.48, 0.88, 0.66, 0.35, 0.72, 0.40],
        [0.72, 0.40, 0.28, 0.62, 0.95, 0.58],
        [0.35, 0.66, 0.52, 0.90, 0.60, 0.30],
        [0.58, 0.25, 0.80, 0.44, 0.34, 0.72],
        [0.42, 0.78, 0.38, 0.68, 0.86, 0.48],
    ]

    /// How long one frame holds before the next.
    nonisolated static let frameDuration: TimeInterval = 0.34

    /// One trip through `frames` and back to the first — the repeating animation's duration.
    nonisolated static var cycleDuration: TimeInterval { frameDuration * Double(frames.count) }

    /// Retained for the test that pins the shared island clock *away* from this rate: the equaliser
    /// must never be the reason `IslandScreenModel` ticks, because ticking that clock invalidates
    /// the island's whole content tree. Sampling the bars off it cost 2.8 % when it was tried.
    nonisolated static let updatesPerSecond: Double = 60

    /// The glyph box the bars are drawn in. Fixed rather than fitted: the flank affords exactly this
    /// much, and a bar row that resized with its container would need the keyframes rebuilt on every
    /// layout pass for a size that never changes.
    nonisolated static let trackSize = CGSize(width: 21, height: 14)

    /// The gap between bars, before pixel snapping.
    nonisolated static let spacing: Double = 1.5

    var body: some View {
        EqualiserBars(isPlaying: isPlaying, reduceMotion: reduceMotion, colors: resolvedColors)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }

    /// The palette, once it has been checked against the number of bars actually drawn.
    private var resolvedColors: [AlbumColor]? {
        guard let colors, colors.count == Self.count else { return nil }
        return colors
    }

    /// The check above, reachable from a test. The view cannot be rendered without a window, and the
    /// rule it enforces — half a colored row is worse than none — is the kind that only ever fails
    /// on somebody's machine at a count nobody thought about.
    var resolvedColorsForTesting: [AlbumColor]? { resolvedColors }

    // MARK: - The pattern, as a pure function

    /// The bar heights at an instant, as fractions of the track.
    ///
    /// Pure and static so the whole pattern — the designed frames, the easing between them, and the
    /// collapse — is testable without a view, a clock, or a running app. Since the rewrite it is the
    /// *specification* rather than the renderer: `keyframeHeights(forBar:trackHeight:barWidth:)`
    /// hands the same table to CoreAnimation, and a test asserts the two agree at every frame
    /// boundary.
    nonisolated static func heights(at time: TimeInterval, playing: Bool, reduceMotion: Bool) -> [Double] {
        guard !reduceMotion else { return frames[0] }
        guard playing else { return Array(repeating: minimumHeight, count: count) }

        let position = max(0, time) / frameDuration
        let index = Int(position.rounded(.down))
        let current = frames[index % frames.count]
        let next = frames[(index + 1) % frames.count]

        // Smoothstep, not linear: the owner asked for bars that animate smoothly *into* their
        // change, and a linear blend arrives at each frame with a visible corner in the motion.
        // CoreAnimation's `.easeInEaseOut` is the same S all the way through — a Bézier
        // approximation of this cubic rather than the cubic itself, which is a difference of under
        // a twentieth of a bar height at the worst point of a 14pt track and invisible on hardware.
        let raw = position - position.rounded(.down)
        let eased = raw * raw * (3 - 2 * raw)

        return (0..<count).map { bar in
            let value = current[bar] + (next[bar] - current[bar]) * eased
            return max(minimumHeight, value)
        }
    }

    /// The keyframe values, **in points**, for one bar's trip through `frames` and back.
    ///
    /// Seven values for six frames: the first is repeated at the end so the cycle closes on itself
    /// and `repeatCount = .infinity` does not jump at the seam.
    ///
    /// The floor is the bar's own width rather than `minimumHeight × trackHeight`, so that a bar at
    /// rest is a circle of the same diameter as the bar rather than a capsule squashed below its own
    /// cap radius. At the shipped 21×14 that floor never binds on a *pattern* value — every entry in
    /// `frames` is well above it — but it is what makes the paused dot a dot.
    nonisolated static func keyframeHeights(forBar bar: Int, trackHeight: Double, barWidth: Double) -> [Double] {
        precondition(bar >= 0 && bar < count)
        let cycle = frames + [frames[0]]
        return cycle.map { frame in
            max(barWidth, trackHeight * max(minimumHeight, frame[bar]))
        }
    }

    /// The height of a bar at rest — the dot in the paused row.
    nonisolated static func dotHeight(trackHeight: Double, barWidth: Double) -> Double {
        max(barWidth, trackHeight * minimumHeight)
    }
}

/// Where the six bars sit, snapped to the device pixel grid.
///
/// ## Why snapping is arithmetic here rather than a rendering hint
///
/// Six 2.25pt bars in a 21pt row land on half-pixel boundaries at 1× and quarter-pixel boundaries at
/// 2×, and a `CALayer` straddling a pixel boundary is drawn with a blurred edge on both sides — six
/// of them side by side read as a smudge rather than as bars. `Canvas` had the same problem and hid
/// it behind antialiasing over a shape that was moving anyway; a layer holds still horizontally, so
/// the softness is legible.
///
/// Each bar's **edges** are snapped, and the width is what falls out of the two rounded edges, so
/// every boundary lands on a pixel and the widths differ by at most one. Rounding the width and then
/// laying the bars out is the version that looks right and is wrong: the accumulated error moves the
/// last bar off the grid again.
///
/// Pure and `Equatable` so the snapping can be asserted at 1× and 2× without a window.
struct EqualiserBarGeometry: Equatable {

    struct Bar: Equatable {
        var x: Double
        var width: Double
    }

    var bars: [Bar]

    /// The vertical center the bars grow either side of, snapped.
    var centerY: Double

    static func resolve(
        size: CGSize,
        count: Int = NowPlayingEqualiserView.count,
        spacing: Double = NowPlayingEqualiserView.spacing,
        scale: Double
    ) -> EqualiserBarGeometry {
        // A backing scale of zero or less is what a view reports before it has a window; treat it as
        // 1× rather than dividing by it.
        let pixel = 1.0 / max(scale, 1)
        func snap(_ value: Double) -> Double { (value / pixel).rounded() * pixel }

        let nominal = max(0, (size.width - spacing * Double(count - 1)) / Double(count))
        let bars = (0..<count).map { index -> Bar in
            let leading = Double(index) * (nominal + spacing)
            let trailing = leading + nominal
            let snappedLeading = snap(leading)
            return Bar(x: snappedLeading, width: max(pixel, snap(trailing) - snappedLeading))
        }
        return EqualiserBarGeometry(bars: bars, centerY: snap(size.height / 2))
    }
}

/// The bridge from SwiftUI to the six layers.
///
/// It carries no state of its own: `updateNSView` hands the two inputs across and
/// `EqualiserBarsView` decides whether anything has actually changed. That matters because SwiftUI
/// re-runs this on every content change on the island — a track title arriving, a scrub, the palette
/// updating — and re-adding a repeating animation on each of those would restart the pattern's phase
/// and make the bars stutter for reasons the user cannot see.
private struct EqualiserBars: NSViewRepresentable {

    let isPlaying: Bool
    let reduceMotion: Bool
    let colors: [AlbumColor]?

    func makeNSView(context: Context) -> EqualiserBarsView {
        EqualiserBarsView(isPlaying: isPlaying, reduceMotion: reduceMotion, colors: colors)
    }

    func updateNSView(_ view: EqualiserBarsView, context: Context) {
        view.apply(isPlaying: isPlaying, reduceMotion: reduceMotion, colors: colors)
    }
}

/// Six `CALayer`s and the animations the render server runs on them.
///
/// ## What this view must never do
///
/// - **Draw.** There is no `draw(_:)` and there must not be one. The layers are a background color
///   and a corner radius, which the compositor renders from the GPU without ever asking this process
///   for pixels. Adding `contents`, a mask, or a `CAShapeLayer` path would put rasterisation back on
///   the table and give back the 2 400× this rewrite bought.
/// - **Take a click.** `hitTest` returns nil unconditionally. The bars sit inside the island's
///   opaque area, where a press has to reach `IslandHitTestView.mouseDown` to open or close the
///   island; an `NSView` that answered the hit test would leave the user pressing a visible island
///   that does nothing. This is the AppKit half of the rule CLAUDE.md records for
///   `.allowsHitTesting(false)`, and it is deliberately expressed here rather than in SwiftUI, where
///   that modifier collapses the whole window's event shape.
///
/// ## Why `bounds.size.height` and not `transform.scale.y`
///
/// The measured arm used the scale, and the scale is wrong for these bars: a capsule squashed to a
/// sixth of its height has its round caps squashed with it, so the paused dot would be a flat sliver
/// rather than a circle. Animating the bounds leaves `cornerRadius` alone, so a bar is a proper
/// capsule at every height and a circle at rest. Both are animated entirely inside the render server
/// — `bounds` is on `CALayer`'s animatable list and the rounded rectangle is generated by the
/// compositor, not by a `CGContext` — and the measurement below confirms the substitution kept the
/// result.
///
/// The anchor point stays at the center and `position` is fixed, so a bar grows equally up and down
/// and the row collapses onto one line rather than onto a floor.
final class EqualiserBarsView: NSView {

    /// How the bars are behaving. Derived from the two inputs rather than stored beside them, for
    /// the reason `IslandPresentation` exists: two independent booleans and one mutable state is how
    /// you get a paused equaliser that is still running because the inputs arrived in the wrong
    /// order.
    private enum Mode: Equatable {
        /// Playing: the repeating pattern, owned by the render server.
        case running
        /// Paused: a row of dots on one line.
        case resting
        /// Reduce Motion: one designed frame, held. Not a flat row — a static silhouette below full
        /// height reads as a meter at rest, where all-equal would read as a loading placeholder.
        case still

        init(isPlaying: Bool, reduceMotion: Bool) {
            if reduceMotion { self = .still } else { self = isPlaying ? .running : .resting }
        }
    }

    private static let patternKey = "isleta.equaliser.pattern"
    private static let transitionKey = "isleta.equaliser.transition"
    private static let tintKey = "isleta.equaliser.tint"

    /// The row with no cover behind it. sRGB for §6.4's reason, same as every other color drawn on
    /// the island: a named color can resolve to an appearance-sensitive variant and lift off the
    /// bezel by a shade.
    private static let uncolored = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private var bars: [CALayer] = []
    private var mode: Mode
    private var appliedMode: Mode?
    private var appliedGeometry: EqualiserBarGeometry?
    private var colors: [AlbumColor]?
    private var appliedColors: [AlbumColor]?

    init(isPlaying: Bool, reduceMotion: Bool, colors: [AlbumColor]?) {
        mode = Mode(isPlaying: isPlaying, reduceMotion: reduceMotion)
        self.colors = colors
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        bars = (0..<NowPlayingEqualiserView.count).enumerated().map { offset, _ in
            let bar = CALayer()
            bar.backgroundColor = Self.color(colors, at: offset)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // Implicit animations off for good. A layer property assigned outside an explicit
            // transaction animates over CoreAnimation's own 0.25 s default — an inline duration by
            // the back door, and §6.1 forbids those whichever framework writes them.
            // `backgroundColor` is on the list for the same reason the geometry keys are: a track
            // change would otherwise recolor the row on CoreAnimation's curve rather than on the
            // one every other part of the swap travels on.
            bar.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "cornerRadius": NSNull(),
                "backgroundColor": NSNull(),
            ]
            layer?.addSublayer(bar)
            return bar
        }
        appliedColors = colors
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EqualiserBarsView is not loaded from a nib") }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(isPlaying: Bool, reduceMotion: Bool, colors: [AlbumColor]?) {
        if colors != self.colors {
            self.colors = colors
            applyColors(transitioning: true)
        }
        let next = Mode(isPlaying: isPlaying, reduceMotion: reduceMotion)
        guard next != mode else { return }
        mode = next
        applyMode(transitioning: true)
    }

    // MARK: - Color

    /// The color for one bar, or white when there is no palette.
    private static func color(_ colors: [AlbumColor]?, at index: Int) -> CGColor {
        guard let colors, index < colors.count else { return uncolored }
        let band = colors[index]
        return CGColor(srgbRed: band.red, green: band.green, blue: band.blue, alpha: 1)
    }

    /// Recolors the row, crossfading on `contentSwap`'s length when a track has changed under it.
    ///
    /// **Not a redraw.** `backgroundColor` is on `CALayer`'s animatable list and the interpolation
    /// happens in the render server, so a track change costs this process six property assignments
    /// and six animation objects — the same trade the heights already make, and the reason the
    /// colors could be added at all without giving back §9.6's measurement.
    private func applyColors(transitioning: Bool) {
        guard colors != appliedColors else { return }
        let previous = appliedColors
        appliedColors = colors

        for (index, bar) in bars.enumerated() {
            let from = bar.presentation()?.backgroundColor
                ?? Self.color(previous, at: index)
            let to = Self.color(colors, at: index)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.backgroundColor = to
            CATransaction.commit()

            bar.removeAnimation(forKey: Self.tintKey)
            guard transitioning, window != nil else { continue }
            // Under Reduce Motion this is still a crossfade rather than travel, which is what §6.3
            // asks for — so it is not suppressed there the way the height transitions are.
            let recolor = CABasicAnimation(keyPath: "backgroundColor")
            recolor.fromValue = from
            recolor.toValue = to
            recolor.duration = Motion.contentSwapDuration
            recolor.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(recolor, forKey: Self.tintKey)
        }
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        let geometry = EqualiserBarGeometry.resolve(size: bounds.size, scale: scale)
        guard geometry != appliedGeometry else { return }
        appliedGeometry = geometry

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, layout) in zip(bars, geometry.bars) {
            bar.contentsScale = scale
            bar.bounds = CGRect(x: 0, y: 0, width: layout.width, height: bar.bounds.height)
            bar.position = CGPoint(x: layout.x + layout.width / 2, y: geometry.centerY)
            bar.cornerRadius = layout.width / 2
        }
        CATransaction.commit()

        // The keyframes are in points and every one of them depends on the bar's snapped width, so a
        // scale change is a rebuild rather than a resize.
        appliedMode = nil
        applyMode(transitioning: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        appliedGeometry = nil
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Off screen is not a state the render server should be animating through. The island
            // takes its panels down on a space transition and rebuilds them on a display change; a
            // pattern left running on a detached layer is work nobody can see.
            bars.forEach { $0.removeAllAnimations() }
            appliedMode = nil
        } else {
            appliedGeometry = nil
            needsLayout = true
        }
    }

    // MARK: - Handing the animation over

    private func applyMode(transitioning: Bool) {
        guard window != nil, let geometry = appliedGeometry, mode != appliedMode else { return }
        appliedMode = mode
        let trackHeight = Double(bounds.height)
        guard trackHeight > 0 else { return }

        for (index, bar) in bars.enumerated() {
            let width = geometry.bars[index].width
            switch mode {
            case .running:
                start(bar, index: index, trackHeight: trackHeight, barWidth: width, easing: transitioning)
            case .resting:
                settle(
                    bar,
                    to: NowPlayingEqualiserView.dotHeight(trackHeight: trackHeight, barWidth: width),
                    easing: transitioning
                )
            case .still:
                let frame = NowPlayingEqualiserView.frames[0][index]
                settle(bar, to: max(width, trackHeight * frame), easing: transitioning)
            }
        }
    }

    /// The repeating pattern, handed over once and never touched again.
    private func start(_ bar: CALayer, index: Int, trackHeight: Double, barWidth: Double, easing: Bool) {
        let values = NowPlayingEqualiserView.keyframeHeights(
            forBar: index,
            trackHeight: trackHeight,
            barWidth: barWidth
        )
        let duration = NowPlayingEqualiserView.cycleDuration
        let steps = values.count - 1

        let pattern = CAKeyframeAnimation(keyPath: "bounds.size.height")
        pattern.values = values
        pattern.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        pattern.timingFunctions = (0..<steps).map { _ in
            CAMediaTimingFunction(name: .easeInEaseOut)
        }
        pattern.duration = duration
        pattern.repeatCount = .infinity
        pattern.isRemovedOnCompletion = false
        pattern.fillMode = .both
        // Phase anchored to the wall clock, which is what `heights(at:)` did and is why the
        // indicator has no state of its own to drift across a pause, a seek or a rebuild.
        pattern.timeOffset = Date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration)

        let from = bar.presentation()?.bounds.height ?? bar.bounds.height
        bar.removeAnimation(forKey: Self.transitionKey)
        bar.removeAnimation(forKey: Self.patternKey)
        bar.add(pattern, forKey: Self.patternKey)

        guard easing else { return }
        // Coming off a pause, the bars must rise out of the line rather than appear at whatever the
        // pattern is doing at that instant. An **additive** animation is what composes with a
        // running one: it contributes a delta that eases to zero, so the bar starts where it was and
        // arrives on the pattern without the pattern having to be restarted or re-phased.
        let entry = NowPlayingEqualiserView.heights(
            at: Date.timeIntervalSinceReferenceDate,
            playing: true,
            reduceMotion: false
        )[index]
        let patternNow = max(barWidth, trackHeight * entry)
        let rise = CABasicAnimation(keyPath: "bounds.size.height")
        rise.fromValue = from - patternNow
        rise.toValue = 0
        rise.isAdditive = true
        rise.duration = Motion.contentSwapDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(rise, forKey: Self.transitionKey)
    }

    /// A bar coming to rest — the paused dot, or Reduce Motion's held frame.
    private func settle(_ bar: CALayer, to height: Double, easing: Bool) {
        let from = bar.presentation()?.bounds.height ?? bar.bounds.height
        bar.removeAnimation(forKey: Self.patternKey)
        bar.removeAnimation(forKey: Self.transitionKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: bar.bounds.width, height: height)
        CATransaction.commit()

        // Under Reduce Motion the substitution is a crossfade rather than travel, and the bars have
        // nothing to fade between — so the held frame is taken up with no animation at all, which is
        // the honest reading of §6.3 here.
        guard easing, mode != .still else { return }
        let collapse = CABasicAnimation(keyPath: "bounds.size.height")
        collapse.fromValue = from
        collapse.toValue = height
        collapse.duration = Motion.contentSwapDuration
        collapse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(collapse, forKey: Self.transitionKey)
    }
}

/// Reports whether the pointer is over the view it is attached to.
///
/// ## Why this is not `.onHover`
///
/// Isleta is an agent app whose panel is deliberately never key and never main (§4.1), and the
/// window server does not deliver ordinary tracking events to a window in that state. That is why
/// `IslandHitTestView` builds its own `NSTrackingArea` with **`.activeAlways`** and says so in a
/// comment, and it is why every hover-driven control here is written to survive a build where hover
/// never arrives at all. SwiftUI's `.onHover` gives no control over that option, so a control that
/// only exists while the pointer is on it cannot be built out of it.
///
/// ## What it must not do
///
/// **Answer the hit test.** `hitTest` returns nil unconditionally, exactly as `EqualiserBarsView`
/// does and for a related reason: this view is a sibling of the button it reports for, and an
/// `NSView` that claimed the point would take the press the button needs — leaving a control that
/// lights up under the pointer and does nothing when clicked. A tracking area is delivered
/// regardless of hit testing, so nothing is lost by refusing it.
///
/// ## Why it re-reads the pointer on every layout
///
/// `mouseEntered` fires on a **crossing**, not on a position — `IslandHitTestView` records the same
/// thing — and the island moves under a stationary pointer all the time: rest to peek is a change of
/// shape, not of where the pointer is. Without the re-read, hovering the sliver as the island swells
/// would leave the control revealed or hidden according to which side of the old geometry the
/// pointer had been on.
/// Internal rather than private: the home page's mini transport reports its hover through the same
/// view, so the two rows light up on identical terms. A second implementation of "is the pointer on
/// this control" is a second place for the crossing-order bug the wash's own note describes.
struct PointerPresence: NSViewRepresentable {

    let isOver: (Bool) -> Void

    func makeNSView(context: Context) -> PointerPresenceView {
        PointerPresenceView(isOver: isOver)
    }

    func updateNSView(_ view: PointerPresenceView, context: Context) {
        view.isOver = isOver
    }
}

final class PointerPresenceView: NSView {

    var isOver: (Bool) -> Void
    private var area: NSTrackingArea?
    private var reported = false

    init(isOver: @escaping (Bool) -> Void) {
        self.isOver = isOver
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PointerPresenceView is not loaded from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // `.activeAlways` for `IslandHitTestView`'s reason, which is the whole reason this view
        // exists. `.inVisibleRect` so the rect follows the island's geometry without this view
        // having to be told the island changed shape.
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(next)
        area = next
        report(pointerIsInside)
    }

    override func mouseEntered(with event: NSEvent) { report(true) }

    override func mouseExited(with event: NSEvent) { report(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window is leaving the control. A panel taken down on a space transition and
        // rebuilt would otherwise come back with the glyph still showing.
        if window == nil { report(false) }
    }

    /// Where the pointer is *now*, rather than which edge it last crossed.
    private var pointerIsInside: Bool {
        guard let window, window.occlusionState.contains(.visible) else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(inWindow, from: nil))
    }

    private func report(_ value: Bool) {
        guard value != reported else { return }
        reported = value
        isOver(value)
    }
}

/// The equaliser, made pressable.
///
/// ## What it is
///
/// The six bars in the collapsed island's trailing sliver are the only thing on a resting notch
/// that is *about* playback rather than about the track, so they are the honest place to put
/// play/pause. The pointer arriving swaps them for the glyph, one alignment tap says the control is
/// there, and a click toggles the player without the island opening.
///
/// ## Why the click does not open the island
///
/// Because a `Button` **consumes** the press. The island is opened by `IslandHitTestView.mouseDown`,
/// which only ever sees presses no subview claimed — the same mechanism `NowPlayingSlotView`'s
/// artwork button relies on, and the same trap recorded there: a *disabled* button claims the press
/// and does nothing with it, leaving a click that neither toggles nor opens. So there is no button
/// at all where there is no transport, and the bars go back to being decoration the island's own
/// hit test can have.
///
/// ## Why the reveal is a swap and not a badge
///
/// A glyph drawn *beside* the bars would need width the flank does not have — the sliver is ~40pt
/// and the bars are 21 of it — and a glyph drawn *over* them at full strength is illegible against
/// six moving capsules in the cover's own colors. Fading the bars back to a trace and bringing the
/// glyph up in their place is the one version that reads at 14pt, and it doubles as the affordance:
/// the thing under the pointer visibly became a control.
///
/// The bars keep running underneath. Their animation belongs to the render server and stopping it on
/// hover would restart the pattern's phase on every pass of the pointer — see
/// `EqualiserBarsView` — so what changes is opacity and nothing else.
struct NowPlayingEqualiserControl: View {

    let controller: NowPlayingController
    let reduceMotion: Bool
    let increaseContrast: Bool
    let colors: [AlbumColor]?

    /// How far the bars fall back under the glyph. Not to zero: the row disappearing entirely reads
    /// as the indicator being replaced by a button, and it is the same object either way.
    ///
    /// Increase Contrast takes them all the way out. A white glyph read against a trace of six
    /// colored capsules is exactly the compromise a user who asked the system for more contrast has
    /// already declined, and the affordance survives it — the bars going *away* under the pointer
    /// says "this became a control" at least as plainly as their fading does.
    private static func barsUnderGlyph(increaseContrast: Bool) -> Double {
        increaseContrast ? 0 : 0.16
    }

    /// The glyph, against a 14pt track. Larger fills the sliver and touches the island's edge, which
    /// §6.4's rule about bright content on a black bezel already forbids for the cover.
    private static let glyphSize: CGFloat = 11

    /// The press target: the bars, given height they do not draw.
    ///
    /// A 14pt-tall row is a 14pt target, and `NowPlayingScrubberView` already records what this
    /// project thinks of those. Five points top and bottom make it 24 — comfortably inside the 32pt
    /// flank, so nothing moves — and the row keeps its drawn position exactly.
    ///
    /// **Vertical only, deliberately.** The flank is 8pt in from the island's edge and the bars are
    /// aligned to it; horizontal padding here would push them inward by its own width and move the
    /// one piece of content whose position on a resting island the user sees all day. It would also
    /// spend the flank the user presses to *open* the island, which is the press this control is
    /// already taking a bite out of.
    private static let targetPadding = EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)

    @State private var isHovering = false

    var body: some View {
        if controller.isTransportAvailable {
            Button {
                controller.send(.togglePlayPause)
            } label: {
                indicator
                    .padding(Self.targetPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PointerPresence { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                // On arrival only. A tap on the way *out* would be the island reporting something
                // the user did not do anything to cause, which §7 calls a bug.
                if hovering { Haptics.arrival() }
            })
            .accessibilityLabel(
                controller.isPlaying
                    ? islandText("nowPlaying.transport.pause", "Pause")
                    : islandText("nowPlaying.transport.play", "Play")
            )
            .accessibilityAddTraits(.isButton)
        } else {
            // No route, no control — and no `.disabled(…)` button standing in for one, which would
            // swallow the press that opens the island. See the note above.
            bars
        }
    }

    private var indicator: some View {
        ZStack {
            bars.opacity(isHovering ? Self.barsUnderGlyph(increaseContrast: increaseContrast) : 1)
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(.white)
                // The glyph swaps between pause and play under a pointer that has not moved, which
                // is §6.2's "same thing, new content" — a crossfade, not a substitution.
                .contentTransition(.opacity)
                .opacity(isHovering ? 1 : 0)
        }
        // One modifier over both halves of the swap, so the bars falling back and the glyph coming
        // up are a single animation rather than two on the same token.
        .animation(Motion.contentSwap, value: isHovering)
        .frame(
            width: NowPlayingEqualiserView.trackSize.width,
            height: NowPlayingEqualiserView.trackSize.height
        )
    }

    private var bars: some View {
        NowPlayingEqualiserView(
            isPlaying: controller.isPlaying,
            reduceMotion: reduceMotion,
            colors: colors
        )
    }
}

/// The draggable position bar.
///
/// ## Working in a window that never becomes key
///
/// The panel returns false from `canBecomeKey` unconditionally (§4.1) — clicking the island must not
/// take focus from whatever the user is typing in. That rules out anything built on first responder
/// status, but a `DragGesture` needs none: SwiftUI reports its hit-testing region up to
/// `NSHostingView`, `IslandHitTestView.hitTest` passes the point through because it is inside
/// `islandPath`, and AppKit delivers the whole mouse-down-drag-up sequence to whichever view
/// answered the hit test. What makes it work at all is that `IslandHitTestView` returns
/// `super.hitTest(point)` rather than `self`, so a subview that wants the event gets it.
///
/// `minimumDistance: 0` is not laziness about tap handling — it is the tap handling. A press
/// anywhere on the track seeks there, which is what a scrub bar does, and expressing it as a
/// zero-distance drag means a press that turns into a drag is one continuous interaction rather than
/// a tap that fires and then a drag that fires again from the same press.
///
/// ## Why the touch target is not the bar
///
/// The bar is 4pt tall. A 4pt hit target is unusable, so the gesture is attached to a 20pt row with
/// `.contentShape` — the drawn thing and the grabbable thing are deliberately different sizes, and
/// `.contentShape` is what says so without changing the layout.
struct NowPlayingScrubberView: View {

    /// 0...1, already resolved through `NowPlayingController.timeline(reportedBy:at:)`.
    let fraction: Double
    let color: Color
    let increaseContrast: Bool
    let isScrubbing: Bool

    let onBegin: (Double) -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    /// Thicker than the 4pt it started at. At 4 it read as a hairline against a 56pt cover and a
    /// row of 30pt glyphs — the thinnest thing in the open island, describing the one value that
    /// changes continuously.
    private static let trackHeight: CGFloat = 6
    private static let rowHeight = NowPlayingExpandedLayout.scrubberRowHeight
    private static let knobDiameter: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filled = (width * min(max(0, fraction), 1)).rounded()
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(color.opacity(ActivityPalette.trackOpacity(increaseContrast: increaseContrast)))
                    .frame(height: Self.trackHeight)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: filled, height: Self.trackHeight)
                // The knob appears only while dragging. A permanent knob on a bar this small is the
                // widest thing in the open island and pulls the eye to the control rather than to
                // the track name; showing it on grab is also the acknowledgement that the drag was
                // received, which matters in a window that cannot show focus.
                if isScrubbing {
                    Circle()
                        .fill(color)
                        .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                        .offset(x: min(max(0, filled - Self.knobDiameter / 2), width - Self.knobDiameter))
                }
            }
            .frame(height: Self.rowHeight)
            // The gesture's own region, distinct from what is drawn. Rectangle rather than the
            // capsule: grabbing a 4pt capsule requires the pointer to be within 2pt of its center
            // line, which no one can do on a moving target.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let position = Double(value.location.x / max(width, 1))
                        // `startLocation`, not `location`, decides whether this is the first event:
                        // a press that has not moved reports the two as equal, and comparing them is
                        // how a slow drag gets treated as a fresh grab on every frame.
                        if value.translation == .zero && !isScrubbing {
                            onBegin(position)
                        } else {
                            onChange(position)
                        }
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: Self.rowHeight)
    }
}

/// Previous, play/pause, next.
///
/// ## Whether a SwiftUI `Button` fires in a non-key panel
///
/// It does, and the reason it does is worth writing down because the codebase's own experience
/// pointed the other way: `IslandHitTestView` handles clicks in `mouseDown` precisely because
/// "routing clicks through SwiftUI's gesture system — which expects a key window and a first
/// responder — is asking for trouble". That is true of the *island as a whole*, where the click has
/// to arrive on a view that is not asking for it. It is not true of a control that is: SwiftUI's
/// button on macOS is driven by a press gesture over its own hit region, and a gesture needs neither
/// key status nor first responder. What it does need is for `NSHostingView` to be handed the event,
/// which happens because `IslandHitTestView.hitTest` returns `super.hitTest(point)` — the deepest
/// subview that wants the point — rather than `self`.
///
/// The one piece that is *not* free is `acceptsFirstMouse`. A window that never becomes key means
/// every click is a first-mouse click forever, not just the first one, so the hosting view has to
/// answer true or AppKit spends each press activating a window that refuses to activate. That is
/// `IslandHostingView` in the app shell. Verified end to end by `TransportSelfTest`, which
/// synthesises a press at the play button's center and asserts the command went out.
///
/// `.buttonStyle(.plain)` is required rather than cosmetic: the default macOS style draws a bezel,
/// and a bezel on pure `#000000` is a gray rectangle floating in the notch.
///
/// ## The pointer's own feedback
///
/// `.buttonStyle(.plain)` also means these controls do nothing at all under the pointer, and on a
/// row of seven glyphs 16pt apart that leaves the user aiming at a 13pt symbol with no confirmation
/// they have hit it until the music changes. Each button draws a rounded wash of its own while the
/// pointer is on it — `hovered` and `hoverWash(isOn:)` below — which is the same thing every other
/// control on the platform does and the only feedback available before the press.
struct NowPlayingTransportView: View {

    let isPlaying: Bool
    let canSkip: Bool
    let color: Color
    let increaseContrast: Bool
    let isShuffling: Bool
    let repeatMode: NowPlayingRepeatMode

    /// False on a radio station, where there is no queue to shuffle or repeat and the player refuses
    /// both commands. Dims the pair and makes them inert, exactly as `canSkip` does to their
    /// neighbors — the capability is missing, the control set is not.
    let canChangeQueueBehavior: Bool

    /// Whether the player offers a like for this track, from `supportsIsLiked`. Absent draws the
    /// heart dimmed and inert — the capability is missing from an otherwise working control set,
    /// which is `canSkip`'s case and not `isTransportAvailable`'s.
    let canFavorite: Bool

    let isFavorite: Bool

    /// Whether the player offers the fifteen-second jumps. When it does they take the
    /// previous/next positions, which is what every spoken-word player draws and what keeps the row
    /// exactly as wide as it was.
    let canSkipBackFifteen: Bool

    let canSkipForwardFifteen: Bool

    /// Whether there is a queue to list at all. False draws no Up Next button rather than a dimmed
    /// one: a build whose route cannot read a queue has no such feature, and a grayed control would
    /// advertise one and invite the user to go looking for the switch that turns it on.
    let canReadQueue: Bool

    let isShowingQueue: Bool

    let action: (NowPlayingControlCommand) -> Void

    /// Which control the pointer is on, or nil.
    ///
    /// **One value for the row, not a flag per button.** The pointer is in one place, and seven
    /// independent booleans is seven ways for two of them to be true at once — `mouseEntered` on
    /// the neighbor can arrive before `mouseExited` from the control being left, which with a
    /// flag each leaves two controls lit until the pointer stops moving. Storing *which* one makes
    /// that impossible to represent: the arrival overwrites, and the late exit is ignored because
    /// it no longer names the control that is stored.
    ///
    /// Reported by `PointerPresence` rather than `.onHover`, and that is not a preference — the
    /// panel is never key and never main, so SwiftUI's hover never arrives at all. The reasoning is
    /// written out on that type.
    @State private var hovered: NowPlayingControlCommand?

    /// The lit color for shuffle and repeat.
    ///
    /// Music's own accent, in sRGB so it cannot pick up an appearance-sensitive variant — the same
    /// rule the island's black follows, and for the same reason: these two glyphs sit on `#000000`
    /// in a notch, where a color that shifts by a shade is a color that reads as a different
    /// control.
    ///
    /// A color rather than a filled pill because that is what the state is: an emphasis on a glyph
    /// the user already knows, not a new object. It also survives the one place a pill would not —
    /// the glyph is 13pt and a pill behind it would be most of the gap between the two neighbors.
    static let activeColor = Color(.sRGB, red: 250.0 / 255, green: 36.0 / 255, blue: 60.0 / 255, opacity: 1)

    /// The two outermost slots on each side, drawn narrower than the three in the middle.
    ///
    /// The row is seven controls now rather than five, and it fits because the outer four are 32pt
    /// wide against the middle three's 38: 3×38 + 4×32 + 6×12 = 314pt inside a 344pt content
    /// column. **The play button's center and the two skip centers are unchanged**, which is not a
    /// coincidence and not luck — `NowPlayingExpandedLayout.skipButtonCenter` derives them from
    /// `transportButtonSize` and `transportButtonSpacing`, and `TransportSelfTest` presses those
    /// points and asserts the command went out. A layout that put the new controls anywhere but
    /// symmetrically outside them would have moved the ones the self-test aims at — and so would
    /// widening the buttons without narrowing the gaps by the same amount, which is why the two
    /// constants carry a note about each other.
    var body: some View {
        HStack(spacing: NowPlayingExpandedLayout.transportButtonSpacing) {
            // The star, at the leading edge. Dimmed like shuffle and repeat, because it says
            // something about the *track* rather than changing what is playing now — and lit when
            // it is on, where a filled glyph alone would read as a disabled state.
            //
            // **A star and not a heart**, because Music calls this Favorite and draws a star for it.
            // The heart was Apple's own glyph for the feature this replaced — Love — and keeping it
            // would have meant Isleta drawing one symbol for a control the app beside it draws with
            // another, which is the "close enough" the brief rules out. `docs/NAMING.md`: name a
            // thing what the user's own machine calls it.
            button(
                .toggleFavorite, symbol: isFavorite ? "star.fill" : "star", size: Self.secondaryGlyph,
                enabled: canFavorite, dimmed: true, active: isFavorite, width: Self.secondaryWidth
            )
            // Dimmer than the three transport glyphs, as the reference has its outermost pair:
            // these change how the queue behaves rather than what is playing now, and the eye should
            // land on play first. Lit, they stop being dim — an active setting is information, and
            // §6.3's rule about "secondary" being hierarchy rather than information cuts both ways.
            button(
                .toggleShuffle, symbol: "shuffle", size: Self.secondaryGlyph,
                enabled: canChangeQueueBehavior, dimmed: true, active: isShuffling,
                width: Self.secondaryWidth
            )
            // Previous/next, or the fifteen-second jumps where the player offers them. The same
            // positions and the same sizes, because a podcast's back-15 is the control a listener
            // reaches for in exactly the place a song's previous-track lives.
            if canSkipBackFifteen {
                button(.skipBackFifteen, symbol: "gobackward.15", size: Self.primaryGlyph, enabled: true)
            } else {
                button(.previousTrack, symbol: "backward.fill", size: Self.primaryGlyph, enabled: canSkip)
            }
            button(.togglePlayPause, symbol: isPlaying ? "pause.fill" : "play.fill", size: Self.playGlyph, enabled: true)
            if canSkipForwardFifteen {
                button(.skipForwardFifteen, symbol: "goforward.15", size: Self.primaryGlyph, enabled: true)
            } else {
                button(.nextTrack, symbol: "forward.fill", size: Self.primaryGlyph, enabled: canSkip)
            }
            button(
                .toggleRepeat, symbol: repeatMode.symbol, size: Self.secondaryGlyph,
                enabled: canChangeQueueBehavior, dimmed: true, active: repeatMode.isOn,
                width: Self.secondaryWidth
            )
            // Up Next, at the trailing edge. **Absent, not dimmed**, where the route reads no
            // queue: there is no such feature in that build, and a grayed control would say there
            // is. That is the same line `isTransportAvailable` draws for the whole row, one control
            // down.
            //
            // The row stays centerd when it is absent, because the leading heart is drawn on every
            // build and the two are the same width — so the asymmetry is one 28pt slot at the far
            // end rather than a set of glyphs sliding across the island.
            if canReadQueue {
                button(
                    .toggleQueue, symbol: "list.bullet", size: Self.secondaryGlyph,
                    enabled: true, dimmed: true, active: isShowingQueue, width: Self.secondaryWidth
                )
            }
        }
        // The wash fades rather than snapping, on the token every content change in the island
        // travels on (§6.1) — keyed on `hovered` so it covers the pointer moving *between* two
        // controls as one crossfade, and so nothing else in the row is animated by it.
        .animation(Motion.contentSwap, value: hovered)
    }

    /// The outer four. Narrower than `transportButtonSize.width` so seven controls fit the column
    /// without the middle three losing their target. The same number lives in
    /// `NowPlayingExpandedLayout.secondaryButtonWidth`, which is what lets the fit be asserted
    /// without a view — see there.
    static let secondaryWidth = NowPlayingExpandedLayout.secondaryButtonWidth

    /// The glyph in the three primary controls, and in the play/pause at the middle of them.
    ///
    /// **18 and 24, up from 15 and 19 on 2026-08-28.** At rest a transport button *is* its glyph —
    /// the frame is a press target and the wash only appears under the pointer — so the widening
    /// that went with this changed the target and nothing anybody was looking at. This is the part
    /// that is looked at.
    ///
    /// Bounded by the box rather than by taste: a 24pt `play.fill` in a 42x30 frame keeps several
    /// points of air on every side, which is what stops the wash reading as a button with a glyph
    /// jammed into it.
    ///
    /// **A step above the home page's mini row, which is the hierarchy restored.** That row briefly
    /// outgrew this one — it had been matched to the player and then raised when the cover above it
    /// grew, while this stayed where it was. The mini row is a reminder beside a calendar; this is
    /// the page about the track, and it should be the larger of the two.
    static let primaryGlyph: CGFloat = 18

    static let playGlyph: CGFloat = 24

    /// The four outer controls — favorite, shuffle, repeat, Up Next.
    ///
    /// **Deliberately well below the primaries', and 15 rather than 18.** These are settings you
    /// change occasionally; those are the controls you press. Raising all seven together would have
    /// spent the extra size on flattening exactly the distinction the row is arranged around. Up
    /// Next was a point smaller again at 12, which was a third weight in a row that only has room
    /// for two.
    static let secondaryGlyph: CGFloat = 15

    private func button(
        _ command: NowPlayingControlCommand,
        symbol: String,
        size: CGFloat,
        enabled: Bool,
        dimmed: Bool = false,
        active: Bool = false,
        width: CGFloat = NowPlayingExpandedLayout.transportButtonSize.width
    ) -> some View {
        Button {
            action(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle((active ? Self.activeColor : color).opacity({
                    guard enabled else {
                        return ActivityPalette.secondaryOpacity(increaseContrast: increaseContrast) * 0.6
                    }
                    // Never dimmed under increase contrast: the whole point of that setting is that
                    // a control is not hard to see, and "secondary" is a hierarchy cue rather than
                    // information (§6.3).
                    return dimmed && !active && !increaseContrast ? 0.55 : 1
                }()))
                // The glyph itself changes when repeat reaches "one", so the transition has to cover
                // the symbol as well as the color — `.contentTransition(.opacity)` below animates
                // the fill, and this is what lets `repeat` become `repeat.1` in the same beat rather
                // than snapping a frame ahead of it.
                .transition(.opacity)
                // A 15pt glyph is a ~17pt target. The frame is what makes it 30pt, and
                // `.contentShape` is what makes the whole frame grabbable rather than only the
                // glyph's own coverage — without it the gaps inside a "backward.fill" chevron are
                // holes the press falls through.
                .frame(width: width, height: NowPlayingExpandedLayout.transportButtonSize.height)
                // Behind the glyph and inside the frame, so the wash is exactly the press target.
                .background(hoverWash(isOn: enabled && hovered == command))
                .contentShape(Rectangle())
                .contentTransition(.opacity)
                // A sibling that answers no hit test, so the press it reports about still reaches
                // the button. Reported whether or not the control is enabled: a disabled one draws
                // no wash (above), but the pointer resting on `next` while a track loads must find
                // it already lit at the instant the player says it can skip.
                .background(PointerPresence { isOver in
                    if isOver {
                        hovered = command
                    } else if hovered == command {
                        // Only ever clears *this* control. A blind `nil` would blank the wash the
                        // neighbor has already claimed when the two crossings arrive out of order.
                        hovered = nil
                    }
                })
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label(for: command))
        .accessibilityValue(accessibilityValue(for: command) ?? "")
    }

    /// What the control under the pointer is drawn on.
    ///
    /// **One view whose opacity animates, not a view that comes and goes.** A wash inserted and
    /// removed is a transition, and a transition across a row of seven controls at pointer speed is
    /// SwiftUI tearing down and rebuilding a view on every crossing; this is one rounded rectangle
    /// per button that is transparent when it is not wanted.
    ///
    /// A white wash, the weight `ActivitySwitcherView`'s chips are drawn at and for the same reason:
    /// the island is darker than anything drawn on it, so a control lifts *up* from the background
    /// rather than being shaded into it. It is deliberately lighter than the switcher's own chip —
    /// this says "the pointer is here", where a chip says "this is a control", and the transport
    /// glyphs already say the second part.
    private func hoverWash(isOn: Bool) -> some View {
        RoundedRectangle(
            cornerRadius: NowPlayingExpandedLayout.transportHoverCornerRadius,
            style: .continuous
        )
        .fill(.white.opacity(isOn ? (increaseContrast ? 0.26 : 0.13) : 0))
    }

    private func label(for command: NowPlayingControlCommand) -> String {
        switch command {
        case .previousTrack: islandText("nowPlaying.transport.previous", "Previous track")
        case .togglePlayPause:
            isPlaying
                ? islandText("nowPlaying.transport.pause", "Pause")
                : islandText("nowPlaying.transport.play", "Play")
        case .nextTrack: islandText("nowPlaying.transport.next", "Next track")
        case .toggleShuffle: islandText("nowPlaying.transport.shuffle", "Shuffle")
        case .toggleRepeat: islandText("nowPlaying.transport.repeat", "Repeat")
        case .toggleFavorite:
            isFavorite
                ? islandText("nowPlaying.transport.unfavorite", "Remove Favorite")
                : islandText("nowPlaying.transport.favorite", "Favorite")
        case .skipBackFifteen:
            islandText("nowPlaying.transport.backFifteen", "Back fifteen seconds")
        case .skipForwardFifteen:
            islandText("nowPlaying.transport.forwardFifteen", "Forward fifteen seconds")
        case .toggleQueue:
            isShowingQueue
                ? islandText("nowPlaying.transport.hideUpNext", "Hide Up Next")
                : islandText("nowPlaying.transport.showUpNext", "Show Up Next")
        }
    }

    /// The state, said separately from the name.
    ///
    /// It used to be omitted entirely, on the grounds that the player never reports these settings
    /// and claiming one would be worse than saying nothing. That is still true of the *player's*
    /// state — what is said here is what the user asked for, which is the same thing the highlight
    /// claims. A sighted user gets the color; this is that color, spoken.
    private func accessibilityValue(for command: NowPlayingControlCommand) -> String? {
        // Asked per command rather than behind one guard, because the four limits are unrelated:
        // the station guard belongs to shuffle and repeat, and applying it to the heart would
        // silence a control whose state the player reports perfectly well on a radio station.
        switch command {
        case .toggleShuffle:
            // A station has no queue: saying "off" would describe a setting that does not exist.
            guard canChangeQueueBehavior else { return nil }
            return isShuffling
                ? islandText("nowPlaying.state.on", "On")
                : islandText("nowPlaying.state.off", "Off")
        case .toggleRepeat:
            guard canChangeQueueBehavior else { return nil }
            switch repeatMode {
            case .off: return islandText("nowPlaying.state.off", "Off")
            case .all: return islandText("nowPlaying.repeat.all", "All")
            case .one: return islandText("nowPlaying.repeat.one", "One")
            }
        case .toggleFavorite:
            // Unlike the two above, this state is *reported* rather than remembered — so it is
            // said even where the control is inert, because "off" is then the player's answer and
            // not ours.
            guard canFavorite else { return nil }
            return isFavorite
                ? islandText("nowPlaying.state.on", "On")
                : islandText("nowPlaying.state.off", "Off")
        case .toggleQueue:
            return isShowingQueue
                ? islandText("nowPlaying.queue.showing", "Showing")
                : islandText("nowPlaying.queue.hidden", "Hidden")
        case .previousTrack, .togglePlayPause, .nextTrack,
             .skipBackFifteen, .skipForwardFifteen:
            return nil
        }
    }
}
