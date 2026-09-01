import Foundation
import IslandActivities
import IslandKit

/// Everything the user has asked Isleta to do, and nothing about how any of it is done.
///
/// A value type on purpose. The store hands out whole copies, so a reader can never observe half
/// an edit, and `Equatable` is what lets the store skip writing and skip notifying when a "change"
/// changed nothing — which is the difference between a settings toggle and a feedback loop between
/// the UI and the handlers it fires.
///
/// What is *not* here is as deliberate as what is:
///
/// - **Launch at login.** The system owns that fact (`SMAppService`), and the user can change it in
///   System Settings without Isleta running. A copy stored here would go stale the first time they
///   did, and then Isleta would either silently disagree with System Settings or "helpfully"
///   re-register something the user had just turned off. `LaunchAtLogin` reads it live instead.
/// - **Reduce motion / transparency / contrast.** Also the system's, via `AccessibilityPreferences`.
///   §6.3 makes them a correctness requirement, which means they are not ours to override.
/// - **Celsius or Fahrenheit.** System Settings ▸ General ▸ Language & Region ▸ Temperature, read
///   through `TemperatureUnit.fromLocale()`. It was a picker in the Glance pane through 2.0, which
///   is a second place to answer a question macOS already asks once for the whole machine.
/// - **Everything schema 18 took out**, which is most of what used to be here: the hover delay, the
///   peek amount, the dwell multiplier, the welcome-back threshold, the synthesized-island opacity,
///   the animation speed, the island's width, height, shadow, style and compact mode, which side of
///   the notch each kind takes, whether notification bursts group, and
///   whether haptics are permitted. Each of those had one right answer, and shipping the slider
///   instead of the answer is what makes an app read as a third-party imitation of a system
///   feature rather than as the feature. The values they are pinned at are in
///   `IslandLayout`, `IslandSizing.standard`, `Motion`, `ActivityKind.flankAffinity` and
///   `WelcomeBackPolicy`.
public struct IsletaConfiguration: Equatable, Sendable {

    /// The schema this value was written with. See `SettingsMigration`.
    public var schemaVersion: Int

    /// Every global keyboard shortcut the user has assigned. See `Shortcuts`.
    ///
    /// One record rather than a property per action, because the thing that has to be readable in
    /// one place is not the individual bindings but **what Isleta has taken from the rest of the
    /// machine**: `RegisterEventHotKey` is exclusive, so each of these is a key no other app can
    /// use while Isleta runs. `Shortcuts.active` is that list.
    public var shortcuts: Shortcuts

    /// The global shortcut that opens and closes the island (§5).
    ///
    /// **Computed, and it forwards to `shortcuts[.toggleIsland]`.** It kept its name and its type
    /// through the 2.0 shortcut vocabulary because it is read from the settings pane, the
    /// onboarding copy and the app shell, and because the alternative — two records that each hold
    /// a shortcut — is the mistake this file already refuses for `SourceToggles`: two spellings of
    /// one vocabulary that agree until somebody writes to one of them.
    ///
    /// Non-optional, where `Shortcuts`' subscript is optional, and that difference is the one piece
    /// of policy here: **the island toggle is the one action that cannot be cleared, only rebound.**
    /// Isleta has no Dock icon and its menu bar item can be hidden, so a user who has hidden the
    /// icon and cleared this shortcut has locked themselves out of the app with no way back that
    /// does not involve `defaults delete`. Every other action is reachable by opening the island
    /// and clicking, so every other action may be cleared.
    public var toggleHotKey: HotKeyBinding {
        get { shortcuts[.toggleIsland] ?? .toggleIsland }
        set { shortcuts[.toggleIsland] = newValue }
    }

    /// Which calendars the glance includes, and where to ask about the weather. See `GlanceSettings`.
    public var glance: GlanceSettings

    /// Which sources are allowed to run (§8.1.4). See `SourceToggles`.
    ///
    /// A nested value rather than a dozen `Bool`s flattened into this struct, because the app shell
    /// applies them as a set: one `SourceToggles` compared against the previous one tells it exactly
    /// which sources to start and stop, and loose flags would mean a comparison per source that has
    /// to be kept in step with the list of them.
    public var sources: SourceToggles

    /// Whether Isleta checks for updates on its own. See `SoftwareUpdater`.
    public var automaticUpdateChecks: Bool

