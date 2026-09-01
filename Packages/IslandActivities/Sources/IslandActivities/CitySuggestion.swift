import Foundation

/// One place the user could mean, offered while they are typing a city into Settings.
///
/// # Why this is here and not beside the thing that produces it
///
/// It is produced in IslandSources, by MapKit, and drawn in IslandSettings — and IslandSettings must
/// build and preview with no permission granted (§3), so it cannot import a package that links
/// EventKit, CoreLocation, MapKit and WeatherKit. `LocationAccess` and `TemperatureUnit` live here
/// for exactly that reason and this is the third of the same shape: the *value* is pure, only the
/// lookup needs a framework, so only the lookup stays behind the seam.
///
/// # Two strings, because MapKit answers with two
///
/// `MKLocalSearchCompletion` gives a title and a subtitle — "London" and "England", "Springfield"
/// and "MO, United States" — and the pair is what disambiguates the eleven Springfields. Joining
/// them here would throw away the typography the list needs; joining them at the point of *use* is
/// what `searchText` does, and that is the string the geocoder is later asked about.
public struct CitySuggestion: Equatable, Sendable, Identifiable, Hashable {

    /// The place's own name — "London".
    public let name: String

    /// Where it is — "England", "ON, Canada". Empty where MapKit offered nothing, which happens for
    /// a place whose name is unambiguous on earth.
    public let region: String

    /// Stable across a redraw, and **not** a `UUID`: a fresh identity per keystroke would make the
    /// list tear down and rebuild every row on every letter, which is visible as a flicker under a
    /// pointer that is about to click one.
    public var id: String { searchText }

    public init(name: String, region: String = "") {
        self.name = name
        self.region = region
    }

    /// What gets stored in `GlanceSettings.city` and handed to the geocoder.
    ///
    /// The pair, comma-joined — "London, England" — rather than the bare name. The bare name is what
    /// the user reads, and it is also what makes a geocoder pick the wrong Springfield; the whole
    /// point of offering a list is that the answer chosen from it is unambiguous, and dropping half
    /// of it on the way into the setting would give that away again.
    public var searchText: String {
        region.isEmpty ? name : "\(name), \(region)"
    }
}

/// Whether a query is worth asking MapKit about.
///
/// A free function on the value rather than a check inside the search: the *rule* is a fact about
/// the feature and belongs where it can be tested without a network, and the search is the thing
/// that would need one. Two characters, because one letter matches most of the earth and the list it
/// produces is noise the user has to read past on the way to the second keystroke.
public enum CityQuery {

    public static let minimumLength = 2

    /// Trimmed, because a field the user has cleared back to spaces has been cleared.
    public static func isSearchable(_ query: String) -> Bool {
        normalized(query).count >= minimumLength
    }

    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
