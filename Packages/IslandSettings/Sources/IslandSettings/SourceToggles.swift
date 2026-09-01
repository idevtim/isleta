import IslandActivities

/// Which of Isleta's sources the user wants running (§8.1.4).
///
/// Keyed by `ActivityKind` rather than by a string or by a parallel enum of this module's own.
/// `ActivityKind` is closed *for this reason* — its own documentation says so — and the alternative
/// is the mistake PROGRESS records against duplicating `IslandPresentation`: two spellings of the
/// same vocabulary that agree until somebody adds a case to one of them. The `switch` in
/// `subscript(_:)` is exhaustive, so a new kind is a compile error here rather than a toggle that
/// silently does nothing.
///
/// The stored representation is still four named `Bool`s rather than a `Set<ActivityKind>` or a
/// dictionary, because this is a persisted record: a named key survives a kind being renamed, reads
/// as a diff a human can check, and can fall back per key when the stored blob is partial. A
/// `Set` would additionally have to answer "does absence mean off, or mean written by an older
/// build" — and those are opposite answers.
///
/// **Everything defaults to on.** A source the user has not heard of that is off by default is a
/// feature they never discover; a source that is on and unpermitted is a source that quietly does
/// nothing and says so in Settings, which is what §10 asks for.
///
/// There were two exceptions once. `appSwitcher` went with the switcher itself, and `focusChanges`
/// is now `respectsFocus` — a *behavior* rather than a source, defaulting to on. Its declaration
/// carries the whole story, and the short version is that a switch which can never move is not a
/// switch.
public struct SourceToggles: Equatable, Sendable {

    /// §2.4. Now Playing.
    public var nowPlaying: Bool

    /// §2.6 / §8.1.5. The HUD source as a whole — volume, mute and both brightnesses.
    ///
    /// **A master switch over the three flags below rather than a fourth peer.** One source reads
    /// four levels, so turning the source off has to be one act rather than three, and the three
    /// exist because a user who wants the island to answer their volume keys does not necessarily
    /// want it to answer the ambient-light sensor moving the keyboard backlight. Off here stops the
    /// source outright and the three below are then moot; on here defers to them.
    public var systemHUDs: Bool

    /// Volume and mute, together.
    ///
    /// **One flag for two `SystemHUD` cases, and that is not a shortcut.** Mute is not a separate
    /// thing the user changed — it is what the volume did — and `SystemHUDLevelState.apply` decides
    /// between the two from a single CoreAudio snapshot, so a switch that left mute on while volume
    /// was off would show a crossed-out speaker for a keypress whose bar had been suppressed.
    public var volumeHUD: Bool

    /// Display brightness.
    ///
    /// **There is no keyboard-backlight switch beside it any more**, and the reason it went is the
    /// reason it needed a switch: macOS raises and lowers the backlight from the ambient-light
    /// sensor, so the island lit up as somebody carried the Mac into a darker room, over a change
    /// they had not made. A HUD reports what you just did. A switch for "stop telling me about
    /// something I did not do" is a setting apologizing for a feature — see `SystemHUD`.
    public var displayBrightnessHUD: Bool

    /// §2.5. The wake/unlock greeting.
    public var welcomeBack: Bool

    /// §2.7. Timers from Apple's Clock.
    public var timers: Bool

    /// A Bluetooth audio device connecting. No permission and no prompt — see
    /// `BluetoothDeviceSource` — so this switch is about whether the user wants the moment shown,
    /// not about what Isleta is allowed to see.
    public var bluetoothDevices: Bool

    // MARK: - 2.0

    /// Calendar and weather in the island.
    public var glance: Bool

    /// An event about to start.
    public var calendarAlerts: Bool

    /// A joinable Zoom / Meet / Teams / FaceTime link on an event that is starting.
    public var meetings: Bool

    /// Charger, low battery, Low Power Mode.
    public var power: Bool

    /// Incoming and in-progress calls.
    public var calls: Bool

    /// What Isleta does to a file dropped on it — convert, compress, transcribe, make a link.
    public var dropActions: Bool

