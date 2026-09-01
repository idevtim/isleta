import Foundation
import IslandActivities
import IslandKit
import MapKit

/// Completions for a city being typed into Settings.
///
/// # Why this exists at all
///
/// The city field shipped as a bare `TextField` whose contents were handed to a geocoder once, at
/// refresh time, fifteen minutes later. Everything about that is invisible: a typo, a place that
/// does not exist, and the *right* place spelled the way another country spells it all produce the
/// same thing on screen — a glance with no weather on it and nothing anywhere saying why. A list of
/// real places, offered while the user types, replaces a silent failure with a choice.
///
/// # No permission, and that is the point
///
/// `MKLocalSearchCompleter` needs no authorization of any kind — the same property that makes a
/// typed city a *complete* weather feature for somebody who has refused location, rather than a
/// degraded one. See `WeatherPlaceSource`. Nothing here ever starts a `CLLocationManager`, and the
/// completer is deliberately given **no region** to bias against: a search seeded with where the
/// user is standing would be a location read taken through a door marked "no permission required".
///
/// # Nothing runs when nobody is typing
///
/// §9 forbids standing machinery on the idle path, and this has none: the completer is built on the
/// first query and `cancel()`ed the moment an answer lands or the caller goes away. There is no
/// timer, no subscription and no delegate left registered between keystrokes. The debounce that
/// keeps a network round trip off every letter is the caller's — `SettingsView` holds it, because
/// the caller is the only layer that knows a keystroke happened.
///
/// # The delegate is the whole subtlety
///
/// `MKLocalSearchCompleter` is a *stream*: setting `queryFragment` produces callbacks, possibly
/// several, for as long as the object lives. This wraps one round of that into a single `async`
/// answer, which means exactly one continuation may ever be resumed and it must be resumed exactly
/// once — a second query arriving while one is outstanding would otherwise resume it twice, which is
/// a crash rather than a wrong answer. `CoreLocationPlaceResolver.pending` guards the identical
/// hazard for the identical reason, and this is the second of the shape.
@MainActor
public final class CitySearch: NSObject, MKLocalSearchCompleterDelegate {

    /// How many places the list offers.
    ///
    /// Five. The list is drawn inside a settings card under the field it belongs to, and a card that
    /// grew to twelve rows would push everything below it off the pane while the user is typing —
    /// the same objection that fixes a list's height while a filter is live. Five is also
    /// past the point where more names help: MapKit ranks, and a sixth Springfield is not the answer.
    public nonisolated static let maximumSuggestions = 5

    /// Built on the first query and kept, not rebuilt per keystroke. Constructing one costs a MapKit
    /// object and an XPC connection to the same daemon every time; the *query* is what changes.
    private var completer: MKLocalSearchCompleter?

    /// The answer in flight, if any. At most one — see the type's note.
    private var pending: CheckedContinuation<[CitySuggestion], Never>?

    public override init() {
        super.init()
    }

    // **No `deinit` that resumes the outstanding continuation**, which is the first thing this file
    // wants and cannot have: a `deinit` on a `@MainActor` class is nonisolated, so touching
    // `pending` from one is a Swift 6 isolation error rather than a safety net. `cancel()` is the
    // supported way to end a round, and the one instance of this type is owned by `SourceHub` for
    // the life of the process — so the case a `deinit` would cover is one where the app is going
    // away anyway.

    /// The places a query could mean, best first.
    ///
    /// Answers `[]` rather than throwing for every failure there is. This is a *suggestion* list:
    /// MapKit being unreachable, the query matching nothing, and the user having typed one letter
    /// are all the same thing on screen — no list — and three error paths to arrive at one empty
    /// state would be three ways to draw it differently.
    public func suggestions(for query: String) async -> [CitySuggestion] {
        let normalized = CityQuery.normalized(query)
        guard CityQuery.isSearchable(normalized) else {
            finishPending(with: [])
            return []
        }

        // The outstanding round is answered empty rather than left hanging. Its caller has already
        // been superseded by this one — the user typed another letter — so an empty answer is the
        // true one for a query nobody is waiting on any more.
        finishPending(with: [])

        let completer = resolvedCompleter()
        return await withCheckedContinuation { continuation in
            pending = continuation
            completer.queryFragment = normalized
        }
    }

