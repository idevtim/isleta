import Foundation
import IslandActivities
import IslandKit

#if canImport(IOBluetooth)
import CoreBluetooth
import IOBluetooth
#endif

/// One route to "a Bluetooth audio device just connected".
///
/// A protocol for the same reason `NowPlayingProvider` and `NotificationSource` are: the real
/// implementation needs a Bluetooth radio and paired hardware, and the source's own behavior —
/// deduplicating a burst, filtering the BLE half, publishing once — has to be testable without
/// either. `UnavailableBluetoothMonitor` is the fallback, and it is what runs when the SPI below
/// ever stops answering.
@MainActor
public protocol BluetoothDeviceMonitoring: AnyObject {

    /// Whether this monitor can observe anything at all.
    var isAvailable: Bool { get }

    /// What TCC currently allows, read live rather than cached — the user can change it in System
    /// Settings while Isleta is running.
    ///
    /// On the protocol rather than only on the concrete monitor because the denied state is what
    /// §10 requires a test for, and the denied state needs no radio and no hardware to describe.
    var authorization: SourceAuthorization { get }

    /// Whether the battery percentages are reachable, as opposed to only the fact of connection.
    ///
    /// Separate from `isAvailable` because the two degrade separately and the island draws
    /// differently for each: without the battery the device still gets its picture in the notch,
    /// with no ring beside it.
    var reportsBattery: Bool { get }

    /// Begin observing. The handler is called for every connection, including — measured on
    /// macOS 27.0 — three or four times for one physical AirPods connect. Deduplication belongs to
    /// the caller, which is where the activity's identity is decided.
    ///
    /// `origin` separates a device that *just* connected from one that was already connected when
    /// observation began. Reported rather than filtered here so the decision is made somewhere it
    /// can be tested without hardware — see `BluetoothDeviceSource.announce`.
    func start(onConnect: @escaping (BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void)

    /// Resolve a Bluetooth address into a device and publish it through `start`'s handler, or do
    /// nothing if it is not paired, not audio, or gone.
    ///
    /// **The address arrives from CoreAudio and the answer leaves through the same door as a connect
    /// notification**, which is the point: `AudioRouteMonitoring` knows a MAC and nothing else, and
    /// turning that into a name, a kind and two battery percentages is work `connection(from:)`
    /// already does. Publishing it here rather than returning it keeps IOBluetooth in one place and
    /// leaves `BluetoothDeviceSource` with one handler to deduplicate rather than two paths to
    /// reconcile.
    ///
    /// Resolves off the main thread, because `IOBluetoothDevice.pairedDevices()` reaches the same
    /// coordinator whose initialiser deadlocked the app at launch — see `coordinatorQueue`.
    func publishConnection(at address: String, origin: BluetoothConnectionOrigin)

    func stop()
}

/// Whether a connection is news.
///
/// The distinction exists because of a measurement: `IOBluetoothDevice.register(forConnectNotifications:)`
/// **replays every already-connected device**, synchronously, inside the register call. That is
/// genuinely useful — it means launch state needs no poll — but announcing it would put an AirPods
/// island on screen every time Isleta starts, for a pair the user has had in their ears for an
/// hour. The island says "this just connected", and at launch that is not true.
public enum BluetoothConnectionOrigin: Equatable, Sendable {

    /// The device connected while Isleta was watching. The only kind worth showing.
    case connected

