import IslandKit
import AudioToolbox
import CoreAudio
import Foundation

/// What an audio observer tells `SystemHUDSource`.
public enum SystemHUDAudioEvent: Equatable, Sendable {

    /// A level moved. Worth a HUD if it really moved — `SystemHUDLevelState` decides.
    case changed(SystemHUDAudioSnapshot)

    /// The default output device itself changed. Never worth a HUD: the number is different because
    /// the destination is, not because the user asked for it.
    case deviceChanged(SystemHUDAudioSnapshot)
}

/// The seam `SystemHUDSource` is written against, so its behavior is testable without CoreAudio,
/// without an audio device, and without a machine that has any output at all.
@MainActor
public protocol SystemHUDAudioObserving: AnyObject {

    /// Set before `start()`. Called on the main actor.
    var onEvent: ((SystemHUDAudioEvent) -> Void)? { get set }

    /// The levels right now, for use as a baseline. A read, not a subscription.
    func snapshot() -> SystemHUDAudioSnapshot

    /// Idempotent.
    func start()

    /// Must leave no listener registered.
    func stop()

    var isRunning: Bool { get }
}

/// Observes the default output device's volume and mute through CoreAudio property listeners.
///
/// This is the one system level in §2.6 that needs no permission, no helper process and no polling:
/// `AudioObjectAddPropertyListenerBlock` is public, unentitled, and pushes. It also fires for
/// changes Isleta did not cause and did not see a key for — Control Center, a slider in Music,
/// `osascript` — which an event tap on the volume keys would miss entirely. That is why the levels
/// are observed rather than the keys.
@MainActor
public final class SystemHUDAudioObserver: SystemHUDAudioObserving {

    public var onEvent: ((SystemHUDAudioEvent) -> Void)?

    public private(set) var isRunning = false

    /// Callbacks land here, off the main actor, and read the new levels before hopping. The
    /// `ActivitySource` contract asks for exactly this shape: do the work wherever it belongs, hop
    /// once to publish.
    private let queue = DispatchQueue(label: "com.tryisleta.isleta.systemhud.audio")

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var registrations: [Registration] = []

    public init() {}

    deinit {
        // `stop()` is main-actor isolated and deinit is not, so the registrations are torn down
        // here directly rather than by calling it. A listener block outliving its observer is not
        // merely a leak: CoreAudio would keep invoking it against a freed capture.
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
    }

    /// How many listener blocks CoreAudio is currently holding on our behalf. Internal, for the
    /// test that "stopped" really means stopped — §9's idle budget is measured with sources running,
    /// so a source that stops without unregistering is a source that spends the budget invisibly.
    var registrationCount: Int { registrations.count }

    /// Reads whichever device is default, running or not.
    ///
    /// Deliberately not "the device I am bound to, or nothing": `SystemHUDSource.supportedHUDs` asks
    /// this before `start()` and after `stop()`, and answering `.unavailable` there told the app
    /// that a Mac with working speakers had no volume to show. Bound device first only so that a
    /// snapshot taken between a default-device change and the rebind describes the device whose
    /// listener actually fired.
    public func snapshot() -> SystemHUDAudioSnapshot {
        let target = device == AudioObjectID(kAudioObjectUnknown)
            ? SystemHUDAudioReader.defaultOutputDevice()
            : device
        return SystemHUDAudioReader.snapshot(of: target)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        observeDefaultOutputDevice()
        bindToCurrentDefaultDevice()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
        registrations.removeAll()
        device = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Binding

    private func observeDefaultOutputDevice() {
        register(
            on: AudioObjectID(kAudioObjectSystemObject),
            address: SystemHUDAudioReader.defaultOutputDeviceAddress
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.bindToCurrentDefaultDevice()
                self.onEvent?(.deviceChanged(self.snapshot()))
            }
        }
    }

