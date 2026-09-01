import AudioToolbox
import CoreAudio
import Foundation
import IslandKit

/// What the audio system is doing with the microphone, at one instant.
public struct CallInputActivity: Equatable, Sendable {

    /// Whether the **default input device** is running for somebody. The edge that matters:
    /// measured at **105 ms** behind a real capture starting.
    public let isInputRunning: Bool

    /// The bundle identifiers of the processes recording, read **on the edge only**.
    ///
    /// Empty when nothing is running, and empty is not the same as "unknown": the list is asked for
    /// only when `isInputRunning` has just become true, because reading it costs **39 ms** for 49
    /// process objects and doing that on any schedule at all would be the poll §9 forbids.
    public let bundleIdentifiers: [String]

    public init(isInputRunning: Bool, bundleIdentifiers: [String] = []) {
        self.isInputRunning = isInputRunning
        self.bundleIdentifiers = bundleIdentifiers
    }
}

/// The seam `CallSource` is written against, so a call can be tested without one.
@MainActor
public protocol CallAudioObserving: AnyObject {
    var onChange: ((CallInputActivity) -> Void)? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// Whether a call is happening, from the only signal macOS gives an unentitled app.
///
/// # Everything that answers "who is calling" is behind an entitlement Apple keeps
///
/// `TUCallCenter` and `CXCallObserver` both instantiate, both accept every call made to them, and
/// both return an **empty array forever** — `callservicesd`'s own log says why, about us: *"Rejecting
/// client … because it lacks the access-calls capability"*. The entitlement
/// (`com.apple.telephonyutilities.callservicesd`) is held by `/System/Applications/FaceTime.app` and
/// by no third-party app on this machine. The trap is the shape of
/// the failure — nothing errors, nothing logs in *our* process, and a source built on it reports
/// healthy and shows a call exactly never.
///
/// # One signal is ungated, and it is push
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device pushes: a real capture
/// starting produced a callback **105 ms** later. `kAudioHardwarePropertyProcessObjectList` then
/// names the processes, each carrying `kAudioProcessPropertyIsRunningInput` and
/// `kAudioProcessPropertyBundleID`. Both need no permission at all.
///
/// # The process list on its own is not the signal, and this machine proves it
///
/// Read cold while nothing was happening, the list reported **`com.apple.CoreSpeech` running input**
/// — Siri's always-on listener — while the default input device reported `isRunningSomewhere == 0`.
/// So a source that watched the process list would announce a call that nobody made, permanently.
/// The device edge is the gate; the list only says who, and `CallDetection` decides whether "who" is
/// a call at all.
@MainActor
public final class CoreAudioCallObserver: CallAudioObserving {

    public var onChange: ((CallInputActivity) -> Void)?

    public private(set) var isRunning = false

    /// Callbacks land here, off the main actor, and hop once — the shape `SystemHUDAudioObserver`
    /// uses and the shape `ActivitySource` asks for.
    private let queue = DispatchQueue(label: "com.tryisleta.isleta.call.audio")

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var registrations: [Registration] = []

    public init() {}

    deinit {
        // `stop()` is main-actor isolated and `deinit` is not, so the listener blocks are unwound
        // here directly. A block outliving its observer is not merely a leak: CoreAudio would go on
        // invoking it against a freed capture.
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
    }

    /// How many listener blocks CoreAudio holds for us. Internal, for the test that "stopped" means
    /// stopped — §9's idle budget is measured with sources running.
    var registrationCount: Int { registrations.count }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observeDefaultInputDevice()
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

    private func observeDefaultInputDevice() {
        register(on: AudioObjectID(kAudioObjectSystemObject), address: CallAudioReader.defaultInputAddress) {
            [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.bindToCurrentDefaultDevice()
            }
        }
    }

    /// Point the running listener at whichever device is the input now.
    ///
    /// Re-resolved rather than remembered, with the old device's listener removed first: leaving it
    /// attached is what makes a call appear because somebody else's USB microphone started, an hour
    /// after it stopped being the input. `SystemHUDAudioObserver` records the same bug in the
    /// opposite direction.
    private func bindToCurrentDefaultDevice() {
        removeDeviceRegistrations()
        device = CallAudioReader.defaultInputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            IslandLog.audio.info("call: no default input device — nothing to watch")
            return
        }
        let bound = device

        // `AudioObjectHasProperty` is the gate, never the status from
        // `AudioObjectAddPropertyListenerBlock`: registering for a property a device does not have
        // returns `noErr` and then never fires, which is a source that compiles, starts, reports
        // success and observes nothing.
        var address = CallAudioReader.isRunningSomewhereAddress
        guard AudioObjectHasProperty(bound, &address) else {
            IslandLog.audio.info("call: input device has no running property — nothing to watch")
            return
        }
        register(on: bound, address: address) { [weak self] in
            // Read on the CoreAudio queue, where it is freshest, and hop the value — the same order
            // `SystemHUDAudioObserver` uses so that deliveries stay in the order they happened.
            let reading = CallAudioReader.reading(of: bound)
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.device == bound else { return }
                self.onChange?(reading)
            }
        }
        IslandLog.audio.info("call: watching the default input device")
    }

    private func removeDeviceRegistrations() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for registration in registrations where registration.object != system {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
        registrations.removeAll { $0.object != system }
    }

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
            IslandLog.audio.warning("call: listener registration failed with status \(status)")
            return
        }
        registrations.append(Registration(object: object, address: address, block: block))
    }

    /// `@unchecked Sendable` for `SystemHUDAudioObserver`'s reason: the block is never called by us
    /// and never inspected — it is an opaque token handed straight back to CoreAudio — and `deinit`
    /// has exclusive access to the array by definition.
    private struct Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}

/// The CoreAudio reads, with no state and no isolation, so a listener block can call them from
/// whatever queue CoreAudio hands it.
enum CallAudioReader {

    static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let isRunningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func defaultInputDevice() -> AudioObjectID {
        var address = defaultInputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// One reading: is the input running, and — **only if it is** — who is running it.
    ///
    /// The conditional is the §9 rule in one line. Enumerating the process objects costs 39 ms for
    /// 49 of them, so it happens on the rising edge of a capture and at no other time.
    static func reading(of device: AudioObjectID) -> CallInputActivity {
        let isRunning = isRunningSomewhere(device)
        return CallInputActivity(
            isInputRunning: isRunning,
            bundleIdentifiers: isRunning ? processesRunningInput() : []
        )
    }

    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = isRunningSomewhereAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Every process CoreAudio says is recording, by bundle identifier.
    static func processesRunningInput() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        return objects.compactMap { object in
            guard isRunningInput(object) else { return nil }
            return bundleIdentifier(of: object)
        }
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// The bundle identifier, read through an `Unmanaged` rather than into a `CFString?` variable.
    ///
    /// Handing CoreAudio the address of an optional class reference compiles and raises a warning
    /// about forming a raw pointer to a variable that "may contain an object reference" — which
    /// under `Tools/check.sh`'s `-warnings-as-errors` is a build failure, and without it is a real
    /// ownership bug: the callee writes a +1 reference over a variable ARC believes it owns.
    private static func bundleIdentifier(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var raw: UnsafeRawPointer?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }
}
