import CoreGraphics
import Testing

@testable import IslandKit

/// The two hover regions, and why there are two.
///
/// Reported from hardware as "I can hover close to the island and it acts like my mouse is on it
/// directly". The cause was that one region did both jobs: the tracking rect has to cover the
/// island's *peeked* shape, or the island grows out from under it, exits, shrinks and oscillates
/// under a stationary pointer — and that same rect was also the test for arriving, which put 6pt of
/// slop each side and 8pt below a 32pt island.
@Suite("Hover hysteresis")
struct HoverHysteresisTests {

    /// A 14" MacBook Pro.
    private static let screen = IslandScreen(
        id: 1,
        name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 663, y: 950, width: 185, height: 32))
    )

    private static let panel = IslandLayout.panelFrame(for: screen).size

    private static func regions(isExpanded: Bool, flanks: IslandFlanks) -> (enter: CGRect, exit: CGRect) {
        (
            IslandLayout.hoverEnterRegion(
                isExpanded: isExpanded, flanks: flanks, on: screen, in: panel
            ),
            IslandLayout.hoverRegion(
                isExpanded: isExpanded, flanks: flanks, on: screen, in: panel
            )
        )
    }

    /// **The fix.** Arriving is tested against the resting island; leaving against the peeked one.
    @Test("the entry region is tighter than the exit region", arguments: IslandFlanks.allCases)
    func entryIsTighterThanExit(flanks: IslandFlanks) {
        let (enter, exit) = Self.regions(isExpanded: false, flanks: flanks)
        #expect(enter.width < exit.width)
        #expect(enter.height < exit.height)
        #expect(exit.contains(enter), "and the tight one is wholly inside the generous one")
    }

    /// The entry region is exactly the island the user can see, so "on it" means on it.
    ///
    /// Against `boundingSize`, not `bodySize`: the flare reaches past the body sideways at the top,
    /// and it is lit pixels the user can see and would expect to be able to point at. This is the
    /// third place in this feature where `bodySize` was the wrong measure — the geometry's own
    /// `boundingSize` is the one that answers "how big does this look".
    @Test("the entry region is the resting island", arguments: IslandFlanks.allCases)
    func entryRegionIsTheRestingIsland(flanks: IslandFlanks) {
        let (enter, _) = Self.regions(isExpanded: false, flanks: flanks)
        let resting = IslandLayout.metrics(
            for: IslandForm(presentation: .rest, flanks: flanks), on: Self.screen
        )
        let bounding = IslandShapeGeometry.boundingSize(for: resting)
        #expect(enter.width == bounding.width)
        #expect(enter.height == bounding.height)
    }

    /// **The oscillation this must not reintroduce.** Once peeked, the island is larger than the
    /// region that let it in — so the exit region has to contain the peeked shape, or the island
    /// hands itself a `mouseExited` and flickers under a stationary pointer.
    @Test("the peeked island still fits inside the exit region", arguments: IslandFlanks.allCases)
    func peekedIslandFitsTheExitRegion(flanks: IslandFlanks) {
        let (_, exit) = Self.regions(isExpanded: false, flanks: flanks)
        let peeked = IslandLayout.metrics(
            for: IslandForm(presentation: .peek, flanks: flanks), on: Self.screen
        )
        let bounding = IslandShapeGeometry.boundingSize(for: peeked)
        #expect(exit.width >= bounding.width)
        #expect(exit.height >= bounding.height)
    }

    /// **The open island's hysteresis is the blur**, and it is the same asymmetry as the closed
    /// island's rather than a second idea: tight to arrive, generous to leave.
    ///
    /// Arriving is the island itself, so the switcher row is revealed by a pointer that is genuinely
    /// on it rather than by one hovering in the blur beside it. Leaving is the island *plus* the
    /// blur, because leaving is what closes the island now — and a boundary at the island's own edge
    /// would close it under a pointer traveling towards a control near the rim.
    @Test("the open island's exit region is its blur and its entry region is not")
    func openIslandLeavesThroughTheBlur() {
        let (enter, exit) = Self.regions(isExpanded: true, flanks: .none)
        #expect(enter == IslandLayout.bounds(for: .expanded, on: Self.screen, in: Self.panel))
        #expect(exit == IslandLayout.blurRegion(isExpanded: true, on: Self.screen, in: Self.panel))
        #expect(exit.contains(enter))
        #expect(exit != enter)
        #expect(exit.width == enter.width + IslandLayout.blurSpread * 2)
        #expect(exit.height == enter.height + IslandLayout.blurSpread)
    }

    /// The user's peek scale widens the gap between the two rather than moving both — a bigger peek
    /// is a bigger island once hovered, not a bigger area that counts as hovering.
    @Test("a larger peek scale grows the exit region and leaves the entry region alone")
    func peekScaleOnlyAffectsTheExitRegion() {
        let standard = IslandLayout.hoverEnterRegion(
            isExpanded: false, flanks: .standard, on: Self.screen, in: Self.panel
        )
        let bigPeek = IslandSizing(peekScale: 2)
        let adjustedEnter = IslandLayout.hoverEnterRegion(
            isExpanded: false, flanks: .standard, on: Self.screen, in: Self.panel, sizing: bigPeek
        )
        let adjustedExit = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .standard, on: Self.screen, in: Self.panel, sizing: bigPeek
        )
        #expect(adjustedEnter == standard, "the island you must touch has not changed size")
        #expect(adjustedExit.width > standard.width)
    }

    /// The user's width adjustment *does* move both: it makes the resting island itself bigger, so
    /// the thing the pointer has to be on is genuinely larger.
    @Test("a user-widened island widens what counts as touching it")
    func widthAdjustmentMovesBoth() {
        let standard = IslandLayout.hoverEnterRegion(
            isExpanded: false, flanks: .standard, on: Self.screen, in: Self.panel
        )
        let wider = IslandLayout.hoverEnterRegion(
            isExpanded: false, flanks: .standard, on: Self.screen, in: Self.panel,
            sizing: IslandSizing(widthAdjustment: 40)
        )
        #expect(wider.width > standard.width)
    }
}
