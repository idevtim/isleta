import AppKit
import CoreGraphics
import Testing

@testable import IslandKit

/// The hit-region invariant, stated for the transition the shelf actually causes.
///
/// `PeekTests` proves that `IslandShapeMetrics.union(start, end)` contains every shape between two
/// forms. The shelf leans on a *different* rule, the one `AppDelegate.transition` applies to every
/// change: the region is widened to the union of where the island **is** and the **maximal** forms,
/// whatever the transition is actually heading for. That is what makes a drop arriving mid-grow
/// safe, and it is what a drag entering the island relies on — the island opens under a pointer
/// that already has a file on it, and `performDragOperation` only reaches us if the drop point is
/// inside `islandPath` at the moment the mouse is released, which can be any frame of the morph.
///
/// **"Maximal" is three forms, not one, and the list is the point of this suite.** The open island
/// contains most of the family and not all of it: `flankedPeekWithLip` can out-reach it downward at
/// the ceiling of the size settings, and `widerFlankedPeekWithLip` out-reaches it sideways on every
/// Mac (`IslandLayout.widerFlankedWidthGrowth` is 274 against an open island of 368). Each is named
/// in `AppDelegate.transition` for that reason, and this is what fails if one is dropped. The widest
/// span contains the wide one, which is why the list names the outer of the two and not both.
///
/// A superset is unreachable and therefore harmless: the window server has already routed drags
/// over transparent pixels elsewhere. A subset is the failure — a drop landing on lit island pixels
/// that we reject does *not* fall through to the app underneath (see `IslandDragAndDrop`), so the
/// file goes nowhere at all.
@Suite("Shelf dragging")
struct ShelfDragTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    /// Every transition the shelf can cause, against the rule the app shell actually applies.
    ///
    /// Parameterised over all 25 ordered pairs rather than over the four the shelf uses today,
    /// because the island can be in any form when a drag arrives — resting, peeking under the
    /// pointer that is carrying the file, flanked because Now Playing is up, or already open.
    @Test("widening to the maximal forms covers every shape the island passes through",
          arguments: IslandForm.allCases, IslandForm.allCases)
    func widenedToExpandedIsASuperset(from: IslandForm, to: IslandForm) {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let start = IslandLayout.metrics(for: from, on: screen)
        let end = IslandLayout.metrics(for: to, on: screen)

        // Exactly the three `widenHitRegionForTransition` calls `AppDelegate.transition` makes, in
        // order, each a union with what is already there.
        let widened = path(
            [IslandForm.expanded, .flankedPeekWithLip, .widerFlankedPeekWithLip]
                .map { IslandLayout.metrics(for: $0, on: screen) }
                .reduce(start, IslandShapeMetrics.union),
            in: panelSize
        )

        for progress in [0.0, 0.15, 0.35, 0.5, 0.65, 0.85, 1.0] as [CGFloat] {
            let intermediate = IslandShapeMetrics.lerp(from: start, to: end, progress: progress)
            let escaped = pointsEscaping(path(intermediate, in: panelSize), from: widened)
            #expect(
                escaped == 0,
                "\(escaped) points of \(from) → \(to) at \(progress) fell outside the widened region"
            )
        }
    }

    /// The drag opens the island by expanding it, so the shape it settles at is one the shape
    /// family already has. This is the claim that keeps the proof above sufficient: if the shelf
    /// ever introduced a new form, the widened region would stop being computed from a form in
    /// this list and none of the sampling above would cover it.
    @Test("the shelf introduces no new island shape")
    func noNewForms() {
        // Thirteen shapes now. Six is the switcher row's, asked for by `hasPageIndicator`; seven is
        // the track lip's, asked for by the pointer landing on an album cover; the last six are the
        // two spans for an activity that spells itself in the slivers (`ActivityKind.flankSpan`) —
        // three shapes for a HUD's noun and three for power's phrase. The shelf asks for none of
        // them: it opens the island, which is still the plain `.expanded` form as far as this family
        // is concerned, and a shelf holding items is `.standard` flanked because a tray glyph is not
        // a word.
        #expect(IslandForm.allCases.count == 13)
        #expect(IslandForm.resolve(isHovering: false, isExpanded: true, flanks: .standard) == .expanded)
        // A shelf with items in it puts the collapsed island in the flanked forms and nowhere else.
        #expect(IslandForm.resolve(isHovering: false, isExpanded: false, flanks: .standard) == .flankedRest)
        #expect(IslandForm.resolve(isHovering: true, isExpanded: false, flanks: .standard) == .flankedPeek)
    }

    /// A drag out of the island must not be able to trash or relocate the user's original: the
    /// shelf holds a *reference* to a file that still lives where they put it, and a destination
    /// that chose `.move` would relocate it in response to a gesture the user reads as "give a copy
    /// of this to that app".
    @Test("a drag out of the shelf can never move or delete the original")
    func dragOutIsNonDestructive() {
        let operations = IslandDragHandlers.dragOutOperations
        #expect(operations.contains(.copy))
        // `.generic` is included because a great many destinations that simply open what they are
        // given ask for it and nothing else.
        #expect(operations.contains(.generic))
        #expect(!operations.contains(.move))
        #expect(!operations.contains(.delete))
    }

    // MARK: - Helpers

    private func path(_ metrics: IslandShapeMetrics, in panelSize: CGSize) -> CGPath {
        IslandShapeGeometry.path(
            metrics: metrics,
            bodyOrigin: IslandLayout.bodyOrigin(for: metrics, in: panelSize)
        )
    }

    private func pointsEscaping(_ drawn: CGPath, from region: CGPath) -> Int {
        let bounds = drawn.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        var escaped = 0
        for xStep in 0...120 {
            for yStep in 0...48 {
                let point = CGPoint(
                    x: bounds.minX + bounds.width * CGFloat(xStep) / 120,
                    y: bounds.minY + bounds.height * CGFloat(yStep) / 48
                )
                if drawn.contains(point), !region.contains(point) { escaped += 1 }
            }
        }
        return escaped
    }
}
