import AppKit
import IslandKit
import SwiftUI

/// The music card on the lock screen.
///
/// ## Three controls, on a surface that receives no events
///
/// This card used to carry none, and the reason was measured: loginwindow captures every event on a
/// locked screen, for every process, across fourteen probe runs.
/// **That finding still holds and nothing here contradicts it** — no `mouseDown` reaches this
/// panel, no `NSTrackingArea` fires, no SwiftUI `Button` can ever be sent an action.
///
/// What was wrong was the conclusion drawn from it. Two things the window server answers as
/// **global queries** rather than as events are readable behind the shield, and both were measured
/// moving there before a line of this was written:
///
/// - `NSEvent.mouseLocation` — where the pointer is.
/// - `NSEvent.pressedMouseButtons` — whether a button is down.
///
/// The padlock has been using both since it shipped, to peek under the pointer and swell under a
/// press. A press *on a rectangle we know the screen coordinates of* is therefore a click we can
/// resolve ourselves: `LockScreenCardLayout.transportFrame` gives the three targets in global
/// points, `LockScreenNotchView`'s display link samples the pointer at 30Hz for both surfaces, and
/// `LockScreenCardModel.updateControlPress` sends the command on the press edge through the same
/// `NowPlayingController` the island's own transport row uses.
///
/// **So the old rule inverts rather than bends.** It said nothing here may look pressable, because
/// a control that cannot be operated is worse than an absent one. These *can* be operated, so they
/// must look it — a wash under the pointer, a swell under the press — and the ones that cannot are
/// still absent rather than dimmed: shuffle, repeat, favorite and the route picker are not drawn,
/// and `hasTransport` false draws no row at all.
///
/// Two things this does not get, and they are the honest cost of a synthesized click rather than a
/// delivered one: **no cursor change**, because the cursor belongs to loginwindow, and **a press
/// resolved on the down edge** at a 30Hz sample rather than on a release inside the target, so a
/// press-and-drag-away cannot be taken back.
///
/// ## Liquid Glass, clear, with nothing over it
///
/// The card is `glassEffect(.clear, in:)` and **carries no veil of any kind** — that is the whole
/// specification, and it took five attempts to arrive at. `.clear` is the material macOS puts under
/// a desktop widget: the wallpaper reads through it almost unaltered, a little lifted and a little
/// desaturated, with a thin bright line where the edge catches. It is a lens, and the point of a
/// lens is that you can see what is behind it.
///
/// The legibility that a veil would have bought comes from the **content** instead — every word and
/// glyph on this card carries a shadow (`textShadowOpacity`). That is local to the letters, does
/// nothing over a dark backdrop and everything over a bright one, and leaves the material alone.
/// `PROGRESS.md` has the five treatments that were measured on the way here and what each of them
/// cost; the short version is that every one of them bought its contrast by darkening the glass,
/// which is exactly what stopped it looking like Apple's.
///
/// Two things inherited from the synthesized island, each of which has already cost a session:
///
/// - **The glass is a sibling below the content, never `content.background(…glassEffect…)`.** The
///   latter composites the glass *above* what it is behind, and every label draws blurred through
///   it.
/// - **The shape handed to it is a built-in `RoundedRectangle`.** `glassEffect(_:in:)` against a
///   custom `Shape` conformance renders zero alpha — see `IslandMaterialView.glass`.
///
/// **This is not the same as a material, and the distinction is the whole point of the change.** An
/// earlier build used `.ultraThinMaterial` here and it came out a flat white rectangle on hardware:
/// an `NSVisualEffectView` samples the window behind it, and on a locked screen that is
/// loginwindow's shield rather than a desktop. Liquid Glass is a different renderer, and the two
/// surfaces in this app that already use it are drawn over arbitrary content without sampling a
/// sibling window. **Not yet re-measured against the shield** — `--lockscreen-demo` draws the card
/// on an unlocked desktop, which is a different backdrop, so the shield remains a lock away.
///
/// Labels stay explicit white rather than `.primary` — the first build let them follow the user's
/// appearance and drew dark text in light mode, which nobody could have caught by looking, because
/// the surface only exists while nobody is at the Mac.
///
/// ## Motion
///
/// The card **drops in on `Motion.reveal`**, scaled from its own top edge, at
/// `LockScreenController.lockArrivalAt` — the beat the padlock springs out of the cutout on — and
/// leaves on `Motion.collapse` the instant the Mac is
/// unlocked — see `LockScreenCardModel.isPlayingOnScreen` for why the two surfaces part company on
/// the way out. One `ActivityClock` at `.seconds` in between, and only while a playhead is
/// advancing. No equaliser: §9's budget is measured on a machine somebody is using, and this is on
/// screen precisely when nobody is.
public struct LockScreenCardView: View {

