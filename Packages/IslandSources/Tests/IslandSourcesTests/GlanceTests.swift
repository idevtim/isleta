import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A fixed instant, so every "in five minutes" below means the same five minutes on every machine.
private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(
    _ title: String = "Standup",
    at offset: TimeInterval,
    lasting: TimeInterval = 1800,
    allDay: Bool = false,
    meeting: MeetingLink? = nil,
    id: String? = nil
) -> GlanceEvent {
    GlanceEvent(
        id: id ?? "\(title)@\(offset)",
        title: title,
        start: noon.addingTimeInterval(offset),
        end: noon.addingTimeInterval(offset + lasting),
        isAllDay: allDay,
        meeting: meeting
    )
}

private let zoom = MeetingLink(
    provider: .zoom,
    url: URL(string: "https://us02web.zoom.us/j/1234567890")!
)

@Suite("Calendar source")
@MainActor
struct CalendarSourceTests {

    private func source(
        access: CalendarAccess,
        events: [GlanceEvent] = [],
        at instant: Date = noon
    ) -> (CalendarSource, UnavailableCalendarStore) {
        let store = UnavailableCalendarStore(access: access, events: events)
        let source = CalendarSource(store: store, now: { instant })
        return (source, store)
    }

    // MARK: - Denied, which is the state that has to work

    @Test("a denied calendar publishes nothing and says why")
    func deniedPublishesNothing() {
        let (source, _) = source(access: .denied)
        var presented: [any IslandActivity] = []
        var snapshots: [GlanceSnapshot] = []
        source.onActivity = { presented.append($0) }
        source.onSnapshot = { snapshots.append($0) }
        source.start()

        #expect(presented.isEmpty)
        #expect(snapshots.last?.access == .denied)
        #expect(snapshots.last?.events.isEmpty == true)
        guard case .denied(let explanation) = source.authorization else {
            Issue.record("a denied store should report a denied authorization")
            return
        }
        // §10: what granting would unlock, not what failed.
        #expect(explanation.contains("System Settings"))
    }

    @Test("a denied calendar arms no timer and holds no events")
    func deniedCostsNothing() {
        let (source, _) = source(access: .denied, events: [event("Standup", at: 600)])
        source.start()
        #expect(source.eventCount == 0)
        #expect(source.announcementCount == 0)
        source.stop()
    }

    @Test("never asked is undetermined, which is the state that gets the offer")
    func undeterminedIsOffered() {
        let (source, _) = source(access: .notDetermined)
        #expect(source.authorization == .undetermined)
    }

    @Test("requesting access is a no-op unless nobody has been asked")
    func requestOnlyWhenUndetermined() {
        // macOS will not show the dialog twice, so a second ask after a refusal is a control that
        // visibly does nothing — and there is deliberately no retry anywhere, because with no usage
        // key the request answers a plausible-looking false in 9 ms and never prompts.
        let (source, store) = source(access: .denied)
        var answered: CalendarAccess?
        source.requestAccessFromUserInitiatedMoment { answered = $0 }
        #expect(answered == .denied)
        #expect(store.access == .denied)
    }

    @Test("write-only is reported as denied, because it cannot read")
    func writeOnlyIsDenied() {
        let (source, _) = source(access: .writeOnly)
        guard case .denied = source.authorization else {
            Issue.record("write-only cannot read and must not report as granted")
            return
        }
    }

    // MARK: - Granted

    @Test("the day and the sky reach the island as a snapshot, never as an activity")
    func theGlanceIsNotAnActivity() {
        // The glance stood on the stack as an ambient activity through 2.0 and was withdrawn. It
        // never expires and a day with anything in it is the ordinary case, so it held the leading
        // sliver forever — and `ActivityKind.nowPlaying` wants that sliver too. A resting island
        // therefore drew a calendar glyph where the album cover belongs, and the track lip, which
        // `IslandScreenModel.trackLipContent` gates on Now Playing owning that sliver, could not
        // fire at all on a Mac with a single event in the diary.
        let (source, _) = source(access: .granted, events: [event("Standup", at: 1800)])
        var presented: [any IslandActivity] = []
        var snapshots: [GlanceSnapshot] = []
        source.onActivity = { presented.append($0) }
        source.onSnapshot = { snapshots.append($0) }
        source.start()

        #expect(!presented.contains { $0.kind == .glance })
        // And the surface itself still arrives, by the route the pages read.
        #expect(snapshots.last?.events.isEmpty == false)
    }

    /// A reading with no bearing on any test's arithmetic beyond being present.
    private var cloudy: WeatherReading {
        WeatherReading(temperatureCelsius: 4, conditionDescription: "Cloudy", symbolName: "cloud.fill")
    }

