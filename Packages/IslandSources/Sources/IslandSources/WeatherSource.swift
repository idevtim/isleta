import Foundation
import IslandActivities
import IslandKit

/// The weather half of the glance.
///
/// # Why this is not an `ActivitySource`
///
/// Weather is not an activity. There is no `ActivityKind.weather`, and there should not be: the
/// island never announces the weather, it *contains* it — one card inside the glance, beside the
/// calendar. So this type publishes a **reading** rather than an activity, and `CalendarSource` folds
/// what it publishes into the snapshot it owns. One surface, one height, one publisher.
///
/// The alternative — a second `ActivitySource` publishing a second activity that happens to be drawn
/// in the same island — was rejected for the reason `GlanceSnapshot` is one value: the open island's
/// height is decided *before* the transition (`IslandController.expandedContentHeight`), and a
/// weather reading landing on its own clock would resize a surface somebody is reading.
///
/// # What it costs when there is no weather
///
/// **Nothing at all.** `start()` arms no timer and asks for no location when
/// `provider.isAvailable` is false, which is every build shipped today — see `WeatherKitProvider`
/// for what a human has to do to change that. There is no branch anywhere else in the app for it;
/// the glance simply draws its calendar half.
///
/// # And when there is
///
/// One refresh every `refreshInterval`, each one a single `requestLocation()` (7 ms warm) and a
/// single `weather(for:)`. §9 permits a provider to poll **only while its activity is presented**,
/// and that is the rule this obeys: the timer is armed by `setPresented(true)` when the glance
/// reaches the stage and canceled when it leaves. On a Mac where the glance never appears — no
/// calendar access, no events, weather unavailable — nothing here ever runs.
@MainActor
public final class WeatherSource {

    /// How often a presented glance re-asks.
    ///
    /// Fifteen minutes, and the number is a **business** decision rather than a UI one. WeatherKit's
    /// quota is 500,000 calls a month, pooled per **Team ID across every app on the team** — not per
    /// app. At one fetch per user per quarter of an hour that is roughly 2,880 calls a user a month,
    /// or about 170 concurrent users on the free pool. Weather also does not move fast enough for a
    /// tighter interval to show the user anything.
    public static let refreshInterval: TimeInterval = 15 * 60

    /// The floor a setting may ever take this to. Below it the quota above stops working, and the
    /// user gains a number that has not changed.
    public static let minimumRefreshInterval: TimeInterval = 5 * 60

    /// Called on the main actor whenever the reading changes. Nil is published too — a refresh that
    /// failed takes the stale card away rather than leaving a temperature from an hour ago on screen
    /// with nothing to say it is old.
    public var onReading: ((WeatherReading?) -> Void)?

    public private(set) var reading: WeatherReading?

    /// Why there is no weather, in words fit for the Settings row. Nil while it is working.
    public private(set) var unavailabilityExplanation: String?

    private let provider: any WeatherProvider

    private var resolver: any WeatherPlaceResolving

    private var placeSource: WeatherPlaceSource

    private var unit: TemperatureUnit

    private var isRunning = false

    private var isPresented = false

    private var refresh: DispatchSourceTimer?

    /// Whether the "a reading arrived" line has been written since the last `start()`.
    private var hasLoggedFirstReading = false

    /// The refresh in flight, so a settings change that arrives mid-fetch does not start a second.
    private var inFlight: Task<Void, Never>?

    public init(
        provider: any WeatherProvider = WeatherKitProvider.resolve(),
        resolver: any WeatherPlaceResolving,
        placeSource: WeatherPlaceSource = .currentLocation,
        unit: TemperatureUnit = .fromLocale()
    ) {
        self.provider = provider
        self.resolver = resolver
        self.placeSource = placeSource
        self.unit = unit
        if let unavailable = provider as? UnavailableWeatherProvider {
            self.unavailabilityExplanation = unavailable.explanation
        }
    }

    /// Which units the glance is drawn in. Held here rather than read by the view, so that one
    /// change redraws one card rather than every consumer having to find the setting.
    public var temperatureUnit: TemperatureUnit { unit }

    /// Whether weather can be expected at all. Read by Settings so the pane says why, rather than
    /// leaving a card that is silently always empty.
    public var isAvailable: Bool { provider.isAvailable }

