import Foundation
import Testing

@testable import IslandActivities

/// The user's "how long an activity stays" multiplier.
///
/// The whole of the rule is which expiries it touches. `.after` is a *dwell* — somebody's judgement
/// about how long a person needs to read something — and is therefore the user's to adjust. `.at` is
/// a fact about the world: a timer that ends at 3:45 ends at 3:45, and scaling it would make
/// Isleta's clock quietly disagree with the clock the user set. Getting that backwards is not
/// visible in a screenshot and is very visible in a kitchen.
@Suite("Activity dwell scale")
struct DwellScaleTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The expiry itself

    @Test("a relative expiry stretches by the scale")
    func afterScales() {
        let expiry = ActivityExpiry.after(.seconds(4))
        #expect(expiry.deadline(from: now, dwellScale: 2) == now.addingTimeInterval(8))
        #expect(expiry.deadline(from: now, dwellScale: 0.5) == now.addingTimeInterval(2))
    }

    @Test("an absolute expiry is a fact about the world and does not move")
    func atDoesNotScale() {
        let alarm = now.addingTimeInterval(600)
        #expect(ActivityExpiry.at(alarm).deadline(from: now, dwellScale: 3) == alarm)
        #expect(ActivityExpiry.at(alarm).deadline(from: now, dwellScale: 0.5) == alarm)
    }

    @Test("never has nothing to scale")
    func neverStaysNever() {
        #expect(ActivityExpiry.never.deadline(from: now, dwellScale: 3) == nil)
    }

    @Test("the default scale is 1, so every existing caller is unchanged")
    func defaultIsUnity() {
        let expiry = ActivityExpiry.after(.seconds(5))
        #expect(expiry.deadline(from: now) == expiry.deadline(from: now, dwellScale: 1))
        #expect(expiry.deadline(from: now) == now.addingTimeInterval(5))
    }

    // MARK: - Through the stack

    /// Applied at insertion — the one point a relative expiry becomes an absolute instant — rather
    /// than by the sources that build the activities. A source runs off the main actor and knows
    /// nothing about IslandSettings, and must keep knowing nothing.
    @Test("the stack applies the scale as it resolves a deadline")
    func stackAppliesTheScale() {
        var stack = ActivityStack()
        stack.dwellScale = 2
        stack.insert(BuiltInActivity(kind: .calendarAlert, expiry: .after(.seconds(5))), at: now)

        #expect(stack.nextExpiry == now.addingTimeInterval(10))
    }

    @Test("a stack starts at 1, so nothing has to remember to set it")
    func stackDefaultsToUnity() {
        var stack = ActivityStack()
        stack.insert(BuiltInActivity(kind: .calendarAlert, expiry: .after(.seconds(5))), at: now)
        #expect(stack.nextExpiry == now.addingTimeInterval(5))
    }

    /// The kinds keep their proportions, which is the argument for a multiplier over a number of
    /// seconds: the HUD's dwell is tuned to sit alongside Apple's own and a notification's to be
    /// readable, and one slider that made them equal would break the first to serve the second.
    @Test("scaling preserves the ratio the kinds were tuned at")
    func proportionsSurvive() {
        let hud = ActivityKind.systemHUD.defaultExpiry.deadline(from: now, dwellScale: 2)
        let notification = ActivityKind.calendarAlert.defaultExpiry.deadline(from: now, dwellScale: 2)
        let unscaledHUD = ActivityKind.systemHUD.defaultExpiry.deadline(from: now)
        let unscaledNotification = ActivityKind.calendarAlert.defaultExpiry.deadline(from: now)

        let scaledRatio = hud!.timeIntervalSince(now) / notification!.timeIntervalSince(now)
        let originalRatio = unscaledHUD!.timeIntervalSince(now) / unscaledNotification!.timeIntervalSince(now)
        #expect(abs(scaledRatio - originalRatio) < 0.0001)
    }

    /// Now Playing and the shelf never expire, at any setting. Their sources remove them; nothing
    /// about the passage of time makes "this track is playing" false.
    @Test("a scale of any size cannot make Now Playing expire")
    func nonExpiringKindsAreUntouched() {
        var stack = ActivityStack()
        stack.dwellScale = 0.5
        stack.insert(BuiltInActivity(kind: .nowPlaying, expiry: .never), at: now)
        #expect(stack.nextExpiry == nil)
    }

    /// Changing the setting does not restretch what is already on the stage — moving it would mean
    /// either expiring something the user is mid-read of, or extending a HUD that was already
    /// leaving. The next thing presented uses the new value.
    @Test("an activity keeps the deadline it was given when the scale changes under it")
    func outstandingDeadlinesAreNotRestretched() {
        var stack = ActivityStack()
        stack.insert(BuiltInActivity(kind: .calendarAlert, expiry: .after(.seconds(5))), at: now)
        let original = stack.nextExpiry

        stack.dwellScale = 3
        #expect(stack.nextExpiry == original)
    }

    @Test("re-presenting the same activity resets its deadline at the new scale")
    func rePresentingUsesTheNewScale() {
        var stack = ActivityStack()
        let activity = BuiltInActivity(kind: .systemHUD, expiry: .after(.seconds(2)))
        stack.insert(activity, at: now)

        stack.dwellScale = 3
        stack.insert(activity, at: now)
        #expect(stack.nextExpiry == now.addingTimeInterval(6))
    }
}
