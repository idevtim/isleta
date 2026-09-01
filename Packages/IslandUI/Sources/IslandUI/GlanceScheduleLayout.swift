import CoreGraphics
import Foundation
import IslandActivities

/// Where the schedule surface's parts sit: the date and today's all-day items on the left, today's
/// timed events and then tomorrow's on the right.
///
/// # Every number here is a constant, and the height most of all
///
/// `contentHeight` takes no arguments. The open island's height is agreed **before** the transition,
/// through `IslandController.expandedContentHeight`, and `islandPath` has to track a shape that has
/// settled — so a surface that grew with the day would move its own bottom edge under a pointer
/// resting on it, and would do it through the widen-then-tighten protocol every time the calendar
/// changed. `GlanceSchedulePlan` is what makes that affordable: it fits the day into a fixed number
/// of rows rather than asking for the rows the day happens to need.
///
/// It is also what makes the closing height unconditionally correct — there is no row count for a
/// stale flag to answer about, which is the bug that shipped on the Up Next surface.
public enum GlanceScheduleLayout {

    /// How wide the open island is while the schedule is up.
    ///
    /// **The one surface in Isleta that asks for more than `IslandLayout.expandedBodySize.width`**,
    /// and the only one with a reason to: every other page is a single column, while this one is
    /// two lists side by side. At the default 368 the right-hand column — the one carrying event
    /// titles, which are the longest strings on the island — would be 196pt, and a title truncated
    /// to two words is the surface failing at the one thing it is for.
    ///
    /// Well inside `IslandLayout.maxExpandedBodySize.width`, which is what the panel was built at
    /// and never resized (§4.2), and `IslandLayout.expandedWidth` clamps it there regardless.
    public static let bodyWidth: CGFloat = 440

    public static let horizontalPadding: CGFloat = GlanceLayout.horizontalPadding

    public static let topPadding: CGFloat = GlanceLayout.topPadding

    public static let bottomPadding: CGFloat = 12

    /// The strip along the top carrying the way out, and nothing else.
    ///
    /// Its own row rather than a control floated over the columns: the right column's first entry
    /// starts at the top of its own list, and a button overlapping it would sit on the title of the
    /// next thing the user has on.
    public static let headerHeight: CGFloat = 26

    public static let headerSpacing: CGFloat = 8

    // MARK: - The left column

    /// The date block's own width.
    ///
    /// Fixed rather than a fraction, because what it holds is fixed: a weekday, a numeral, and
    /// pills whose text is a title. The right column takes everything left over — see
    /// `eventColumnWidth` — which is the column whose content actually varies in length.
    public static let dateColumnWidth: CGFloat = 168

    /// Air between the two columns. Wider than the row spacing inside either, so the eye reads two
    /// lists rather than one ragged one.
    public static let columnSpacing: CGFloat = 16

    /// The three parts of the date block, at the home page's own sizes.
    ///
    /// Deliberately the same constants rather than new ones of a similar size: this surface is
    /// reached by clicking that exact block on the home page, so the numeral must not change size
    /// as the island opens onto it. A date that grew a point under the click would read as the
    /// surface being a different date.
    public static let weekdayHeight: CGFloat = IslandHomeLayout.weekdayHeight

    public static let dateHeight: CGFloat = IslandHomeLayout.dateHeight

    public static let dateBlockSpacing: CGFloat = IslandHomeLayout.dateBlockSpacing

    public static var dateBlockHeight: CGFloat { weekdayHeight + dateBlockSpacing + dateHeight }

    /// Air under the date block, before the all-day pills.
    public static let dateSpacing: CGFloat = 10

    /// One all-day pill, and the gap under it — the home page's pill exactly, for
    /// `weekdayHeight`'s reason and one of its own: a person swiping between the two surfaces is
    /// looking at the same events, and a row that changed shape between them would read as a
    /// different list.
    public static let pillHeight: CGFloat = IslandHomeLayout.eventHeight

