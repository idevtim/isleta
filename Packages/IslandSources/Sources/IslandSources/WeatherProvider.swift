import Foundation
import IslandActivities
import IslandKit

/// A point on the earth the weather can be asked about, with no CoreLocation in it.
///
/// Deliberately not a `CLLocation`. WeatherKit takes one, but the *protocol* below must be
/// satisfiable by a stub in a test bundle that has never started a location manager, and a
/// CoreLocation type in the seam would drag a permission into every test that touched it. The
/// conversion happens in exactly one place, inside `WeatherKitProvider`.
public struct WeatherPlace: Equatable, Sendable {

    public let latitude: Double

    public let longitude: Double

    /// What to call it on screen — "London", or nil where only coordinates are known.
    ///
    /// Carried alongside rather than looked up on demand, because the two ways a place arrives
    /// already know the answer: a city the user typed *is* the name, and a fix from CoreLocation is
    /// reverse-geocoded once when it lands rather than on every draw.
    public let name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}

/// Why a weather reading could not be taken.
///
/// Cases rather than a string, because the three are answered differently on screen: the first two
/// are permanent facts about this build and this Mac, and the third is a bad afternoon.
public enum WeatherUnavailable: Error, Equatable, Sendable {

    /// This copy of Isleta holds no WeatherKit entitlement, so there is no weather at all. See
    /// `WeatherKitProvider` for exactly what a human has to do in the Apple Developer portal.
    case notEntitled

    /// No location: refused, never asked, and no city typed in Settings either.
    case noPlace

    /// The service was asked and did not answer.
    case serviceFailed(String)
}

/// One route to the weather.
///
/// The `NowPlayingProvider` / `NullProvider` pattern, and it is here for exactly the same reason it
/// is there: the route Isleta wants is gated by something outside the code, so the interface has to
/// be satisfiable by a thing that honestly reports having nothing. The glance draws its calendar
/// half whether or not this ever answers, and that is a property of the design rather than a
/// fallback bolted on afterwards.
///
/// `Sendable` and `async`, because the real implementation is a network call. Nothing on the island
/// waits for it — `WeatherSource` hops the result to the main actor and republishes the snapshot.
public protocol WeatherProvider: Sendable {

    /// For the diagnostics report and the Settings row. A category, never a coordinate.
    var providerName: String { get }

    /// Whether asking is worth the attempt. False here means the source arms **no refresh timer at
    /// all**, which is what makes the unentitled build cost precisely zero on the idle path.
    var isAvailable: Bool { get }

    func reading(at place: WeatherPlace) async throws -> WeatherReading
}

/// The provider for a build that cannot ask.
///
/// `NullProvider`'s counterpart. It exists so that "no weather" is a *configuration* rather than a
/// branch: every consumer holds a `WeatherProvider` and none of them has an `if weather == nil`
/// in it, which is the difference between a feature that degrades and a feature with a hole in it.
public struct UnavailableWeatherProvider: WeatherProvider {

    /// Why, in words fit for the Settings row. Supplied by whoever chose this provider, because the
    /// two reasons for landing here — no entitlement, no location — are unrelated and both true
    /// sentences.
    public let explanation: String

    /// A stored constant rather than the default argument itself, because a default argument on a
    /// `public` initializer may not call an internal function and `sourceText` is one.
    public static let defaultExplanation = sourceText(
        "weather.unavailable.default",
        "Weather is not available in this build of Isleta."
    )

    public init(explanation: String = UnavailableWeatherProvider.defaultExplanation) {
        self.explanation = explanation
    }

    public var providerName: String { "unavailable" }

    public var isAvailable: Bool { false }

    public func reading(at place: WeatherPlace) async throws -> WeatherReading {
        throw WeatherUnavailable.notEntitled
    }
}
