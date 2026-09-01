import Foundation
import IslandActivities
import Testing

@testable import IslandSettings

/// Per-source switches (§8.1.4). The interesting failures are all about *storage*: a record written
/// by a build that did not have one of these flags, and a kind added later with nowhere to go.
@Suite("Source toggles")
struct SourceTogglesTests {

    @Test("every source ships on")
    func defaultsAreOn() {
        let toggles = SourceToggles()
        #expect(toggles.nowPlaying)
        #expect(toggles.systemHUDs)
        #expect(toggles.welcomeBack)
    }

    // MARK: - Inside the HUD source

    /// The three finer switches ship on, for the reason at the top of `SourceToggles`: a level the
    /// user has not heard of that is off by default is a feature they never find. An upgrade from a
    /// build that had one switch must therefore look identical.
    @Test("both HUD levels ship on")
    func hudLevelsShipOn() {
        let toggles = SourceToggles()
        #expect(toggles.volumeHUD)
        #expect(toggles.displayBrightnessHUD)
        #expect(toggles.enabledHUDs == Set(SystemHUD.allCases))
    }

    /// Mute rides volume's switch. A build where it did not would show a crossed-out speaker for a
    /// keypress whose bar had been suppressed — see `SourceToggles.volumeHUD`.
    @Test("mute follows the volume switch")
    func muteFollowsVolume() {
        var toggles = SourceToggles()
        toggles.volumeHUD = false
        #expect(!toggles.enabledHUDs.contains(.volume))
        #expect(!toggles.enabledHUDs.contains(.mute))
        #expect(toggles.enabledHUDs == [.brightness])
        #expect(SourceToggles.keyPath(for: .mute) == SourceToggles.keyPath(for: .volume))
    }

    @Test("each level answers its own flag", arguments: SystemHUD.allCases)
    func levelsAnswerTheirOwnFlag(hud: SystemHUD) {
        var configuration = IsletaConfiguration()
        configuration[keyPath: SourceToggles.keyPath(for: hud)] = false
        #expect(!configuration.sources.enabledHUDs.contains(hud))

        // Exactly the levels sharing that flag moved, and nothing else.
        let moved = SystemHUD.allCases.filter { !configuration.sources.enabledHUDs.contains($0) }
        let sharing = SystemHUD.allCases.filter {
            SourceToggles.keyPath(for: $0) == SourceToggles.keyPath(for: hud)
        }
        #expect(moved == sharing)
    }

    /// The master and the three are different questions, and the hub asks them in different places:
    /// `subscript(_:)` decides whether the source runs at all, `enabledHUDs` decides what it reports.
    /// Folding one into the other would leave a source stopped by a flag that is not its row's
    /// switch.
    @Test("the two levels do not move the master switch")
    func levelsDoNotMoveTheMaster() {
        var toggles = SourceToggles()
        toggles.volumeHUD = false
        toggles.displayBrightnessHUD = false
        #expect(toggles.systemHUDs)
        #expect(toggles[.systemHUD])
        #expect(toggles.enabledHUDs.isEmpty)
    }

    /// The upgrade path in one assertion: a stored record written before the three flags existed
    /// keeps whatever the user chose for the source and gets every level.
    @Test("a record with only the old flag decodes to all four levels")
    func legacyRecordKeepsEveryLevel() throws {
        for stored in [true, false] {
            let json = "{\"systemHUDs\":\(stored)}"
            let decoded = try JSONDecoder().decode(SourceToggles.self, from: Data(json.utf8))
            #expect(decoded.systemHUDs == stored)
            #expect(decoded.enabledHUDs == Set(SystemHUD.allCases))
        }
    }

