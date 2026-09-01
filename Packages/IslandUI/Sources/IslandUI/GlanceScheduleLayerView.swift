import IslandActivities
import IslandKit
import SwiftUI

/// Today and tomorrow, behind the date: the day on the left with whatever is on all of it, and the
/// hours on the right.
///
/// Reached by clicking the date on the home page — or on the glance, where the same date is the
/// same affordance — and left by the **✕ Close** button or by closing the island. Drawn in place of
/// the glance's own body, the way the drop history and Up Next are drawn in place of theirs, so the
/// island keeps its flanks and goes on saying what it was saying.
///
/// **The island is wider here and wears no page indicator**, and both follow from the same fact:
/// this is not one of the three pages. It is two lists side by side and needs the width
/// (`GlanceScheduleLayout.bodyWidth`), and the dots below it would be answering a question about
/// somewhere the user is not — see `IslandScreenModel.hasPageIndicator`.
///
/// # What this is not
///
/// **Not a calendar app, and not an editor.** There is no create-event, no drag, no week or month
/// view. It answers one question — *what is left of today, and what is coming tomorrow* — and a
/// click on any row opens that event in Calendar, which is one click away and better at the rest.
///
/// **It replaced a month grid**, on 2026-08-28. Six weeks of dots answered "what does this month
/// look like", which is a question people ask a wall planner and not a notch; what they ask the
/// notch is what is next. The grid, its two arrows, day selection and `GlanceMonthGrid` all went
/// with it — see PROGRESS.md, which keeps what the grid measured about EventKit.
///
/// **Not scrollable.** A fixed five entries and then a count, decided by `GlanceSchedulePlan`.
/// A scrollable list here would be a *fourth* surface owning the island's vertical axis, and
/// `SwipeController` already arbitrates three.
///
/// # Nothing here moves on its own
///
/// No clock, no per-frame drawing, nothing on the idle path. Both days are fetched once, when the
/// surface opens, and forgotten when it closes — §9's rule about pulling rather than polling, which
/// the month grid followed for the same reason.
struct GlanceScheduleLayerView: View {

    let model: IslandScreenModel

    let glance: GlanceModel

    /// The instant "today" is judged against. Passed in rather than read from the clock, so the
    /// date block and the two lists agree, and so a test can ask about any day of any year.
    let now: Date

    private var calendar: Calendar { .current }

