import Foundation
import IslandActivities
import Testing

@testable import IslandSettings

@Suite("Glance settings")
@MainActor
struct GlanceSettingsTests {

    // Its own suite domain, never `UserDefaults.standard`: writing there from a test bundle lands
    // in the *test runner's* preference domain, where it survives the process and leaks into the
    // next run. `SettingsStorage` exists for the same reason.
    //
    // It used to be a `defaults(_:)` helper over `UserDefaults(suiteName:)`, which emptied the
    // domain on the way *in* and never on the way out — see `InMemoryDefaults` for what that cost.

    @Test("nothing picked means every calendar, which is what a first launch has")
    func emptyMeansAll() {
        // An empty include-list is what every user has before they first open the pane, and a glance
        // that showed nothing until somebody had visited Settings would look broken to everybody who
        // never does.
        #expect(GlanceSettings.defaults.includedCalendarIDs.isEmpty)
    }

    /// The default is **no place at all**, and that is the fix rather than a conservative choice.
    ///
    /// `usesCurrentLocation` defaulted to true, so a Mac that had never been asked for its location
    /// drew "Use my location" switched **on** and resolved nothing on every refresh — a feature
    /// reporting itself as running while showing nothing. The switch now cannot be on without the
    /// grant (`SettingsView.useCurrentLocationBinding`), so the stored default has to agree with it.
    @Test("a first launch has no place to ask about until somebody picks one")
    func defaultsToNoPlace() {
        #expect(!GlanceSettings.defaults.usesCurrentLocation)
        #expect(GlanceSettings.defaults.city.isEmpty)
        #expect(!GlanceSettings.defaults.hasPlace)
    }

    @Test("location on, or a city typed, is what counts as having somewhere to ask about")
    func hasPlace() {
        #expect(GlanceSettings(usesCurrentLocation: true).hasPlace)
        #expect(!GlanceSettings(usesCurrentLocation: false).hasPlace)
        #expect(!GlanceSettings(usesCurrentLocation: false, city: "   ").hasPlace)
        #expect(GlanceSettings(usesCurrentLocation: false, city: "London").hasPlace)
    }

    @Test("a partial record costs the user only the field that is unreadable")
    func lenientDecoding() throws {
        // The synthesised decoder is all-or-nothing, and here "all" is the whole glance
        // configuration — one field written by a build that spelled it differently would silently
        // put a user's calendars and their city back to the defaults together.
        let json = Data(#"{"city":"Lisbon","usesCurrentLocation":"nonsense"}"#.utf8)
        let decoded = try JSONDecoder().decode(GlanceSettings.self, from: json)
        #expect(decoded.city == "Lisbon")
        #expect(decoded.usesCurrentLocation == GlanceSettings.defaults.usesCurrentLocation)
    }

    @Test("an edit round-trips through the configuration record")
    func persistence() {
        let defaults = InMemoryDefaults()
        let store = SettingsStore(storage: UserDefaultsSettingsStorage(defaults: defaults))
        store.update {
            $0.glance.city = "Lisbon"
            $0.glance.usesCurrentLocation = false
            $0.glance.includedCalendarIDs = ["work"]
        }
        /* Reopened over the same store, which is what "reopening the domain" was standing in for:
           the assertion is that the edit survived being encoded, not that a file exists. */
        let reopened = SettingsStore(storage: UserDefaultsSettingsStorage(defaults: defaults))
        #expect(reopened.configuration.glance.city == "Lisbon")
        #expect(reopened.configuration.glance.usesCurrentLocation == false)
        #expect(reopened.configuration.glance.includedCalendarIDs == ["work"])
    }

    /// The half that was missing while the glance lived on its own key, and the reason it was moved:
    /// a record "Reset to Defaults" does not contain is a record it does not reset.
    @Test("Reset to Defaults reaches the glance")
    func resetReachesTheGlance() {
        let defaults = InMemoryDefaults()
        let store = SettingsStore(storage: UserDefaultsSettingsStorage(defaults: defaults))
        store.update {
            $0.glance.city = "Lisbon"
            $0.glance.usesCurrentLocation = false
        }
        #expect(store.configuration.glance != .defaults)

        store.resetToDefaults()
        #expect(store.configuration.glance == .defaults)
    }

    /// A v7 file has the glance parked on its own key and nothing under `glance`. It has to survive,
    /// or every early adopter's city and chosen calendars are silently discarded on upgrade.
    @Test("a schema 7 file keeps the glance it parked on its own key")
    func legacyKeyMigrates() throws {
        var parked = GlanceSettings.defaults
        parked.city = "Lisbon"
        parked.usesCurrentLocation = false
        UserDefaults.standard.set(try JSONEncoder().encode(parked), forKey: SettingsMigration.legacyGlanceKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsMigration.legacyGlanceKey) }

        let decoded = try SettingsMigration.decode(Data(#"{"schemaVersion":7}"#.utf8))
        #expect(decoded.glance.city == "Lisbon")
        #expect(decoded.glance.usesCurrentLocation == false)
    }

    /// A file that already carries `glance` was written by a build that had migrated, so the nested
    /// record is the live one and the parked key is a leftover the encoder is about to drop.
    @Test("the nested record wins over the key it was migrated from")
    func recordWinsOverLegacy() throws {
        var parked = GlanceSettings.defaults
        parked.city = "Lisbon"
        UserDefaults.standard.set(try JSONEncoder().encode(parked), forKey: SettingsMigration.legacyGlanceKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsMigration.legacyGlanceKey) }

        let json = #"{"schemaVersion":8,"glance":{"city":"Porto","usesCurrentLocation":false}}"#
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.glance.city == "Porto")
    }

