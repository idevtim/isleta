import Foundation
import IslandActivities
import IslandKit

/// The day, on the island: what is next, what else is on, and what it is doing outside.
///
/// # Three kinds from one source, and why they are not three sources
///
/// - **`.glance`** is the standing surface — the calendar and the weather, read when the user asks.
/// - **`.calendarAlert`** is an event about to start, announced unasked with a deadline on it.
/// - **`.meeting`** is a joinable link at the moment it becomes joinable, and it carries a button.
///
/// They come from one source because they come from one fetch. Splitting them would mean three
/// objects each re-running the same predicate against the same store on the same notification, and
/// three answers about what is next that can disagree — which is the failure `SourceToggles`
/// documents about two spellings of one vocabulary. The user's three switches are still three
/// switches; they gate what this publishes, not how many stores are open.
///
/// # Nothing here polls, and one thing here has a timer
///
/// `.EKEventStoreChanged` is genuine push: measured, **8–10 ms** after a commit. It is the only
/// signal EventKit offers, and it says *the user edited a calendar* — never *a meeting is now five
/// minutes away*. Time passing announces itself to nobody.
///
/// The obvious answer is a minute timer, and §9 forbids one on the idle path. So the source arms
/// **exactly one** `DispatchSourceTimer`, at `GlancePolicy.nextBoundary` — the next instant at which
/// any answer could change — and re-arms it from its own handler. On a Mac with an empty calendar
/// there is no boundary and therefore no timer at all; on a busy day it fires a handful of times and
/// each firing does something the user can see. This is the same shape `ActivityCoordinator` uses
/// for the whole expiry model: one scheduled sleep for a stack, rather than one timer per entry.
///
/// # The change notification fires twice, and equality is the coalescer
///
/// One user-visible edit produced **two callbacks 2,019 ms apart**. Undeduplicated that is two full
/// re-fetches and two islands for one thing the user did.
///
/// Two mechanisms handle it, and the second is the one that actually holds. The first is a leading
/// edge with a short trailing window (`changeCoalescingWindow`): refresh at once, and if anything
/// else arrives inside the window, refresh **once** more at the end of it rather than per callback.
/// The second is that publication is gated on the snapshot having *changed* — and because
/// `GlanceEvent` is a value rebuilt from a re-run predicate rather than a diff of held `EKEvent`s,
/// the second fetch produces a snapshot equal to the first and publishes nothing. Either alone
/// would mostly work; together the failure mode is a wasted 2 ms fetch rather than a second island.
///
/// # Nothing about the user's calendar is ever logged
///
/// Event titles, notes, locations, attendee names and meeting URLs are the user's own content, and
/// `IslandLog` writes into the file "Export Logs…" hands to strangers. Counts, enum values and
/// authorization states only — the rule every list of somebody's own content is built around, and the same
/// reason.
@MainActor
public final class CalendarSource: ActivitySource {

    public static let sourceName = "calendar"

    /// How long after the first change notification a second one is folded into it.
    ///
    /// 2.5 s, chosen against the measured 2,019 ms gap between the two callbacks one edit produces
    /// — long enough to cover the pair, short enough that two deliberate edits half a second apart
    /// still reach the island as one update rather than being lost.
    static let changeCoalescingWindow: TimeInterval = 2.5

    public var onActivity: ((any IslandActivity) -> Void)?

    public var onDismiss: ((ActivityID) -> Void)?

    /// The whole surface, for `GlanceLayerView`.
    ///
    /// A second callback beside the protocol's two, for the same reason `NowPlayingSource` exposes
    /// `transport` and `artwork`: `ActivitySource` is deliberately a one-way stream of
    /// `ActivityContent`, and a day's worth of events with join links in them is not sayable in a
    /// vocabulary of symbols and strings. The activity is what the *stack* sees; this is what the
    /// open island draws.
    public var onSnapshot: ((GlanceSnapshot) -> Void)?

    /// The event a `.meeting` activity is currently about, or nil.
    ///
    /// A third callback, and it exists because a button needs a URL and `ActivityContent` has no
    /// field for one — deliberately, since the vocabulary is symbols and strings. `GlanceLayerView`
    /// draws the Join button from this; the app shell opens the link. **Nothing between here and
    /// `NSWorkspace` logs it.**
    public var onJoinableMeeting: ((GlanceEvent?) -> Void)?