    /// The subscript is what removes string matching from the app shell. If it ever disagreed with
    /// the stored properties, a user switching Now Playing off would stop the HUDs instead.
    @Test("the subscript reaches the same flag the property does", arguments: ActivityKind.allCases)
    func subscriptMatchesProperties(kind: ActivityKind) {
        var toggles = SourceToggles()
        // Written as "the other value" rather than as `false`, so that a flag which ships off would
        // still be moved by this test. Writing `false` over an already-false flag moves nothing and
        // makes the test pass by asserting that a write did what it always did — the shape of a
        // test that has quietly stopped checking anything.
        let flipped = !SourceToggles()[kind]
        toggles[kind] = flipped

        // Two kinds have no source and no flag: they read true and cannot be switched off.
        // `.shelf` is published from a drag session in the app shell, and `.focusChanged` has no
        // publisher at all and cannot get one — macOS raises no notification when a Focus changes,
        // so the only way to announce it would be a poll (see `SourceToggles.respectsFocus`, which
        // is what that slot became). Asserted rather than skipped, because "the write silently did
        // nothing" is only correct while it is deliberate — the day either gets a flag, this fails
        // and says so.
        guard kind != .shelf, kind != .focusChanged else {
            #expect(toggles[kind])
            #expect(toggles == SourceToggles())
            return
        }

        #expect(toggles[kind] == flipped)
        // Exactly one flag moved.
        let changed = ActivityKind.allCases.filter { toggles[$0] != SourceToggles()[$0] }
        #expect(changed == [kind])
    }

    /// Key paths and the subscript have to name the same flag, or the settings switch writes one
    /// thing and the app shell reads another — a toggle that appears to do nothing until relaunch.
    @Test("the settings key path and the subscript agree", arguments: ActivityKind.allCases)
    func keyPathMatchesSubscript(kind: ActivityKind) throws {
        guard let keyPath = SourceToggles.keyPath(for: kind) else {
            #expect(kind == .shelf || kind == .focusChanged)
            return
        }
        var configuration = IsletaConfiguration()
        configuration[keyPath: keyPath] = false
        #expect(configuration.sources[kind] == false)
    }

    /// The reason the decoder is hand-written. A blob from a build that only knew about two of these
    /// must cost the user those two settings and nothing else — the synthesised all-or-nothing
    /// decode would throw and reset every source back on.
    @Test("a record missing some flags keeps the ones it has")
    func partialRecordDecodesPerKey() throws {
        let json = #"{"nowPlaying":false,"timers":false}"#
        let toggles = try JSONDecoder().decode(SourceToggles.self, from: Data(json.utf8))
        #expect(toggles.nowPlaying == false)
        #expect(toggles.timers == false)
        #expect(toggles.systemHUDs)
        #expect(toggles.welcomeBack)
    }

    /// One unreadable flag must not take the other three with it. This is the same guarantee
    /// `IsletaConfiguration` makes, one level down — and it only holds because `SourceToggles` has
    /// its own lenient decoder rather than relying on its parent's.
    @Test("a malformed flag falls back alone")
    func malformedFlagFallsBackAlone() throws {
        let json = #"{"nowPlaying":"yes please","welcomeBack":false}"#
        let toggles = try JSONDecoder().decode(SourceToggles.self, from: Data(json.utf8))
        #expect(toggles.nowPlaying)
        #expect(toggles.welcomeBack == false)
    }

    /// The nested value has to survive the same route the real configuration takes — raw JSON,
    /// through the migration chain, into `IsletaConfiguration`.
    @Test("toggles round-trip through the migration chain")
    func roundTripsThroughMigration() throws {
        var configuration = IsletaConfiguration()
        configuration.sources.systemHUDs = false
        configuration.sources.timers = false

        let decoded = try SettingsMigration.decode(SettingsMigration.encode(configuration))
        #expect(decoded.sources == configuration.sources)
    }

    /// A settings file written before per-source switches existed. It has no `sources` key at all,
    /// and every source must come back on rather than the whole record failing to read.
    @Test("a pre-toggles settings file reads with every source on")
    func recordWithoutSourcesKeyDefaultsToOn() throws {
        let json = #"{"schemaVersion":1,"showMenuBarIcon":false,"automaticUpdateChecks":true}"#
        let configuration = try SettingsMigration.decode(Data(json.utf8))
        #expect(configuration.sources == SourceToggles())
        #expect(configuration.showMenuBarIcon == false)
    }

