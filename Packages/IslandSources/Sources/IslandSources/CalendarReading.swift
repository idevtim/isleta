import EventKit
import Foundation
import IslandActivities
import IslandKit

/// The seam between the glance and EventKit.
///
/// Everything above this protocol speaks `GlanceEvent`, `GlanceCalendar` and `CalendarAccess`;
/// nothing above it has ever seen an `EKEvent`. That is not tidiness, it is the one rule EventKit
/// insists on and does not enforce: **every `EKEvent` a process is holding is invalid the moment
/// `.EKEventStoreChanged` arrives.** The objects are faults into a store that has moved underneath
/// them. Re-run the predicate; never diff what you were holding.
///
/// It is also what makes the glance testable. `UnavailableCalendarStore` and a stub satisfy this in
/// a test bundle with no calendar, no permission and no store, which is where every decision in
/// `GlancePolicy` is actually checked.
@MainActor
public protocol CalendarReading: AnyObject {

    /// Read live, never cached — the user can change it in System Settings while Isleta runs.
    var access: CalendarAccess { get }

    /// Ask. **Never called from `start()`** — see `CalendarSource`.
    func requestAccess(_ completion: @escaping @MainActor (CalendarAccess) -> Void)

    /// Every calendar the user has, for the Settings pane's include-list.
    var calendars: [GlanceCalendar] { get }

    /// Events in a window, already flattened and already parsed for a join link.
    ///
    /// - Parameter calendarIDs: nil means every calendar. An **empty set** also means every
    ///   calendar, and that is a decision rather than a slip: an empty include-list is what a user
    ///   has the moment before they pick one, and a glance that showed nothing until they had
    ///   visited Settings would look broken to everybody who never does.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [GlanceEvent]

    /// Push. Fires 8–10 ms after a commit and **twice per user edit** — see `CalendarSource`.
    func observeChanges(_ handler: @escaping @MainActor () -> Void)

    func stopObserving()
}

/// The real one.
///
/// # The permission key matters, and the *missing* key is the trap
///
/// Isleta ships **`NSCalendarsFullAccessUsageDescription`** and calls
/// `requestFullAccessToEvents`. Write-only access authorises *saving* new items and returns **no
/// calendars to read**, which is the exact opposite of what a "what's next" surface needs.
///
/// Three bundled probes on macOS 27, each launched with `open` so each was its own responsible
/// process:
///
/// | Info.plist key | Result |
/// |---|---|
/// | `NSCalendarsFullAccessUsageDescription` | prompt, `granted=true` at **1,988 ms**, status → 3 |
/// | `NSCalendarsUsageDescription` (legacy only) | prompt, `granted=true` at **2,339 ms**, status → 3 |
/// | *no calendar key at all* | **`granted=false`, `err=nil`, in 9 ms. No prompt. No crash. Nothing logged. Status stays `notDetermined`.** |
///
/// The legacy key still works — `tccd` carries all three names and falls back — but that is a
/// fallback rather than a license. **The no-key row is the one to remember.** Calendar does not
/// abort the way a missing `NSBluetoothAlwaysUsageDescription` aborts, so an app with no key can
/// call `requestFullAccessToEvents` forever, get a plausible-looking `false` every time, never raise
/// a prompt and never advance. A source that retries on `.notDetermined` becomes a silent 9 ms loop.
/// `CalendarSource` therefore never retries on that state, and this is where the reason is written
/// down.
///
/// # And the rebuild trap, reproduced live
///
/// Recompiling and re-signing an already-granted ad-hoc probe left its next launch reading
/// `authorizationStatus = 0` — **`notDetermined`, not `denied`**. Expect
/// `tccutil reset Calendar com.tryisleta.isleta` to join the Accessibility reset in the dev loop.
///
/// # Costs, measured
///
/// Keeping the store alive costs **0.0010 % CPU** and about **+0.7 MB** over 20 s with zero
/// spontaneous callbacks. A warm one-day fetch is 2 ms; a 14-day fetch over 14 calendars is 10–12 ms.
/// `predicateForEvents(withStart:end:calendars:)` silently **clamps any range longer than four years
/// to the first four**, which is irrelevant to "what's next" and would matter to a year view.
@MainActor
public final class EventKitCalendarStore: CalendarReading {

