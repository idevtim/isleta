import Testing

@testable import IslandSources

/// The arithmetic Isleta has to get exactly right before it may swallow a volume key.
///
/// Every number here is Apple's, and the ones that matter are pinned to a reading rather than to an
/// assumption: `HUDConsumeSelfTest`'s control phase measured five presses moving 0.2000 → 0.5000 on
/// macOS 27.0, which fixes both the notch size and the snap-to-grid behaviour at once.
///
/// This suite is the reason `VolumeStep` has no I/O in it. Once the key is consumed Isleta owns the
/// whole behaviour, and "it felt about right when I pressed it" is not a check that survives a
/// refactor.
@Suite("Volume stepping")
struct VolumeStepTests {

    @Test("sixteen notches span the range")
    func notchCount() {
        #expect(VolumeStep.notch == 1.0 / 16.0)
        #expect(VolumeStep.fineNotch == 1.0 / 64.0)
    }

    /// **The measured case.** Five presses from 0.2 land on 0.5 — which only works if the first
    /// press snaps to the grid (0.25) rather than adding a notch to an off-grid value (0.2625).
    @Test("five presses from 0.2 reach 0.5, as measured on hardware")
    func matchesTheHardwareReading() {
        var volume = 0.2
        for _ in 0..<5 {
            volume = VolumeStep.apply(.up, volume: volume, isMuted: false).volume
        }
        #expect(abs(volume - 0.5) < 1e-9)
    }

    /// An off-grid level moves to the next notch, not to itself-plus-a-notch. A level set by a
    /// script or a slider drag is almost never a multiple of 1/16.
    @Test("an off-grid level snaps to the grid")
    func snapsToGrid() {
        #expect(abs(VolumeStep.apply(.up, volume: 0.2, isMuted: false).volume - 0.25) < 1e-9)
        #expect(abs(VolumeStep.apply(.down, volume: 0.2, isMuted: false).volume - 0.1875) < 1e-9)
    }

    /// A level already on a notch advances by one. `ceil` would leave it where it is, which is the
    /// bug this test exists to stop coming back.
    @Test("a level already on the grid still moves")
    func onGridStillMoves() {
        let up = VolumeStep.apply(.up, volume: 0.25, isMuted: false)
        #expect(abs(up.volume - 0.3125) < 1e-9)
        #expect(up.didChange)

        let down = VolumeStep.apply(.down, volume: 0.25, isMuted: false)
        #expect(abs(down.volume - 0.1875) < 1e-9)
        #expect(down.didChange)
    }

    @Test("⇧⌥ gives quarter notches")
    func fineSteps() {
        let outcome = VolumeStep.apply(.up, volume: 0.25, isMuted: false, fine: true)
        #expect(abs(outcome.volume - (0.25 + 1.0 / 64.0)) < 1e-9)
    }

    // MARK: - The three behaviours that are not arithmetic

    /// **Volume-up unmutes rather than raising.** The press is spent on the unmute and the level
    /// stays put; only the next one moves it. Get this wrong and a user presses volume-up once,
    /// watches the number climb, and hears nothing.
    @Test("volume-up while muted unmutes at the level it was already at")
    func volumeUpUnmutes() {
        let outcome = VolumeStep.apply(.up, volume: 0.5, isMuted: true)
        #expect(outcome.isMuted == false)
        #expect(outcome.volume == 0.5, "the press unmuted; it must not also raise")
        #expect(outcome.didChange)
        #expect(outcome.didReachLimit == false)
    }

    @Test("the press after an unmute raises normally")
    func secondPressRaises() {
        let first = VolumeStep.apply(.up, volume: 0.5, isMuted: true)
        let second = VolumeStep.apply(.up, volume: first.volume, isMuted: first.isMuted)
        #expect(abs(second.volume - 0.5625) < 1e-9)
    }

    /// Volume-down walks to zero and stops. Muted-at-a-level and silent-at-zero are different
    /// states, and collapsing them loses the level the user is muted *at*.
    @Test("volume-down never mutes")
    func volumeDownDoesNotMute() {
        var volume = 0.125
        var muted = false
        for _ in 0..<4 {
            let outcome = VolumeStep.apply(.down, volume: volume, isMuted: muted)
            volume = outcome.volume
            muted = outcome.isMuted
        }
        #expect(volume == 0)
        #expect(muted == false, "reaching zero is not muting")
    }

    @Test("mute toggles without touching the level")
    func muteTogglePreservesLevel() {
        let muted = VolumeStep.toggleMute(volume: 0.375, isMuted: false)
        #expect(muted.isMuted)
        #expect(muted.volume == 0.375)

        let unmuted = VolumeStep.toggleMute(volume: muted.volume, isMuted: muted.isMuted)
        #expect(unmuted.isMuted == false)
        #expect(unmuted.volume == 0.375, "unmuting returns you to where you were")
    }

    // MARK: - The ends

    /// `didChange` and `didReachLimit` are separate answers, and the island needs both: the rebound
    /// runs on the limit, and the HUD's content swap runs on the change. Volume-up at 1.0 is a limit
    /// that is not a change; an unmute is a change that is not a limit.
    @Test("the ends are reported as limits without being reported as changes")
    func limitsAreNotChanges() {
        let top = VolumeStep.apply(.up, volume: 1.0, isMuted: false)
        #expect(top.volume == 1.0)
        #expect(top.didChange == false)
        #expect(top.didReachLimit)

        let bottom = VolumeStep.apply(.down, volume: 0.0, isMuted: false)
        #expect(bottom.volume == 0.0)
        #expect(bottom.didChange == false)
        #expect(bottom.didReachLimit)
    }

    @Test("stepping never leaves the range")
    func staysInRange() {
        for start in stride(from: 0.0, through: 1.0, by: 1.0 / 64.0) {
            for direction in [VolumeStep.Direction.up, .down] {
                for fine in [true, false] {
                    let outcome = VolumeStep.apply(direction, volume: start, isMuted: false, fine: fine)
                    #expect(outcome.volume >= 0)
                    #expect(outcome.volume <= 1)
                }
            }
        }
    }

    /// A level out of range — which CoreAudio should never report and a fake certainly can — is
    /// clamped rather than propagated.
    @Test("an impossible level is clamped rather than trusted")
    func clampsBadInput() {
        #expect(VolumeStep.apply(.up, volume: 42, isMuted: false).volume == 1.0)
        #expect(VolumeStep.apply(.down, volume: -3, isMuted: false).volume == 0.0)
    }

    /// Sixteen presses cross the whole range from silence to full, which is the property a user
    /// actually feels: "about a dozen presses" is the wrong number and they notice.
    @Test("sixteen presses walk the whole range")
    func sixteenPressesCrossTheRange() {
        var volume = 0.0
        for _ in 0..<16 {
            volume = VolumeStep.apply(.up, volume: volume, isMuted: false).volume
        }
        #expect(abs(volume - 1.0) < 1e-9)
    }
}
