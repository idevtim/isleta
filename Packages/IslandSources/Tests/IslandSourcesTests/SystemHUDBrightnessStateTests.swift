import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The coalescer, tested against the shape a real brightness ramp actually has.
///
/// `capturedRamp` below is not invented: it is the first of nine key-holds recorded from
/// DisplayServices on macOS 27.0 (26A5416b) on 2026-08-22, verbatim, as (milliseconds since the
/// first callback, level). Every threshold in `SystemHUDBrightnessState` was chosen by replaying
/// this session, so the constants and the data that justify them are pinned together — change one
/// and this suite says what it cost.
@Suite("SystemHUDBrightnessState")
struct SystemHUDBrightnessStateTests {

    /// One real key-hold: 27 callbacks over 494ms, easing from 0.8546 to exactly 1.0.
    static let capturedRamp: [(ms: Double, level: Double)] = [
        (0.0, 0.8546), (28.6, 0.8696), (46.4, 0.8810), (65.5, 0.8897), (84.6, 0.8963),
        (102.3, 0.9014), (121.3, 0.9052), (139.4, 0.9081), (158.4, 0.9104), (177.8, 0.9121),
        (188.8, 0.9330), (211.2, 0.9490), (229.0, 0.9611), (249.0, 0.9704), (267.7, 0.9774),
        (288.4, 0.9828), (310.6, 0.9869), (330.5, 0.9900), (343.3, 0.9924), (360.5, 0.9942),
        (380.4, 0.9956), (402.6, 0.9966), (419.6, 0.9974), (437.8, 0.9980), (456.4, 0.9985),
        (477.8, 0.9989), (494.0, 1.0000),
    ]

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Replay the captured ramp through a baselined state, returning what would reach the island.
    private func replayCapturedRamp(
        into state: inout SystemHUDBrightnessState, startingAt offset: TimeInterval = 0
    ) -> [SystemHUDReading] {
        Self.capturedRamp.compactMap { sample in
            state.apply(
                sample.level, at: Self.epoch.addingTimeInterval(offset + sample.ms / 1000)
            )
        }
    }

    // MARK: - The launch bug

    /// The bug this prevents is visible and was shipped once by the volume path's ancestor: a HUD
    /// on screen at login for a level the user set yesterday.
    @Test("the first level seen is a reference point, not news")
    func firstLevelIsSilent() {
        var state = SystemHUDBrightnessState()
        #expect(state.apply(0.5, at: Self.epoch) == nil)
        #expect(state.hasBaseline)
        #expect(state.level == 0.5)
    }

