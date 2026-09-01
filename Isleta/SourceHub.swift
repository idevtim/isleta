import AppKit
import ApplicationServices
import Foundation
import IslandActivities
import IslandKit
import IslandSettings
import IslandSources

/// Every `ActivitySource` Isleta runs, and the one place they are joined to the coordinator.
///
/// This is wiring and nothing else, which is the point: the sources know how to observe the system
/// and the coordinator knows what to do with an activity, and neither is allowed to know about the
/// other. The three things that genuinely belong here are the three that need both halves — routing
/// `onActivity`/`onDismiss`, deciding which sources the user's configuration allows to run, and
/// reading each source's `authorization` back out for Settings and diagnostics.
///
/// **It lives in the app shell rather than in IslandSources on purpose.** Starting a source is a
/// policy decision that reads `IsletaConfiguration`, and IslandSources must never read IslandSettings
/// — a source that reaches for user preferences is a source that cannot be tested without them, and
/// `SystemHUDSuppression` says as much in its own documentation. The shell is the only layer that
/// legitimately sees both.
///
/// # §10, made structural
///
/// Nothing in here prompts at launch. `start()` on every source is documented never to ask, and the
/// Now Playing scripting route checks Automation with `askUserIfNeeded: false` before it ever sends
/// an Apple event. The calls that *can* raise a permission dialog — the calendar, the location, the
/// Focus — are each reachable from one button in a window the user opened, and
/// from nowhere on the launch path.
@MainActor
final class SourceHub {

    /// One source, plus the two things the protocol deliberately does not expose: which kind it
    /// publishes (so the user's per-source toggle can be found without string matching), and whether
    /// this object has started it.
    ///
    /// `isRunning` is tracked here rather than read from the source because `ActivitySource` has no
    /// such member, and it should not: "is this observing" is a different question per source —
    /// `SystemHUDSource` is running when CoreAudio has a listener, and a source can be running with
    /// nothing attached because the thing it watches is idle. What the hub knows, and all it claims,
    /// is whether it asked.
    private struct Entry {
        let kind: ActivityKind
        let source: any ActivitySource
        var isRunning = false
    }

    private let coordinator: ActivityCoordinator
    private var entries: [Entry]

    /// Held concretely as well as through `entries`, for the two things only they can answer:
    /// the scripting route's separate Automation verdict, and re-checking Accessibility after the
    /// user has been away in System Settings.
    /// Exposed, unlike the other three, because Now Playing is the one source with a channel *back*
    /// to the system: `transport` sends commands and `artwork` fetches covers, and neither is
    /// expressible through `ActivitySource`, which is deliberately one-way. See `NowPlayingBridge`,
    /// which is the only reader.
    let nowPlaying: NowPlayingSource
    private let systemHUD: SystemHUDSource
    private let timers: TimerSource
    private let bluetooth: BluetoothDeviceSource

    /// Stage 2's three. Held concretely for the same reason the others are: the settings rows need
    /// to say something a `SourceAuthorization` cannot — whether this Mac has a battery at all, and
    /// how many moments each has shown.
    private let power: PowerSource
    private let calls: CallSource

    /// Whether `weather` has been started. It is **not in `entries`** — it publishes *into* the
    /// calendar source rather than onto the island — so the loop in `apply(_:)` cannot do this
    /// bookkeeping for it.
    private var weatherIsRunning = false

    /// "A Focus is on, do not show this", asked at the funnel every activity already passes
    /// through.
    ///
    /// It lives here rather than in a source because it is not a source: there is no change
    /// notification for Focus anywhere on macOS (see `FocusGate`), so it can only ever be *asked*,
    /// and the one moment worth asking at is the moment something is about to go on the island. The
    /// hub is the only place every source's output meets, which makes it the only place the question
    /// gets asked once instead of in eight sources.
    let focus = FocusGate()

    /// Held concretely for three things `ActivitySource` deliberately cannot express: the day's
    /// snapshot for `GlanceLayerView`, the join link a button needs, and the include-list the user
    /// picked in Settings. `NowPlayingSource` is held for the same reason — it is the other source
    /// with a channel back out.
    let calendar: CalendarSource

    /// **Not an `ActivitySource`, and not in `entries`.** Weather is not an activity: there is no
    /// `ActivityKind.weather` and there should not be, because the island never announces the
    /// weather, it *contains* it — one card inside the glance. It publishes a reading, and the
    /// reading is folded into the calendar source's snapshot so the open island has one height
    /// decided by one publisher. See `WeatherSource`.
    let weather: WeatherSource

    private let placeResolver = CoreLocationPlaceResolver()

    /// Completions for a city being typed in Settings.
    ///
    /// Held for the life of the hub rather than built per keystroke, and it costs nothing to hold:
    /// `CitySearch` constructs its `MKLocalSearchCompleter` on the first query and has no timer, no
    /// subscription and no delegate registered between them. Not an `ActivitySource` and not in
    /// `entries` — it publishes nothing and announces nothing, exactly like `weather`; it answers a
    /// question the settings window asks.
    private let citySearch = CitySearch()

    /// Held concretely rather than only as an `Entry`, so the one thing that is not an
    /// `ActivitySource` question — the absence threshold — has somewhere to be read from.
    ///
    /// That threshold was the user's through 2.0 (`IsletaConfiguration.welcomeBackMinimumAbsence`,
    /// a slider from nought to fifteen minutes) and is `WelcomeBackPolicy.defaultMinimumAbsence`
    /// again: five minutes, which is what the policy was born with and what the slider's neutral
    /// position was. Nothing writes it here, which is why there is no assignment in `apply`.
    private let systemEvents: SystemEventsSource