    public static let pillSpacing: CGFloat = IslandHomeLayout.eventSpacing

    /// How many all-day pills the left column draws before it starts counting.
    ///
    /// Four, which is what the column's height affords beneath the date block. A day with more says
    /// so in one line rather than scrolling: a scrollable list here would be a surface that owns the
    /// vertical axis, which `SwipeController` already arbitrates for three others.
    public static let maximumPills = 4

    /// The "4 more all-day events" line under the pills.
    public static let overflowHeight: CGFloat = 18

    public static let overflowSpacing: CGFloat = 4

    // MARK: - The right column

    /// One entry — a timed event drawn as a title over its time, or the summary row that stands in
    /// for a day's all-day events.
    ///
    /// **A single height for both**, which is what keeps the column's arithmetic a constant: the
    /// summary is one line and a timed event is two, and a column whose rows were sized to their
    /// contents would be a different height for every day of the week.
    public static let entryHeight: CGFloat = 32

    public static let entrySpacing: CGFloat = 4

    /// The bar down the leading edge of an entry, in the calendar's own colour.
    public static let entryBarWidth: CGFloat = 3

    public static let entryBarSpacing: CGFloat = 8

    /// The "TOMORROW" heading, and the air under it.
    public static let sectionHeaderHeight: CGFloat = 14

    public static let sectionHeaderSpacing: CGFloat = 4

    /// How many entries the right column draws, today's and tomorrow's together.
    ///
    /// Five, which is what the column's height affords with the heading in it. `GlanceSchedulePlan`
    /// is where that budget is spent — today first, tomorrow into what is left.
    public static let maximumEntries = 5

    /// The height every entry takes together, gaps included.
    public static func entriesExtent(count: Int) -> CGFloat {
        let entries = max(0, count)
        guard entries > 0 else { return 0 }
        return CGFloat(entries) * entryHeight + CGFloat(entries - 1) * entrySpacing
    }

    /// The two columns' shared height: whichever of them needs more, so neither is cut.
    ///
    /// The right one wins today — five entries and a heading against a date block, four pills and a
    /// count — and it is written as a `max` rather than as the winning number so that a change to
    /// either column fails loudly rather than silently clipping the other.
    public static var columnsHeight: CGFloat {
        max(leftColumnHeight, rightColumnHeight)
    }

    private static var leftColumnHeight: CGFloat {
        dateBlockHeight
            + dateSpacing
            + entriesExtentForPills
            + overflowSpacing
            + overflowHeight
    }

    private static var entriesExtentForPills: CGFloat {
        CGFloat(maximumPills) * pillHeight + CGFloat(maximumPills - 1) * pillSpacing
    }

    private static var rightColumnHeight: CGFloat {
        sectionHeaderHeight + sectionHeaderSpacing + entriesExtent(count: maximumEntries)
    }

    /// The whole surface's height, and it is the same for every day.
    public static var contentHeight: CGFloat {
        topPadding
            + headerHeight + headerSpacing
            + columnsHeight
            + bottomPadding
    }

    /// The width the events column gets, given the island's drawable width.
    ///
    /// Whatever is left after the date block, which is fixed. Nil when there is not enough left to
    /// be worth drawing — on a narrow island the date is the surface and the events are not shown,
    /// rather than squeezed into forty points where every title truncates to two words.
    public static func eventColumnWidth(inBodyWidth width: CGFloat) -> CGFloat? {
        let available = width - 2 * horizontalPadding - dateColumnWidth - columnSpacing
        return available >= minimumEventColumnWidth ? available : nil
    }

    /// Below this the column says nothing useful, so it is not drawn at all.
    public static let minimumEventColumnWidth: CGFloat = 150
}