    /// Whether the user wants an event about to start announced. Their own switch
    /// (`SourceToggles.calendarAlerts`), applied by the app shell.
    public var publishesAlerts = true

    /// Whether a joinable link is worth opening the island for (`SourceToggles.meetings`).
    public var publishesMeetings = true

    /// Which calendars to include. Empty means all — see `CalendarReading.events(from:to:calendarIDs:)`.
    public var includedCalendarIDs: Set<String> = [] {
        didSet {
            guard includedCalendarIDs != oldValue, isRunning else { return }
            refresh()
        }
    }

    private let store: any CalendarReading

    private let now: () -> Date

    /// The user's calendar, which decides where a day starts and where a month ends.
    ///
    /// Held rather than read as `.current` at each use so a test can ask about a Monday-first week
    /// or a month that crosses a daylight-saving change without moving the machine — the same
    /// reason `now` is a closure: a test must be able to ask about any day of any year.
    private let calendar: Calendar

    private var isRunning = false

    /// The last snapshot published. Publication is gated on this changing — see the type's note on
    /// the double notification.
    private var published = GlanceSnapshot()

    /// Which alert and meeting activities are on the stack, so they can be withdrawn on teardown.
    ///
    /// A ringing-phone-shaped obligation, one size down: both kinds expire on their own, but a
    /// source that stops without retracting leaves an island saying a meeting starts in four minutes
    /// with nothing left running to correct it.
    private var announced: Set<ActivityID> = []

    private var boundary: DispatchSourceTimer?

    private var coalesce: DispatchSourceTimer?

    private var changedDuringWindow = false

    /// What `onJoinableMeeting` last said, so it is not re-said on every boundary.
    private var joinable: GlanceEvent?