    init(coordinator: ActivityCoordinator) {
        self.coordinator = coordinator
        self.nowPlaying = NowPlayingSource()
        self.systemHUD = SystemHUDSource()
        self.timers = TimerSource()
        // The monitor is chosen here rather than inside the source, so that the one place a private
        // selector is reached for is also the one place the fallback is named. On a Mac with no
        // radio `IOBluetoothDeviceMonitor.isAvailable` is false and the source idles; there is no
        // separate branch for it.
        // Two monitors, because the feature has two events and only one of them is IOBluetooth's.
        // `AudioRouteMonitoring` holds the table: an AirPods pair leaving and re-entering the ears
        // never drops the Bluetooth link, so the only thing that moves is the system output device.
        self.bluetooth = BluetoothDeviceSource(
            monitor: IOBluetoothDeviceMonitor(),
            routeMonitor: CoreAudioRouteMonitor()
        )
        self.systemEvents = SystemEventsSource()
        self.calendar = CalendarSource()
        self.power = PowerSource()
        self.calls = CallSource()
        // The provider is chosen here, beside the fallback, for the reason the Bluetooth monitor is:
        // one place reaches for the gated route and one place names what happens without it. **Which
        // of the two you get is decided by the signature, not by a setting**: a Release build signed
        // with the Developer ID identity and the embedded profile is `weatherkit entitled` and this
        // is the real provider, while a Debug build is ad-hoc signed, cannot carry a developer
        // entitlement at all, and gets `UnavailableWeatherProvider` — so the calendar draws with
        // nothing beside it under `Tools/check.sh` and everything launched from `.build/xcode`.
        // `WeatherKitProvider` holds the whole argument, including why it may not simply be added
        // to the Debug entitlements.
        self.weather = WeatherSource(
            provider: WeatherKitProvider.resolve(),
            resolver: placeResolver
        )

        self.entries = [
            Entry(kind: .nowPlaying, source: nowPlaying),
            Entry(kind: .systemHUD, source: systemHUD),
            Entry(kind: .welcomeBack, source: self.systemEvents),
            Entry(kind: .timer, source: timers),
            Entry(kind: .deviceConnected, source: bluetooth),
            // One entry for three kinds. `CalendarSource` publishes `.glance`, `.calendarAlert` and
            // `.meeting` from one fetch of one store; the user's other two switches gate what it
            // publishes rather than how many stores are open. See `apply`.
            Entry(kind: .glance, source: calendar),
            // Stage 2.
            Entry(kind: .power, source: power),
            Entry(kind: .call, source: calls),
        ]

        // Routed once, at construction, rather than on every `start()`. The callbacks are the
        // source's only way out and they do not change; re-pointing them per start would mean a
        // source that publishes on its way down — `NowPlayingSource.stop()` does exactly that —
        // could land in a closure that has just been replaced.
        for entry in entries {
            entry.source.onActivity = { [weak self] activity in
                guard let self else { return }
                // The Focus gate, and this is the only place it is consulted. It costs a 15 ms XPC
                // read for the two kinds a Focus can suppress and **nothing at all** for the other
                // fourteen, which is why it is asked here rather than inside each source: a volume
                // HUD is on the path a keypress takes, and it never asks.
                guard self.focus.allows(activity.kind) else { return }
                self.coordinator.present(activity)
            }
            entry.source.onDismiss = { [weak self] id in
                self?.coordinator.dismiss(id)
            }
        }

        // **The one signal that is not an activity**, and it goes straight past the coordinator
        // because there is nothing on the stack for it to change: the user pressed a key asking for
        // more of a level that has none left, which produces no reading at all. See
        // `SystemHUDSource.onLimitPushed`, and `IslandScreenModel.bounce(toward:reduceMotion:)` for
        // the one entry point both causes of a rebound share.
        //
        // Gated by the Focus rule like every activity, and read from the same table: a Focus that
        // suppresses the volume HUD must suppress the island moving for it too, or Do Not Disturb
        // would silence the picture and leave the gesture.
        systemHUD.onLimitPushed = { [weak self] _, limit in
            guard let self, self.focus.allows(.systemHUD) else { return }
            self.onLimitPushed?(limit)
        }
    }

    /// A level the user is driving was pushed past its end. The app shell rebounds every island.
    ///
    /// Its own callback rather than a synthetic activity for the reason `onLimitPushed` gives on the
    /// source: nothing changed, so an activity carrying it would be identical to the one already on
    /// stage and `ActivityStack` would correctly report `.none`.
    var onLimitPushed: ((ActivityLimit) -> Void)?

    // MARK: - Lifecycle

    /// Starts and stops sources to match the user's configuration.
    ///
    /// Called once at launch and again on every settings change, from the same path — a separate
    /// "start at launch" branch is how the two drift until one of them is missing a source. Each
    /// source's `start()` and `stop()` are idempotent, but the `isRunning` bookkeeping is what keeps
    /// a settings change that touched the hot key from stopping and restarting four observers,
    /// spawning an `osascript` and re-reading a CoreAudio baseline for nothing.
    func apply(_ configuration: IsletaConfiguration) {
        // The two announcing kinds are the calendar source's switches rather than its own entries,
        // because all three come from one fetch — see the `entries` note. Assigned on every apply
        // and outside the `isRunning` bookkeeping, for the reason the Welcome Back threshold is:
        // they must land whether or not the source is currently running, so switching the glance
        // back on does not resurrect a stale answer.
        calendar.publishesAlerts = configuration.sources.calendarAlerts
        calendar.publishesMeetings = configuration.sources.meetings

        // The HUD source's three sub-switches, assigned for the reason the calendar's two above are
        // and outside the `isRunning` bookkeeping for the same one: one source reads four levels, so
        // "which levels" is a property of the source rather than a second entry in the loop below.
        // The setter attaches and detaches the individual monitors, so a level switched off leaves
        // no CoreAudio listener and no DisplayServices callback behind — see `enabledHUDs`.
        systemHUD.enabledHUDs = configuration.sources.enabledHUDs
        // **Gated on the grant as well as on the setting.** Without Accessibility the tap receives
        // nothing at all — a non-nil mach port and an empty stream, measured twice — so replacing
        // would swallow no keys and suppress no HUD while the settings switch claimed otherwise.
        // Read live rather than cached: the user can grant it from the first-run flow's own page,
        // and the next `apply` after they come back picks it up.
        systemHUD.replacesVolumeKeys = configuration.suppressSystemHUDs && AXIsProcessTrusted()
        systemHUD.replacesBrightnessKeys = configuration.suppressBrightnessHUD && AXIsProcessTrusted()

        // The Focus gate is a behavior rather than a source, so it is not in the loop below — there
        // is nothing to start or stop, only a question to stop asking. Assigned on every apply for
        // the same reason the two above are. See `SourceToggles.respectsFocus`, which is the flag
        // that used to be `focusChanges` and could never do anything.
        focus.isEnabled = configuration.sources.respectsFocus

        for index in entries.indices {
            let wanted = configuration.sources[entries[index].kind]
            guard wanted != entries[index].isRunning else { continue }
            entries[index].isRunning = wanted
            if wanted {
                entries[index].source.start()
            } else {
                entries[index].source.stop()
            }
            // After `start()`, so the authorization printed is the one the source settled on —
            // the Now Playing route is chosen in its initializer and the AX source's answer
            // depends on whether it attached.
            IslandLog.sources.info(
                "\(entries[index].source.sourceName) \(wanted ? "started" : "stopped") — authorization: \(entries[index].source.authorization)"
            )
        }

        // The weather is started here beside the loop rather than inside it, and **its absence is the bug
        // 2.0.0 shipped with**: `WeatherSource` is not an `ActivitySource` — it publishes *into* the
        // calendar source rather than onto the island — so it is not in `entries`, and `stopAll()`
        // had the matching `weather.stop()` while nothing anywhere called `start()`.
        //
        // Every path downstream then failed *silently and correctly*. `refreshNow()` returns at its
        // `isRunning` guard, so no request is made and no failure is logged; `retune()` wants
        // `isRunning` too, so presenting the glance armed nothing. The result is a glance with no
        // weather on a Mac that is entitled, located and configured — indistinguishable, in the log
        // and on screen, from one that is none of those. It rides `sources.glance` because the
        // reading has nowhere else to be drawn.
        if configuration.sources.glance != weatherIsRunning {
            weatherIsRunning = configuration.sources.glance
            if weatherIsRunning { weather.start() } else { weather.stop() }
        }

    }