    @Bindable var model: LockScreenCardModel

    public init(model: LockScreenCardModel) {
        self.model = model
    }

    /// Published by the display link, gated to whole seconds. Seeded rather than optional so the
    /// first frame prints real numerals rather than a placeholder replaced a second later.
    @State private var now = Date()


    /// How small the card is on the far side of its arrival, and how small it goes on the way out.
    ///
    /// One number for both directions, because the two directions are one movement played twice —
    /// what tells them apart is the token, not the distance. 0.90 rather than the 0.96 this was:
    /// a bounce needs travel to be a bounce, and at 4% the overshoot was smaller than the card's
    /// corner radius and read as a flicker rather than as weight.
    ///
    /// Anchored at the **top**, which is the whole reason `Motion.reveal` is the right token: the
    /// card grows downward out of its own top edge, the way the island drops out of the bezel, and
    /// leaves the same way in reverse. Anchored at the centre it would bloom outward from nothing,
    /// which is a dialog appearing, not a surface being handed over.
    private static let arrivalScale: CGFloat = 0.90

    public var body: some View {
        ZStack {
            if model.isPlayingOnScreen {
                card
                    .transition(
                        model.reduceMotion
                            ? .opacity
                            : .opacity.combined(
                                with: .scale(scale: Self.arrivalScale, anchor: .top)
                            )
                    )
            }
        }
        // **The root fills the panel, not the card.** The card carries its own `.frame`, so this one
        // is the *window's* size — which is what centres the card inside the margin the bounce needs
        // (`LockScreenCardLayout.overshootMargin`) rather than leaving that to whatever
        // `NSHostingView` does with spare points. See `LockScreenCardLayout.panelSize`.
        .frame(width: LockScreenCardLayout.panelSize.width, height: LockScreenCardLayout.panelSize.height)
        // **Two tokens, one per direction**, which is the codebase's own division by *which edge
        // moves* rather than a curve invented here: the card arriving grows downward, so it is
        // `Motion.reveal` — the same bounce the island drops out of the bezel on — and the card
        // leaving is the unlock, which is `Motion.collapse`, the shortest and best damped spring in
        // the file, because the Mac is already the user's again and a surface still settling over
        // their desktop is the two-animations-at-once complaint `returnDelay` records. Under reduce
        // motion both become the crossfade.
        //
        // This was `Motion.expand` in, which grows and *arrives*: correct for a panel being opened
        // onto and wrong for this, which is a surface appearing on a screen nobody is touching and
        // has to announce itself.
        .animation(
            Motion.respectingReduceMotion(
                model.isPlayingOnScreen ? Motion.reveal : Motion.collapse,
                reduceMotion: model.reduceMotion
            ),
            value: model.isPlayingOnScreen
        )
        .background(clock)
    }

    /// Zero-sized, and never given `.allowsHitTesting(false)` — see `ActivityClock.DisplayLinkView`.
    @ViewBuilder
    private var clock: some View {
        ActivityClock(rate: model.clockRate) { instant in
            now = instant
        }
    }

