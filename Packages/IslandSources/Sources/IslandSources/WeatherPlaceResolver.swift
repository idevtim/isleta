import CoreLocation
import Foundation
import IslandActivities
import IslandKit
import MapKit

/// Where the weather should be asked about.
///
/// Two answers, and the second is why location is a toggle rather than a wall: **WeatherKit takes a
/// `CLLocation` and has no opinion about where it came from**, so a city typed in Settings gives a
/// fully working weather island with the location permission refused, or never asked for at all.
/// `MKGeocodingRequest` is public and needs no permission of its own. That fits onboarding's rule
/// that Continue is live on every page — there is no page here that has to be got past.
public enum WeatherPlaceSource: Equatable, Sendable {

    /// One `requestLocation()` per refresh. See `CoreLocationPlaceResolver`.
    case currentLocation

    /// A city the user typed, geocoded once and remembered.
    case city(String)
}

/// The `CLAuthorizationStatus` bridge for `LocationAccess`.
///
/// The enum itself lives in IslandActivities, beside `CalendarAccess`, because IslandSettings draws
/// a row from it and must not import a package that links CoreLocation, EventKit and WeatherKit —
/// §3's layering test is that everything in the UI layers builds with no permission granted. Only
/// the conversion needs CoreLocation, so only the conversion is here.
extension LocationAccess {

    /// Read from a `CLAuthorizationStatus` in the one place it is legal to.
    ///
    /// `.authorizedAlways` is the granted state and there is no when-in-use case to fold in — see
    /// the type's own note. `@unknown default` is `notDetermined` rather than `denied` because a
    /// status this build has never heard of is not evidence of a refusal.
    public init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .notDetermined
        }
    }
}

/// Turns a `WeatherPlaceSource` into coordinates.
///
/// A seam for the same reason `WeatherProvider` is one: the pure half of this feature has to be
/// exercisable in a test bundle that has never started a location manager, and CoreLocation in the
/// interface would make every such test a permission question.
@MainActor
public protocol WeatherPlaceResolving: AnyObject {

    var access: LocationAccess { get }

    /// Called when the system's answer to the location dialog changes.
    ///
    /// **Not a subscription to *where* the user is** — that would be the persistent client §9
    /// forbids. It fires when the *permission* moves, which happens when a person clicks a button
    /// and then answers a dialog, and it exists because the moment they say yes is the moment they
    /// are watching for a temperature. Without it the reading appears at the next scheduled refresh,
    /// up to `WeatherSource.refreshInterval` — a quarter of an hour — after the grant, which reads
    /// as the button having done nothing.
    var onAccessChange: ((LocationAccess) -> Void)? { get set }

    /// One fix, or one geocode. Never a subscription.
    func place(for source: WeatherPlaceSource) async throws -> WeatherPlace
}