    /// Everything down, for `applicationWillTerminate`.
    ///
    /// Not optional and not best-effort: a leaked `AXObserver` keeps a run-loop source alive, and an
    /// orphaned `perl` from the adapter route outlives the app that spawned it. `stop()` is
    /// idempotent on every source, so calling this after a partial start is safe.
    ///
    /// **`stopAndWait()` and not `stop()`**, because this is the one caller with no "later". The
    /// caller returns into `exit()`, so a source that merely schedules its teardown gets no chance
    /// to perform it — which is exactly how an ordinary Quit came to strand a `perl` per launch. For
    /// every source but Now Playing the two are the same call.
    func stopAll() {
        IslandLog.sources.info("stopping every source and waiting for their children")
        // Not in `entries`, so it is not reached by the loop below. Stopped first, because it
        // publishes *into* the calendar source and a reading landing after that source has retracted
        // its glance would put one back on an island that is being torn down.
        weather.stop()
        weatherIsRunning = false
        for index in entries.indices {
            entries[index].isRunning = false
            entries[index].source.stopAndWait()
        }
        // `SystemHUDSuppression.restore()` used to be called here. It is not any more, and its
        // absence is now the guarantee rather than a gap in it: Isleta no longer offers a switch to
        // suppress anything, so there is no path by which system state could need putting back. The
        // type stays in IslandSources as the record of why — every mechanism that works outlives the
        // process, and §2.6 requires the HUD back after a crash.
    }

    /// The user's glance record: which calendars, which units, and where.
    ///
    /// Separate from `apply(_:)` because the record is separate — `GlanceSettings` lives in its own
    /// `UserDefaults` blob rather than in `IsletaConfiguration`, which is a **queued integration**
    /// and is documented as such on that type. When it moves, this folds into `apply` and this
    /// method goes away.
    func apply(glance settings: GlanceSettings) {
        calendar.includedCalendarIDs = settings.includedCalendarIDs
        // Celsius or Fahrenheit follows System Settings ▸ General ▸ Language & Region ▸
        // Temperature, read through `Locale.measurementSystem`. It was a picker in this app's own
        // Glance pane through 2.0, which is a second place to answer a question macOS already asks
        // once for every app on the machine. `CalendarSource` is no longer given it: the day and
        // the sky are drawn by the pages now, and `GlanceModel` holds the unit they read.
        let unit = TemperatureUnit.fromLocale()
        weather.apply(
            placeSource: settings.usesCurrentLocation ? .currentLocation : .city(settings.city),
            unit: unit
        )
    }

    /// What the Glance settings pane draws, read live.
    ///
    /// Assembled here because this is the only layer that sees both a running source and the
    /// settings window. The three offers are nil unless a prompt or a deep link would actually do
    /// something — §10's "no nagging", enforced by there being no control rather than by a disabled
    /// one.
    func glanceSettingsState() -> GlanceSettingsState {
        let calendarAccess = calendar.storeAccess
        let locationAccess = placeResolver.access

        // The three closures are built as explicitly typed locals rather than inline ternaries. The
        // inline form is what this was first written as, and it defeated the type checker outright —
        // `error: failed to produce diagnostic for expression; please submit a bug report` — because
        // an optional main-actor closure chosen by a ternary inside a multi-argument initializer has
        // no obvious contextual type to work back from. Spelling the type is also the clearer read.
        var askCalendar: (@MainActor () -> Void)?
        if calendarAccess == .notDetermined {
            askCalendar = { [weak self] in self?.calendar.requestAccessFromUserInitiatedMoment() }
        }
        // The answer is handed back rather than only raised: the Glance pane's "Use my location"
        // switch is drawn from the grant and cannot move until there is one — see
        // `GlanceSettingsState.requestLocationAccess`.
        var askLocation: GlanceSettingsState.LocationRequest?
        if locationAccess == .notDetermined {
            askLocation = { [weak self] answer in
                self?.placeResolver.requestAccessFromUserInitiatedMoment(then: answer)
            }
        }
        let openPrivacy: @MainActor (GlanceSettingsState.PrivacyPane) -> Void = { pane in
            let string: String = switch pane {
            case .calendars: GlancePrivacySettings.calendarsURLString
            case .location: GlancePrivacySettings.locationURLString
            }
            guard let url = URL(string: string) else { return }
            NSWorkspace.shared.open(url)
        }

        return GlanceSettingsState(
            calendarAccess: calendarAccess,
            calendars: calendar.availableCalendars,
            locationAccess: locationAccess,
            weatherIsAvailable: weather.isAvailable,
            weatherExplanation: weather.unavailabilityExplanation,
            requestCalendarAccess: askCalendar,
            requestLocationAccess: askLocation,
            openPrivacySettings: openPrivacy,
            // **Not gated on the weather being available**, unlike everything else on this card. A
            // build with no WeatherKit entitlement still stores a city, and the day the entitlement
            // lands it has to be the right one — a search switched off until the feature works would
            // leave every existing user's typo in place at exactly the moment it started mattering.
            searchCities: { [weak self] query in
                await self?.citySearch.suggestions(for: query) ?? []
            },
            cancelCitySearch: { [weak self] in self?.citySearch.cancel() }
        )
    }

