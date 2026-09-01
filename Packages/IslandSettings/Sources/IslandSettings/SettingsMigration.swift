import Foundation

/// Reads a stored configuration written by any version of Isleta, and writes one this version can
/// read back (§11).
///
/// Migration runs on the raw JSON object, before `Codable` ever sees it, and that ordering is the
/// whole design. Once the data has been decoded into `IsletaConfiguration` the information a
/// migration needs is already gone: a renamed key looks identical to an absent one, and a field
/// whose units changed looks like a field that is simply set to a surprising number. Migrating
/// afterwards can only ever guess.
///
/// The complementary half is that `IsletaConfiguration`'s decoder is lenient (see its `init(from:)`),
/// so purely additive and subtractive changes need no step here at all. A step is required only when
/// the *meaning* of stored data changes — a rename, a change of units, a semantic flip.
public enum SettingsMigration {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The stored blob is not a JSON object. Hand-edited, truncated, or written by something
        /// that is not Isleta.
        case notAJSONObject

        public var description: String {
            switch self {
            case .notAJSONObject: "the stored configuration is not a JSON object"
            }
        }
    }

    /// Decodes stored bytes into a configuration, applying every migration step the file is behind.
    public static func decode(_ data: Data) throws -> IsletaConfiguration {
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else { throw Failure.notAJSONObject }

        let migrated = migrate(object)
        let normalized = try JSONSerialization.data(withJSONObject: migrated)
        return try JSONDecoder().decode(IsletaConfiguration.self, from: normalized)
    }

    /// The version stored bytes claim to be, for the launch log line — so a report says whether the
    /// configuration was migrated on the way in. Unreadable bytes answer 0, the same as a file with
    /// no version, because `decode` is about to throw over them and say why.
    public static func schemaVersion(of data: Data) -> Int {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return storedVersion(of: object)
    }

    /// Encodes a configuration, stamping it with the version this build writes.
    ///
    /// Sorted keys so the bytes are stable: an unordered encode makes every save look like a change
    /// to anything diffing the file, and makes a test that compares blobs flap.
    public static func encode(_ configuration: IsletaConfiguration) throws -> Data {
        var stamped = configuration
        stamped.schemaVersion = IsletaConfiguration.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stamped)
    }

    /// The version a stored object claims to be.
    ///
    /// An object with no `schemaVersion` is version 0 — the shape Isleta wrote before it versioned
    /// anything. That is not hypothetical bookkeeping: a hand-edited or truncated file with the key
    /// missing has to land somewhere deterministic rather than throwing, and 0 is the only answer
    /// that runs the full chain over it.
    static func storedVersion(of object: [String: Any]) -> Int {
        object["schemaVersion"] as? Int ?? 0
    }

    /// Applies every step between the object's version and this build's, in order.
    ///
    /// Written as a fallthrough chain rather than a table of closures so that adding a step is one
    /// `case` and the compiler still checks it. A `[Int: (inout [String: Any]) -> Void]` stored
    /// statically would need to be non-Sendable-escaped global state for no gain.
    static func migrate(_ object: [String: Any]) -> [String: Any] {
        var object = object
        let version = storedVersion(of: object)

        // A file from a *newer* Isleta. Nothing to migrate downwards, and refusing to read it would
        // reset a user who briefly ran a newer build. Everything this build understands is read;
        // anything it does not is ignored by the lenient decoder — and lost on the next save, which
        // is the honest cost of running the older build.
        guard version < IsletaConfiguration.currentSchemaVersion else { return object }

        if version < 1 { migrateV0ToV1(&object) }
        if version < 2 { migrateV1ToV2(&object) }
        if version < 3 { migrateV2ToV3(&object) }
        if version < 4 { migrateV3ToV4(&object) }
        if version < 5 { migrateV4ToV5(&object) }
        if version < 6 { migrateV5ToV6(&object) }
        if version < 7 { migrateV6ToV7(&object) }
        if version < 8 { migrateV7ToV8(&object) }
        if version < 9 { migrateV8ToV9(&object) }
        if version < 10 { migrateV9ToV10(&object) }
        if version < 11 { migrateV10ToV11(&object) }
        if version < 12 { migrateV11ToV12(&object) }
        if version < 13 { migrateV12ToV13(&object) }
        if version < 14 { migrateV13ToV14(&object) }
        if version < 15 { migrateV14ToV15(&object) }
        if version < 16 { migrateV15ToV16(&object) }
        if version < 17 { migrateV16ToV17(&object) }
        if version < 18 { migrateV17ToV18(&object) }
        if version < 19 { migrateV18ToV19(&object) }
        if version < 20 { migrateV19ToV20(&object) }
        if version < 21 { migrateV20ToV21(&object) }
        if version < 22 { migrateV21ToV22(&object) }
        if version < 23 { migrateV22ToV23(&object) }

        object["schemaVersion"] = IsletaConfiguration.currentSchemaVersion
        return object
    }

    /// Version 0 → 1: the pre-versioning shape.
    ///
    /// Isleta has never shipped a settings file, so there are no version 0 files in the wild. This
    /// step exists for two honest reasons. It is the worked example the next migration is copied
    /// from — the version to test against, the mutation to write, the place to put it. And it gives
    /// a file with no `schemaVersion` a defined destination instead of an accident.
    ///
    /// Its one real transformation: version 0 predates the configurable toggle shortcut, which was
    /// compiled in as ⌃⌥⌘I. A v0 file therefore has no `toggleHotKey`, and it must become the
    /// shortcut the user's fingers already know rather than whatever a later build happens to
    /// default to. Today those are the same value; the point is that this step keeps them the same
    /// if the default ever moves.
    private static func migrateV0ToV1(_ object: inout [String: Any]) {
        if object["toggleHotKey"] == nil {
            object["toggleHotKey"] = [
                "keyCode": HotKeyBinding.toggleIsland.keyCode,
                "carbonModifiers": HotKeyBinding.toggleIsland.carbonModifiers,
            ]
        }
    }

    /// Version 1 → 2: the four continuous settings arrived.
    ///
    /// Purely additive, so `IsletaConfiguration`'s lenient decoder would already give a v1 file the
    /// right answer for all four — the defaults are exactly today's compiled-in behavior, which is
    /// what a v1 file was running with. The step exists anyway, and does one thing leniency cannot:
    /// it **deletes** a key that is present but not a number.
    ///
    /// The distinction matters because leniency's fallback is per key and its recovery is the
    /// default, which is right for a *missing* key and wrong here. `defaults write` is the
    /// documented way to inspect this blob (see the module README) and it is one flag away from
    /// writing `peekScale` as the string "1.5". Left in place that key decodes as absent, so the
    /// slider reads 1.0, the user's edit does nothing, and the next save silently overwrites it —
    /// with no way to tell that from a typo in the key's name. Removed here, the value that lands
    /// is the same, but the stored blob no longer claims otherwise.
    ///
    /// Out-of-range numbers are deliberately *not* touched: those are clamped by the decoder, which
    /// keeps the user's direction rather than discarding it.
    private static func migrateV1ToV2(_ object: inout [String: Any]) {
        removeNonNumbers(["hoverDelay", "peekScale", "activityDwellScale", "synthesizedIslandOpacity"], from: &object)
    }

    /// Version 2 → 3: the Welcome Back threshold became a setting.
    ///
    /// Additive, and the default is exactly what v2 had compiled in — five minutes — so a v2 file
    /// keeps behaving the way it did. The step exists for the same reason `migrateV1ToV2` does: a
    /// key that is present but is not a number is a `defaults write` one flag away from a string,
    /// and leniency would silently read it as absent while leaving the blob claiming otherwise.
    private static func migrateV2ToV3(_ object: inout [String: Any]) {
        removeNonNumbers(["welcomeBackMinimumAbsence"], from: &object)
    }

    /// Version 3 → 4: two settings were withdrawn.
    ///
    /// `suppressSystemHUDs` was a switch that could never move — `SystemHUDSuppression` suppresses
    /// nothing on macOS 26 and documents why — and `delightEnabled` was stored ahead of a §8.4
    /// registry that never arrived, so it was written, migrated and read by nobody.
    ///
    /// The decoder's leniency means a v3 file already decodes correctly without this step: a key
    /// with no field behind it is simply ignored. The step exists because *ignored* and *gone* are
    /// different states of the file. Left in place, both keys survive every future save, still
    /// holding whatever the user last chose, and the next person to read the blob has to work out
    /// which of the keys in it are live. This is the subtractive counterpart to `migrateV1ToV2`'s
    /// deletions, and the reason both are deletions rather than rewrites: the honest record of a
    /// setting that no longer exists is its absence.
    private static func migrateV3ToV4(_ object: inout [String: Any]) {
        object["suppressSystemHUDs"] = nil
        object["delightEnabled"] = nil
    }

    /// Version 4 → 5: the status item became hideable.
    ///
    /// Additive, and the default — `true` — is what every build before v5 did, so a v4 file keeps
    /// its status item. That is the outcome that must not be got wrong: the failure mode is a user
    /// whose only route into an app with no Dock icon disappears on upgrade, and leniency already
    /// gives it to us for a *missing* key.
    ///
    /// What leniency cannot do is the same thing `migrateV1ToV2` exists for: a key that is present
    /// but holds the wrong type. `defaults write` is the documented way to inspect this blob and it
    /// is one flag away from writing `showMenuBarIcon` as the string "false" — which decodes as
    /// absent, so the icon stays, the switch reads on, and the blob goes on claiming otherwise.
    private static func migrateV4ToV5(_ object: inout [String: Any]) {
        removeNonBooleans(["showMenuBarIcon"], from: &object)
    }

    /// Version 5 → 6: eleven module switches arrive with the 2.0 parity vocabulary.
    ///
    /// Purely additive, and the whole step is a type sweep over the nested `sources` object for the
    /// reason `migrateV4ToV5` explains — `defaults write` is one flag away from putting the string
    /// "false" where a `Bool` belongs, and a wrongly-typed key decodes as *absent*, which here means
    /// the module comes back on and the record goes on claiming it is off.
    ///
    /// **The one that defaults to off is why this needs a step at all rather than leniency alone.**
    /// A v5 file has none of these keys, so leniency gives every one of them its default — and for
    /// nine of them the default is on, which is what a v5 user would expect from an upgrade that
    /// added a feature. For `appSwitcher` the default is off, and that is also the right answer for
    /// an upgrade: it should not start claiming a system-wide hot key because the user installed a
    /// new version. Nothing to do, then — but it is written down here rather than left to be
    /// rediscovered, because "the migration does nothing" and "the migration was forgotten" look
    /// identical six months later.
    ///
    /// `focusChanges`, `appSwitcher` and `transfers` are swept here and none of the three exists as
    /// a field any more — `migrateV10ToV11`, `migrateV18ToV19` and `migrateV21ToV22` are where they
    /// go away. All three are left in the list because this step runs against a v5 file, where the
    /// keys are present and this is still the right thing to do to them.
    private static func migrateV5ToV6(_ object: inout [String: Any]) {
        guard var sources = object["sources"] as? [String: Any] else { return }
        removeNonBooleans(
            [
                "glance", "calendarAlerts", "meetings", "power", "calls",
                "transfers", "dropActions", "appSwitcher", "focusChanges", "screenSharing",
            ],
            from: &sources
        )
        object["sources"] = sources
    }

    /// Version 6 → 7: the single toggle shortcut became a vocabulary of them.
    ///
    /// The flat `toggleHotKey` key moves into `shortcuts`, keyed by `ShortcutAction.toggleIsland`.
    /// Done here as well as in the decoder — which also reads the flat key — because the two answer
    /// different questions. The decoder's leniency keeps a v6 file *working*; this step is what
    /// makes the record on disk say the same thing the app believes, so the next person to read the
    /// blob does not find a shortcut in two places and have to work out which one is live.
    ///
    /// The flat key is left in place rather than deleted. It is the one migration in this chain
    /// that does not remove what it moves, and the reason is downgrade: a user who runs 2.0 once
    /// and goes back to 1.3 keeps the shortcut their fingers know. The encoder drops it on the
    /// first save after that, which is when the downgrade window genuinely closes.
    private static func migrateV6ToV7(_ object: inout [String: Any]) {
        guard let legacy = object["toggleHotKey"] as? [String: Any] else { return }
        var shortcuts = object["shortcuts"] as? [String: Any] ?? [:]
        var assignments = shortcuts["assignments"] as? [String: Any] ?? [:]
        // Never over the top of a choice already made in the new shape.
        if assignments[ShortcutAction.toggleIsland.rawValue] == nil {
            assignments[ShortcutAction.toggleIsland.rawValue] = legacy
        }
        shortcuts["assignments"] = assignments
        object["shortcuts"] = shortcuts
    }

    /// Version 7 → 8: the glance's settings move in from the key they were parked on.
    ///
    /// `GlanceSettings` shipped in its own `UserDefaults` key while Stage 1 was built, because the
    /// alternative — an agent inserting a stored property into `IsletaConfiguration` alongside three
    /// others editing the same tree — is the cross-package layout trap CLAUDE.md documents. The cost
    /// of that parking was real and was written down rather than hidden: **"Reset to Defaults" did
    /// not reset the glance**, because the record it resets did not contain it.
    ///
    /// This step is what makes that true again. It reads the parked blob out of its own key and
    /// nests it under `glance`, and it does **not** delete the old key — for `migrateV6ToV7`'s
    /// reason. A user who runs 2.0 once and goes back keeps their city and their chosen calendars;
    /// the encoder stops writing the old key from here on, which is when the downgrade window
    /// genuinely closes.
    ///
    /// A file that already has `glance` was written by a build that had migrated, so the nested
    /// record wins and the parked key is a leftover.
    static func migrateV7ToV8(_ object: inout [String: Any]) {
        guard object["glance"] == nil else { return }
        guard let data = UserDefaults.standard.data(forKey: legacyGlanceKey),
              let parked = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        object["glance"] = parked
    }

    /// The key `GlanceSettings` was parked on for one release. Read by `migrateV7ToV8` and written
    /// by nothing.
    static let legacyGlanceKey = "com.tryisleta.isleta.glance"

    /// Version 8 → 9: the notification rules move in from the key they were parked on.
    ///
    /// The same shape as `migrateV7ToV8`, for the same reason and with the same cost — Stage 4 was
    /// built beside four other agents, so `NotificationPreferences` waited on its own key and
    /// **"Reset to Defaults" did not reach a user's muted apps** for as long as it sat there.
    ///
    /// That this is the *second* record to be parked and lifted is the point worth writing down. It
    /// is now the established shape for the 2.0 fan-out rather than an improvisation: an agent that
    /// needs a persisted field parks it behind a store of the same shape, says so in the type, and
    /// the integrator lifts it in one schema step. The alternative — five agents appending to one
    /// struct — is the cross-package layout trap, which has no compile error and segfaults somewhere
    /// else entirely.
    /// **Nothing left to lift.** It moved a parked `NotificationPreferences` blob into
    /// `object["notifications"]`, and `migrateV19ToV20` now deletes that key on the way past — so
    /// doing the lift would be reading a defaults key in order to write a field that is removed two
    /// steps later. The step stays in the chain because the version numbers are a ledger and
    /// renumbering them would strand every file written against the old ones.
    static func migrateV8ToV9(_ object: inout [String: Any]) {}

    /// Version 9 → 10: Stage 7's appearance record.
    ///
    /// **Not** a lift from a parked key, unlike the two steps above — Stage 7 was built alone, so
    /// `AppearanceSettings` went straight into `IsletaConfiguration` and there is nothing to move.
    /// What is left is the type sweep, which is the thing leniency cannot do and the reason every
    /// additive step in this chain still exists: `defaults write` is the documented way to inspect
    /// this blob (see the module README) and it is one flag away from writing `shadow` as the string
    /// "true" or `animationSpeed` as "1.5". A wrongly-typed key decodes as **absent**, so the
    /// setting silently reverts to its default, the switch reads the opposite of the file, and the
    /// next save overwrites the user's edit with no way to tell that from a typo in the key's name.
    ///
    /// Three things are deliberately *not* swept.
    ///
    /// `style` is a string from a fixed vocabulary, and a string is what it is meant to be — a
    /// misspelling decodes as absent and lands on `.automatic`, which is precisely what the island
    /// looked like before styles existed and therefore the right answer to an unreadable one.
    /// `hiddenApplications` is an array, and an array holding one wrong element is still a usable
    /// list; dropping the whole key over it would unhide every app the user had chosen.
    /// Out-of-range *numbers* are left alone as well, for `migrateV1ToV2`'s reason: the decoder
    /// clamps them, which keeps the user's direction rather than discarding it.
    ///
    /// A v9 file has no `appearance` object at all, and every default in `AppearanceSettings`
    /// reproduces what that build drew — so an upgrade changes nothing on screen. The one exception
    /// is `albumColor`, which defaults to on and is written down as an exception where it is
    /// declared rather than hidden here.
    static func migrateV9ToV10(_ object: inout [String: Any]) {
        guard var appearance = object["appearance"] as? [String: Any] else { return }
        removeNonBooleans(
            // The **old** spelling, deliberately. This step runs against a v9 file, where the key
            // is `miniLake`; `migrateV11ToV12` is what renames it.
            ["miniLake", "shadow", "albumColor", "minimalOnSynthesizedDisplays"],
            from: &appearance
        )
        removeNonNumbers(
            ["islandWidthAdjustment", "islandHeightAdjustment", "animationSpeed"],
            from: &appearance
        )
        object["appearance"] = appearance
    }

    /// Version 10 → 11: `sources.focusChanges` becomes `sources.respectsFocus`, and does **not**
    /// carry the old value across.
    ///
    /// This is the one step in the chain that deliberately discards what it replaces, and the reason
    /// is that the two flags are not the same question. `focusChanges` meant "announce a Focus
    /// turning on", which macOS has never been able to tell us (see `IntentsFocusStatus`) — so
    /// nothing published `ActivityKind.focusChanged`, nothing read the flag, and whatever value is
    /// in a user's file is a preference they were never able to express or observe. Carrying a
    /// meaningless `false` across into `respectsFocus` would turn Focus suppression **off** for
    /// every existing user, silently, in an upgrade — a change to what the island does, made from a
    /// value that meant nothing.
    ///
    /// So the key is removed and `respectsFocus` is left absent, which the lenient decoder resolves
    /// to its default of `true`: exactly what every build up to now did.
    ///
    /// The type sweep is for the same reason every other step has one — `defaults write` is one
    /// flag away from putting the string "false" where a `Bool` belongs, and a wrongly-typed key
    /// decodes as absent, which here means Focus suppression comes back on while the record claims
    /// it is off.
    static func migrateV10ToV11(_ object: inout [String: Any]) {
        guard var sources = object["sources"] as? [String: Any] else { return }
        sources["focusChanges"] = nil
        removeNonBooleans(["respectsFocus"], from: &sources)
        object["sources"] = sources
    }

    /// Version 11 → 12: `appearance.miniLake` becomes `appearance.compactIsland`, **carrying the
    /// user's value**.
    ///
    /// A rename and nothing else. This is the opposite of `migrateV10ToV11`, which deliberately
    /// throws its old value away — and the difference is worth stating, because two renames in
    /// consecutive schema steps that behave oppositely is exactly the pair somebody will later
    /// "make consistent". `focusChanges` meant something nothing could deliver, so its stored value
    /// was never a preference anybody expressed. `miniLake` meant precisely what `compactIsland`
    /// means, was drawn as a switch, and was switched by hand. Losing it would be losing a setting.
    ///
    /// The old key is deleted rather than left beside the new one. Unlike `migrateV6ToV7`, which
    /// keeps `toggleHotKey` in place so a downgrade to 1.3 still finds the user's shortcut, there is
    /// nothing to preserve here: a build old enough to read `miniLake` predates the whole appearance
    /// record, so it would ignore the object either way.
    static func migrateV11ToV12(_ object: inout [String: Any]) {
        guard var appearance = object["appearance"] as? [String: Any] else { return }
        if let stored = appearance["miniLake"] {
            appearance["miniLake"] = nil
            // Only if the new key is genuinely absent. A file that already has both — which only a
            // hand-edit can produce — keeps the one the app is actually reading.
            if appearance["compactIsland"] == nil { appearance["compactIsland"] = stored }
        }
        removeNonBooleans(["compactIsland"], from: &appearance)
        object["appearance"] = appearance
    }

    /// Version 12 → 13: the player bar's parked record came home.
    ///
    /// **Nothing left to lift.** It moved a parked `PlayerBarSettings` blob into
    /// `object["playerBar"]` — the third record to be parked and lifted, after `GlanceSettings`
    /// (`migrateV7ToV8`) and `NotificationPreferences` (`migrateV8ToV9`) — and `migrateV20ToV21`
    /// now deletes that key on the way past, because the bar itself is withdrawn. Doing the lift
    /// would be reading a defaults key in order to write a field that is removed eight steps later.
    ///
    /// The step stays in the chain for `migrateV8ToV9`'s reason: the version numbers are a ledger,
    /// and renumbering them would strand every file written against the old ones.
    static func migrateV12ToV13(_ object: inout [String: Any]) {}

    /// Version 13 → 14: the HUD source's one switch becomes a master and three.
    ///
    /// **Nothing is carried across, and nothing needs to be.** `systemHUDs` keeps both its name and
    /// its meaning — it is still the switch that decides whether the source runs — and the three new
    /// keys are additive, absent from a v13 file, and default to on. So a user who had the HUDs on
    /// gets all four levels exactly as before, and a user who had them off gets nothing exactly as
    /// before. This is the opposite of `migrateV10ToV11`, where the old flag's value was meaningless
    /// and had to be discarded; here the old flag is unchanged and the new ones are a subdivision
    /// underneath it.
    ///
    /// The type sweep is why the step exists at all rather than being left to leniency, and it is
    /// the reason every additive step in this chain has one: `defaults write` is the documented way
    /// to inspect this blob and is one flag away from writing `volumeHUD` as the string "false" — a
    /// wrongly-typed key decodes as **absent**, which here means the HUD the user switched off comes
    /// back on while the file goes on claiming it is off.
    ///
    /// `keyboardBrightnessHUD` is swept here and no longer exists as a field; `migrateV17ToV18` is
    /// where it goes away, with the level it switched. Left in the list because this step runs
    /// against a v13 file, where the key is present and this is still the right thing to do to it.
    static func migrateV13ToV14(_ object: inout [String: Any]) {
        guard var sources = object["sources"] as? [String: Any] else { return }
        removeNonBooleans(
            ["volumeHUD", "displayBrightnessHUD", "keyboardBrightnessHUD"],
            from: &sources
        )
        object["sources"] = sources
    }

    /// Version 14 → 15: the sides record arrives, and the step exists to type-check it.
    ///
    /// **Nothing is carried across, and nothing needs to be.** `sides` is additive, absent from a
    /// v14 file, and every default in `IslandSides` reproduces what Isleta drew before any of it was
    /// adjustable — so an upgrade changes nothing on screen, which is the property `AppearanceSettings`
    /// established and every record since has kept.
    ///
    /// The type sweep is the reason it is a step rather than being left to leniency, and this record
    /// needs it more than most: `defaults write` is the documented way to inspect this blob, and
    /// `assignments` is the first field in the file whose *value* is a free-form object. A `mirrored`
    /// written as the string "true", or an `assignments` written as an array, decodes as **absent** —
    /// which here means the island quietly goes back to the sides the user moved it away from while
    /// the file goes on claiming otherwise.
    ///
    /// Individual entries inside `assignments` are deliberately **not** swept. An entry naming a kind
    /// or a side this build does not have is already ignored at the read (`IslandSides.side(for:)`),
    /// and that is what lets a kind be retired without a migration step — dropping them here would
    /// destroy a preference that a downgrade, or a later build, could still honor.
    static func migrateV14ToV15(_ object: inout [String: Any]) {
        guard var sides = object["sides"] as? [String: Any] else {
            // Present but not an object at all — a hand-edit that wrote a string or a number where
            // the record goes. Dropped, so leniency sees an absent key rather than a malformed one.
            if object["sides"] != nil { object["sides"] = nil }
            return
        }
        removeNonBooleans(["mirrored"], from: &sides)
        if sides["assignments"] != nil, !(sides["assignments"] is [String: Any]) {
            sides["assignments"] = nil
        }
        object["sides"] = sides
    }

    /// Version 15 → 16: `showsNowPlayingOnLockScreen`.
    ///
    /// Purely additive, and the absent key decodes to the default — which for this one field is
    /// **false**. That is the opposite of the usual rule in this file, where an absent key must
    /// decode to whatever the previous build did, and here those happen to agree: no build before 16
    /// drew anything on the lock screen, so `false` *is* what the user had.
    ///
    /// It is worth stating anyway, because the temptation on the next release is to make it default
    /// on now that it works. It must not. The surface exists through a private, undocumented SkyLight
    /// space level; it can stop working on any macOS release, and it shows what somebody is listening
    /// to on a screen they have walked away from. Both are reasons for the user to have chosen it.
    ///
    /// The type sweep is here for the same reason every other step has one: `defaults write` is the
    /// documented way to inspect this blob, and a `showsNowPlayingOnLockScreen` hand-written as the
    /// string "true" decodes as **absent** — which is off, silently, on a switch the user believes
    /// they set.
    static func migrateV15ToV16(_ object: inout [String: Any]) {
        removeNonBooleans(["showsNowPlayingOnLockScreen"], from: &object)
    }

    /// Version 16 → 17: `playsLockScreenSounds`.
    ///
    /// Additive, absent decodes to **false**, and — as with every step in this file — the type sweep
    /// is here because `defaults write` is the documented way to inspect this blob and a boolean
    /// hand-written as the string "true" decodes as absent. For this key that failure is silent in
    /// the *quiet* direction, which is the harmless one; the sweep exists so the stored value and
    /// the switch agree either way.
    static func migrateV16ToV17(_ object: inout [String: Any]) {
        removeNonBooleans(["playsLockScreenSounds"], from: &object)
    }

    /// Version 17 → 18: nineteen settings go, two move, and one is folded into another.
    ///
    /// The only step in this chain that is mostly *deletion*, and the only reason it is a step at
    /// all is the two that move. Leniency already ignores a key this build has no field for, so the
    /// removals would work without it — but a record whose keys outlive their meaning is how a later
    /// migration ends up guessing which of two spellings was live, and there is nothing left to
    /// guess about here: `appearance` is gone as a concept, and a v18 file that still carried a
    /// `hoverDelay` would invite the next reader to wonder whether something still honors it.
    ///
    /// ## The lift, which is the part that cannot be left to leniency
    ///
    /// `appearance.hiddenApplications` and `appearance.minimalOnSynthesizedDisplays` are the two
    /// fields that survived the Appearance pane, and they are now top-level. Without this step the
    /// lenient decoder finds no `hiddenApplications` key, defaults it to empty, and **silently
    /// unhides every app a user had spent time adding** — a settings file that looks like it was
    /// reset by an update. Read across, then the whole `appearance` record is dropped.
    ///
    /// The old key is deleted here, unlike `migrateV6ToV7`'s and `migrateV7ToV8`'s, which left theirs
    /// for a downgrade to find. Those two moved a record into a *new* home while the old build's home
    /// still meant something; this one moves two fields out of a record whose other seven fields no
    /// longer exist, so a 2.0 build reading the leftover would restore a style, a width and an
    /// animation speed alongside them. There is no downgrade this leaves working, and pretending
    /// otherwise costs the correctness of the file.
    ///
    /// ## The fold
    ///
    /// `playsLockScreenSounds` is not carried anywhere. The sounds now follow
    /// `showsNowPlayingOnLockScreen`, so a user who had the card keeps the card and gains the sound
    /// they had switched off, and one who had the sound *without* the card loses it. That second
    /// case is the cost of the fold and it is stated rather than hidden — it is a combination the
    /// pane no longer offers, and there is no honest way to keep it without keeping the switch.
    ///
    /// ## No type sweep
    ///
    /// Every other additive step in this file ends with one, because a `defaults write` of the wrong
    /// type decodes as absent and silently disagrees with what the switch says. This step adds no
    /// key that a person could have hand-written yet — `hiddenApplications` and
    /// `minimalOnSynthesizedDisplays` are read here from a nested record this build wrote itself, and
    /// swept on the way across.
    static func migrateV17ToV18(_ object: inout [String: Any]) {
        if let appearance = object["appearance"] as? [String: Any] {
            // An array of strings or nothing. A hand-edited `hiddenApplications` holding numbers
            // would decode as absent — which is the silent unhiding this whole step exists to
            // prevent — so it is checked here rather than trusted.
            if let hidden = appearance["hiddenApplications"] as? [Any] {
                let identifiers = hidden.compactMap { $0 as? String }
                if !identifiers.isEmpty { object["hiddenApplications"] = identifiers }
            }
            if let minimal = appearance["minimalOnSynthesizedDisplays"],
               CFGetTypeID(minimal as CFTypeRef) == CFBooleanGetTypeID() {
                object["minimalOnSynthesizedDisplays"] = minimal
            }
        }

        for key in [
            "appearance", "sides", "hapticsEnabled", "hoverDelay", "peekScale",
            "activityDwellScale", "welcomeBackMinimumAbsence", "synthesizedIslandOpacity",
            "playsLockScreenSounds",
        ] {
            object[key] = nil
        }

        // The five actions that lost their recorder. Left in the file they would keep claiming a
        // system-wide key on every launch — `Shortcuts` registers whatever `assignments` names, and
        // `ShortcutAction` no longer has a case to decode them into, so the binding would be
        // unreachable *and* unremovable from the settings window.
        if var shortcuts = object["shortcuts"] as? [String: Any],
           var assignments = shortcuts["assignments"] as? [String: Any] {
            for retired in ["startTimer", "openShelf", "copyLastLink", "openDropHistory", "dismissAll"] {
                assignments[retired] = nil
            }
            shortcuts["assignments"] = assignments
            object["shortcuts"] = shortcuts
        }

        // The glance's own casualty. Celsius or Fahrenheit follows the Mac's region setting now —
        // see `IsletaConfiguration`'s note on what is deliberately not stored.
        if var glance = object["glance"] as? [String: Any] {
            glance["temperatureUnit"] = nil
            object["glance"] = glance
        }

        if var notifications = object["notifications"] as? [String: Any] {
            notifications["groupsBursts"] = nil
            notifications["showsLinkPreviews"] = nil
            object["notifications"] = notifications
        }

        if var playerBar = object["playerBar"] as? [String: Any] {
            playerBar["position"] = nil
            playerBar["showsWhenNothingIsPlaying"] = nil
            object["playerBar"] = playerBar
        }

        // The keyboard-backlight HUD, gone with its level rather than its switch — see `SystemHUD`.
        // The other two HUD flags stay exactly as `migrateV13ToV14` left them.
        if var sources = object["sources"] as? [String: Any] {
            sources["keyboardBrightnessHUD"] = nil
            object["sources"] = sources
        }
    }

    /// Version 18 → 19: the app switcher is withdrawn.
    ///
    /// Two keys, in two records, and only the second of them has to be here. `sources.appSwitcher`
    /// is a field this build no longer has, so leniency already ignores it — it is deleted for
    /// `migrateV3ToV4`'s reason: *ignored* and *gone* are different states of the file, and a flag
    /// that survives every future save leaves the next reader working out which keys are live.
    ///
    /// **`shortcuts.assignments["appSwitcher"]` is the one that would do damage if it stayed**, and
    /// it is the same trap `migrateV17ToV18` names for its five retired actions. `Shortcuts`
    /// registers whatever `assignments` holds, and `ShortcutAction` no longer has a case to decode
    /// this into — so a user who had bound a combination would go on losing it to Isleta on every
    /// launch, with no row in the settings window to clear it from.
    ///
    /// No type sweep: this step adds nothing, and both keys are on their way out regardless of what
    /// a `defaults write` may have left in them.
    static func migrateV18ToV19(_ object: inout [String: Any]) {
        if var sources = object["sources"] as? [String: Any] {
            sources["appSwitcher"] = nil
            object["sources"] = sources
        }

        if var shortcuts = object["shortcuts"] as? [String: Any],
           var assignments = shortcuts["assignments"] as? [String: Any] {
            assignments["appSwitcher"] = nil
            shortcuts["assignments"] = assignments
            object["shortcuts"] = shortcuts
        }
    }

    /// Version 19 → 20: notifications are withdrawn.
    ///
    /// The whole feature is gone — the accessibility observer, the list, the reply, and with them
    /// every preference that only ever configured it. Three places held state for it and all three
    /// are swept for `migrateV3ToV4`'s reason: leniency already *ignores* a key this build has no
    /// field for, and *ignored* and *gone* are different states of the file. A record that survives
    /// every future save leaves the next reader working out which keys are live.
    ///
    /// - `notifications` — the top-level `NotificationPreferences` record: the muted apps, the
    ///   per-app sounds, and the banner-hiding flag.
    /// - `sources.notifications` — the source's own on/off switch.
    /// - The parked `com.tryisleta.notifications.preferences` defaults key, which
    ///   `migrateV8ToV9` lifted from for one release. Deleted rather than left, because it is the
    ///   one piece of this that is **a list of the apps a person chose to silence** — it outlives
    ///   the app's own record otherwise, and there is no longer anything that could read it.
    ///
    /// No type sweep: this step adds nothing, and every key is on its way out regardless of what a
    /// `defaults write` may have left in it.
    static func migrateV19ToV20(_ object: inout [String: Any]) {
        object["notifications"] = nil

        if var sources = object["sources"] as? [String: Any] {
            sources["notifications"] = nil
            object["sources"] = sources
        }

        UserDefaults.standard.removeObject(forKey: "com.tryisleta.notifications.preferences")
    }

    /// Version 20 → 21: the player bar is withdrawn.
    ///
    /// A permanently visible window is the one surface a user cannot miss, and it is gone — the
    /// window, the controller, the view and the record that configured it. Two places held state
    /// for it and both are swept for `migrateV3ToV4`'s reason: leniency already *ignores* a key
    /// this build has no field for, and *ignored* and *gone* are different states of the file.
    ///
    /// - `playerBar` — the top-level `PlayerBarSettings` record: whether the bar existed, and which
    ///   displays got one.
    /// - The parked `com.tryisleta.isleta.playerbar` defaults key, which `migrateV12ToV13` lifted
    ///   from for one release and deliberately left in place for a downgrade. There is no longer a
    ///   build to downgrade *to* that would draw a bar from it, so it goes with the record.
    ///
    /// No type sweep: this step adds nothing, and both keys are on their way out regardless of what
    /// a `defaults write` may have left in them.
    static func migrateV20ToV21(_ object: inout [String: Any]) {
        object["playerBar"] = nil

        UserDefaults.standard.removeObject(forKey: "com.tryisleta.isleta.playerbar")
    }

    /// Version 21 → 22: downloads are withdrawn.
    ///
    /// `ActivityKind.transfer` went with the source, so there is no kind left for a switch to gate
    /// and `sources.transfers` is a field this build no longer has. Both keys are swept for
    /// `migrateV3ToV4`'s reason: leniency already *ignores* a key with no field behind it, and
    /// *ignored* and *gone* are different states of the file.
    ///
    /// - `sources.transfers` — the source's own on/off switch.
    /// - The parked `com.tryisleta.transfers.downloadsFolderAllowed` defaults key, which is the
    ///   one piece of this worth deleting rather than leaving: it is the note that the user once
    ///   granted Isleta their Downloads folder, and nothing in the app can read it now. The TCC
    ///   grant itself is macOS's record and is not ours to revoke — a user who wants it back lives
    ///   in System Settings under Privacy & Security → Files and Folders.
    ///
    /// No type sweep: this step adds nothing, and both keys are on their way out regardless of what
    /// a `defaults write` may have left in them.
    /// Version 22 → 23: `suppressSystemHUDs` comes back, and starts at false for everybody.
    ///
    /// **A deletion, not an addition**, which looks backwards for a step that reintroduces a
    /// setting. The key was removed by `migrateV3ToV4` because it was a switch that could never
    /// move; a blob written before that still carries whatever the user chose in 2024, and the
    /// decoder would read it as consent. It is not: an answer to "hide a HUD Isleta cannot hide" was
    /// given about a control that did nothing, and a mechanism arriving twenty schema versions later
    /// does not inherit it. Clearing the key makes the decoder fall back to `false`, which is where
    /// CLAUDE.md requires suppression to start.
    ///
    /// The same reasoning as `migrateV3ToV4`'s, run in the other direction: *ignored* and *gone* are
    /// different states of the file, and so are *absent* and *stale*.
    static func migrateV22ToV23(_ object: inout [String: Any]) {
        object["suppressSystemHUDs"] = nil
    }

    static func migrateV21ToV22(_ object: inout [String: Any]) {
        if var sources = object["sources"] as? [String: Any] {
            sources["transfers"] = nil
            object["sources"] = sources
        }

        UserDefaults.standard.removeObject(forKey: "com.tryisleta.transfers.downloadsFolderAllowed")
    }

    /// Drops keys that are present but hold something other than a number.
    ///
    /// Shared by the two steps that do it rather than copied, because the mistake this catches is
    /// itself a copy-paste one: a third step that adds a key to the wrong list looks identical to
    /// one that adds it to the right one.
    private static func removeNonNumbers(_ keys: [String], from object: inout [String: Any]) {
        for key in keys {
            guard let stored = object[key] else { continue }
            if !(stored is NSNumber) { object[key] = nil }
        }
    }

    /// Drops keys that are present but hold something other than a JSON boolean.
    ///
    /// **`stored is Bool` is not the test, and reads as though it is.** `JSONSerialization` hands
    /// back every number as `NSNumber`, and Swift bridges `NSNumber(value: 1)` to `Bool` happily —
    /// so `is Bool` accepts the `1` this is meant to catch while rejecting nothing. The type id is
    /// the only thing that separates `true` from `1` once the JSON has been parsed.
    private static func removeNonBooleans(_ keys: [String], from object: inout [String: Any]) {
        for key in keys {
            guard let stored = object[key] else { continue }
            if CFGetTypeID(stored as CFTypeRef) != CFBooleanGetTypeID() { object[key] = nil }
        }
    }
}