    public init(
        store: any CalendarReading = EventKitCalendarStore(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Authorization

    /// Read live. §10: `.undetermined` gets an offer in Settings, `.denied` gets the deep link, and
    /// neither gets a prompt from here.
    public var authorization: SourceAuthorization {
        switch store.access {
        case .granted: .granted
        case .notDetermined: .undetermined
        case .denied:
            .denied(explanation: sourceText("calendar.authorization.denied", """
                Isleta can’t see your calendar, so the island has nothing to \
                show for your day. Turning Calendar on for Isleta in System Settings ▸ \
                Privacy & Security brings back what’s next — your events are never stored, \
                never sent anywhere and never written to Isleta’s logs.
                """))
        case .restricted:
            .denied(explanation: sourceText("calendar.authorization.restricted", """
                Calendar access is managed on this Mac, so Isleta cannot read \
                your events. Nothing you can change in Isleta will alter that.
                """))
        case .writeOnly:
            .denied(explanation: sourceText("calendar.authorization.writeOnly", """
                Isleta has write-only calendar access, which authorises adding \
                events and returns none to read. Full access is what the island needs.
                """))
        }
    }

    /// Ask for the calendar. **A prompt, so it may only be reached from a moment the user began.**
    ///
    /// The single caller is the button on the Glance settings pane. Two rules are enforced here
    /// rather than trusted to the caller:
    ///
    /// - **A no-op unless the status is `.notDetermined`.** macOS will not show the dialog twice, so
    ///   asking again after a refusal is a control that visibly does nothing (§10: no nagging).
    /// - **It never retries.** With no usage key in the Info.plist the request answers
    ///   `granted=false, err=nil` in **9 ms**, raises no prompt, logs nothing, and leaves the status
    ///   at `notDetermined` rather than `denied`. A loop that retried on that state would ask
    ///   forever, nine milliseconds at a time, and never advance — the whole signal being a
    ///   false-looking false. There is deliberately no retry anywhere in this file.
    public func requestAccessFromUserInitiatedMoment(_ completion: @escaping @MainActor (CalendarAccess) -> Void = { _ in }) {
        guard store.access == .notDetermined else {
            completion(store.access)
            return
        }
        IslandLog.calendar.info("calendar access requested from the settings window")
        store.requestAccess { [weak self] access in
            guard let self else {
                completion(access)
                return
            }
            if self.isRunning { self.refresh() }
            completion(access)
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // Registered whatever the authorization is. A user who grants access in System Settings
        // while Isleta is running gets a `.EKEventStoreChanged` when their calendars sync, and an
        // observer registered only in the granted state would be the one thing not listening at the
        // moment it started to matter.
        store.observeChanges { [weak self] in self?.storeChanged() }
        IslandLog.calendar.info("calendar source started — access \(store.access)")
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        store.stopObserving()
        boundary?.cancel()
        boundary = nil
        coalesce?.cancel()
        coalesce = nil
        changedDuringWindow = false

        // Withdraw the announcements. There is no standing surface to withdraw with them: the
        // day and the sky reach the island as a *snapshot* the pages read, never as an activity on
        // the stack — see `publish`.
        for id in announced { onDismiss?(id) }
        announced.removeAll()
        if joinable != nil {
            joinable = nil
            onJoinableMeeting?(nil)
        }
        published = GlanceSnapshot()
        onSnapshot?(published)
        IslandLog.calendar.info("calendar source stopped")
    }

    /// Nothing here is deferred — no queue, no child process, no completion handler that outlives
    /// the call — so `stop()` already carries the promise `stopAndWait()` makes. Spelled out rather
    /// than inherited, so the next person to put work on a queue in `stop()` sees the rule.
    public func stopAndWait() { stop() }

    // MARK: - Weather

    /// Folded in by the app shell from `WeatherSource`. Republishes the snapshot, which is what
    /// redraws the card — and publishes nothing when the reading is unchanged.
    public func setWeather(_ reading: WeatherReading?) {
        guard published.weather != reading else { return }
        var snapshot = published
        snapshot.weather = reading
        publish(snapshot)
    }

    // MARK: - Reading

    private func storeChanged() {
        guard isRunning else { return }
        guard coalesce == nil else {
            // Inside the window. Remembered rather than acted on — see the coalescing note.
            changedDuringWindow = true
            return
        }
        refresh()
        openCoalescingWindow()
    }

    /// The trailing half of the coalescer: one shot, `changeCoalescingWindow` from now, and only if
    /// something else arrived meanwhile.
    private func openCoalescingWindow() {
        coalesce?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.changeCoalescingWindow)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coalesce = nil
                guard self.changedDuringWindow, self.isRunning else { return }
                self.changedDuringWindow = false
                self.refresh()
            }
        }
        timer.resume()
        coalesce = timer
    }

    // MARK: - A day, which is pulled rather than pushed

    /// One day's events — everything on it, timed and all-day.
    ///
    /// **Pulled, not published**, and that is the difference between this and everything else in
    /// this file. The snapshot is pushed whenever the day or the store changes; a day is fetched
    /// when somebody opens the schedule surface, and forgotten when they close it. Publishing it
    /// instead would mean re-fetching two days on every `.EKEventStoreChanged` — which fires
    /// **twice per user edit** — to keep a surface nobody is looking at up to date.
    ///
    /// Empty rather than nil when access is refused, and the caller must not read that as "no
    /// events": a denied store answers zero calendars and an empty list **without throwing**, which
    /// CLAUDE.md records as indistinguishable from a user who owns no calendars. `CalendarAccess`
    /// is the only discriminator, and the surface already has it from the snapshot.
    ///
    /// Half-open: the start of the day to the start of the next one, so an event at 23:59:59.5
    /// belongs to exactly one of them.
    public func events(on day: Date) -> [GlanceEvent] {
        guard store.access.isReadable,
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        else { return [] }
        return store.events(
            from: calendar.startOfDay(for: day),
            to: next,
            calendarIDs: includedCalendarIDs
        )
        .sorted { $0.start < $1.start }
    }

