import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The schedule surface's geometry. Its whole contract with the island is that the height is a
/// constant, so that is what most of this pins.
@Suite("The schedule surface's layout")
struct GlanceScheduleLayoutTests {

    @Test("the height does not depend on the day, the events, or how they split")
    func theHeightIsAConstant() {
        // The open island's height is agreed *before* the transition, through
        // `IslandController.expandedContentHeight`, and `islandPath` has to track a shape that has
        // settled. `GlanceScheduleLayout.contentHeight` takes no arguments at all, which is the
        // strongest possible statement of that — there is nothing for a stale flag to answer about,
        // which is the bug that shipped on the Up Next surface.
        #expect(GlanceScheduleLayout.contentHeight > 0)
        let again = GlanceScheduleLayout.contentHeight
        #expect(GlanceScheduleLayout.contentHeight == again)
    }

    @Test("it fits inside the island's ceiling, with the cutout taken off the top")
    func itFitsTheIsland() {
        // The panel is created once at `maxExpandedBodySize` and never resized, so a surface taller
        // than that is one the island cannot draw — it would be clipped by the panel rather than by
        // anything anybody chose.
        let cutout: CGFloat = 32
        #expect(GlanceScheduleLayout.contentHeight + cutout <= IslandLayout.maxExpandedBodySize.height)
    }

    @Test("both columns fit the height the surface asks for")
    func neitherColumnIsCut() {
        // `columnsHeight` is a `max` of the two rather than the winning number written out, so this
        // is the test that fails if a change to either column outgrows it.
        let left = GlanceScheduleLayout.dateBlockHeight
            + GlanceScheduleLayout.dateSpacing
            + CGFloat(GlanceScheduleLayout.maximumPills) * GlanceScheduleLayout.pillHeight
            + CGFloat(GlanceScheduleLayout.maximumPills - 1) * GlanceScheduleLayout.pillSpacing
            + GlanceScheduleLayout.overflowSpacing
            + GlanceScheduleLayout.overflowHeight
        let right = GlanceScheduleLayout.sectionHeaderHeight
            + GlanceScheduleLayout.sectionHeaderSpacing
            + GlanceScheduleLayout.entriesExtent(count: GlanceScheduleLayout.maximumEntries)
        #expect(GlanceScheduleLayout.columnsHeight >= left)
        #expect(GlanceScheduleLayout.columnsHeight >= right)
    }

    @Test("the island it asks for is wider than the default, and one the panel can draw")
    func itWidensTheIsland() {
        #expect(GlanceScheduleLayout.bodyWidth > IslandLayout.expandedBodySize.width)
        #expect(GlanceScheduleLayout.bodyWidth <= IslandLayout.maxExpandedBodySize.width)
        // `IslandLayout.expandedWidth` clamps, so a width past the ceiling would be silently
        // ignored — the columns would lay out at a width the island is not.
        #expect(IslandLayout.expandedWidth(contentWidth: GlanceScheduleLayout.bodyWidth)
                == GlanceScheduleLayout.bodyWidth)
    }

    @Test("the events column takes exactly what the date block leaves")
    func theColumnTakesTheRemainder() {
        let body = GlanceScheduleLayout.bodyWidth
        let expected = body - 2 * GlanceScheduleLayout.horizontalPadding
            - GlanceScheduleLayout.dateColumnWidth - GlanceScheduleLayout.columnSpacing
        #expect(GlanceScheduleLayout.eventColumnWidth(inBodyWidth: body) == expected)
        #expect((GlanceScheduleLayout.eventColumnWidth(inBodyWidth: body) ?? 0)
                >= GlanceScheduleLayout.minimumEventColumnWidth)
    }

    @Test("a collapsed or absurd width is answered with no column rather than a negative one")
    func degenerateWidthsAreSafe() {
        // SwiftUI lays a view out at zero before it has a size, and the island rebuilds its panels
        // on every display change.
        for width in [CGFloat(0), -100, 10, 240] {
            #expect(GlanceScheduleLayout.eventColumnWidth(inBodyWidth: width) == nil)
        }
    }

    @Test("an entry list is its rows and the gaps between them")
    func entriesMeasureWhatTheyDraw() {
        #expect(GlanceScheduleLayout.entriesExtent(count: 0) == 0)
        #expect(GlanceScheduleLayout.entriesExtent(count: 1) == GlanceScheduleLayout.entryHeight)
        #expect(GlanceScheduleLayout.entriesExtent(count: 3)
                == 3 * GlanceScheduleLayout.entryHeight + 2 * GlanceScheduleLayout.entrySpacing)
        // Negative counts are what a subtraction produces when two caps disagree.
        #expect(GlanceScheduleLayout.entriesExtent(count: -2) == 0)
    }
}

