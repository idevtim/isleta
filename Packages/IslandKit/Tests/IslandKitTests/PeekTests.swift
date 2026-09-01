import CoreGraphics
import Testing

@testable import IslandKit

@Suite("Peek")
struct PeekTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    @Test("peek grows past the notch on every free edge")
    func peekGrows() {
        let rest = IslandLayout.restMetrics(for: screen)
        let peek = IslandLayout.peekMetrics(for: screen)

        #expect(peek.bodySize.width > rest.bodySize.width)
        #expect(peek.bodySize.height > rest.bodySize.height)
        // At rest the island is exactly the notch, so any growth at all is growth into lit pixels.
        #expect(rest.bodySize == screen.notch.rect.size)
    }

    /// Peek is an invitation, not a result. If it ever grows enough to read as "expanded" the click
    /// has nothing left to do.
    @Test("peek stays subtle")
    func peekIsSubtle() {
        let rest = IslandLayout.restMetrics(for: screen)
        let peek = IslandLayout.peekMetrics(for: screen)

        #expect(peek.bodySize.width - rest.bodySize.width <= 20)
        #expect(peek.bodySize.height - rest.bodySize.height <= 12)
        #expect(peek.bodySize.width < IslandLayout.maxExpandedBodySize.width / 2)
    }

    /// The invariant `IslandHitTestView` depends on, stated over the whole shape family rather than
    /// over one pair of states: the region a transition is widened to must contain every shape the
    /// island passes through. A superset is unreachable and therefore harmless — the window server
    /// has already routed those clicks elsewhere; a subset swallows clicks that land on visible
    /// island pixels, so they neither open the island nor reach the app underneath.
    ///
    /// **Why this is parameterised over every ordered pair.** It used to be a single assertion that
    /// the peek shape contains the rest shape, which was sound while the island's states were
    /// totally ordered by size: each was inset from the next on all four sides, so "the larger
    /// endpoint" was a real thing and `widenHitRegionForTransition` could pick it by height. The
    /// flanked resting island breaks that order — it is 265x32 where the unflanked peek is 197x40,
    /// wider *and* shorter — so for that pair neither endpoint contains the other and picking the
    /// taller one silently chose a subset across 68pt of lit island. The invariant that survives is
    /// about `IslandShapeMetrics.union`, which is a superset of both endpoints by construction, and
    /// it has to hold for every pair because the island can now travel between any two forms.
    @Test("the widened region contains every state between any two forms",
          arguments: IslandForm.allCases, IslandForm.allCases)
    func transitionRegionIsASuperset(from: IslandForm, to: IslandForm) {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let start = IslandLayout.metrics(for: from, on: screen)
        let end = IslandLayout.metrics(for: to, on: screen)
        let widened = path(IslandShapeMetrics.union(start, end), in: panelSize)

        for progress in [0.0, 0.15, 0.35, 0.5, 0.65, 0.85, 1.0] as [CGFloat] {
            let intermediate = IslandShapeMetrics.lerp(from: start, to: end, progress: progress)
            let escaped = pointsEscaping(path(intermediate, in: panelSize), from: widened)
            #expect(
                escaped == 0,
                "\(escaped) points of \(from) → \(to) at \(progress) fell outside the widened region"
            )
        }
    }

    /// The reason the old rule has to go, pinned down rather than described. If this ever starts
    /// failing, "whichever endpoint is taller" has become safe again and the union is no longer
    /// earning its keep — which would mean the flanked shapes had stopped being wider than the
    /// unflanked peek, i.e. the feature had been undone.
    @Test("no single endpoint contains the other across a flank change")
    func flankedRestAndPeekAreUnordered() {
        let flankedRest = IslandLayout.metrics(for: .flankedRest, on: screen)
        let peek = IslandLayout.peekMetrics(for: screen)

        #expect(flankedRest.bodySize.width > peek.bodySize.width)
        #expect(flankedRest.bodySize.height < peek.bodySize.height)

        // The taller endpoint, which is what `widenHitRegionForTransition` used to choose.
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let escaped = pointsEscaping(path(flankedRest, in: panelSize), from: path(peek, in: panelSize))
        #expect(escaped > 0, "the taller endpoint now contains the wider one; the union may be redundant")
    }

    /// Flanked rest and flanked peek are ordered the same way rest and peek are — the flank growth
    /// is a constant added to both, so peek's growth is untouched by it. This is what keeps a hover
    /// on a flanked island as ordinary a transition as a hover on an empty one.
    @Test("the flanked peek shape contains the flanked rest shape")
    func flankedPeekContainsFlankedRest() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let rest = IslandLayout.metrics(for: .flankedRest, on: screen)
        let peek = IslandLayout.metrics(for: .flankedPeek, on: screen)
        let escaped = pointsEscaping(path(rest, in: panelSize), from: path(peek, in: panelSize))
        #expect(escaped == 0, "\(escaped) points of the flanked resting island fall outside the flanked peek")
    }

    /// The flanked island has to be wide enough to draw in, or it is 80pt of black for nothing.
    /// 34pt is `ActivitySlotLayout.minimumFlankWidth` — named there because only IslandUI knows what
    /// a glyph costs, and restated here because only IslandKit decides the width. `FlankedLayoutTests`
    /// in IslandUI is where the two are checked against each other.
    @Test("a flanked island has a sliver each side wide enough for a glyph")
    func flankedRestAffordsAFlank() {
        let rest = IslandLayout.metrics(for: .flankedRest, on: screen)
        let flank = (rest.bodySize.width - screen.notch.rect.width) / 2

        #expect(flank == IslandLayout.flankedFlankWidth)
        #expect(flank >= 34)
        // Still the notch growing, not a bar: under half again as wide as the cutout, and clearly
        // narrower than the open island.
        #expect(rest.bodySize.width < screen.notch.rect.width * 1.5)

        // Compared against the open island's *drawn* width, not its body. The open island's top
        // corners flare outside `bodySize` into the ceiling, so the body alone understates how much
        // wider it actually reads — and the point of this assertion is that opening is a visible
        // change, which is a question about what is drawn.
        let openWidth = IslandShapeGeometry.boundingSize(
            for: IslandLayout.metrics(for: .expanded, on: screen)
        ).width
        #expect(rest.bodySize.width < openWidth * 0.75)
    }

    /// Growing downward instead of sideways would afford the *body* slot
    /// (`ActivitySlotLayout.minimumBodyHeight`, 22pt) and hang a strip of text under the notch at
    /// rest. The flanked island is the cutout made wider and nothing else.
    @Test("flanking adds width and not height")
    func flankedRestKeepsTheCutoutsHeight() {
        let rest = IslandLayout.restMetrics(for: screen)
        let flankedRest = IslandLayout.metrics(for: .flankedRest, on: screen)
        let flankedPeek = IslandLayout.metrics(for: .flankedPeek, on: screen)
        let peek = IslandLayout.peekMetrics(for: screen)

        #expect(flankedRest.bodySize.height == rest.bodySize.height)
        #expect(flankedPeek.bodySize.height == peek.bodySize.height)
        #expect(flankedRest.bottomCornerRadius == rest.bottomCornerRadius)
    }

    /// The open island is 380pt wide with ~98pt of sliver either side; there is no wider shape for
    /// the flag to select. Letting it ride through would give one geometry two dictionary keys.
    @Test("the open island is never flanked")
    func expandedIgnoresFlanking() {
        #expect(IslandForm(presentation: .expanded, flanks: .standard) == IslandForm.expanded)
        #expect(
            IslandLayout.metrics(for: IslandForm(presentation: .expanded, flanks: .standard), on: screen)
                == IslandLayout.expandedMetrics(for: screen)
        )
        #expect(IslandForm.allCases.count == 13)
        #expect(IslandForm(presentation: .expanded, flanks: .wide) == IslandForm.expanded)
        #expect(IslandForm(presentation: .expanded, flanks: .wider) == IslandForm.expanded)
    }

    /// The sixth shape, and the two rules that keep it from multiplying the table further: only an
    /// open island can wear the row, and an open island is still never flanked.
    @Test("only the open island wears the switcher row")
    func switcherIsExpandedOnly() {
        #expect(IslandForm(presentation: .rest, showsPageIndicator: true) == IslandForm.rest)
        #expect(IslandForm(presentation: .peek, showsPageIndicator: true) == IslandForm.peek)
        #expect(IslandForm(presentation: .expanded, flanks: .standard, showsPageIndicator: true)
                == IslandForm.expandedWithPageIndicator)
        #expect(IslandForm.expandedWithPageIndicator != IslandForm.expanded)
        #expect(IslandForm.allCases.filter(\.showsPageIndicator) == [.expandedWithPageIndicator])
    }

    /// An open island with nothing to put in the row — a quiet one, or a stowed one — has to be
    /// exactly the shape it was before the row existed. That is what the plain `.expanded` form is
    /// for now that the row no longer comes and goes with the pointer.
    @Test("an open island with nothing in the row is unchanged by it")
    func expandedWithoutTheRowIsUnchanged() {
        #expect(
            IslandLayout.metrics(for: .expanded, on: screen, pageIndicatorHeight: 42)
                == IslandLayout.metrics(for: .expanded, on: screen, pageIndicatorHeight: 0)
        )
        #expect(
            IslandLayout.metrics(for: .expandedWithPageIndicator, on: screen, pageIndicatorHeight: 42).bodySize.height
                - IslandLayout.metrics(for: .expanded, on: screen, pageIndicatorHeight: 42).bodySize.height
                == 42
        )
    }

    /// Flanked-ness is resolved from the inputs the same way hovering and expansion are, so there
    /// is no state to get out of step with what is on stage.
    @Test("the form is derived from all three inputs")
    func formResolves() {
        #expect(IslandForm.resolve(isHovering: false, isExpanded: false, flanks: .none) == .rest)
        #expect(IslandForm.resolve(isHovering: false, isExpanded: false, flanks: .standard) == .flankedRest)
        #expect(IslandForm.resolve(isHovering: true, isExpanded: false, flanks: .standard) == .flankedPeek)
        // Expansion still wins, and still collapses the flank input.
        #expect(IslandForm.resolve(isHovering: true, isExpanded: true, flanks: .standard) == .expanded)
    }

    /// A spring can overshoot its target. The hover region has to tolerate that, or the island
    /// growing under a stationary pointer could hand itself a mouseExited and start oscillating.
    @Test("the hover region covers the island's largest state")
    func hoverRegionCoversPeek() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let hover = IslandLayout.hoverRegion(isExpanded: false, flanks: .none, on: screen, in: panelSize)
        let peek = IslandLayout.peekMetrics(for: screen)
        let peekBounds = IslandShapeGeometry.path(
            metrics: peek,
            bodyOrigin: IslandLayout.bodyOrigin(for: peek, in: panelSize)
        ).boundingBoxOfPath

        #expect(hover.contains(peekBounds) || hover == peekBounds)

        let rest = IslandLayout.restMetrics(for: screen)
        let restBounds = IslandShapeGeometry.path(
            metrics: rest,
            bodyOrigin: IslandLayout.bodyOrigin(for: rest, in: panelSize)
        ).boundingBoxOfPath
        #expect(hover.contains(restBounds))
    }

    @Test("notchless displays peek too")
    func synthesizedPeek() {
        let external = IslandScreen(
            id: 2, name: "External",
            frame: CGRect(x: -2001, y: 1117, width: 1920, height: 1080),
            backingScaleFactor: 2,
            notch: NotchResolver.resolve(
                screenFrame: CGRect(x: -2001, y: 1117, width: 1920, height: 1080),
                safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
            )
        )
        let rest = IslandLayout.restMetrics(for: external)
        let peek = IslandLayout.peekMetrics(for: external)
        #expect(peek.bodySize.width > rest.bodySize.width)
        #expect(peek.bodySize.height > rest.bodySize.height)
    }

    // MARK: - Helpers

    private func path(_ metrics: IslandShapeMetrics, in panelSize: CGSize) -> CGPath {
        IslandShapeGeometry.path(
            metrics: metrics,
            bodyOrigin: IslandLayout.bodyOrigin(for: metrics, in: panelSize)
        )
    }

    /// How many sampled points of `drawn` fall outside `region`. Sampling rather than solving:
    /// these are continuous-corner Béziers, and the question being asked is only ever "does any
    /// visible pixel land outside the region we accept clicks in".
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

