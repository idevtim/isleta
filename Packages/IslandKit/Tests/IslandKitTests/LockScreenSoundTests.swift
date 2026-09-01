import Testing

@testable import IslandKit

/// The one sound the lock screen makes — at the unlock. The lock's went on 2026-08-26.
@Suite("Lock screen sound")
@MainActor
struct LockScreenSoundTests {

    /// A player that records names instead of making a noise, so the behavior is provable without
    /// a speaker — and without a test suite that beeps.
    private func recorder(succeeds: Bool = true) -> (LockScreenSound, () -> [LockScreenSound.Moment]) {
        final class Box { var moments: [LockScreenSound.Moment] = [] }
        let box = Box()
        let sound = LockScreenSound { moment in
            box.moments.append(moment)
            return succeeds
        }
        return (sound, { box.moments })
    }

    /// **The gate.** Sound is the most intrusive thing an app can do unasked, so nothing is played
    /// unless the user has said so — and the switch is checked at the moment of playing rather than
    /// cached, so turning it off is immediate.
    @Test("nothing is played unless the user asked for it")
    func silentUnlessEnabled() {
        let (sound, names) = recorder()
        sound.play(.unlocked, isEnabled: false)
        #expect(names().isEmpty)
        #expect(sound.playedCount == 0)
    }

    @Test("unlocking plays its sound")
    func unlockPlays() {
        let (sound, names) = recorder()
        sound.play(.unlocked, isEnabled: true)
        #expect(names() == [.unlocked])
        #expect(sound.playedCount == 1)
    }

    /// The bundled file is the app shell's to carry; this package only knows its name. Pinned so a
    /// rename in `Isleta/Resources` fails here rather than falling silently back to the system
    /// sound on every unlock.
    @Test("the bundled file has the name the app ships")
    func bundledFileName() {
        let file = LockScreenSound.Moment.unlocked.resource
        #expect(file.name == "Unlocked")
        #expect(file.extension == "wav")
    }

    /// The fallback is a system sound — a name that is not in `/System/Library/Sounds` would be
    /// silence with nothing to explain it.
    @Test("the fallback is one macOS ships")
    func soundIsASystemSound() {
        let shipped: Set<String> = [
            "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
            "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ]
        #expect(shipped.contains(LockScreenSound.Moment.unlocked.soundName))
    }

    /// A retired sound name is counted rather than swallowed — the only tell that macOS has dropped
    /// one from under us.
    @Test("a sound that will not play is counted")
    func unresolvedIsCounted() {
        let (sound, _) = recorder(succeeds: false)
        sound.play(.unlocked, isEnabled: true)
        #expect(sound.unresolvedCount == 1)
        #expect(sound.playedCount == 0)
    }
}
