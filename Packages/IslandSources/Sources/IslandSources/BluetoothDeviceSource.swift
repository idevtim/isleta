import Foundation
import IslandActivities
import IslandKit

/// A Bluetooth audio device connecting, said once and briefly.
///
/// # Why this source keeps no timer
///
/// It is the only source in the package with nothing on any path but the callback. The connect
/// notification is push and permission-free; the battery percentages are read *inside* that
/// callback, where — measured — the ear pieces have already reported; and the activity retires
/// itself four seconds later through `ActivityKind.deviceConnected.defaultExpiry`. There is no
/// value to refresh because there is no time in which it could go stale, so §9's idle cost for this
/// source is exactly zero.
///
/// That is not a compromise forced by the platform, it is the shape of the feature. A persistent
/// battery readout would need polling — the properties are not KVO-compliant (see
/// `BluetoothDeviceBattery`) — and §9 forbids one on the idle path.
///
/// # The burst
///
/// One physical AirPods connect fires the notification **three or four times**, measured on
/// macOS 27.0: twice or three times at the classic address within 33ms, and once more at a BLE
/// random address. `IOBluetoothDeviceMonitor` drops the BLE half, and the rest collapse on their
/// own — `BluetoothDeviceConnection.activityID` is keyed on the address, so the coordinator treats
/// repeats as an update to the activity already on stage rather than as new ones behind it.
///
/// `recentlyAnnounced` is the second half of that, and it is about a different event: connecting,
/// disconnecting and reconnecting the same AirPods within a few seconds is one thing the user did,
/// and re-publishing restarts a four-second dwell that was already running. The window is short
/// enough that a genuine reconnect ten seconds later is still announced.
@MainActor
public final class BluetoothDeviceSource: ActivitySource {

    public static let sourceName = "Bluetooth"

    /// **Bluetooth is a permission, and this property said `.notRequired` through 1.3.0.**
    ///
    /// The claim looked safe from every angle: the connect notification is classic IOBluetooth,
    /// reading a paired device's own properties is not TCC-gated, and no prompt was ever seen while
    /// the feature was being built. The last of those was the tell that was misread — the prompt was
    /// never seen because every run was launched from a shell, where TCC judges the request against
    /// Terminal. Launched by LaunchServices, the registration files a real access request; see
    /// `IOBluetoothDeviceMonitor.authorization` for what that cost.
    ///
    /// A Mac with no radio is still `.notRequired`, for the reason `SystemHUDSource` gives: denied
    /// means "you could have this and don't", and a Mac with Bluetooth off is not being refused
    /// anything. That case is checked before the permission, because the radio being absent makes
    /// the permission moot rather than the other way round.
    public var authorization: SourceAuthorization {
        monitor.isAvailable ? monitor.authorization : .notRequired
    }

    public var onActivity: ((any IslandActivity) -> Void)?

    public var onDismiss: ((ActivityID) -> Void)?

    public private(set) var isRunning = false

    private let monitor: any BluetoothDeviceMonitoring

    /// The second route in, and the one that carries the event IOBluetooth does not have.
    ///
    /// See `AudioRouteMonitoring` for the measurement. In one sentence: taking AirPods out of your
    /// ears is not a Bluetooth disconnect, so putting them back is not a Bluetooth connect, and the
    /// only thing that moves is the system output device.
    private let routeMonitor: any AudioRouteMonitoring

    /// Addresses announced in the last `announcementWindow`, and when. Bounded by the number of
    /// devices a person can connect in four seconds, so there is nothing to evict on a schedule —
    /// which would be a timer, for a dictionary that never exceeds a handful of entries.
    private var recentlyAnnounced: [String: Date] = [:]

    private static let announcementWindow: TimeInterval = 4

    public init(
        monitor: any BluetoothDeviceMonitoring,
        routeMonitor: any AudioRouteMonitoring = UnavailableAudioRouteMonitor()
    ) {
        self.monitor = monitor
        self.routeMonitor = routeMonitor
    }