/// How two days are fitted into a fixed column — the product rule, checked without a screen.
@Suite("Fitting today and tomorrow")
struct GlanceSchedulePlanTests {

    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(
        _ id: String, hour: Int = 9, allDay: Bool = false, on day: Date? = nil
    ) -> GlanceEvent {
        let base = (day ?? self.day).addingTimeInterval(Double(hour) * 3600)
        return GlanceEvent(
            id: id, title: id, start: base, end: base.addingTimeInterval(1800), isAllDay: allDay
        )
    }

    @Test("today's all-day events are the pills, capped, and the rest are counted")
    func allDayBecomesPills() {
        let all = (0..<7).map { event("a\($0)", allDay: true) }
        let plan = GlanceSchedulePlan.plan(today: all, tomorrow: [])
        #expect(plan.pills.count == GlanceScheduleLayout.maximumPills)
        #expect(plan.pillOverflow == 7 - GlanceScheduleLayout.maximumPills)
        // An all-day event is not an hour, so it never appears in the right-hand column.
        #expect(plan.today.isEmpty)
    }

    @Test("today's timed events are listed in the order they happen")
    func todayIsOrdered() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("late", hour: 17), event("early", hour: 8), event("noon", hour: 12)],
            tomorrow: []
        )
        #expect(plan.today.map(\.id) == ["early", "noon", "late"])
        #expect(plan.overflow == 0)
        // What the heading does when tomorrow is empty is `anEmptyTomorrowSaysSo`'s question, not
        // this one's. It asserted `!showsTomorrow` here until 2026-08-31, which made a test about
        // *ordering* fail when the empty-day line was added — a second copy of somebody else's
        // rule, in the place least likely to be looked at when that rule changes.
    }

    @Test("tomorrow fills what today leaves")
    func tomorrowTakesTheRest() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("t1", hour: 9), event("t2", hour: 11)],
            tomorrow: [event("m1", hour: 9), event("m2", hour: 14)]
        )
        #expect(plan.today.count == 2)
        #expect(plan.showsTomorrow)
        #expect(plan.tomorrow.map(\.id) == ["m1", "m2"])
        #expect(plan.overflow == 0)
    }

    @Test("tomorrow's all-day events are one row, however many there are")
    func tomorrowsAllDayIsSummarised() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("t1", hour: 9)],
            tomorrow: (0..<5).map { event("m\($0)", allDay: true) } + [event("m.timed", hour: 17)]
        )
        // The count is the whole point of the row: five all-day events collapse into one line that
        // says five, rather than into five lines that would push the timed event out.
        #expect(plan.tomorrowAllDayCount == 5)
        #expect(plan.tomorrow.map(\.id) == ["m.timed"])
        #expect(plan.overflow == 0)
    }

    /// **Today first**, which is the rule the surface was built on: it is opened from today's date.
    @Test("a full day of its own leaves tomorrow nothing, and says how much was dropped")
    func todayCanFillTheColumn() {
        let capacity = GlanceScheduleLayout.maximumEntries
        let today = (0..<(capacity + 2)).map { event("t\($0)", hour: $0 + 6) }
        let plan = GlanceSchedulePlan.plan(today: today, tomorrow: [event("m1", hour: 9)])
        // One row of the budget goes to the count itself, which is why this is capacity - 1.
        #expect(plan.today.count == capacity - 1)
        #expect(!plan.showsTomorrow)
        // Everything not drawn, both days: three of today's and tomorrow's one.
        #expect(plan.overflow == (capacity + 2) - (capacity - 1) + 1)
    }

    /// The count never costs more room than it reports on — the island has already been sized.
    ///
    /// **`rowCount` and not a hand-rolled sum**, since the empty-day lines were added: this is the
    /// invariant the type exists to hold, and a test that re-derived it would be checking its own
    /// arithmetic rather than the plan's. The heading is not an entry — it has its own reserved
    /// strip (`GlanceScheduleLayout.rightColumnHeight`) — so it is not in the sum. The overflow line
    /// is, because it is drawn in the column, and it *takes* the last row rather than adding one.
    @Test("the drawn rows never exceed the column's capacity", arguments: [0, 1, 3, 5, 9, 40])
    func neverOverflowsTheColumn(count: Int) {
        let plan = GlanceSchedulePlan.plan(
            today: (0..<count).map { event("t\($0)", hour: $0 % 23) },
            tomorrow: (0..<count).map { event("m\($0)", hour: $0 % 23) }
        )
        #expect(plan.rowCount + (plan.overflow > 0 ? 1 : 0) <= GlanceScheduleLayout.maximumEntries)
    }

    /// The same, across every shape of the two days that fits in a reasonable test — all-day events
    /// on either side included, which is where the row budget has the most ways to be spent.
    @Test(
        "no combination of the two days overflows the column",
        arguments: [0, 1, 2, 5, 8], [0, 1, 2, 5, 8]
    )
    func noCombinationOverflows(todayCount: Int, tomorrowCount: Int) {
        let plan = GlanceSchedulePlan.plan(
            today: (0..<todayCount).map { event("t\($0)", hour: $0 % 23, allDay: $0 % 3 == 0) },
            tomorrow: (0..<tomorrowCount).map { event("m\($0)", hour: $0 % 23, allDay: $0 % 4 == 0) }
        )
        #expect(plan.rowCount + (plan.overflow > 0 ? 1 : 0) <= GlanceScheduleLayout.maximumEntries)
    }

    // MARK: - A day with nothing on it says so

    /// **Reported from use, 2026-08-31.** An empty today was silent: the column began at "TOMORROW"
    /// with no word about the day the surface is headed with, so a free day and a day whose events
    /// had failed to arrive drew the identical picture.
    @Test("an empty today says so, above tomorrow's heading")
    func anEmptyTodaySaysSo() {
        let plan = GlanceSchedulePlan.plan(
            today: [],
            tomorrow: [event("m1", hour: 9), event("m2", hour: 10)]
        )
        #expect(plan.today.isEmpty)
        #expect(plan.showsTodayEmpty)
        #expect(plan.showsTomorrow)
        #expect(!plan.showsTomorrowEmpty)
        #expect(plan.hasEntries)
    }

    /// The other end, which was silent in a different way: the column simply stopped after today,
    /// and a reader could not tell an empty tomorrow from one that had been left off.
    @Test("an empty tomorrow says so, under its own heading")
    func anEmptyTomorrowSaysSo() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("t1", hour: 9)],
            tomorrow: []
        )
        #expect(plan.today.count == 1)
        #expect(!plan.showsTodayEmpty)
        #expect(plan.showsTomorrowEmpty)
        // The heading is drawn *because* something follows it, which is the rule `showsTomorrow`
        // has always stated — an empty tomorrow is now one of the things that can follow.
        #expect(plan.showsTomorrow)
    }

    @Test("two empty days both say so")
    func bothDaysSaySo() {
        let plan = GlanceSchedulePlan.plan(today: [], tomorrow: [])
        #expect(plan.showsTodayEmpty)
        #expect(plan.showsTomorrowEmpty)
        #expect(plan.showsTomorrow)
        #expect(plan.rowCount == 2)
    }

    /// **The line is about the hours, not about the day.** Today's all-day events are pills in the
    /// *other* column, and a day whose only entry is somebody's birthday still has no hours in it —
    /// which is what this column is. Saying nothing here would leave the right-hand column blank
    /// with no explanation, which is the bug.
    @Test("a day of nothing but all-day events still says its hours are empty")
    func allDayAloneStillLeavesTheHoursEmpty() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("a1", allDay: true), event("a2", allDay: true)],
            tomorrow: []
        )
        #expect(plan.pills.count == 2)
        #expect(plan.today.isEmpty)
        #expect(plan.showsTodayEmpty)
    }

    /// **A tomorrow squeezed out by a full today is not an empty tomorrow.** The flag is asked of
    /// the inputs rather than of what was fitted, because the alternative is the surface lying about
    /// the one day it is there to look ahead at.
    @Test("a tomorrow that did not fit is never called empty")
    func aSqueezedTomorrowIsNotEmpty() {
        let capacity = GlanceScheduleLayout.maximumEntries
        let plan = GlanceSchedulePlan.plan(
            today: (0..<(capacity + 2)).map { event("t\($0)", hour: $0 % 23) },
            tomorrow: [event("m1", hour: 9)]
        )
        #expect(!plan.showsTomorrowEmpty)
        #expect(!plan.showsTodayEmpty)
        #expect(plan.overflow > 0)
    }

    /// And an empty day says nothing when there is no row to say it in — the budget is the budget.
    @Test("the lines are charged against the column like everything else")
    func theLinesArePaidFor() {
        let plan = GlanceSchedulePlan.plan(today: [], tomorrow: [], entryCapacity: 0)
        #expect(!plan.showsTodayEmpty)
        #expect(!plan.showsTomorrowEmpty)
        #expect(plan.rowCount == 0)
    }

    /// Nothing dropped means nothing counted, whatever the shape of the two days.
    @Test("everything that fits is drawn, and the count is only what did not")
    func theCountIsHonest() {
        let plan = GlanceSchedulePlan.plan(
            today: [event("t1", hour: 9), event("t2", hour: 10)],
            tomorrow: [event("m1", hour: 9), event("m2", hour: 10), event("m3", hour: 11),
                       event("m4", hour: 12)]
        )
        let drawnTomorrow = plan.tomorrow.count
        #expect(plan.today.count == 2)
        #expect(plan.overflow == 4 - drawnTomorrow)
    }

    /// **This asserted the opposite until 2026-08-31, and the rule it held was the reported bug.**
    /// Two empty days drew a blank column — no heading, no lines, nothing — on the argument that a
    /// heading with nothing under it says nothing. That is right about the *heading* and wrong about
    /// the column: a surface that just stops is read as broken, and it was, as "some days are
    /// missing events". The heading is still never drawn bare; what follows it now is a sentence.
    /// See `GlanceSchedulePlan.showsTodayEmpty`, and `bothDaysSaySo` for the replacement.
    @Test("an empty day says it is empty rather than drawing a blank column")
    func anEmptyDaySaysSo() {
        let plan = GlanceSchedulePlan.plan(today: [], tomorrow: [])
        #expect(plan.hasEntries)
        #expect(plan.showsTodayEmpty)
        // The heading is drawn because something follows it — which is the rule it always had.
        #expect(plan.showsTomorrow)
        #expect(plan.showsTomorrowEmpty)
        // Nothing was hidden, so nothing is counted, and there were no all-day events to be pills.
        #expect(plan.pills.isEmpty)
        #expect(plan.overflow == 0)
    }

    @Test("a day with nothing left still shows tomorrow")
    func tomorrowStandsAlone() {
        let plan = GlanceSchedulePlan.plan(today: [], tomorrow: [event("m1", hour: 9)])
        #expect(plan.today.isEmpty)
        #expect(plan.showsTomorrow)
        #expect(plan.hasEntries)
    }
}

/// What the model exposes to the schedule surface.
@MainActor
@Suite("The schedule surface's model")
struct GlanceScheduleModelTests {

    @Test("the surface starts closed, with neither day loaded")
    func itStartsClosed() {
        // The island opens on the day. Opening straight onto tomorrow would be the surface deciding
        // what the user came for, and it costs two EventKit fetches nobody asked for.
        let model = GlanceModel()
        #expect(model.isShowingSchedule == false)
        #expect(model.todayEvents.isEmpty)
        #expect(model.tomorrowEvents.isEmpty)
    }

    @Test("a model with no shell wired to it draws a date and does nothing when clicked")
    func itPreviewsWithNothingInjected() {
        // §3's layering test: this package must build and preview with nothing granted and no
        // wiring. Every closure is nil in a preview, and the view guards on that rather than
        // force-unwrapping — a preview that crashed would make the whole surface unviewable.
        let model = GlanceModel()
        #expect(model.onOpenSchedule == nil)
        #expect(model.onCloseSchedule == nil)
        #expect(model.onOpenEvent == nil)
    }
}
