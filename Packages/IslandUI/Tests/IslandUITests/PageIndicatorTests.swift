import CoreGraphics
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The strip of dots at the bottom of the open island, and the height it costs.
///
/// It replaced the switcher row, and these are that row's height invariants — the ones that were
/// about *a strip at the bottom of the island* rather than about chips. The row's own tests (its
/// overflow counter, the reserved settings chip, the roster's order) went with it.
@Suite("The page indicator")
struct PageIndicatorTests {

    /// `islandPath` tracks a settled shape, so a strip whose height followed its contents would move
    /// the island's bottom edge — and the clickable region with it.
    @Test("the strip's height is a constant, not a function of what is in it")
    func heightIsConstant() {
        #expect(IslandPageIndicatorLayout.height
                == IslandPageIndicatorLayout.dotSide
                + IslandPageIndicatorLayout.topPadding
                + IslandPageIndicatorLayout.bottomPadding)
    }

    /// The whole argument for dots over chips: the open island gives the difference back to whatever
    /// it is showing. The row was 42pt.
    @Test("the strip is shorter than the chip row it replaced")
    func shorterThanTheChipRow() {
        #expect(IslandPageIndicatorLayout.height < 42)
    }

    @Test("the strip makes the open island taller, by exactly its own height")
    func addsItsHeightToTheIsland() {
        let without = IslandLayout.expandedHeight(contentHeight: 80, cutoutHeight: 32)
        let with = IslandLayout.expandedHeight(
            contentHeight: 80, cutoutHeight: 32, pageIndicatorHeight: IslandPageIndicatorLayout.height)
        #expect(with - without == IslandPageIndicatorLayout.height)
    }

    @Test("the strip also grows the default height, which no content asked for")
    func growsTheDefaultHeight() {
        let without = IslandLayout.expandedHeight(contentHeight: nil, cutoutHeight: 32)
        let with = IslandLayout.expandedHeight(
            contentHeight: nil, cutoutHeight: 32, pageIndicatorHeight: IslandPageIndicatorLayout.height)
        #expect(without == IslandLayout.expandedBodySize.height)
        #expect(with - without == IslandPageIndicatorLayout.height)
    }

    @Test("the tallest content plus the strip still fits inside the panel")
    func tallestContentPlusStripFits() {
        let tallest = IslandLayout.maxExpandedBodySize.height
        let height = IslandLayout.expandedHeight(
            contentHeight: 1000, cutoutHeight: 32, pageIndicatorHeight: IslandPageIndicatorLayout.height)
        #expect(height == tallest)
        #expect(IslandLayout.expandedBodySize.height + IslandPageIndicatorLayout.height <= tallest)
    }

    /// The dot is the picture; the target is the control. A 6pt circle is not something a pointer
    /// that has travelled into the notch can be expected to hit.
    @Test("the hit target is far larger than the dot, and does not widen the island")
    func targetIsLargerThanTheDot() {
        #expect(IslandPageIndicatorLayout.targetSide > IslandPageIndicatorLayout.dotSide)
        #expect(IslandPageIndicatorLayout.targetSide >= 22)
    }

    @Test("the row is as wide as its targets and the gaps between them")
    func widthIsTargetsPlusGaps() {
        let count = IslandPage.allCases.count
        #expect(IslandPageIndicatorLayout.width(pageCount: count)
                == CGFloat(count) * IslandPageIndicatorLayout.targetSide
                + CGFloat(count - 1) * IslandPageIndicatorLayout.dotSpacing)
        #expect(IslandPageIndicatorLayout.width(pageCount: 0) == 0)
    }

    /// It has to fit the body it is drawn in, with room either side.
    @Test("the whole strip fits across the open island")
    func stripFitsTheBody() {
        #expect(IslandPageIndicatorLayout.width(pageCount: IslandPage.allCases.count)
                < IslandLayout.expandedBodySize.width)
    }
}

@MainActor
@Suite("The page indicator on the island")
struct PageIndicatorIslandTests {

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    /// **The regression the unconditional strip exists to make impossible.** The switcher row was
    /// drawn only when something was on stage, and `AppDelegate.pageIndicatorHeight` had to answer
    /// that question identically or a strip was drawn where no height was reserved. The pages are
    /// fixed, so an open island always has three of them and always says which one you are on.
    @Test("an island with nothing on stage still wears the strip")
    func emptyIslandStillWearsTheStrip() {
        let m = model()
        #expect(m.chips.isEmpty)
        #expect(m.hasPageIndicator)
    }

