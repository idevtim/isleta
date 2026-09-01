import IslandActivities
import SwiftUI

/// What the Glance pane needs from the running app, as one snapshot.
///
/// The same arrangement `SourceSettingsRow` uses, and for the same two reasons. The first is
/// layering: IslandSettings must build and preview with no permission granted (§3), so it cannot
/// import IslandSources — which links EventKit, CoreLocation, MapKit and WeatherKit. The app shell
/// is the only layer that sees both, and it hands the answers over as values.
///
/// The second is cost. Every field here is read live from the system: `EKEventStore` for the
/// authorization and the calendar list, `CLLocationManager` for the location status, a code-signing
/// query for the WeatherKit entitlement. `SettingsView.body` runs on every redraw — including once
/// per keystroke while a city is being typed — so it reads a **snapshot** refreshed when Isleta
/// comes back to the front, and never calls the provider from `body`. A permission can only change
/// while the user is away in System Settings, so coming back is exactly when the answer is stale.
/// No timer, per §9.
public struct GlanceSettingsState {

    /// **The only thing that can tell a refusal from a user with no calendars.** A denied store
    /// answers zero calendars, a valid predicate and an empty event list without throwing, so every
    /// sentence on this pane is chosen from here.
    public var calendarAccess: CalendarAccess

    /// Every calendar the user has, for the include-list. Empty when access is refused, which is
    /// why the pane says why rather than drawing an empty list.
    public var calendars: [GlanceCalendar]

    public var locationAccess: LocationAccess

    /// Whether weather is possible in this build at all. False in every build shipped today — see
    /// `WeatherKitProvider` for the entitlement and the provisioning profile a human has to add.
    public var weatherIsAvailable: Bool

    /// Why there is no weather, in the user's words. Nil when it is working.
    public var weatherExplanation: String?

    /// Ask for the calendar. Nil unless a prompt would actually show — which is only
    /// `.notDetermined`, because macOS will not raise the dialog twice and a button that visibly
    /// does nothing is worse than no button (§10, no nagging).
    public var requestCalendarAccess: (@MainActor () -> Void)?

    /// Ask for location, and hand back what the system answered.
    ///
    /// **The completion is what makes "Use my location" a switch rather than a claim.** The switch
    /// is drawn from `locationAccess` rather than from the stored setting, so it can only move once
    /// the grant is real — and the grant arrives from a dialog raised outside this window, after
    /// this pane's snapshot was taken. Without an answer coming back the switch would stay off under
    /// the user's finger until something else refreshed the snapshot.
    ///
    /// Nil unless asking would do something, on `requestCalendarAccess`'s rule. A refusal already
    /// given is `openPrivacySettings`' job.
    public typealias LocationRequest = @MainActor (@escaping @MainActor (LocationAccess) -> Void) -> Void
    public var requestLocationAccess: LocationRequest?

    /// Open System Settings at the right privacy pane, for a permission already refused.
    public var openPrivacySettings: (@MainActor (PrivacyPane) -> Void)?

    /// Places a half-typed city could mean.
    ///
    /// A closure for this pane's founding reason: the lookup is `MKLocalSearchCompleter`, MapKit
    /// lives in IslandSources, and IslandSettings must build and preview with no permission granted
    /// (§3). `CitySuggestion` is a pure value in IslandActivities precisely so this seam can exist —
    /// see that type, and `CitySearch` for what is behind it.
    ///
    /// `async`, and **not** debounced here. The search costs a network round trip and this pane's
    /// `body` runs once per keystroke, so something has to hold the letters back; the view is the
    /// only layer that knows a keystroke happened, and `SettingsView.citySuggestions` is where the
    /// wait lives. Nil in a build with no source hub running, which is every preview — and the field
    /// stays a working plain text field in that state rather than becoming a control that offers
    /// nothing.
    public var searchCities: (@MainActor (String) async -> [CitySuggestion])?