    /// Whether the charge can be shown, as opposed to only the fact of connection. Read by
    /// IslandSettings so the gap gets a sentence rather than a silently missing ring.
    public var reportsBattery: Bool { monitor.reportsBattery }

    /// **The radio is not asked about here, and that is the fix for a launch-hanging deadlock.**
    ///
    /// This read `guard monitor.isAvailable` first, which is the natural shape and which called
    /// `IOBluetoothHostController.default()` on the main thread inside
    /// `applicationDidFinishLaunching`. That call waits on a semaphore whose reply comes back
    /// through the main queue — see `IOBluetoothDeviceMonitor.coordinatorQueue` — so it deadlocked
    /// the whole app before the source ever started, and took every source after this one in
    /// `SourceHub.entries` down with it.
    ///
    /// So the monitor is started unconditionally and answers the availability question itself, on
    /// its own queue. A Mac with no radio is still silent; it is silent a few milliseconds later
    /// and from `IOBluetoothDeviceMonitor.register`, which is where the log line now lives.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start { [weak self] connection, origin in
            self?.announce(connection, origin: origin)
        }
        // Both routes land in `announce`, and the burst window is what makes them one island. A
        // genuine connect fires IOBluetooth and then this, 244 ms apart (measured) — deduplicated
        // on the address, so whichever arrives first is the announcement and the other is a repeat.
        routeMonitor.start { [weak self] address, origin in
            self?.monitor.publishConnection(at: address, origin: origin)
        }
    }

    public func stop() {
        guard isRunning else { return }
        monitor.stop()
        routeMonitor.stop()
        recentlyAnnounced.removeAll()
        isRunning = false
    }

    /// Nothing is deferred here — no queue, no child process, no timer — so `stop()` already
    /// carries the promise `stopAndWait()` makes. Spelled out rather than inherited so that the
    /// next person to add work to `stop()` sees the rule they are now bound by.
    public func stopAndWait() { stop() }

    /// Publish, unless this device was already announced a moment ago — or was already connected
    /// when the source started.
    ///
    /// The second rule is the one that is easy to leave out and impossible to miss once it is
    /// wrong. Registering for connect notifications replays every already-connected device, so
    /// without it Isleta announced the user's AirPods on every launch, for a pair that had been in
    /// their ears for an hour. The island's sentence is "this just connected", and at launch that
    /// is not true of anything.
    ///
    /// - Note: the device's **name and address are not logged**, and the *kind* is. The name is a
    ///   string the user wrote and the address identifies a specific piece of their hardware, on a
    ///   line that goes into the file "Export Logs…" hands to strangers. The kind is a category with
    ///   six possible values and it is the one thing a bug report about this feature needs — "the
    ///   wrong picture appeared" is unanswerable without knowing which picture was chosen.
    func announce(
        _ connection: BluetoothDeviceConnection,
        origin: BluetoothConnectionOrigin = .connected,
        now: Date = Date()
    ) {
        // Recorded, not merely dropped: a device that was connected at launch and is *re*connected
        // later is news, and the burst window below is what tells the two apart.
        guard origin == .connected else {
            recentlyAnnounced[connection.address] = now
            return
        }
        if let last = recentlyAnnounced[connection.address],
           now.timeIntervalSince(last) < Self.announcementWindow {
            return
        }
        recentlyAnnounced[connection.address] = now
        // Evicted here rather than on a schedule: this runs only when a device connects, which is
        // the only moment the map can grow.
        recentlyAnnounced = recentlyAnnounced.filter {
            now.timeIntervalSince($0.value) < Self.announcementWindow * 4
        }
        IslandLog.sources.info(
            "Bluetooth: \(connection.kind) connected, battery \(connection.battery.isReported ? "reported" : "absent")"
        )
        onActivity?(BuiltInActivity.deviceConnected(connection))
    }
}
