import CoreLocation
import Foundation
import IslandActivities
import IslandKit
import Security
import WeatherKit

/// Apple's own weather, through the public framework.
///
/// # This is on in Release and off in Debug, and the difference is the signature
///
/// **`com.apple.developer.weatherkit` landed in `Config/Isleta.entitlements` on 2026-08-23, in the
/// same change that added `Config/Isleta.provisionprofile`** — and the pairing is the whole rule.
/// Measured on macOS 27, an app that *claims* an entitlement with no matching embedded provisioning
/// profile is **SIGKILLed at `exec`** — exit 137, no stdout, no stderr, and **no `.ips` crash
/// report**, with the kernel logging `AMFI: Unsatisfied Entitlements: … code signature validation
/// failed fatally`. `codesign` accepts the claim without a word. This is the 1.3.0 Bluetooth abort's
/// shape again: silent, instant, and invisible to every check that runs from a shell. It is also not
/// specific to WeatherKit — a control with an invented `com.tryisleta.nonsense` died identically,
/// while `com.apple.security.network.client` alone ran fine.
///
/// **A Debug build still has no weather, and that is structural rather than a decision.** An ad-hoc
/// signature cannot carry a developer entitlement at all — Xcode refuses the build outright — so
/// `Config/Isleta-Debug.entitlements` omits it, `isAvailable` is false under `Tools/check.sh` and
/// under anything launched from `.build/xcode`, and `UnavailableWeatherProvider` draws the calendar
/// with nothing beside it. That is a real state a user can be in (anyone whose profile has expired),
/// so developing against it is not a loss — but it does mean **the only way to exercise the weather
/// is a signed Release build**: `./Tools/release.sh --build-only`, installed and launched with
/// `open -a Isleta`. Verified 2026-08-24: `weatherkit entitled`, then a real reading.
///
/// ## What was done to get here, kept because touching that page undoes it
///
/// Step 1 invalidates every existing profile for the App ID, so the whole list has to be repeated
/// whenever anybody edits the capabilities page.
///
/// 1. **developer.apple.com → Certificates, Identifiers & Profiles → Identifiers →
///    `com.tryisleta.isleta`.** Tick WeatherKit on the **App Services** tab *and* on the **App
///    Capabilities** tab. Both. Ticking one is the common mistake and it produces a profile that
///    validates and a service that refuses.
/// 2. **Create a *Developer ID* distribution provisioning profile** for that App ID. From Xcode's
///    own portal cache, WeatherKit's `distributionTypes` genuinely includes `DEVELOPER_ID` — which
///    is worth checking rather than assuming, because **25 of the 83 macOS capabilities in that file
///    do not carry it**. `distributionApprovalRequired` is false, so no request has to be approved.
/// 3. **Copy the profile to `Isleta.app/Contents/embedded.provisionprofile`**, replacing any
///    *development* profile Xcode may have embedded. `Tools/release.sh` is where this belongs.
/// 4. **Add `com.apple.developer.weatherkit` (Boolean, true) to `Config/Isleta.entitlements`** — and
///    only now — then sign, notarize, and **launch the result with `open -a Isleta`**. A build run
///    from a shell proves nothing about entitlements any more than it does about TCC.
///
/// There is no service ID, no private key and no JWT anywhere in that list. Those belong to the
/// **REST** API, which is for servers and non-Apple platforms; the native framework mints its own
/// token through `com.apple.weatherkit.authservice`.
///
/// ## Two things to write into the release checklist at the same time
///
/// - Apple: *"Gatekeeper will evaluate the validity of your Developer ID provisioning profile at
///   every app launch… if your Developer ID provisioning profile expires, the app will no longer
///   launch."* Isleta **now ships with a profile and therefore with an expiry** — 18 years, for
///   profiles created after 2017-02-22 — and its failure mode is the SIGKILL above rather than a
///   feature quietly degrading.
/// - **Editing the App ID's capabilities invalidates every existing profile for it.** Touching that
///   page again means regenerating and re-embedding, or the next launch dies.
///
/// ## The quota is a business decision, and it is pooled
///
/// 500,000 calls a month with the Developer Program membership, pooled **per Team ID across every
/// app on the team** rather than per app. One fetch per user per 15 minutes is about 2,880
/// calls/user/month — roughly 170 concurrent users on the free pool. `WeatherSource.refreshInterval`
/// is where that number lives, and it has a floor for this reason rather than for a UI one.
///
/// ## Attribution is mandatory
///
/// `WeatherService.attribution` returns its marks as **remote URLs**, and Apple requires the Apple
/// Weather mark plus a link to their legal page wherever the data is shown. `GlanceLayout` reserves
/// the strip and what is drawn today is the text attribution, which is permitted. **Now that the
/// entitlement is live the mark itself is fetchable, and nobody has looked at it** — that is the
/// next thing owed on this file.
public struct WeatherKitProvider: WeatherProvider {

    /// The entitlement whose presence is the entire availability question.
    public static let entitlement = "com.apple.developer.weatherkit"

    public init() {}

    public var providerName: String { "weatherkit" }