/// How a day and the one after it are fitted into a fixed number of rows.
///
/// Pure, and deliberately not a view's private arithmetic: what it decides — whose events are
/// dropped when the two days do not fit — is a product rule, and a rule that lives inside a
/// `ViewBuilder` is a rule nobody can check without a screen. `ActivityStack` and `GlancePolicy`
/// are the same shape for the same reason.
///
/// # The rule
///
/// **Today first, tomorrow into what is left.** Today is what the surface was opened for, so it
/// takes the rows it needs; tomorrow fills whatever remains, and the heading is drawn only when
/// there is at least one row for it to head. Anything neither day could show is counted in one
/// line, so the column never simply stops — a list that ends without saying so reads as an empty
/// evening, which is the one thing a schedule must never imply.
///
/// **All-day events are counted, not listed.** Today's are pills in the left column, where the date
/// is; tomorrow's collapse into a single "5 all-day events" row, because a day whose all-day items
/// filled the column would push out the timed events that are the reason anybody looks at tomorrow.
public struct GlanceSchedulePlan: Equatable, Sendable {

    /// Today's all-day events, capped at what the left column draws.
    public var pills: [GlanceEvent] = []

    /// How many of today's all-day events the pills did not fit.
    public var pillOverflow: Int = 0

    /// Today's timed events, in the order they happen.
    public var today: [GlanceEvent] = []

    /// Whether the "TOMORROW" heading is drawn — true only when something follows it, and an
    /// empty tomorrow counts as something (`showsTomorrowEmpty`).
    public var showsTomorrow: Bool = false

    /// Whether today says, in one line, that it has nothing on it.
    ///
    /// **Reported from use, 2026-08-31: "some days are missing events / maybe they are truly
    /// empty."** They were truly empty, and the column said nothing about it — a day with nothing
    /// on it and a day whose events failed to arrive drew the identical picture, and where today was
    /// empty but tomorrow was not, the column simply began at "TOMORROW" with no word about the day
    /// the surface is headed with. That is the calendar's own version of the mistake
    /// `CalendarAccess` exists to prevent one level up: **absence has to be stated, because a
    /// surface that just stops is read as broken.**
    ///
    /// It costs a row, charged against `entryCapacity` like everything else here — see `plan`.
    public var showsTodayEmpty: Bool = false

    /// The same for tomorrow, drawn under the heading. `showsTomorrow` is true whenever this is.
    public var showsTomorrowEmpty: Bool = false

    /// How many all-day events tomorrow holds, or zero. Drawn as one summary row above tomorrow's
    /// timed events.
    public var tomorrowAllDayCount: Int = 0

    /// Tomorrow's timed events, in the order they happen.
    public var tomorrow: [GlanceEvent] = []

    /// How many events, across both days, the right column had no room for.
    public var overflow: Int = 0

    /// Whether the right column has anything in it at all — a stated absence included, which is
    /// the point of stating it.
    public var hasEntries: Bool {
        !today.isEmpty || showsTodayEmpty || showsTomorrow
    }

    /// Every row the column draws, so the one invariant this type has — that it never asks for more
    /// rows than the island was sized for — can be checked in one place rather than re-derived by
    /// each test that cares. The overflow line is not counted: it takes the last row rather than
    /// adding one, which is what the fitting below is careful about.
    public var rowCount: Int {
        today.count
            + (showsTodayEmpty ? 1 : 0)
            + (tomorrowAllDayCount > 0 ? 1 : 0)
            + tomorrow.count
            + (showsTomorrowEmpty ? 1 : 0)
    }

