import CoreLocation
import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A provider that answers instantly and counts how often it was asked, so the "does it poll?"
/// question is checkable without a network, an entitlement or a fifteen-minute wait.
private final class StubWeatherProvider: WeatherProvider, @unchecked Sendable {

    let providerName = "stub"
    var isAvailable: Bool
    var reading: WeatherReading
    private(set) var asks = 0

    init(isAvailable: Bool = true, temperature: Double = 4) {
        self.isAvailable = isAvailable
        self.reading = WeatherReading(
            temperatureCelsius: temperature,
            conditionDescription: "Cloudy",
            symbolName: "cloud.fill"
        )
    }

    func reading(at place: WeatherPlace) async throws -> WeatherReading {
        asks += 1
        guard isAvailable else { throw WeatherUnavailable.notEntitled }
        return reading
    }
}

@MainActor
private final class StubPlaceResolver: WeatherPlaceResolving {
    var access: LocationAccess = .granted
    var place = WeatherPlace(latitude: 51.5, longitude: -0.12, name: "London")
    private(set) var resolutions = 0
    var onAccessChange: ((LocationAccess) -> Void)?

    /// Answers the dialog the way CoreLocation would, so a test can watch the grant arrive.
    func grant() {
        access = .granted
        onAccessChange?(access)
    }

    func place(for source: WeatherPlaceSource) async throws -> WeatherPlace {
        resolutions += 1
        guard access.isUsable || !isCurrentLocation(source) else { throw WeatherUnavailable.noPlace }
        return place
    }

    private func isCurrentLocation(_ source: WeatherPlaceSource) -> Bool { source == .currentLocation }
}