    /// Whether the status item is in the menu bar.
    ///
    /// **The switch is only honest because something else can reach Settings.** Isleta has no Dock
    /// icon and installs no menu bar of its own, so ⌘, is dispatched by whichever app is frontmost
    /// (see CLAUDE.md on key equivalents in a status menu) — which makes the status item the only
    /// route to this window, to the Setup Guide, and to Quit. Hiding it without a second route
    /// strands the user in an app they cannot configure or close.
    ///
    /// The second route is `toggleHotKey`: it works from any app including full screen, opens the
    /// island, and the island carries a Settings affordance. That is why this field may not ship
    /// ahead of that affordance, and why the General pane names the shortcut *beside* the switch
    /// rather than in a help article nobody opens.
    ///
    /// Defaults to `true`, and an absent key must decode to `true` — the difference between an
    /// upgrade that keeps the icon where the user left it and one that silently removes it.
    public var showMenuBarIcon: Bool

    /// Whether the track that is playing appears on the macOS lock screen, with the lock and unlock
    /// sounds that go with it.
    ///
    /// Defaults to `false`, which is the opposite of most switches here and is deliberate. The
    /// surface reaches it through a private, undocumented SkyLight space level
    /// (`SkyLightLockScreenSpace`, and `docs/PLATFORM-CONSTRAINTS.md` for the fourteen runs behind
    /// it). Two things follow. It can stop working on any macOS release, and a feature that appears
    /// by default and then silently stops is worse than one the user switched on knowing what it
    /// was. And it puts what somebody is listening to on a screen that is, by definition, showing
    /// to a room the owner has walked away from — which is a choice to make rather than to assume,
    /// even though iOS makes the same one the other way.
    ///
    /// **One switch, where schema 17 had two.** The sounds were `playsLockScreenSounds`, on the
    /// argument that "show me what is playing" and "make a noise" are different questions. They are,
    /// and they are not different *decisions*: both are answered by whether the user wants Isleta on
    /// their lock screen at all, and a second switch under the first bought a combination — the
    /// sound without the card — that reads as a setting nobody set. Folding it costs the user who
    /// wanted exactly that combination and nobody else; the two ordinary answers are unchanged, and
    /// silence is still what an install that has never opened this pane does.
    ///
    /// There is no companion switch for controls, because there can never be controls: loginwindow
    /// captures every event on the locked screen. See `LockScreenPanel`.
    public var showsNowPlayingOnLockScreen: Bool

    /// Applications whose frontmost moment the island stays out of — full-screen video, a
    /// presentation, anything the user would rather not be spoken over.
    ///
    /// An array rather than a `Set` so the order the user added them in survives a round trip
    /// through JSON, which is what stops the list in Settings reshuffling itself on every launch.
    ///
    /// **Lifted out of the old `appearance` record by schema 18**, which is where it lived while
    /// there was an Appearance pane to put it in. It is not an appearance setting and never was —
    /// it is a rule about when Isleta speaks, which is what the Sources pane is — and the record it
    /// was in had nothing else left after 18 took the styling out.
    public var hiddenApplications: [String]

    /// Whether a **synthesized** island — one on a Mac or a display with no notch at all — is
    /// invisible when it has nothing to say.
    ///
    /// See `IslandScreenModel.minimalWhenSynthesized` for what it costs and for why the island
    /// stays reachable with nothing drawn. Lifted out of `appearance` by schema 18, with
    /// `hiddenApplications`, and for the same reason.
    public var minimalOnSynthesizedDisplays: Bool

    /// Whether Isleta replaces Apple's volume HUD instead of appearing beside it.
    ///
    /// **Removed in schema 4 and back in schema 23**, which is the whole story of this flag. It was
    /// withdrawn because it was a switch that could never move: `SystemHUDSuppression` suppressed
    /// nothing, and `PLATFORM-CONSTRAINTS.md` says in as many words *"do not reintroduce the setting
    /// without a mechanism"*. There is now a mechanism — `MediaKeyMonitor` in `.replace` swallows
    /// the volume keys and `SystemVolumeControl` does what they would have done — measured on
    /// 2026-08-30, so this is that condition being met rather than being forgotten.
    ///
    /// **False by default**, which is CLAUDE.md's first condition for suppression and not a
    /// nicety: turning it on means Isleta becomes the implementation of the volume keys, and an app
    /// that does that to somebody who never asked has taken their volume keys away.
    ///
    /// Volume and mute only. Brightness keeps Apple's HUD — see `SystemHUDSuppression.suppressible`.
    public var suppressSystemHUDs: Bool

