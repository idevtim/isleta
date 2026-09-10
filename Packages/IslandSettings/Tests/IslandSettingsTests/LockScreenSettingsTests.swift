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

    // MARK: - Schema 26: the unlock sound comes back out of the card

    /// A new install is silent, which is the answer the fold gave too — the card it was folded into
    /// is off by default, so nothing has changed for anybody installing Isleta for the first time.
    @Test("a fresh install makes no sound at the unlock")
    func unlockSoundDefaultsToOff() {
        #expect(!IsletaConfiguration.defaults.playsUnlockSound)
    }

    /// **The half that cannot be left to the decoder.** Between schemas 18 and 25 the card *was*
    /// the sound, so every Mac with the card on has been making it. Absent this seeding the new key
    /// would decode to its default and those Macs would simply go quiet on upgrade, with nothing
    /// anywhere saying why.
    @Test("an upgrade from the fold keeps the sound the card was making", arguments: [18, 20, 25])
    func upgradeSeedsTheSoundFromTheCard(version: Int) throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": version,
            "showsNowPlayingOnLockScreen": true,
        ])
        let decoded = try SettingsMigration.decode(blob)
        #expect(decoded.playsUnlockSound, "the sound survives the upgrade from \(version)")
        #expect(decoded.showsNowPlayingOnLockScreen)
    }

    /// The other direction, and the one that would be worse to get wrong: a Mac that has never made
    /// a sound must not start because a key appeared.
    @Test("an upgrade with the card off stays silent")
    func upgradeWithoutTheCardStaysSilent() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 25,
            "showsNowPlayingOnLockScreen": false,
        ])
        let decoded = try SettingsMigration.decode(blob)
        #expect(!decoded.playsUnlockSound)
    }

    /// A file that predates the card entirely has nothing to seed from, and silence is what those
    /// installs have always had.
    @Test("a file with no card key at all is left silent")
    func upgradeWithNoCardKeyStaysSilent() throws {
        let blob = try JSONSerialization.data(withJSONObject: ["schemaVersion": 15])
        let decoded = try SettingsMigration.decode(blob)
        #expect(!decoded.playsUnlockSound)
    }

    /// `defaults write` can put a string anywhere, and a string in the *source* of the seed would
    /// put one in the key being seeded. Both are dropped rather than copied.
    @Test("a hand-written non-boolean is dropped rather than seeded")
    func migrationDropsNonBooleanUnlockSound() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 25,
            "showsNowPlayingOnLockScreen": true,
            "playsUnlockSound": "false",
        ])
        // Dropped, and then seeded from the card — which is the honest answer for a value that
        // could not be read: what this Mac was actually doing before the upgrade.
        #expect(migrated["playsUnlockSound"] as? Bool == true)

        let fromString = SettingsMigration.migrate([
            "schemaVersion": 25,
            "showsNowPlayingOnLockScreen": "true",
        ])
        #expect(fromString["playsUnlockSound"] == nil)
    }

    /// A value this build wrote is never re-seeded: the step only fills a key that is not there, so
    /// somebody who turns the sound off keeps it off through every later launch.
    @Test("an answer already given is not overwritten by the card")
    func existingAnswerSurvives() {
        let migrated = SettingsMigration.migrate([
            "schemaVersion": 25,
            "showsNowPlayingOnLockScreen": true,
            "playsUnlockSound": false,
        ])
        #expect(migrated["playsUnlockSound"] as? Bool == false)
    }

    /// The combination the fold could not express, and the reason it was undone: the sound with no
    /// card, and the card with no sound. Both have to survive a round trip.
    @Test("the sound and the card are independent")
    func soundAndCardAreIndependent() throws {
        var soundOnly = IsletaConfiguration.defaults
        soundOnly.playsUnlockSound = true
        let decodedSoundOnly = try SettingsMigration.decode(SettingsMigration.encode(soundOnly))
        #expect(decodedSoundOnly.playsUnlockSound)
        #expect(!decodedSoundOnly.showsNowPlayingOnLockScreen)

        var cardOnly = IsletaConfiguration.defaults
        cardOnly.showsNowPlayingOnLockScreen = true
        let decodedCardOnly = try SettingsMigration.decode(SettingsMigration.encode(cardOnly))
        #expect(decodedCardOnly.showsNowPlayingOnLockScreen)
        #expect(!decodedCardOnly.playsUnlockSound)
    }

    @Test("turning the sound on is a named change")
    func soundChangeIsNamed() {
        var edited = IsletaConfiguration.defaults
        edited.playsUnlockSound = true
        let keys = IsletaConfiguration.changedKeys(from: .defaults, to: edited)
        #expect(keys.contains("playsUnlockSound"))
    }
}
