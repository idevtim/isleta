import IslandActivities
import IslandKit
import SwiftUI

/// The music page: the full player, drawn as a page rather than as an activity's body.
///
/// ## Why this exists at all, rather than the page just letting the player draw itself
///
/// The player is `NowPlayingSlotView`'s `.expanded` case, and it is reached through
/// `ActivityLayerView`'s per-slot kind dispatch — which means it is drawn **only when a `.nowPlaying`
/// activity owns the body slot**, i.e. when it is the stage's primary. That was right while the
/// island showed one activity at a time and you switched between them with chips. It is wrong for a
/// page: the music page has to draw the player when the *calendar* is the primary and music is the
/// companion, when music is queued behind a timer, and when nothing is playing at all.
///
/// So the player moves to a sibling layer, on exactly the terms `GlanceLayerView` already had. This
/// view is the seam: it positions the player's own body in the page's box and hands it the content,
/// and `NowPlayingSlotView` goes on owning every pixel inside it. There is deliberately no second
/// copy of the player here — a page that redrew the artwork, the scrubber and the transport would be
/// a second definition of the one surface this app is most often looked at through.
///
/// ## Coordinates and motion
///
/// The same rules as every other page: offset by `IslandLayout.bodyOrigin` and then by the cutout's
/// height, laid out against `contentMetrics` rather than `metrics` so it follows the container by
/// `Motion.contentFollowDelay` (§6.2), and carrying no animation of its own (§6.1).
struct IslandMusicPageView: View {

    let model: IslandScreenModel

    /// What the player has to say, or nil when nothing is playing.
    let content: ActivityContent?

    let now: Date

    var body: some View {
        GeometryReader { proxy in
            // The width and nothing else — see `IslandScreenModel.contentBodyWidth`, which is
            // why a page does not read the shape a drag is interpolating.
            let bodyWidth = model.contentBodyWidth
            let origin = IslandLayout.bodyOrigin(bodyWidth: bodyWidth, in: proxy.size)

            Group {
                if let controller = model.nowPlaying, let content {
                    NowPlayingSlotView(
                        content: content,
                        slot: .expanded,
                        controller: controller,
                        increaseContrast: model.increaseContrast,
                        reduceMotion: model.reduceMotion,
                        now: now,
                        namespace: nil,
                        icons: model.applicationIcons
                    )
                } else {
                    nothingPlaying
                }
            }
            .frame(
                width: bodyWidth,
                // **This page's own height, not the box the island currently is.** See
                // `IslandPageHeight`: reading the box made the player's three rows redistribute
                // around their `Spacer`s as it slid away, which is the jumping this fixed.
                height: IslandPageHeight.layoutHeight(
                    for: .music, glance: model.glance, cutoutHeight: model.cutoutSize.height
                ),
                alignment: .top
            )
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the page says with nothing playing.
    ///
    /// **A page, not an empty island.** The music page is one swipe from home and is reachable
    /// whether or not anything is playing — so it has to answer, and "Not playing" is the answer.
    /// Drawing nothing would read as the swipe having failed rather than as the Mac being quiet.
    private var nothingPlaying: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.45))

            Text(islandText("home.notPlaying", "Not playing"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