    @Test("the strip is worn for as long as the island is open")
    func wornWhileOpen() {
        let m = model()
        m.setExpanded(true, reduceMotion: true)
        #expect(m.form == .expandedWithPageIndicator)

        m.setHovering(true, reduceMotion: true)
        #expect(m.form == .expandedWithPageIndicator)

        // The pointer leaving takes the strip nowhere. It leaves with the island, at the close.
        m.setHovering(false, reduceMotion: true)
        #expect(m.form == .expandedWithPageIndicator)

        m.setExpanded(false, reduceMotion: true)
        #expect(!m.form.showsPageIndicator)
    }

    /// A closed island has nowhere to draw a strip.
    @Test("a peeking island wears no strip")
    func peekWearsNoStrip() {
        let m = model()
        m.setHovering(true, reduceMotion: true)
        #expect(m.presentation == .peek)
        #expect(!m.form.showsPageIndicator)
    }

    /// Stowed is off screen, not merely small.
    @Test("a stowed island wears no strip")
    func stowedWearsNoStrip() {
        let m = model()
        m.setStowed(true, reduceMotion: true)
        #expect(!m.hasPageIndicator)
    }

    /// The body the page is laid out in is the island's, less the strip — so a page anchored to the
    /// bottom of its box does not draw underneath the dots.
    ///
    /// Built with a real shape table rather than the empty one the other tests use: `contentBodySize`
    /// subtracts from `contentMetrics`, and an island with no metrics has a zero body to subtract
    /// from, which would pass this for the wrong reason.
    @Test("the strip is taken out of the body the page is given")
    func bodyLeavesRoomForTheStrip() {
        let open = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 200),
            topCornerRadius: 0,
            bottomCornerRadius: 22
        )
        let m = IslandScreenModel(
            metricsByForm: [.expanded: open, .expandedWithPageIndicator: open],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        m.setExpanded(true, reduceMotion: true)
        #expect(m.contentMetrics.bodySize.height == 200)
        #expect(m.contentBodySize.height == 200 - IslandPageIndicatorLayout.height)
    }

    /// The month is a drill-down from home rather than one of the three pages, so the dots would be
    /// answering a question about somewhere the user is not — and a page turn is refused while it is
    /// up, so they would be a control that does nothing when pressed.
    @Test("an island showing the month wears no strip")
    func theMonthWearsNoStrip() {
        let m = model()
        let glance = GlanceModel()
        m.glance = glance
        m.setExpanded(true, reduceMotion: true)
        #expect(m.form == .expandedWithPageIndicator)

        glance.isShowingSchedule = true
        #expect(!m.hasPageIndicator)
        #expect(m.form == .expanded)

        glance.isShowingSchedule = false
        #expect(m.form == .expandedWithPageIndicator)
    }

    /// **The two answers this replaced a constant with, and why they cannot drift.** The strip's
    /// height reaches the shape through `IslandForm.showsPageIndicator` — `IslandLayout.metrics`
    /// adds it only to forms that wear the row — and the room reserved inside the body is
    /// `contentShowsPageIndicator`. Both are this one property read twice, so a strip the island
    /// grew for but reserved no height for is not expressible.
    @Test("the month gives the strip's height back to the body it takes it from")
    func theMonthReclaimsTheStrip() {
        let screen = IslandScreen(
            id: 1, name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            backingScaleFactor: 2,
            notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        )
        let table = Dictionary(uniqueKeysWithValues: IslandForm.allCases.map {
            ($0, IslandLayout.metrics(
                for: $0,
                on: screen,
                expandedContentHeight: GlanceScheduleLayout.contentHeight,
                expandedContentWidth: GlanceScheduleLayout.bodyWidth,
                pageIndicatorHeight: IslandPageIndicatorLayout.height
            ))
        })
        let m = IslandScreenModel(
            metricsByForm: table,
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        let glance = GlanceModel()
        m.glance = glance
        m.setExpanded(true, reduceMotion: true)
        let withStrip = m.contentMetrics.bodySize.height

        glance.isShowingSchedule = true
        m.setShowingGlanceSchedule(true, reduceMotion: true)
        // The island is shorter by exactly the strip, and the body inside it is not shortened
        // again: nothing is drawn there any more.
        #expect(withStrip - m.contentMetrics.bodySize.height == IslandPageIndicatorLayout.height)
        #expect(m.contentBodySize.height == m.contentMetrics.bodySize.height)
        // And wider, because the grid asked for it.
        #expect(m.contentMetrics.bodySize.width == GlanceScheduleLayout.bodyWidth)
    }

    /// A model with no page model injected draws home and cannot be turned — §3's layering test:
    /// this package must work with nothing wired.
    @Test("with no page model injected the island draws home")
    func defaultsToHomeWithNothingInjected() {
        let m = model()
        #expect(m.page == nil)
        #expect(m.currentPage == .home)
    }

    @Test("an injected page model is what the island reads")
    func readsTheInjectedPage() {
        let m = model()
        let pages = IslandPageModel()
        m.page = pages
        pages.go(to: .weather)
        #expect(m.currentPage == .weather)
    }
}