    /// The device was already connected when observation began — the registration replay.
    case alreadyConnectedAtStart
}

/// Where System Settings puts the Bluetooth privacy list, for the row's deep link.
///
/// Spelled beside the monitor rather than in the app shell so the pane name and the state that
/// sends a user to it are written down in one place — the same arrangement
/// `AudioBadgeAccessibility` uses for Accessibility.
public enum BluetoothPrivacySettings {
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
}

/// The monitor for a machine with no Bluetooth, or an OS that has taken the SPI away.
///
/// Not an error path: a Mac with the radio off is a normal Mac, and the correct behavior is that
/// no device ever connects and nothing is ever shown. §10's denied-state rule, in its mildest form.
@MainActor
public final class UnavailableBluetoothMonitor: BluetoothDeviceMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    /// Nothing is being refused: a Mac with no radio is not a Mac that could have this and doesn't.
    public var authorization: SourceAuthorization { .notRequired }
    public var reportsBattery: Bool { false }
    public func start(onConnect: @escaping (BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void) {}
    public func publishConnection(at address: String, origin: BluetoothConnectionOrigin) {}
    public func stop() {}
}

#if canImport(IOBluetooth)

/// `IOBluetooth`, asked at runtime for things its headers do not admit to.
///
/// ## Why this is the third exception, and what it is held to
///
/// §Working agreements sanction two private paths — the `mediaremote-adapter` helper and
/// `SkyLightOverlaySpace` — and say a third needs the same measurement those two got first. This is
/// that third, and unlike them it is not a private *framework*: `IOBluetooth` is public, linked
/// normally, and the connect notification used here is documented API. What is undocumented is five
/// selectors on `IOBluetoothDevice` carrying the battery percentages.
///
/// So it is held to the same three rules: resolved at runtime rather than declared, behind this
/// protocol, with a fallback that degrades to showing the connection without the charge.
///
/// ## What was measured, on macOS 27.0 with a connected AirPods Pro
///
/// There is **no other route**. The IORegistry — which is where every guide and every other menu
/// bar app looks — holds no AirPods battery at all: a sweep of the entire tree for any key
/// containing "battery" returned the Mac's own pack and nothing else, and
/// `AppleDeviceManagementHIDEventService` had only the internal keyboard under it.
/// `system_profiler SPBluetoothDataType` does report the numbers, but it shells out, takes over a
/// second, and — the trap — **reports battery for devices that are not connected**, from a cache:
/// it showed a pair of AirPods Pro at 100/100/93 while they were shut in their case.
///
/// The connect notification is genuinely push and needs no permission prompt, and registering for
/// it fires immediately for devices already connected — so there is nothing to poll at launch
/// either.
@MainActor
public final class IOBluetoothDeviceMonitor: NSObject, BluetoothDeviceMonitoring {

    /// The five selectors, named as strings because that is the whole point — nothing here is
    /// declared, so an OS that removes them makes `reportsBattery` false instead of failing to link.
    private enum Battery {
        static let left = "batteryPercentLeft"
        static let right = "batteryPercentRight"
        static let single = "batteryPercentSingle"
    }