    /// Point the level listeners at whichever device is default now.
    ///
    /// The device id is re-resolved rather than remembered across a change, and the old device's
    /// listeners are removed first. Leaving them attached is the bug that makes a HUD appear when
    /// somebody adjusts the volume of a Bluetooth speaker that has not been the output for an hour.
    private func bindToCurrentDefaultDevice() {
        removeDeviceRegistrations()

        device = SystemHUDAudioReader.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            IslandLog.audio.warning("no default output device — no volume or mute listener")
            return
        }
        let boundDevice = device

        // `AudioObjectHasProperty` is the gate, not the status returned by
        // `AudioObjectAddPropertyListenerBlock`. Registering for a property the device does not have
        // returns `noErr` and then never fires — verified on macOS 26, where the built-in output
        // has no main-element `kAudioDevicePropertyVolumeScalar` at all and a listener on it sat
        // silent through every volume change.
        if let level = SystemHUDAudioReader.levelAddress(for: boundDevice) {
            register(on: boundDevice, address: level) { [weak self] in
                let snapshot = SystemHUDAudioReader.snapshot(of: boundDevice)
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.device == boundDevice else { return }
                    self.onEvent?(.changed(snapshot))
                }
            }
        }

        var mute = SystemHUDAudioReader.muteAddress
        let hasMute = AudioObjectHasProperty(boundDevice, &mute)
        if hasMute {
            register(on: boundDevice, address: mute) { [weak self] in
                let snapshot = SystemHUDAudioReader.snapshot(of: boundDevice)
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.device == boundDevice else { return }
                    self.onEvent?(.changed(snapshot))
                }
            }
        }
        // Which properties the device turned out to have is the whole diagnosis when a HUD never
        // appears — see the note above about the built-in output and `VolumeScalar`.
        IslandLog.audio.info(
            "bound to output device \(boundDevice) — level listener: "
            + "\(SystemHUDAudioReader.levelAddress(for: boundDevice) != nil ? "yes" : "no property"), "
            + "mute listener: \(hasMute ? "yes" : "no property")"
        )
    }

    private func removeDeviceRegistrations() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for registration in registrations where registration.object != system {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
        registrations.removeAll { $0.object != system }
    }

    /// The snapshot is read on `queue` inside the callback and delivered in order, because
    /// `DispatchQueue.main.async` is FIFO and `Task { @MainActor in }` is not. Out-of-order delivery
    /// here would publish a stale level as the newest one — invisible in testing and wrong on screen
    /// exactly when the user holds the volume key down.
    private func register(
        on object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async(execute: handler)
        }
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            IslandLog.audio.warning("listener registration failed with status \(status) on object \(object)")
            return
        }
        registrations.append(Registration(object: object, address: address, block: block))
    }

    /// `@unchecked Sendable` so `deinit` — which is nonisolated — can reach the registrations it has
    /// to unwind. The block inside is never called by us and never inspected; it is an opaque token
    /// handed straight back to `AudioObjectRemovePropertyListenerBlock`, and `deinit` has exclusive
    /// access to the array by definition.
    private struct Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}

/// The CoreAudio reads, with no state and no isolation, so a listener block can call them from
/// whatever queue CoreAudio hands it.
enum SystemHUDAudioReader {

    static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Candidates in the order they are worth trying, which is *not* the order the documentation
    /// suggests. On macOS 26 the built-in output reports no main-element `VolumeScalar`; the
    /// property that exists, tracks the volume keys and matches what the system HUD draws is
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`. The per-channel scalars are the
    /// fallback for devices that expose no virtual main at all.
    private static let levelCandidates: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        ),
    ]

    static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputDeviceAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func levelAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        levelCandidates.first { candidate in
            var address = candidate
            return AudioObjectHasProperty(device, &address)
        }
    }

    static func snapshot(of device: AudioObjectID) -> SystemHUDAudioSnapshot {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return .unavailable }
        return SystemHUDAudioSnapshot(volume: volume(of: device), isMuted: isMuted(of: device))
    }

    static func volume(of device: AudioObjectID) -> Double? {
        guard var address = levelAddress(for: device) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? Double(value) : nil
    }

    static func isMuted(of device: AudioObjectID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }
}
