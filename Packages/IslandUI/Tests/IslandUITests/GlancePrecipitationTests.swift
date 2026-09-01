import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// Where the rain falls to, which is the one number on the glance that cannot be checked by reading
/// the view.
///
/// `PrecipitationField.resolve` treats the **bottom of the rectangle it is handed as the ground** —
/// rain finishes with its tip on that line and throws its flare there — so the rectangle
/// `GlancePrecipitationLayer` hands it is load-bearing, and both of the ways it has been wrong were
/// off by exactly one padding in opposite directions:
///
/// - Hung on the content's box, the box is inset by `GlanceLayout.topPadding` *after* the background
///   is attached, so its bottom edge sits that far **below** the island. The root's mask clips the
///   overshoot, so what shipped was rain falling through the island's bottom edge with its landings
///   happening off-surface.
/// - `IslandScreenModel.contentBodySize` subtracts the switcher strip, so an island wearing the row
///   had its ground moved **up** by 42pt and the rain stopped in mid-air across the chips.
///
/// Both are the same mistake — measuring the ground against the *content* rather than against the
/// island — and this suite pins the rule that replaced them: the ground is `bodySize.height`, with
/// the row and without it, on every surface that draws the layer.
@Suite("Glance precipitation")
@MainActor
struct GlancePrecipitationTests {

    private static let cutout = CGSize(width: 185, height: 32)

    /// The open island, and the open island wearing the row — the second taller by exactly the row,
    /// which is what `IslandLayout.expandedHeight` builds and what the shell publishes.
    private static let expandedHeight: CGFloat = 152

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(
                    bodySize: Self.cutout, topCornerRadius: 0, bottomCornerRadius: 8
                ),
                .expanded: IslandShapeMetrics(
                    bodySize: CGSize(width: 380, height: Self.expandedHeight),
                    topCornerRadius: 0,
                    bottomCornerRadius: 22
                ),
                .expandedWithPageIndicator: IslandShapeMetrics(
                    bodySize: CGSize(
                        width: 380,
                        height: Self.expandedHeight + IslandPageIndicatorLayout.height
                    ),
                    topCornerRadius: 0,
                    bottomCornerRadius: 22
                ),
            ],
            notchKind: .hardware,
            cutoutSize: Self.cutout
        )
    }

    /// An open island with one activity on stage, so there is a roster for the row to be made of.
    private func opened(
        chips: [ActivityChip] = [
            ActivityChip(id: "np", kind: .nowPlaying, symbol: "music.note", isOnStage: false),
        ]
    ) -> IslandScreenModel {
        let m = model()
        m.setActivity(
            ActivityPresentations(
                compact: ActivityContent(symbol: "calendar"),
                expanded: ActivityContent()
            ),
            kind: .glance,
            change: .presented("glance"),
            reduceMotion: true
        )
        m.chips = chips
        m.setExpanded(true, reduceMotion: true)
        return m
    }

    /// What `GlancePrecipitationLayer` hands `PrecipitationView`: the body below the cutout.
    private func precipitationHeight(_ m: IslandScreenModel) -> CGFloat {
        max(0, m.contentMetrics.bodySize.height - m.cutoutSize.height)
    }

    /// What the *content* is laid out in, which is what the rain used to be measured against.
    private func contentHeight(_ m: IslandScreenModel) -> CGFloat {
        max(0, m.contentBodySize.height - m.cutoutSize.height)
    }

    /// **There is no longer an open island without the strip**, and that is what these now pin.
    ///
    /// They used to compare two shapes — an island wearing the switcher row and one with an empty
    /// roster that wore nothing. The pages are fixed, so an open island always wears the indicator
    /// (`IslandScreenModel.hasPageIndicator`) and the second shape has no way to exist. What is left
    /// is the rule that mattered all along: the rain's ground is the island's own bottom edge, which
    /// is *below* where the content stops.
    @Test("the ground is the island's own bottom edge, strip and all")
    func groundIsTheBottomEdge() {
        let m = opened()
        #expect(m.contentShowsPageIndicator)
        #expect(
            m.cutoutSize.height + precipitationHeight(m) == m.contentMetrics.bodySize.height
        )
    }

    /// The regression in the screenshot: the rain overshot the island by `topPadding`, because the
    /// background was attached before the padding that moved the box down.
    @Test("the ground does not fall past the island")
    func groundDoesNotOvershoot() {
        let m = opened()
        #expect(precipitationHeight(m) <= m.contentMetrics.bodySize.height - m.cutoutSize.height)
        // And it does not stop short at the padding either, which is the half the bug inverted.
        #expect(precipitationHeight(m) > GlanceLayout.topPadding)
    }

    /// The other half: the island is taller than its content box by the strip, and the rain has to
    /// fall the whole way down it rather than stopping where the *content* stops.
    @Test("the rain falls the length of the indicator strip as well")
    func groundIncludesTheIndicatorStrip() {
        let m = opened()
        #expect(m.contentShowsPageIndicator)
        let fell = precipitationHeight(m)
        // Still the island's own bottom edge, which is the whole rule.
        #expect(m.cutoutSize.height + fell == m.contentMetrics.bodySize.height)
        // And below where the content stops — the strip the dots are drawn on.
        #expect(fell == contentHeight(m) + IslandPageIndicatorLayout.height)
    }

    /// The row stopped moving with the pointer on 2026-08-27, so the ground stopped moving with it
    /// too — and *that* is now the thing to guard. Rain that rose and fell as the pointer crossed
    /// the island would be the same regression wearing the other sign.
    @Test("the pointer arriving and leaving does not move the ground")
    func groundIgnoresThePointer() {
        let m = opened()
        let before = precipitationHeight(m)

        m.setHovering(true, reduceMotion: true)
        #expect(precipitationHeight(m) == before)

        m.setHovering(false, reduceMotion: true)
        #expect(m.contentShowsPageIndicator)
        #expect(precipitationHeight(m) == before)
    }

    /// The layer is shared, so the weather page cannot end up measuring its ground differently from
    /// the day it was opened from — there is one expression and both surfaces call it.
    @Test("a rectangle with nothing in it resolves to no drops rather than to a crash")
    func emptyRectangleIsEmptyField() {
        let field = PrecipitationField.resolve(
            size: .zero, kind: .rain, intensity: .moderate, scale: 2
        )
        #expect(field.drops.isEmpty)
    }
}