    /// Whether this build actually holds the entitlement.
    ///
    /// Asked of the running process rather than of the bundle's plist, and the reasoning is the same
    /// one that makes this check trustworthy at all: an entitlement **not** authorised by an embedded
    /// profile kills the process at `exec`, so a process that is alive and reports holding this
    /// entitlement is a process whose profile validated. There is no state in which this returns
    /// true and the call below fails for want of authorisation.
    ///
    /// `SecTaskCopyValueForEntitlement` and not `Bundle`: the plist is what was *asked for* at build
    /// time and the task is what was *granted* at launch, and only one of those two is a fact.
    public var isAvailable: Bool { Self.hasEntitlement }

    /// Computed once. The answer cannot change while the process runs — it is a property of the
    /// signature the kernel already validated — and the call is a Mach round trip.
    private static let hasEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        // Already bridged to a managed `CFTypeRef` by the importer — there is no `Unmanaged` to
        // take a value out of, which is what the name of the C function leads you to write first.
        return (value as? Bool) == true
    }()

    /// The current conditions, today's range, and the days after it.
    ///
    /// One `weather(for:)` rather than targeted calls, because a targeted `.current` and a targeted
    /// `.daily` are two requests against a pooled quota to fill one card. It is also why the weather
    /// **surface** is free: the daily forecast it draws arrives in the same response the chip's
    /// temperature already came from, so opening the page costs no request at all.
    public func reading(at place: WeatherPlace) async throws -> WeatherReading {
        guard isAvailable else { throw WeatherUnavailable.notEntitled }

        // The **only** place a CoreLocation type appears in the weather path. Everything either side
        // of this line speaks `WeatherPlace`, which is what keeps the provider protocol satisfiable
        // by a stub that has never started a location manager.
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let today = weather.dailyForecast.first
            return WeatherReading(
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                highCelsius: today?.highTemperature.converted(to: .celsius).value,
                lowCelsius: today?.lowTemperature.converted(to: .celsius).value,
                humidity: current.humidity,
                conditionDescription: current.condition.description,
                // WeatherKit's own name for the glyph, day and night variants included. A table of
                // our own here would be a second mapping that drifts every time Apple adds a
                // condition — and the conditions are theirs to add.
                symbolName: current.symbolName,
                placeName: place.name,
                readAt: .now,
                apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                // **Today's chance, from the daily forecast rather than from the current
                // conditions.** `CurrentWeather` has no `precipitationChance` at all — it reports
                // what is falling now, which the symbol already says. The probability is a property
                // of a forecast period, and today is the first one.
                precipitationChance: today?.precipitationChance,
                windSpeedKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
                days: Self.days(from: weather.dailyForecast)
            )
        } catch {
            // **This failure does not look like a permission problem, and that is the trap.** With
            // no entitlement it is not `WeatherError.permissionDenied` — that case exists in the
            // interface and is not what arrives. It is
            // `WDSJWTAuthenticatorServiceProxy.Errors.xpcConnectionFailed`, NSCocoaErrorDomain 4097,
            // "connection to service named com.apple.weatherkit.authservice", in 184–189 ms. It
            // reads as broken XPC plumbing, so the instinct is to go hunting for a launchd or
            // sandbox bug. `isAvailable` above is what makes that unreachable from here.
            throw WeatherUnavailable.serviceFailed("\(error)")
        }
    }

    /// The forecast as our own value, capped.
    ///
    /// `nonisolated static` and taking the forecast rather than the whole `Weather`, so the mapping
    /// — which is the part that can be wrong — has no `WeatherService` in its way. The conversion to
    /// Celsius happens here, once, for `WeatherReading`'s reason: the unit a person reads a
    /// temperature in is a fact about them and not about the air, and a value stored in whichever
    /// unit they currently prefer is silently wrong by 32 the moment they change their mind.
    private static func days(from forecast: Forecast<DayWeather>) -> [WeatherDay] {
        // Capped **here** rather than in the view. WeatherKit answers with ten days and the island
        // has room for `WeatherPolicy.forecastDays`; a value that reaches the model is one that gets
        // held in memory, published to every screen and compared on every refresh, so the five
        // nothing can draw would be all three for nothing.
        forecast.prefix(WeatherPolicy.forecastDays).map { day in
            WeatherDay(
                date: day.date,
                highCelsius: day.highTemperature.converted(to: .celsius).value,
                lowCelsius: day.lowTemperature.converted(to: .celsius).value,
                precipitationChance: day.precipitationChance,
                symbolName: day.symbolName,
                conditionDescription: day.condition.description
            )
        }
    }

    /// The provider this build should actually use.
    ///
    /// The one call site outside a test. `NowPlayingSource` chooses between its adapter, its script
    /// route and `NullProvider` in exactly this shape, and for exactly this reason: the *choice* and
    /// the *explanation for the choice* belong in one place, so a Settings row saying why there is no
    /// weather cannot disagree with the reason there is none.
    public static func resolve() -> any WeatherProvider {
        let provider = WeatherKitProvider()
        guard provider.isAvailable else {
            IslandLog.weather.info("weatherkit entitlement absent — weather disabled, calendar unaffected")
            return UnavailableWeatherProvider(
                explanation: sourceText("weather.unavailable.notEntitled", """
                    Weather isn’t in this build of Isleta yet. Your calendar still shows in \
                    the island; the weather needs a signing change that has to be made by hand.
                    """)
            )
        }
        IslandLog.weather.info("weatherkit entitled")
        return provider
    }
}
