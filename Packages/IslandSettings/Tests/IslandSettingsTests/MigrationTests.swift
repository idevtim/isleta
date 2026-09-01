import Carbon.HIToolbox
import Foundation
import IslandActivities
import Testing

@testable import IslandSettings

/// §11. These are the tests that have to exist before the schema ever changes, because after it
/// changes the only files left to test against are the ones this suite describes.
@Suite("Migration")
struct MigrationTests {

    @Test("a saved configuration is stamped with the version this build writes")
    func encodeStampsVersion() throws {
        var stale = IsletaConfiguration.defaults
        stale.schemaVersion = 0

        let data = try SettingsMigration.encode(stale)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == IsletaConfiguration.currentSchemaVersion)
    }

    /// A blob with no version key is version 0, not an error. A truncated or hand-edited file has
    /// to land somewhere deterministic, and 0 is the only answer that runs the whole chain over it.
    @Test("a file with no version is treated as version 0")
    func absentVersionIsZero() {
        #expect(SettingsMigration.storedVersion(of: ["showMenuBarIcon": true]) == 0)
        #expect(SettingsMigration.storedVersion(of: ["schemaVersion": 7]) == 7)
    }

    /// The v0 → v1 step: version 0 predates the configurable shortcut, which was compiled in as
    /// ⌃⌥⌘I. A v0 file must come out with the shortcut the user's fingers already know, whatever a
    /// later build's default happens to be.
    @Test("version 0 gains the shortcut that used to be hardcoded")
    func v0GainsTheHardcodedShortcut() throws {
        let json = #"{"showMenuBarIcon":false}"#
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)
        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.toggleHotKey.keyCode == kVK_ANSI_I)
        #expect(decoded.toggleHotKey.carbonModifiers == controlKey | optionKey | cmdKey)
    }

    /// A v0 file that somehow *does* carry a shortcut keeps it. A migration step that overwrote
    /// what it found would be indistinguishable from one that filled in what was missing, right up
    /// until it silently reset a real user's choice.
    @Test("version 0 keeps a shortcut it already has")
    func v0PreservesAnExistingShortcut() throws {
        let json = #"{"toggleHotKey":{"keyCode":38,"carbonModifiers":256}}"#
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.toggleHotKey.keyCode == 38)
        #expect(decoded.toggleHotKey.carbonModifiers == 256)
    }

    /// The v3 → v4 step: two settings were withdrawn, and the step is what makes them *gone* rather
    /// than merely ignored.
    ///
    /// Leniency alone would already decode this file correctly — a key with no field behind it is
    /// skipped — so the assertion that matters is the one about the re-encoded bytes, not the one
    /// about the decoded value. Without the step both keys survive every future save, still holding
    /// whatever the user last chose, and the blob keeps claiming a preference nothing reads.
    @Test("version 4 drops the withdrawn settings from the stored blob")
    func v4RemovesWithdrawnKeys() throws {
        let json = """
        {"schemaVersion":3,"showMenuBarIcon":false,"suppressSystemHUDs":true,"delightEnabled":false}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)

        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        #expect(object["delightEnabled"] == nil)
    }

    /// **The one that matters now `suppressSystemHUDs` is a live setting again.**
    ///
    /// This file says `true`. It was written when the switch could not move anything —
    /// `SystemHUDSuppression` suppressed nothing on macOS 26 — so it is an answer about a control
    /// that did nothing, not consent to hand Isleta the volume keys. Schema 23 clears the key so the
    /// decoder falls back to `false`, which is where CLAUDE.md requires suppression to start.
    ///
    /// If this ever fails, somebody upgrading from a 1.x install silently loses their volume keys on
    /// first launch, and the only clue is a switch they never touched.
    @Test("a v3 file that asked to hide the HUD does not consent to replacing it")
    func staleSuppressionIsNotConsent() throws {
        let json = """
        {"schemaVersion":3,"suppressSystemHUDs":true}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.suppressSystemHUDs == false)
    }

    /// And a fresh install starts there too, which is the same rule stated without a migration in
    /// front of it.
    @Test("suppression is off in the shipped defaults")
    func suppressionIsOffByDefault() {
        #expect(IsletaConfiguration.defaults.suppressSystemHUDs == false)
    }

    /// The migrator runs on the raw object, which is the only place the withdrawn keys are still
    /// visible — by the time `Codable` has been through it they are indistinguishable from keys that
    /// were never there.
    @Test("the v3 to v4 step deletes the keys from the object it is handed")
    func v4StepDeletesKeysFromTheRawObject() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 3,
            "suppressSystemHUDs": true,
            "delightEnabled": false,
            "showMenuBarIcon": true,
        ])
        #expect(migrated["suppressSystemHUDs"] == nil)
        #expect(migrated["delightEnabled"] == nil)
        #expect(migrated["showMenuBarIcon"] as? Bool == true)
        #expect(migrated["schemaVersion"] as? Int == IsletaConfiguration.currentSchemaVersion)
    }

    /// The one outcome of the v5 step that must not be got wrong. Isleta has no Dock icon, so a
    /// user upgrading from any build before v5 whose icon vanished would be left with an app they
    /// cannot open Settings on, cannot reach the Setup Guide in, and cannot quit from a menu.
    @Test("a file from before the menu bar setting keeps its status item")
    func v5AbsentKeyKeepsTheIcon() throws {
        let json = """
        {"schemaVersion":4,"automaticUpdateChecks":false}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.showMenuBarIcon == true)
        #expect(decoded.automaticUpdateChecks == false)
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)
    }

    /// The whole reason `removeNonBooleans` cannot be written as `stored is Bool`: after
    /// `JSONSerialization` both `1` and `true` are `NSNumber`, and Swift bridges the first to `Bool`
    /// happily. A step that used `is Bool` would delete neither and this test would pass while the
    /// blob went on holding a value nothing reads.
    @Test("version 5 drops a menu bar setting that is not a boolean")
    func v5RemovesNonBooleanIcon() {
        for wrong in [ "false" as Any, 0 as Any, 1 as Any, [ "on": true ] as Any ] {
            let migrated = SettingsMigration.migrate(["schemaVersion": 4, "showMenuBarIcon": wrong])
            #expect(migrated["showMenuBarIcon"] == nil)
        }
    }

    /// The complement of the test above: a real boolean is the one thing the step must leave alone,
    /// in both directions. Deleting `false` would silently turn the icon back on for every user who
    /// had hidden it.
    @Test("version 5 keeps a menu bar setting that is a real boolean")
    func v5KeepsBooleanIcon() throws {
        for stored in [true, false] {
            let migrated = SettingsMigration.migrate(["schemaVersion": 4, "showMenuBarIcon": stored])
            #expect(migrated["showMenuBarIcon"] as? Bool == stored)

            let json = """
            {"schemaVersion":4,"showMenuBarIcon":\(stored)}
            """
            #expect(try SettingsMigration.decode(Data(json.utf8)).showMenuBarIcon == stored)
        }
    }

    /// A user who ran a newer build and went back. Refusing to read the file would reset every
    /// setting they have; reading what we understand costs them only the settings this build has
    /// never heard of.
    @Test("a file from a newer Isleta is read, not rejected")
    func newerVersionIsReadLeniently() throws {
        let json = """
        {"schemaVersion":99,"showMenuBarIcon":false,"automaticUpdateChecks":false,
         "somethingFromTheFuture":{"nested":true}}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.automaticUpdateChecks == false)
        // Not rewritten downwards: the version it claims is preserved through the read, and only a
        // save re-stamps it.
        #expect(decoded.schemaVersion == 99)
    }

    @Test("migration is idempotent")
    func migratingTwiceChangesNothing() throws {
        let data = try SettingsMigration.encode(.defaults)
        let once = try SettingsMigration.decode(data)
        let twice = try SettingsMigration.decode(try SettingsMigration.encode(once))
        #expect(once == twice)
    }

    @Test("bytes that are not JSON throw rather than decoding to nonsense")
    func corruptDataThrows() {
        #expect(throws: (any Error).self) {
            try SettingsMigration.decode(Data("not json at all".utf8))
        }
    }

    @Test("JSON that is not an object throws")
    func nonObjectJSONThrows() {
        #expect(throws: SettingsMigration.Failure.notAJSONObject) {
            try SettingsMigration.decode(Data("[1,2,3]".utf8))
        }
    }
    // MARK: - Version 14

    /// The upgrade that split one HUD switch into a master and three. Nothing moves and nothing is
    /// discarded: `systemHUDs` keeps its name and its meaning, and the three new keys are absent
    /// from a v13 file and default to on — so a user who had the HUDs on still gets all four levels.
    @Test("a file from before the three HUD switches keeps every level")
    func v14AbsentKeysKeepEveryLevel() throws {
        for stored in [true, false] {
            let json = """
            {"schemaVersion":13,"sources":{"systemHUDs":\(stored)}}
            """
            let decoded = try SettingsMigration.decode(Data(json.utf8))
            #expect(decoded.sources.systemHUDs == stored)
            #expect(decoded.sources.enabledHUDs == Set(SystemHUD.allCases))
        }
    }

    /// Why the step exists rather than being left to the lenient decoder. A wrongly-typed key
    /// decodes as *absent*, which for these three means the HUD the user switched off comes back on
    /// while the file goes on claiming it is off — and `defaults write` is one flag away from
    /// writing `false` as a string.
    @Test("version 14 drops HUD level flags that are not booleans")
    func v14RemovesNonBooleanLevels() {
        for wrong in ["false" as Any, 0 as Any, 1 as Any, ["on": true] as Any] {
            let migrated = SettingsMigration.migrate([
                "schemaVersion": 13,
                "sources": ["volumeHUD": wrong, "displayBrightnessHUD": wrong],
            ])
            let sources = migrated["sources"] as? [String: Any]
            #expect(sources?["volumeHUD"] == nil)
            #expect(sources?["displayBrightnessHUD"] == nil)
        }
    }

    /// The complement, in both directions: deleting a real `false` would silently turn a HUD the
    /// user had switched off back on.
    @Test("version 14 keeps HUD level flags that are real booleans")
    func v14KeepsBooleanLevels() throws {
        for stored in [true, false] {
            let migrated = SettingsMigration.migrate([
                "schemaVersion": 13,
                "sources": ["displayBrightnessHUD": stored],
            ])
            #expect((migrated["sources"] as? [String: Any])?["displayBrightnessHUD"] as? Bool == stored)

            let json = """
            {"schemaVersion":13,"sources":{"displayBrightnessHUD":\(stored)}}
            """
            let decoded = try SettingsMigration.decode(Data(json.utf8))
            #expect(decoded.sources.displayBrightnessHUD == stored)
            #expect(decoded.sources.enabledHUDs.contains(.brightness) == stored)
        }
    }


    // MARK: - Version 18

    /// A **real** v17 record, taken off a machine that had been running 2.0 for a fortnight and
    /// anonymised only in the city. It is here rather than a hand-built minimal blob because the
    /// thing schema 18 can get wrong is not any one key — it is losing something in the shuffle
    /// while eighteen others are being deleted, and a fixture with one field in it cannot catch that.
    ///
    /// Every assertion below is something a user would notice the loss of on their next launch.
    @Test("a real v17 file keeps everything the user chose")
    func v17FileSurvivesIntact() throws {
        let json = """
        {"activityDwellScale":1,"appearance":{"albumColor":true,"animationSpeed":1,\
        "compactIsland":false,"hiddenApplications":["com.apple.Keynote","com.apple.Safari"],\
        "islandHeightAdjustment":0,"islandWidthAdjustment":0,\
        "minimalOnSynthesizedDisplays":true,"shadow":true,"style":"automatic"},\
        "automaticUpdateChecks":true,"glance":{"city":"Lisbon","includedCalendarIDs":["work"],\
        "temperatureUnit":"fahrenheit","usesCurrentLocation":true},"hapticsEnabled":true,\
        "hoverDelay":0,"notifications":{"groupsBursts":true,"hidesSystemBanners":true,\
        "mutedApps":["slack"],"showsLinkPreviews":true,"soundApps":{}},\
        "peekScale":0.9878573158914729,"playerBar":{"displays":"all","isEnabled":true,\
        "position":"topTrailing","showsWhenNothingIsPlaying":true},"playsLockScreenSounds":true,\
        "schemaVersion":17,"shortcuts":{"assignments":{"toggleIsland":{"carbonModifiers":6400,\
        "keyCode":34},"openShelf":{"carbonModifiers":256,"keyCode":1}}},"showMenuBarIcon":true,\
        "showsNowPlayingOnLockScreen":true,"sides":{"assignments":{"nowPlaying":"leading"},\
        "mirrored":false},"sources":{"appSwitcher":true,"bluetoothDevices":true,\
        "calendarAlerts":true,"calls":true,"displayBrightnessHUD":true,"dropActions":true,\
        "glance":true,"keyboardBrightnessHUD":false,"meetings":true,"notifications":true,\
        "nowPlaying":true,"power":true,"respectsFocus":true,"screenSharing":true,\
        "systemHUDs":true,"timers":true,"transfers":true,"volumeHUD":true,"welcomeBack":true},\
        "synthesizedIslandOpacity":1,"welcomeBackMinimumAbsence":282.2966834500876}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        // The lift. Without `migrateV17ToV18` these two come back empty and false, and the first is
        // a settings file that looks like the update reset it.
        #expect(decoded.hiddenApplications == ["com.apple.Keynote", "com.apple.Safari"])
        #expect(decoded.minimalOnSynthesizedDisplays)

        // The rebound island toggle — ⌃⌥⌘I moved to another key. There is no way back into an app
        // with no Dock icon if this is dropped.
        #expect(decoded.toggleHotKey.keyCode == 34)
        #expect(decoded.toggleHotKey.carbonModifiers == 6400)
        // And the retired one is gone rather than left claiming a system-wide key with no case to
        // decode it into and no row to clear it from.
        #expect(decoded.shortcuts.active.map(\.action) == [.toggleIsland])

        #expect(decoded.glance.city == "Lisbon")
        #expect(decoded.glance.includedCalendarIDs == ["work"])
        // The keyboard-backlight flag this Mac had switched off has nothing left to switch — the
        // level went with schema 18, so the key is swept and the other two are untouched.
        #expect(decoded.sources.volumeHUD)
        #expect(decoded.sources.displayBrightnessHUD)
        #expect(decoded.showsNowPlayingOnLockScreen)
        #expect(decoded.showMenuBarIcon)
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)
    }

    /// The retired keys leave the blob rather than riding along in every future save. Leniency would
    /// already read the file correctly, so the assertion that matters is about the **re-encoded
    /// bytes** — the same shape `v4RemovesWithdrawnKeys` pins, for the same reason.
    @Test("version 18 drops every withdrawn key from the stored blob")
    func v18RemovesWithdrawnKeys() throws {
        let json = """
        {"schemaVersion":17,"appearance":{"style":"liquidGlass","shadow":true},"sides":{"mirrored":true},\
        "hapticsEnabled":false,"hoverDelay":0.4,"peekScale":1.8,"activityDwellScale":2,\
        "welcomeBackMinimumAbsence":600,"synthesizedIslandOpacity":0.5,"playsLockScreenSounds":true,\
        "glance":{"temperatureUnit":"celsius"},"notifications":{"groupsBursts":false},\
        "playerBar":{"position":"topLeading","showsWhenNothingIsPlaying":false}}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        for retired in [
            "appearance", "sides", "hapticsEnabled", "hoverDelay", "peekScale", "activityDwellScale",
            "welcomeBackMinimumAbsence", "synthesizedIslandOpacity", "playsLockScreenSounds",
        ] {
            #expect(object[retired] == nil, "\(retired) is still in the saved blob")
        }
        #expect((object["sources"] as? [String: Any])?["keyboardBrightnessHUD"] == nil)
        #expect((object["glance"] as? [String: Any])?["temperatureUnit"] == nil)
        // The two keys schema 18 stripped from `playerBar` outlived it by three versions; schema 21
        // takes the record itself.
        #expect(object["playerBar"] == nil)
    }

    /// A hand-edited `hiddenApplications` holding something other than strings must not reach the
    /// lift as a half-read array — the silent-unhiding failure again, one layer down.
    @Test("version 18 lifts only the identifiers that are actually strings")
    func v18LiftIsTypeChecked() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 17,
            "appearance": [
                "hiddenApplications": ["com.apple.Keynote", 42, "com.apple.Safari"],
                "minimalOnSynthesizedDisplays": "yes please",
            ],
        ])
        #expect(migrated["hiddenApplications"] as? [String] == ["com.apple.Keynote", "com.apple.Safari"])
        #expect(migrated["minimalOnSynthesizedDisplays"] == nil)
    }

    // MARK: - Version 19

    /// The switcher's two keys leave the file, and the shortcut is the one that would do damage.
    ///
    /// `Shortcuts` registers whatever `assignments` holds and `ShortcutAction` has no case to decode
    /// this into any more, so a binding left behind would go on being claimed from every other app
    /// on the Mac at every launch, with no row in the settings window to clear it from.
    @Test("version 19 drops the app switcher's flag and its binding")
    func v19RemovesTheSwitcher() throws {
        let json = """
        {"schemaVersion":18,"sources":{"appSwitcher":true,"nowPlaying":true},\
        "shortcuts":{"assignments":{"toggleIsland":{"carbonModifiers":6400,"keyCode":34},\
        "appSwitcher":{"carbonModifiers":2048,"keyCode":48}}}}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.shortcuts.active.map(\.action) == [.toggleIsland])
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)

        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        #expect((object["sources"] as? [String: Any])?["appSwitcher"] == nil)
        let assignments = (object["shortcuts"] as? [String: Any])?["assignments"] as? [String: Any]
        #expect(assignments?["appSwitcher"] == nil)
        // The rest of the record is untouched.
        #expect((object["sources"] as? [String: Any])?["nowPlaying"] as? Bool == true)
        #expect(assignments?["toggleIsland"] != nil)
    }

    // MARK: - Version 20

    /// Notifications are withdrawn, and every key that only ever configured them leaves the file.
    ///
    /// Leniency would already read this file correctly, so the assertion that matters is about the
    /// **re-encoded bytes** — the same shape `v19RemovesTheSwitcher` pins, for the same reason:
    /// *ignored* and *gone* are different states of the file, and a record that survives every
    /// future save leaves the next reader working out which keys are live.
    @Test("version 20 drops the notification record and the source's flag")
    func v20RemovesNotifications() throws {
        let json = """
        {"schemaVersion":19,"notifications":{"hidesSystemBanners":true,"mutedApps":["slack"],\
        "soundApps":{"slack":"Ping"}},"sources":{"notifications":true,"nowPlaying":true},\
        "showMenuBarIcon":true}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)

        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        #expect(object["notifications"] == nil)
        #expect((object["sources"] as? [String: Any])?["notifications"] == nil)
        // The rest of the record is untouched.
        #expect((object["sources"] as? [String: Any])?["nowPlaying"] as? Bool == true)
        #expect(object["showMenuBarIcon"] as? Bool == true)
    }

    /// The parked defaults key goes with the record it fed.
    ///
    /// It is the one piece of this that is **a list of the apps a person chose to silence**. Left
    /// alone it outlives the app's own record, and nothing that could read it exists any more.
    @Test("version 20 clears the parked notification-preferences defaults key")
    func v20ClearsTheParkedKey() throws {
        let key = "com.tryisleta.notifications.preferences"
        UserDefaults.standard.set(Data(#"{"mutedApps":["slack"]}"#.utf8), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = try SettingsMigration.decode(Data(#"{"schemaVersion":19}"#.utf8))
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }

    // MARK: - Version 21

    /// The player bar is withdrawn, and the record that configured it leaves the file.
    ///
    /// Leniency would already read this file correctly, so the assertion that matters is about the
    /// **re-encoded bytes** — the same shape `v20RemovesNotifications` pins, for the same reason:
    /// *ignored* and *gone* are different states of the file.
    @Test("version 21 drops the player bar's record")
    func v21RemovesThePlayerBar() throws {
        let json = """
        {"schemaVersion":20,"playerBar":{"displays":"all","isEnabled":true},\
        "sources":{"nowPlaying":true},"showMenuBarIcon":true}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)

        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        #expect(object["playerBar"] == nil)
        // The rest of the record is untouched.
        #expect((object["sources"] as? [String: Any])?["nowPlaying"] as? Bool == true)
        #expect(object["showMenuBarIcon"] as? Bool == true)
    }

    /// The parked defaults key goes with the record it fed.
    ///
    /// `migrateV12ToV13` deliberately left it in place for a downgrade. There is no build left to
    /// downgrade to that would draw a bar from it.
    @Test("version 21 clears the parked player-bar defaults key")
    func v21ClearsTheParkedKey() throws {
        let key = "com.tryisleta.isleta.playerbar"
        UserDefaults.standard.set(Data(#"{"isEnabled":true}"#.utf8), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = try SettingsMigration.decode(Data(#"{"schemaVersion":20}"#.utf8))
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }

    // MARK: - Version 22

    /// Downloads are withdrawn, and the switch that gated them leaves the file.
    ///
    /// `ActivityKind.transfer` went with the source, so there is no kind left for this flag to
    /// gate. Leniency would already read the file correctly, so the assertion that matters is about
    /// the **re-encoded bytes** — the same shape `v21RemovesThePlayerBar` pins, for the same
    /// reason: *ignored* and *gone* are different states of the file.
    @Test("version 22 drops the downloads switch")
    func v22RemovesDownloads() throws {
        let json = """
        {"schemaVersion":21,"sources":{"transfers":true,"nowPlaying":true},"showMenuBarIcon":true}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.schemaVersion == IsletaConfiguration.currentSchemaVersion)

        let object = try #require(
            try JSONSerialization.jsonObject(with: SettingsMigration.encode(decoded)) as? [String: Any]
        )
        #expect((object["sources"] as? [String: Any])?["transfers"] == nil)
        // The rest of the record is untouched.
        #expect((object["sources"] as? [String: Any])?["nowPlaying"] as? Bool == true)
        #expect(object["showMenuBarIcon"] as? Bool == true)
    }

    /// The parked defaults key goes with the source it fed.
    ///
    /// It is the note that the user once granted Isleta their Downloads folder, and nothing in the
    /// app can read it now. The TCC grant itself is macOS's record and is not ours to revoke.
    @Test("version 22 clears the parked downloads-access defaults key")
    func v22ClearsTheParkedKey() throws {
        let key = "com.tryisleta.transfers.downloadsFolderAllowed"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = try SettingsMigration.decode(Data(#"{"schemaVersion":21}"#.utf8))
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