    /// Whether a Focus quiets the island.
    ///
    /// **This slot shipped as `focusChanges` and was a switch that could never move.** It meant
    /// "announce a Focus turning on or off", which macOS cannot tell us about: there is no change
    /// notification for Focus anywhere — `INFocusStatusCenter.h` declares two properties and one
    /// method and no constant, and `DoNotDisturb`, `DoNotDisturbKit` and `Focus.framework` carry no
    /// Darwin names for state (see `IntentsFocusStatus`). So `ActivityKind.focusChanged` has no
    /// publisher and cannot get one without a poll, which §9 forbids. CLAUDE.md already records what
    /// to do with a switch in that position, from `suppressSystemHUDs`: **a switch that can never
    /// move is not made honest by graying it.**
    ///
    /// It was not deleted, because the slot turned out to hold a live question that had simply never
    /// been asked. Isleta *does* let a Focus silence calendar alerts — `FocusGate`
    /// has done that since Stage 2 — and until now the user had no say in it. So the flag keeps its
    /// place in the record and changes its meaning, and `FocusGate.isEnabled` is where it lands.
    ///
    /// **On by default**, because that is exactly what every build before it did.
    ///
    /// This is a *behavior*, not a source, which is why `subscript(kind:)` and `keyPath(for:)`
    /// below answer `.focusChanged` the way they answer `.shelf` — true, and no key path. A row with
    /// a switch bound to this flag would say it turns a source on, and it does not.
    public var respectsFocus: Bool

    /// A persistent reminder that the screen is being recorded or shared.
    public var screenSharing: Bool

    public init(
        nowPlaying: Bool = true,
        systemHUDs: Bool = true,
        volumeHUD: Bool = true,
        displayBrightnessHUD: Bool = true,
        welcomeBack: Bool = true,
        timers: Bool = true,
        bluetoothDevices: Bool = true,
        glance: Bool = true,
        calendarAlerts: Bool = true,
        meetings: Bool = true,
        power: Bool = true,
        calls: Bool = true,
        dropActions: Bool = true,
        respectsFocus: Bool = true,
        screenSharing: Bool = true
    ) {
        self.nowPlaying = nowPlaying
        self.systemHUDs = systemHUDs
        self.volumeHUD = volumeHUD
        self.displayBrightnessHUD = displayBrightnessHUD
        self.welcomeBack = welcomeBack
        self.timers = timers
        self.bluetoothDevices = bluetoothDevices
        self.glance = glance
        self.calendarAlerts = calendarAlerts
        self.meetings = meetings
        self.power = power
        self.calls = calls
        self.dropActions = dropActions
        self.respectsFocus = respectsFocus
        self.screenSharing = screenSharing
    }

    /// Whether the source that publishes `kind` may run.
    ///
    /// `.shelf` and `.focusChanged` are always true and have no stored flag. `.shelf` is the one
    /// kind with no source in IslandSources — Milestone 3 publishes it from a drag session in the app shell — so a toggle
    /// for it would be a switch with nothing on the other end. Returning true rather than adding a
    /// fifth flag keeps the record describing sources that exist; when the shelf lands and wants to
    /// be switchable, it gets a flag here and this line becomes a real read.
    public subscript(kind: ActivityKind) -> Bool {
        get {
            switch kind {
            case .nowPlaying: nowPlaying
            case .systemHUD: systemHUDs
            case .welcomeBack: welcomeBack
            case .timer: timers
            case .deviceConnected: bluetoothDevices
            case .glance: glance
            case .calendarAlert: calendarAlerts
            case .meeting: meetings
            case .power: power
            case .call: calls
            case .fileAction: dropActions
            case .focusChanged: true
            case .screenSharing: screenSharing
            case .shelf: true
            }
        }
        set {
            switch kind {
            case .nowPlaying: nowPlaying = newValue
            case .systemHUD: systemHUDs = newValue
            case .welcomeBack: welcomeBack = newValue
            case .timer: timers = newValue
            case .deviceConnected: bluetoothDevices = newValue
            case .glance: glance = newValue
            case .calendarAlert: calendarAlerts = newValue
            case .meeting: meetings = newValue
            case .power: power = newValue
            case .call: calls = newValue
            case .fileAction: dropActions = newValue
            case .focusChanged: break
            case .screenSharing: screenSharing = newValue
            case .shelf: break
            }
        }
    }