    /// Whether Isleta replaces Apple's brightness HUD instead of appearing beside it.
    ///
    /// **A second flag rather than a widening of `suppressSystemHUDs`**, because the two levels carry
    /// different risk and a user may reasonably want one without the other. Volume is recoverable if
    /// Isleta gets it wrong — the slider is in Control Center. Brightness is the one
    /// `SystemHUDSuppression` spent a year calling "not a gray area; it is a broken laptop", and
    /// while the API claim behind that was false, a screen somebody cannot dim is still the worse
    /// failure. Folding them into one switch would make accepting the cheaper risk mean accepting
    /// the dearer one.
    ///
    /// False by default, for `suppressSystemHUDs`'s reason and more so.
    public var suppressBrightnessHUD: Bool

    public init(
        schemaVersion: Int = IsletaConfiguration.currentSchemaVersion,
        suppressSystemHUDs: Bool = false,
        suppressBrightnessHUD: Bool = false,
        toggleHotKey: HotKeyBinding = .toggleIsland,
        shortcuts: Shortcuts = Shortcuts(),
        sources: SourceToggles = SourceToggles(),
        automaticUpdateChecks: Bool = true,
        showMenuBarIcon: Bool = true,
        glance: GlanceSettings = .defaults,
        showsNowPlayingOnLockScreen: Bool = false,
        hiddenApplications: [String] = [],
        minimalOnSynthesizedDisplays: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.suppressSystemHUDs = suppressSystemHUDs
        self.suppressBrightnessHUD = suppressBrightnessHUD
        // The stored record first, then the forwarding property over the top of it. A caller that
        // passed both gets the explicit `toggleHotKey` — which is what the parameter order reads as
        // and what every existing call site means.
        self.shortcuts = shortcuts
        self.shortcuts[.toggleIsland] = toggleHotKey
        self.sources = sources
        self.automaticUpdateChecks = automaticUpdateChecks
        self.showMenuBarIcon = showMenuBarIcon
        self.glance = glance
        self.showsNowPlayingOnLockScreen = showsNowPlayingOnLockScreen
        self.hiddenApplications = hiddenApplications
        self.minimalOnSynthesizedDisplays = minimalOnSynthesizedDisplays
    }

    /// The schema version this build writes.
    ///
    /// Version 2 added the four continuous settings. Nothing needed converting — leniency covers
    /// keys that are merely absent — but the version still moves, because `SettingsMigration` is
    /// where an out-of-range value written by a build with different bounds gets caught.
    ///
    /// Version 3 made the Welcome Back threshold a setting, for the same reason and with the same
    /// step: additive to the decoder, but `defaults write` can put a string where a number belongs.
    ///
    /// Version 4 is the first step that *removes* settings — `suppressSystemHUDs` and
    /// `delightEnabled`. Leniency already ignores a key this build has no field for, so nothing
    /// would break without the step; it exists so the stored blob stops carrying two answers that
    /// nothing will ever read again. A record whose keys outlive their meaning is how a later
    /// migration ends up guessing which of two spellings was the live one.
    ///
    /// Version 5 added `showMenuBarIcon`. Additive, and the default is what every build before it
    /// did, so a v4 file keeps its status item — which is the one outcome that must not be got
    /// wrong, because the failure is a user whose only route into the app disappears on upgrade.
    /// Version 10 brings Stage 7's appearance record home, and is a type sweep rather than a move:
    /// unlike `glance` this one was never parked on a key of its own, because Stage 7 was built
    /// alone.
    /// Version 15 adds `sides` — which side of the notch each kind takes, and whether the two
    /// slivers read the other way round. Additive, and every default reproduces what Isleta drew
    /// before it was adjustable, so an upgrade changes nothing on screen.
    /// Version 16 adds `showsNowPlayingOnLockScreen`. Additive, and it defaults to **off** — so an
    /// upgrade changes nothing, which for this one field is the whole point: it turns on a surface
    /// drawn through a private SkyLight space level, and nobody should find that switched on for
    /// them by an update.
    /// Version 17 adds `playsLockScreenSounds`. Additive, defaults **off** — no build before 17
    /// made a noise at a lock, so off is also what the user had.
    ///
    /// **Version 18 is the large one, and it only removes.** Eighteen settings went, the Island and
    /// Appearance panes with them, and every one of them is pinned at what its own slider called
    /// neutral — so an install that never opened those panes sees no change at all, and one that
    /// did is put back on the shipped geometry. `playsLockScreenSounds` is the one field that is
    /// *folded* rather than dropped: it survives as part of `showsNowPlayingOnLockScreen`, and a
    /// user who had the sounds without the card loses the sounds. `appearance.hiddenApplications`
    /// and `appearance.minimalOnSynthesizedDisplays` are the two fields lifted out of a record that
    /// had nothing else left; the lift is why this step is hand-written rather than left to
    /// leniency, which would silently have reset both.
    ///
    /// **Version 21 removes `playerBar`.** The bar is withdrawn — the surface, its window, its
    /// settings card and the record that configured it — so the field goes rather than being left
    /// as a key nothing reads. Every default in it was "off", so nobody loses a bar they had; a
    /// user who had switched one on loses it, which is what withdrawing a feature means.
    ///
    /// **Version 22 removes `sources.transfers`.** Downloads are withdrawn — the folder watcher,
    /// the source, `ActivityKind.transfer` and the settings row — so the switch goes with the kind
    /// it gated rather than being left as a key nothing reads.
    public static let currentSchemaVersion = 24

