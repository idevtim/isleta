import AppKit
import CoreGraphics
import Foundation
import IslandActivities
import SwiftUI

/// Draws one slot of the Now Playing activity.
///
/// The single exception to "every activity renders through `ActivityContentView`", and the exception
/// IslandActivities' README names in advance: *"A bespoke view belongs in IslandUI keyed on
/// `ActivityKind`, never as an `AnyView` smuggled through IslandActivities."* This is that view, and
/// the key is `ActivityKind.nowPlaying`.
///
/// What is bespoke about it is only the drawing. Everything it needs still arrives as
/// `ActivityContent` — the title and subtitle are strings in the content, the playhead is the
/// content's `.timeline` value — which is what keeps `ActivitySlotLayout` deciding where it can go
/// and `ActivitySlotLayout.needsClock` deciding whether anything redraws, with no case for music in
/// either. The three things that genuinely cannot be content come from `NowPlayingController`: the
/// cover image, whether the player permits skipping, and the way back to it.
///
/// Falls back to `ActivityContentView` for anything it has no bespoke treatment for. A Now Playing
/// activity from the scripting route carries no timeline and gets no transport, and it must still
/// render as a perfectly ordinary activity rather than as an empty music card.
struct NowPlayingSlotView: View {

    let content: ActivityContent
    let slot: ActivitySlot
    let controller: NowPlayingController
    let increaseContrast: Bool
    let reduceMotion: Bool
    let now: Date
    let namespace: Namespace.ID?

    /// Where the player application's icon comes from, for a track with no cover. The same store
    /// every other slot draws an app icon from — one cache of eight rasters for the whole island,
    /// rather than a second one that would evict the first one's entries.
    let icons: ApplicationIconStore

    var body: some View {
        switch slot {
        case .leading:
            leadingFlank
        case .trailing:
            trailingFlank
        case .compact:
            // No bespoke treatment: the compact badge is the single slot on an island with no
            // flanks — a synthesized one — and there is nothing music-specific to say in it that a
            // glyph and a title do not already say.
            generic
        case .expanded:
            expanded
        }
    }

    /// The accent for this track's chrome: the cover's, where the user has asked for it and the
    /// cover gave one, and the activity's own palette color otherwise. See
    /// `NowPlayingController.accent(_:increaseContrast:)` for what it reaches and what it must not.
    private var tint: Color {
        controller.accent(
            ActivityPalette.color(for: content.tint, increaseContrast: increaseContrast),
            increaseContrast: increaseContrast
        )
    }

    /// Whether the cover should draw back.
    ///
    /// **`isTransportAvailable`, not `timeline != nil`.** The first version asked whether *this
    /// slot's content* carried a timeline, on the theory that a route which cannot report position
    /// cannot report play state either — and it was wrong in the one slot the feature is for.
    /// `ActivityStage.content(for:)` hands each sliver its **own** `ActivityContent`, and
    /// `BuiltInActivity.nowPlaying` deliberately puts the timeline in the *trailing* flank alone
    /// (that is what makes `ActivitySlotLayout.needsClock` run the display link for the equaliser
    /// and nothing else). The leading flank's content is a bare `music.note`, so the gate was false
    /// on every collapsed island and the cover never drew back at all — while the equaliser two
    /// slivers away, reading the same `controller.isPlaying`, sank to its dots correctly.
    ///
    /// `isTransportAvailable` is the honest form of what was meant: there is a route to the player,
    /// so what it says about playing or paused is a fact rather than an uninitialized `false`. Every
    /// route that reports one reports the other — `BuiltInActivity.nowPlaying` takes `isPlaying`
    /// even from the scripting fallback, which is what draws its `pause.fill` glyph.
    private var isPaused: Bool {
        Self.coverIsPaused(
            isTransportAvailable: controller.isTransportAvailable,
            isPlaying: controller.isPlaying
        )
    }

