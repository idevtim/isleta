import AudioToolbox
import CoreAudio
import Foundation
import IslandKit

/// One route to "a Bluetooth audio device is what you are listening through now".
///
/// # Why this exists beside `BluetoothDeviceMonitoring`
///
/// Because IOBluetooth does not have the event. **Measured 2026-08-30 on macOS 27.0, with AirPods
/// Pro and one probe watching five signals at once:**
///
/// | what the user did | IOBluetooth | CoreAudio default output |
/// |---|---|---|
/// | case → ears | `CONNECT` ×4 | → AirPods |
/// | out of ears | *silent* | → speakers |
/// | back in ears | *silent* | → AirPods |
/// | → case | `DISCONNECT` ×4 | → speakers |
///
/// Taking AirPods out of your ears is **not a Bluetooth disconnect**. The link stays up — the paired
/// device's `isConnected()` never goes false, and no notification fires in either direction — so a
/// source listening only to IOBluetooth is right to say nothing and the island stays empty. What
/// actually moves is the *route*: the system output device changes, twice, and that is the event a
/// person means when they say the AirPods reconnected.
///
/// So this is the second half of the same feature rather than a feature of its own, and it publishes
/// into the same `deviceConnected` activity. `BluetoothDeviceSource` owns both and collapses them —
/// a genuine connect fires IOBluetooth at `.553` and this at `.797`, 244 ms apart, and the source's
/// address-keyed window makes them one island rather than two.
///
/// # What it costs
///
/// Nothing on the idle path. `AudioObjectAddPropertyListenerBlock` is public, unentitled and pushes,
/// which is the same argument `SystemHUDAudioObserver` makes for observing levels rather than keys —
/// and it means this hears a route change Isleta did not cause and saw no key for, which is most of
/// them: Control Center, an app grabbing the route, the ear-detection above.
@MainActor
public protocol AudioRouteMonitoring: AnyObject {

    /// Whether CoreAudio can answer at all.
    var isAvailable: Bool { get }

    /// Begin observing. The handler is called with the **Bluetooth address** of the device that has
    /// become the system output, never with a name — resolving that address into a device is
    /// IOBluetooth's job and belongs in one place, which is `BluetoothDeviceMonitoring`.
    ///
    /// `origin` separates a route that *changed* from the one that was already in effect when
    /// observation began, for exactly the reason the connect notification's replay is separated:
    /// announcing the latter would put an AirPods island on screen every time Isleta starts, for a
    /// pair the user has been listening to for an hour.
    func start(onBluetoothOutput: @escaping (String, BluetoothConnectionOrigin) -> Void)

    func stop()
}

/// The monitor for a machine whose CoreAudio cannot answer.
///
/// Not an error path, and the same shape as `UnavailableBluetoothMonitor`: nothing is observed,
/// nothing is published, and the island simply never says a device arrived by this route. The
/// IOBluetooth half keeps working on its own.
@MainActor
public final class UnavailableAudioRouteMonitor: AudioRouteMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(onBluetoothOutput: @escaping (String, BluetoothConnectionOrigin) -> Void) {}
    public func stop() {}
}

/// `kAudioHardwarePropertyDefaultOutputDevice`, watched for Bluetooth arriving on it.
@MainActor
public final class CoreAudioRouteMonitor: AudioRouteMonitoring {