    private var onConnect: ((BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void)?
    private var connectNotification: IOBluetoothUserNotification?

    /// True only for the duration of the `register` call, which is exactly when the already-connected
    /// replay is delivered.
    ///
    /// Locked rather than plain, and `nonisolated(unsafe)` rather than main-actor, because the two
    /// sides genuinely run on different threads: measured on macOS 27.0, `register` blocks the
    /// calling thread while the replay is delivered on **another** one. So the flag is written on
    /// the main thread and read off it, within a window that ends when `register` returns.
    private nonisolated(unsafe) var isReplayingExistingConnections = false
    private nonisolated let replayLock = NSLock()

    /// Where the coordinator is woken, and **the reason this class has a queue at all**.
    ///
    /// `+[IOBluetoothHostController defaultController]` looks like an accessor and is a
    /// `dispatch_once` that builds `IOBluetoothCoreBluetoothCoordinator`, and that initialiser
    /// **waits on a dispatch semaphore** for its `CBCentralManager` to answer. Measured on
    /// macOS 27.0 by `sample`, from a build launched with `open -a`: the reply is delivered through
    /// the main queue, so calling this from `applicationDidFinishLaunching` — which *is* a block on
    /// the main queue — is a deadlock with no timeout. The main thread sat in `semaphore_wait_trap`
    /// under `-[IOBluetoothCoreBluetoothCoordinator init]` for minutes, `startSources()` never
    /// returned, and every source after Bluetooth in the list never started. Nothing was logged,
    /// nothing crashed, and no report was generated.
    ///
    /// It did not reproduce from a shell, for the reason CLAUDE.md gives about `open -a`: a
    /// Terminal-launched probe is attributed to Terminal, whose Bluetooth grant is already decided,
    /// and the coordinator answered in 3 ms. That is the same instrument that made this look safe
    /// for two releases.
    ///
    /// So the first touch happens here, off the main thread, and the main queue stays free to drain
    /// the reply the semaphore is waiting for. Once `dispatch_once` has run, every later call is
    /// immediate — which is why `register` below is still on the main actor, unchanged.
    private static let coordinatorQueue = DispatchQueue(label: "com.tryisleta.bluetooth.coordinator")

    /// The answer from the last completed probe, and `nil` until one has completed.
    ///
    /// Cached rather than asked, because asking is the deadlock above. It reads `false` for the few
    /// milliseconds between `start()` and the queue answering — a window in which the settings row
    /// says the radio is absent — and that is the honest reading: at that instant Isleta genuinely
    /// does not know, and claiming a radio it has not found would be the worse of the two.
    private var hostControllerPresent: Bool?

    public override init() { super.init() }

    public var isAvailable: Bool { hostControllerPresent ?? false }

    /// **This is a permission, and 1.3.0 was cut believing it was not.**
    ///
    /// `IOBluetoothDevice.register(forConnectNotifications:)` reads as classic IOBluetooth, which is
    /// not TCC-gated — but it builds an `IOBluetoothCoreBluetoothCoordinator` underneath, and that
    /// coordinator's `CBCentralManager` files a TCC access request. Without
    /// `NSBluetoothAlwaysUsageDescription` in the app's Info.plist, TCC does not deny the request:
    /// it aborts the process, 270 ms into launch, before the island is ever drawn.
    ///
    /// It could not be seen from a shell. TCC judges a request against the *responsible* process,
    /// and a build launched from Terminal inherits Terminal's usage strings and grant — so
    /// `--perf-report` and every hardware check ran the whole feature, reported "battery readable",
    /// and proved nothing about a real launch. `open -a Isleta` is the only verification that
    /// counts here.
    ///
    /// Read from `CBManager` rather than remembered, because the answer changes in System Settings
    /// while we are running, and no notification announces it.
    public var authorization: SourceAuthorization {
        switch CBManager.authorization {
        case .allowedAlways:
            return .granted
        case .notDetermined:
            // Transient in practice: the prompt is raised by `start()`, at launch. It is still a
            // real state — a user who dismisses the dialog without answering sits here — and it is
            // not `.denied`, because nothing has been refused yet.
            return .undetermined
        case .restricted:
            return .denied(explanation: sourceText(
                "bluetooth.authorization.restricted",
                "Bluetooth access is restricted on this Mac, so devices connecting cannot be shown."
            ))
        case .denied:
            return .denied(explanation: sourceText("bluetooth.authorization.denied", """
                Isleta cannot see Bluetooth devices connecting. Allow Bluetooth for Isleta in \
                System Settings ▸ Privacy & Security ▸ Bluetooth.
                """))
        @unknown default:
            return .undetermined
        }
    }

    /// Asked of the class rather than of a device, so it is answerable with nothing connected —
    /// which is when IslandSettings needs to know.
    public var reportsBattery: Bool {
        [Battery.left, Battery.right, Battery.single].allSatisfy {
            IOBluetoothDevice.instancesRespond(to: NSSelectorFromString($0))
        }
    }

    /// Wake the coordinator off the main thread, then register on it.
    ///
    /// Two steps rather than one because only the first is dangerous. `coordinatorQueue` above holds
    /// why the wake cannot happen here; the registration must, because the replay bracket below is a
    /// main-actor discriminator and because `register` is what publishes into the activity stack.
    public func start(onConnect: @escaping (BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void) {
        guard connectNotification == nil, !isWakingCoordinator else { return }
        isWakingCoordinator = true
        self.onConnect = onConnect
        Self.coordinatorQueue.async {
            let present = IOBluetoothHostController.default() != nil
            Task { @MainActor [weak self] in self?.register(hostControllerPresent: present) }
        }
    }

    /// True from `start()` until the queue answers, so a second `start()` in that window does not
    /// queue a second wake — `connectNotification` is still nil and cannot guard it on its own.
    private var isWakingCoordinator = false

    private func register(hostControllerPresent present: Bool) {
        isWakingCoordinator = false
        hostControllerPresent = present
        guard present else {
            IslandLog.sources.info("Bluetooth: no host controller, source idle")
            return
        }
        // `stop()` while the wake was in flight. Nothing to unregister and nowhere to publish, so
        // the registration is simply not made — the alternative is a live notification with no
        // handler behind it.
        guard onConnect != nil else { return }

        // **Measured on macOS 27.0: the already-connected replay arrives *inside* this call.** A
        // probe printing either side of it saw the callback for a connected AirPods Pro land
        // between "before register" and "after register", on thread 2 while the main thread was
        // still blocked in the call. So bracketing it is an exact discriminator — a real connect
        // cannot be mistaken for a replay, and no timing window has to be guessed at.
        //
        // Without this the island announced the user's AirPods on every launch, and — because the
        // island then animated inside `--perf-report`'s idle window — read 0.85% against a 0.3%
        // budget for a source that keeps no timer at all.
        replayLock.withLock { isReplayingExistingConnections = true }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        replayLock.withLock { isReplayingExistingConnections = false }
        if connectNotification == nil {
            IslandLog.sources.info("Bluetooth: could not register for connect notifications")
            return
        }
        // Logged here rather than from the source, because here is the first moment the answer is
        // real. `SourceHub`'s generic "started — authorization:" line runs while the wake is still in
        // flight and reads `notRequired` from the not-yet-known radio, which is true of the instant
        // and misleading about the machine.
        IslandLog.sources.info("Bluetooth: watching for device connections — authorization: \(authorization)")
    }

    public func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        onConnect = nil
    }

    /// Matched on `addressString` case-insensitively, because the two sides genuinely disagree:
    /// CoreAudio's UID spells the MAC in upper case (`04-9D-05-6B-19-80:output`) and IOBluetooth's
    /// `addressString` in lower (`04-9d-05-6b-19-80`). `CoreAudioRouteMonitor` already lowercases,
    /// so this is the belt to that braces — a device whose address arrived from somewhere else must
    /// not silently fail to match.
    ///
    /// `connection(from:)` does the rest, which means the route path inherits its two rejections for
    /// free: a class of zero and anything that is not audio. A Magic Mouse cannot become the system
    /// output, but a device with a class of zero is exactly what the BLE half of an AirPods connect
    /// looks like, and the island must not draw an empty one.
    public func publishConnection(at address: String, origin: BluetoothConnectionOrigin) {
        let wanted = address.lowercased()
        Self.coordinatorQueue.async { [weak self] in
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let match = paired.first { $0.addressString?.lowercased() == wanted }
            guard let connection = match.flatMap({ Self.connection(from: $0) }) else { return }
            Task { @MainActor [weak self] in self?.onConnect?(connection, origin) }
        }
    }

    /// **`nonisolated`, and it is not a formality.**
    ///
    /// IOBluetooth does not deliver this on the main queue. Measured by crash on macOS 27.0: the
    /// callback arrives on CoreBluetooth's own XPC queue, by way of
    /// `-[IOBluetoothCoreBluetoothCoordinator centralManager:connectionEventDidOccur:forPeripheral:]`
    /// posting through `NSNotificationCenter`. An `@objc` method on a `@MainActor` class compiles
    /// clean, links, runs — and then `dispatch_assert_queue` fails inside Swift's isolation check
    /// and the process takes SIGTRAP the first time a device connects. Nothing warns, and it cannot
    /// happen until there is real hardware to connect, so it survives every test.
    ///
    /// The device is therefore read **here**, on the delivering queue, and only the pure `Sendable`
    /// value hops. That is also the right place to read it: this is the instant the percentages are
    /// freshest, and it avoids handing a non-`Sendable` `IOBluetoothDevice` across isolation.
    @objc private nonisolated func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard let connection = Self.connection(from: device) else { return }
        let origin: BluetoothConnectionOrigin = replayLock.withLock {
            isReplayingExistingConnections ? .alreadyConnectedAtStart : .connected
        }
        Task { @MainActor [weak self] in
            self?.onConnect?(connection, origin)
        }
    }

