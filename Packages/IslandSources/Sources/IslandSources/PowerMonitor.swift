import Foundation
import IOKit.ps
import IslandKit
// `notify(3)` is its own clang module (`usr/include/notify.modulemap`) and is **not** re-exported by
// Darwin or Foundation — without this line `notify_register_dispatch` and `NOTIFY_STATUS_OK` are
// simply "not in scope", which reads as the API having been removed rather than as a missing import.
import notify

/// The seam `PowerSource` is written against, so its behavior is testable on a machine with no
/// battery, with the charger in, and without waiting for anything to reach 5 %.
@MainActor
public protocol PowerMonitoring: AnyObject {

    /// Whether this Mac has an internal battery. False on a mini, a Studio and an iMac, where the
    /// whole feature is meaningless — and *not* a denial: nothing is being refused.
    var isAvailable: Bool { get }

    /// The power state right now. A read, not a subscription — used once at `start()` to establish
    /// the baseline the first real change is compared against.
    func read() -> PowerState

    /// Idempotent. The handler is called on the main actor, already coalesced and already deduped.
    func start(_ onChange: @escaping @MainActor (PowerState) -> Void)

    /// Must leave no notify token and no observer registered.
    func stop()
}

/// Power, through the **specific** `notify(3)` keys — never the aggregate.
///
/// # The aggregate key is a once-a-minute heartbeat
///
/// Measured on macOS 27.0 over **315 s idle, on AC, at 100 %, with nothing changing**:
/// `kIOPSNotifyAnyPowerSource` fired **5 times, at exactly 60.003 s intervals**, with a byte-identical
/// snapshot each time — confirmed at the same instants by `pmset -g pslog`. It is powerd's periodic
/// refresh. A source registered on it wakes once a minute forever, for nothing, which is precisely
/// what §9's idle budget exists to prevent. Every specific key —
/// `kIOPSNotifyPowerSource`, `…TimeRemaining`, `…LowBattery` and the undocumented percent key —
/// fired **zero** times over the same window.
///
/// So: register the four specific names, never `kIOPSNotifyAnyPowerSource`, and never
/// `IOPSNotificationCreateRunLoopSource` with a nil name, which is the same firehose wearing a
/// CoreFoundation hat.
///
/// # `com.apple.system.powersources.percent` is real and is in no header
///
/// `IOPowerSources.h` declares `lowbattery`, `timeremaining`, `source`, `attach` and the aggregate,
/// and **not** the percent key — grepped in the installed SDK rather than remembered. It is
/// nonetheless the key that fires when the number the island draws changes, so it is spelled as a
/// string literal here with this note beside it, which is the same treatment
/// `SystemEventsSource` gives `loginwindow`'s two undeclared names.
///
/// # Registration status is never evidence
///
/// `notify_register_dispatch` returns `NOTIFY_STATUS_OK` for **any string** — verified against
/// `com.apple.THIS.NAME.DOES.NOT.EXIST.ANYWHERE` and two more invented names. So a wrong name is
/// indistinguishable from a quiet machine, and "we registered successfully" says nothing about
/// whether anything will ever arrive. The names above are taken from the SDK header where one
/// exists and from a measurement where one does not.
///
/// # The serial number
///
/// `IOPSCopyPowerSourcesInfo`'s dictionary carries **`Hardware Serial Number`** — verified live on
/// this machine, in a dictionary of seventeen keys — alongside `Current Capacity`, `Is Charging`
/// and the rest. Nothing in this file logs the dictionary, logs a key of it, or hands it to anybody:
/// the only thing that leaves here is a `PowerState`, which has no field a serial could reach. That
/// is a structural guarantee rather than a rule to remember, and it is why the parse is in one
/// place.
@MainActor
public final class IOKitPowerMonitor: PowerMonitoring {

    /// From `IOPowerSources.h`. Named individually rather than iterated so that adding the
    /// aggregate is a visible edit somebody has to argue for.
    private static let notifyNames = [
        kIOPSNotifyPowerSource,      // the charger going in or coming out
        kIOPSNotifyTimeRemaining,    // the estimate being recalculated
        kIOPSNotifyLowBattery,       // the system's own low-battery moment
        // Undocumented, measured, and the one that carries the number this kind draws. See above.
        "com.apple.system.powersources.percent",
    ]

    /// 100 ms, and it is the burst that sets it rather than taste: under load the power keys fired
    /// **3 times in 39 ms**, two of them in the same millisecond, with identical content. Long
    /// enough to swallow a burst, short enough that a charger going in is on the island in the same
    /// tenth of a second the user let go of the cable.
    private static let coalesceInterval: TimeInterval = 0.1

    private var tokens: [Int32] = []
    private var powerStateObserver: (any NSObjectProtocol)?
    private var onChange: (@MainActor (PowerState) -> Void)?

    /// What was last handed out, so a coalesced burst that says nothing new says nothing.
    private var published: PowerState?

    /// Whether a coalesced read is already scheduled. Not a timer: it is armed by an event, fires
    /// once, and leaves nothing behind — an idle Mac has none of these outstanding, which is what
    /// §9 asks for.
    private var flushIsScheduled = false

    public init() {}

    public var isAvailable: Bool { PowerSourceReader.hasInternalBattery() }

    public func read() -> PowerState { PowerSourceReader.read() }

