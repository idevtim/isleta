import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The sentinel rule, the announcement rule and the diff, none of which need a battery.
@Suite("Power state")
struct PowerStateTests {

    // MARK: - The three values that are not durations

    /// `kIOPSTimeRemainingUnlimited`. Measured on AC at 100 %: `IOPSGetTimeRemainingEstimate()`
    /// answers −2.0, and a reader that divides it by 60 draws "0 min left" on a machine that is
    /// plugged in.
    @Test("−2.0 is unlimited, not a duration")
    func unlimitedIsNotADuration() {
        #expect(PowerTimeEstimate.seconds(-2.0) == .notApplicable)
        #expect(PowerTimeEstimate.seconds(-2.0).formatted == nil)
    }

    /// `kIOPSTimeRemainingUnknown` — normal on battery for the first minute after a plug change,
    /// which is exactly when somebody looks at the island.
    @Test("−1.0 is unknown, not a duration")
    func unknownIsNotADuration() {
        #expect(PowerTimeEstimate.seconds(-1.0) == .unknown)
        #expect(PowerTimeEstimate.seconds(-1.0).formatted == nil)
    }

    /// The IORegistry's sentinel, in the units the power-source dictionary answers in. It is in no
    /// SDK header, which is why the number is pinned here rather than trusted to a memory.
    @Test("65535 minutes is the registry sentinel, not 45 days")
    func registrySentinelIsNotADuration() {
        #expect(PowerTimeEstimate.minutes(65535) == .unknown)
        #expect(PowerTimeEstimate.minutes(70000) == .unknown)
    }

    /// Measured in the same snapshot as the −2.0 above: both `Time to Empty` and `Time to Full
    /// Charge` read **0** on AC at 100 %. Zero is "not calculated", and it is the one sentinel that
    /// looks like a real number.
    @Test("zero minutes is not a duration either")
    func zeroIsNotADuration() {
        #expect(PowerTimeEstimate.minutes(0) == .unknown)
        #expect(PowerTimeEstimate.seconds(0) == .unknown)
    }

    @Test("a real estimate survives, in both units")
    func realEstimates() {
        #expect(PowerTimeEstimate.minutes(160) == .remaining(9600))
        #expect(PowerTimeEstimate.seconds(9600).formatted == "2 hr 40 min")
        #expect(PowerTimeEstimate.minutes(40).formatted == "40 min")
        #expect(PowerTimeEstimate.minutes(120).formatted == "2 hr")
        // Under a minute is still worth a sentence — "0 min left" is the one thing it must not say.
        #expect(PowerTimeEstimate.seconds(20).formatted == "1 min")
    }

    // MARK: - What becomes an island

    private func battery(
        pluggedIn: Bool = false,
        charging: Bool = false,
        charged: Bool = false,
        percent: Int? = 80,
        lowPowerMode: Bool = false
    ) -> PowerState {
        PowerState(
            isPresent: true,
            isPluggedIn: pluggedIn,
            isCharging: charging,
            isCharged: charged,
            percent: percent,
            estimate: .remaining(9600),
            isLowPowerMode: lowPowerMode
        )
    }

    /// The launch rule. A Mac that has been on the charger all night must not be told at every
    /// launch that it is on the charger — the same mistake `BluetoothDeviceSource` fixed for devices
    /// that were already connected when the source started.
    @Test("the first reading is a baseline and announces nothing")
    func firstReadingIsSilent() {
        var policy = PowerAnnouncementPolicy()
        #expect(policy.handle(battery(pluggedIn: true, charging: true)) == nil)
    }