@Suite("Expanded")
struct ExpandedTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    @Test("the island grows monotonically through its states")
    func statesGrow() {
        let rest = IslandLayout.metrics(for: .rest, on: screen)
        let peek = IslandLayout.metrics(for: .peek, on: screen)
        let expanded = IslandLayout.metrics(for: .expanded, on: screen)

        #expect(rest.bodySize.width < peek.bodySize.width)
        #expect(peek.bodySize.width < expanded.bodySize.width)
        #expect(rest.bodySize.height < peek.bodySize.height)
        #expect(peek.bodySize.height < expanded.bodySize.height)
    }

    /// §4.2: the panel is created once at the maximum expanded bounds and never resized. If a
    /// presentation could outgrow it the island would clip, and the fix would be the one thing the
    /// section forbids — animating the window frame.
    @Test("every form fits inside the fixed panel", arguments: IslandForm.allCases)
    func fitsInPanel(form: IslandForm) {
        let panel = IslandLayout.panelFrame(for: screen)
        let bounds = IslandLayout.bounds(for: form, on: screen, in: panel.size)

        #expect(bounds.minX >= -0.001)
        #expect(bounds.maxX <= panel.width + 0.001)
        #expect(bounds.maxY <= panel.height + 0.001)
        #expect(bounds.minY >= -0.001)
    }

    /// The top edge is against the bezel in every state. Rounding it would open a sliver of lit
    /// pixels between the island and the bezel and break the illusion instantly.
    @Test("the top edge stays flush in every state", arguments: IslandForm.allCases)
    func topStaysFlush(form: IslandForm) {
        #expect(IslandLayout.metrics(for: form, on: screen).topCornerRadius == 0)
    }

    /// The invariant `IslandHitTestView` relies on, now across all three states: the region used
    /// during a transition must contain every shape the island passes through, in either direction.
    @Test("the expanded shape contains every state below it",
          arguments: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] as [CGFloat])
    func expandedContainsEveryIntermediate(progress: CGFloat) {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let rest = IslandLayout.metrics(for: .rest, on: screen)
        let expanded = IslandLayout.metrics(for: .expanded, on: screen)

        let widened = IslandShapeGeometry.path(
            metrics: expanded, bodyOrigin: IslandLayout.bodyOrigin(for: expanded, in: panelSize))
        let intermediate = IslandShapeMetrics.lerp(from: rest, to: expanded, progress: progress)
        let drawn = IslandShapeGeometry.path(
            metrics: intermediate, bodyOrigin: IslandLayout.bodyOrigin(for: intermediate, in: panelSize))

        let bounds = drawn.boundingBoxOfPath
        var escaped = 0
        for xStep in 0...150 {
            for yStep in 0...60 {
                let point = CGPoint(
                    x: bounds.minX + bounds.width * CGFloat(xStep) / 150,
                    y: bounds.minY + bounds.height * CGFloat(yStep) / 60
                )
                if drawn.contains(point), !widened.contains(point) { escaped += 1 }
            }
        }
        #expect(escaped == 0, "\(escaped) drawn points fell outside the expanded region")
    }

    /// Too small and the island growing under a stationary pointer hands itself a mouseExited and
    /// oscillates; too large and it stays peeked with the pointer far away over transparent pixels.
    @Test("the hover region tracks the largest state reachable without another click")
    func hoverRegionTracksExpansion() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let collapsed = IslandLayout.hoverRegion(isExpanded: false, flanks: .none, on: screen, in: panelSize)
        let opened = IslandLayout.hoverRegion(isExpanded: true, flanks: .none, on: screen, in: panelSize)

        #expect(collapsed == IslandLayout.bounds(for: .peek, on: screen, in: panelSize))
        // The open island's region is its **blur**, not its outline: since the pointer leaving is
        // what closes the island, the region watched for it leaving is the region it is allowed to
        // rest in, and that is the ring of blur the island draws around itself.
        #expect(opened == IslandLayout.blurRegion(isExpanded: true, on: screen, in: panelSize))
        #expect(opened.contains(IslandLayout.bounds(for: .expanded, on: screen, in: panelSize)))
        #expect(opened.contains(collapsed))
    }

    /// The blur is a **superset** of the open island on the three sides it has screen to reach into,
    /// and reaches nowhere above it — the island hangs from the top edge, so there is nothing up
    /// there to blur.
    @Test("the blur surrounds the open island and stops at the ceiling")
    func blurSurroundsTheOpenIsland() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let island = IslandLayout.bounds(for: .expanded, on: screen, in: panelSize)
        let blur = IslandLayout.blurRegion(isExpanded: true, on: screen, in: panelSize)

        #expect(blur.minX == island.minX - IslandLayout.blurSpread)
        #expect(blur.maxX == island.maxX + IslandLayout.blurSpread)
        #expect(blur.maxY == island.maxY + IslandLayout.blurSpread)
        #expect(blur.minY == island.minY, "the top edge is the top of the screen")
    }

    /// **A closed island has no blur, and must accept no clicks around itself.** Nothing is painted
    /// out there, so a region left behind would be one the window server never routes to us — until
    /// the day something else does paint there, at which point it is a click that lands nowhere.
    @Test("a closed island has no blur at all")
    func closedIslandHasNoBlur() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        #expect(IslandLayout.blurRegion(isExpanded: false, on: screen, in: panelSize) == .zero)
    }

    /// The blur never leaves the panel, which is never resized (§4.2). `blurSpread` is bounded by
    /// `panelMargin` for exactly that: even were the open island ever to take the widest body the
    /// panel is built for, the ring would still fit rather than being clipped on one side and not
    /// the other — the island is centerd on the notch, and the notch is not centerd on the display.
    ///
    /// The tallest island is the one worth asserting, because that is the dimension the open island
    /// actually varies in: `IslandSizing.widthAdjustment` is collapsed-only, so the open body's
    /// width is `expandedBodySize.width` at every setting, while its height follows its content up
    /// to `maxExpandedBodySize.height`.
    @Test("the blur fits inside the panel at the tallest island the content can ask for")
    func blurFitsThePanel() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let blur = IslandLayout.blurRegion(
            isExpanded: true,
            on: screen,
            in: panelSize,
            expandedContentHeight: IslandLayout.maxExpandedBodySize.height
        )
        #expect(blur.minX >= 0)
        #expect(blur.maxX <= panelSize.width)
        #expect(blur.maxY <= panelSize.height)
        #expect(IslandLayout.blurSpread <= IslandLayout.panelMargin)
    }

    /// The flanked island's largest state reachable without another click is the *flanked* peek,
    /// which is 80pt wider than the unflanked one. Tracking the unflanked peek instead would leave
    /// 40pt of lit island either side outside the watched region: the watchdog would read a pointer
    /// resting on a visible flank as having left, collapse, and — with the pointer still there —
    /// re-enter. Tracking the flanked peek unconditionally has the opposite fault, and holds a peek
    /// open over 40pt of transparent pixels on an island with nothing in its flanks.
    @Test("the hover region follows flanked-ness as well as expansion")
    func hoverRegionTracksFlanking() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let unflanked = IslandLayout.hoverRegion(isExpanded: false, flanks: .none, on: screen, in: panelSize)
        let flanked = IslandLayout.hoverRegion(isExpanded: false, flanks: .standard, on: screen, in: panelSize)
        let opened = IslandLayout.hoverRegion(isExpanded: true, flanks: .standard, on: screen, in: panelSize)

        #expect(flanked == IslandLayout.bounds(for: .flankedPeek, on: screen, in: panelSize))
        #expect(flanked.contains(unflanked))

        // Both peeks flare into the ceiling now — peek is wider than the cutout whether or not it is
        // flanked — so the flare cancels and the difference is exactly the flanking. Asserted
        // against the drawn width rather than the body, because the region has to cover the lit
        // corners: one stopping at the body would count a pointer resting on a flare as having left
        // the island.
        let flare = IslandShapeGeometry.flareExtent(
            for: IslandLayout.metrics(for: .flankedPeek, on: screen)
        )
        #expect(flare > 0)
        #expect(flanked.width == unflanked.width + IslandLayout.flankedWidthGrowth)

        // Every collapsed shape the island can be in while flanked has to be inside it, or the
        // island growing under a stationary pointer hands itself a mouseExited.
        #expect(flanked.contains(IslandLayout.bounds(for: .flankedRest, on: screen, in: panelSize)))
        #expect(flanked.contains(IslandLayout.bounds(for: .rest, on: screen, in: panelSize)))

        // An open island is open however it got there — and its region is its blur either way.
        #expect(opened == IslandLayout.blurRegion(isExpanded: true, on: screen, in: panelSize))
    }
}

