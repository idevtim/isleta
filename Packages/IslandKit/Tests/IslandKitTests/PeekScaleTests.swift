import CoreGraphics
import Testing

@testable import IslandKit

/// The user's peek amount, as arithmetic.
///
/// Two properties matter and both are load-bearing rather than cosmetic. The scale must reach
/// **only** peek, because everything downstream of `IslandShapeMetrics.union` assumes each dimension
/// is monotone in its own input — rest inside peek inside expanded — and a scale that also moved
/// rest would break the containment the widen-then-tighten protocol depends on. And the drawn shape
/// and the clickable shape must be the *same* function of the *same* scale, because a peek drawn
/// larger than the region that accepts clicks is the subset bug `IslandHitTestView` documents: the
/// window server routes the click to us because those pixels are lit, and `hitTest` drops it.
@Suite("Peek scale")
struct PeekScaleTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    private let panelSize = CGSize(width: 603, height: 200)

    @Test("a scale of 1 is exactly the shape the island had before the setting existed")
    func unityIsUnchanged() {
        let peek = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 1))
        let rest = IslandLayout.restMetrics(for: screen)

        #expect(peek.bodySize.width == rest.bodySize.width + IslandLayout.peekWidthGrowth)
        #expect(peek.bodySize.height == rest.bodySize.height + IslandLayout.peekHeightGrowth)
    }

    @Test("the default argument is 1, so an uncalibrated caller gets the shipped shape")
    func defaultArgumentIsUnity() {
        #expect(IslandLayout.peekMetrics(for: screen) == IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 1)))
        #expect(IslandLayout.metrics(for: .peek, on: screen) == IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 1)))
    }

    @Test("a larger scale grows peek, a smaller one shrinks it")
    func scaleMovesPeek() {
        let small = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 0.5))
        let unity = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 1))
        let large = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 2))

        #expect(small.bodySize.width < unity.bodySize.width)
        #expect(unity.bodySize.width < large.bodySize.width)
        #expect(small.bodySize.height < unity.bodySize.height)
        #expect(unity.bodySize.height < large.bodySize.height)
    }

    /// The containment `IslandShapeMetrics.union` and `widenHitRegionForTransition` are built on.
    @Test("peek still contains rest at the smallest scale the user can choose")
    func peekContainsRestAtEveryScale() {
        let rest = IslandLayout.restMetrics(for: screen)
        for scale in [0.5, 0.75, 1.0, 1.5, 2.0] {
            let peek = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: scale))
            #expect(peek.bodySize.width >= rest.bodySize.width)
            #expect(peek.bodySize.height >= rest.bodySize.height)
        }
    }

    @Test("rest and expanded are untouched by the scale")
    func onlyPeekMoves() {
        for scale in [0.5, 1.0, 2.0] {
            #expect(IslandLayout.metrics(for: .rest, on: screen, sizing: IslandSizing(peekScale: scale))
                    == IslandLayout.metrics(for: .rest, on: screen))
            #expect(IslandLayout.metrics(for: .expanded, on: screen, sizing: IslandSizing(peekScale: scale))
                    == IslandLayout.metrics(for: .expanded, on: screen))
            #expect(IslandLayout.metrics(for: .flankedRest, on: screen, sizing: IslandSizing(peekScale: scale))
                    == IslandLayout.metrics(for: .flankedRest, on: screen))
        }
    }

    @Test("a flanked peek scales by the same growth an unflanked one does")
    func flankedPeekScalesIdentically() {
        for scale in [0.5, 1.5, 2.0] {
            let peek = IslandLayout.metrics(for: .peek, on: screen, sizing: IslandSizing(peekScale: scale))
            let flanked = IslandLayout.metrics(for: .flankedPeek, on: screen, sizing: IslandSizing(peekScale: scale))
            let flankedRest = IslandLayout.metrics(for: .flankedRest, on: screen)
            let rest = IslandLayout.metrics(for: .rest, on: screen)

            #expect(flanked.bodySize.width - flankedRest.bodySize.width
                    == peek.bodySize.width - rest.bodySize.width)
        }
    }

    /// §6.6 asks for layout snapped to the pixel grid at 1x and 2x. A scale of 1.3 on 12pt is 15.6,
    /// which is a half pixel at 1x — a soft edge on the one shape whose job is to be
    /// indistinguishable from the bezel.
    @Test("a fractional scale still lands on whole points")
    func growthIsPixelSnapped() {
        for scale in [0.7, 1.3, 1.55, 1.9] {
            let growth = IslandLayout.peekGrowth(scale: scale)
            #expect(growth.width == growth.width.rounded())
            #expect(growth.height == growth.height.rounded())
        }
    }

    /// The two halves that must never disagree. `hoverRegion` is what the tracking area watches;
    /// if it were computed at a different scale than the drawn shape, the island would grow outside
    /// the rect watching it and hand itself a `mouseExited` under a stationary pointer.
    @Test("the watched region follows the same scale the island is drawn at")
    func hoverRegionFollowsTheScale() {
        let unity = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .none, on: screen, in: panelSize, sizing: IslandSizing(peekScale: 1)
        )
        let large = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .none, on: screen, in: panelSize, sizing: IslandSizing(peekScale: 2)
        )

        #expect(large.width > unity.width)
        #expect(large.height > unity.height)
        // And it is the peek footprint, not something adjacent to it — measured as *drawn*, which
        // is wider than the body: a peeked island's top corners flare out into the ceiling, and a
        // watched region stopping at the body would leave those lit corners outside it, so a pointer
        // resting on one would count as having left the island.
        let drawn = IslandLayout.peekMetrics(for: screen, sizing: IslandSizing(peekScale: 2))
        #expect(large.width == IslandShapeGeometry.boundingSize(for: drawn).width)
    }

    /// An expanded island's watched region is the expanded footprint, which the peek amount has
    /// nothing to say about — the alternative would let a peek setting change the region an *open*
    /// island is tracked in.
    @Test("an expanded island's region ignores the peek amount")
    func expandedRegionIgnoresScale() {
        let unity = IslandLayout.hoverRegion(
            isExpanded: true, flanks: .none, on: screen, in: panelSize, sizing: IslandSizing(peekScale: 1)
        )
        let large = IslandLayout.hoverRegion(
            isExpanded: true, flanks: .none, on: screen, in: panelSize, sizing: IslandSizing(peekScale: 2)
        )
        #expect(unity == large)
    }
}