    private let store = EKEventStore()

    private var observer: (any NSObjectProtocol)?

    public init() {}

    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        // A status this build has never heard of is not evidence of a refusal, and treating it as
        // one would put "Calendar access is off" under an island that is working.
        @unknown default: .notDetermined
        }
    }

    /// # EventKit answers on a background queue, and `assumeIsolated` here is a crash
    ///
    /// This was `MainActor.assumeIsolated`, and it **killed the app the first time a real person
    /// clicked Allow** — shipped in 2.0.0 and found within a minute of installing it.
    /// `requestFullAccessToEvents` delivers its completion on an arbitrary background queue, so the
    /// isolation check fails inside `dispatch_assert_queue` and the process dies with no crash
    /// report and nothing in our own log after the "requested" line.
    ///
    /// **This is the `IOBluetooth` trap in a third framework**, and CLAUDE.md already draws the
    /// distinction that makes it dangerous: `CLLocationManager`'s delegate *may* use
    /// `assumeIsolated`, because CoreLocation delivers on the run loop its manager was created on;
    /// `IOBluetooth` may not, because it delivers on CoreBluetooth's XPC queue. **The two look
    /// identical in the source.** EventKit is the second of that kind, and there was no reason to
    /// assume it was the first — the assumption was never measured, only inherited.
    ///
    /// No test could catch it. A test bundle has no usage string, so the request answers in 9 ms on
    /// the calling thread and `assumeIsolated` succeeds; only a real grant, from a real launch,
    /// takes the background queue. The one check that would have seen it is the one CLAUDE.md names
    /// as the only one that counts — `open -a`, and then *using* the thing.
    ///
    /// `error` is reduced to a `String` before the hop rather than captured: `any Error` is not
    /// `Sendable`, and carrying it across would be a second concurrency problem in the fix for the
    /// first.
    public func requestAccess(_ completion: @escaping @MainActor (CalendarAccess) -> Void) {
        store.requestFullAccessToEvents { [weak self] granted, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                // **The `granted` flag is not read here, and that is deliberate.** With no usage key
                // it answers false with a nil error in 9 ms while the status stays `notDetermined`,
                // so believing it would record a refusal that never happened — and a refusal is what
                // stops Settings offering the prompt again. The status is the only fact.
                let access = self.access
                if let failure {
                    IslandLog.calendar.info("calendar access request failed: \(failure)")
                }
                IslandLog.calendar.info("calendar access is now \(access) (reported granted=\(granted))")
                completion(access)
            }
        }
    }

    public var calendars: [GlanceCalendar] {
        // Asked unconditionally rather than behind an `access == .granted` guard, because the answer
        // is the same empty array either way and the guard would imply the two are distinguishable
        // here. They are not — that is `access`'s entire job.
        store.calendars(for: .event).map { calendar in
            GlanceCalendar(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                tint: Self.tint(of: calendar.cgColor)
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [GlanceEvent] {
        guard end > start else { return [] }
        let all = store.calendars(for: .event)
        // nil *and* empty both mean "every calendar" — see the protocol. `nil` is also what
        // `predicateForEvents` itself wants for that, so the filtered list is only built when there
        // is genuinely a subset.
        let selected: [EKCalendar]? = {
            guard let calendarIDs, !calendarIDs.isEmpty else { return nil }
            let matching = all.filter { calendarIDs.contains($0.calendarIdentifier) }
            // An include-list naming only calendars that have since been deleted would otherwise
            // filter everything out, and the user would see an empty glance with no way to tell why.
            return matching.isEmpty ? nil : matching
        }()

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate).compactMap(Self.glanceEvent(from:))
    }

    /// Flattens one `EKEvent` into a value that can outlive it.
    ///
    /// This is the **only** place in Isleta that touches an `EKEvent`'s fields, and it does all of
    /// its reading before returning — see the type's note about faults going invalid. Everything it
    /// reads is user content, and none of it is logged at any level.
    private static func glanceEvent(from event: EKEvent) -> GlanceEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        // A canceled or declined event is still returned by the predicate. Showing one is worse
        // than showing nothing: the island would name a meeting the user has already said no to.
        guard event.status != .canceled else { return nil }
        let identifier = event.eventIdentifier ?? UUID().uuidString
        return GlanceEvent(
            // The identifier **plus the start**. Every occurrence of a recurring event shares one
            // `eventIdentifier`, so a weekly standup keyed on the identifier alone collapses to a
            // single entry — and "what's next" then shows last week's.
            id: "\(identifier)@\(start.timeIntervalSinceReferenceDate)",
            title: event.title ?? "Event",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            calendarTint: Self.tint(of: event.calendar?.cgColor),
            // `notes` first, `url` second, `location` last — the order the fields actually carry a
            // link in, which is not the order their names suggest. See `MeetingLinkParser`.
            meeting: MeetingLinkParser.firstLink(
                notes: event.notes,
                url: event.url,
                location: event.location
            ),
            // Unqualified, unlike `id` above — see `GlanceEvent.externalID`. This is what a click
            // on the event hands to Calendar.
            externalID: identifier
        )
    }

    public func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        stopObserving()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    public func stopObserving() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    /// sRGB components, or nil where the color could not be converted.
    ///
    /// Components rather than the `CGColor` itself, because `GlanceCalendar` is `Sendable` and
    /// crosses into a package with no CoreGraphics color in it. Grayscale calendars exist and
    /// report two components, which is why the count is checked rather than assumed to be four.
    private static func tint(of color: CGColor?) -> GlanceTint? {
        guard let color,
              let converted = color.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
              ),
              let parts = converted.components,
              parts.count >= 3
        else { return nil }
        return GlanceTint(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}

/// The store for a build, a preview or a test with no calendar.
///
/// `NullProvider`'s and `UnavailableBluetoothMonitor`'s counterpart. It reports `.denied` rather than
/// `.notDetermined`, which looks like the pessimistic choice and is the correct one: `notDetermined`
/// is the state that offers the user a prompt, and offering a prompt from a build that has no store
/// to grant access to would be a button that visibly does nothing.
@MainActor
public final class UnavailableCalendarStore: CalendarReading {

    /// What a caller wants this stub to say. Defaults to denied; a test that is checking the
    /// *granted* path hands events in through `events`.
    public var access: CalendarAccess

    public var events: [GlanceEvent]

    public var calendars: [GlanceCalendar]

    private var handler: (@MainActor () -> Void)?

    public init(
        access: CalendarAccess = .denied,
        events: [GlanceEvent] = [],
        calendars: [GlanceCalendar] = []
    ) {
        self.access = access
        self.events = events
        self.calendars = calendars
    }

    public func requestAccess(_ completion: @escaping @MainActor (CalendarAccess) -> Void) {
        completion(access)
    }

    public func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [GlanceEvent] {
        guard access.isReadable else { return [] }
        return events.filter { $0.end > start && $0.start < end }
    }

    public func observeChanges(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    public func stopObserving() { handler = nil }

    /// Pretends the store changed, so a test can exercise the coalescing without a calendar.
    public func simulateChange() { handler?() }
}

/// Where System Settings puts the two privacy lists the glance depends on.
///
/// Spelled beside the store rather than in the app shell for the reason `BluetoothPrivacySettings`
/// and `AudioBadgeAccessibility` are: the pane name and the state that sends a user to it
/// belong in one place, and a deep link invented at the call site is a string nobody re-checks when
/// Apple renames a pane.
///
/// Location's is `Privacy_LocationServices` and **not** a TCC pane at all — location authorization
/// lives in `/var/db/locationd/clients.plist` rather than in `tccd`'s table (see
/// `CoreLocationPlaceResolver`). The URL scheme is the same; what is behind it is not.
public enum GlancePrivacySettings {

    public static let calendarsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    public static let locationURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
}
