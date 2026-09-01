import Foundation

/// What the calendar is allowed to tell us.
///
/// Its own enum rather than `EKAuthorizationStatus`, for the reason every seam in this package has
/// one: the pure half of the glance — which event is next, what the empty island should say — has to
/// be exercisable with no EventKit, no permission and no calendar on the machine.
///
/// ## This is the only thing that can tell a refusal from an empty life
///
/// Measured on macOS 27 against a genuinely denied store: `sources.count == 0`,
/// `calendars(for:).count == 0`, `defaultCalendarForNewEvents == nil`, the predicate builds
/// perfectly well (`CADEventPredicate`), and `events(matching:)` returns `[]` in 1–4 ms **without
/// throwing**. There is no error, no exception and no flag anywhere in that path. A user who has
/// refused Isleta and a user who has never made a calendar produce byte-identical results from every
/// call except this one.
///
/// So the empty state's words are chosen from `access` and never from `events.isEmpty` — "Grant
/// access in Settings" and "Nothing else today" are the same zero, and showing the wrong one is
/// either an app that nags a person who has nothing on, or an app that silently pretends to work.
public enum CalendarAccess: Equatable, Sendable {

    /// Full access. The only state that returns events.
    case granted

    /// Never asked. **Never retried in a loop** — see `CalendarSource.start()`.
    case notDetermined

    case denied

    /// Refused by policy rather than by the user — a managed Mac. Distinct from `denied` because
    /// the offer differs: there is no System Settings switch for the user to go and flip.
    case restricted

    /// Write-only. Authorises saving new events and returns **no calendars to read**, which is the
    /// exact opposite of what a "what's next" surface needs, and is why Isleta ships
    /// `NSCalendarsFullAccessUsageDescription` rather than the legacy key.
    case writeOnly

    /// Whether events can be expected.
    public var isReadable: Bool { self == .granted }

    /// Whether there is a System Settings switch the user could go and flip.
    ///
    /// **The discriminator for the button, and `restricted` is why it is not simply `!isReadable`.**
    /// A managed Mac has no switch — the refusal is the organisation's and the pane shows it greyed
    /// — so a button that walked somebody to a control they cannot use would be worse than no
    /// button. `writeOnly` is out for a different reason: the user *did* answer the prompt, and the
    /// only honest fix is the full-access prompt Isleta can no longer raise.
    ///
    /// `notDetermined` is out because it has a better offer than a trip to System Settings — the
    /// prompt itself. See `GlanceModel.onRequestCalendarAccess`.
    public var canBeGrantedInSettings: Bool { self == .denied }

    /// What the open island says when it has no events to show.
    ///
    /// One sentence per state, and each is written to be true *and* actionable. `granted` is the
    /// only one that is allowed to be cheerful about the emptiness, because it is the only one where
    /// the emptiness is real.
    ///
    /// **`denied` names the pane rather than reporting the state.** "Calendar access is off" was
    /// true and useless: it told somebody what had happened without telling them the one thing they
    /// can do about it, and macOS will not raise the permission dialog a second time, so there is
    /// nothing Isleta can offer except the trip to System Settings. See `canBeGrantedInSettings`,
    /// which is what puts a button next to this sentence.
    public var emptyStateMessage: String {
        switch self {
        case .granted: activityText("glance.empty.granted", "Nothing else today")
        case .notDetermined:
            activityText("glance.empty.notDetermined", "Isleta hasn’t asked for your calendar yet")
        case .denied:
            activityText("glance.empty.denied", "Turn on Calendar access in System Settings")
        case .restricted:
            activityText("glance.empty.restricted", "Calendar access is managed on this Mac")
        case .writeOnly:
            activityText("glance.empty.writeOnly", "Isleta can add events but not read them")
        }
    }
}

