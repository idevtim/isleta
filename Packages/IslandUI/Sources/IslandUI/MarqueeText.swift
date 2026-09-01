import AppKit
import SwiftUI

/// One line of text that scrolls sideways when it is too long for the room it has, and sits still
/// when it is not.
///
/// ## Why this is CoreAnimation and not SwiftUI
///
/// §9 and `CLAUDE.md` are unambiguous: continuous animation belongs to CoreAnimation. A SwiftUI
/// `.offset` on a repeating linear animation is not per-frame *drawing*, but it is a per-frame trip
/// through SwiftUI's animation machinery on the main thread, and it runs for as long as the pointer
/// rests on the album cover. A `CABasicAnimation` on `position.x` is handed to the render server
/// once and costs the main thread nothing after that — the same trade `EqualiserBarsView` made, for
/// the same reason, with the measurements written out there.
///
/// ## Why the text is duplicated
///
/// Two copies of the line with `gap` between them, scrolled by exactly one copy's width plus the
/// gap and then repeated. That makes the wrap seamless: at the moment the cycle restarts, the
/// second copy is standing precisely where the first one began, so there is nothing to hide.
/// Scrolling one copy out and back would give the reader a stretch of empty island and a snap at
/// the end of it.
///
/// ## Why it stops between cycles
///
/// **A line that never stops moving is a line nobody reads the beginning of.** The first version
/// held still once and then travelled forever, and what that produces is a title whose opening
/// words are only ever legible in the first second of the track — after that the reader arrives
/// mid-phrase every time they look, and has to wait a full lap for the start to come round.
///
/// So each cycle is `hold` then travel, and the hold is at the *start* position, which is where the
/// words that identify a track are. It is one `CAKeyframeAnimation` rather than a chain of
/// animations for the same reason the travel is one `CABasicAnimation` was: the render server is
/// handed the whole loop once and the main thread never hears about it again.
///
/// ## What it does under Reduce Motion
///
/// Nothing moves. §6.3 asks for motion to be *substituted*, and the substitution for "the rest of
/// this line is over there" is the truncation everything else on the island uses — the line is
/// drawn once, clipped, with a tail fade. A marquee is the one animation in the island a reader
/// cannot look away from, so honoring the setting here is a correctness requirement rather than
/// politeness.
enum MarqueeMetrics {

    /// Points of clear air between the two copies. Wide enough that the repeat reads as the same
    /// line coming round again rather than as two different lines chasing each other.
    static let gap: CGFloat = 44

    /// How fast the line travels, in points per second.
    ///
    /// Slow — a title is read at a glance, and a marquee that outruns the eye is decoration.
    static let speed: CGFloat = 26

    /// How long the line holds still at the start of every cycle, the first one included.
    ///
    /// The first thing a reader does is read the beginning, and a line already moving when they
    /// arrive makes them chase it. Long enough to take in a title and an artist at a glance —
    /// measured against the two lines the open player draws, which is the surface with the most to
    /// read — and short enough that a reader waiting for the rest of a long title is not left
    /// wondering whether it is going to move at all.
    static let hold: TimeInterval = 1.5
}

struct MarqueeText: NSViewRepresentable {

    let text: String
    let font: NSFont
    let color: NSColor
    let reduceMotion: Bool

    /// Where the line sits **when it fits** — it has no meaning once it is scrolling, because a
    /// line wider than its box has no centre to speak of.
    ///
    /// Two surfaces want different answers and both are right. The track lip centres, because a
    /// short title pinned left with 60pt of empty island beside it reads as a layout that gave up
    /// under a symmetric notch. The open player's title block is left-aligned against a cover, and
    /// a centred title there would be the one thing in the row not lining up with the rest.
    var alignment: Alignment = .center

    /// How far in from the leading edge a travelling line starts. See `MarqueeTextView`.
    var contentInset: CGFloat = 0

    /// A drop shadow under the glyphs, for a caller drawing over something it does not control.
    ///
    /// Zero everywhere in the island, where the line sits on `#000000` or on the island's own glass
    /// and needs nothing. The lock screen is the case it exists for: white text on Liquid Glass
    /// over an arbitrary wallpaper, where the contrast has to come from the letters rather than
    /// from darkening the material — `LockScreenCardView.glassScrimOpacity` records why.
    ///
    /// On the text layers rather than as a SwiftUI `.shadow`, because that modifier filters a
    /// rendered SwiftUI subtree and this line is an `NSView` hosting `CATextLayer`s of its own.
    /// The render server draws it, which is the same trade the marquee itself makes.
    var shadowOpacity: Float = 0

    /// The blur, in points. Ignored when `shadowOpacity` is zero.
    var shadowRadius: CGFloat = 0

    enum Alignment: Sendable {
        case leading
        case center
    }