    /// Stop whatever search is outstanding — the field lost focus, or a place was chosen. Nil for
    /// `searchCities`' reason.
    public var cancelCitySearch: (@MainActor () -> Void)?

    /// Which pane of System Settings ▸ Privacy & Security to open.
    ///
    /// An enum rather than a URL string, so the deep links live in the app shell beside the two that
    /// already exist (`AudioBadgeAccessibility`, `BluetoothPrivacySettings`) rather than
    /// being invented a third time here.
    public enum PrivacyPane: Sendable {
        case calendars
        case location
    }

    public init(
        calendarAccess: CalendarAccess = .notDetermined,
        calendars: [GlanceCalendar] = [],
        locationAccess: LocationAccess = .notDetermined,
        weatherIsAvailable: Bool = false,
        weatherExplanation: String? = nil,
        requestCalendarAccess: (@MainActor () -> Void)? = nil,
        requestLocationAccess: LocationRequest? = nil,
        openPrivacySettings: (@MainActor (PrivacyPane) -> Void)? = nil,
        searchCities: (@MainActor (String) async -> [CitySuggestion])? = nil,
        cancelCitySearch: (@MainActor () -> Void)? = nil
    ) {
        self.calendarAccess = calendarAccess
        self.calendars = calendars
        self.locationAccess = locationAccess
        self.weatherIsAvailable = weatherIsAvailable
        self.weatherExplanation = weatherExplanation
        self.requestCalendarAccess = requestCalendarAccess
        self.requestLocationAccess = requestLocationAccess
        self.openPrivacySettings = openPrivacySettings
        self.searchCities = searchCities
        self.cancelCitySearch = cancelCitySearch
    }

    /// What the calendar card says under its title.
    ///
    /// Five states and five sentences, and the point of writing them out is that four of them are
    /// invisible to code: a denied calendar and an empty one are the same zero everywhere except
    /// `calendarAccess`, so a pane that inferred its copy from `calendars.isEmpty` would tell a user
    /// who has refused access that they own no calendars.
    public var calendarSummary: String {
        switch calendarAccess {
        case .granted:
            calendars.isEmpty
                ? settingsText(
                    "glance.calendars.summary.granted.empty",
                    "Isleta can see your calendars, and there are none on this Mac yet."
                )
                : settingsText(
                    "glance.calendars.summary.granted",
                    "Pick which calendars the island shows. With none picked it shows them all."
                )
        case .notDetermined:
            settingsText("glance.calendars.summary.notDetermined", """
                Isleta hasn’t asked for your calendar yet. Your events are never stored, never sent \
                anywhere and never written to Isleta’s logs.
                """)
        case .denied:
            settingsText("glance.calendars.summary.denied", """
                Calendar access is off, so the island has nothing to show for your day. Turning it on \
                in System Settings brings back what’s next.
                """)
        case .restricted:
            settingsText(
                "glance.calendars.summary.restricted",
                "Calendar access is managed on this Mac. Nothing you change in Isleta will alter that."
            )
        case .writeOnly:
            settingsText("glance.calendars.summary.writeOnly", """
                Isleta has write-only calendar access, which authorises adding events and returns none \
                to read. Full access is what the island needs.
                """)
        }
    }

    /// What the weather card says.
    ///
    /// The entitlement comes first, because it makes every other question moot: there is no point
    /// offering a city to somebody whose build cannot ask about one.
    public var weatherSummary: String {
        if let weatherExplanation { return weatherExplanation }
        switch locationAccess {
        case .granted:
            return settingsText(
                "glance.weather.summary.granted",
                "The island shows the weather where you are, or in a city you pick."
            )
        case .notDetermined:
            return settingsText("glance.weather.summary.notDetermined", """
                Isleta hasn’t asked for your location. You can type a city instead — the weather \
                works either way.
                """)
        case .denied, .restricted:
            return settingsText("glance.weather.summary.denied", """
                Location is off, so type a city. The weather works exactly the same; Isleta just \
                asks about there instead of here.
                """)
        }
    }
}
