import Foundation
import Testing

@testable import IslandSettings

/// Schema 16, which adds `showsNowPlayingOnLockScreen`.
///
/// A one-field additive step, and it still gets a suite for the reason every step in
/// `SettingsMigration` gets one: the failure mode is silent. A field that decodes to the wrong
/// default does not crash, does not log, and does not look wrong in Settings — the user simply finds
/// a switch in a position they did not choose, in this case one that puts what they are listening to
/// on a screen a room can see.
@Suite("Lock screen settings")
struct LockScreenSettingsTests {

    /// **The direction that matters.** Every other additive field in this file defaults to whatever
    /// the previous build did, and for most of them that is "on". This one must default to **off**,
    /// and the temptation on the next release — now that it works — will be to flip it. It draws
    /// through a private, undocumented SkyLight space level and it shows the user's listening to
    /// anyone walking past; both are reasons for the user to have chosen it rather than inherited it.
    @Test("the lock screen card is off unless the user asked for it")
    func defaultsToOff() {
        #expect(!IsletaConfiguration.defaults.showsNowPlayingOnLockScreen)
    }

    /// A v15 file has no key at all. It must decode to off — which is also exactly what a v15 build
    /// did, since no build before 16 drew anything on the lock screen.
    @Test("a v15 file keeps the lock screen clear")
    func upgradeFromFifteenChangesNothing() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 15,
            "hapticsEnabled": true,
        ])
        let decoded = try SettingsMigration.decode(blob)
        #expect(!decoded.showsNowPlayingOnLockScreen)
    }

    /// `defaults write` is the documented way to inspect this blob, so the string "true" is a real
    /// thing a user types. It decodes as **absent**, which is off — a switch the user believes they
    /// set and which is not set. The step drops it so the value is honestly the default.
    @Test("a hand-written non-boolean is dropped by the v15 to v16 step")
    func migrationDropsNonBoolean() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 15,
            "showsNowPlayingOnLockScreen": "true",
        ])
        #expect(migrated["showsNowPlayingOnLockScreen"] == nil)
        #expect(migrated["schemaVersion"] as? Int == IsletaConfiguration.currentSchemaVersion)
    }

    /// A genuine boolean survives the step untouched, in both positions. The `false` case is not
    /// redundant with the default: a step that dropped it would look identical here and different
    /// on a downgrade, where the key is what a v15 build reads.
    @Test("a real boolean survives the step")
    func migrationKeepsBooleans() {
        for value in [true, false] {
            let migrated = SettingsMigration.migrate([
                "schemaVersion": 15,
                "showsNowPlayingOnLockScreen": value,
            ])
            #expect(migrated["showsNowPlayingOnLockScreen"] as? Bool == value)
        }
    }

    @Test("the setting round-trips through the record")
    func roundTrips() throws {
        var configuration = IsletaConfiguration.defaults
        configuration.showsNowPlayingOnLockScreen = true
        let blob = try SettingsMigration.encode(configuration)
        let decoded = try SettingsMigration.decode(blob)
        #expect(decoded.showsNowPlayingOnLockScreen)
    }

    /// The log records *that* it changed, so a support report says when the user turned it on.
    // MARK: - Schema 18: the sounds fold into the card

    /// Sound is the most intrusive thing an app can do unasked, so silence has to survive an
    /// upgrade from every version that had a separate switch for it.
    @Test("a Mac that never asked for the Lock Screen stays silent")
    func silentByDefault() {
        #expect(!IsletaConfiguration.defaults.showsNowPlayingOnLockScreen)
    }

    /// A v16 file has no sound key at all; a v17 file may have it either way. Both keep their card
    /// and both lose the separate answer, which is what the fold means.
    @Test("the card survives an upgrade from 16 and from 17, and the sound key goes")
    func upgradeFoldsTheSound() throws {
        for version in [16, 17] {
            let blob = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": version,
                "showsNowPlayingOnLockScreen": true,
                "playsLockScreenSounds": false,
            ])
            let decoded = try SettingsMigration.decode(blob)
            #expect(decoded.showsNowPlayingOnLockScreen, "the card survives the upgrade from \(version)")
        }
    }

    /// The one case the fold costs somebody: the sound without the card. It is stated in
    /// `IsletaConfiguration.showsNowPlayingOnLockScreen` rather than hidden, and pinned here so a
    /// later change to the step cannot quietly turn it into the card without the sound.
    @Test("a v17 file with the sound and no card ends up silent")
    func soundWithoutCardIsLost() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 17,
            "playsLockScreenSounds": true,
        ])
        let decoded = try SettingsMigration.decode(blob)
        #expect(!decoded.showsNowPlayingOnLockScreen)
    }

    @Test("the retired sound key is dropped by the v17 to v18 step")
    func soundKeyIsDropped() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 17,
            "playsLockScreenSounds": true,
        ])
        #expect(migrated["playsLockScreenSounds"] == nil)
        #expect(migrated["schemaVersion"] as? Int == IsletaConfiguration.currentSchemaVersion)
    }

    @Test("turning it on is a named change")
    func changeIsNamed() {
        var edited = IsletaConfiguration.defaults
        edited.showsNowPlayingOnLockScreen = true
        let keys = IsletaConfiguration.changedKeys(from: .defaults, to: edited)
        #expect(keys.contains("showsNowPlayingOnLockScreen"))
    }
}
