import CoreGraphics
import Testing

@testable import IslandKit

/// The user's own island size, as arithmetic.
///
/// The property that matters here is not "the island got wider". It is that **every shape the island
/// can pass through is still contained by `IslandShapeMetrics.union` of its endpoints**, because that
/// is what the widen-then-tighten protocol in `AppDelegate.transition` depends on: a hit region that
/// is a *subset* of what is drawn means clicks land on lit island pixels, reach us, and get dropped —
/// they neither open the island nor fall through to the app underneath. A settings slider that
/// quietly broke that would look exactly like a settings slider that worked.
@Suite("Island sizing")
struct IslandSizingTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    private let panelSize = CGSize(width: 608, height: 400)

    /// Every sizing worth sweeping, including the two extremes of each adjustment.
    private let sizings: [IslandSizing] = [
        .standard,
        IslandSizing(widthAdjustment: -12),
        IslandSizing(widthAdjustment: 48),
        IslandSizing(heightAdjustment: -6),
        IslandSizing(heightAdjustment: 24),
        IslandSizing(peekScale: 2, widthAdjustment: 48, heightAdjustment: 24, compactIsland: true),
        IslandSizing(compactIsland: true),
    ]

    @Test("the standard sizing is exactly the geometry that shipped before any of it was adjustable")
    func standardIsUnchanged() {
        for form in IslandForm.allCases {
            #expect(
                IslandLayout.metrics(for: form, on: screen, sizing: .standard)
                    == IslandLayout.metrics(for: form, on: screen)
            )
        }
        #expect(IslandLayout.restMetrics(for: screen).bodySize == screen.notch.rect.size)
    }

    @Test("the adjustments reach the collapsed island and nothing else")
    func adjustmentsAreCollapsedOnly() {
        let sizing = IslandSizing(widthAdjustment: 48, heightAdjustment: 24)
        let rest = IslandLayout.metrics(for: .rest, on: screen, sizing: sizing)
        #expect(rest.bodySize.width == screen.notch.rect.width + 48)
        #expect(rest.bodySize.height == screen.notch.rect.height + 24)

        let peek = IslandLayout.metrics(for: .peek, on: screen, sizing: sizing)
        let standardPeek = IslandLayout.metrics(for: .peek, on: screen)
        #expect(peek.bodySize.width == standardPeek.bodySize.width + 48)
        #expect(peek.bodySize.height == standardPeek.bodySize.height + 24)

        // The open island is untouched, which is not laziness: `NowPlayingExpandedLayout`'s
        // transport row is written against `expandedBodySize.width` as a constant, so moving it
        // draws that row outside the mask.
        #expect(
            IslandLayout.metrics(for: .expanded, on: screen, sizing: sizing)
                == IslandLayout.metrics(for: .expanded, on: screen)
        )
    }

    /// The whole point of the suite. Sampled rather than argued, exactly as `PeekTests` does it.
    @Test("union of any two forms still contains every shape between them, at every sizing")
    func unionRemainsASuperset() {
        for sizing in sizings {
            for from in IslandForm.allCases {
                for to in IslandForm.allCases {
                    let a = IslandLayout.metrics(for: from, on: screen, sizing: sizing)
                    let b = IslandLayout.metrics(for: to, on: screen, sizing: sizing)
                    let widened = IslandShapeMetrics.union(a, b)
                    for step in 0...10 {
                        let mid = IslandShapeMetrics.lerp(from: a, to: b, progress: CGFloat(step) / 10)
                        #expect(mid.bodySize.width <= widened.bodySize.width)
                        #expect(mid.bodySize.height <= widened.bodySize.height)
                        // Radii the other way round: a radius only ever *removes* area from the
                        // body, so the widened region is the one with the least-rounded corners.
                        #expect(mid.topCornerRadius >= widened.topCornerRadius)
                        #expect(mid.bottomCornerRadius >= widened.bottomCornerRadius)
                        // The flare only adds area, so it takes the max.
                        #expect(mid.topFlareRadius <= widened.topFlareRadius)
                    }
                }
            }
        }
    }

    /// The open island has to stay the largest thing in the family, because `hoverRegion` picks
    /// *one* form to watch the pointer over and the island must never grow out from under it.
    @Test("the open island is still taller than every collapsed one, at every sizing")
    func expandedStaysLargest() {
        for sizing in sizings {
            let expanded = IslandLayout.metrics(for: .expanded, on: screen, sizing: sizing)
            for form in IslandForm.allCases where form.presentation != .expanded {
                let collapsed = IslandLayout.metrics(for: form, on: screen, sizing: sizing)
                #expect(collapsed.bodySize.height < expanded.bodySize.height)
            }
        }
    }

    /// A negative adjustment large enough to swallow a narrow cutout must not produce a path with
    /// no area — `IslandHitTestView` would then reject every click on an island still being drawn.
    @Test("a body can never be driven negative")
    func bodyIsNeverNegative() {
        let tiny = IslandScreen(
            id: 2, name: "Improbable",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            backingScaleFactor: 2,
            notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 396, y: 596, width: 8, height: 4))
        )
        let metrics = IslandLayout.metrics(
            for: .rest, on: tiny, sizing: IslandSizing(widthAdjustment: -12, heightAdjustment: -6)
        )
        #expect(metrics.bodySize.width >= 0)
        #expect(metrics.bodySize.height >= 0)
    }

    /// Widening the island past the cutout puts two square corners against the top of the screen,
    /// which is the same condition that earns a flanked island its flare. Reached from the settings
    /// window rather than from an activity, and it has to be answered the same way.
    @Test("a widened resting island earns the top flare a flanked one gets")
    func wideningEarnsTheFlare() {
        #expect(IslandLayout.restMetrics(for: screen).topFlareRadius == 0)
        #expect(
            IslandLayout.metrics(for: .rest, on: screen, sizing: IslandSizing(widthAdjustment: 24))
                .topFlareRadius == IslandLayout.flankedTopFlareRadius
        )
        // Narrower does not: the island is inside the hole, where there is nothing to curve.
        #expect(
            IslandLayout.metrics(for: .rest, on: screen, sizing: IslandSizing(widthAdjustment: -12))
                .topFlareRadius == 0
        )
    }

    @Test("the hovered region follows the sizing, so the island cannot grow out from under it")
    func hoverRegionFollows() {
        for sizing in sizings {
            let region = IslandLayout.hoverRegion(
                isExpanded: false, flanks: .standard, on: screen, in: panelSize, sizing: sizing
            )
            let drawn = IslandLayout.bounds(
                for: .flankedPeek, on: screen, in: panelSize, sizing: sizing
            )
            #expect(region.width >= drawn.width)
            #expect(region.height >= drawn.height)
        }
    }

    // MARK: - compactIsland

    @Test("compactIsland shortens the default open island and nothing else")
    func compactIslandIsADefaultHeight() {
        let mini = IslandSizing(compactIsland: true)
        #expect(
            IslandLayout.metrics(for: .expanded, on: screen, sizing: mini).bodySize.height
                == IslandLayout.miniExpandedBodyHeight
        )
        #expect(
            IslandLayout.metrics(for: .expanded, on: screen, sizing: mini).bodySize.width
                == IslandLayout.expandedBodySize.width
        )
        // Collapsed is untouched: compactIsland is about the open island.
        for form in IslandForm.allCases where form.presentation != .expanded {
            #expect(
                IslandLayout.metrics(for: form, on: screen, sizing: mini)
                    == IslandLayout.metrics(for: form, on: screen)
            )
        }
    }

    /// The clause that makes compactIsland safe. An activity that measured what it needs keeps it — a
    /// list scaled down to fit is a list with a row cut in half, which reads as a rendering fault
    /// rather than as a compact island.
    @Test("a content-sized island is not shortened by compactIsland")
    func contentHeightsAreLeftAlone() {
        for contentHeight in [CGFloat(76), 120, 220, 300] {
            #expect(
                IslandLayout.expandedHeight(
                    contentHeight: contentHeight, cutoutHeight: 32, compactIsland: true
                )
                    == IslandLayout.expandedHeight(contentHeight: contentHeight, cutoutHeight: 32)
            )
        }
    }
}