    private var onBluetoothOutput: ((String, BluetoothConnectionOrigin) -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private var isRunning = false

    /// The address published last, so a change that lands on the device already announced is not
    /// announced again.
    ///
    /// This is not the burst window — `BluetoothDeviceSource.recentlyAnnounced` is, and it is about
    /// time. This is about *identity*, and it is what keeps the island quiet when CoreAudio
    /// republishes the same default. Measured: one ear-in fires the device-list property twice and
    /// the default-device property once, and the list settles on the value it already had.
    private var lastPublishedAddress: String?

    public init() {}

    public var isAvailable: Bool {
        SystemHUDAudioReader.defaultOutputDevice() != AudioObjectID(kAudioObjectUnknown)
    }

    public func start(onBluetoothOutput: @escaping (String, BluetoothConnectionOrigin) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.onBluetoothOutput = onBluetoothOutput

        // The route in effect at launch, recorded and **not** announced. Same rule as the connect
        // notification's replay: the island's sentence is "this just arrived", and at launch that is
        // not true of whatever the user was already listening through.
        if let address = Self.bluetoothAddressOfDefaultOutput() {
            lastPublishedAddress = address
            onBluetoothOutput(address, .alreadyConnectedAtStart)
        }

        var address = SystemHUDAudioReader.defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Read on the delivering queue, where the value is freshest, and hop with a `String`.
            // The same shape `IOBluetoothDeviceMonitor.deviceConnected` uses, and for the same
            // reason: nothing non-`Sendable` crosses isolation.
            let resolved = Self.bluetoothAddressOfDefaultOutput()
            Task { @MainActor [weak self] in self?.publish(resolved) }
        }
        listener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else {
            IslandLog.audio.info("route: could not watch the default output device")
            listener = nil
            return
        }
        IslandLog.audio.info("route: watching the default output device for Bluetooth arrivals")
    }

    public func stop() {
        guard isRunning else { return }
        if let listener {
            var address = SystemHUDAudioReader.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
            )
        }
        listener = nil
        onBluetoothOutput = nil
        lastPublishedAddress = nil
        isRunning = false
    }

    /// - Parameter address: the Bluetooth address now on the output, or nil for anything else.
    ///
    /// A route that moves *away* from Bluetooth — to the speakers, when the AirPods come out of the
    /// ears — clears the memory rather than announcing. That is what makes putting them back in an
    /// arrival again, and it is why this is not simply `!= lastPublishedAddress`: without the clear,
    /// speakers → AirPods → speakers → AirPods would announce once.
    private func publish(_ address: String?) {
        guard isRunning else { return }
        guard let address else {
            lastPublishedAddress = nil
            return
        }
        guard address != lastPublishedAddress else { return }
        lastPublishedAddress = address
        onBluetoothOutput?(address, .connected)
    }

    /// The system output's Bluetooth address, or nil if the output is not Bluetooth.
    ///
    /// **The transport type is the gate, and the UID is the answer.** A Bluetooth output device's
    /// `kAudioDevicePropertyDeviceUID` carries the MAC address ahead of a colon — measured,
    /// `04-9D-05-6B-19-80:output` for a pair of AirPods Pro whose `IOBluetoothDevice.addressString`
    /// is `04-9d-05-6b-19-80`. So the mapping back to the paired device is exact, and needs only a
    /// lowercase. The shape is validated rather than trusted: a UID that is not six hyphenated hex
    /// pairs is some other vendor's idea of a UID and resolves to nothing, which is better than
    /// handing IOBluetooth a string to fail on.
    nonisolated static func bluetoothAddressOfDefaultOutput() -> String? {
        let device = SystemHUDAudioReader.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        guard isBluetooth(device) else { return nil }
        guard let uid = deviceUID(device) else { return nil }
        return bluetoothAddress(fromUID: uid)
    }

    /// `kAudioDeviceTransportTypeBluetooth` **and** its LE sibling. Classic is what AirPods report
    /// today; LE Audio is what the controller on this Mac already advertises, so a device that
    /// arrives on the newer transport must not be silently ignored.
    nonisolated static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    nonisolated static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (uid as String) : nil
    }

    /// Pure, so the parsing is testable with no CoreAudio and no hardware — which is the half of
    /// this that can actually be got wrong.
    nonisolated static func bluetoothAddress(fromUID uid: String) -> String? {
        let candidate = uid.split(separator: ":", maxSplits: 1).first.map(String.init) ?? uid
        let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        guard parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return candidate.lowercased()
    }
}