    /// What the first-run flow's five permission pages draw, read live.
    ///
    /// Assembled here for `glanceSettingsState()`'s reason — this is the only layer that sees both a
    /// running source and the settings window — and with the same §10 rule made structural: a page
    /// gets a `request` closure only where a dialog would actually appear, so "no nagging" is
    /// enforced by there being no button rather than by a disabled one.
    ///
    /// **This is the only place in Isleta that hands out a closure which can raise a TCC dialog at
    /// launch-adjacent time**, and it is safe because none of them is *called* at launch — the flow
    /// opens during launch, and every one of these fires from a button the user pressed.
    /// `didPromptDuringLaunch` is the runtime check on that claim.
    func onboardingState() -> OnboardingState {
        var permissions: [OnboardingPermission: OnboardingState.Permission] = [:]

        // MARK: Automation
        //
        // **Populated in every state, including the one where there is nothing to ask.** This block
        // was first written as `if let script = provider as? NowPlayingScriptProvider`, which is the
        // correct test for *whether Automation is needed* and the wrong shape for a page: on a Mac
        // where the adapter route is live the cast fails, no permission was recorded, and the page
        // fell back to its `.notDetermined` copy — "Choose OK when macOS asks whether Isleta can
        // control your music app", under a Continue that would never raise a dialog. Caught by
        // looking at it. `.notNeeded` is the state that was missing.
        let script = nowPlaying.provider as? NowPlayingScriptProvider
        // The adapter reads Now Playing directly and asks nobody for anything, so Automation is the
        // *fallback* route's permission and only the fallback's. No script provider means nothing to
        // allow, rather than something not yet allowed.
        let automationAccess = script.map { Self.onboardingAccess(from: $0.initialReadAuthorization) } ?? .notNeeded
        var askAutomation: OnboardingState.Permission.Request?
        if automationAccess == .notDetermined, let script {
            askAutomation = { [weak self] answer in
                self?.script(script, requestAutomation: answer)
            }
        }
        // Automation's pane, unlike the other four, is not one of ours to deep-link into usefully:
        // it lists every app that has ever asked, and Isleta is only in it once it has. `.denied`
        // means it is, so the link is offered exactly then.
        //
        // `var` plus an `if` rather than an inline ternary, and this is not style. The inline form
        // is what all five of these were first written as, and it defeated the type checker outright
        // — five copies of `failed to produce diagnostic for expression`, exactly as
        // `glanceSettingsState` records it doing for the same shape. A typed `let` with a ternary is
        // *not* enough either: `@MainActor` closures are implicitly `@Sendable` in Swift 6 and the
        // branches of the ternary are not.
        var openAutomation: (@MainActor () -> Void)?
        if automationAccess == .denied {
            openAutomation = { Self.open(AutomationPrivacySettings.settingsURLString) }
        }
        permissions[.automation] = OnboardingState.Permission(
            access: automationAccess,
            request: askAutomation,
            openSettings: openAutomation,
            payoff: Self.installedPayoff(
                NowPlayingPlayer.all.map { ($0.bundleIdentifier, "music.note") }
            )
        )

        // MARK: Calendar
        let calendarAccess: OnboardingState.Permission.Access = switch calendar.storeAccess {
        case .granted: .granted
        case .notDetermined: .notDetermined
        // `writeOnly` and `restricted` are refusals as far as this page is concerned: neither can
        // read an event, and neither can be turned into a grant by asking again. Folding them in
        // here rather than adding cases is the same call `SourceSettingsRow.Status` makes.
        case .denied, .writeOnly, .restricted: .denied
        }
        var askCalendar: OnboardingState.Permission.Request?
        if calendarAccess == .notDetermined {
            askCalendar = { [weak self] answer in
                guard let self else { return }
                self.calendar.requestAccessFromUserInitiatedMoment()
                // EventKit answers on a background queue and `requestAccessFromUserInitiatedMoment`
                // reports nothing back, so the answer is read rather than received. One hop to the
                // next main-actor turn is not enough — the dialog is modal to the user — so this
                // reports the state as it stands and the page's `didBecomeActive` refresh is what
                // notices the grant. That is why the page stays put on anything but `.granted`.
                answer(Self.onboardingAccess(from: self.calendar.authorization))
            }
        }
        var openCalendar: (@MainActor () -> Void)?
        if calendarAccess == .denied {
            openCalendar = { Self.open(GlancePrivacySettings.calendarsURLString) }
        }
        permissions[.calendar] = OnboardingState.Permission(
            access: calendarAccess,
            request: askCalendar,
            openSettings: openCalendar,
            payoff: Self.installedPayoff(Self.calendarApps)
        )

        // MARK: Location
        let locationAccess: OnboardingState.Permission.Access = switch placeResolver.access {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        }
        var askLocation: OnboardingState.Permission.Request?
        if locationAccess == .notDetermined {
            askLocation = { [weak self] answer in
                self?.placeResolver.requestAccessFromUserInitiatedMoment { access in
                    answer(Self.onboardingAccess(from: access))
                }
            }
        }
        var openLocation: (@MainActor () -> Void)?
        if locationAccess == .denied {
            openLocation = { Self.open(GlancePrivacySettings.locationURLString) }
        }
        permissions[.location] = OnboardingState.Permission(
            access: locationAccess,
            request: askLocation,
            openSettings: openLocation,
            // Hardware and a place rather than apps: there is no third-party "weather app" this
            // permission is about, and showing the user Apple's Weather icon would name an app
            // Isleta does not read from.
            payoff: [
                OnboardingState.Payoff(id: "location", name: appText("onboarding.payoff.here", "Here"), symbol: "location.fill"),
                OnboardingState.Payoff(id: "forecast", name: appText("onboarding.payoff.forecast", "Forecast"), symbol: "cloud.sun.fill"),
                OnboardingState.Payoff(id: "conditions", name: appText("onboarding.payoff.conditions", "Conditions"), symbol: "thermometer.medium")
            ]
        )

        // MARK: Bluetooth
        //
        // **No `request`, in any state, and that is the platform rather than an omission.**
        // CoreBluetooth raises its dialog when `IOBluetoothDeviceMonitor.start()` registers for
        // connect notifications, which is at launch — before this page can be reached on a first
        // run — and there is no call that asks a second time. A button here would be the control
        // that visibly does nothing, which is the same reason `action(for:)` refuses to draw one.
        let bluetoothAccess = Self.onboardingAccess(from: bluetooth.authorization)
        var openBluetooth: (@MainActor () -> Void)?
        if bluetoothAccess == .denied {
            openBluetooth = { Self.open(BluetoothPrivacySettings.settingsURLString) }
        }
        permissions[.bluetooth] = OnboardingState.Permission(
            access: bluetoothAccess,
            request: nil,
            openSettings: openBluetooth,
            payoff: [
                OnboardingState.Payoff(id: "headphones", name: appText("onboarding.payoff.headphones", "Headphones"), symbol: "headphones"),
                OnboardingState.Payoff(id: "earbuds", name: appText("onboarding.payoff.earbuds", "Earbuds"), symbol: "airpods.gen3"),
                OnboardingState.Payoff(id: "speaker", name: appText("onboarding.payoff.speaker", "Speakers"), symbol: "hifispeaker.fill")
            ]
        )

        // MARK: Accessibility
        //
        // The only one of the five whose offer survives a refusal. `AXIsProcessTrusted` cannot
        // report *denied* at all — see `AccessibilityAccess` — so an untrusted process is always
        // `.notDetermined` here, and `AXIsProcessTrustedWithOptions` genuinely does raise its dialog
        // again. "Ask Again" is an honest button on this page and would be a lie on the other four.
        let accessibilityGranted = AccessibilityAccess.access == .granted
        var askAccessibility: OnboardingState.Permission.Request?
        if !accessibilityGranted {
            askAccessibility = { answer in
                AccessibilityAccess.request()
                // Read back immediately, which will almost always still say no: the dialog is modal
                // to the user, and the grant is thrown in System Settings afterwards. The page's
                // `didBecomeActive` refresh is what actually notices, which is why this page stays
                // put and offers again rather than advancing on a press.
                answer(AccessibilityAccess.access == .granted ? .granted : .notDetermined)
            }
        }
        // Offered in **both** states, unlike everywhere else here. Accessibility's grant is a switch
        // the user throws themselves after the dialog adds Isleta to the list, so the pane is useful
        // to somebody who answered the dialog and has not finished.
        var openAccessibility: (@MainActor () -> Void)?
        if !accessibilityGranted {
            openAccessibility = { Self.open(AccessibilityPrivacySettings.settingsURLString) }
        }
        permissions[.accessibility] = OnboardingState.Permission(
            access: accessibilityGranted ? .granted : .notDetermined,
            request: askAccessibility,
            openSettings: openAccessibility,
            payoff: [
                OnboardingState.Payoff(id: "volume", name: appText("onboarding.payoff.volume", "Volume"), symbol: "speaker.wave.2.fill"),
                OnboardingState.Payoff(id: "brightness", name: appText("onboarding.payoff.brightness", "Brightness"), symbol: "sun.max.fill"),
                OnboardingState.Payoff(id: "mediaKeys", name: appText("onboarding.payoff.mediaKeys", "Media keys"), symbol: "playpause.fill")
            ]
        )

        return OnboardingState(permissions: permissions)
    }