    func makeNSView(context: Context) -> MarqueeTextView {
        MarqueeTextView()
    }

    func updateNSView(_ view: MarqueeTextView, context: Context) {
        view.apply(
            text: text, font: font, color: color, reduceMotion: reduceMotion,
            alignment: alignment, contentInset: contentInset,
            shadowOpacity: shadowOpacity, shadowRadius: shadowRadius
        )
    }
}

/// The layer-backed half of `MarqueeText`.
///
/// **`hitTest` returns nil unconditionally**, as `PointerPresence` and `EqualiserBarsView` both do
/// and for the same reason: this view is inside the island, and an `NSView` that claimed a point
/// would take a press that `IslandHitTestView` has to see. It draws and reports nothing.
final class MarqueeTextView: NSView {

    private let track = CALayer()
    private let first = CATextLayer()
    private let second = CATextLayer()

    private var text = ""
    private var reduceMotion = false
    private var alignment: MarqueeText.Alignment = .center
    private var contentInset: CGFloat = 0
    private var textWidth: CGFloat = 0

    private static let animationKey = "isleta.marquee"
    /// How far in from the leading edge a **travelling** line starts.
    ///
    /// **For a caller whose line is drawn under a fade.** The track lip masks both ends so a
    /// scrolling line arrives out of the island's own black rather than off a hard cut — and a
    /// travelling line starts hard against x=0, which is underneath the ramp, so the first character
    /// of a long artist was drawn at partial opacity and read as missing. Reported from use.
    ///
    /// The fix is not a narrower fade: the fade is right, and it has to be there or the line pops in
    /// and out at the edge. It is that the text should *begin* clear of it and pass through it as it
    /// travels, which is what the eye expects of a thing scrolling out of a shadow.
    ///
    /// Applies to the travelling case only. A line that fits is centred (or ranged leading) and is
    /// nowhere near the ends, so insetting it would move text that had no problem.
    private static let crossfadeKey = "isleta.marquee.swap"

    /// How far past the top and bottom of the line the view is allowed to draw.
    ///
    /// **The clip is horizontal, and it always was — the vertical half of it was incidental.** This
    /// view exists to scroll a line sideways past a fixed width, and `masksToBounds` was how that
    /// was expressed. It also clipped the *top and bottom*, which nothing here needed until the
    /// glyphs were given a shadow: a 4pt blur on a line in a box sized to the glyphs has nowhere to
    /// fall, so it was cut off flat above and below the letters instead of fading out. Reported on
    /// sight of it on the lock screen.
    ///
    /// So the mask is a layer rather than a flag, and it is generous vertically. Nothing overflows
    /// it but a shadow: the text layers are exactly the view's height and their glyphs are drawn
    /// inside that.
    static let verticalOverflow: CGFloat = 16

    private let clip = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clip.backgroundColor = NSColor.black.cgColor
        clip.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.mask = clip
        for text in [first, second] {
            text.anchorPoint = .zero
            text.alignmentMode = .left
            // Never truncated by the layer itself. Whether the line is clipped is this view's
            // decision — it depends on Reduce Motion — and a layer that had already put an ellipsis
            // in would make the scrolling copy carry one too.
            text.truncationMode = .none
            text.isWrapped = false
            // Implicit animations off for good, exactly as `EqualiserBarsView` turns them off and
            // for the same reason: a layer property assigned outside an explicit transaction
            // animates over CoreAnimation's own 0.25s default, which is an inline duration by the
            // back door and §6.1 forbids those whichever framework writes them.
            text.actions = [
                "bounds": NSNull(), "position": NSNull(),
                "contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull(),
            ]
            track.addSublayer(text)
        }
        track.anchorPoint = .zero
        track.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MarqueeTextView is not loaded from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Unflipped, matching `EqualiserBarsView`. A flipped layer-backed view sets
    /// `isGeometryFlipped` on its backing layer, and a `CATextLayer` under a flipped parent draws
    /// its glyphs upside down — the classic way this view fails, and one no test catches.
    override var isFlipped: Bool { false }