    /// A device, read once, or nil if it is not something to announce.
    ///
    /// Two rejections, both measured rather than defensive:
    ///
    /// - **`classOfDevice == 0`.** One physical AirPods connect fires this notification at the
    ///   classic address *and* at a BLE random address; the BLE half reports a class of zero and
    ///   zero for every battery field. Published, it is a second, empty island for the same event.
    /// - **Anything that is not audio.** A Magic Mouse and an iPhone both fire this too, and the
    ///   island has nothing to say about either that the user did not already know.
    nonisolated static func connection(from device: IOBluetoothDevice) -> BluetoothDeviceConnection? {
        let classOfDevice = device.classOfDevice
        guard classOfDevice != 0 else { return nil }

        // Bluetooth major class 4 is "Audio/Video". Minor classes 1, 2, 4, 6 are headset, hands
        // free, headphones and "portable audio" — the things a person wears or carries. Everything
        // else in the major class is a television, a camcorder or a set-top box.
        let major = (classOfDevice >> 8) & 0x1F
        let minor = (classOfDevice >> 2) & 0x3F
        guard major == 4 else { return nil }
        let isWorn = [1, 2, 4, 6].contains(Int(minor))

        let object = device as NSObject
        func percent(_ selector: String) -> Int? {
            guard object.responds(to: NSSelectorFromString(selector)) else { return nil }
            return object.value(forKey: selector) as? Int
        }

        let kind = BluetoothDeviceKind.resolve(
            vendorID: percent("vendorID"),
            productID: percent("productID"),
            isWorn: isWorn
        )

        return BluetoothDeviceConnection(
            name: device.name ?? device.nameOrAddress ?? "Device",
            address: device.addressString ?? "unknown",
            kind: kind,
            battery: BluetoothDeviceBattery(
                left: percent(Battery.left),
                right: percent(Battery.right),
                single: percent(Battery.single)
            )
        )
    }
}

#endif