    /// Stops whatever is in flight. Called when the field loses focus or the pane goes away, so a
    /// completer is not left holding a query nobody is reading the answer to.
    public func cancel() {
        completer?.cancel()
        finishPending(with: [])
    }

    private func resolvedCompleter() -> MKLocalSearchCompleter {
        if let completer { return completer }
        let completer = MKLocalSearchCompleter()
        completer.delegate = self
        // Addresses only. The default includes points of interest and query suggestions, which is
        // how "Lon" answers with a café called Lon's and a suggestion to search for one — neither of
        // which is a place the weather can be asked about.
        completer.resultTypes = .address
        // And of the addresses, only the ones a city is spelled with. Without this the list fills
        // with street addresses and postcodes the moment a query resembles one, and a weather
        // forecast for a postcode is a forecast for its city with a longer name on it.
        completer.addressFilter = MKAddressFilter(
            including: [.locality, .subLocality, .administrativeArea, .subAdministrativeArea, .country]
        )
        self.completer = completer
        return completer
    }

    /// Resumes the outstanding continuation exactly once, or does nothing.
    private func finishPending(with suggestions: [CitySuggestion]) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: suggestions)
    }

    // MARK: - MKLocalSearchCompleterDelegate

    /// `nonisolated` with a `MainActor.assumeIsolated` hop, which is required rather than stylistic:
    /// under Swift 6 a `@MainActor` type whose methods directly satisfy a *nonisolated* protocol
    /// requirement is a `#ConformanceIsolation` diagnostic, and `Tools/check.sh` turns that into a
    /// build failure. The assumption is sound because `MKLocalSearchCompleter` delivers on the run
    /// loop it was created on and this one is created in a `@MainActor` method —
    /// `CoreLocationPlaceResolver` carries the same note, and `BluetoothDeviceSource` is the
    /// counter-example that takes SIGTRAP for assuming it.
    public nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // **Mapped before the hop, not inside it.** `MKLocalSearchCompleter` is not `Sendable`, so
        // capturing it in the `assumeIsolated` closure is `sending 'completer' risks causing data
        // races` — a build failure under `Tools/check.sh`, not a warning. `CitySuggestion` is a
        // `Sendable` value, so converting first is what makes the crossing legal, and it is also the
        // honest shape: what the main actor wants is the answer, not the object that has it.
        let suggestions = Self.suggestions(from: completer.results)
        MainActor.assumeIsolated {
            finishPending(with: suggestions)
        }
    }

    public nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // The category and never the query. What somebody typed into the city field is where
            // they live or where they are going, and this file's log goes into the bundle
            // "Export Logs…" hands to strangers.
            IslandLog.weather.info("city search did not answer")
            finishPending(with: [])
        }
    }

    /// MapKit's completions as our own value, deduplicated and capped.
    ///
    /// `nonisolated static` so it is testable without a completer: the mapping is the part that can
    /// be wrong — a duplicate row, an empty name, a cap off by one — and the part that needs MapKit
    /// is the part that cannot be tested at all.
    nonisolated static func suggestions(from results: [MKLocalSearchCompletion]) -> [CitySuggestion] {
        var seen = Set<String>()
        var suggestions: [CitySuggestion] = []
        for result in results {
            let name = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let suggestion = CitySuggestion(
                name: name,
                region: result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // MapKit answers the same place twice for a query that matches both its name and its
            // administrative area, and two identical rows in a five-row list is a fifth of the list
            // spent saying nothing.
            guard seen.insert(suggestion.searchText).inserted else { continue }
            suggestions.append(suggestion)
            if suggestions.count == maximumSuggestions { break }
        }
        return suggestions
    }
}