/// A calendar's own color, as sRGB components.
///
/// Components in a plain struct rather than an `NSColor` or a `CGColor`, for the reason this whole
/// file is where it is: IslandActivities contains no AppKit and no CoreGraphics, and a color that
/// arrived as a system object could not cross into a `Sendable` value. IslandUI resolves it into a
/// `Color` at the one place it is drawn, exactly as `ActivityTint` is resolved.
public struct GlanceTint: Equatable, Sendable {

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// One calendar the user owns, as a name and a stable identifier.
///
/// A value rather than an `EKCalendar` so the settings pane can list them without importing
/// EventKit, and so a stored selection survives a calendar being renamed.
public struct GlanceCalendar: Identifiable, Equatable, Sendable {

    public let id: String

    public let title: String

    /// Nil where the platform gave no color, which a subscribed calendar sometimes does.
    public let tint: GlanceTint?

    public init(id: String, title: String, tint: GlanceTint? = nil) {
        self.id = id
        self.title = title
        self.tint = tint
    }
}

/// One event, flattened out of EventKit into something that can be held.
///
/// **Held is the operative word, and it is why this type exists at all.** EventKit's own header is
/// explicit that every `EKEvent` a process is holding is invalid the moment `.EKEventStoreChanged`
/// arrives — the objects are faults into a store that has just moved underneath them, and reading
/// one after the notification is undefined rather than merely stale. Measured, that notification
/// arrives 8–10 ms after a commit, so "after the notification" is essentially always. A source that
/// diffed the `EKEvent`s it was holding against a fresh fetch would be diffing against corpses.
///
/// So nothing outside `EventKitCalendarStore` ever sees an `EKEvent`. The predicate is re-run and
/// this value is rebuilt, and because it is `Equatable` the rebuild is also the coalescer: one user
/// edit produces **two** callbacks about 2 s apart, and the second one publishes nothing because the
/// snapshot it produces is equal to the one already on the island.
public struct GlanceEvent: Identifiable, Equatable, Sendable {

    /// `eventIdentifier` plus the start instant.
    ///
    /// Not `eventIdentifier` alone: every occurrence of a recurring event shares one identifier, so
    /// a weekly standup would collapse to a single entry and "what's next" would show last week's.
    public let id: String

    public let title: String

    public let start: Date

    public let end: Date

    public let isAllDay: Bool

    /// Which calendar it came from, for the color dot and for the accessibility label.
    public let calendarID: String

    public let calendarTitle: String

    /// The calendar's color, so the open island can draw the dot the user already reads their week
    /// by. Carried on the event rather than looked up from `GlanceCalendar`, because the glance
    /// draws events and would otherwise need the calendar list on screen to color one row.
    public let calendarTint: GlanceTint?

    /// The join link, if the event carries one. See `MeetingLinkParser`.
    public let meeting: MeetingLink?

    /// EventKit's own identifier for the event, unqualified — what Calendar needs to be told which
    /// event to open.
    ///
    /// **Separate from `id`, which cannot be taken apart to recover it.** `id` is the identifier
    /// *plus* the occurrence's start, because every occurrence of a recurring event shares one
    /// EventKit identifier and a weekly standup keyed on the identifier alone collapses to a single
    /// entry. Splitting that back apart would mean assuming the separator never appears inside an
    /// identifier, which is not true of every CalDAV server — so the raw value is carried rather
    /// than reconstructed.
    ///
    /// Empty where there is none: a preview's fixture, and the one real case where EventKit hands
    /// back an event with no identifier at all. `GlanceEventLink` answers nil for it rather than
    /// building a URL that would open Calendar at nothing.
    public let externalID: String

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarID: String = "",
        calendarTitle: String = "",
        calendarTint: GlanceTint? = nil,
        meeting: MeetingLink? = nil,
        externalID: String = ""
    ) {
        self.externalID = externalID
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.calendarTint = calendarTint
        self.meeting = meeting
    }

    /// Whether `now` is inside the event.
    public func isUnderway(at now: Date) -> Bool { start <= now && now < end }

    /// How long until it starts. Negative once it has.
    public func timeUntilStart(from now: Date) -> TimeInterval { start.timeIntervalSince(now) }
}