    /// Fits two days into the column.
    ///
    /// - Parameters:
    ///   - today: everything on today, timed and all-day, in any order.
    ///   - tomorrow: the same for tomorrow.
    ///   - entryCapacity: how many rows the right column draws.
    ///   - pillCapacity: how many all-day pills the left column draws.
    public static func plan(
        today todayEvents: [GlanceEvent],
        tomorrow tomorrowEvents: [GlanceEvent],
        entryCapacity: Int = GlanceScheduleLayout.maximumEntries,
        pillCapacity: Int = GlanceScheduleLayout.maximumPills
    ) -> Self {
        let capacity = max(0, entryCapacity)
        var plan = Self()

        // Sorted here rather than trusted from the caller: the shell fetches each day with its own
        // predicate, and a column drawn in EventKit's order is a day out of sequence.
        let todayAllDay = todayEvents.filter(\.isAllDay).sorted { $0.title < $1.title }
        let todayTimed = todayEvents.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        let tomorrowAllDay = tomorrowEvents.filter(\.isAllDay)
        let tomorrowTimed = tomorrowEvents.filter { !$0.isAllDay }.sorted { $0.start < $1.start }

        plan.pills = Array(todayAllDay.prefix(max(0, pillCapacity)))
        plan.pillOverflow = todayAllDay.count - plan.pills.count

        // Today takes what it needs.
        plan.today = Array(todayTimed.prefix(capacity))
        var spent = plan.today.count
        var missed = todayTimed.count - plan.today.count

        // **A day with nothing on it says so, and it costs a row.** Before this, an empty today was
        // silent and the column opened at "TOMORROW" — see `showsTodayEmpty`. It is charged against
        // the budget rather than floated above it for the reason everything here is: the island's
        // height is agreed before the transition and there are exactly `entryCapacity` rows to
        // spend, so a line that did not pay would be drawn outside the island.
        //
        // Today's all-day pills do **not** count. They are in the other column, and a day whose
        // only entry is "Sam's birthday" still has no hours in it — which is what this column is.
        if plan.today.isEmpty, spent < capacity {
            plan.showsTodayEmpty = true
            spent += 1
        }

        // Tomorrow fills the rest. The summary row is one row whatever it counts, and it goes first
        // — an all-day event is the whole of tomorrow rather than a point in it, so a reader
        // scanning down the column meets it before the times it spans.
        var remaining = capacity - spent
        if remaining > 0, !tomorrowAllDay.isEmpty {
            plan.tomorrowAllDayCount = tomorrowAllDay.count
            spent += 1
            remaining -= 1
        } else {
            missed += tomorrowAllDay.count
        }
        if remaining > 0 {
            plan.tomorrow = Array(tomorrowTimed.prefix(remaining))
            // **Charged against the budget, not merely taken from it.** Left uncounted, `spent`
            // stayed at today's own total — so a column that was already full drew the count as a
            // *sixth* row, outside the island the shape had been agreed for. Caught by
            // `neverOverflowsTheColumn` before it was ever drawn.
            spent += plan.tomorrow.count
            remaining -= plan.tomorrow.count
        }
        missed += tomorrowTimed.count - plan.tomorrow.count

        // And tomorrow says it too, under its own heading, when there is genuinely nothing there
        // and a row left to say it in. Asked of the **inputs** rather than of what was fitted: a
        // tomorrow whose events were squeezed out by a full today is not an empty tomorrow, and
        // saying so would be the surface lying about the one day it is there to look ahead at.
        if tomorrowAllDay.isEmpty, tomorrowTimed.isEmpty, spent < capacity {
            plan.showsTomorrowEmpty = true
            spent += 1
        }
        plan.showsTomorrow = plan.tomorrowAllDayCount > 0
            || !plan.tomorrow.isEmpty
            || plan.showsTomorrowEmpty

        // **The count takes a row of its own**, which is why this runs after the fitting rather
        // than beside it: a line drawn under a full column would be the one thing on this surface
        // outside the island. The row it takes is the last entry drawn, and what that entry was
        // goes back into the count.
        if missed > 0, spent == capacity {
            if !plan.tomorrow.isEmpty {
                missed += 1
                plan.tomorrow.removeLast()
            } else if plan.tomorrowAllDayCount > 0 {
                missed += plan.tomorrowAllDayCount
                plan.tomorrowAllDayCount = 0
            } else if !plan.today.isEmpty {
                missed += 1
                plan.today.removeLast()
            }
            plan.showsTomorrow = plan.tomorrowAllDayCount > 0
                || !plan.tomorrow.isEmpty
                || plan.showsTomorrowEmpty
        }
        plan.overflow = max(0, missed)
        return plan
    }
}