    /// Rasters are per-display, so this is re-read rather than set once — an island dragged to a
    /// 1x display and back would otherwise draw a 2x raster scaled down, which on 10pt text is the
    /// difference between crisp and smeared.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [first, second] { text.contentsScale = scale }
        layer?.contentsScale = scale
    }

    func apply(
        text: String,
        font: NSFont,
        color: NSColor,
        reduceMotion: Bool,
        alignment: MarqueeText.Alignment,
        contentInset: CGFloat = 0,
        shadowOpacity: Float = 0,
        shadowRadius: CGFloat = 0
    ) {
        let changed = text != self.text
            || reduceMotion != self.reduceMotion
            || alignment != self.alignment
            || contentInset != self.contentInset
        self.alignment = alignment
        self.contentInset = contentInset
        // **A track change crossfades, exactly as it did when this was a `Text`.** §6.2's "same
        // activity, new content" is the whole of what a new title is, and replacing a `Text` with a
        // layer would otherwise have quietly swapped a crossfade for a snap — a regression nobody
        // would file, because the frame it happens on is the one everything else is moving in.
        //
        // `Motion.contentSwapDuration` rather than a number: it exists for precisely this, the
        // CoreAnimation caller that cannot take an `Animation`, and reading it is what keeps the
        // title crossfading on the same curve length as the artist beside it and the equaliser
        // across the row — including under the user's animation speed.
        let crossfades = changed && !self.text.isEmpty && !text.isEmpty && !reduceMotion
        self.text = text
        self.reduceMotion = reduceMotion

        // Everything but the string, with actions off. Belt and braces with the `actions` map in
        // the initialiser: a layer property assigned outside an explicit transaction animates over
        // CoreAnimation's own 0.25s default, which is an inline duration by the back door.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [first, second] {
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = color.cgColor
            // Black and straight down, which is what a shadow for legibility is: it exists to put
            // a dark edge under every glyph whatever is behind them, not to imply a light source.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = shadowOpacity
            layer.shadowRadius = shadowRadius
            layer.shadowOffset = .zero
        }
        textWidth = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        CATransaction.commit()

        // The string last, and on its own, because this is the one property that is *allowed* to
        // animate — and an explicit `CATransition` is unaffected by the `actions` map, which only
        // governs the implicit lookup. Set inside a transaction with actions disabled it would be
        // suppressed along with everything else, which is why the two are not one block.
        if crossfades {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.contentSwapDuration
            for layer in [first, second] { layer.add(fade, forKey: Self.crossfadeKey) }
            for layer in [first, second] { layer.string = text }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [first, second] { layer.string = text }
            CATransaction.commit()
        }

        if changed { restart() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The clip follows the bounds, wide as the line and taller than it. See `verticalOverflow`.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = CGRect(
            x: 0,
            y: -Self.verticalOverflow,
            width: bounds.width,
            height: bounds.height + Self.verticalOverflow * 2
        )
        CATransaction.commit()
        restart()
    }

    /// Lays the two copies out and starts — or refuses to start — the travel.
    ///
    /// Idempotent, and called from both `layout()` and `apply`: the island changes shape under this
    /// view all the time, and an animation left running against the old width would scroll the line
    /// to somewhere it no longer has to go.
    private func restart() {
        let height = bounds.height
        let available = bounds.width
        guard available > 0, height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        track.removeAnimation(forKey: Self.animationKey)

        let fits = textWidth <= available
        // The static case, which is most of them: one copy, clipped to the room available, and the
        // second one moved out of the way rather than hidden — a hidden layer that is later shown
        // arrives with a fade the island did not ask for.
        let travels = !fits && !reduceMotion

        // Where the line sits while it fits — see `MarqueeText.alignment`. Once it is scrolling
        // there is no "centre" to speak of, so a travelling line starts against the leading edge
        // whatever the caller asked for — plus `contentInset`, which is the whole of that property.
        let centred = (fits && alignment == .center) ? ((available - textWidth) / 2).rounded() : 0
        let inset = travels ? contentInset : centred
        first.frame = CGRect(x: inset, y: 0, width: max(textWidth, available), height: height)
        second.frame = CGRect(
            x: travels ? inset + textWidth + MarqueeMetrics.gap : available * 2,
            y: 0,
            width: max(textWidth, available),
            height: height
        )
        track.frame = CGRect(x: 0, y: 0, width: max(textWidth, available) * 2, height: height)

        guard travels else { return }

        let distance = textWidth + MarqueeMetrics.gap
        let travelSeconds = CFTimeInterval(distance / MarqueeMetrics.speed)
        let cycle = MarqueeMetrics.hold + travelSeconds

        // Three keyframes, two segments: hold at the start, then travel one whole copy plus the
        // gap. The wrap back to the first keyframe is invisible because the second copy is standing
        // exactly where the first began, so what the reader sees is *stop, scroll, stop, scroll*
        // with no seam in either transition.
        let travel = CAKeyframeAnimation(keyPath: "position.x")
        travel.values = [0, 0, -distance]
        travel.keyTimes = [0, NSNumber(value: MarqueeMetrics.hold / cycle), 1]
        // Linear, and this is the one place in the island where that is right: a marquee is a
        // constant reading speed, not a gesture, and easing it would make the same line legible at
        // the middle and unreadable at both ends. It is not an inline `.easeInOut(duration:)` of
        // the kind §6.1 forbids — there is no spring that expresses "read this at a steady pace".
        travel.calculationMode = .linear
        travel.duration = cycle
        travel.repeatCount = .infinity
        track.add(travel, forKey: Self.animationKey)
    }
}