    /// Re-runs the predicate and publishes the difference.
    ///
    /// **The predicate is re-run rather than the previous events re-read**, and that is not a
    /// preference: EventKit's own header says every `EKEvent` held across a change notification is
    /// invalid. Nothing outside `EventKitCalendarStore` has ever held one.
    func refresh() {
        let instant = now()
        let access = store.access
        let events = access.isReadable
            ? store.events(
                from: instant,
                to: instant.addingTimeInterval(GlancePolicy.lookAhead),
                calendarIDs: includedCalendarIDs
            )
            : []

        publish(
            GlanceSnapshot(
                access: access,
                events: GlancePolicy.upcoming(in: events, at: instant, limit: GlancePolicy.maximumEvents),
                weather: published.weather,
                asOf: instant
            ),
            allEvents: events
        )
        armBoundary(for: events, at: instant)
    }

    /// Publishes a snapshot and whatever announcements fall out of it.
    ///
    /// **A snapshot only — never an activity.** The day and the sky are what the island shows when
    /// nothing has happened, which is the definition of a *page* rather than of an activity, and
    /// `GlanceModel` carries them straight to `IslandPage.home` and `.weather` with no stack
    /// involved. Publishing them as a standing activity as well is what this source did through
    /// 2.0, and it cost the thing the island is most often showing: see "Will not own" in the
    /// module README.
    ///
    /// - Parameter allEvents: the full fetch, not just the three the island lists. The alert and
    ///   meeting windows are decided against everything in the look-ahead — a fourth event starting
    ///   in three minutes is exactly the one worth being told about.
    private func publish(_ snapshot: GlanceSnapshot, allEvents: [GlanceEvent]? = nil) {
        let events = allEvents ?? snapshot.events
        if snapshot != published {
            published = snapshot
            onSnapshot?(snapshot)
        }
        announce(from: events, at: snapshot.asOf)
    }

    /// The two announcing kinds.
    ///
    /// Each is published **once** per event per window, which is what `announced` is for: `refresh`
    /// runs on every boundary and on every calendar edit, and re-publishing would restart a dwell
    /// that was already running — the same rule `BluetoothDeviceSource.recentlyAnnounced` enforces
    /// for a burst of connect notifications.
    private func announce(from events: [GlanceEvent], at instant: Date) {
        // Said once per change rather than once per boundary: this drives a button, and re-handing
        // the same event to the view on every wake would rebuild it under the pointer.
        let nowJoinable = publishesMeetings ? GlancePolicy.joinable(in: events, at: instant).first : nil
        if nowJoinable?.id != joinable?.id {
            joinable = nowJoinable
            onJoinableMeeting?(nowJoinable)
        }
        if publishesMeetings {
            for event in GlancePolicy.joinable(in: events, at: instant) {
                let id = Self.meetingID(for: event)
                guard !announced.contains(id) else { continue }
                announced.insert(id)
                IslandLog.calendar.info("meeting joinable — provider \(event.meeting?.provider.rawValue ?? "none")")
                onActivity?(Self.meetingActivity(for: event, id: id))
            }
        }
        if publishesAlerts {
            for event in GlancePolicy.alerting(in: events, at: instant) {
                let id = Self.alertID(for: event)
                guard !announced.contains(id) else { continue }
                // An event that is *also* joinable has already opened the island with a button on
                // it. A second island four minutes later saying the same meeting is about to start
                // is the same news twice — and the meeting is the more useful of the two, because it
                // is the one you can act on.
                guard !announced.contains(Self.meetingID(for: event)) else { continue }
                announced.insert(id)
                IslandLog.calendar.info("event alert — \(Int(GlancePolicy.alertLead / 60)) minute lead")
                onActivity?(Self.alertActivity(for: event, id: id, at: instant))
            }
        }
        // Forget events that are long past, so the set does not grow for the life of the process.
        // Done here rather than on a schedule, because this is the only moment it can grow.
        let live = Set(events.filter { $0.end > instant }.flatMap { [Self.alertID(for: $0), Self.meetingID(for: $0)] })
        announced.formIntersection(live)
    }

    // MARK: - The one timer