    private var card: some View {
        // Explicit spacers rather than a `VStack` spacing, because the three gaps are three
        // different numbers and `LockScreenCardLayout.stackedHeight` adds exactly these terms up to
        // `size.height`. A single spacing would make the assertion in `LockScreenSurfaceTests`
        // describe a layout the view does not have.
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0).frame(height: LockScreenCardLayout.progressSpacing)
            progressRow
                .shadow(
                    color: .black.opacity(Double(Self.textShadowOpacity)),
                    radius: Self.textShadowRadius
                )
            Spacer(minLength: 0).frame(height: LockScreenCardLayout.transportSpacing)
            // **Less shadow than the words.** The glyphs are solid, 20-26pt and white — they are
            // legible on a fraction of what a 14pt artist line needs — and at the text's own
            // strength the row read as three buttons floating above the card rather than sitting
            // on it. A control on glass should look pressed into the material, not laid on it.
            transportRow
                .shadow(
                    color: .black.opacity(Self.controlShadowOpacity),
                    radius: Self.controlShadowRadius
                )
        }
        // **The content carries its own legibility, and the material carries none of it.**
        //
        // This is the whole shape of the fix. A card of white text over a wallpaper needs contrast
        // from somewhere, and the first three attempts all took it out of the glass — a 0.32 veil,
        // a 0.48 veil, a 0.55 one held off the edge — each of which bought its ratio by making the
        // plate darker, until what was left was a dark rounded rectangle with a bright rim. Every
        // one of them was measured, and every one of them read as "not Liquid Glass" on sight,
        // which is the verdict that matters on a surface whose whole job is to look like Apple's.
        //
        // A shadow on the *glyphs* buys the same legibility and costs the material nothing: it is
        // local to the letters, it scales with how bright the wallpaper behind them is (a dark
        // shadow does nothing over a dark backdrop and everything over a white one), and the glass
        // is left to lens and refract at full strength. It is also what the platform does — the
        // lock screen's own clock and the notification stack both carry one.
        //
        // **The title and the artist are not covered by this one.** They are `MarqueeText`, which
        // hosts `CATextLayer`s in an `NSView`, and a SwiftUI shadow filters a SwiftUI subtree. They
        // carry the same two numbers on their own layers instead — see `MarqueeText.shadowOpacity`.
        .padding(.horizontal, LockScreenCardLayout.horizontalPadding)
        .padding(.vertical, LockScreenCardLayout.verticalPadding)
        .frame(
            width: LockScreenCardLayout.size.width,
            height: LockScreenCardLayout.size.height,
            alignment: .leading
        )
        .background(background)
        .clipShape(shape)
        // **No shadow.** It had one; see `LockScreenCardLayout.shadowMargin` for why a translucent
        // lens that also casts a hard shadow reads as a sticker rather than as glass.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The shadow the card's words carry so they are legible on clear glass over any wallpaper.
    ///
    /// **This is the card's whole legibility budget** — there is no veil under it. See the type
    /// comment for why the contrast lives on the content rather than on the material.
    ///
    /// A `Float` because `CALayer.shadowOpacity` is one and `MarqueeText` hands it straight to the
    /// render server — spelled once here so the two lines that are layers and the two rows that are
    /// SwiftUI cannot drift apart.
    ///
    /// Softened from 0.55/5 once it stopped being clipped. At that strength, cut flat top and
    /// bottom by the marquee's own mask, it read as a dark band behind the words rather than as a
    /// shadow — and a shadow allowed to fade out needs less of itself to do the same work.
    static let textShadowOpacity: Float = 0.45

    static let textShadowRadius: CGFloat = 4

    /// And the lighter one the transport glyphs carry. See `card`.
    static let controlShadowOpacity: Double = 0.28

    static let controlShadowRadius: CGFloat = 3


    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LockScreenCardLayout.cornerRadius, style: .continuous)
    }

    /// Clear Liquid Glass, or a solid fill when the user has asked for less transparency.
    ///
    /// Reduce transparency is a correctness requirement, not polish (§6.7), and it is the one case
    /// where the glass has to go entirely: `glassEffect` is a lens, and dimming it would leave a
    /// lens somebody has asked not to be given.
    private var background: some View {
        Group {
            if model.reduceTransparency {
                shape.fill(IslandMaterialView.black.opacity(0.96))
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // **`.clear`, and nothing over it.** Not `.regular`, not a tint, not a scrim —
                    // see the type comment, and `PROGRESS.md` for the four heavier treatments that
                    // were measured and rejected on the way here.
                    .glassEffect(.clear, in: shape)
            }
        }
        // **Only under increase contrast.** Glass draws its own edge, and a second one on top of it
        // is what makes the card look bordered rather than made of something. The setting is the
        // one case that overrides that: a user who has asked for edges wants the boundary findable
        // whatever the wallpaper does behind it.
        .overlay(
            shape.strokeBorder(
                .white.opacity(model.increaseContrast ? 0.32 : 0), lineWidth: 0.5
            )
        )
    }

    // MARK: - Header

    /// **`spacing: 0` and explicit gaps, which is not a style choice.**
    ///
    /// An `HStack`'s spacing applies between *every* adjacent pair, and this row has four children.
    /// Written as `HStack(spacing: artworkSpacing)` it charged 14pt three times — cover to text,
    /// text to spacer, spacer to bars — where the arithmetic in `textColumnWidth` accounts for it
    /// once. The row came out 28pt wider than the card and, with `alignment: .leading` on the
    /// frame, the overflow went off the trailing edge: the equaliser was drawn *outside* the card
    /// entirely, on whatever was behind it.
    ///
    /// It was over by 14 before the bars arrived, for the same reason, and nothing showed it —
    /// `clipShape` cut the overflow and there was nothing in it but a `Spacer`. The first thing
    /// ever placed at that edge is what surfaced it.
    private var header: some View {
        HStack(spacing: 0) {
            artwork
            Spacer(minLength: 0).frame(width: LockScreenCardLayout.artworkSpacing)
            VStack(alignment: .leading, spacing: LockScreenCardLayout.titleSpacing) {
                // **Both lines scroll**, on the island's own `MarqueeText`: a line that fits sits
                // still, one that does not holds at its start for `MarqueeMetrics.hold` and then
                // travels, and under Reduce Motion neither moves at all. This is the surface with
                // the strongest case for it — 261pt of column against album titles that carry a
                // remaster year and a parenthesis, read by somebody across a room who cannot lean
                // in and cannot hover to reveal the rest.
                //
                // CoreAnimation, not a SwiftUI offset: §9's rule, and it matters more here than
                // anywhere. This is on screen precisely when nobody is at the Mac, so the animation
                // that runs has to be one the render server owns outright.
                MarqueeText(
                    text: model.content?.title ?? "",
                    font: .systemFont(ofSize: 17, weight: .semibold),
                    color: .white,
                    reduceMotion: model.reduceMotion,
                    alignment: .leading,
                    shadowOpacity: Self.textShadowOpacity,
                    shadowRadius: Self.textShadowRadius
                )
                .frame(height: LockScreenCardLayout.titleLineHeight)
                .mask(Self.trailingFade)
                if let subtitle = model.content?.subtitle, !subtitle.isEmpty {
                    MarqueeText(
                        text: subtitle,
                        font: .systemFont(ofSize: 14, weight: .regular),
                        color: NSColor.white.withAlphaComponent(0.7),
                        reduceMotion: model.reduceMotion,
                        alignment: .leading,
                        shadowOpacity: Self.textShadowOpacity,
                        shadowRadius: Self.textShadowRadius
                    )
                    .frame(height: LockScreenCardLayout.subtitleLineHeight)
                    .mask(Self.trailingFade)
                }
                formatLine
            }
            .frame(width: LockScreenCardLayout.textColumnWidth, alignment: .leading)
            // The gap the bars sit behind, and the check that the row adds up: the terms of
            // `textColumnWidth` leave exactly `equaliserSpacing` here, so this spacer resolves to
            // that and nothing is pushed anywhere. `LockScreenSurfaceTests` asserts the sum.
            Spacer(minLength: 0)
            equaliser
        }
        .frame(height: LockScreenCardLayout.headerRowHeight)
    }

    /// The bars, at the trailing end of the header.
    ///
    /// **This card used to say, in as many words, that it would never have one** — "§9's budget is
    /// measured on a machine somebody is using, and this is on screen precisely when nobody is."
    /// The owner asked for it, and the number that argument rests on is not the one that applies:
    /// the equaliser has been six `CALayer`s driven by the render server since it was rewritten,
    /// measured at **0.0733 % of a core** against the 18 % the `Canvas` version cost. The main
    /// thread hears about it once, when the animation is handed over, and never again.
    ///
    /// It also earns its place here more than anywhere else in the app. On a locked screen there is
    /// no menu bar, no dock and no window to glance at — the bars are the only thing on the display
    /// that says whether the music is actually running, and when it stops they sink to a line
    /// rather than freezing mid-pattern, which is the difference between paused and hung.
    ///
    /// Album colors when there are any, exactly as the open island draws them.
    @ViewBuilder
    private var equaliser: some View {
        if model.hasTransport {
            NowPlayingEqualiserView(
                isPlaying: model.nowPlaying?.isPlaying ?? false,
                reduceMotion: model.reduceMotion,
                // **White, not the album's colors.** The island takes its accent from the cover
                // because it is a black strip in a bezel with one thing on it, and the color is
                // what ties the strip to the record. This card already has the cover on it at 64pt,
                // three lines of white text and five white glyphs — a sixth element in an album's
                // pink is the only colored thing on the surface, and it reads as an alert rather
                // than as a level meter. The owner's verdict on hardware.
                colors: nil,
                size: LockScreenCardLayout.equaliserSize
            )
        }
    }

    /// The cover — **the island's own `NowPlayingArtworkView`, not a second one.**
    ///
    /// It was a local `Image` in a clipped square, which drew the same picture and knew none of the
    /// things that view knows: the well with the activity's glyph for the beat before the fetch
    /// returns, the player's icon for a track with no cover at all, the hair of edge that stops a
    /// near-black sleeve dissolving into what is behind it — and the pause state, which is what
    /// brought this here. A cover that draws back to `pausedScale` and dims to `pausedOpacity` when
    /// the music stops is how the island already says "paused", and a second surface saying it
    /// differently is the inconsistency a user notices.
    ///
    /// `isPaused` is `coverIsPaused`, not `!isPlaying`, and the distinction is load-bearing: a route
    /// that cannot report transport state at all would otherwise draw every cover permanently
    /// dimmed. That rule is pinned by a test in `NowPlayingTests` because a version of it shipped
    /// for an hour depending on a third fact it should not have.
    private var artwork: some View {
        NowPlayingArtworkView(
            image: model.artwork,
            fallbackSymbol: model.content?.symbol ?? "music.note",
            side: LockScreenCardLayout.artworkSide,
            tint: .white,
            increaseContrast: model.increaseContrast,
            isPaused: NowPlayingSlotView.coverIsPaused(
                isTransportAvailable: model.hasTransport,
                isPlaying: model.nowPlaying?.isPlaying ?? false
            ),
            reduceMotion: model.reduceMotion
        )
    }

    /// The ramp the two scrolling lines end on.
    ///
    /// **Trailing only, where the track lip fades both ends.** The lip centres a line that fits, so
    /// a leading ramp never touches it; these are ranged left against the cover, so a fade at that
    /// edge would draw the first character of every short title at partial opacity — which reads as
    /// a missing letter, and is the exact failure `NowPlayingTrackLipLayout.marqueeInset` was
    /// written to fix from the other direction. The trailing edge is where a long line is actually
    /// cut, and a scrolling line arriving out of a ramp rather than off a hard edge is the whole
    /// point of having one.
    private static var trailingFade: some View {
        HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: NowPlayingTrackLipLayout.edgeFadeWidth)
        }
        // **Taller than the line it masks**, or it becomes the second thing cutting the glyphs'
        // shadow off flat — a mask is opaque only where it draws, and one sized to the line box
        // ends exactly where the blur begins. `MarqueeTextView.verticalOverflow` is the same fix
        // one layer down; both had to go for the shadow to fade out at all.
        .padding(.vertical, -MarqueeTextView.verticalOverflow)
    }

    /// The format badge, where the player reports one — Apple's own mark for Dolby Atmos, Lossless,
    /// Hi-Res Lossless, Spatial Audio and Apple Digital Master, read out of Music's bundle at
    /// runtime rather than shipped. `AudioFormatBadge` records why a reference is a different act
    /// from a copy, and `NowPlayingSlotView.formatLine` is the same line in the open island.
    ///
    /// **The line takes no room when there is no badge.** A library where the format is usually
    /// unknown would otherwise carry an empty strip under every artist and push the two lines above
    /// it off the cover's centre — the same thing that was tuned out of the island's copy.
    ///
    /// Read from `NowPlayingController` rather than from `ActivityContent`, because it arrives one
    /// query after the track does and there is no second activity change to carry it. That is the
    /// artwork's argument, on a second field — see `LockScreenCardModel.nowPlaying`.
    @ViewBuilder
    private var formatLine: some View {
        if let format = model.nowPlaying?.audioFormat {
            Group {
                if let badge = AudioFormatBadge.image(for: format.kind) {
                    // Drawn at its own size, never `.resizable()`: the badges are not one height —
                    // 18pt for Lossless, 14 for Atmos — and that difference is Apple's, made so
                    // they sit on a baseline together. Scaling a wordmark is how a trademark ends
                    // up soft or subtly the wrong proportions.
                    Image(nsImage: badge)
                        .renderingMode(.template)
                } else {
                    // Isleta's own, for the kinds Apple has no badge for and for a Mac with Music
                    // removed. §8: a fallback that is a real feature rather than an apology.
                    HStack(spacing: 4) {
                        Image(systemName: format.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(format.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
            // The least of the three lines: a fact about the file rather than about the music.
            .foregroundStyle(.white.opacity(model.increaseContrast ? 0.8 : 0.5))
            // The words' shadow, not the controls': this is a wordmark at 11pt over a wallpaper,
            // which is the case that needs it most.
            .shadow(
                color: .black.opacity(Double(Self.textShadowOpacity)),
                radius: Self.textShadowRadius
            )
            .frame(height: NowPlayingExpandedLayout.formatLineHeight, alignment: .leading)
            .animation(
                Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: model.reduceMotion),
                value: format
            )
        }
    }

    // MARK: - Transport

    /// Previous, play/pause and next, centered under the progress rule.
    ///
    /// Absent — not dimmed — when there is no transport at all: see
    /// `LockScreenCardModel.hasTransport`.
    @ViewBuilder
    private var transportRow: some View {
        if model.hasTransport {
            // **Plain glyphs, and `GlassEffectContainer` + `glassEffectUnion` were tried here.**
            // That pair is for merging several glass shapes into one piece of material — Apple's
            // own example unions a row of buttons — and it is the obvious thing to reach for. On
            // this card it made the row worse, twice over, and both are worth writing down:
            //
            // - **Unioned**, only the middle button drew a plate at all; the row read as one
            //   emphasised control between two bare glyphs rather than as a capsule.
            // - **Not unioned**, each button carried its own rim, and a rim on a control that is
            //   sitting on glass is an edge with nothing behind it to bend.
            //
            // The reason is upstream of the API: glass refracts *what is behind it*, and behind
            // these is the card, which is already glass. Apple's own transport rows — the iOS lock
            // screen's, Music's — are bare glyphs on the material for the same reason.
            HStack(spacing: LockScreenCardLayout.transportButtonSpacing) {
                // Walked from the same list `LockScreenCardLayout.transportFrame` places from, so
                // the drawn row and the hit-tested row cannot disagree about what is in it or what
                // order it is in. The symbol is the only thing that varies per control.
                ForEach(LockScreenTransportControl.allCases, id: \.self) { control in
                    transportButton(control, symbol: symbol(for: control))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// One button.
    ///
    /// **Every visible state here is driven from the model rather than from `.onHover` or a
    /// `Button`.** Neither can work: the panel is never key and never main and no event is ever
    /// delivered to it, so SwiftUI's hover never arrives and a `Button`'s action is never sent.
    /// What drives all three — the wash, the swell and the command — is the pointer sample the
    /// padlock's display link is already taking. See the type comment.
    /// Which glyph a control wears right now.
    ///
    /// Two of the five change with state, and both changes are the glyph itself rather than a color
    /// — play becomes pause, and repeat becomes `repeat.1`, which is the whole reason repeat is
    /// three states and not a flag. `NowPlayingRepeatMode.symbol` is where that lives, so the card
    /// and the island cannot draw the same mode differently.
    private func symbol(for control: LockScreenTransportControl) -> String {
        switch control {
        case .toggleShuffle: "shuffle"
        case .previousTrack: "backward.fill"
        case .playPause: model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill"
        case .nextTrack: "forward.fill"
        case .toggleRepeat: model.nowPlaying?.repeatMode.symbol ?? "repeat"
        }
    }

    private func transportButton(
        _ control: LockScreenTransportControl,
        symbol: String
    ) -> some View {
        let isHovered = model.hoveredControl == control
        let isEnabled = model.canOperate(control)
        let isActive = model.isActive(control)
        let size: CGFloat = switch control {
        case .playPause: LockScreenCardLayout.transportPrimaryGlyph
        case .previousTrack, .nextTrack: LockScreenCardLayout.transportSecondaryGlyph
        case .toggleShuffle, .toggleRepeat: LockScreenCardLayout.transportQueueGlyph
        }
        return Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            // Three states, in the island's own order of precedence. **Lit** where the setting is
            // on, in Music's own accent — an emphasis on a glyph the user already knows, not a new
            // object. **Dimmed** where the control is secondary, because these say something about
            // the queue rather than about what is playing now and the eye should land on play
            // first; never dimmed under increase contrast, where "secondary" is hierarchy rather
            // than information (§6.3). **Faded** where the route prohibits the command, which is
            // information and survives the setting.
            .foregroundStyle(
                (isActive ? NowPlayingTransportView.activeColor : .white).opacity({
                    guard isEnabled else { return 0.35 }
                    guard control.isSecondary, !isActive, !model.increaseContrast else { return 1 }
                    return 0.6
                }())
            )
            .frame(
                width: LockScreenCardLayout.transportWidth(of: control),
                height: LockScreenCardLayout.transportButtonSize
            )
            // **No glass on the buttons.** They are on a glass card, and a glass control on a
            // glass surface has nothing new behind it to refract — see `transportRow`, where the
            // container and the union were tried and what came back is on record. A wash is the
            // honest way to say "the pointer is here" on a surface that cannot change the cursor.
            .background(
                // A capsule rather than a circle: two of the five are narrower than they are tall,
                // and a circle inside those would be a wash smaller than the target it is drawn to
                // describe. At the three square ones a capsule *is* the circle.
                Capsule(style: .continuous).fill(
                    .white.opacity(
                        isEnabled && isHovered ? (model.increaseContrast ? 0.26 : 0.14) : 0
                    )
                )
            )
            // One view whose opacity animates rather than a view that comes and goes: a wash
            // inserted and removed at pointer speed is a transition per crossing.
            .animation(
                Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: model.reduceMotion),
                value: model.hoveredControl
            )
            // The press is a flex, not a size change — `nudge`, the token for the island
            // acknowledging something rather than becoming something, exactly as the padlock's own
            // press swell rides it.
            .scaleEffect(isEnabled && isHovered && model.isControlPressed ? 0.92 : 1)
            .animation(
                Motion.respectingReduceMotion(Motion.nudge, reduceMotion: model.reduceMotion),
                value: model.isControlPressed
            )
            .accessibilityElement()
            .accessibilityLabel(label(for: control))
    }

    /// The island's own transport keys, not a second set. `docs/LOCALIZATION.md`: one string per
    /// thing said, wherever it is said — five new keys for five controls that already have names is
    /// five chances for a translator to give the same button two words.
    private func label(for control: LockScreenTransportControl) -> String {
        switch control {
        case .toggleShuffle: islandText("nowPlaying.transport.shuffle", "Shuffle")
        case .previousTrack: islandText("nowPlaying.transport.previous", "Previous track")
        case .playPause:
            model.nowPlaying?.isPlaying == true
                ? islandText("nowPlaying.transport.pause", "Pause")
                : islandText("nowPlaying.transport.play", "Play")
        case .nextTrack: islandText("nowPlaying.transport.next", "Next track")
        case .toggleRepeat: islandText("nowPlaying.transport.repeat", "Repeat")
        }
    }

    // MARK: - Progress

    private var progressRow: some View {
        HStack(spacing: LockScreenCardLayout.timeLabelSpacing) {
            timeLabel(model.elapsedText(at: now), alignment: .leading)
            progressLine
            timeLabel(model.remainingText(at: now), alignment: .trailing)
        }
        .frame(width: LockScreenCardLayout.progressRowWidth)
    }

    private func timeLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            // Monospaced digits so the row does not shuffle sideways once a second, which would be
            // the only thing moving on the whole lock screen.
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .frame(width: LockScreenCardLayout.timeLabelWidth, alignment: alignment)
    }

    /// The playhead, and — since it can be seeked — a control.
    ///
    /// **It thickens under the pointer.** The old comment here said a readout must not look
    /// draggable, and that was right while nothing on this surface could be operated. This one can:
    /// a press on it seeks, so the line has to say so, and with no cursor to change the only thing
    /// it has to say it with is its own shape. Growing from `progressHeight` to
    /// `progressHoverHeight` inside a row sized to the taller of the line and the time labels
    /// costs no layout at all — nothing moves, the rule just gets heavier under the hand.
    private var progressLine: some View {
        let isActive = model.isProgressHovered || model.isScrubbing
        return GeometryReader { geometry in
            let filled = (model.progress(at: now) ?? 0) * geometry.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(model.increaseContrast ? 0.35 : 0.22))
                Capsule(style: .continuous)
                    .fill(.white.opacity(model.increaseContrast ? 1 : 0.85))
                    .frame(width: max(0, filled))
            }
        }
        .frame(
            height: isActive
                ? LockScreenCardLayout.progressHoverHeight
                : LockScreenCardLayout.progressHeight
        )
        // The same token the transport wash travels on: this is a content change inside a container
        // that is standing still, which is what `contentSwap` is for.
        .animation(
            Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: model.reduceMotion),
            value: isActive
        )
    }

    /// One label for the whole card: VoiceOver reading "artwork, title, artist, 1:04, -2:31" as five
    /// elements on a surface with nothing to navigate to is worse than one sentence.
    private var accessibilityLabel: String {
        let title = model.content?.title ?? ""
        let subtitle = model.content?.subtitle ?? ""
        return subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

/// The padlock hanging from the notch: the island, flanked, with the lock in the artwork's slot.
///
/// Its own view and its own panel because it is placed against the hardware cutout rather than
/// against the display, and because it is drawn whenever the Mac is locked — with or without music.
/// The first build gated the whole lock-screen surface on there being a track, which is why a silent
/// Mac showed nothing at all.
public struct LockScreenNotchView: View {

    @Bindable var model: LockScreenCardModel

    public init(model: LockScreenCardModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if model.isOnScreen {
                shape
                    // **Neither the way in nor the way out is a transition's job to invent.**
                    // Both are `reentry`, below: the island's own re-entry spring — `Motion.nudge`
                    // from a third of its size, exactly as the island bounces its artwork and
                    // equaliser back after a lock — played forwards at the lock and backwards at
                    // the unlock (`playArrival` / `playDeparture`). By the time this branch goes
                    // the shape is already at zero, so `.identity` is the honest transition.
                    .transition(.identity)
                    // Sideways only, like the island's own re-entry (`IslandRootView`): the
                    // flanks spring out of the cutout to the left and right, and the height —
                    // the cutout's own — never moves.
                    .scaleEffect(x: model.arrivalScale, y: 1, anchor: .top)
                    .opacity(model.arrivalOpacity)
            }
        }
        // Laid out at the **panel's** size — the peeked island — with the shape top-aligned inside
        // it, so growing on hover never resizes the window. `LockScreenPanel`'s frame never
        // animates, for `IslandPanel`'s reason: animating `NSWindow.setFrame` tears.
        .frame(
            width: model.notchPanelSize.width,
            height: model.notchPanelSize.height,
            alignment: .top
        )
        // Width, height and both corner radii travel on **one spring instance**, which is §6.1's
        // rule and the whole reason the island's morphs read as one object rather than two
        // animations. `isHovered` is the single value they all derive from.
        .animation(
            Motion.respectingReduceMotion(Motion.expand, reduceMotion: model.reduceMotion),
            value: model.isHovered
        )
        // The press is a *flex*, not a size change, so it rides `nudge` — the token for the island
        // acknowledging something rather than becoming something. Scale rather than metrics for the
        // same reason: a fourth entry in the shape table would make the press a state the island can
        // be in, and it is an event it responds to.
        .scaleEffect(model.pressScale, anchor: .top)
        .animation(
            Motion.respectingReduceMotion(Motion.nudge, reduceMotion: model.reduceMotion),
            value: model.isPressed
        )
        .background(pointerClock)
    }

    /// Samples the pointer on the display link the surface is already entitled to.
    ///
    /// There is no `NSTrackingArea` here and there cannot be: our panel receives no events on a
    /// locked screen. `NSEvent.mouseLocation` is a global query rather than an event, and it was
    /// measured moving behind the shield before this was built. Zero-sized, and never given
    /// `.allowsHitTesting(false)` — see `ActivityClock.DisplayLinkView`.
    ///
    /// **One sampler for both surfaces.** The card's transport buttons are hit-tested from the same
    /// two queries — they are two panels but one `LockScreenCardModel`, so what this writes the card
    /// redraws from. A second display link in `LockScreenCardView` asking the window server the same
    /// question thirty times a second would be a second clock on the one path §9 says must have
    /// none.
    @ViewBuilder
    private var pointerClock: some View {
        ActivityClock(rate: model.pointerRate) { instant in
            let location = NSEvent.mouseLocation
            // Hover for all three regions from one sample — the padlock, a transport button, the
            // progress line. What this drives is the drawing: the lit button, the widened line, the
            // peeked padlock.
            //
            // **There is no haptic on any of this, and there used to be one on each.** A tick fired
            // on every crossing and on both press edges, which is §7's vocabulary applied to a
            // surface that is not the island: on a locked screen the user is looking straight at
            // the thing they are pointing at, and the lit button already says it is live. Three
            // buzzes for one glance at a track title is the feature announcing itself, which is
            // what the brief rules out.
            model.updatePointer(location)
            let isDown = NSEvent.pressedMouseButtons != 0
            // `pressedMouseButtons` is a global query, not an event — see `isPressed`. The island
            // cannot act on the click; the swell under the press is the acknowledgement, and it is
            // what tells the user the Mac is locked rather than hung.
            model.updatePressed(isDown)
            // The card's own press, which *can* act: a transport command on the way down, or a
            // scrub that begins here, follows the pointer on the samples between, and commits its
            // seek on the release. The model does the sending because it holds the player.
            model.updateCardPress(isDown, at: location, now: instant)
        }
    }

    /// Pure `#000000`, no material, no blur — §6.4, because this hangs from the bezel and has to be
    /// optically continuous with it. Exactly the island's own rule, for exactly the island's reason.
    ///
    /// Drawn with **`IslandShape`**, the island's own path, not a `RoundedRectangle`. That is what
    /// carries `topFlareRadius` — the outward curve where the shape meets the bezel — and it is the
    /// difference between the cutout appearing to widen and a pill being stuck underneath it. A
    /// rounded rectangle shipped once and read as the latter.
    private var shape: some View {
        HStack(spacing: 0) {
            padlock
                .frame(width: IslandLayout.flankedFlankWidth)
            Spacer(minLength: 0)
        }
        .frame(width: model.notchSize.width, height: model.notchSize.height)
        .background(IslandShape(metrics: model.notchMetrics).fill(.black))
        .accessibilityElement()
        .accessibilityLabel(model.lockedAccessibilityLabel)
    }

    /// `lock.fill` and `lock.open.fill` are the same glyph with the shackle in two positions, so
    /// SwiftUI's own symbol replacement swings the shackle rather than cross-fading two pictures.
    /// **No Lottie**: §6.5 allows SF Pro and SF Symbols only, and §9 measures SwiftUI per-frame
    /// drawing at ~18% of a core against ~0.008% in CoreAnimation — the wrong trade twice over on a
    /// surface shown to an empty room.
    private var padlock: some View {
        Image(systemName: model.isUnlocking ? "lock.open.fill" : "lock.fill")
            .font(.system(size: LockScreenNotchLayout.glyphPointSize, weight: .medium))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
    }
}