/// The open island's *width*, which was a constant until the month grid asked for more.
///
/// Everything here is about the one direction this parameter is allowed to move the island. It can
/// only widen it: `NowPlayingExpandedLayout` computes its transport row against
/// `IslandLayout.expandedBodySize.width` as a constant rather than against the body it is handed,
/// so a narrower island would draw that row outside the mask — a button visibly shaved and
/// invisibly unhittable.
@Suite("The open island's width")
struct ExpandedWidthTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    @Test("nobody asking is the default width")
    func nilIsTheDefault() {
        #expect(IslandLayout.expandedWidth(contentWidth: nil) == IslandLayout.expandedBodySize.width)
        #expect(IslandLayout.metrics(for: .expanded, on: screen).bodySize.width
                == IslandLayout.expandedBodySize.width)
    }

    @Test("a surface that asks for more gets it")
    func aWiderSurfaceWidensTheIsland() {
        let wide = IslandLayout.metrics(for: .expanded, on: screen, expandedContentWidth: 440)
        #expect(wide.bodySize.width == 440)
    }

    /// The clamp that keeps this parameter out of `NowPlayingExpandedLayout` entirely.
    @Test("a surface that asks for less is given the default anyway", arguments: [CGFloat(0), -100, 200, 367])
    func itNeverNarrowsTheIsland(asked: CGFloat) {
        #expect(IslandLayout.expandedWidth(contentWidth: asked) == IslandLayout.expandedBodySize.width)
    }

    /// §4.2: the panel is created once at `maxExpandedBodySize` and never resized, so a body wider
    /// than it would be drawn clipped and hit-tested against a path running off the side.
    @Test("anything absurd is clamped to the widest body the panel was built for")
    func itIsClampedToTheCeiling() {
        #expect(IslandLayout.expandedWidth(contentWidth: 10_000)
                == IslandLayout.maxExpandedBodySize.width)
    }

    /// Every width a surface in this app actually asks for, drawn inside the panel with its margins
    /// intact — the flare included, which is the part that is not the body's own width. See
    /// `IslandLayout.expandedWidth` on why the ceiling itself is a guard rail rather than a size.
    @Test("a widened island is drawn inside the panel", arguments: [CGFloat(368), 440, 500])
    func itFitsThePanel(width: CGFloat) {
        let panel = IslandLayout.panelFrame(for: screen)
        let bounds = IslandLayout.bounds(
            for: .expanded, on: screen, in: panel.size, expandedContentWidth: width)
        #expect(bounds.minX >= -0.001)
        #expect(bounds.maxX <= panel.width + 0.001)
    }

    /// Only the expanded form reads it. A collapsed island that widened with the month behind it
    /// would be a shape nobody asked for, and it would break the ordering below.
    @Test("no collapsed form moves when a surface asks for width", arguments: IslandForm.allCases)
    func collapsedFormsAreUntouched(form: IslandForm) {
        let plain = IslandLayout.metrics(for: form, on: screen)
        let wide = IslandLayout.metrics(for: form, on: screen, expandedContentWidth: 440)
        if form.presentation == .expanded {
            #expect(wide.bodySize.width > plain.bodySize.width)
        } else {
            #expect(wide.bodySize == plain.bodySize)
        }
    }

    /// The ordering `IslandHitTestView` depends on, restated for the widened island — and it is an
    /// ordering over the **maximal forms**, not over the open one alone.
    ///
    /// A widened open island contains every *collapsed* shape it could have come from, which is what
    /// the month grid asking for 440pt has to be true of. It does not contain the two flanked spans
    /// that spell themselves: those out-reach it sideways on every Mac, which is exactly why
    /// `AppDelegate.transition` names `.widerFlankedPeekWithLip` beside `.expanded` rather than
    /// trusting the open island to cover the family. `TrackLipTests` holds the whole of that rule;
    /// this pins the half that belongs to the width parameter.
    @Test("a widened open island still contains every state below it", arguments: IslandForm.allCases)
    func expandedStaysTheLargest(form: IslandForm) {
        let expanded = IslandLayout.metrics(for: .expanded, on: screen, expandedContentWidth: 440)
        let other = IslandLayout.metrics(for: form, on: screen, expandedContentWidth: 440)
        let widened = IslandShapeMetrics.union(
            expanded,
            IslandLayout.metrics(for: .widerFlankedPeekWithLip, on: screen, expandedContentWidth: 440)
        )
        #expect(other.bodySize.width <= widened.bodySize.width + 0.001)
        if form.flanks < .wide {
            #expect(other.bodySize.width <= expanded.bodySize.width + 0.001,
                    "\(form) draws no word and must fit the island it opens into")
        }
    }

    /// The hover region is the open island's blur ring, so a region built at the default width while
    /// a wider island is drawn would read a pointer resting on real island as having left, and close
    /// it under the hand.
    @Test("the hover region follows the width the island is drawn at")
    func theHoverRegionFollowsTheWidth() {
        let panelSize = IslandLayout.panelFrame(for: screen).size
        let plain = IslandLayout.hoverRegion(
            isExpanded: true, flanks: .none, on: screen, in: panelSize)
        let wide = IslandLayout.hoverRegion(
            isExpanded: true, flanks: .none, on: screen, in: panelSize, expandedContentWidth: 440)
        #expect(abs((wide.width - plain.width) - (440 - IslandLayout.expandedBodySize.width)) < 0.001)
        #expect(wide.contains(CGPoint(x: plain.maxX + 1, y: plain.midY)))
    }
}