    /// The store's equality check is what stops a change handler that writes back from recursing,
    /// and it now has to see through a nested value.
    @Test("changing one source is a change the store notices")
    @MainActor
    func storeNoticesASourceChange() {
        let store = SettingsStore(storage: InMemorySettingsStorage())
        var seen: [SourceToggles] = []
        store.addChangeHandler { seen.append($0.sources) }

        store.update { $0.sources.nowPlaying = false }
        store.update { $0.sources.nowPlaying = false }

        #expect(seen.count == 1)
        #expect(seen.first?.nowPlaying == false)
    }
}

/// The Sources pane's three non-sources, and the flag that changed meaning under them.
@Suite("The Sources pane's extras")
struct SourcesPaneStateTests {

    // MARK: - respectsFocus

    @Test("a Focus quiets the island unless the user says otherwise")
    func respectsFocusDefaultsOn() {
        // On by default is not a taste — it is what every build before this switch existed did.
        // `FocusGate` has suppressed calendar alerts during a Focus since Stage 2 with no way to say
        // no, so a default of off would be an upgrade that changed what the island does.
        #expect(SourceToggles().respectsFocus)
    }

    @Test("a v10 file's dead focusChanges value is not carried into respectsFocus")
    func theDeadFlagIsNotInherited() throws {
        // The trap this exists to catch. `focusChanges` meant "announce a Focus turning on", which
        // macOS cannot tell us about, so nothing ever read it and whatever is in a user's file is a
        // preference they could not express or observe. Carrying a meaningless `false` across would
        // turn Focus suppression **off** for every existing user, silently, in an upgrade.
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 10,
            "sources": ["focusChanges": false, "nowPlaying": false],
        ])
        let decoded = try SettingsMigration.decode(blob)
        #expect(decoded.sources.respectsFocus)
        // The rest of the record is untouched.
        #expect(decoded.sources.nowPlaying == false)
    }

    @Test("the dead key is dropped rather than left in the file")
    func theDeadKeyIsRemoved() {
        var object: [String: Any] = ["sources": ["focusChanges": true, "nowPlaying": true]]
        SettingsMigration.migrateV10ToV11(&object)
        let sources = object["sources"] as? [String: Any]
        #expect(sources?["focusChanges"] == nil)
        // Nothing else in the object is disturbed — the step removes one key and sweeps one type.
        #expect(sources?["nowPlaying"] as? Bool == true)
    }

    @Test("a wrongly-typed respectsFocus is dropped so leniency can answer")
    func aStringIsNotABool() {
        // `defaults write` is one flag away from putting the string "false" where a Bool belongs,
        // and a wrongly-typed key decodes as absent — which here means Focus suppression comes back
        // on while the record goes on claiming it is off.
        var object: [String: Any] = ["sources": ["respectsFocus": "false"]]
        SettingsMigration.migrateV10ToV11(&object)
        #expect((object["sources"] as? [String: Any])?["respectsFocus"] == nil)
    }

    @Test("a user who turned it off keeps it off")
    func aRealChoiceSurvives() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 11,
            "sources": ["respectsFocus": false],
        ])
        #expect(try SettingsMigration.decode(blob).sources.respectsFocus == false)
    }

    // MARK: - The pane's copy

    @Test("every Focus state has its own sentence, including the one that is not a refusal")
    func focusCopyIsDistinct() {
        // `unavailable` is a build problem rather than a user one. A card that said "not granted"
        // there would send somebody to System Settings to look for a row that is not in the list.
        let all: [SourcesPaneState.FocusAccess] = [.granted, .notDetermined, .denied, .unavailable]
        let sentences = all.map { SourcesPaneState(focusAccess: $0).focusSummary }
        #expect(Set(sentences).count == all.count)
    }

    @Test("no offer is made where a prompt would not show")
    func thereIsNoControlRatherThanADeadOne() {
        // §10, enforced by there being nothing to click. The app shell builds these closures only in
        // the one state each dialog would appear in; the default record is what a preview and a test
        // get, and it must offer nothing at all.
        let state = SourcesPaneState()
        #expect(state.requestFocusAccess == nil)
    }
}