/// Waits for a condition, with a deadline.
///
/// A wait rather than a fixed sleep, because a refresh here is an `async` hop and the suite runs in
/// parallel: a 50 ms sleep that is ample on an idle machine is not ample on one running nineteen
/// other suites, and a test that fails only under load is worse than no test. The deadline is what
/// keeps a genuinely broken source from hanging the run.
///
/// Note where this is **not** used: `unavailableCostsNothing` asserts that nothing happened, and a
/// wait cannot prove a negative any better than a short sleep can. CLAUDE.md's warning about polling
/// teardown tests applies to that shape and not to this one.
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    deadline: Duration = .seconds(2)
) async {
    let start = ContinuousClock.now
    while !condition(), start.duration(to: .now) < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Weather source")
@MainActor
struct WeatherSourceTests {

    @Test("an unavailable provider arms nothing and asks nobody")
    func unavailableCostsNothing() async {
        // This is the shipped state: `com.apple.developer.weatherkit` is deliberately absent from
        // the entitlements, so `WeatherKitProvider.resolve()` hands back the unavailable one. The
        // claim being pinned is that it costs precisely zero on the idle path — no timer, no
        // location request, no network call.
        let provider = StubWeatherProvider(isAvailable: false)
        let resolver = StubPlaceResolver()
        let source = WeatherSource(provider: provider, resolver: resolver)
        source.start()
        source.setPresented(true)
        source.refreshNow()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(provider.asks == 0)
        #expect(resolver.resolutions == 0)
        #expect(!source.isAvailable)
        source.stop()
    }

    @Test("the moment location is granted, the reading is fetched rather than waited for")
    func theGrantIsTheTrigger() async {
        // 2.0.0's second weather bug. `locationManagerDidChangeAuthorization` only *logged*, so a
        // person who clicked "Allow Location", answered the dialog and watched the island saw
        // nothing happen — the next scheduled refresh is `refreshInterval` away, a quarter of an
        // hour, which is indistinguishable from the button being broken.
        let provider = StubWeatherProvider()
        let resolver = StubPlaceResolver()
        resolver.access = .notDetermined
        let source = WeatherSource(provider: provider, resolver: resolver)
        source.start()
        source.setPresented(true)
        // The first attempt resolves nothing: there is no place to ask about yet.
        await waitUntil { resolver.resolutions > 0 }
        #expect(provider.asks == 0)

        resolver.grant()
        await waitUntil { provider.asks > 0 }
        #expect(provider.asks == 1)
        source.stop()
    }

    @Test("a source nobody started asks nothing, however granted the Mac is")
    func startIsWhatArmsIt() async {
        // **The bug 2.0.0 shipped with**, pinned at the layer that can see it. `WeatherSource` is
        // not an `ActivitySource`, so it is not in `SourceHub.entries`; the hub had the matching
        // `weather.stop()` in `stopAll()` and nothing that ever called `start()`. Every guard
        // downstream then held correctly and silently — this asserts the silence, so that a future
        // hub which forgets the same line fails here instead of on a user's Mac.
        let provider = StubWeatherProvider()
        let source = WeatherSource(provider: provider, resolver: StubPlaceResolver())
        source.setPresented(true)
        source.refreshNow()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(provider.asks == 0)
    }

    @Test("nothing is asked until a surface drawing a reading is on screen")
    func onlyPollsWhilePresented() async {
        // §9 permits a provider to poll only while what it feeds is presented, and this is that
        // rule read literally: nothing about the weather is push, so the only honest shapes are a
        // timer while somebody is looking at it, or nothing at all. The shell decides who is
        // looking — see `AppDelegate.refreshWeatherPolling`, which asks the open island's page now
        // that the glance is one rather than an activity.
        let provider = StubWeatherProvider()
        let source = WeatherSource(provider: provider, resolver: StubPlaceResolver())
        source.start()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(provider.asks == 0)

        source.setPresented(true)
        await waitUntil { provider.asks > 0 }
        #expect(provider.asks == 1)
        source.stop()
    }

    @Test("a reading reaches the glance, and an equal one does not republish")
    func publishesOnChangeOnly() async {
        let provider = StubWeatherProvider()
        let source = WeatherSource(provider: provider, resolver: StubPlaceResolver())
        var readings: [WeatherReading?] = []
        source.onReading = { readings.append($0) }
        source.start()
        source.setPresented(true)
        await waitUntil { !readings.isEmpty }
        #expect(readings.count == 1)

        source.refreshNow()
        try? await Task.sleep(for: .milliseconds(100))
        // Same temperature, same condition, same place — nothing on the island has changed.
        #expect(readings.count == 1)
        source.stop()
    }

    @Test("a city works with location refused")
    func cityWorksWithoutLocation() async {
        // The half of this feature that makes location a toggle rather than a wall: WeatherKit takes
        // a CLLocation and has no opinion about where it came from.
        let provider = StubWeatherProvider()
        let resolver = StubPlaceResolver()
        resolver.access = .denied
        let source = WeatherSource(
            provider: provider, resolver: resolver, placeSource: .city("London")
        )
        source.start()
        source.setPresented(true)
        await waitUntil { provider.asks > 0 }
        #expect(provider.asks == 1)
        source.stop()
    }

    @Test("current location with the permission refused asks the service nothing")
    func deniedLocationDoesNotAskTheService() async {
        let provider = StubWeatherProvider()
        let resolver = StubPlaceResolver()
        resolver.access = .denied
        let source = WeatherSource(provider: provider, resolver: resolver, placeSource: .currentLocation)
        source.start()
        source.setPresented(true)
        await waitUntil { resolver.resolutions > 0 }
        #expect(provider.asks == 0)
        source.stop()
    }

    @Test("changing units redraws without spending a call")
    func unitChangeCostsNoCall() async {
        // The whole reason readings are stored in Celsius and converted at the edge: the user's
        // preference is a fact about how they read a number, not about the number.
        let provider = StubWeatherProvider()
        let source = WeatherSource(provider: provider, resolver: StubPlaceResolver())
        var publishes = 0
        source.onReading = { _ in publishes += 1 }
        source.start()
        source.setPresented(true)
        await waitUntil { publishes > 0 }
        let asksBefore = provider.asks

        source.apply(placeSource: .currentLocation, unit: .fahrenheit)
        #expect(provider.asks == asksBefore)
        #expect(publishes == 2)
        source.stop()
    }

    @Test("stopping takes the reading away")
    func stopClearsTheCard() async {
        let source = WeatherSource(provider: StubWeatherProvider(), resolver: StubPlaceResolver())
        var readings: [WeatherReading?] = []
        source.onReading = { readings.append($0) }
        source.start()
        source.setPresented(true)
        await waitUntil { !readings.isEmpty }
        source.stop()
        // Leaving it would let a glance summoned afterwards draw a temperature nothing is
        // maintaining.
        #expect(readings.last == .some(nil))
    }
}

@Suite("Location access")
struct LocationAccessTests {

    @Test("the granted state on macOS is authorizedAlways, and when-in-use does not exist")
    func macOSHasNoWhenInUse() {
        // `kCLAuthorizationStatusAuthorizedWhenInUse` is `API_UNAVAILABLE(macos)` and Swift refuses
        // to compile a comparison against it here — after granting a *when-in-use* request the
        // status a Mac reports is `.authorizedAlways` (raw 3). Any code gating on when-in-use is
        // dead on this platform, and it is exactly the case somebody writing this from memory adds.
        //
        // This suite stays in IslandSources even though `LocationAccess` lives in IslandActivities:
        // what is being pinned is the *bridge*, and `CLAuthorizationStatus` is CoreLocation's.
        #expect(LocationAccess(.authorizedAlways) == .granted)
        #expect(LocationAccess(.denied) == .denied)
        #expect(LocationAccess(.notDetermined) == .notDetermined)
        #expect(LocationAccess(.restricted) == .restricted)
    }

    @Test("only granted is usable")
    func usable() {
        #expect(LocationAccess.granted.isUsable)
        #expect(!LocationAccess.notDetermined.isUsable)
        #expect(!LocationAccess.denied.isUsable)
    }
}