    /// Ask for Automation and hand the answer back. Extracted only so the closure above stays a
    /// single line — the type checker has already refused a multi-argument initializer holding an
    /// inline optional main-actor closure once in this file (see `glanceSettingsState`).
    private func script(
        _ provider: NowPlayingScriptProvider,
        requestAutomation answer: @escaping @MainActor (OnboardingState.Permission.Access) -> Void
    ) {
        provider.requestAutomationFromUserInitiatedMoment { result in
            answer(Self.onboardingAccess(from: result))
        }
    }

    /// `SourceAuthorization`'s four states as the flow's four. One for one, and it took two goes.
    ///
    /// `.notRequired` was collapsed into `.granted` on the argument that both mean "Continue
    /// advances" — true of the button, false of the sentence above it. A page that says "Allowed"
    /// about a permission nobody was ever asked for is telling the user they made a choice they did
    /// not make, and on the Bluetooth page it would say it to a Mac with no radio. See
    /// `OnboardingState.Permission.Access.notNeeded`.
    private static func onboardingAccess(
        from authorization: SourceAuthorization
    ) -> OnboardingState.Permission.Access {
        switch authorization {
        case .granted: .granted
        case .notRequired: .notNeeded
        case .undetermined: .notDetermined
        case .denied: .denied
        }
    }

    private static func onboardingAccess(from access: CalendarAccess) -> OnboardingState.Permission.Access {
        switch access {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .denied, .writeOnly, .restricted: .denied
        }
    }

    private static func onboardingAccess(from access: LocationAccess) -> OnboardingState.Permission.Access {
        switch access {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        }
    }

    /// The calendar apps worth showing, and the symbol each falls back to.
    ///
    /// A closed list rather than a search for anything that handles `.ics`, for
    /// `NowPlayingPlayer.all`'s reason: this row is three icons wide, so the question is not "which
    /// apps could" but "which three would a person recognise as their calendar". Anything not
    /// installed is simply dropped.
    private static let calendarApps: [(String, String)] = [
        ("com.apple.iCal", "calendar"),
        ("com.flexibits.fantastical2.mac", "calendar"),
        ("notion.id", "calendar")
    ]