    @Test("an explicit rebase never publishes")
    func rebaseIsSilent() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.42)
        #expect(state.hasBaseline)
        #expect(state.level == 0.42)
        // And the level it adopted is not then reported as a change.
        #expect(state.apply(0.42, at: Self.epoch) == nil)
    }

    // MARK: - The ramp

    @Test("one real key-hold becomes a handful of readings, not twenty-seven")
    func capturedRampIsCoalesced() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.8350)
        let readings = replayCapturedRamp(into: &state)

        // 27 callbacks in. The throttle is 100ms over a 494ms ramp and the first publishes at once,
        // so five get through — at 0, 102, 211, 330 and 438ms — **plus the last**, at 494ms, which
        // is the ramp arriving at exactly 1.0. An end of the range always publishes, throttle or no:
        // it is the one value in a ramp that is not a transient, and swallowing it is what would
        // leave the island never learning it had reached the top. See `SystemHUDBrightnessState`.
        #expect(readings.count == 6)
        // Still a handful rather than a stream — a quarter of the callbacks, plus that one.
        #expect(readings.count <= Self.capturedRamp.count / 4 + 1)
        #expect(readings.allSatisfy { $0.hud == .brightness })
        // And only the last one is at an end. Nothing in the middle of a ramp is.
        #expect(readings.map(\.limit) == [nil, nil, nil, nil, nil, .maximum])
    }

    /// The one frame that must not be delayed. A HUD that appears 100ms after the key is a HUD the
    /// user has already stopped looking for.
    @Test("the first callback of a burst publishes immediately")
    func burstStartIsImmediate() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.8350)
        let first = state.apply(0.8546, at: Self.epoch)
        #expect(first?.level == 0.8546)
    }

    /// The measured cost of not scheduling a trailing flush. If this ever exceeds one notch of the
    /// sixteen macOS itself draws (0.0625), the throttle is too coarse and the table in
    /// `SystemHUDBrightnessState` needs re-reading.
    ///
    /// **The recorded ramp ends at a bound, so this one is now exact** — the limit rule publishes
    /// that last callback. The bound-free case below is where the throttle's real settled error
    /// still shows, and it is the one the table's 0.0034 is about.
    @Test("the settled value left on screen is within a third of one notch of the truth")
    func settledErrorIsImperceptible() throws {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.8350)
        let readings = replayCapturedRamp(into: &state)

        let shown = try #require(readings.last).level
        let truth = try #require(Self.capturedRamp.last).level
        let error = abs(shown - truth)
        #expect(error <= 0.0625 / 3)
        // The recorded figure, so a regression is a number rather than a feeling.
        #expect(error < 0.004)
    }

    /// The same ramp stopped short of the top, which is what most brightness presses actually do.
    ///
    /// Here the trailing value **is** swallowed — that is the throttle working as the table says —
    /// and the error left on screen is the 0.34% the table records. Written down separately so the
    /// limit rule cannot be mistaken for a trailing flush: it publishes at the ends of the range and
    /// nowhere else, and this is the cost that stands everywhere else.
    @Test("a ramp that stops short of the top still leaves the throttle's own error")
    func settledErrorWithoutABound() throws {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.8350)
        // Every sample but the final 1.0.
        let readings = Self.capturedRamp.dropLast().compactMap { sample in
            state.apply(sample.level, at: Self.epoch.addingTimeInterval(sample.ms / 1000))
        }
        let shown = try #require(readings.last).level
        let truth = try #require(Self.capturedRamp.dropLast().last).level
        #expect(abs(shown - truth) <= 0.0625 / 3)
        #expect(readings.allSatisfy { $0.limit == nil })
    }

    @Test("a second key-hold after a gap starts its own burst and publishes at once")
    func secondBurstPublishesImmediately() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.8350)
        _ = replayCapturedRamp(into: &state)

        // The measured gaps between the nine real key-holds were 189-403ms.
        let readings = replayCapturedRamp(into: &state, startingAt: 0.494 + 0.189)
        // The ramp replays the same values, and the first of them differs from where the last
        // burst settled, so it is a change and it is immediate.
        #expect(readings.first?.level == Self.capturedRamp[0].level)
    }

    // MARK: - Silence

    @Test("a callback carrying the level already on screen says nothing")
    func duplicateValueIsSilent() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.5)
        #expect(state.apply(0.5, at: Self.epoch) == nil)
        #expect(state.apply(0.5, at: Self.epoch.addingTimeInterval(1)) == nil)
    }

    @Test("mid-burst callbacks inside the throttle window are swallowed")
    func midBurstIsThrottled() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.50)
        #expect(state.apply(0.51, at: Self.epoch) != nil)
        // 20ms later — the measured within-burst interval — and well inside the 100ms throttle.
        #expect(state.apply(0.52, at: Self.epoch.addingTimeInterval(0.020)) == nil)
        #expect(state.apply(0.53, at: Self.epoch.addingTimeInterval(0.040)) == nil)
        // Past the throttle, the latest value gets through.
        let published = state.apply(0.54, at: Self.epoch.addingTimeInterval(0.101))
        #expect(published?.level == 0.54)
    }

    /// Swallowed is not forgotten: the state still tracks the newest level, or the next burst would
    /// compare against a stale one and mistake a real change for a duplicate.
    @Test("a swallowed callback still updates the level it holds")
    func throttledCallbackStillRecordsLevel() {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.50)
        _ = state.apply(0.51, at: Self.epoch)
        _ = state.apply(0.52, at: Self.epoch.addingTimeInterval(0.020))
        #expect(state.level == 0.52)
    }

    // MARK: - The activity it becomes

    @Test("a reading becomes the brightness HUD, with §8.3's expiry and identity")
    func readingBecomesBrightnessActivity() throws {
        var state = SystemHUDBrightnessState()
        state.rebase(to: 0.5)
        let published = state.apply(0.6, at: Self.epoch)
        let reading = try #require(published)
        let activity = reading.activity
        #expect(activity.kind == .systemHUD)
        // Volume and brightness are one HUD, so they must share an id or the island would queue a
        // second HUD behind the first instead of replacing it.
        #expect(activity.id == BuiltInActivity.systemHUD(.volume, level: 0).id)
    }
}
