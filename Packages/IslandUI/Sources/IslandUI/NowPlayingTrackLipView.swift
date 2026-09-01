import IslandActivities
import IslandKit
import SwiftUI

/// Fixed sizes for the lip that says what is playing.
///
/// Its own type, like every other surface the island draws, so the height the *shape* grows by
/// (`IslandLayout.trackLipHeight`) and the rows drawn inside it are one piece of arithmetic rather
/// than two that agree until somebody edits one. `TrackLipTests` asserts the rows fit.
public enum NowPlayingTrackLipLayout {

    /// Clear air at each end of the strip.
    ///
    /// 14, not the flanks' 8: the cover and the equaliser are hard against the island's outer edge
    /// by design, and text is not — a title starting where a 24pt sleeve starts would read as the
    /// second line of the cover rather than as a caption under the notch.
    public static let horizontalPadding: CGFloat = 14

    public static let topPadding: CGFloat = 3
    public static let bottomPadding: CGFloat = 3

    /// 14 over 12, up from 12 over 10.
    ///
    /// Bigger than the open island's own subtitle (12) and one step under its title (15), which is
    /// the right way round: the open island has a cover, a scrubber and a transport row to carry
    /// the hierarchy, and the lip has two lines and 40pt. It is also read from further away than
    /// anything else on the island — the pointer is on a 24pt sleeve in a notch, and the eye is on
    /// whatever the user was actually working in.
    public static let titleFontSize: CGFloat = 14
    public static let artistFontSize: CGFloat = 12

    /// The room a line of each font actually takes, measured rather than assumed — SF Pro's line
    /// height is not its point size, and a strip sized to the point size clips the descenders on
    /// the one word in a title most likely to have one.
    public static let titleLineHeight: CGFloat = 17
    /// **18, up from 15, and the extra three points are Apple's badge rather than air.** This row
    /// carries the audio badge at its trailing edge (see `NowPlayingTrackLipView.lines`), and those
    /// are 18pt tall and not ours to shrink.
    ///
    /// A *constant* three points, on every track, which is the entire reason the badge went on this
    /// row instead of getting one of its own. A third row would have made the lip 40pt tall for a
    /// track whose format is unknown and 60 for the next one — and this strip appears because a
    /// pointer is resting on the album cover, so that is the island's bottom edge moving under a
    /// stationary pointer, once per song. `islandPath` tracks a settled shape; a shape that settles
    /// somewhere different per track is not one.
    public static let artistLineHeight: CGFloat = 18

    /// How far the fade at each end reaches, in points.
    ///
    /// **Points rather than a fraction of the width**, which is what it was: the gradient ran to 5%
    /// of the line, so the ramp was a different size on every island width and there was no number
    /// the text could be insetted by to clear it. Fixed, `marqueeInset` can be stated against it.
    public static let edgeFadeWidth: CGFloat = 12

    /// Where a scrolling line starts, measured from the leading edge.
    ///
    /// **Two points clear of the fade, deliberately.** A travelling line used to start at x=0, which
    /// is the bottom of the ramp, so the first character of a long artist was drawn at partial
    /// opacity — it read as missing, and the leading edge is the one a reader starts at. Landing it
    /// just past the ramp is what makes the line begin rather than emerge.
    ///
    /// The fade stays at both ends. It is not decoration: the line scrolls, and text arriving and
    /// leaving at a hard cut reads as clipped. What changed is where the line *starts*, not whether
    /// it fades on the way past.
    public static var marqueeInset: CGFloat { edgeFadeWidth + 2 }

    public static let lineSpacing: CGFloat = 1

    /// What the two rows and their padding come to. Compared against
    /// `IslandLayout.trackLipHeight` by a test, which is the only thing that keeps the two honest.
    public static var contentHeight: CGFloat {
        topPadding + titleLineHeight + lineSpacing + artistLineHeight + bottomPadding
    }

    /// How wide a line of text has, given the island's body.
    public static func textWidth(bodyWidth: CGFloat) -> CGFloat {
        max(0, bodyWidth - horizontalPadding * 2)
    }
}

/// The strip of island that springs out under the cutout while the pointer is on the album cover.
///
/// ## Why it exists
///
/// The collapsed island says a track is playing — a sleeve on one side of the notch and an
/// equaliser on the other — and deliberately does not say *which* track: there is no room beside a
/// 185pt hole for a title, and `IslandLayout.flankedHeightGrowth` is zero so there is none below it
/// either. That leaves "what is this?" answerable only by opening the island, which is a click and
/// a 380pt panel over whatever the user is working in, to read two lines of text.
///
/// So the pointer arriving on the cover asks the question and the lip answers it: title, artist,
/// gone again when the pointer leaves. It is the smallest possible version of opening the island,
/// and it costs no click.
///
/// ## Where it is drawn
///
/// In the body region — everything below the cutout, which exists *only* while the lip is out (see
/// `IslandForm.showsTrackLip`). `ActivityLayerView` gives the region up while this is on screen,
/// because a body slot and this in one rectangle is not a layered effect, it is text on text.
///
/// Laid out against `contentMetrics` like every other surface, never `metrics`: the content lags
/// the container by `Motion.contentFollowDelay` (§6.2), so the text arrives *into* a strip that has
/// already grown rather than being drawn 40ms ahead of the island it is in.
///
/// ## Motion
///
/// None of its own. The island growing is `Motion.reveal`, opened by
/// `IslandScreenModel.setHoveringArtwork`, and this view is inside that transaction and inherits
/// it. The one thing that moves independently is the two lines' scroll, which is `MarqueeText` and is
/// CoreAnimation for §9's reason.
struct NowPlayingTrackLipView: View {