    @Test("weather with no diary still reaches the page")
    func weatherAloneCounts() {
        // The two halves of the glance arrive independently and either is worth the page on its
        // own — a day with nothing in it and a sky doing something is the ordinary weekend.
        let (source, _) = source(access: .granted)
        var snapshots: [GlanceSnapshot] = []
        source.onSnapshot = { snapshots.append($0) }
        source.start()
        source.setWeather(
            WeatherReading(temperatureCelsius: 4, conditionDescription: "Cloudy", symbolName: "cloud.fill")
        )
        #expect(snapshots.last?.weather != nil)
        #expect(snapshots.last?.events.isEmpty == true)
    }

    // MARK: - Announcements

    @Test("an event inside the lead is announced once, not once per refresh")
    func alertAnnouncedOnce() {
        let soon = event("Standup", at: 120)
        let (source, _) = source(access: .granted, events: [soon])
        var alerts: [any IslandActivity] = []
        source.onActivity = { if $0.kind == .calendarAlert { alerts.append($0) } }
        source.start()
        source.refresh()
        source.refresh()
        // Re-publishing would restart a dwell that is already running — the rule
        // `BluetoothDeviceSource.recentlyAnnounced` enforces for a burst of connect notifications.
        #expect(alerts.count == 1)
    }

    @Test("a joinable meeting suppresses the alert about the same event")
    func meetingOutranksItsOwnAlert() {
        // The meeting has already opened the island with a button on it. A second island saying the
        // same meeting is about to start is the same news twice, and the button is the useful half.
        let soon = event("Standup", at: 30, meeting: zoom)
        let (source, _) = source(access: .granted, events: [soon])
        var kinds: [ActivityKind] = []
        source.onActivity = { kinds.append($0.kind) }
        source.start()
        #expect(kinds.contains(.meeting))
        #expect(!kinds.contains(.calendarAlert))
    }

    @Test("the user's two switches gate the two announcements")
    func togglesAreHonored() {
        let soon = event("Standup", at: 30, meeting: zoom)
        let (source, _) = source(access: .granted, events: [soon])
        source.publishesAlerts = false
        source.publishesMeetings = false
        var kinds: [ActivityKind] = []
        source.onActivity = { kinds.append($0.kind) }
        source.start()
        #expect(!kinds.contains(.meeting))
        #expect(!kinds.contains(.calendarAlert))
        // With both switched off this source has nothing at all to put on the stack: the day and
        // the sky are a snapshot, not an activity. See `theGlanceIsNotAnActivity`.
        #expect(kinds.isEmpty)
    }

    @Test("stopping withdraws everything it put up")
    func stopRetracts() {
        let soon = event("Standup", at: 120)
        let (source, _) = source(access: .granted, events: [soon])
        var dismissed: [ActivityID] = []
        source.onDismiss = { dismissed.append($0) }
        source.start()
        source.stop()
        // A source that stops without retracting leaves an island saying a meeting starts in four
        // minutes with nothing running to correct it. The announcements are the whole of what it
        // has to retract — nothing standing is left on the stack to withdraw.
        #expect(dismissed.contains(CalendarSource.alertID(for: soon)))
    }

    // MARK: - Coalescing

    @Test("the second change notification for one edit publishes nothing")
    func doubleNotificationIsCoalesced() {
        // Measured: one user-visible edit produced two callbacks 2,019 ms apart. Undeduplicated
        // that is two full re-fetches and two islands for one thing the user did. The re-run
        // predicate rebuilds an *equal* snapshot, and equality is what stops the second publish.
        let (source, store) = source(access: .granted, events: [event("Standup", at: 1800)])
        // Counted as snapshots, which is now the source's only standing output — see
        // `theGlanceIsNotAnActivity`.
        var glances = 0
        source.onSnapshot = { _ in glances += 1 }
        source.start()
        #expect(glances == 1)
        store.simulateChange()
        store.simulateChange()
        #expect(glances == 1)
    }

    @Test("a real edit does publish")
    func realEditPublishes() {
        let (source, store) = source(access: .granted, events: [event("Standup", at: 1800)])
        // Counted as snapshots, which is now the source's only standing output — see
        // `theGlanceIsNotAnActivity`.
        var glances = 0
        source.onSnapshot = { _ in glances += 1 }
        source.start()
        store.events = [event("Standup moved", at: 2400)]
        store.simulateChange()
        #expect(glances == 2)
    }

    @Test("start is idempotent")
    func startTwice() {
        let (source, _) = source(access: .granted, events: [event("Standup", at: 1800)])
        // Counted as snapshots, which is now the source's only standing output — see
        // `theGlanceIsNotAnActivity`.
        var glances = 0
        source.onSnapshot = { _ in glances += 1 }
        source.start()
        source.start()
        #expect(glances == 1)
    }
}
