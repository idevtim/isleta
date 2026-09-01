import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// Which readings say they landed on the end of their range.
///
/// The decision lives in the two state machines because they are the only things that can see the
/// *previous* level and the reason for the new one. Both failure directions are user-visible: a
/// limit reported when the user did not run a level to its end bounces the island for nothing, and
/// one never reported means the bounce never fires.
@Suite("System HUD limits")
struct SystemHUDLimitTests {

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func baselined(volume: Double, muted: Bool = false) -> SystemHUDLevelState {
        var state = SystemHUDLevelState()
        state.rebase(to: SystemHUDAudioSnapshot(volume: volume, isMuted: muted))
        return state
    }

    // MARK: - Volume

    @Test("running the volume to the top reports the maximum")
    func volumeToTheTop() {
        var state = baselined(volume: 0.9)
        let reading = state.apply(SystemHUDAudioSnapshot(volume: 1, isMuted: false))
        #expect(reading?.limit == .maximum)
        #expect(reading?.activity.reachedLimit == .maximum)
    }

    @Test("running it to the bottom reports the minimum")
    func volumeToTheBottom() {
        var state = baselined(volume: 0.05)
        #expect(state.apply(SystemHUDAudioSnapshot(volume: 0, isMuted: false))?.limit == .minimum)
    }

    @Test("anywhere in between reports nothing")
    func middleOfTheRange() {
        var state = baselined(volume: 0.5)
        #expect(state.apply(SystemHUDAudioSnapshot(volume: 0.75, isMuted: false))?.limit == nil)
    }

    /// CoreAudio's own overshoot, which `ActivityValue.normalized` already clamps for the bar. The
    /// limit test has to be `>=` for the same reason, or full volume would never be full.
    @Test("a level slightly past the top is still the top")
    func coreAudioOvershoot() {
        var state = baselined(volume: 0.9)
        let reading = state.apply(SystemHUDAudioSnapshot(volume: 1.0000000149011612, isMuted: false))
        #expect(reading?.limit == .maximum)
    }

    /// **The case that decides where this logic lives.** Mute publishes level zero, and it is not a
    /// range being run to its end — derived from the number alone, the island would bounce every
    /// time anybody muted.
    @Test("muting is not reaching the bottom of a range")
    func muteIsNotALimit() {
        var state = baselined(volume: 0.4)
        let reading = state.apply(SystemHUDAudioSnapshot(volume: 0.4, isMuted: true))
        #expect(reading?.hud == .mute)
        #expect(reading?.level == 0)
        #expect(reading?.limit == nil)
    }

    /// Unmuting hands the user back the bar they came back to. If that level happens to be full, it
    /// is full — the reading is a volume reading again, and the same rules apply to it.
    @Test("unmuting to a full volume is the top of the range like any other")
    func unmutingToFull() {
        var state = baselined(volume: 1, muted: true)
        #expect(state.apply(SystemHUDAudioSnapshot(volume: 1, isMuted: false))?.limit == .maximum)
    }

    /// The eight duplicate callbacks one keypress delivers are dropped before any of this, so a
    /// single press at the top produces a single limit — not eight bounces.
    @Test("one keypress at the top is one reading")
    func duplicatesStillCollapse() {
        var state = baselined(volume: 0.9)
        let first = state.apply(SystemHUDAudioSnapshot(volume: 1, isMuted: false))
        #expect(first?.limit == .maximum)
        for _ in 0..<7 {
            #expect(state.apply(SystemHUDAudioSnapshot(volume: 1, isMuted: false)) == nil)
        }
    }

    /// **The platform constraint, written down where somebody will look for it.** Pressing volume-up
    /// at full volume changes nothing, so CoreAudio delivers no callback and Isleta never hears
    /// about it. The bounce answers *arriving* at the end of the range, not pushing against it — and
    /// no amount of work in this file can change that, because the event does not exist.
    @Test("pushing against a limit that is already reached is not observable")
    func pushingAgainstTheTopSaysNothing() {
        var state = baselined(volume: 1)
        #expect(state.apply(SystemHUDAudioSnapshot(volume: 1, isMuted: false)) == nil)
    }

    // MARK: - Brightness

    @Test("a brightness ramp reaching the top reports the maximum")
    func brightnessToTheTop() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.9)
        #expect(state.apply(1, at: Self.epoch)?.limit == .maximum)
    }

    @Test("and reaching the bottom reports the minimum")
    func brightnessToTheBottom() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.1)
        #expect(state.apply(0, at: Self.epoch)?.limit == .minimum)
    }

    /// **The throttle would otherwise swallow the one value that matters.** A brightness ramp
    /// publishes at most every 100ms, and its settled value arrives whenever it arrives — 56ms after
    /// the last publish, in the recorded session. Without the limit bypass the island's last word on
    /// a run to full brightness is 0.9980 and it never learns it got there.
    @Test("an end of the range publishes inside the throttle window")
    func limitBypassesTheThrottle() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.5)
        // Starts a burst, publishes immediately.
        #expect(state.apply(0.6, at: Self.epoch)?.limit == nil)
        // Well inside the 100ms window: swallowed, because it is mid-ramp.
        #expect(state.apply(0.8, at: Self.epoch.addingTimeInterval(0.02)) == nil)
        // Also inside it, and published anyway, because it is the end of the range.
        let arrived = state.apply(1, at: Self.epoch.addingTimeInterval(0.04))
        #expect(arrived?.level == 1)
        #expect(arrived?.limit == .maximum)
    }

    /// It publishes once and then stops: the equality guard drops every callback carrying the level
    /// already on screen, which is what makes a limit a moment rather than a state.
    @Test("a brightness key held at the top publishes the arrival once")
    func brightnessLimitDoesNotRepeat() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.99)
        #expect(state.apply(1, at: Self.epoch)?.limit == .maximum)
        #expect(state.apply(1, at: Self.epoch.addingTimeInterval(0.02)) == nil)
        #expect(state.apply(1, at: Self.epoch.addingTimeInterval(0.5)) == nil)
    }
}