    let model: IslandScreenModel

    /// The two strings, resolved by the model — see `IslandScreenModel.trackLipContent`, which is
    /// also what the island's *shape* is gated on so the strip can never be grown and left empty.
    ///
    /// `ActivityContent` and not `NowPlayingController` state, for the reason `NowPlayingSlotView`
    /// states about the same two fields: the scripting fallback publishes a title and an artist and
    /// has no transport at all, so a lip drawn from the controller would be blank on that route.
    let content: ActivityContent

    let increaseContrast: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)
            let bodyHeight = max(0, metrics.bodySize.height - model.cutoutSize.height)

            lines
                .padding(.horizontal, NowPlayingTrackLipLayout.horizontalPadding)
                .padding(.top, NowPlayingTrackLipLayout.topPadding)
                .frame(
                    width: metrics.bodySize.width,
                    height: bodyHeight,
                    alignment: .top
                )
                .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The flank the pointer is on already carries the activity's accessibility label, and
        // VoiceOver reaches the island through that. This is the same sentence a second time, in a
        // strip that only exists while a pointer — which a VoiceOver user may not be driving — is
        // held on a 24pt square.
        .accessibilityHidden(true)
    }

    /// Opaque through the middle, transparent at the last few points of each end.
    ///
    /// **Built from fixed-width ramps rather than percentage stops.** A proportional gradient made
    /// the ramp a different size on every island width, so there was no inset the text could be
    /// given that reliably cleared it — see `NowPlayingTrackLipLayout.marqueeInset`, which is stated
    /// against `edgeFadeWidth` and would be a guess against a fraction.
    private static var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: NowPlayingTrackLipLayout.edgeFadeWidth)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: NowPlayingTrackLipLayout.edgeFadeWidth)
        }
    }

    private var lines: some View {
        VStack(alignment: .center, spacing: NowPlayingTrackLipLayout.lineSpacing) {
            MarqueeText(
                text: content.title ?? "",
                font: .systemFont(ofSize: NowPlayingTrackLipLayout.titleFontSize, weight: .semibold),
                color: NowPlayingSlotView.lineColor(opacity: 1),
                reduceMotion: model.reduceMotion,
                contentInset: NowPlayingTrackLipLayout.marqueeInset
            )
            .frame(height: NowPlayingTrackLipLayout.titleLineHeight)
            // Both ends fade rather than being cut. A scrolling line that appears and disappears at
            // a hard edge reads as clipped text; the same line arriving out of the island's own
            // black reads as the island being deeper than the strip. It is also what stands in for
            // the ellipsis under Reduce Motion, where the line is clipped and does not travel.
            .mask(Self.edgeFade)

            // **The artist scrolls too, and it did not until 2026-08-28.**
            //
            // The argument for holding it still was that two lines travelling at once is a sign
            // rather than a caption, and that the name under a title is a line a reader *checks*
            // rather than reads — so a tail truncation loses less of it than a second moving object
            // costs. That reasoning is kept here because it is not wrong; it lost to a different
            // one.
            //
            // The lip is the collapsed island's answer to "what is this", and it is read beside the
            // open player, which scrolls both lines. Two surfaces showing the same pair of strings
            // with different rules is the inconsistency a user notices — reported from use, twice —
            // and "Memphis May Fire — The Hol…" under a title that travels reads as the second line
            // having failed rather than as a deliberate restraint. The owner's verdict on hardware.
            HStack(spacing: 6) {
                MarqueeText(
                    text: content.subtitle ?? "",
                    font: .systemFont(
                        ofSize: NowPlayingTrackLipLayout.artistFontSize, weight: .regular
                    ),
                    color: NowPlayingSlotView.lineColor(opacity: increaseContrast ? 0.9 : 0.6),
                    reduceMotion: model.reduceMotion,
                    contentInset: NowPlayingTrackLipLayout.marqueeInset
                )
                .frame(maxWidth: .infinity)
                .mask(Self.edgeFade)

                // **The badge shares the artist's row.** It is the only place in this strip it can
                // go: a row of its own would make the lip's height depend on whether *this* track's
                // format is known, and the lip is on screen because a pointer is resting on the
                // album cover. See `NowPlayingTrackLipLayout.artistLineHeight`.
                //
                // Outside the fade, unlike the artist beside it. The fade exists because the line
                // travels; the badge does not travel, and a trademark drawn at a ramp's partial
                // opacity is worse than one not drawn at all.
                if let format = model.nowPlaying?.audioFormat,
                   let badge = AudioFormatBadge.image(for: format.kind) {
                    Image(nsImage: badge)
                        .renderingMode(.template)
                        .foregroundStyle(.white.opacity(increaseContrast ? 0.9 : 0.6))
                }
            }
            .frame(height: NowPlayingTrackLipLayout.artistLineHeight)
        }
        .frame(maxWidth: .infinity)
    }
}