/// A fix from CoreLocation, and a geocode for a typed city.
///
/// # One `requestLocation()` per refresh, and not the API that looks right
///
/// `startMonitoringSignificantLocationChanges` is the wrong shape and it is the one every guide
/// reaches for. It fires on roughly 500 m of movement, which makes it a *commute detector*; it
/// registers a persistent client with locationd; and its header says plainly that it exists to
/// **relaunch apps in the background**, which an `LSUIElement` agent with no Dock icon does not want
/// and cannot use.
///
/// Measured in-process over the stated windows: no manager **0.0057 %**, a live manager sitting idle
/// **0.0013 %**, significant-change monitoring ≈**0 %**, `startUpdatingLocation` **0.0007 %**. The
/// work is all inside locationd, outside our task — so the honest reading is that none of these
/// threatens §9, and the choice between them is about *shape* rather than cost. One
/// `requestLocation()` per refresh is **7 ms warm** (accuracy 40 m), because locationd already holds
/// a fix for its other clients, and leaves nothing running in between.
///
/// (One of those significant-change figures came out slightly **negative**: `task_thread_times_info`
/// counts only live threads, so a thread exiting inside the sample window subtracts from the total.
/// Worth knowing before somebody goes looking for a bug in `PerformanceProbe`.)
///
/// # The rebuild trap applies here too
///
/// locationd stores a per-client **designated requirement** — for an ad-hoc-signed probe, a bare
/// `cdhash` — so a Debug build's location grant dies on every compile, exactly as its Accessibility
/// grant does, with System Settings still showing the row switched on. This is not a shipped bug:
/// release builds share one designated requirement (identifier plus team). It costs a session only
/// on a machine that has run both.
@MainActor
public final class CoreLocationPlaceResolver: NSObject, WeatherPlaceResolving, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    /// The continuation for the one fix in flight, if any.
    ///
    /// At most one, and the guard below is not paranoia: `requestLocation()` calls back on either
    /// `didUpdateLocations` **or** `didFailWithError`, and a second refresh arriving while the first
    /// is outstanding would otherwise resume a continuation twice, which is a crash rather than a
    /// wrong answer.
    private var pending: CheckedContinuation<CLLocation, any Error>?

    /// The last city geocoded, so a Mac left running does not geocode the same string every quarter
    /// of an hour. A city does not move; the fix does.
    private var geocodedCity: (name: String, place: WeatherPlace)?

    public var onAccessChange: ((LocationAccess) -> Void)?

    /// The one-shot answer owed to whoever asked for the permission — see
    /// `requestAccessFromUserInitiatedMoment(then:)`. Cleared as it is called, so a later
    /// authorization change (the user revoking it in System Settings) reaches `onAccessChange`
    /// alone.
    private var pendingAccessRequest: (@MainActor (LocationAccess) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        // 40 m is what a warm `requestLocation()` answers with anyway, and the weather is the same
        // across a town. Asking for `kCLLocationAccuracyBest` would spend the radios to move a
        // temperature by nothing.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public var access: LocationAccess { LocationAccess(manager.authorizationStatus) }

    /// Ask for location. **The only call in this file that can raise a system dialog.**
    ///
    /// §10: never at launch, never from `start()`. The single caller is the "Use my location" switch
    /// on the Glance settings pane, which is a moment the user is already looking at Isleta and has
    /// just asked for exactly this. No dialog unless the status is `.notDetermined`, because macOS
    /// will not show the prompt a second time — the completion answers with what is already known
    /// instead, and the pane offers System Settings rather than a control that visibly does nothing.
    ///
    /// **Location is not a TCC service**, which changes the failure mode from every other permission
    /// in this app: `kTCCServiceLocation` is absent from `tccd`'s table (Calendar, Reminders,
    /// FocusStatus and BluetoothAlways are all in it) and authorization lives in
    /// `/var/db/locationd/clients.plist`. Measured, a probe with **no** location usage string still
    /// raised a prompt and was granted — it did not abort the way a missing
    /// `NSBluetoothAlwaysUsageDescription` aborts. Good for crash risk and bad for discipline: the
    /// missing string is invisible in testing and shows the user a prompt with no reason on it.
    /// `NSLocationWhenInUseUsageDescription` is in `Config/Isleta-Info.plist` for that reason alone.
    /// # `requestWhenInUseAuthorization()` alone raises no dialog on macOS
    ///
    /// Shipped in 2.0.0 as that call by itself, and a person clicked the button **five times in
    /// four seconds** with nothing happening. The log proves how quiet the failure is: our own line
    /// prints every time, `locationManagerDidChangeAuthorization` never fires, and — the part that
    /// settles it — **`locationd`'s log never mentions us at all**, so the call is not reaching the
    /// daemon rather than being refused by it. Location Services was on system-wide and the status
    /// was `notDetermined`, so nothing was in the way.
    ///
    /// On macOS the authorization dialog is raised by *asking for a location*, not by asking for
    /// permission. `requestWhenInUseAuthorization` is the iOS-shaped half of the API and is kept
    /// because it is what declares the intent; `requestLocation()` is what makes the dialog appear.
    ///
    /// **`requestLocation()` is the right second call rather than `startUpdatingLocation()`**, and
    /// for the reason CLAUDE.md already gives about this file: it is one-shot, so it adds nothing to
    /// the idle path, where a running updater would. It is also exactly what the user just asked
    /// for — they turned on "Use my location" — so the fix answers the question rather than only
    /// unblocking the dialog.
    ///
    /// A fix arriving with no `pending` continuation is discarded by the delegate, which guards on
    /// it. So is a failure, including the one a refusal produces.
    ///
    /// # The answer comes back, and that is what makes the switch a switch
    ///
    /// `then` is called once, when the authorization actually moves — or immediately, with what is
    /// already known, when there is no dialog to raise. The Glance pane's "Use my location" is drawn
    /// from the *granted* state rather than from a stored intention, so without this it would stay
    /// off under the user's finger until something else refreshed the pane's snapshot: the dialog is
    /// answered outside the window, and the snapshot is only re-read when Isleta comes back to the
    /// front. It is one callback and not a subscription — `onAccessChange` is the standing one, and
    /// `WeatherSource` owns it.
    public func requestAccessFromUserInitiatedMoment(
        then completion: (@MainActor (LocationAccess) -> Void)? = nil
    ) {
        guard access == .notDetermined else {
            completion?(access)
            return
        }
        IslandLog.weather.info("location requested from the settings window")
        pendingAccessRequest = completion
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    public func place(for source: WeatherPlaceSource) async throws -> WeatherPlace {
        switch source {
        case .city(let name):
            return try await geocode(name)
        case .currentLocation:
            guard access.isUsable else { throw WeatherUnavailable.noPlace }
            let fix = try await requestFix()
            return WeatherPlace(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                // Reverse-geocoded once per fix rather than on every draw. Nil is fine — the glance
                // draws the temperature without a place name, which is the honest thing to show when
                // the only thing known is where you are.
                name: await reverseGeocode(fix)
            )
        }
    }

    // MARK: - The one fix

    private func requestFix() async throws -> CLLocation {
        // A second request while one is outstanding is answered by failing the *new* one rather than
        // by replacing the old. Replacing it would strand the first continuation forever, which is a
        // leaked task rather than a visible bug.
        guard pending == nil else { throw WeatherUnavailable.serviceFailed("a location request is already in flight") }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            manager.requestLocation()
        }
    }

    /// The three delegate methods are `nonisolated` and hop with `MainActor.assumeIsolated`, which
    /// is the same shape `TimerSource`'s workspace observers use — and it is required rather than
    /// stylistic. Under Swift 6, a `@MainActor` type whose methods directly satisfy
    /// `CLLocationManagerDelegate`'s *nonisolated* requirements is a `#ConformanceIsolation`
    /// diagnostic, which `Tools/check.sh` turns into a build failure.
    ///
    /// The assumption is sound for a different reason from the assertion's usual one: a
    /// `CLLocationManager` delivers to the run loop it was created on, and this one is created in a
    /// `@MainActor` initializer. That is **not** the case for `IOBluetooth`'s connect notification,
    /// which arrives on CoreBluetooth's XPC queue and takes SIGTRAP from a `@MainActor` method —
    /// see `BluetoothDeviceSource`. The two look identical in source and differ entirely in which
    /// queue the framework calls back on, which is the thing to check before copying either.
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            guard let continuation = pending, let last = locations.last else { return }
            pending = nil
            continuation.resume(returning: last)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            guard let continuation = pending else { return }
            pending = nil
            // The message and never the coordinate: this line goes into the file "Export Logs…"
            // hands to strangers, and a failure is the one moment a lazy log prints where somebody
            // is standing.
            continuation.resume(throwing: WeatherUnavailable.serviceFailed("\(error)"))
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let access = access
            IslandLog.weather.info("location authorization is now \(access)")
            // Announced rather than only logged. This is the one moment the user is waiting on a
            // result: they moved the switch, answered the dialog, and the next scheduled refresh
            // is up to fifteen minutes away.
            onAccessChange?(access)
            // And the settings window, if it is what asked. Taken before it is called so a switch
            // toggled twice cannot be answered twice by one request.
            let asked = pendingAccessRequest
            pendingAccessRequest = nil
            asked?(access)
        }
    }

    // MARK: - Geocoding, through MapKit rather than CoreLocation

    /// **`CLGeocoder` is deprecated as of macOS 26 — "Use MapKit" — and this corrects the probe.**
    ///
    /// The probe recorded that "a typed city through `CLGeocoder` (public, no
    /// permission) gives a fully working weather island with zero location permission". The
    /// permission half is still exactly right and is what makes the city option worth having; the
    /// *class* is not. `CLGeocoder`, `geocodeAddressString` and `reverseGeocodeLocation` are all
    /// `API_DEPRECATED(… macos(10.9, 26.0))` in the 26.5 SDK, so under `Tools/check.sh`'s
    /// `-warnings-as-errors` they do not merely warn — they fail the build.
    ///
    /// `MKGeocodingRequest` / `MKReverseGeocodingRequest` are the replacements, they are equally
    /// public, and they need no permission either. `MKAddressRepresentations.cityName` is also a
    /// better answer than the old `CLPlacemark.locality` for what is wanted here: it is the
    /// city, formatted the way the user's own region formats one.
    private func geocode(_ name: String) async throws -> WeatherPlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WeatherUnavailable.noPlace }
        // A city does not move. Geocoding the same string every quarter of an hour would be a
        // network round trip to learn nothing; the *fix* is the thing that has to be re-taken.
        if let cached = geocodedCity, cached.name == trimmed { return cached.place }

        guard let request = MKGeocodingRequest(addressString: trimmed) else {
            throw WeatherUnavailable.noPlace
        }
        guard let item = try await request.mapItems.first else { throw WeatherUnavailable.noPlace }
        let coordinate = item.location.coordinate
        // The user's own spelling is kept as the display name rather than the geocoder's, which
        // answers "Greater London" for "London". They typed what they wanted to read.
        let place = WeatherPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, name: trimmed)
        geocodedCity = (trimmed, place)
        return place
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }
        return item.addressRepresentations?.cityName ?? item.name
    }
}