    /// The key path Settings binds a row's toggle to, for a kind.
    ///
    /// A key path rather than the subscript because `SettingsView` writes through
    /// `SettingsStore.update`, which hands out an `inout IsletaConfiguration` — and a `Binding`
    /// built from a subscript on a nested value would need a setter that reassembles the whole
    /// record at each call site. The key paths are checked by the compiler in exactly the way a
    /// string key would not be.
    public static func keyPath(for kind: ActivityKind) -> WritableKeyPath<IsletaConfiguration, Bool>? {
        switch kind {
        case .nowPlaying: \IsletaConfiguration.sources.nowPlaying
        case .systemHUD: \IsletaConfiguration.sources.systemHUDs
        case .welcomeBack: \IsletaConfiguration.sources.welcomeBack
        case .timer: \IsletaConfiguration.sources.timers
        case .deviceConnected: \IsletaConfiguration.sources.bluetoothDevices
        case .glance: \IsletaConfiguration.sources.glance
        case .calendarAlert: \IsletaConfiguration.sources.calendarAlerts
        case .meeting: \IsletaConfiguration.sources.meetings
        case .power: \IsletaConfiguration.sources.power
        case .call: \IsletaConfiguration.sources.calls
        case .fileAction: \IsletaConfiguration.sources.dropActions
        case .focusChanged: nil
        case .screenSharing: \IsletaConfiguration.sources.screenSharing
        case .shelf: nil
        }
    }

    // MARK: - Inside the HUD source

    /// Which of the four levels the HUD source may report.
    ///
    /// The one place `SystemHUD` is mapped onto stored flags, for `keyPath(for kind:)`'s reason a
    /// few lines up: the alternative is the app shell asking three questions in the right order,
    /// and the day a fifth level lands one caller gets it and the other does not.
    ///
    /// **Says nothing about `systemHUDs`.** This is what the source may report *if it is running*,
    /// and whether it runs is the master switch, read by the hub through `subscript(_:)` like every
    /// other source. Folding the master in here would give the hub two answers to "is this on" and
    /// leave a source stopped by a flag that is not its row's switch.
    public var enabledHUDs: Set<SystemHUD> {
        Set(SystemHUD.allCases.filter { self[keyPath: Self.storage(for: $0)] })
    }

    /// The stored flag a level rides, for a settings switch to bind to.
    ///
    /// `.volume` and `.mute` deliberately answer the same key path — see `volumeHUD`.
    public static func keyPath(for hud: SystemHUD) -> WritableKeyPath<IsletaConfiguration, Bool> {
        switch hud {
        case .volume, .mute: \IsletaConfiguration.sources.volumeHUD
        case .brightness: \IsletaConfiguration.sources.displayBrightnessHUD
        }
    }

    /// The same mapping, rooted on this record rather than on the whole configuration, so
    /// `enabledHUDs` can read it without one.
    private static func storage(for hud: SystemHUD) -> WritableKeyPath<SourceToggles, Bool> {
        switch hud {
        case .volume, .mute: \SourceToggles.volumeHUD
        case .brightness: \SourceToggles.displayBrightnessHUD
        }
    }
}

// MARK: - Coding

extension SourceToggles: Codable {

    enum CodingKeys: String, CodingKey {
        case nowPlaying
        case systemHUDs
        case volumeHUD
        case displayBrightnessHUD
        case welcomeBack
        case timers
        case bluetoothDevices
        case glance
        case calendarAlerts
        case meetings
        case power
        case calls
        case dropActions
        case respectsFocus
        case screenSharing
    }

    /// Per-key fallback, for the same reason `IsletaConfiguration`'s decoder has it: a record
    /// written by a build that did not have one of these flags must not cost the user the three it
    /// did have. Written out rather than synthesised because the synthesised decoder is
    /// all-or-nothing, and here "all" includes a whole nested value — a single unreadable flag
    /// would turn every source back on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SourceToggles()

        func value(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key))?.flatMap { $0 } ?? fallback
        }

        nowPlaying = value(.nowPlaying, defaults.nowPlaying)
        systemHUDs = value(.systemHUDs, defaults.systemHUDs)
        volumeHUD = value(.volumeHUD, defaults.volumeHUD)
        displayBrightnessHUD = value(.displayBrightnessHUD, defaults.displayBrightnessHUD)
        welcomeBack = value(.welcomeBack, defaults.welcomeBack)
        timers = value(.timers, defaults.timers)
        bluetoothDevices = value(.bluetoothDevices, defaults.bluetoothDevices)
        glance = value(.glance, defaults.glance)
        calendarAlerts = value(.calendarAlerts, defaults.calendarAlerts)
        meetings = value(.meetings, defaults.meetings)
        power = value(.power, defaults.power)
        calls = value(.calls, defaults.calls)
        dropActions = value(.dropActions, defaults.dropActions)
        respectsFocus = value(.respectsFocus, defaults.respectsFocus)
        screenSharing = value(.screenSharing, defaults.screenSharing)
    }
}