    /// What a machine that has never opened Settings runs with.
    public static let defaults = IsletaConfiguration()

    /// The names of the fields that differ between two configurations, for the log.
    ///
    /// Names and not values, on purpose: the log records *that* the hot key changed and when, and
    /// the value is the user's own. `schemaVersion` is excluded — `update` restamps it on every edit,
    /// so it would read as changed on a change to anything else.
    public static func changedKeys(from old: IsletaConfiguration, to new: IsletaConfiguration) -> [String] {
        var keys: [String] = []
        if old.shortcuts != new.shortcuts { keys.append("shortcuts") }
        if old.sources != new.sources { keys.append("sources") }
        if old.automaticUpdateChecks != new.automaticUpdateChecks { keys.append("automaticUpdateChecks") }
        if old.showMenuBarIcon != new.showMenuBarIcon { keys.append("showMenuBarIcon") }
        // The whole record, never its fields. The city is where somebody lives and the calendar
        // identifiers are theirs, and `changedKeys` is read straight into `IslandLog`, which is the
        // file "Export Logs…" hands to strangers.
        if old.glance != new.glance { keys.append("glance") }
        if old.showsNowPlayingOnLockScreen != new.showsNowPlayingOnLockScreen {
            keys.append("showsNowPlayingOnLockScreen")
        }
        // The count, never the list — these are the apps a person uses and does not want
        // interrupted during, and this line is read straight into a file emailed to strangers.
        if old.hiddenApplications != new.hiddenApplications { keys.append("hiddenApplications") }
        if old.minimalOnSynthesizedDisplays != new.minimalOnSynthesizedDisplays {
            keys.append("minimalOnSynthesizedDisplays")
        }
        return keys
    }
}

// MARK: - Coding

extension IsletaConfiguration: Codable {