    private var plan: GlanceSchedulePlan {
        GlanceSchedulePlan.plan(today: glance.todayEvents, tomorrow: glance.tomorrowEvents)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)
            let plan = plan

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, GlanceScheduleLayout.headerSpacing)

                HStack(alignment: .top, spacing: GlanceScheduleLayout.columnSpacing) {
                    dateColumn(plan)
                        .frame(width: GlanceScheduleLayout.dateColumnWidth, alignment: .leading)

                    if let columnWidth = GlanceScheduleLayout.eventColumnWidth(
                        inBodyWidth: model.contentBodySize.width
                    ) {
                        eventColumn(plan)
                            .frame(width: columnWidth, alignment: .leading)
                    }
                }
                .frame(height: GlanceScheduleLayout.columnsHeight, alignment: .top)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, GlanceScheduleLayout.horizontalPadding)
            .padding(.top, GlanceScheduleLayout.topPadding)
            .frame(width: model.contentBodySize.width, alignment: .topLeading)
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    // MARK: - The way out

    /// A strip holding one control, at the trailing edge.
    ///
    /// **The ✕ says what it does.** A bare glyph in a circle is the shape every other dismiss on
    /// this island wears, and it is right where the surface it closes is obviously modal — the drop
    /// history covers the island, Up Next replaces the player. This one does neither: it is the
    /// calendar, opened from the calendar, and the way back was a symbol somebody had to try.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Button {
                glance.onCloseSchedule?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text(islandText("glance.schedule.close.label", "Close"))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
                .padding(.horizontal, 9)
                .frame(height: GlanceScheduleLayout.headerHeight - 6)
                .contentShape(Rectangle())
                .background(Capsule().fill(.white.opacity(model.increaseContrast ? 0.24 : 0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(islandText("glance.schedule.close", "Close the schedule"))
        }
        .frame(height: GlanceScheduleLayout.headerHeight)
    }

    // MARK: - The day

    /// The weekday, the numeral, and everything that is true of the whole day.
    ///
    /// The same block the home page draws, at the same sizes — this surface is reached by clicking
    /// it, and a date that changed size under the click would read as a different date. See
    /// `GlanceScheduleLayout.weekdayHeight`.
    private func dateColumn(_ plan: GlanceSchedulePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: GlanceScheduleLayout.dateBlockSpacing) {
                Text(GlanceFormat.weekday(now).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(weekdayTint)
                    .frame(height: GlanceScheduleLayout.weekdayHeight, alignment: .bottomLeading)

                Text(GlanceFormat.dayOfMonth(now))
                    .font(.system(size: 34, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(height: GlanceScheduleLayout.dateHeight, alignment: .topLeading)
            }
            .accessibilityElement(children: .combine)

            if glance.snapshot.access.isReadable {
                if !plan.pills.isEmpty {
                    VStack(alignment: .leading, spacing: GlanceScheduleLayout.pillSpacing) {
                        ForEach(plan.pills) { event in
                            pill(event)
                        }
                    }
                    .padding(.top, GlanceScheduleLayout.dateSpacing)
                }

                if plan.pillOverflow > 0 {
                    Text(islandText(
                        "glance.schedule.moreAllDay",
                        "\(plan.pillOverflow) more all-day events"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.5))
                    .lineLimit(1)
                    .frame(height: GlanceScheduleLayout.overflowHeight, alignment: .leading)
                    .padding(.top, GlanceScheduleLayout.overflowSpacing)
                }
            } else {
                accessNotice
            }

            Spacer(minLength: 0)
        }
    }

    private func pill(_ event: GlanceEvent) -> some View {
        Button {
            glance.onOpenEvent?(event)
        } label: {
            GlanceEventPill(event: event, increaseContrast: model.increaseContrast)
        }
        .buttonStyle(.plain)
        // The pill already reads its own title; what a click *does* is the part the label does not
        // say, and VoiceOver announces a button's action nowhere else.
        .accessibilityHint(islandText("glance.schedule.openEvent.a11y", "Opens the event in Calendar"))
    }

    /// Why the day is empty, when the reason is not "nothing on".
    ///
    /// **A refused calendar and a free day are byte-identical from EventKit** — a denied store
    /// answers zero calendars and an empty list without throwing — so the sentence comes from
    /// `access` and never from the list being empty. `IslandHomeLayerView.accessNotice` makes the
    /// same argument in the same words, and the two share the copy so that a click on the date does
    /// not change the story.
    ///
    /// Which control appears is §10: macOS raises the permission dialog exactly once, so an
    /// "Allow…" button after a refusal is a control that visibly does nothing. Before the prompt,
    /// the prompt; after it, the trip to System Settings; on a managed Mac, neither.
    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: IslandHomeLayout.accessButtonSpacing) {
            Text(glance.snapshot.access.emptyStateMessage)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.6))
                .lineLimit(IslandHomeLayout.accessMessageLines)
                .fixedSize(horizontal: false, vertical: true)

            if glance.snapshot.access == .notDetermined, let ask = glance.onRequestCalendarAccess {
                accessButton(islandText("home.allow", "Allow…"), action: ask)
                    .accessibilityLabel(islandText("glance.allow.a11y", "Allow calendar access"))
            } else if glance.snapshot.access.canBeGrantedInSettings,
                      let open = glance.onOpenCalendarSettings {
                accessButton(islandText("home.openSettings", "Open Settings"), action: open)
                    .accessibilityLabel(
                        islandText("home.openSettings.a11y", "Open Calendar privacy settings")
                    )
            }
        }
        .padding(.top, GlanceScheduleLayout.dateSpacing)
    }

    /// The notice's one control.
    ///
    /// A SwiftUI `Button`, which is also why clicking it does not close the island —
    /// `IslandHitTestView.mouseDown` toggles the island for any click that reaches it, and `hitTest`
    /// returns the deepest subview that wants the point.
    private func accessButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: IslandHomeLayout.accessButtonHeight)
                .contentShape(Rectangle())
                .background(Capsule().fill(.white.opacity(model.increaseContrast ? 0.28 : 0.14)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - The hours

    /// Today's timed events, then tomorrow's under a heading — as many of each as
    /// `GlanceSchedulePlan` fitted, and a line for either day that has nothing.
    ///
    /// **The whole column is drawn only when the calendar is readable.** A refusal and a free day
    /// are byte-identical from EventKit, so "no events" said over a denied store is a lie the user
    /// has no way to see through; the left column has already given the honest reason, and this
    /// would contradict it. `CalendarAccess` is where that argument lives.
    @ViewBuilder
    private func eventColumn(_ plan: GlanceSchedulePlan) -> some View {
        VStack(alignment: .leading, spacing: GlanceScheduleLayout.entrySpacing) {
            if glance.snapshot.access.isReadable {
                ForEach(plan.today) { event in
                    entry(event)
                }

                if plan.showsTodayEmpty {
                    nothingOn(islandText("glance.schedule.emptyToday", "No events today"))
                }

                if plan.showsTomorrow {
                    sectionHeader(islandText("glance.schedule.tomorrow", "Tomorrow"))

                    if plan.tomorrowAllDayCount > 0 {
                        allDaySummary(plan.tomorrowAllDayCount)
                    }

                    ForEach(plan.tomorrow) { event in
                        entry(event)
                    }

                    if plan.showsTomorrowEmpty {
                        nothingOn(islandText("glance.schedule.emptyTomorrow", "No events tomorrow"))
                    }
                }

                if plan.overflow > 0 {
                    Text(islandText("glance.schedule.more", "\(plan.overflow) more"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.8 : 0.45))
                        .lineLimit(1)
                        .frame(height: GlanceScheduleLayout.sectionHeaderHeight, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// One day's stated absence.
    ///
    /// **The same height as an entry**, because it occupies an entry's row — `GlanceSchedulePlan`
    /// charged it against the column's fixed budget, and a line that drew shorter would let the row
    /// under it ride up and stop the column's arithmetic matching what is on screen.
    ///
    /// Dimmer than a title and not a button: it is the answer to a question, not a thing to open.
    private func nothingOn(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.45))
            .lineLimit(1)
            .frame(height: GlanceScheduleLayout.entryHeight, alignment: .leading)
    }

    /// "TOMORROW", and nothing under it unless something follows — see `GlanceSchedulePlan`.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.45))
            .lineLimit(1)
            .frame(height: GlanceScheduleLayout.sectionHeaderHeight, alignment: .bottomLeading)
            .padding(.top, GlanceScheduleLayout.sectionHeaderSpacing)
    }

    /// One event: the calendar's colour down its leading edge, the title, and when it runs.
    ///
    /// A bar rather than the left column's pill, and the difference is what each column is for. A
    /// pill is a badge for a thing that is true of the whole day; these are *hours*, read down a
    /// column in order, and a stack of filled capsules would weigh the same as the titles on it.
    private func entry(_ event: GlanceEvent) -> some View {
        Button {
            glance.onOpenEvent?(event)
        } label: {
            entryBody(event)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(event))
        .accessibilityHint(islandText("glance.schedule.openEvent.a11y", "Opens the event in Calendar"))
    }

    /// The entry itself, which is a label and knows nothing about being clicked.
    ///
    /// Split from `entry` so the `Button` wraps a finished view: a `buttonStyle(.plain)` label that
    /// *builds* its own background is where SwiftUI starts applying the style's content shape to
    /// something other than the drawn row, and the press target stops matching what is on screen.
    private func entryBody(_ event: GlanceEvent) -> some View {
        let calendar = event.calendarTint ?? .init(red: 0.5, green: 0.5, blue: 0.5)
        return HStack(spacing: GlanceScheduleLayout.entryBarSpacing) {
            Capsule()
                .fill(calendar.color(increaseContrast: model.increaseContrast))
                .frame(width: GlanceScheduleLayout.entryBarWidth)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(GlanceFormat.timeRange(event))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: GlanceScheduleLayout.entryHeight)
        .contentShape(Rectangle())
    }

    /// Tomorrow's all-day events, as one row.
    ///
    /// **Counted rather than listed**, and it is the same decision the left column makes in the
    /// other direction: today's all-day items are what the date block is about, so they are drawn;
    /// tomorrow's would push out the times that are the reason anybody reads ahead. Two overlapping
    /// discs rather than one, so the row reads as a stack at a glance — and exactly two whatever the
    /// count, because a row that grew a disc per event would be a bar chart nobody asked for.
    private func allDaySummary(_ count: Int) -> some View {
        HStack(spacing: GlanceScheduleLayout.entryBarSpacing) {
            ZStack(alignment: .leading) {
                disc.offset(x: 7)
                disc
            }
            .frame(width: IslandHomeLayout.eventBadgeSide + 7, alignment: .leading)

            Text(islandText("glance.schedule.allDay", "\(count) all-day events"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: GlanceScheduleLayout.entryHeight)
        .accessibilityElement(children: .combine)
    }

    /// One of the two discs.
    ///
    /// **The ring is the island's own black, not a colour**, and it is what makes two overlapping
    /// discs read as two: without it they merge into a single soft blob at this size, which is a
    /// stack of nothing. Drawn as a stroke *inside* the circle rather than as a second shape behind
    /// it, so the pair still measures one badge plus the overlap.
    private var disc: some View {
        Circle()
            .fill(.white.opacity(model.increaseContrast ? 0.9 : 0.35))
            .overlay(
                Circle().strokeBorder(.black.opacity(0.85), lineWidth: 1.5)
            )
            .frame(
                width: IslandHomeLayout.eventBadgeSide,
                height: IslandHomeLayout.eventBadgeSide
            )
    }

    /// Spoken as what and when, because a title and a time range read separately out loud are two
    /// unrelated announcements.
    private func spoken(_ event: GlanceEvent) -> String {
        [event.title, GlanceFormat.timeRange(event)]
            .joined(separator: islandText("list.separator", ", "))
    }

    /// The weekday, in the accent the date block reads against — system red, the Mac's own mark for
    /// today, spelled in sRGB for the reason `IslandHomeLayerView.weekdayTint` gives at length: a
    /// dynamic system colour resolves against the *view's* appearance, and the panel's is not
    /// guaranteed to be the dark one.
    private var weekdayTint: Color {
        model.increaseContrast
            ? .white
            : Color(.sRGB, red: 1.0, green: 0.271, blue: 0.227, opacity: 1)
    }
}