    /// The rule above, as a function of the two facts it is allowed to depend on — and pinned by a
    /// test, because the version that shipped for an hour depended on a third one it should not
    /// have and was silently false in the only slot that draws a cover on a resting island.
    static func coverIsPaused(isTransportAvailable: Bool, isPlaying: Bool) -> Bool {
        isTransportAvailable && !isPlaying
    }

    /// The player's icon, for a track that has no cover.
    ///
    /// Asked only when there is no artwork: resolving an icon that is about to be covered by a
    /// sleeve is a disk read for something nobody will see, and the store would keep it in a cache
    /// of eight for an app whose icon this island is never going to draw.
    private var applicationIcon: CGImage? {
        guard controller.artwork == nil, let identifier = controller.playerBundleIdentifier else {
            return nil
        }
        return icons.icon(forBundleIdentifier: identifier)
    }

    /// White at an opacity, in sRGB.
    ///
    /// Spelled out rather than `NSColor.white.withAlphaComponent(_:)` for §6.4's reason, which
    /// applies to a `CALayer`'s colour exactly as it does to the island's black: a catalog colour
    /// can resolve to an appearance-sensitive variant and shift by a shade, and these two lines sit
    /// on `#000000` in a notch.
    static func lineColor(opacity: CGFloat) -> NSColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: opacity)
    }

    private var secondaryOpacity: Double {
        ActivityPalette.secondaryOpacity(increaseContrast: increaseContrast)
    }

    /// The timeline actually on screen: what the player reports, unless the user is dragging it or
    /// has just let go. One call, one answer, used by the bar and the numerals alike.
    private var timeline: ActivityTimeline? {
        guard case .timeline(let reported)? = content.value else {
            return controller.timeline(reportedBy: nil, at: now)
        }
        return controller.timeline(reportedBy: reported, at: now)
    }

    private var generic: some View {
        ActivityContentView(
            content: content,
            slot: slot,
            increaseContrast: increaseContrast,
            reduceMotion: reduceMotion,
            now: now,
            namespace: namespace
        )
    }

    // MARK: - Flanks

    /// The album cover, hugging the island's outer edge.
    ///
    /// Aligned outward for the same reason every flank is (`ActivityContentView.flank`): centerd in
    /// the sliver reads fine at 40pt and wrong at the ~98pt the flanks reach when the island opens,
    /// where a centerd square floats with the cutout half a flank away.
    ///
    /// 24pt, which is 4pt of breathing room top and bottom inside the 32pt flank. Bigger touches the
    /// island's edge, and a bright square touching the edge of a black shape on a black bezel reads
    /// as a rendering fault rather than as content.
    private var leadingFlank: some View {
        HStack(spacing: 0) {
            NowPlayingArtworkView(
                image: controller.artwork,
                fallbackSymbol: content.symbol ?? "music.note",
                side: 24,
                tint: tint,
                increaseContrast: increaseContrast,
                applicationIcon: applicationIcon,
                isPaused: isPaused,
                reduceMotion: reduceMotion
            )
            // **The pointer on this sleeve grows the track lip, and this view has nothing to do
            // with noticing that.** It was a `PointerPresence` overlay here for an afternoon, and
            // it failed in the one gesture the feature is for: a nested tracking area is told only
            // about crossings of its own rect, so arriving from outside the island worked and
            // sliding across from the middle of the notch did nothing. The pointer's *position* is
            // the honest question, it is asked of the island's own move events, and the answer is
            // `IslandScreenModel.isPointOnAlbumArtwork` — which also means the rule is geometry a
            // test can ask about rather than an event a test cannot deliver.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(content.accessibilityLabel ?? islandText("nowPlaying.a11y", "Now playing"))
    }

    /// The equaliser, or the glyph for a route that cannot say whether anything is moving.
    ///
    /// The bars are also the collapsed island's play/pause — see `NowPlayingEqualiserControl`, which
    /// is what makes the press stop at the sliver instead of opening the island. That is deliberately
    /// *only* here: the open island draws a full transport row a few points away, and a second play
    /// button hidden under an indicator beside a visible one is a control the user has to discover in
    /// order to be confused by.
    private var trailingFlank: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if timeline != nil {
                // No `position` and no `now`: the equaliser drives its own clock so that ticking it
                // does not invalidate the rest of the island. See its doc comment for the two
                // measurements that forced that.
                NowPlayingEqualiserControl(
                    controller: controller,
                    reduceMotion: reduceMotion,
                    increaseContrast: increaseContrast,
                    colors: controller.barColors(increaseContrast: increaseContrast)
                )
            } else {
                generic
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **Not** `accessibilityHidden(true)` any more. It was correct while the flank was six
        // decorative bars restating the play glyph on the other side of the cutout; it would now
        // hide the only transport control a collapsed island offers.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Expanded

    /// The open island: what is playing, where it is, and the controls.
    ///
    /// Three rows, following the reference the owner supplied for the expanded player:
    ///
    /// 1. the cover, the title block, and the equaliser at the trailing edge;
    /// 2. elapsed, the scrub bar, and the **remaining** time as a negative;
    /// 3. previous, play/pause, next — centerd, in white.
    ///
    /// The times sit either side of the bar rather than at the ends of the transport row. That is
    /// what the reference does, and it is also what buys the transport row the room to hold three
    /// large glyphs centerd on the island instead of three small ones squeezed between two labels.
    ///
    /// The body region below the cutout is 108pt and all three rows have to fit inside it —
    /// `NowPlayingExpandedLayout.fits(in:)` asserts that against real hardware geometry rather than
    /// trusting the arithmetic, because a row that does not fit is not merely ugly: it is clipped by
    /// the mask in `IslandRootView`, so a button can be visibly shaved and invisibly unhittable.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Two equal spacers, matching `NowPlayingExpandedLayout.scrubberRect`, which centers the
            // bar in the same gap. The layout and the view have to agree about where the bar is:
            // that rect is what a drag is measured against, so a bar drawn anywhere else is a bar
            // that seeks from somewhere the pointer is not.
            Spacer(minLength: 0)

            if let timeline, timeline.duration > 0 {
                scrubberRow(timeline)
            }

            Spacer(minLength: 0)

            transportRow
        }
        .padding(.horizontal, NowPlayingExpandedLayout.horizontalPadding)
        .padding(.top, NowPlayingExpandedLayout.topPadding)
        .padding(.bottom, NowPlayingExpandedLayout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Cover, title block, equaliser.
    private var header: some View {
        HStack(alignment: .center, spacing: NowPlayingExpandedLayout.headerSpacing) {
            // The cover and the title open the player.
            //
            // A `Button` rather than a tap gesture, for the reason the transport row already relies
            // on: a button consumes the press, and an unconsumed one travels back up the responder
            // chain to `IslandHitTestView.mouseDown` and collapses the island — so tapping the
            // artwork would launch Music *and* shut the island in the same click.
            //
            // Only attached when there is somewhere to go. A tap target that does nothing teaches
            // the user the island is unresponsive, which is worse than no target at all.
            if controller.canOpenPlayer {
                Button {
                    controller.openPlayer()
                } label: {
                    // The whole row is the target, gaps included — a region covering only the glyphs
                    // and the glyph-shaped parts of the text would have edges the eye cannot find.
                    // Applied *here* and not on the label itself: in the branch below there is no
                    // button, and a content shape with no gesture behind it still claims the press
                    // from the island underneath.
                    openPlayerLabel.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openPlayerAccessibilityLabel)
            } else {
                // **Not** a disabled button. A disabled `Button` still swallows the click — it
                // simply does not act on it — so with no player to open, pressing the artwork would
                // do nothing *and* stop the press reaching `IslandHitTestView.mouseDown`, which is
                // what closes the island. The island would sit open under a click that appeared to
                // be ignored. Caught by `--transport-test`, which presses a point it expects to be
                // inert and found the island still expanded.
                openPlayerLabel
            }

            // The same indicator the collapsed island flanks the cutout with, at the trailing edge
            // of the header. It keeps driving its own clock here — see `NowPlayingEqualiserView`.
            NowPlayingEqualiserView(
                isPlaying: controller.isPlaying,
                reduceMotion: reduceMotion,
                colors: controller.barColors(increaseContrast: increaseContrast)
            )
        }
        .frame(height: NowPlayingExpandedLayout.headerRowHeight)
    }

    /// The cover and the two lines beside it, which together are one target.
    private var openPlayerLabel: some View {
        HStack(alignment: .center, spacing: NowPlayingExpandedLayout.headerSpacing) {
            NowPlayingArtworkView(
                image: controller.artwork,
                fallbackSymbol: content.symbol ?? "music.note",
                side: NowPlayingExpandedLayout.artworkSide,
                tint: tint,
                increaseContrast: increaseContrast,
                applicationIcon: applicationIcon,
                isPaused: isPaused,
                reduceMotion: reduceMotion
            )

            VStack(alignment: .leading, spacing: NowPlayingExpandedLayout.titleBlockSpacing) {
                if let title = content.title {
                    // **It scrolls rather than truncating.** The column is ~230pt and a track title
                    // is whatever the record says it is, so the tail truncation this used to do lost
                    // the end of a great many perfectly ordinary songs — and the end is often the
                    // half that distinguishes one version of a track from another.
                    //
                    // `MarqueeText` holds still for `MarqueeMetrics.hold` at the start of every cycle,
                    // which is what makes it readable rather than merely complete: a line that
                    // never stops moving is one whose opening words are only ever legible in the
                    // first second of the track. It sits still outright for a title that fits,
                    // which is most of them, and under Reduce Motion.
                    MarqueeText(
                        text: title,
                        // Heavier than the artist by a clear margin, as the reference shows — the
                        // title is what the glance is for.
                        font: .systemFont(ofSize: 15, weight: .bold),
                        color: Self.lineColor(opacity: 1),
                        reduceMotion: reduceMotion,
                        alignment: .leading
                    )
                    .frame(height: NowPlayingExpandedLayout.titleLineHeight)
                }
                subtitleLine
                formatLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole header is one `Button` carrying `openPlayerAccessibilityLabel`, which
            // already speaks the title and the artist. A label inside a button's own label is not
            // reached, and two layer-backed lines would otherwise arrive as elements with no
            // description at all.
            .accessibilityHidden(true)
        }
    }

    /// What the audio actually is: a waveform and a word, under the artist.
    ///
    /// **Empty for anything streamed, and that is the design rather than a gap.** Apple Music draws
    /// its own Lossless badge from state it does not publish: MediaRemote carries no codec key, and
    /// Music's scripting answers `kind: ""` for a `URL track`. `AudioFormat` has the measurement,
    /// and the reason a badge is not inferred from the user's Lossless *setting* instead — that
    /// would be the island naming a format it has no way of knowing this track was delivered in.
    ///
    /// **The line takes no room when there is no badge**, which was the second thing tuned about it.
    /// It first reserved its height either way, so that a playlist crossing between a track whose
    /// format is known and one whose is not would not walk the title and the artist about — and on a
    /// library where the format is *usually* unknown that meant an empty 15pt strip under the artist
    /// and two lines pushed off the centre of the cover for a third that never arrived. The movement
    /// it was avoiding is the smaller problem. See `NowPlayingExpandedLayout.titleBlockHeight`.
    ///
    /// A plain `Text` and not `MarqueeText`: the two lines above scroll because a title and an
    /// artist are whatever the record says they are, and this is one word from a closed set.
    ///
    /// **Apple's own badge is drawn where Apple has one.** `AudioFormatBadge` reads it out of
    /// Music's bundle at runtime, which is why there is no artwork in this repository and no
    /// trademark in the app bundle.
    @ViewBuilder
    private var formatLine: some View {
        if let format = controller.audioFormat {
            Group {
                // **Apple's own badge where Apple has one**, borrowed from Music at runtime rather
                // than shipped — see `AudioFormatBadge` for why a copy is a different act from a
                // reference. Each of these already contains its own words, so nothing is drawn
                // beside it: "Lossless" is 60pt of mark *and* word.
                if let badge = AudioFormatBadge.image(for: format.kind) {
                    // **Drawn at its own size, not resized to the line.** The badges are not one
                    // height — 18pt for Lossless and Hi-Res, 14 for Atmos — and that difference is
                    // Apple's, made deliberately so they sit together on a baseline. Forcing them
                    // all to one number scales two of the three, and scaling a wordmark is how a
                    // trademark ends up soft or, worse, subtly the wrong proportions.
                    //
                    // So the *line* is sized to the tallest of them (`formatLineHeight`) and each
                    // badge is left alone inside it. No `.resizable()`, and that omission is the
                    // whole of the fix.
                    Image(nsImage: badge)
                        .renderingMode(.template)
                } else {
                    // Isleta's own, for the kinds Apple has no badge for and for a Mac with no
                    // Music on it. §8: a fallback that is a real feature rather than an apology.
                    HStack(spacing: 4) {
                        Image(systemName: format.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(format.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            // Dimmer than the artist, which is already dimmer than the title. Three lines in
            // one block need three weights or they read as a paragraph, and this is the least
            // of the three: it is a fact about the file rather than about the music.
            .foregroundStyle(.white.opacity(increaseContrast ? 0.75 : 0.45))
            .frame(height: NowPlayingExpandedLayout.formatLineHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The badge arrives one `osascript` after the track does, so it appears *into* a block
            // that is already on screen — `Motion.contentSwap` is §6.2's "same activity, new
            // content", and the curve the title beside it crossfades on when the track changes.
            .animation(
                Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion),
                value: controller.audioFormat
            )
        }
    }

    /// The artist, or — for the last ten seconds of the track — what plays next.
    ///
    /// It takes the artist's line rather than adding a row, and that is a layout decision with a
    /// hit-testing consequence behind it. The open island's body is 108pt with three rows already
    /// measured into it (`NowPlayingExpandedLayout`), and `islandPath` tracks a **settled** shape:
    /// a fourth row would move the island's bottom edge — and the region clicks are accepted in —
    /// ten seconds before the end of every song, under a pointer that may be on the transport row.
    /// Swapping one line for another costs nothing and moves nothing.
    ///
    /// The artist is the right line to spend, too. It is the field the peek is replacing for ten
    /// seconds and then handing straight back, and a listener who wanted to know who this was has
    /// had the whole song to read it.
    ///
    /// **The next track's artist is deliberately not drawn.** The column is ~230pt at 12pt, which is
    /// a title and not much else, and a peek that truncates mid-title to make room for a name is a
    /// peek that failed at the one thing it is for. It is carried on the controller, because the
    /// row a later milestone draws will have room for it.
    @ViewBuilder
    private var subtitleLine: some View {
        Group {
            if let upNext = upNextTitle {
                HStack(spacing: 4) {
                    // Small, and the same glyph as the Next button two rows below — the peek is
                    // saying what that button would go to.
                    Image(systemName: "forward.end.alt.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(islandText("nowPlaying.upNext", "Up Next"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(upNext)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.white.opacity(increaseContrast ? 0.85 : 0.6))
            } else if let subtitle = content.subtitle {
                // The artist scrolls on the same terms as the title above it, and for a reason of
                // its own: this line is "artist — album" joined, so it is the *longer* of the two
                // more often than not.
                MarqueeText(
                    text: subtitle,
                    font: .systemFont(ofSize: 12, weight: .regular),
                    color: Self.lineColor(opacity: increaseContrast ? 0.85 : 0.6),
                    reduceMotion: reduceMotion,
                    alignment: .leading
                )
                .frame(height: NowPlayingExpandedLayout.artistLineHeight)
            }
        }
        // The one place in the island where an animation is driven by the *clock* rather than by
        // something arriving. `isDue` flips on a display-link tick, outside any transaction, so
        // without this the line would snap — and `Motion.contentSwap` is the right token because
        // this is §6.2's "same activity, new content" exactly: it is the curve the title beside it
        // crossfades on when the track changes.
        .animation(
            Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion),
            value: upNextTitle
        )
    }

    /// The next track's title, but only while the peek is due.
    ///
    /// Nil is what the view branches on, so the "do we know one" and "should it be on screen"
    /// questions collapse into one optional rather than a flag and a string that can disagree.
    /// `timeline` here is the **resolved** one, so a drag pins the rate to zero and
    /// `NowPlayingUpNextPeek` withholds the peek for the length of the scrub without knowing that
    /// scrubbing exists.
    private var upNextTitle: String? {
        guard let title = controller.upNextTitle,
              NowPlayingUpNextPeek.isDue(timeline: timeline, at: now)
        else { return nil }
        return title
    }

    private var openPlayerAccessibilityLabel: String {
        // The peek is spoken here rather than as its own element, because the whole header is one
        // `Button` and a label inside a button's own label is not reached. It is appended rather
        // than substituted: a sighted user still has the title and the cover in front of them, and
        // dropping the track's name for ten seconds would leave VoiceOver describing a control by
        // what it is *not* about.
        // Each of the three sentences is one key with the track and the artist as arguments, so a
        // translator can put them where the language wants them — this is the most word-order
        // fragile string in the package, and "Open X by Y in the player" is English's order and
        // nobody else's.
        let peek = upNextTitle.map {
            islandText("nowPlaying.a11y.upNextPeek", ". Up next, \($0)")
        } ?? ""
        guard let title = content.title else {
            return islandText("nowPlaying.a11y.openPlayer", "Open the player") + peek
        }
        guard let artist = content.subtitle else {
            return islandText("nowPlaying.a11y.openTrack", "Open \(title) in the player") + peek
        }
        return islandText(
            "nowPlaying.a11y.openTrackByArtist",
            "Open \(title) by \(artist) in the player"
        ) + peek
    }

    /// Elapsed, the bar, and the remaining time as a negative.
    private func scrubberRow(_ timeline: ActivityTimeline) -> some View {
        HStack(spacing: NowPlayingExpandedLayout.timeLabelSpacing) {
            timeLabel(elapsedText(timeline), alignment: .leading)
            scrubber(timeline)
            timeLabel(remainingText(timeline), alignment: .trailing)
        }
        .frame(height: NowPlayingExpandedLayout.scrubberRowHeight)
    }

    /// Previous, play/pause, next — centerd, with nothing else on the row.
    @ViewBuilder
    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if controller.isTransportAvailable {
                NowPlayingTransportView(
                    isPlaying: controller.isPlaying,
                    canSkip: controller.canSkip,
                    // White, matching the reference and the equaliser. The activity tint is for
                    // content that means something by its color; a transport glyph does not.
                    color: .white,
                    increaseContrast: increaseContrast,
                    isShuffling: controller.isShuffling,
                    repeatMode: controller.repeatMode,
                    canChangeQueueBehavior: controller.canChangeQueueBehavior,
                    canFavorite: controller.canFavorite,
                    isFavorite: controller.isFavorite,
                    canSkipBackFifteen: controller.canSkipBackFifteen,
                    canSkipForwardFifteen: controller.canSkipForwardFifteen,
                    canReadQueue: controller.canReadQueue,
                    isShowingQueue: controller.isShowingQueue,
                    action: { controller.send($0) }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(height: NowPlayingExpandedLayout.transportRowHeight)
    }

    private func scrubber(_ timeline: ActivityTimeline) -> some View {
        NowPlayingScrubberView(
            fraction: timeline.fraction(at: now) ?? 0,
            // White for the played portion, matching the reference; the unplayed track behind it is
            // drawn from the same color at low opacity inside the view. With album color on it is
            // the cover's accent instead — the played portion is the one piece of Now Playing chrome
            // where every other player on the platform expects the record's own color.
            color: controller.accent(.white, increaseContrast: increaseContrast),
            increaseContrast: increaseContrast,
            isScrubbing: controller.isScrubbing,
            onBegin: { fraction in
                controller.beginScrub(from: timeline, toFraction: fraction, at: now)
            },
            onChange: { fraction in
                controller.updateScrub(toFraction: fraction)
            },
            onEnd: {
                // `reportedBy` is the *player's* timeline rather than the resolved one, so the
                // optimistic value that replaces it inherits the real playback rate. Handing it the
                // dragged timeline instead would inherit that timeline's pinned zero and leave the
                // playhead standing still for the settle window on a track that is playing.
                controller.endScrub(reportedBy: reportedTimeline, at: Date())
            }
        )
        .accessibilityLabel(islandText("nowPlaying.scrubber.a11y", "Playback position"))
        .accessibilityValue(ActivityValueFormatter.clock(seconds: timeline.position(at: now)))
    }

    /// The player's own timeline, before the controller resolves a drag or a pending seek over it.
    private var reportedTimeline: ActivityTimeline? {
        guard case .timeline(let reported)? = content.value else { return nil }
        return reported
    }

    @ViewBuilder
    private func transportRow(_ timeline: ActivityTimeline?) -> some View {
        HStack(spacing: 0) {
            timeLabel(elapsedText(timeline), alignment: .leading)
            Spacer(minLength: 0)
            if controller.isTransportAvailable {
                NowPlayingTransportView(
                    isPlaying: controller.isPlaying,
                    canSkip: controller.canSkip,
                    color: tint,
                    increaseContrast: increaseContrast,
                    isShuffling: controller.isShuffling,
                    repeatMode: controller.repeatMode,
                    canChangeQueueBehavior: controller.canChangeQueueBehavior,
                    canFavorite: controller.canFavorite,
                    isFavorite: controller.isFavorite,
                    canSkipBackFifteen: controller.canSkipBackFifteen,
                    canSkipForwardFifteen: controller.canSkipForwardFifteen,
                    canReadQueue: controller.canReadQueue,
                    isShowingQueue: controller.isShowingQueue,
                    action: { controller.send($0) }
                )
            }
            Spacer(minLength: 0)
            timeLabel(remainingText(timeline), alignment: .trailing)
        }
        .frame(height: NowPlayingExpandedLayout.transportRowHeight)
    }

    /// A fixed-width slot for a time, so the transport buttons stay centerd on the island rather
    /// than sliding sideways as a track crosses from "9:59" to "10:00".
    private func timeLabel(_ text: String?, alignment: Alignment) -> some View {
        Text(text ?? "")
            // `.rounded` and monospaced digits for numerals being read as a quantity (§6.5) — the
            // even-width digits are what stop a counting number from looking like it is flickering.
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            // Gray, not the activity tint — the reference's times and bar are neutral, and a tinted
            // numeral reads as a value that means something by its color, which a clock does not.
            .foregroundStyle(.white.opacity(increaseContrast ? 0.9 : 0.55))
            .frame(width: NowPlayingExpandedLayout.timeLabelWidth, alignment: alignment)
            .accessibilityHidden(true)
    }

    private func elapsedText(_ timeline: ActivityTimeline?) -> String? {
        guard let timeline, timeline.duration > 0 else { return nil }
        return ActivityValueFormatter.clock(seconds: timeline.position(at: now))
    }

    /// Counts down, with the minus sign every player uses. Not the track's total: the number a
    /// listener wants from a glance at a playing track is how much is left.
    private func remainingText(_ timeline: ActivityTimeline?) -> String? {
        guard let timeline, timeline.duration > 0 else { return nil }
        let remaining = timeline.duration - timeline.position(at: now)
        return "-" + ActivityValueFormatter.clock(seconds: remaining)
    }
}
