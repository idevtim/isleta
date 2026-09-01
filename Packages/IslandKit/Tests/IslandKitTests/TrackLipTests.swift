import CoreGraphics
import Testing

@testable import IslandKit

/// The strip that springs out under the cutout while the pointer is on the album cover.
///
/// The rules pinned here are the ones that keep it from being a seventh shape the rest of the
/// geometry does not know about: it is representable in exactly one form, it grows in exactly one
/// direction, and it stays inside the ordering the widen-then-tighten protocol rests on.
@Suite("The track lip")
struct TrackLipTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    /// A resting island has not been asked anything, an open one already draws the title in its
    /// header, and an unflanked one has no cover to hover. None of the three can wear a lip, and
    /// the constructor is where that is enforced — so no call site can invent the shape.
    @Test("only a flanked peek can wear the lip")
    func lipIsAFlankedPeekOnly() {
        #expect(IslandForm(presentation: .rest, flanks: .standard, showsTrackLip: true) == .flankedRest)
        #expect(IslandForm(presentation: .peek, flanks: .none, showsTrackLip: true) == .peek)
        #expect(IslandForm(presentation: .expanded, flanks: .standard, showsTrackLip: true) == .expanded)
        #expect(IslandForm(presentation: .peek, flanks: .standard, showsTrackLip: true) == .flankedPeekWithLip)
        #expect(IslandForm.flankedPeekWithLip != IslandForm.flankedPeek)
        #expect(IslandForm(presentation: .peek, flanks: .wide, showsTrackLip: true)
                == .wideFlankedPeekWithLip)
        #expect(IslandForm(presentation: .peek, flanks: .wider, showsTrackLip: true)
                == .widerFlankedPeekWithLip)
        #expect(IslandForm.allCases.filter(\.showsTrackLip)
                == [.flankedPeekWithLip, .wideFlankedPeekWithLip, .widerFlankedPeekWithLip])
    }

    /// `resolve` has to discard it on the same terms the constructor does, or the model would ask
    /// for a form the shape table has no entry for and the island would snap to its fallback.
    @Test("resolving discards a lip the island cannot draw")
    func resolveDiscardsAnImpossibleLip() {
        #expect(
            IslandForm.resolve(
                isHovering: false, isExpanded: false, flanks: .standard, showsTrackLip: true
            ) == .flankedRest
        )
        #expect(
            IslandForm.resolve(
                isHovering: true, isExpanded: true, flanks: .standard, showsTrackLip: true
            ) == .expanded
        )
        #expect(
            IslandForm.resolve(
                isHovering: true, isExpanded: false, flanks: .none, showsTrackLip: true
            ) == .peek
        )
        #expect(
            IslandForm.resolve(
                isHovering: true, isExpanded: false, flanks: .standard, showsTrackLip: true
            ) == .flankedPeekWithLip
        )
    }

    /// The lip hangs *below* the cutout. Growing sideways as well would move the flanks — one of
    /// which is the album cover the pointer is currently resting on, so the island would slide out
    /// from under the gesture that asked for it.
    @Test("the lip adds height and not width")
    func lipAddsHeightOnly() {
        let peek = IslandLayout.metrics(for: .flankedPeek, on: screen)
        let lip = IslandLayout.metrics(for: .flankedPeekWithLip, on: screen)

        #expect(lip.bodySize.width == peek.bodySize.width)
        #expect(lip.bodySize.height == peek.bodySize.height + IslandLayout.trackLipHeight)
        #expect(lip.topCornerRadius == peek.topCornerRadius)
        #expect(lip.topFlareRadius == peek.topFlareRadius)
    }

    /// Between the cutout's own corner and the open island's. Rounder than the notch because the
    /// shape is more than twice as tall; squarer than the open island because a peek that looks
    /// like an open island has taken the click's job.
    @Test("the lip's corners sit between the notch's and the open island's")
    func lipCornersAreBetween() {
        let lip = IslandLayout.metrics(for: .flankedPeekWithLip, on: screen)

        #expect(lip.bottomCornerRadius > IslandLayout.notchBottomCornerRadius)
        #expect(lip.bottomCornerRadius < IslandLayout.expandedBottomCornerRadius)
    }

    /// **The open island does not contain the lip, and this is the test that says so.**
    ///
    /// Every other shape in the family is inside the expanded form, which is why
    /// `AppDelegate.transition` widens the hit region to that one form and is covered for every
    /// intermediate. The lip breaks it — at the ceiling of both size settings a collapsed island
    /// wearing one is 112pt tall, against the 108 an open island showing a short content-sized
    /// activity is allowed to shrink to. Those four points would be drawn island that rejects
    /// clicks for the length of the morph, which is the subset `IslandHitTestView` is written
    /// around.
    ///
    /// So the shell widens to **all three** maximal forms, and this pins each half of that: the
    /// three together contain the whole family, and no two of them do.
    ///
    /// The third is the **widest** flanked peek, `IslandFlanks.wider` — power spelling what the
    /// charger just did, since 2026-09-01, where it used to be `.wide` and a HUD. It out-reaches the
    /// open island in the other dimension and by a much larger margin than the lip does — 274pt of
    /// flank growth against an open body of 368 — and unlike the lip it does so on every Mac at
    /// every setting, not only at the ceiling. Naming the widest span rather than both is what makes
    /// this three forms and not four: it contains the wide one at the same presentation.
    ///
    /// Asked at the ceiling of every adjustment at once, because that is the combination nobody
    /// will have on their Mac and everybody's Mac has to survive.
    @Test("no two maximal forms contain the family, and the three of them do")
    func widestPairContainsTheFamily() {
        let extreme = IslandSizing(peekScale: 2, widthAdjustment: 48, heightAdjustment: 24)
        // The shortest an open island is ever allowed to be — `minimumExpandedHeight` clamps it, so
        // any content height at or below the cutout's own lands here.
        let expanded = IslandLayout.metrics(
            for: .expanded, on: screen, sizing: extreme, expandedContentHeight: 1
        )
        let lip = IslandLayout.metrics(for: .flankedPeekWithLip, on: screen, sizing: extreme)
        let wide = IslandLayout.metrics(for: .widerFlankedPeekWithLip, on: screen, sizing: extreme)
        // The span it replaced in this list, which it has to contain for that replacement to be
        // sound — see `AppDelegate.transition`.
        #expect(wide.bodySize.width
                >= IslandLayout.metrics(
                    for: .wideFlankedPeekWithLip, on: screen, sizing: extreme
                ).bodySize.width)

        // The lip out-reaches the open island downward and nothing else.
        #expect(expanded.bodySize.height == IslandLayout.minimumExpandedHeight)
        #expect(lip.bodySize.height > expanded.bodySize.height)
        #expect(lip.bodySize.width < expanded.bodySize.width)
        // The wide flanks out-reach both of them sideways, which is why naming only the first two
        // would leave the region a subset for the whole of a volume keypress.
        #expect(wide.bodySize.width > expanded.bodySize.width)
        #expect(wide.bodySize.width > lip.bodySize.width)

        let widest = [lip, wide].reduce(expanded, IslandShapeMetrics.union)
        for form in IslandForm.allCases {
            let metrics = IslandLayout.metrics(
                for: form, on: screen, sizing: extreme, expandedContentHeight: 1
            )
            #expect(metrics.bodySize.width <= widest.bodySize.width, "\(form) is wider")
            #expect(metrics.bodySize.height <= widest.bodySize.height, "\(form) is taller")
        }
    }

    /// The lip has to make the body region *drawable*, not merely make the island taller. Below
    /// `ActivitySlotLayout.minimumBodyHeight` the strip would grow the island and have nowhere to
    /// put the two lines, which is the one failure that looks like a bug in the shape rather than
    /// in the content.
    ///
    /// Stated here in IslandKit's own terms — the height below the cutout — because that constant
    /// lives in IslandUI and this package cannot see it. `TrackLipLayoutTests` asserts the other
    /// half, that the rows fit in what this leaves.
    @Test("the lip leaves a drawable strip below the cutout")
    func lipAffordsABody() {
        let lip = IslandLayout.metrics(for: .flankedPeekWithLip, on: screen)
        let belowTheCutout = lip.bodySize.height - screen.notch.cutoutSize.height

        #expect(belowTheCutout >= IslandLayout.trackLipHeight)
    }
}