    /// Arms the single boundary timer, or cancels it when nothing ahead can change anything.
    private func armBoundary(for events: [GlanceEvent], at instant: Date) {
        boundary?.cancel()
        boundary = nil
        guard isRunning, let next = GlancePolicy.nextBoundary(in: events, at: instant) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // One shot. Re-armed from the handler against the *new* set of events, so an edit made in
        // the meantime is honored rather than being waited out.
        timer.schedule(deadline: .now() + max(1, next.timeIntervalSince(instant)))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.refresh()
            }
        }
        timer.resume()
        boundary = timer
    }

    /// The store's own answer, for the Settings pane.
    ///
    /// Handed through rather than derived back out of `authorization`, because the mapping is lossy
    /// on purpose: `.restricted` and `.writeOnly` both become `.denied(explanation:)` there, and the
    /// pane needs to tell them apart to say the right sentence and offer the right control.
    public var storeAccess: CalendarAccess { store.access }

    /// Every calendar the user has, for the include-list. Empty when access is refused, which the
    /// pane says in words rather than by drawing an empty list.
    public var availableCalendars: [GlanceCalendar] { store.calendars }

    // MARK: - Diagnostics

    /// Counts only, for `--perf-report` and the export bundle. A title is the user's own words.
    public var eventCount: Int { published.events.count }

    public var announcementCount: Int { announced.count }

    public var hasWeather: Bool { published.weather != nil }

    // MARK: - The activities

    /// The two factories below are `public` for one caller: `--glance-demo`, which stages a meeting
    /// and a refused calendar with no EventKit involved. Building the activities there by hand
    /// instead would be a second definition of what an alert looks like, and a demo that diverged
    /// from the real thing is a demo that checks nothing.
    ///
    /// There is no factory for the day itself any more, and its singleton id has gone with it —
    /// the glance reaches the island as a `GlanceSnapshot` the pages read. See `publish`.
    public static func alertID(for event: GlanceEvent) -> ActivityID { ActivityID("calendar.alert.\(event.id)") }

    public static func meetingID(for event: GlanceEvent) -> ActivityID { ActivityID("calendar.meeting.\(event.id)") }

    /// An event about to start.
    ///
    /// A plain content-sized activity — a glyph, a title, a countdown — because that is all it has
    /// to say. `ActivityValue.countdown(until:)` rather than a formatted string, so IslandUI drives
    /// the numerals off the display link it is already running instead of this source re-publishing
    /// once a second.
    public static func alertActivity(for event: GlanceEvent, id: ActivityID, at instant: Date) -> BuiltInActivity {
        BuiltInActivity(
            id: id,
            kind: .calendarAlert,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: "calendar.badge.clock", tint: .neutral),
                trailing: ActivityContent(value: .countdown(until: event.start), tint: .neutral),
                compact: ActivityContent(
                    symbol: "calendar.badge.clock",
                    title: event.title,
                    value: .countdown(until: event.start),
                    tint: .neutral
                ),
                expanded: ActivityContent(
                    symbol: "calendar.badge.clock",
                    title: event.title,
                    subtitle: GlanceFormat.startsIn(event.start, from: instant),
                    value: .countdown(until: event.start),
                    tint: .neutral,
                    accessibilityLabel: sourceText(
                        "glance.alert.a11y",
                        "\(event.title), \(GlanceFormat.startsIn(event.start, from: instant))"
                    )
                )
            )
        )
    }

    /// A joinable meeting. Opens the island, because the button *is* the kind — collapsed it is a
    /// video glyph in the notch and the one thing it exists for is behind a click nobody has a
    /// reason to make. `ActivityKind.meeting.opensIsland` already says so.
    ///
    /// Like the glance, its expanded slot is empty and `GlanceLayerView` draws it, because a button
    /// is not sayable in a vocabulary of symbols and strings.
    public static func meetingActivity(for event: GlanceEvent, id: ActivityID) -> BuiltInActivity {
        let provider = event.meeting?.provider
        return BuiltInActivity(
            id: id,
            kind: .meeting,
            presentations: ActivityPresentations(
                leading: ActivityContent(
                    symbol: provider?.symbol ?? "video.fill",
                    tint: .neutral,
                    accessibilityLabel: sourceText("glance.meeting.a11y", "\(event.title), ready to join")
                ),
                trailing: ActivityContent(title: GlanceFormat.clock(event.start), tint: .neutral),
                compact: ActivityContent(
                    symbol: provider?.symbol ?? "video.fill",
                    title: event.title,
                    tint: .neutral
                ),
                expanded: .empty
            )
        )
    }
}