    public func start(_ onChange: @escaping @MainActor (PowerState) -> Void) {
        guard tokens.isEmpty, powerStateObserver == nil else { return }
        self.onChange = onChange

        for name in Self.notifyNames {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.main) { [weak self] _ in
                // `DispatchQueue.main` is what the token was registered on, so this really is the
                // main thread and `assumeIsolated` is the assertion that says so rather than a hope.
                MainActor.assumeIsolated { self?.scheduleFlush() }
            }
            // Recorded, not trusted. `NOTIFY_STATUS_OK` comes back for names that do not exist, so
            // this line is only useful for the one failure it *can* see — the daemon refusing to
            // register anything at all.
            guard status == NOTIFY_STATUS_OK else {
                IslandLog.system.warning("power: notify registration failed with status \(status)")
                continue
            }
            tokens.append(token)
        }

        observeLowPowerMode()
        IslandLog.system.info("power: \(self.tokens.count) notify keys registered, aggregate deliberately not among them")
    }

    public func stop() {
        for token in tokens { notify_cancel(token) }
        tokens.removeAll()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        powerStateObserver = nil
        onChange = nil
        published = nil
        flushIsScheduled = false
    }

    /// Low Power Mode, which is the one input here that does not come from IOKit.
    ///
    /// **`NSProcessInfoPowerStateDidChange` is posted on the global dispatch queue**, not on the
    /// main one — the same shape as `IOBluetooth`'s connect notification, which took SIGTRAP the
    /// first time real hardware connected because an `@objc` method on a `@MainActor` class was
    /// called from CoreBluetooth's XPC queue. So the block is registered with **no queue**, is
    /// therefore nonisolated, and hops explicitly. Handing `OperationQueue.main` to the registration
    /// would also work and is not used deliberately: it hides which thread the post arrives on, and
    /// the next person to add a line here would have no way of knowing it was ever a question.
    private func observeLowPowerMode() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleFlush() }
            }
        }
    }

    /// Arm the one-shot coalescer, or do nothing if it is already armed.
    private func scheduleFlush() {
        guard !flushIsScheduled, onChange != nil else { return }
        flushIsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Read once, and hand it on **only if it differs from what was handed on last**.
    ///
    /// The diff is on the whole `PowerState`, which is exactly the set of fields the island draws —
    /// so a burst that repeats itself is silent, and a burst that carries a real change is one
    /// event. Anything IOKit knows and Isleta does not draw cannot cause an island, by construction.
    private func flush() {
        flushIsScheduled = false
        guard let onChange else { return }
        let state = PowerSourceReader.read()
        guard state != published else { return }
        published = state
        onChange(state)
    }
}

/// A monitor for a Mac with no battery, and for tests that want the feature absent.
///
/// The same shape as `UnavailableBluetoothMonitor` and `UnavailableWeatherProvider`: the missing
/// capability is a conformance rather than a branch in the source.
@MainActor
public final class UnavailablePowerMonitor: PowerMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    public func read() -> PowerState { PowerState(isPresent: false) }
    public func start(_ onChange: @escaping @MainActor (PowerState) -> Void) {}
    public func stop() {}
}

/// The IOKit reads, in one place, with no state and nothing that can leak.
///
/// Separate from the monitor for the reason `SystemHUDAudioReader` is separate from its observer:
/// the parse is the part worth being able to read on its own, and it is where the sentinel rules and
/// the serial number both live.
enum PowerSourceReader {

    /// Whether an internal battery is present. External UPS sources are deliberately not counted —
    /// the island's sentence is about *this Mac's* charge.
    static func hasInternalBattery() -> Bool {
        descriptions().contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    static func read() -> PowerState {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let battery = descriptions().first(where: {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }) else {
            return PowerState(isPresent: false, isLowPowerMode: lowPowerMode)
        }

        let current = battery[kIOPSCurrentCapacityKey] as? Int
        let max = battery[kIOPSMaxCapacityKey] as? Int
        let isCharging = battery[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = battery[kIOPSIsChargedKey] as? Bool ?? false
        // `Power Source State` rather than `Is Charging`: a machine that is plugged in and full is
        // not charging, and "On Battery" would be a plain lie about the cable in its side.
        let isPluggedIn = (battery[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        let percent: Int? = {
            guard let current, let max, max > 0 else { return nil }
            return Swift.min(Swift.max(current * 100 / max, 0), 100)
        }()

        // Two units and two sets of sentinels, which is why `PowerTimeEstimate` owns the rule: the
        // estimate function answers in seconds with −1/−2, and the dictionary answers in minutes
        // with 0/65535. Charging asks the dictionary because the estimate function describes time
        // to *empty*.
        let estimate: PowerTimeEstimate = if isCharging {
            .minutes(battery[kIOPSTimeToFullChargeKey] as? Int ?? 0)
        } else if isPluggedIn {
            .notApplicable
        } else {
            .seconds(IOPSGetTimeRemainingEstimate())
        }

        return PowerState(
            isPresent: true,
            isPluggedIn: isPluggedIn,
            isCharging: isCharging,
            isCharged: isCharged,
            percent: percent,
            estimate: estimate,
            isLowPowerMode: lowPowerMode
        )
    }

    /// Every power source's description dictionary.
    ///
    /// **The return value never leaves this file.** It carries `Hardware Serial Number` among its
    /// seventeen keys, and the export bundle is a file people email to strangers — so the dictionary
    /// is read into a `PowerState` here and dropped, and nothing above this line has a way to ask
    /// for it.
    private static func descriptions() -> [[String: Any]] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return sources.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
    }
}