    /// Resolve bundle identifiers to what is actually installed on *this* Mac.
    ///
    /// The whole point of the row, and the reason it is built here rather than in IslandSettings: a
    /// page that shows Spotify to somebody who has never installed it is telling them about an app
    /// instead of about their Mac, and `NSWorkspace.urlForApplication` is a live system read that
    /// IslandSettings may not make (§3).
    ///
    /// The **display name comes from the bundle**, never from a string in Isleta. A user who renamed
    /// the app, or runs it in another language, is looking at the name on their own screen.
    private static func installedPayoff(_ candidates: [(String, String)]) -> [OnboardingState.Payoff] {
        let workspace = NSWorkspace.shared
        return candidates.compactMap { identifier, symbol in
            guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return OnboardingState.Payoff(
                id: identifier,
                // `displayName` keeps the ".app" off and honours a localized bundle name; the
                // last-path-component fallback is for a bundle it cannot read rather than for a
                // missing app, which `urlForApplication` has already ruled out above.
                name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                icon: workspace.icon(forFile: url.path),
                symbol: symbol
            )
        }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the Sources pane draws beside its rows, read live.
    ///
    /// Assembled here for `glanceSettingsState()`'s reason — this is the only layer that sees both a
    /// running source and the settings window — and the three offers are nil unless a prompt or a
    /// deep link would actually do something, which is §10 enforced by there being no control rather
    /// than a disabled one.
    ///
    /// The three parts have nothing to do with each other and are in one record because they share
    /// one refresh: `SettingsView` re-reads this when Isleta comes back to the front, and splitting
    /// it into three closures would be three snapshots that can disagree about when they were taken.
    func sourcesPaneState() -> SourcesPaneState {
        let focusAccess: SourcesPaneState.FocusAccess = switch focus.authorization {
        case .authorized: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable: .unavailable
        }

        var askFocus: (@MainActor () -> Void)?
        if focusAccess == .notDetermined {
            askFocus = { [weak self] in
                // Fire-and-forget rather than awaited, because the button is synchronous and the
                // dialog took **8.42 s** to answer when it was measured — that interval is a person
                // reading. The pane re-reads the authorization when the window comes back to the
                // front, which is exactly when the answer has changed.
                Task { @MainActor in await self?.requestFocusAuthorization() }
            }
        }

        let openPrivacy: @MainActor (SourcesPaneState.PrivacyPane) -> Void = { pane in
            let string: String = switch pane {
            case .focus: FocusPrivacySettings.settingsURLString
            }
            guard let url = URL(string: string) else { return }
            NSWorkspace.shared.open(url)
        }

        return SourcesPaneState(
            focusAccess: focusAccess,
            requestFocusAccess: askFocus,
            openPrivacySettings: openPrivacy
        )
    }

    /// Re-checks the permissions that can change while Isleta is running.
    ///
    /// Called when the user is already looking at Isleta — the status menu opening, the settings
    /// window coming forward. Deliberately not discovered: a permission changes only when somebody
    /// goes to System Settings, and noticing that without being told means either a timer on the
    /// idle path or an undocumented distributed notification, both worse than one call at a moment
    /// that is already an event.
    func refreshAuthorizations() {
        // The Focus answer is held for a second so that a burst of reads does not pay for three XPC
        // round trips; a user coming back from System Settings is exactly the moment that held
        // answer is worth throwing away.
        focus.refresh()
    }

    /// Ask for permission to read whether a Focus is on, from a moment the user initiated.
    ///
    /// Reached from the Focus card in the Sources pane, which is the only caller and the only thing
    /// in Isleta that can put this dialog on screen.
    ///
    /// **The gate was inert until that card existed**, and it is worth saying why rather than
    /// leaving it as history: Focus is a gate rather than a source, so it has no `entries` slot to
    /// hang a row on, and the switch that did exist — `SourceToggles.focusChanges` — was for
    /// *announcing* a Focus change, which nothing on macOS can do. So `INFocusStatusCenter` sat at
    /// `.notDetermined`, `IntentsFocusStatus` correctly refused every read, and nothing was ever
    /// withheld. The switch is now `respectsFocus` and this is the button beside it.
    func requestFocusAuthorization() async {
        IslandLog.system.info("focus: authorization requested from the settings window")
        await focus.requestAuthorizationFromUserInitiatedMoment()
    }

    // MARK: - Reporting

    /// What each source is doing, in a form safe to print.
    ///
    /// Safe by construction rather than by care: every source reports through a diagnostics value
    /// carrying counts and flags, and no source's diagnostics has a field a track title, an event
    /// title or a file name could reach.
    ///
    /// **`kind.rawValue`, deliberately, and not `title(for:)`.** This feeds `--perf-report` and the
    /// "Export Logs…" bundle, which are read by whoever is debugging and are emailed to strangers —
    /// so they are English wherever they are read, exactly as every `IslandLog` line is. `title` is
    /// translated as of Stage 7.9, and leaving it here would have made a German user's bug report
    /// arrive with a German column in it and every grep written for that report stop matching. The
    /// raw value is the better answer anyway rather than a consolation: it is the identifier the
    /// code uses, it cannot drift from the display name because it is not one, and it is what
    /// somebody reading the report wants to search the source for.
    var statuses: [SourceStatus] {
        entries.map { entry in
            SourceStatus(
                kind: entry.kind,
                name: entry.kind.rawValue,
                isEnabled: entry.isRunning,
                authorization: entry.source.authorization,
                detail: detail(for: entry.kind)
            )
        }
    }

    /// Settings' Sources section, phrased for a person.
    ///
    /// Built here rather than in IslandSettings because this is the only layer that sees both a live
    /// `ActivitySource` and `IsletaConfiguration`. Every row gets a `summary` that holds whether or
    /// not the source can run — §10 asks for what granting would unlock, not for what failed.
    var settingsRows: [SourceSettingsRow] {
        entries.map { entry in
            SourceSettingsRow(
                kind: entry.kind,
                title: Self.title(for: entry.kind),
                summary: Self.summary(for: entry.kind),
                status: status(for: entry),
                action: action(for: entry),
                options: options(for: entry.kind)
            )
        }
    }

    /// The finer switches inside a row, for the one source that has any.
    ///
    /// **Sub-switches rather than three more rows**, because `SourceSettingsRow` is keyed on
    /// `ActivityKind` — deliberately, so that two rows for one kind is not expressible — and volume,
    /// display brightness and keyboard backlight are all `ActivityKind.systemHUD`. They are cases of
    /// `SystemHUD`, which is what a level *is*, and minting three activity kinds to buy three rows
    /// would be the duplicate vocabulary `SourceToggles` opens by refusing.
    ///
    /// Each carries its own unavailability sentence rather than borrowing the row's, so a Mac with
    /// no keyboard backlight grays one switch and says why beside it instead of declaring the whole
    /// source unavailable — see `status(for:)`.
    private func options(for kind: ActivityKind) -> [SourceSettingsRow.Option] {
        guard kind == .systemHUD else { return [] }
        let supported = systemHUD.supportedHUDs
        // `.mute` is not here. It rides `.volume`'s switch — see `SourceToggles.volumeHUD` — so
        // listing it would draw two switches writing one flag.
        return [SystemHUD.volume, .brightness].map { hud in
            SourceSettingsRow.Option(
                id: hud.rawValue,
                title: Self.title(for: hud),
                toggle: SourceToggles.keyPath(for: hud),
                // Volume and mute share a switch, so it is offered while *either* is readable: a
                // device that reports mute but no level still has something to say.
                unavailable: hud == .volume && supported.contains(.mute)
                    ? nil
                    : (supported.contains(hud) ? nil : systemHUD.unavailabilityExplanation(for: hud))
            )
        }
    }

    /// What a level is called beside its switch.
    ///
    /// Not `SystemHUD.accessibilityLabel`, which is the same four words for a different job: that is
    /// what VoiceOver reads when a HUD is *on screen*, where "Volume" is the whole truth because the
    /// bar beside it says the rest. This is a switch in a list of switches, where the user is
    /// choosing between them — so volume's label has to name the mute it also governs.
    private static func title(for hud: SystemHUD) -> String {
        switch hud {
        case .volume, .mute: appText("sources.systemHUD.option.volume", "Volume and mute")
        case .brightness: appText("sources.systemHUD.option.brightness", "Display brightness")
        }
    }

    private func status(for entry: Entry) -> SourceSettingsRow.Status {
        switch entry.kind {
        case .nowPlaying:
            // The scripting route works with Automation refused — live updates ride distributed
            // notifications, which are broadcast rather than requested. Reporting the refusal as the
            // *source's* authorization would make `isUsable` false and invite exactly the mistake
            // `NowPlayingScriptProvider` documents: skipping a route that works because a permission
            // governing a tenth of it was declined. So the source stays "working" and the missing
            // tenth is described separately.
            // **Not `summary(for: .nowPlaying)`.** The summary is already on screen directly above
            // this line, as the row's caption, so handing it in as the "working" sentence printed
            // the same words twice with a tick next to the second copy. A status says what is true
            // *now*; a summary says what the source is for, and the two are only interchangeable
            // when nobody is looking at both.
            guard let script = nowPlaying.provider as? NowPlayingScriptProvider else {
                return Self.status(
                    from: entry.source.authorization,
                    working: appText("sources.nowPlaying.status.working",
                                     "Working. Isleta reads what’s playing with no permission.")
                )
            }
            switch script.initialReadAuthorization {
            case .granted, .notRequired:
                return .working(appText("sources.nowPlaying.status.working",
                                        "Working. Isleta reads what’s playing with no permission."))
            case .undetermined:
                return .needsPermission(appText(
                    "sources.nowPlaying.status.undetermined",
                    """
                    Isleta will show what’s playing from the next play, pause, or track change. \
                    Allowing it to control your music app makes it show the current track straight away.
                    """
                ))
            case .denied(let explanation):
                return .working(explanation)
            }

        case .systemHUD:
            // All four HUDs have a route as of 2026-08-22 — see `DisplayBrightnessMonitor` and
            // `KeyboardBrightnessMonitor` — but three of them depend on hardware this Mac may not
            // have.
            //
            // **The missing one is reported on its own switch now, not here**, and the difference is
            // not cosmetic: this row used to read "Not available on this Mac" in full because a
            // MacBook Air had no keyboard backlight, over a source whose other three levels were
            // working perfectly. A per-level switch is somewhere for a per-level sentence to go, so
            // this line is back to answering the question it is under — can the source run at all —
            // and only a Mac that can produce none of the four gets a refusal.
            let supported = systemHUD.supportedHUDs
            guard supported.isEmpty else {
                return .working(appText("sources.systemHUD.status.working",
                                        "Working. Volume, mute and brightness need no permission."))
            }
            return .unavailable(appText(
                "sources.systemHUD.status.unavailable",
                "This Mac reports no volume, display brightness or keyboard backlight Isleta can show."
            ))

        case .deviceConnected:
            // Two facts, and the second is the one worth saying — the same shape as the HUD row
            // above it. The connection needs nothing granted; the *battery* is read through
            // undocumented properties (see `IOBluetoothDeviceMonitor`), so an OS that takes them
            // away leaves the picture working and the ring gone. A user watching a device connect
            // with no percentage beside it is owed that sentence rather than left to wonder.
            guard bluetooth.reportsBattery else {
                return .unavailable(appText(
                    "sources.deviceConnected.status.noBattery",
                    """
                    Isleta will show devices connecting, but this version of macOS no longer \
                    reports their battery level, so no charge is shown.
                    """
                ))
            }
            // Not routed through `status(from:)`, whose undetermined case is a generic sentence
            // that would be prose about a different permission entirely under this row.
            switch entry.source.authorization {
            case .granted, .notRequired:
                return .working(appText("sources.status.working", "Working."))
            case .undetermined:
                return .needsPermission(appText(
                    "sources.deviceConnected.status.undetermined",
                    """
                    Waiting for Bluetooth access. macOS asks once, when Isleta starts — if you \
                    closed that dialog without answering, quit Isleta and open it again.
                    """
                ))
            case .denied(let explanation):
                return .needsPermission(explanation)
            }

        case .glance:
            // Two facts, and the second is the one worth saying — the same shape as the HUD row and
            // the Bluetooth one. The calendar half is a permission the user can grant; the weather
            // half needs a signing change nobody using Isleta can make, so it is `unavailable`
            // rather than `needsPermission`. Saying only "granted" would leave somebody who turned
            // this on for the weather looking at a calendar and wondering what broke.
            switch entry.source.authorization {
            case .granted, .notRequired:
                guard weather.isAvailable else {
                    return .working(appText(
                        "sources.glance.status.grantedNoWeather",
                        "Granted. The island shows your day. Weather is not in this build yet."
                    ))
                }
                return .working(appText("sources.glance.status.granted",
                                        "Granted. Isleta shows your day and the weather."))
            case .undetermined:
                return .needsPermission(appText("sources.status.notGrantedYet", "Not granted yet."))
            case .denied(let explanation):
                return .needsPermission(explanation)
            }

        case .power:
            // A Mac with no battery is `unavailable`, never `needsPermission`: nothing is being
            // refused, there is simply nothing to say. Low Power Mode still exists on a Studio, and
            // is deliberately not offered as half a feature.
            guard power.hasBattery else {
                return .unavailable(appText("sources.power.status.noBattery",
                                            "This Mac has no battery, so there is nothing to show here."))
            }
            return .working(appText("sources.power.status.working",
                                    "Working. The charger and the battery need no permission."))

        case .call:
            // The honest sentence, and it is the Volume-and-mute shape: say what is shown and say
            // plainly what macOS does not allow, rather than shipping a switch for something that
            // will never appear.
            return .working(appText(
                "sources.call.status.working",
                """
                Working. Isleta shows that a call is in progress, and how long it has been going. \
                macOS does not let apps outside Apple see who is calling, or answer for you.
                """
            ))

        // The 2.0 vocabulary. Each takes a real status when its source lands; until then the same
        // answer the three permission-free kinds already give. Grouped separately rather than
        // folded in, so adding a source is a visible edit rather than a silent omission.
        case .calendarAlert, .meeting, .fileAction,
             .focusChanged, .screenSharing:
            fallthrough
        case .welcomeBack, .timer, .shelf:
            return Self.status(from: entry.source.authorization,
                               working: appText("sources.status.workingNoPermission",
                                                "Working. Needs no permission."))
        }
    }

    private static func status(
        from authorization: SourceAuthorization,
        working: String
    ) -> SourceSettingsRow.Status {
        switch authorization {
        case .granted, .notRequired: .working(working)
        case .undetermined: .needsPermission(appText(
            "sources.status.notGrantedYet", "Not granted yet."
        ))
        case .denied(let explanation): .needsPermission(explanation)
        }
    }

    /// The offer, and only where there is one.
    ///
    /// `.undetermined` is the single case that gets a button, because it is the single case where a
    /// prompt would show. `.denied` gets the deep link instead: the system will not raise the dialog
    /// a second time, so a "Grant Access" button there would be a control that visibly does nothing.
    private func action(for entry: Entry) -> SourceSettingsRow.Action? {
        // Bluetooth has no button in the `.undetermined` case, and that is not an omission. Its
        // prompt is raised by CoreBluetooth the first time the source registers, which is at
        // launch; there is no call that asks a second time, so a "Grant Access" button here would
        // be the control that visibly does nothing the comment below warns about.
        if entry.kind == .deviceConnected {
            guard case .denied = entry.source.authorization else { return nil }
            return SourceSettingsRow.Action(title: appText("sources.action.openSystemSettings", "Open System Settings…")) {
                guard let url = URL(string: BluetoothPrivacySettings.settingsURLString) else { return }
                NSWorkspace.shared.open(url)
            }
        }
        // The glance's own offer, on the same rule as everything else here: a prompt only where one
        // would show, and the deep link where the system will not ask again.
        if entry.kind == .glance {
            switch entry.source.authorization {
            case .undetermined:
                return SourceSettingsRow.Action(title: appText("sources.action.allowCalendar", "Allow Calendar Access…")) { [weak self] in
                    self?.calendar.requestAccessFromUserInitiatedMoment()
                }
            case .denied:
                return SourceSettingsRow.Action(title: appText("sources.action.openSystemSettings", "Open System Settings…")) {
                    guard let url = URL(string: GlancePrivacySettings.calendarsURLString) else { return }
                    NSWorkspace.shared.open(url)
                }
            case .granted, .notRequired:
                return nil
            }
        }
        return nil
    }

    /// A line of extra detail for diagnostics, where the source has one worth reporting.
    private func detail(for kind: ActivityKind) -> String? {
        switch kind {
        case .nowPlaying:
            // Both halves, because "music shows but the buttons do nothing" and "no music at all"
            // are different reports with different causes, and a user cannot tell us which they are
            // seeing. The transport retires itself when a command fails to launch, so this is read
            // live rather than being a property of the build.
            return "provider \(nowPlaying.provider.providerName), "
                + "transport \(nowPlaying.transport.isAvailable ? "available" : "unavailable"), "
                + "artwork \(nowPlaying.artwork?.isAvailable == true ? "available" : "unavailable")"
        case .systemHUD:
            let supported = systemHUD.supportedHUDs.map(\.rawValue).sorted().joined(separator: ", ")
            // Both halves, for the reason the Now Playing line has two: "the keyboard HUD never
            // appears" is a different report depending on whether this Mac has a backlight or the
            // user has the switch off, and they cannot tell us which.
            let enabled = systemHUD.enabledHUDs.map(\.rawValue).sorted().joined(separator: ", ")
            return "HUDs \(supported.isEmpty ? "none" : supported), "
                + "enabled \(enabled.isEmpty ? "none" : enabled)"
        case .timer:
            // Counts, never contents: the timer's *name* is the user's own words, and this line
            // goes into the export bundle that gets emailed to strangers.
            return "live \(timers.liveCount)"
        case .glance:
            // Counts and enum values only. An event's title, its notes, its location, its attendees
            // and its join URL are all the user's own content, and this line is in the file a person
            // is asked to attach to a bug report. What a report about this feature actually needs is
            // whether the calendar answered and whether weather is possible at all.
            // The Focus gate's two numbers ride this row, and that is deliberate: `.focusChanged`
            // has no source and therefore no `entries` slot, so a line written there would never be
            // printed at all. They belong here anyway — a calendar alert is the one thing a Focus
            // now withholds, and reading the authorization is also the one place a diagnostics run
            // touches `INFocusStatusCenter`, which is what makes a real `open -a` launch able to see
            // a TCC problem with it.
            return "events \(calendar.eventCount), announced \(calendar.announcementCount), "
                + "weather \(weather.isAvailable ? weather.providerName : "unavailable"), "
                + "focus \(focus.authorization), withheld \(focus.suppressedCount)"
        case .deviceConnected:
            // Whether the charge is reachable, never which device or whose. The device's name is
            // the user's own words and the address identifies their hardware; neither belongs in a
            // file that gets emailed to strangers. This flag is the one thing a bug report needs —
            // "the ring never appears" and "nothing appears at all" are different reports.
            return "battery \(bluetooth.reportsBattery ? "readable" : "unreadable")"
        case .welcomeBack, .shelf:
            return nil
        case .power:
            // Whether there is a battery at all, and how many moments have been shown. Never the
            // charge: it is a fact about the user's hardware at a moment in time, and this line is
            // in the file people are asked to attach to a bug report.
            return "battery \(power.hasBattery ? "present" : "absent"), announced \(power.announcementCount)"
        case .call:
            return "calls shown \(calls.publishedCount)"
        // The 2.0 vocabulary. Each of these gains a real line when its source lands; until then a
        // nil is the honest answer, and it is written out as a group rather than folded into the
        // line above so that adding a source is a visible edit here rather than a silent omission.
        case .calendarAlert, .meeting, .fileAction, .screenSharing, .focusChanged:
            return nil
        }
    }

    private static func title(for kind: ActivityKind) -> String {
        switch kind {
        case .nowPlaying: appText("sources.nowPlaying.title", "Now Playing")
        case .systemHUD: appText("sources.systemHUD.title", "Volume, mute and brightness")
        case .welcomeBack: appText("sources.welcomeBack.title", "Welcome Back")
        case .timer: appText("sources.timer.title", "Timers")
        case .deviceConnected: appText("sources.deviceConnected.title", "Bluetooth devices")
        case .shelf: appText("sources.shelf.title", "Shelf")
        case .glance: appText("sources.glance.title", "Calendar and weather")
        case .calendarAlert: appText("sources.calendarAlert.title", "Event alerts")
        case .meeting: appText("sources.meeting.title", "Meetings")
        case .power: appText("sources.power.title", "Battery and power")
        case .call: appText("sources.call.title", "Calls")
        case .fileAction: appText("sources.fileAction.title", "Drop actions")
        case .focusChanged: appText("sources.focusChanged.title", "Focus changes")
        case .screenSharing: appText("sources.screenSharing.title", "Screen sharing")
        }
    }

    private static func summary(for kind: ActivityKind) -> String {
        switch kind {
        case .nowPlaying:
            appText(
                "sources.nowPlaying.summary",
                "Shows the track playing in Music, Spotify, or the system player."
            )
        case .systemHUD:
            appText(
                "sources.systemHUD.summary",
                """
                Shows volume, mute, display brightness and keyboard backlight changes in the island, \
                alongside the system’s own HUD.
                """
            )
        case .welcomeBack:
            appText(
                "sources.welcomeBack.summary",
                "Greets you when you come back to your Mac after a while away."
            )
        case .timer:
            appText(
                "sources.timer.summary",
                """
                Shows timers from Apple’s Clock counting down in the island. Reads only the state \
                Clock already stores on this Mac, and needs no permission.
                """
            )
        case .deviceConnected:
            appText(
                "sources.deviceConnected.summary",
                """
                Shows AirPods and other Bluetooth audio devices connecting, with their battery. Needs \
                Bluetooth access to see them arrive — the device’s name and charge never leave your Mac.
                """
            )
        case .shelf:
            appText(
                "sources.shelf.summary",
                "Holds files you drag onto the island."
            )
        case .glance:
            appText(
                "sources.glance.summary",
                """
                Shows your day — what’s next in your calendar, and the weather. Needs Calendar access, \
                and Location if you want the weather to follow you.
                """
            )
        case .calendarAlert:
            appText(
                "sources.calendarAlert.summary",
                "Tells you when an event is about to start."
            )
        case .meeting:
            appText(
                "sources.meeting.summary",
                "Gives you a button to join a Zoom, Meet, Teams or FaceTime call when a meeting starts."
            )
        case .power:
            appText(
                "sources.power.summary",
                "Shows the charger going in and coming out, a battery getting low, and Low Power Mode."
            )
        case .call:
            // The honest sentence. macOS gates every "who is calling" API behind an entitlement only
            // FaceTime holds, so a switch promising a caller's name would be a switch for something
            // that never appears.
            appText(
                "sources.call.summary",
                """
                Shows that a call is in progress, and how long it has been going. macOS does not let \
                apps outside Apple see who is calling.
                """
            )
        case .fileAction:
            appText(
                "sources.fileAction.summary",
                """
                Converts, compresses and transcribes files you drop on the island. The work happens on \
                this Mac; nothing is uploaded.
                """
            )
        case .focusChanged:
            appText(
                "sources.focusChanged.summary",
                "Says when a Focus turns on or off — which is also why the island goes quiet."
            )
        case .screenSharing:
            appText(
                "sources.screenSharing.summary",
                "Reminds you while your screen is being recorded or shared."
            )
        }
    }
}

/// One source's state, for `--perf-report` and the diagnostics report.
///
/// Counts and flags only. `detail` is built from the sources' own diagnostics values and
/// supported-feature sets; none of the user's own words can reach it, because none of those types
/// carry any.
struct SourceStatus: Sendable {
    let kind: ActivityKind
    let name: String
    let isEnabled: Bool
    let authorization: SourceAuthorization
    let detail: String?

    /// `SourceAuthorization` printed with its explanation, because "denied" without the reason is
    /// the diagnostic that generates the follow-up question.
    var authorizationDescription: String {
        switch authorization {
        case .notRequired: "not required"
        case .granted: "granted"
        case .undetermined: "undetermined (never asked)"
        case .denied(let explanation): "denied — \(explanation)"
        }
    }
}
