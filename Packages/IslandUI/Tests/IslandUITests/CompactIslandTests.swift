import CoreGraphics
import IslandKit
import Testing

@testable import IslandUI

/// compactIsland, and the arithmetic that decides how far it is allowed to go.
///
/// **compactIsland is a size, not a state**, and that is the first thing this suite is here to record.
/// `IslandPresentation` derives `.rest`/`.peek`/`.expanded` from two independent inputs, and a fourth
/// case would have to be a third input — but nothing produces one. The user does not hover *mini*,
/// and no click puts the island into it. What they are asking for is the island they already have,
/// smaller, so it belongs in `IslandLayout` beside the peek scale and the two size adjustments, and
/// it flows through the one table (`metricsByForm`) that both the drawn shape and `islandPath` are
/// built from. `IslandSizingTests` covers the geometry; what is left here is the bound.
///
/// The bound is `NowPlayingExpandedLayout`. Its rows are anchored to the *bottom* of the body it is
/// handed, so a body shorter than the rows need does not simply crowd them — it pushes the transport
/// row past the bottom edge, where `IslandRootView`'s mask clips it and a button is visibly shaved
/// *and* invisibly unhittable. Nothing in a build catches that; the numbers are here so a later
/// change to any of the five constants fails the suite instead.
@Suite("compactIsland")
struct CompactIslandTests {

    /// The tallest cutout Isleta has met, which is the case that leaves the least drawable height.
    private let cutoutHeight: CGFloat = 32

    /// What the open island's rows actually need, in the body's own space.
    private var rowsHeight: CGFloat {
        NowPlayingExpandedLayout.topPadding
            + NowPlayingExpandedLayout.headerRowHeight
            + NowPlayingExpandedLayout.scrubberRowHeight
            + NowPlayingExpandedLayout.transportRowHeight
            + NowPlayingExpandedLayout.bottomPadding
    }

    @Test("the compact height is shorter than the default, and by a visible amount")
    func miniIsSmaller() {
        #expect(IslandLayout.miniExpandedBodyHeight < IslandLayout.expandedBodySize.height)
        // Not a token 2pt. Under about 5% nobody can see it and the switch reads as broken.
        let reduction = IslandLayout.expandedBodySize.height - IslandLayout.miniExpandedBodyHeight
        #expect(reduction / IslandLayout.expandedBodySize.height > 0.05)
    }

    /// The whole reason the constant is 156 and not 140.
    @Test("the player's rows still fit inside the compact island")
    func playerFitsAtMiniHeight() {
        let drawable = IslandLayout.miniExpandedBodyHeight - cutoutHeight
        #expect(rowsHeight <= drawable)
    }

    /// And the other half: the compact height spends the slack and does not invent any. If a future
    /// edit lowers it further, this fails before anybody sees a clipped button.
    @Test("the compact height is the whole of the slack the default had, and no more")
    func miniSpendsExactlyTheSlack() {
        let defaultDrawable = IslandLayout.expandedBodySize.height - cutoutHeight
        let slack = defaultDrawable - rowsHeight
        #expect(slack >= 0)
        #expect(
            IslandLayout.miniExpandedBodyHeight
                == IslandLayout.expandedBodySize.height - slack
        )
    }

    /// The open island still has to be a panel hanging off the notch rather than a strip.
    @Test("the compact island is still taller than the floor an open island is allowed to be")
    func miniClearsTheMinimum() {
        #expect(IslandLayout.miniExpandedBodyHeight > IslandLayout.minimumExpandedHeight)
    }

    /// The width is deliberately untouched, and this is the assertion that says why:
    /// `NowPlayingExpandedLayout` computes its columns against the *constant* rather than against
    /// the body it is handed, so narrowing the island would draw its rows outside the mask. Whoever
    /// makes the width adjustable has to fix that first, and this test is where they will find that
    /// out.
    @Test("the compact island keeps the width the transport layout assumes as a constant")
    func widthIsUntouched() {
        let screen = IslandScreen(
            id: 1, name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            backingScaleFactor: 2,
            notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        )
        let mini = IslandLayout.metrics(for: .expanded, on: screen, sizing: IslandSizing(compactIsland: true))
        #expect(mini.bodySize.width == IslandLayout.expandedBodySize.width)
    }
}
