import CoreGraphics
import Testing

@testable import IslandKit

/// The shape the island takes when what is on stage spells itself in the slivers.
///
/// The arithmetic here is what `ActivitySlotLayout` then divides into two drawable slivers, and what
/// `AppDelegate.transition` has to name in its widen — see `TrackLipTests` for the other form the
/// open island does not contain.
@Suite("Wide flanks")
struct WideFlankGeometryTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    /// A constant added to the *cutout*, like `flankedWidthGrowth` — so the sliver a word gets is
    /// the same 96pt on a Mac whose notch measures 185pt and on one that measures 200.
    @Test("the wide island is the cutout plus a constant, split evenly")
    func widthIsTheCutoutPlusAConstant() {
        let rest = IslandLayout.metrics(for: .wideFlankedRest, on: screen)
        #expect(rest.bodySize.width == 185 + IslandLayout.wideFlankedWidthGrowth)
        #expect(IslandLayout.wideFlankedFlankWidth == IslandLayout.wideFlankedWidthGrowth / 2)

        let wider = IslandScreen(
            id: 2, name: "Wider notch",
            frame: screen.frame, backingScaleFactor: 2,
            notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 764, y: 1085, width: 200, height: 32))
        )
        let onWider = IslandLayout.metrics(for: .wideFlankedRest, on: wider)
        #expect(onWider.bodySize.width - 200 == rest.bodySize.width - 185)
    }

    /// `flankedHeightGrowth` is zero and the wide span does not get its own exception: a strip of
    /// text hanging under the notch at rest is a panel, not a notch, and that objection does not
    /// care how wide the island is.
    ///
    /// It is also what keeps the widen protocol sound. The wide forms exceed the open island in
    /// width only, so one extra `widenHitRegionForTransition` covers the whole of the difference.
    @Test("a wide island is the cutout's own height, exactly as a flanked one is")
    func widthOnly() {
        let rest = IslandLayout.metrics(for: .rest, on: screen)
        let wide = IslandLayout.metrics(for: .wideFlankedRest, on: screen)
        #expect(wide.bodySize.height == rest.bodySize.height)
        #expect(wide.bottomCornerRadius == rest.bottomCornerRadius)

        let peek = IslandLayout.metrics(for: .peek, on: screen)
        let widePeek = IslandLayout.metrics(for: .wideFlankedPeek, on: screen)
        #expect(widePeek.bodySize.height == peek.bodySize.height)
    }

    /// **The property `IslandShapeMetrics.union` rests on.** Every dimension is monotone in its own
    /// input, so widening to a maximal form contains every intermediate a `lerp` can produce.
    @Test("width is monotone in the span, at rest and at peek", arguments: [IslandPresentation.rest, .peek])
    func widthIsMonotoneInTheSpan(presentation: IslandPresentation) {
        let widths = IslandFlanks.allCases.map {
            IslandLayout.metrics(
                for: IslandForm(presentation: presentation, flanks: $0), on: screen
            ).bodySize.width
        }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count, "four spans, four shapes")
    }

    /// The wide island is deliberately wider than the island it opens into — see
    /// `IslandLayout.wideFlankedWidthGrowth`, where the departure is argued. This pins it so the
    /// day it stops being true, whoever made it stop reads why the extra widen exists.
    @Test("the wide island out-reaches the open one sideways and nothing else",
          arguments: [IslandForm.wideFlankedPeek, .widerFlankedPeek])
    func widerThanTheOpenIsland(form: IslandForm) {
        let wide = IslandLayout.metrics(for: form, on: screen)
        let expanded = IslandLayout.expandedMetrics(for: screen)
        #expect(wide.bodySize.width > expanded.bodySize.width)
        #expect(wide.bodySize.height < expanded.bodySize.height)
    }

    /// **What lets `AppDelegate.transition` name one form where it used to name the wide one.** The
    /// widest span contains the wide one at the same presentation, so the union is the same union —
    /// and if that ever stops being true, the widen goes back to naming both or the island rejects
    /// clicks on lit pixels for the length of a morph.
    @Test("the widest flanked peek contains the wide one")
    func widestContainsWide() {
        let wide = IslandLayout.metrics(for: .wideFlankedPeekWithLip, on: screen)
        let widest = IslandLayout.metrics(for: .widerFlankedPeekWithLip, on: screen)
        #expect(IslandShapeMetrics.union(wide, widest) == widest)
    }

    /// The second constant is sized to power's phrases and the first to a HUD's nouns, so they are
    /// two numbers and not one — see `IslandLayout.widerFlankedWidthGrowth`. A change that made them
    /// equal would mean one of the two kinds is being drawn in a sliver sized for the other's words.
    @Test("the widest island is the cutout plus its own constant, split evenly")
    func widestWidthIsItsOwnConstant() {
        let rest = IslandLayout.metrics(for: .widerFlankedRest, on: screen)
        #expect(rest.bodySize.width == 185 + IslandLayout.widerFlankedWidthGrowth)
        #expect(IslandLayout.widerFlankedFlankWidth == IslandLayout.widerFlankedWidthGrowth / 2)
        #expect(IslandLayout.widerFlankedWidthGrowth > IslandLayout.wideFlankedWidthGrowth)
    }

    /// The hover region is the largest state reachable without another click, and on a wide island
    /// that is a wide peek. Sized to the standard flanks instead, ~56pt of lit island either side
    /// would sit outside the watched rect and the 100ms watchdog would read a pointer resting on it
    /// as having left — the oscillation `hoverRegion` is written around.
    @Test("the hover region follows the span")
    func hoverRegionFollowsTheSpan() {
        let panel = IslandLayout.panelFrame(for: screen).size
        let standard = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .standard, on: screen, in: panel
        )
        let wide = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .wide, on: screen, in: panel
        )
        #expect(wide.width > standard.width)
        #expect(wide.contains(standard))

        let peeked = IslandLayout.metrics(for: .wideFlankedPeek, on: screen)
        #expect(wide.width >= IslandShapeGeometry.boundingSize(for: peeked).width)

        // And one span further out, which is where power puts it.
        let widest = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .wider, on: screen, in: panel
        )
        #expect(widest.width > wide.width)
        #expect(widest.contains(wide))

        let widestPeek = IslandLayout.metrics(for: .widerFlankedPeek, on: screen)
        #expect(widest.width >= IslandShapeGeometry.boundingSize(for: widestPeek).width)
    }
}
