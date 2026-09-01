import Foundation
import IslandActivities
import IslandKit
import Observation

/// What the user has asked the glance to show, and where to ask about the weather.
///
/// # This record does not live in `IsletaConfiguration`, and it must
///
/// **It belongs there, and it is here because a shared struct could not be touched safely.** Adding
/// a stored property to `IsletaConfiguration` is the cross-package memory-layout trap CLAUDE.md
/// documents at length — dependent packages keep the old layout and read every field at the wrong
/// offset, with no compile error and a segfault three packages away — so a field appended to it
/// belongs in a change that is *only* that, made by whoever owns the schema, and not smuggled in
/// beside a feature.
///
/// So this is a **queued integration, not a design.** What it should become, in one edit, by the
/// integrator:
/// Lived on its own `UserDefaults` key for exactly one release, and is now in
/// `IsletaConfiguration` where it belongs — see `SettingsMigration.migrateV7ToV8`, which brought it
/// home. The parking was deliberate and its cost was written down rather than hidden: Stage 1 was
/// built beside three other agents in one tree, and appending a stored property to a shared struct
/// is the cross-package layout trap CLAUDE.md documents — dependent packages keep the old layout and
/// read every field at the wrong offset, with no compile error. So the record waited for an
/// integrator to move it, and until it moved **"Reset to Defaults" did not reach the glance**.
///
public struct GlanceSettings: Equatable, Sendable {

    /// Which calendars the glance includes, by `EKCalendar.calendarIdentifier`.
    ///
    /// **Empty means all**, and that is a decision rather than a slip. An empty include-list is what
    /// every user has the moment before they first open this pane, and a glance that showed nothing
    /// until somebody had visited Settings would look broken to everybody who never does. Storing
    /// an *exclude* list instead would answer that — and would then silently hide every calendar
    /// added after the choice was made, which is the same failure pointing the other way.
    public var includedCalendarIDs: Set<String>

    /// Whether the weather follows the user.
    ///
    /// False is not a degraded state: WeatherKit takes a `CLLocation` and has no opinion about where
    /// it came from, so a typed city gives a fully working weather island with the location
    /// permission refused or never asked for. That is what makes "use my location" a toggle rather
    /// than a wall, which is the same bar onboarding sets — Continue is live on every page.
    ///
    /// **False by default, and it must be.** True was the shipped default, and it made the switch a
    /// claim rather than a fact: a Mac that had never been asked for its location drew the switch
    /// on, asked CoreLocation for a place on every refresh, and got `.noPlace` back every time — a
    /// feature reporting itself as on while showing nothing. The switch now says what is true, so
    /// somebody who has not granted location starts with no place at all and picks one.
    public var usesCurrentLocation: Bool

    /// The city to ask about when `usesCurrentLocation` is false. Geocoded once and remembered.
    public var city: String

    public init(
        includedCalendarIDs: Set<String> = [],
        usesCurrentLocation: Bool = false,
        city: String = ""
    ) {
        self.includedCalendarIDs = includedCalendarIDs
        self.usesCurrentLocation = usesCurrentLocation
        self.city = city
    }

    public static let defaults = GlanceSettings()

    /// Whether the weather has anywhere to ask about at all.
    ///
    /// A user who turned location off and typed nothing has asked for no weather, and the pane says
    /// so rather than leaving a card that is silently always empty. That is also where a new install
    /// starts, since `usesCurrentLocation` defaults to false and the city to empty.
    public var hasPlace: Bool {
        usesCurrentLocation || !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension GlanceSettings: Codable {

    enum CodingKeys: String, CodingKey {
        case includedCalendarIDs
        case usesCurrentLocation
        case city
    }

    /// Per-key fallback, for the reason `SourceToggles`' decoder has it: a record written by a build
    /// that did not have one of these must not cost the user the three it did have. The synthesised
    /// decoder is all-or-nothing, and here "all" is the whole glance configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GlanceSettings.defaults

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key))?.flatMap { $0 } ?? fallback
        }

        includedCalendarIDs = value(.includedCalendarIDs, defaults.includedCalendarIDs)
        usesCurrentLocation = value(.usesCurrentLocation, defaults.usesCurrentLocation)
        city = value(.city, defaults.city)
    }
}
