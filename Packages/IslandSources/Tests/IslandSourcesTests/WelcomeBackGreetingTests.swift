import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The copy, and specifically the parts of it that are wrong for everybody who does not live in the
/// author's time zone and read the author's language.
@Suite("WelcomeBackGreeting")
struct WelcomeBackGreetingTests {

    private static func calendar(_ timeZoneID: String, locale: Locale = Locale(identifier: "en_US")) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        calendar.locale = locale
        return calendar
    }

    /// 2026-08-19 at `hour` local time in `calendar`.
    private static func date(hour: Int, in calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = hour
        components.minute = 41
        return calendar.date(from: components)!
    }

    // MARK: - Time of day

    @Test("the bands cover all twenty-four hours", arguments: 0..<24)
    func everyHourHasAGreeting(hour: Int) {
        let band = TimeOfDay(hour: hour)
        #expect(!band.greeting.isEmpty)
        switch hour {
        case 5..<12: #expect(band == .morning)
        case 12..<17: #expect(band == .afternoon)
        case 17..<22: #expect(band == .evening)
        default: #expect(band == .night)
        }
    }

    @Test("late at night the island says welcome back, not good night")
    func nightIsNotAFarewell() {
        // "Good night" is what you say leaving. The one band where the time-of-day phrasing would be
        // actively wrong is the one that falls back to the neutral line.
        #expect(TimeOfDay.night.greeting == "Welcome back")
        #expect(TimeOfDay.morning.greeting == "Good morning")
        #expect(TimeOfDay.afternoon.greeting == "Good afternoon")
        #expect(TimeOfDay.evening.greeting == "Good evening")
    }

    @Test("the hour is read in the user's time zone, not UTC")
    func hourIsLocal() {
        // The same instant, in two places. Reading the hour off the timestamp instead of out of the
        // calendar greets one of these two people with the other one's time of day, and it is
        // invisible to anyone testing in their own time zone.
        let auckland = Self.calendar("Pacific/Auckland")
        let losAngeles = Self.calendar("America/Los_Angeles")
        let instant = Self.date(hour: 9, in: auckland)

        #expect(WelcomeBackGreeting(at: instant, calendar: auckland).title == "Good morning")
        #expect(WelcomeBackGreeting(at: instant, calendar: losAngeles).title != "Good morning")
    }

    @Test("the greeting follows the clock through the day")
    func greetingFollowsTheDay() {
        let calendar = Self.calendar("America/New_York")
        let titles = [7, 14, 19, 23].map {
            WelcomeBackGreeting(at: Self.date(hour: $0, in: calendar), calendar: calendar).title
        }
        #expect(titles == ["Good morning", "Good afternoon", "Good evening", "Welcome back"])
    }

    // MARK: - The line underneath

    /// A deterministic generator, so the same seed picks the same line every run.
    ///
    /// `SystemRandomNumberGenerator` is untestable by construction, which is the whole reason
    /// `WelcomeBackGreeting` takes a generator at all — without one, every claim below would have to
    /// be "the subtitle is *one of* these five", which passes just as happily when the pools are
    /// wired to the wrong band.
    ///
    /// SplitMix64 rather than the obvious `struct { mutating func next() -> UInt64 { fixed } }`,
    /// which **hangs**. `randomElement(using:)` reaches `next(upperBound:)`, whose default
    /// implementation rejection-samples: `repeat { random = next() } while random < range`. A
    /// generator that always answers the same number either satisfies that immediately or never
    /// does, and for a five-element pool the value it never satisfies is zero.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func greeting(hour: Int, seed: UInt64 = 0, zone: String = "America/New_York") -> WelcomeBackGreeting {
        let calendar = Self.calendar(zone)
        var generator = SeededGenerator(seed: seed)
        return WelcomeBackGreeting(at: Self.date(hour: hour, in: calendar), calendar: calendar, using: &generator)
    }

    @Test("every band has something to say")
    func everyBandHasMessages() {
        // `subtitle` is optional because `ActivityContent.subtitle` is, not because a band may be
        // empty. An empty pool would make `randomElement` return nil and the island would draw the
        // greeting over a blank line, which reads as a truncation rather than as a choice.
        for band in TimeOfDay.allCases {
            #expect(!band.messages.isEmpty)
            #expect(band.messages.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("the line always belongs to the hour it is read at", arguments: 0..<24)
    func messageMatchesTheBand(hour: Int) {
        // The failure this exists for: pools wired to the wrong case, so the island tells somebody
        // at two in the morning to make a good day of it. Invisible in a screenshot taken at noon.
        let band = TimeOfDay(hour: hour)
        let calendar = Self.calendar("America/New_York")
        let date = Self.date(hour: hour, in: calendar)

        for seed in UInt64(0)..<24 {
            var generator = SeededGenerator(seed: seed)
            let subtitle = WelcomeBackGreeting(at: date, calendar: calendar, using: &generator).subtitle
            #expect(subtitle.map(band.messages.contains) == true)
        }
    }

    @Test("no morning line is ever read at night")
    func bandsDoNotOverlap() {
        // Stronger than the last test and worth stating separately: the pools are disjoint, so
        // "belongs to this band" and "does not belong to any other" are the same claim. A line
        // shared between two bands would make the test above pass while the copy drifted.
        for band in TimeOfDay.allCases {
            for other in TimeOfDay.allCases where other != band {
                #expect(Set(band.messages).isDisjoint(with: Set(other.messages)))
            }
        }
    }

    @Test("the line is drawn from the pool rather than built")
    func subtitleIsNotInterpolated() {
        // Nothing here concatenates, for the reason `TimeOfDay.greeting` gives: a line assembled
        // from a translated fragment and something else reads as machine output in any language
        // whose word order is not English's. Asserting identity with a pool entry is how that stays
        // true — a subtitle that had been formatted or padded would no longer be one of these.
        let subtitle = Self.greeting(hour: 9).subtitle
        #expect(TimeOfDay.morning.messages.contains(subtitle ?? ""))
    }

    @Test("the same clock can produce different lines")
    func theLineVaries() {
        // The point of the feature. Two greetings at the same instant differing only by the
        // generator have to be able to disagree, or the pool is decoration.
        // Enough seeds that a pool of five colliding on all of them is not a thing that happens.
        let lines = Set((UInt64(0)..<32).map { Self.greeting(hour: 9, seed: $0).subtitle })
        #expect(lines.count > 1)
    }

    @Test("the greeting above it does not vary")
    func theGreetingIsStable() {
        // Only the second line is random. The first is a fact about the hour, and an island that
        // said "Good morning" and "Morning" on alternate wakes would read as two products.
        let titles = Set((UInt64(0)..<32).map { Self.greeting(hour: 9, seed: $0).title })
        #expect(titles == ["Good morning"])
    }

    // MARK: - What reaches the island

    @Test("the greeting becomes a welcomeBack activity carrying its own copy")
    func activityCarriesTheCopy() {
        let calendar = Self.calendar("America/New_York")
        let greeting = WelcomeBackGreeting(at: Self.date(hour: 9, in: calendar), calendar: calendar)
        let activity = greeting.activity

        #expect(activity.kind == .welcomeBack)
        #expect(activity.id == ActivityKind.welcomeBack.singletonID)
        #expect(activity.priority == .prominent)
        #expect(activity.presentations.compact.title == greeting.title)
        #expect(activity.presentations.expanded.subtitle == greeting.subtitle)
        // The copy reaches the island whole. `welcomeBack` takes both halves and this is the only
        // place they are handed over, so a slot dropping one would show a greeting with no line.
        #expect(activity.presentations.expanded.subtitle?.isEmpty == false)
    }

    @Test("the greeting expires on its own, so nothing here needs a timer")
    func expiryComesFromTheKind() {
        // §9: the four second dwell is data on the activity and is served by the coordinator's one
        // scheduled sleep. A source that scheduled its own dismissal would be a second clock for the
        // same fact, and the one that fired first would win.
        let calendar = Self.calendar("America/New_York")
        let activity = WelcomeBackGreeting(at: Self.date(hour: 9, in: calendar), calendar: calendar).activity
        #expect(activity.expiry == .after(.seconds(4)))
    }
}
