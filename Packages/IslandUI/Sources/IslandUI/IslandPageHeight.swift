import CoreGraphics
import Foundation
import IslandActivities
import IslandKit

/// How much body each page lays its content out in, below the cutout.
///
/// **One definition, asked by the shell and by the page itself.** The shell asks it *before* a turn,
/// to size the island for the page arriving; each page asks it while drawing, to lay out at the
/// height it is going to have rather than at the height the island happens to be.
///
/// ## Why a page does not simply measure the box it is in
///
/// Every other surface in the island reads `IslandScreenModel.contentBodySize` and lays out against
/// that, on the argument written there: ask the box rather than recompute, because the two agree
/// right up until they do not and the way that fails is a row sliced in half by the island's own
/// bottom edge.
///
/// That argument holds at rest and breaks during a page turn. `metricsByForm` is a **settled table
/// swapped in one frame** — SwiftUI interpolates inside `IslandShape`, not in the model — so the
/// instant a turn commits, the box both pages are reading jumps to the incoming page's height. The
/// outgoing page then re-lays-out to a height meant for its replacement and visibly reflows as it
/// slides away: rows redistributing around `Spacer`s, the transport row walking up the island.
/// Reported from use as the elements jumping around mid-swipe.
///
/// Asking *per page* fixes it by construction. Home always lays out at home's height whatever the
/// island is doing, so the page leaving keeps its arrangement all the way out and the page arriving
/// is complete before it is on screen. The safety the box gave up is bought back by this being the
/// **same function the shell sized the island with** — they cannot disagree at rest, because there
/// is only one of them.
///
/// `@MainActor` because it reads `GlanceModel`, which is. That is the whole of the isolation: the
/// arithmetic underneath is in `IslandHomeLayout` and `GlanceWeatherLayout`, both plain enums a
/// nonisolated test can call directly — which is where the numbers are pinned, for the trap
/// `docs/BUILD-AND-TEST.md` records about main-actor statics.
@MainActor
public enum IslandPageHeight {

    /// What the **shell** sizes the island for: the body a page needs below the cutout, or nil for
    /// the island's default height.
    ///
    /// Nil rather than a number for `.music`, because that is genuinely what the player wants. It is
    /// a fixed three-row layout measured into a rectangle it agreed on in advance
    /// (`NowPlayingExpandedLayout.fits(in:)`), so it does not size the island — the island sizes it,
    /// and it has always been drawn at `IslandLayout.expandedBodySize`. `IslandLayout.expandedHeight`
    /// already spells nil as exactly that, so saying so is one word rather than an arithmetic
    /// restatement of it that could drift.
    /// - Parameter hasAudioFormat: whether the playing track has an audio badge to draw. Only the
    ///   home page cares: its music column gains a row for it. See `IslandHomeLayout.formatLineHeight`
    ///   for why that row is counted rather than reserved.
    public static func contentHeight(
        for page: IslandPage,
        glance: GlanceModel?,
        hasAudioFormat: Bool = false
    ) -> CGFloat? {
        switch page {
        case .home:
            IslandHomeLayout.contentHeight(
                eventCount: glance?.rows.count ?? 0,
                hasOverflow: hasOverflow(glance),
                // `.granted` where there is no glance at all — §3's layering test builds this
                // package with nothing injected, and an un-wired preview is not a refused
                // calendar. It is also the only value that adds no height, which is the right
                // answer for a page that has no notice to draw.
                access: glance?.snapshot.access ?? .granted,
                hasAudioFormat: hasAudioFormat
            )
        case .music:
            nil
        case .weather:
            // A constant: `GlanceWeatherLayout` draws a fixed number of forecast rows whether or not
            // the service answered with that many, so a reading landing while the page is open
            // cannot move the island's bottom edge under a pointer resting on it.
            GlanceWeatherLayout.contentHeight
        }
    }

    /// What the **page itself** lays out in: the same answer, with nil resolved against this
    /// screen's cutout.
    ///
    /// The two are one function so they cannot disagree, and they are two spellings because the
    /// shell's caller has no screen in hand and the view's does. `IslandLayout.expandedHeight` turns
    /// nil into `expandedBodySize.height`; this subtracts the hole, which is the part of the island
    /// there are no pixels to draw in.
    public static func layoutHeight(
        for page: IslandPage,
        glance: GlanceModel?,
        cutoutHeight: CGFloat,
        hasAudioFormat: Bool = false
    ) -> CGFloat {
        if let height = contentHeight(for: page, glance: glance, hasAudioFormat: hasAudioFormat) {
            return height
        }
        return max(0, IslandLayout.expandedBodySize.height - cutoutHeight)
    }

    /// Whether the day has more events than the home page has room to list.
    ///
    /// Asked of the snapshot rather than of `rows`, which is already capped — the whole point of the
    /// "+N more" line is to say what the cap hid.
    public static func hasOverflow(_ glance: GlanceModel?) -> Bool {
        guard let glance else { return false }
        return glance.snapshot.events.count > glance.rows.count
    }
}
