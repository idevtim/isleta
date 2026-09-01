import Foundation
import IslandActivities
import IslandKit

/// The charger, the charge, and Low Power Mode.
///
/// # Why this source keeps no timer
///
/// Every input is push. The four `notify(3)` keys fire when the hardware changes and are silent
/// otherwise — measured at **zero fires over 315 s idle**, where the aggregate key beat five times
/// in the same window — and Low Power Mode arrives on `NSProcessInfoPowerStateDidChange`. The one
/// scheduled thing anywhere in the feature is `IOKitPowerMonitor`'s 100 ms coalescer, which is armed
/// by an event, fires once, and leaves nothing outstanding on an idle Mac.
///
/// Nothing here polls the charge, and that is a deliberate ceiling on the feature rather than a gap
/// in it: Isleta shows power *moments* — the cable going in, a battery getting low, Low Power Mode
/// turning itself on — and each retires itself through `ActivityKind.power.defaultExpiry`. A
/// persistent battery readout would need to be kept current, and the only way to keep it current is
/// to ask repeatedly. That is the same argument `BluetoothDeviceSource` makes about the AirPods
/// ring, and it ends the same way.
///
/// # The baseline
///
/// `start()` reads once and hands the reading to `PowerAnnouncementPolicy` as its *baseline*, which
/// announces nothing. A machine that has been on the charger all night must not be told at every
/// launch that it is on the charger, and a machine at 8 % must not open with a low-battery island
/// for a fact its owner has been looking at for an hour.
@MainActor
public final class PowerSource: ActivitySource {

    public static let sourceName = "Power"

    /// Nothing to ask for. `IOPSCopyPowerSourcesInfo`, the notify keys and
    /// `ProcessInfo.isLowPowerModeEnabled` are all public, unentitled and ungated.
    ///
    /// A Mac with no battery is still `.notRequired` rather than `.denied`, for the reason
    /// `BluetoothDeviceSource` gives about a Mac with no radio: denied means "you could have this
    /// and are being refused", and a Studio is not being refused anything.
    public var authorization: SourceAuthorization { .notRequired }

    public var onActivity: ((any IslandActivity) -> Void)?

    /// Never called. Every power activity is a moment with a dwell
    /// (`ActivityKind.power.defaultExpiry`), so there is nothing for a source to retract — the
    /// clock is right about when it stops being interesting. Set by the protocol, deliberately
    /// unused, and said here so the next reader does not go looking for the retraction path.
    public var onDismiss: ((ActivityID) -> Void)?

    public private(set) var isRunning = false

    private let monitor: any PowerMonitoring
    private var policy = PowerAnnouncementPolicy()

    /// How many power moments have been published this launch. Counts only — the diagnostics report
    /// is emailed, and a battery percentage is not something to put in a file that travels.
    public private(set) var announcementCount = 0

    public init(monitor: any PowerMonitoring = IOKitPowerMonitor()) {
        self.monitor = monitor
    }

    /// Whether this Mac has a battery at all, for the Settings row. A machine with none gets a
    /// sentence rather than a switch that silently does nothing.
    public var hasBattery: Bool { monitor.isAvailable }

    public func start() {
        guard !isRunning else { return }
        guard monitor.isAvailable else {
            IslandLog.system.info("power: no internal battery, source idle")
            return
        }
        isRunning = true

        // Read first, register second. The other order has a window — however small — in which a
        // change arrives before there is anything to compare it against, and the policy would take
        // that first callback as its baseline and swallow the event.
        _ = policy.handle(monitor.read())
        monitor.start { [weak self] state in
            self?.receive(state)
        }
        IslandLog.system.info("power: watching charger, level and Low Power Mode")
    }

    public func stop() {
        guard isRunning else { return }
        monitor.stop()
        // Reset, so a source switched off and on again treats its next reading as a baseline. Not
        // resetting is how switching the source off at 100 % and on again at 40 % announces a low
        // battery that nothing crossed while anybody was watching.
        policy.reset()
        isRunning = false
        IslandLog.system.info("power: stopped")
    }

    /// Nothing is deferred here — no queue, no child process, no timer of our own — so `stop()`
    /// already carries the promise `stopAndWait()` makes. Spelled out rather than inherited so the
    /// next person to add work to `stop()` sees the rule they are now bound by.
    public func stopAndWait() { stop() }

    /// Fold in a reading. The seam the tests drive: the whole matrix — plug, unplug, three low
    /// thresholds, Low Power Mode, charged — is reachable from here with no battery in the machine.
    ///
    /// - Note: the **percentage is not logged**. It is a fact about the user's hardware at a moment
    ///   in time, on a line that goes into the file "Export Logs…" hands to strangers, and a bug
    ///   report about this feature needs to know *which announcement* was chosen, never at what
    ///   charge. The announcement's case name is a closed vocabulary of five values.
    func receive(_ state: PowerState) {
        guard let announcement = policy.handle(state) else { return }
        announcementCount += 1
        IslandLog.system.info("power: \(String(describing: announcement).prefix(while: { $0 != "(" }))")
        onActivity?(BuiltInActivity.power(announcement, state: state))
    }
}