    /// The diff rule: the percent moving is not news. Bursts of three identical callbacks in 39 ms
    /// are real, and so are ordinary one-per-cent drops.
    @Test("a percentage drifting down announces nothing")
    func driftIsSilent() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 80))
        #expect(policy.handle(battery(percent: 79)) == nil)
        #expect(policy.handle(battery(percent: 79)) == nil)
        #expect(policy.handle(battery(percent: 78)) == nil)
    }

    @Test("the charger going in and coming out are both announced")
    func chargerIsAnnounced() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(pluggedIn: false))
        #expect(policy.handle(battery(pluggedIn: true, charging: true)) == .pluggedIn)
        #expect(policy.handle(battery(pluggedIn: false)) == .unplugged)
    }

    /// Three announcements over a whole discharge, not one per reading. A battery hovering on a
    /// boundary recalculates its estimate constantly, and each of those is a callback.
    @Test("a low threshold is announced once per discharge")
    func lowThresholdAnnouncesOnce() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 30))
        #expect(policy.handle(battery(percent: 20)) == .low(percent: 20))
        #expect(policy.handle(battery(percent: 19)) == nil)
        #expect(policy.handle(battery(percent: 21)) == nil)
        #expect(policy.handle(battery(percent: 10)) == .low(percent: 10))
        #expect(policy.handle(battery(percent: 7)) == nil)
        #expect(policy.handle(battery(percent: 5)) == .low(percent: 5))
        #expect(policy.handle(battery(percent: 4)) == nil)
    }

    /// Plugging in re-arms them, because that is where the battery's story restarts.
    @Test("plugging in re-arms the low thresholds")
    func chargingRearmsThresholds() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 30))
        // The announcement carries the **real** percentage, not the threshold it crossed: the
        // island draws "15%", which is what the battery says, rather than the round number that
        // decided the moment was worth showing.
        #expect(policy.handle(battery(percent: 15)) == .low(percent: 15))
        #expect(policy.handle(battery(pluggedIn: true, charging: true, percent: 16)) == .pluggedIn)
        _ = policy.handle(battery(pluggedIn: true, charging: true, percent: 40))
        #expect(policy.handle(battery(percent: 40)) == .unplugged)
        #expect(policy.handle(battery(percent: 18)) == .low(percent: 18))
    }

    /// A low battery is never reported while the charger is in: the number is going *up*.
    @Test("a low battery on the charger is not a low battery")
    func chargingIsNeverLow() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(pluggedIn: true, charging: true, percent: 30))
        #expect(policy.handle(battery(pluggedIn: true, charging: true, percent: 8)) == nil)
    }

    /// macOS turns Low Power Mode on by itself at 20 %, so it arrives in the same breath as the
    /// low-battery reading. One event, one island — the low battery wins because it is the one with
    /// a consequence attached.
    @Test("low battery outranks the Low Power Mode it caused")
    func lowBatteryOutranksLowPowerMode() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 25))
        #expect(policy.handle(battery(percent: 20, lowPowerMode: true)) == .low(percent: 20))
        // …and the mode itself is not then announced separately on the next reading, because it has
        // not changed again.
        #expect(policy.handle(battery(percent: 19, lowPowerMode: true)) == nil)
    }

    @Test("Low Power Mode on its own is announced both ways")
    func lowPowerModeIsAnnounced() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 90))
        #expect(policy.handle(battery(percent: 90, lowPowerMode: true)) == .lowPowerMode(isOn: true))
        #expect(policy.handle(battery(percent: 90, lowPowerMode: false)) == .lowPowerMode(isOn: false))
    }

    /// Charged is the system's own flag, not `percent == 100`: a battery held at 80 % by Optimized
    /// Charging is charged in the sense that matters.
    @Test("charged is announced from the system's flag")
    func chargedIsAnnounced() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(pluggedIn: true, charging: true, percent: 99))
        #expect(policy.handle(battery(pluggedIn: true, charged: true, percent: 80)) == .charged)
        #expect(policy.handle(battery(pluggedIn: true, charged: true, percent: 80)) == nil)
    }

    /// A Mac with no battery has no power moments at all, and that is not a denial of anything.
    @Test("a machine with no battery announces nothing")
    func noBatteryNoAnnouncements() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(PowerState(isPresent: false))
        #expect(policy.handle(PowerState(isPresent: false, isLowPowerMode: true)) == nil)
    }

    @Test("reset makes the next reading a baseline again")
    func resetRestoresTheBaseline() {
        var policy = PowerAnnouncementPolicy()
        _ = policy.handle(battery(percent: 90))
        policy.reset()
        #expect(policy.handle(battery(percent: 5)) == nil)
    }

    // MARK: - What it draws

    /// The sentinel rule, at the point where it would be visible: never a duration in the subtitle
    /// when there is not one.
    @Test("an unknown estimate is left out of the sentence rather than drawn as zero")
    func unknownEstimateIsNotDrawn() {
        let state = PowerState(
            isPresent: true, isPluggedIn: false, percent: 42, estimate: .unknown
        )
        let activity = BuiltInActivity.power(.unplugged, state: state)
        #expect(activity.presentations.expanded.subtitle == "42%")
    }

    @Test("a real estimate is drawn with the right preposition")
    func estimateIsDrawnPerAnnouncement() {
        let discharging = PowerState(isPresent: true, percent: 42, estimate: .remaining(3600))
        #expect(BuiltInActivity.power(.unplugged, state: discharging)
            .presentations.expanded.subtitle == "42% · 1 hr left")

        let charging = PowerState(
            isPresent: true, isPluggedIn: true, isCharging: true, percent: 42,
            estimate: .remaining(3600)
        )
        #expect(BuiltInActivity.power(.pluggedIn, state: charging)
            .presentations.expanded.subtitle == "42% · 1 hr to full")
    }

    /// The trailing flank is where this kind's number goes — `ActivityKind.power.flankAffinity` —
    /// and a machine with no battery draws nothing there rather than an empty ring, which would be
    /// a claim about the charge.
    @Test("the level goes in the trailing flank, and is absent when there is none")
    func levelIsInTheTrailingFlank() {
        let withBattery = BuiltInActivity.power(
            .unplugged, state: PowerState(isPresent: true, percent: 50, estimate: .unknown)
        )
        #expect(withBattery.presentations.trailing.value?.normalized == 0.5)

        let without = BuiltInActivity.power(
            .lowPowerMode(isOn: true), state: PowerState(isPresent: false)
        )
        #expect(without.presentations.trailing.isEmpty)
    }

    @Test("five per cent is critical, twenty is a warning")
    func tintEscalates() {
        let state = PowerState(isPresent: true, percent: 5, estimate: .unknown)
        #expect(BuiltInActivity.power(.low(percent: 5), state: state).presentations.expanded.tint == .critical)
        #expect(BuiltInActivity.power(.low(percent: 20), state: state).presentations.expanded.tint == .warning)
        #expect(BuiltInActivity.power(.pluggedIn, state: state).presentations.expanded.tint == .positive)
    }

    /// Every kind's defaults come from `ActivityKind`, and this one is worth pinning because the
    /// island's behavior depends on it: a power moment must not open the island and must retire
    /// itself, or every charger connection would take the top of the screen.
    @Test("a power activity is a moment, not a state the island holds")
    func powerIsAMoment() {
        let activity = BuiltInActivity.power(
            .pluggedIn, state: PowerState(isPresent: true, percent: 50, estimate: .unknown)
        )
        #expect(activity.kind == .power)
        #expect(activity.expiry == .after(.seconds(5)))
        #expect(activity.kind.opensIsland == false)
    }
}