    public var providerName: String { provider.providerName }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        guard provider.isAvailable else {
            // Deliberately one line and then silence. A source that logged its unavailability on
            // every refresh it was not doing would be the noisiest thing in the export bundle.
            IslandLog.weather.info("weather source idle — provider \(provider.providerName) is unavailable")
            return
        }
        IslandLog.weather.info("weather source started — provider \(provider.providerName)")
        // The grant is the trigger, not a poll. `LocationAccess` moving to usable means a place that
        // could not be resolved a second ago now can, and the person who just answered the dialog is
        // looking at the island waiting for it.
        resolver.onAccessChange = { [weak self] _ in self?.refreshNow() }
        retune()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isPresented = false
        hasLoggedFirstReading = false
        resolver.onAccessChange = nil
        refresh?.cancel()
        refresh = nil
        inFlight?.cancel()
        inFlight = nil
        // The reading goes with it. Leaving it would let a glance summoned after the source was
        // switched off draw a temperature nothing is maintaining.
        guard reading != nil else { return }
        reading = nil
        onReading?(nil)
    }

    /// Whether a surface that draws a reading is on screen.
    ///
    /// §9's exception, applied literally: "a provider that must poll polls only while its activity
    /// is presented". Nothing about the weather is push — there is no notification, no callback and
    /// no bus — so the only honest shapes are a timer while it is being looked at, or nothing.
    ///
    /// **An activity is no longer what is being asked about.** This was armed off the standing
    /// glance activity's presence on the stack; that activity is withdrawn and the day and the sky
    /// are pages now, so the app shell answers this from the open island's current page instead —
    /// see `AppDelegate.refreshWeatherPolling`. Nothing about this source changed with it, which is
    /// the point of the question being phrased as "is anyone looking".
    public func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        retune()
    }

    /// The user changed where or in what units. Re-reads at once rather than waiting a quarter of an
    /// hour, because this is a moment they are watching for a result.
    public func apply(placeSource: WeatherPlaceSource, unit: TemperatureUnit) {
        let placeChanged = placeSource != self.placeSource
        self.placeSource = placeSource
        self.unit = unit
        guard placeChanged else {
            // A unit change moves no data. Republishing the reading unchanged is what redraws the
            // card, and it costs no network call — which is the whole reason readings are stored in
            // Celsius and converted at the edge.
            onReading?(reading)
            return
        }
        refreshNow()
    }

    /// Ask now. Called on presentation, on a settings change, and from `--glance-demo`.
    public func refreshNow() {
        guard isRunning, provider.isAvailable else { return }
        guard inFlight == nil else { return }
        let provider = self.provider
        let resolver = self.resolver
        let source = self.placeSource
        inFlight = Task { [weak self] in
            let outcome: Result<WeatherReading, any Error>
            do {
                let place = try await resolver.place(for: source)
                outcome = .success(try await provider.reading(at: place))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.inFlight = nil
            switch outcome {
            case .success(let reading):
                // Counts and outcomes only. **Never the coordinate and never the place name** —
                // where somebody is standing is the most identifying thing this app could write into
                // a file that gets emailed to strangers.
                //
                // One line, once per start, and it earns its place: until it existed, a *working*
                // weather source and one that was never started produced byte-identical logs —
                // silence. That is precisely how 2.0.0 shipped with `SourceHub` never calling
                // `start()`. It says that a reading arrived and nothing whatever about it, so it
                // carries no place, no coordinate and no temperature; §9's "nothing on the idle
                // path logs" is kept because a refresh is fifteen minutes apart at its busiest.
                if !self.hasLoggedFirstReading {
                    self.hasLoggedFirstReading = true
                    IslandLog.weather.info("first reading received")
                }
                guard self.reading != reading else { return }
                self.reading = reading
                self.onReading?(reading)
            case .failure(let error):
                IslandLog.weather.info("weather refresh failed: \(Self.reason(for: error))")
                guard self.reading != nil else { return }
                self.reading = nil
                self.onReading?(nil)
            }
        }
    }

    // MARK: - The timer, and when there is one at all

    /// Arms, re-arms or cancels the refresh so it matches the moment.
    ///
    /// Compared against what is already running rather than rebuilt unconditionally, for the reason
    /// `TimerSource.retune` gives: this is called from presentation changes and settings changes, and
    /// tearing a `DispatchSourceTimer` down and building another on each would spend more on the
    /// bookkeeping than on the work.
    private func retune() {
        let wanted = isRunning && isPresented && provider.isAvailable
        guard wanted != (refresh != nil) else { return }
        guard wanted else {
            refresh?.cancel()
            refresh = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.refreshInterval, repeating: Self.refreshInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        timer.resume()
        refresh = timer
        // The first read happens now rather than in fifteen minutes: the glance has just reached the
        // stage and an empty card while the timer waits out its first interval reads as broken.
        refreshNow()
    }

    /// A failure as a **category**, never as a message that could carry a place.
    private static func reason(for error: any Error) -> String {
        switch error as? WeatherUnavailable {
        case .notEntitled: "no entitlement"
        case .noPlace: "no location and no city set"
        case .serviceFailed: "the service did not answer"
        case nil: "unknown"
        }
    }
}