/// Everything the glance surface draws, in one value.
///
/// One snapshot rather than two streams, because the island's height is decided from it *before* the
/// transition (`IslandController.expandedContentHeight`) and a weather reading arriving separately
/// would resize a surface the user is already reading. The weather is folded into the snapshot by
/// `CalendarSource`, which republishes; a snapshot equal to the last one publishes nothing.
public struct GlanceSnapshot: Equatable, Sendable {

    /// Chosen from this and never from `events.isEmpty` — see `CalendarAccess`.
    public var access: CalendarAccess

    /// Upcoming events, soonest first, already filtered to the calendars the user selected.
    public var events: [GlanceEvent]

    /// Nil until a reading lands, and nil forever where WeatherKit has no entitlement. The glance
    /// draws its calendar half either way — see `WeatherProvider`.
    public var weather: WeatherReading?

    /// The instant the snapshot describes. The day header is formatted from it, so a Mac left open
    /// across midnight redraws on the next refresh rather than insisting it is still yesterday.
    public var asOf: Date

    public init(
        access: CalendarAccess = .notDetermined,
        events: [GlanceEvent] = [],
        weather: WeatherReading? = nil,
        asOf: Date = Date()
    ) {
        self.access = access
        self.events = events
        self.weather = weather
        self.asOf = asOf
    }

    /// Whether there is anything at all worth putting on the island.
    ///
    /// Weather alone counts. A person with an empty calendar and 4°C outside still has something to
    /// glance at, and an island that showed nothing until they had a meeting would look broken to
    /// exactly the users with the least reason to open it.
    public var hasContent: Bool { !events.isEmpty || weather != nil }
}

/// The decisions the glance makes about time, kept away from EventKit so they can be checked at any
/// instant without waiting for one.
///
/// The same shape as `ActivityStack` and `WelcomeBackPolicy`: a pure function of a list and a
/// `Date`. Every bug this file could have is a bug about *when*, and a test that had to wait five
/// minutes to see one would not be written.
public enum GlancePolicy {

    /// How long before an event starts the island says so.
    ///
    /// Five minutes, which is the shortest lead that is still a warning rather than a report. It
    /// pairs with `ActivityKind.calendarAlert.defaultExpiry` — ten seconds — so the alert is on
    /// screen for ten of the three hundred seconds it is about, and is gone long before the meeting.
    public static let alertLead: TimeInterval = 300

    /// How close to the start a *joinable* event becomes a `.meeting` — the kind that carries a
    /// button and opens the island.
    ///
    /// A minute, deliberately much tighter than `alertLead`. An alert is information and can afford
    /// to be early; a Join button is an instruction, and one offered five minutes out is an
    /// instruction to arrive early to an empty room. It is also the point at which "join now" is
    /// unambiguous, which is what justifies opening the island unasked.
    public static let meetingLead: TimeInterval = 60

    /// How long after an event has started it is still worth offering to join.
    ///
    /// Two minutes. Past that the user is either in the call or has decided not to be, and an island
    /// still offering to join a meeting that began ten minutes ago is Isleta nagging.
    public static let meetingGrace: TimeInterval = 120

    /// How far ahead the source looks.
    ///
    /// Thirty-six hours rather than "the rest of today", so that at 11 pm the glance says what is
    /// happening at nine tomorrow instead of "Nothing else today" — which is true, useless, and the
    /// most likely moment for somebody to look. Well inside the four-year ceiling
    /// `predicateForEvents(withStart:end:calendars:)` silently clamps to.
    public static let lookAhead: TimeInterval = 36 * 3600

    /// How many events the open island lists. See `GlanceLayout.maximumRows`.
    public static let maximumEvents = 3

