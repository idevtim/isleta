import IslandActivities
import IslandKit
import SwiftUI

/// The weather that is actually happening, behind whichever calendar surface is up.
///
/// Behind rather than beside: it is the sky the temperature is describing, not a second reading.
/// Drawn only when the sky is doing something — `Precipitation.matching` answers nil for a dry one,
/// which is the common case and costs nothing.
///
/// **Matched on the SF Symbol name, never on `conditionDescription`.** That string is Apple's own
/// *localized* prose, so a rule keyed on it works in English and stops on the first German Mac —
/// the same trap CLAUDE.md records for a notification banner's action titles.
///
/// ## Why this is a layer of its own rather than a `.background`
///
/// `PrecipitationField.resolve` treats **the bottom of the rectangle it is handed as the ground**:
/// rain finishes with its tip on that line and throws its flare there. So the rectangle has to be
/// the island's own body, and hanging the rain on the content's box instead gets it wrong twice
/// over, in opposite directions, and only ever by a padding:
///
/// - The content box is inset by `topPadding` *after* the background is attached, so its bottom
///   edge sits that far **below** the island — rain falling through the bottom edge, clipped by the
///   root's mask, with its landings happening off-surface where nobody sees them.
/// - `IslandScreenModel.contentBodySize` subtracts the switcher strip while the pointer is on the
///   island, so the moment the row is revealed the ground jumps **up** by the height of it — rain
///   stopping in mid-air across the chips.
///
/// Asking the shape for its body answers both: the island's bottom edge is the ground in either
/// state, and the rain grows into the switcher strip as the island grows to hold it.
///
/// Suppressed by Reduce Motion, Reduce Transparency and Increase Contrast, each for its own reason
/// and all three argued on `PrecipitationField.resolve`. Reduce Motion draws **nothing** rather than
/// a still field: rain's whole content is the falling, and a frozen scatter of pale ticks over the
/// text reads as a rendering fault. What the sky is doing is still on the weather chip, as a symbol
/// and a description.
///
/// ## Coordinates
///
/// Read from `contentMetrics` and never from `metrics`, like every other layer inside the island:
/// the content lags the container by `Motion.contentFollowDelay` (§6.2), so measuring the ground
/// against the container's target would put it where the island is *going* to be.
struct GlancePrecipitationLayer: View {

    let model: IslandScreenModel

    let glance: GlanceModel

    /// How far the rain falls: the surface's whole body below the cutout, **and the bottom of that
    /// rectangle is the ground**.
    ///
    /// Asked of the caller rather than read off the island here, and the two callers answer
    /// differently on purpose.
    ///
    /// - The **weather page** answers with its own settled height, which is `IslandPageHeight`'s
    ///   argument applied to the one layer inside a page that is a function of the island's
    ///   *height* rather than its width. A page turn moves the island's bottom edge with the
    ///   finger, so reading `contentMetrics` here resized this view on every sample of every
    ///   drag — `layout()` per frame, and `PrecipitationLayersView.settleDelay` earning its keep on
    ///   every one of them. It was also the *wrong* height while the page was a neighbour:
    ///   `contentMetrics` is the shape of the page being left, lerping toward this one, so the rain
    ///   sliding in was sized for the home page for the length of the turn.
    /// - The **meeting** answers with the island's current box, which is what it has always been.
    ///   A meeting is not a page and cannot be dragged (`IslandRootView` draws it no neighbours),
    ///   so there is no interpolation there to be tied to.
    let groundBelowCutout: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let bodyWidth = model.contentBodyWidth
            let origin = IslandLayout.bodyOrigin(bodyWidth: bodyWidth, in: proxy.size)

            precipitation
                .frame(
                    // The whole body below the cutout — the notch is a **hole**, and there are no
                    // pixels to draw on above that line.
                    width: bodyWidth,
                    height: max(0, groundBelowCutout)
                )
                .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The falling rain or snow, or nothing at all.
    ///
    /// Sixty-four layers cost the same as six — measured, paired against a static control: the
    /// render server's expense is *that something is animating* rather than how many layers are
    /// doing it, and this process draws zero frames either way. So the drop count is a design
    /// decision and not a performance one.
    @ViewBuilder
    private var precipitation: some View {
        if let weather = glance.snapshot.weather,
           let falling = Precipitation.matching(weatherSymbolName: weather.symbolName) {
            PrecipitationView(
                falling,
                reduceMotion: model.reduceMotion,
                reduceTransparency: model.reduceTransparency,
                increaseContrast: model.increaseContrast
            )
        }
    }
}