    @Test("a corrupt blob falls back to defaults rather than refusing to launch")
    func corruptBlob() {
        let defaults = InMemoryDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsMigration.legacyGlanceKey)
        let store = SettingsStore(storage: UserDefaultsSettingsStorage(defaults: defaults))
        #expect(store.configuration.glance == .defaults)
    }
}

@Suite("Glance settings pane state")
struct GlanceSettingsStateTests {

    @Test("the copy is chosen from the authorization, never from an empty calendar list")
    func copyComesFromAccess() {
        // A denied store answers zero calendars, a valid predicate and an empty event list without
        // throwing — so a pane that inferred its words from `calendars.isEmpty` would tell somebody
        // who refused access that they own no calendars.
        let denied = GlanceSettingsState(calendarAccess: .denied, calendars: [])
        let emptyButGranted = GlanceSettingsState(calendarAccess: .granted, calendars: [])
        #expect(denied.calendarSummary != emptyButGranted.calendarSummary)
        // The substring is source-language: under `swift test` every lookup falls back to the
        // English `defaultValue`. `LocalizationCoverageTests` is what guards the other languages.
        #expect(denied.calendarSummary.contains("System Settings"))
    }

    @Test("every calendar state has something to say")
    func everyCalendarStateHasCopy() {
        for access in [CalendarAccess.granted, .notDetermined, .denied, .restricted, .writeOnly] {
            #expect(!GlanceSettingsState(calendarAccess: access).calendarSummary.isEmpty)
        }
    }

    @Test("the entitlement's absence outranks the location question")
    func entitlementOutranksLocation() {
        // There is no point offering a city to somebody whose build cannot ask about one.
        let unentitled = GlanceSettingsState(
            locationAccess: .granted,
            weatherIsAvailable: false,
            weatherExplanation: "Weather isn’t in this build of Isleta yet."
        )
        #expect(unentitled.weatherSummary == "Weather isn’t in this build of Isleta yet.")
    }

    @Test("refused location says the city works, rather than saying weather is broken")
    func deniedLocationIsNotAWall() {
        let denied = GlanceSettingsState(locationAccess: .denied, weatherIsAvailable: true)
        // The substring is source-language: under `swift test` every lookup falls back to the
        // English `defaultValue`. `LocalizationCoverageTests` is what guards the other languages,
        // and each of them names the city in its own words for the same reason.
        #expect(denied.weatherSummary.contains("city"))
    }
}