    /// Everything still ahead or underway, soonest first.
    ///
    /// All-day events sort **before** timed ones that start on the same day, because that is how a
    /// person reads a day: the thing that is true all of it, then the things that happen during it.
    /// Sorting purely by `start` puts an all-day event at midnight and therefore always first, which
    /// is the same answer by accident and the wrong answer the moment two days are in the window.
    public static func upcoming(
        in events: [GlanceEvent],
        at now: Date,
        limit: Int = maximumEvents,
        calendar: Calendar = .current
    ) -> [GlanceEvent] {
        let live = events.filter { $0.end > now }
        let sorted = live.sorted { first, second in
            let firstDay = calendar.startOfDay(for: first.start)
            let secondDay = calendar.startOfDay(for: second.start)
            if firstDay != secondDay { return firstDay < secondDay }
            if first.isAllDay != second.isAllDay { return first.isAllDay }
            if first.start != second.start { return first.start < second.start }
            return first.id < second.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// The one event the collapsed island names.
    ///
    /// **Timed events only, and an all-day event is never it.** The flank is 40pt of lit pixels
    /// beside the cutout and what it draws there is a time — "10:30". An all-day event has no time
    /// to draw, so the flank would say the one thing the sliver cannot render, and the user's
    /// actual next meeting would be invisible behind it. All-day events are still listed in the open
    /// island, where there is room for the word "All day".
    public static func next(in events: [GlanceEvent], at now: Date) -> GlanceEvent? {
        events
            .filter { !$0.isAllDay && $0.end > now }
            .min { first, second in
                first.start == second.start ? first.id < second.id : first.start < second.start
            }
    }

    /// The events that should be announcing themselves right now.
    ///
    /// Inside the lead and not yet started. Deliberately **not** "already started": an event that is
    /// underway is not news, it is a fact the user is living in, and an alert about it would fire on
    /// every refresh for the length of the meeting.
    public static func alerting(in events: [GlanceEvent], at now: Date) -> [GlanceEvent] {
        events.filter { event in
            guard !event.isAllDay else { return false }
            let until = event.timeUntilStart(from: now)
            return until > 0 && until <= alertLead
        }
    }

    /// The events with a join link that the user should be offered a button for.
    ///
    /// The window straddles the start — `meetingLead` before, `meetingGrace` after — because a call
    /// is joinable both a moment early and a moment late, and the two edges are chosen from
    /// different arguments. See the two constants.
    public static func joinable(in events: [GlanceEvent], at now: Date) -> [GlanceEvent] {
        events.filter { event in
            guard event.meeting != nil, !event.isAllDay else { return false }
            let until = event.timeUntilStart(from: now)
            return until <= meetingLead && until >= -meetingGrace
        }
    }

    /// The next instant at which any of the answers above would change.
    ///
    /// **This is what stops the calendar source owning a poll.** Time passing is the one input to
    /// this feature that no notification announces: `.EKEventStoreChanged` fires when the user
    /// *edits* a calendar and never when a meeting simply gets closer. The obvious answer is a
    /// minute timer, and §9 forbids one on the idle path.
    ///
    /// So the source arms exactly one `DispatchSourceTimer`, at this instant, and re-arms from the
    /// handler — the same shape `ActivityCoordinator` uses for the whole expiry model. On a Mac with
    /// nothing in the calendar it returns nil and there is no timer at all; on a busy day it fires a
    /// handful of times, each time doing something the user can see.
    ///
    /// Returns nil when nothing ahead can change anything, which is also what makes a denied
    /// calendar cost nothing: no events, no boundaries, no timer.
    public static func nextBoundary(in events: [GlanceEvent], at now: Date) -> Date? {
        var candidates: [Date] = []
        for event in events {
            // The three instants at which this event changes what the island says: it enters the
            // alert window, it becomes joinable, it starts, it stops being joinable, it ends.
            candidates.append(event.start.addingTimeInterval(-alertLead))
            if event.meeting != nil {
                candidates.append(event.start.addingTimeInterval(-meetingLead))
                candidates.append(event.start.addingTimeInterval(meetingGrace))
            }
            candidates.append(event.start)
            candidates.append(event.end)
        }
        return candidates.filter { $0 > now }.min()
    }
}

/// The glance's own formatting, on a plain `enum`.
///
/// Not `static func`s on a view: `View` conformance is main-actor isolated, so a formatter declared
/// on one is too, and the first nonisolated test to call it is an error under `Tools/check.sh`'s
/// `-warnings-as-errors`. `RecentsFormat` and `WeatherFormat` exist for the same reason.
public enum GlanceFormat {

    /// "10:30", in the user's own 12- or 24-hour setting.
    ///
    /// `Date.FormatStyle` with `.omitted` seconds rather than a hand-built string, because a
    /// hardcoded `HH:mm` shows 14:30 to somebody whose Mac says 2:30 PM — and that is the sort of
    /// wrongness nobody reports and everybody notices.
    public static func clock(_ date: Date, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        return date.formatted(style)
    }

    /// "in 4 min", "now", "in 2 hr".
    public static func startsIn(_ start: Date, from now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 30 { return activityText("glance.startsIn.now", "Starting now") }
        if seconds < 3600 {
            return activityText("glance.startsIn.minutes", "In \(Int((seconds / 60).rounded(.up))) min")
        }
        return activityText("glance.startsIn.hours", "In \(Int((seconds / 3600).rounded())) hr")
    }

    /// "Today", "Tomorrow", or the weekday. What the glance's day header says.
    ///
    /// - Parameter locale: threaded for the same reason `clock` threads it. `Date.formatted(_:)`
    ///   with no explicit locale reads `Locale.current`, which is the user's *region* — so a Mac set
    ///   to German with a British region drew "Heute" one line above "Wednesday". The two halves of
    ///   this one string have to come from the same place, and a caller that can pin `clock` and not
    ///   this one can only pin half a header.
    public static func day(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return activityText("glance.day.today", "Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return activityText("glance.day.tomorrow", "Tomorrow")
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.locale = locale
        return date.formatted(style)
    }

    /// When an event runs — "10:30 – 11:15" — or "All day".
    ///
    /// `Date.FormatStyle` over the range rather than two `clock` calls with a dash between them,
    /// and the difference is not cosmetic: the interval style drops what the two ends share, so a
    /// meeting from 6pm to 7:30pm reads "6:00 – 7:30 PM" with one meridiem rather than two. That is
    /// what makes a range fit a 236pt column beside a title, and it is decided per locale rather
    /// than by us — a 24-hour Mac has nothing to drop and gets both ends in full.
    ///
    /// - Parameter locale: threaded for the reason `clock` threads it — `Date.formatted` with no
    ///   locale reads the user's *region*, so a range and the header above it can otherwise come
    ///   from two different places.
    public static func timeRange(_ event: GlanceEvent, locale: Locale = .current) -> String {
        guard !event.isAllDay else { return activityText("glance.row.allDay", "All day") }
        // A zero-length event is a real thing people put in calendars, and an interval style hands
        // back an empty string for one — which would draw a row with a title and a blank line where
        // its time should be.
        guard event.end > event.start else { return clock(event.start, locale: locale) }
        var style = Date.IntervalFormatStyle.interval.hour().minute()
        style.locale = locale
        return (event.start..<event.end).formatted(style)
    }

    /// What one row's time column reads: "10:30", or "All day".
    public static func rowTime(_ event: GlanceEvent, locale: Locale = .current) -> String {
        event.isAllDay ? activityText("glance.row.allDay", "All day") : clock(event.start, locale: locale)
    }

    /// The short weekday — "Fri" — for the home page's date block.
    ///
    /// **Abbreviated, and formatted rather than localized by us.** `.abbreviated` is what
    /// `Date.FormatStyle` gives for the locale, which is the only way to be right about a language
    /// whose short weekday is not simply its long one cut to three letters. Deliberately *not*
    /// `day(_:relativeTo:)` above: that one says "Today", which is the right word beside a list of
    /// events and the wrong one above a numeral — "Today / 28" reads as two answers to one question.
    public static func weekday(_ date: Date, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.locale = locale
        return date.formatted(style)
    }

    /// The day of the month as a bare numeral — "28".
    ///
    /// No month, no suffix, no padding: it is drawn at 34pt under the weekday, where it is the one
    /// large thing on the column and needs no units. `.day(.defaultDigits)` rather than pulling the
    /// component out of a `Calendar` and interpolating it, so a locale with its own digits gets them.
    public static func dayOfMonth(_ date: Date, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.day(.defaultDigits)
        style.locale = locale
        return date.formatted(style)
    }
}

/// The URL that opens one event in Calendar.
///
/// ## `ical://ekevent` is undocumented, and it is the only door there is
///
/// EventKit can read an event and it can write one; it cannot ask Calendar to *show* one. The URL
/// scheme is what every third-party client on the platform uses for this and has worked for well
/// over a decade, but Apple has never written it down — so it is treated the way §8 treats every
/// private path: resolved at the edge, behind a value that can be tested without a calendar, with
/// a real feature underneath it if it goes. The fallback is `bareCalendar`, which opens Calendar on
/// today; a person who wanted the event is one keystroke away rather than nowhere.
///
/// **Neither form can be checked at runtime.** `NSWorkspace.open` answers `true` for a URL whose
/// scheme has a handler, whatever the handler then makes of the path — which is the shape of
/// "measure the effect, never the return value": the return says Calendar was launched and says
/// nothing about whether it found the event. So there is no branch to write here, and the choice
/// between the two spellings below is a decision rather than a fallback chain.
///
/// It is also why `AppDelegate` logs *which* of the two paths it took. "Calendar opened but not on
/// the event" has two causes that are identical from outside — EventKit handed us no identifier, or
/// it handed us one Calendar made nothing of — and without that line the only way to tell them
/// apart is to change one and try again.
///
/// **The plain form, after the occurrence-qualified one was tried on hardware and did not work.**
/// `dated` below prefixes the occurrence's start in UTC, which is what would pin a recurring event
/// to the instance the user is looking at rather than to the first in the series, and it is the
/// spelling several third-party clients are documented as using. On 2026-08-28 it opened Calendar
/// without opening the event. Kept, named, and deliberately not used, so that the next person to
/// reach for it knows it has already been reached for.
///
/// The cost of the plain form is real and bounded: a recurring event opens at the *series*, so a
/// weekly standup lands on whatever week it began. Every non-recurring event — most of a normal day
/// — opens exactly where it should.
public enum GlanceEventLink {

    /// The series form. What `urlString(for:)` returns.
    static func plain(identifier: String) -> String {
        "ical://ekevent/\(escaped(identifier))?method=show&options=more"
    }

    /// The occurrence-qualified form. Tried on hardware; it did not open the event.
    static func dated(identifier: String, start: Date) -> String {
        "ical://ekevent/\(utcStamp(start))/\(escaped(identifier))?method=show&options=more"
    }

    /// The identifier, made safe to be exactly one path component.
    ///
    /// **A CalDAV server's identifier is not a UUID and is not guaranteed to be URL-safe.** A local
    /// event gives EventKit a tidy `UUID:UUID`; an Exchange or Google account gives it whatever that
    /// server uses as a key, which in the wild includes slashes. One unescaped slash turns a single
    /// path component into two, and Calendar is then handed an identifier that ends where the slash
    /// was — which fails by opening the app at nothing rather than by erroring, and so looks exactly
    /// like every other way this can fail.
    ///
    /// `urlPathAllowed` minus the characters this path is *made* of, so the escaping cannot eat the
    /// structure it is there to protect.
    static func escaped(_ identifier: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier
    }

    /// Calendar with no event named — today, in whatever view the user left it in.
    public static let bareCalendar = "ical://"

    /// Where a click on this event should go, or nil where there is nothing to open.
    ///
    /// A `String` rather than a `URL` because this package has no business resolving one: the app
    /// shell owns `NSWorkspace`, and every other privacy and deep link in Isleta is spelled the
    /// same way for the same reason.
    public static func urlString(for event: GlanceEvent) -> String? {
        guard !event.externalID.isEmpty else { return nil }
        return plain(identifier: event.externalID)
    }

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC — the basic ISO 8601 form Calendar's own links use.
    ///
    /// Built by hand rather than through `DateFormatter`, and not for speed: a formatter carries a
    /// locale and a calendar, and both of them can put non-Gregorian digits or a non-Gregorian year
    /// into this string on a Mac set to Thai or Japanese-imperial. The stamp is a machine-readable
    /// key, not a date anybody reads, so it is composed from the components directly against a
    /// Gregorian calendar in UTC.
    static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