    /// Written out rather than synthesised, for one reason: `toggleHotKey` is a *computed* forwarder
    /// onto `shortcuts` since the 2.0 vocabulary, so the synthesised encoder cannot find a stored
    /// property behind its coding key and the conformance fails to compile. That is the good
    /// outcome — the bad one would have been a synthesised encoder that wrote the shortcut twice,
    /// in two shapes, leaving the next reader to work out which one is live.
    ///
    /// **The legacy `toggleHotKey` key is decoded and never encoded.** A v6 file keeps working; the
    /// first save after upgrading moves the binding into `shortcuts` and drops the flat key. The
    /// cost is the one this file already accepts for a newer file read by an older build — the
    /// setting is lost rather than corrupted.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(suppressSystemHUDs, forKey: .suppressSystemHUDs)
        try container.encode(suppressBrightnessHUD, forKey: .suppressBrightnessHUD)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(sources, forKey: .sources)
        try container.encode(automaticUpdateChecks, forKey: .automaticUpdateChecks)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(glance, forKey: .glance)
        try container.encode(showsNowPlayingOnLockScreen, forKey: .showsNowPlayingOnLockScreen)
        try container.encode(hiddenApplications, forKey: .hiddenApplications)
        try container.encode(minimalOnSynthesizedDisplays, forKey: .minimalOnSynthesizedDisplays)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case suppressSystemHUDs
        case suppressBrightnessHUD
        case toggleHotKey
        case shortcuts
        case sources
        case automaticUpdateChecks
        case showMenuBarIcon
        case glance
        case showsNowPlayingOnLockScreen
        case hiddenApplications
        case minimalOnSynthesizedDisplays
    }

    /// Decoding is deliberately lenient: any key that is missing or malformed falls back to its
    /// default, and the rest of the file still lands.
    ///
    /// The synthesised all-or-nothing decode is the wrong shape for a settings file. One field added
    /// in a later build makes every file written by an earlier one fail to decode *in its entirety*,
    /// and the only sane recovery from a thrown error is to start from defaults — so a user who had
    /// customised five things loses all five because of the sixth. Per-key fallback means a
    /// downgrade, a partially written file, or a hand-edited one costs the user exactly the settings
    /// that are actually unreadable.
    ///
    /// `SettingsMigration` still runs first and still stamps a version: leniency handles *added* and
    /// *removed* keys, which is most of it. It cannot handle a key whose meaning changed while its
    /// name and type stayed the same, or one that moved — which is what schema 18 does to
    /// `hiddenApplications` — and that is what the version number is for.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IsletaConfiguration.defaults
        let legacyToggleHotKey: HotKeyBinding?

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key))?.flatMap { $0 } ?? fallback
        }

        schemaVersion = value(.schemaVersion, IsletaConfiguration.currentSchemaVersion)
        // **Deliberately not carried across from a v3 file.** `migrateV3ToV4` deleted the old key,
        // so any blob that still holds one predates that migration and cannot reach here — and even
        // if it could, an answer given to "hide a HUD Isleta could not hide" is not consent for a
        // mechanism that did not exist when it was given. Everyone starts at false.
        suppressSystemHUDs = value(.suppressSystemHUDs, defaults.suppressSystemHUDs)
        // New in schema 24 and therefore absent from every file written before it, which the
        // decoder's leniency reads as the default — false. No migration step is needed for a key
        // that has never existed: `migrateV22ToV23` had to *clear* `suppressSystemHUDs` only because
        // a v3 file could still be carrying a stale answer to a different question.
        suppressBrightnessHUD = value(.suppressBrightnessHUD, defaults.suppressBrightnessHUD)
        // Order matters, and only in one direction. `shortcuts` is the stored record, so it is read
        // first; `toggleHotKey` is then read over the top of it, which is what lets a v6 file — and
        // a hand-written `defaults write` — keep working. A file holding both is a file where the
        // user rebound the island toggle after upgrading, and the flat key is the older of the two.
        shortcuts = value(.shortcuts, defaults.shortcuts)
        legacyToggleHotKey =
            (try? container.decodeIfPresent(HotKeyBinding.self, forKey: .toggleHotKey)).flatMap { $0 }
        sources = value(.sources, defaults.sources)
        automaticUpdateChecks = value(.automaticUpdateChecks, defaults.automaticUpdateChecks)
        showMenuBarIcon = value(.showMenuBarIcon, defaults.showMenuBarIcon)
        glance = value(.glance, defaults.glance)
        showsNowPlayingOnLockScreen = value(
            .showsNowPlayingOnLockScreen, defaults.showsNowPlayingOnLockScreen
        )
        hiddenApplications = value(.hiddenApplications, defaults.hiddenApplications)
        minimalOnSynthesizedDisplays = value(
            .minimalOnSynthesizedDisplays, defaults.minimalOnSynthesizedDisplays
        )

        // Applied last, because `toggleHotKey` is a computed forwarder and writing through it
        // touches `self` — which is not allowed until every stored property exists.
        //
        // **Only when the record has no opinion**, which is the half a test had to catch. A v6 file
        // has the flat key and no `shortcuts`, so the legacy value is the only value and must win.
        // A file with *both* was written by a build that had already migrated, so the record is the
        // live one and the flat key is a leftover the encoder is about to drop — applying it there
        // would silently undo the last rebind on every launch until the file was saved again.
        if let legacyToggleHotKey, !shortcuts.isCustomised(.toggleIsland) {
            toggleHotKey = legacyToggleHotKey
        }
    }
}
