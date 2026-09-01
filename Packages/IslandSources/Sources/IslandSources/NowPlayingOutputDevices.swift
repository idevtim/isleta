import AudioToolbox
import CoreAudio
import Foundation
import IslandKit

/// Reading the system's audio output devices, and moving the system to one of them.
///
/// # What this ships
///
/// The **system output device** — the same setting as the Sound menu in Control Center and the
/// Output list in System Settings. Choosing a device here moves *every* app's audio, which is what
/// a person means when they pick AirPods from the notch while a song is playing. It is entirely
/// public CoreAudio: `kAudioHardwarePropertyDevices` to enumerate,
/// `kAudioHardwarePropertyDefaultOutputDevice` to read and write, both pushed by
/// `AudioObjectAddPropertyListenerBlock`. No permission, no entitlement, no helper process, and — as
/// with volume and mute in `SystemHUDAudioObserver` — nothing on a clock.
///
/// A HomePod or an Apple TV the Mac is already AirPlaying to appears in that list with transport
/// type `kAudioDeviceTransportTypeAirPlay`, so system-wide AirPlay output is included by
/// construction rather than by a second mechanism.
///
/// # What this does not ship
///
/// **AirPlay routing *inside* Music.** Music's own AirPlay picker routes that application's audio to
/// one or more receivers and leaves everything else on the Mac's speakers; it is a different
/// destination from the system output device, and it is not reachable from a third-party process.
/// What was found either way, so it is not searched for again:
///
/// - MediaRemote does carry a route vocabulary — `kMRMediaRemotePickableRoutesDidChangeNotification`,
///   `kMRMediaRemoteRouteStatusDidChangeNotification`,
///   `kMRMediaRemoteRouteDescriptionUserInfoKey` are all declared in the vendored adapter's
///   `MediaRemote.h`. They are **notification and user-info names only**: no picker, no enumerate,
///   no select function is declared beside them, and the adapter vends no route command. So even the
///   private surface Isleta already walks through for Now Playing has nothing here to call, and
///   inventing a symbol for it is exactly what CLAUDE.md forbids.
/// - `AVAudioSession` — the API that does own per-app routing — is iOS-only. It is absent from the
///   macOS surface, so there is no session category, no `setPreferredOutput`, and no route change
///   notification to observe.
///
/// This is not a gap that a future measurement closes quietly. Per-app routing on macOS is the
/// system's business, and the honest thing the island can offer is the system-wide switch.
@MainActor
public protocol NowPlayingOutputRouting: AnyObject {

    /// Whether picking a device would actually do something. Same contract as
    /// `NowPlayingTransport.isAvailable`: the island asks before it draws, and a route that cannot
    /// answer draws no picker at all rather than a dimmed one.
    var isAvailable: Bool { get }

    /// The output devices as of the last push, the current default marked. Empty before `start()`.
    var devices: [NowPlayingOutputDevice] { get }

    /// Set before `start()`. Called on the main actor, and only when the list actually changed.
    var onDevices: (([NowPlayingOutputDevice]) -> Void)? { get set }

    /// Idempotent. Registers the listeners and publishes the first list.
    func start()

    /// Must leave no listener registered.
    func stop()

    /// Make this device the system output. Verified by reading the property back — see
    /// `CoreAudioOutputRouting.select(_:)` for the measurement that makes that mandatory.
    func select(_ id: UInt32)
}

/// The routing that is honest about having none.
///
/// The same discipline as `NowPlayingUnavailableTransport`: `isAvailable` is false, the list is
/// empty, and `select` does nothing — so a build or a machine where CoreAudio cannot answer draws no
/// device picker rather than an empty one the user keeps opening.
@MainActor
public final class UnavailableOutputRouting: NowPlayingOutputRouting {

    public init() {}

    public var isAvailable: Bool { false }

    public var devices: [NowPlayingOutputDevice] { [] }

    public var onDevices: (([NowPlayingOutputDevice]) -> Void)?

    public func start() {}

    public func stop() {}

    public func select(_ id: UInt32) {}
}

// MARK: - The value

/// One audio output device, as much of it as the island needs.
public struct NowPlayingOutputDevice: Equatable, Sendable, Identifiable {

    /// The `AudioDeviceID`, which is a `UInt32`. Carried as the underlying type rather than as
    /// `AudioObjectID` so that nothing above `IslandSources` has to import CoreAudio to hold one.
    ///
    /// **It is not stable across a disconnect.** The window server's `CGDirectDisplayID` rule
    /// applies here too: this id is assigned by the HAL when a device appears and is reused freely
    /// after it goes, so it addresses a device *now* and must never be persisted or remembered
    /// across a list change. The list is republished on every change for exactly that reason.
    public let id: UInt32

    /// What the user calls it. **Never logged** — see the note on `CoreAudioOutputRouting`.
    public let name: String

    /// Whether this is the system output right now.
    public let isDefault: Bool

    public let kind: NowPlayingOutputDeviceKind

    public init(id: UInt32, name: String, isDefault: Bool, kind: NowPlayingOutputDeviceKind) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.kind = kind
    }

    /// The SF Symbol for the row. The kind exists for this and for nothing else.
    public var symbolName: String { kind.symbolName }

    /// The same device with its default flag set. The flag is resolved separately from the device
    /// list — two properties, two listeners — so the value is built once and marked afterwards.
    public func settingIsDefault(_ isDefault: Bool) -> NowPlayingOutputDevice {
        NowPlayingOutputDevice(id: id, name: name, isDefault: isDefault, kind: kind)
    }
}

/// How a device is attached, which is the only thing CoreAudio will tell us about what it *is*.
///
/// Derived from `kAudioDevicePropertyTransportType`, plus one look at the output data source, and
/// used for one thing: choosing a glyph. It is deliberately not a model, a brand or a capability —
/// the transport type says how the audio leaves the Mac and nothing else.
public enum NowPlayingOutputDeviceKind: String, Equatable, Sendable, CaseIterable {

    /// The Mac's own speakers.
    case builtIn

    /// Something in the headphone jack. Distinguished from `builtIn` by the data source, not by the
    /// transport type — the jack is `bltn` like the speakers are.
    case headphones

    case bluetooth

    /// A receiver the Mac is AirPlaying to system-wide. Not Music's own AirPlay picker; see the
    /// protocol's note.
    case airPlay

    case hdmi

    case displayPort

    /// An aggregate device, a multi-output device, or a virtual driver such as a loopback.
    case virtual

    /// USB, Thunderbolt, PCI, FireWire, AVB, Continuity Capture, and anything the HAL cannot name.
    case external

    /// The glyph for a picker row.
    ///
    /// `bluetooth` and `external` share the neutral speaker on purpose. The transport type says a
    /// device is wireless; it does not say whether it is earbuds or a speaker on a shelf, and there
    /// is no neutral "wireless audio" symbol to fall back to — `headphones` would lie about a
    /// Bluetooth speaker and `hifispeaker.fill` would lie about AirPods. The tell does exist: it is
    /// the Bluetooth class of device that `IOBluetoothDeviceMonitor` already reads for the connect
    /// moment. Reaching into that source from here would make an output picker depend on a
    /// permission it does not need, so the glyph stays honest instead of specific.
    public var symbolName: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .headphones: "headphones"
        case .bluetooth: "speaker.wave.2.fill"
        case .airPlay: "airplayaudio"
        case .hdmi: "tv"
        case .displayPort: "display"
        case .virtual: "waveform"
        case .external: "speaker.wave.2.fill"
        }
    }
}

// MARK: - The rules

/// Everything about output devices that can be decided without CoreAudio.
///
/// Pure and static for the same reason `SystemHUDLevelState` is: this is where the bugs are, and a
/// machine with one output device and no way to plug a second one in — which is every laptop on a
/// desk — can exercise none of them at runtime. The three rules here are the classification, the
/// output-only filter, and when a push is worth publishing.
public enum NowPlayingOutputDeviceState {

    /// Data-source subtypes, from `IOAudioTypes.h`. They are not in the CoreAudio headers, so they
    /// are spelled out rather than imported; only the headphone jack is acted on, and the built-in
    /// speaker code is here because it is what the alternative reads as (measured `ispk` on this
    /// machine's `MacBook Pro Speakers`).
    static let headphoneDataSource = fourCharacterCode("hdpn")
    static let internalSpeakerDataSource = fourCharacterCode("ispk")

    /// What kind of thing a device is, from how it is attached.
    ///
    /// - Parameters:
    ///   - transportType: `kAudioDevicePropertyTransportType`, or nil if the device does not report
    ///     one. Absent is treated as `external` rather than as an error: a device that will not say
    ///     how it is attached is still a device the user can pick.
    ///   - outputDataSource: `kAudioDevicePropertyDataSource` in the **output** scope, which is what
    ///     separates the headphone jack from the speakers — both are transport `bltn`, and a
    ///     mapping keyed on transport type alone draws a laptop next to a pair of wired
    ///     headphones. Nil where the device has no data source, which is most of them.
    public static func kind(transportType: UInt32?, outputDataSource: UInt32? = nil) -> NowPlayingOutputDeviceKind {
        guard let transportType else { return .external }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return outputDataSource == headphoneDataSource ? .headphones : .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeHDMI:
            return .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            return .displayPort
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .external
        }
    }

    /// Whether a device is an output at all, from its output-scope stream configuration.
    ///
    /// The whole rule is "at least one channel". A device with zero output channels is an input —
    /// this Mac reports `MacBook Pro Microphone` and an iPhone's Continuity microphone exactly that
    /// way — and a picker that lists them offers the user a destination that plays nothing. The
    /// buffer *count* is not the test: a device can report several buffers of which some are empty,
    /// so the channels are summed.
    public static func hasOutputStreams(bufferChannelCounts: [UInt32]) -> Bool {
        bufferChannelCounts.reduce(0, +) > 0
    }

    /// Mark whichever device is the system output.
    ///
    /// Separate from building the list because the two facts arrive on two different listeners: the
    /// device list changes when hardware comes and goes, and the default changes when the user picks
    /// something. Both republish, and both go through here so the two paths cannot disagree about
    /// which row is ticked.
    public static func marking(
        defaultDeviceID: UInt32?,
        in devices: [NowPlayingOutputDevice]
    ) -> [NowPlayingOutputDevice] {
        devices.map { $0.settingIsDefault($0.id == defaultDeviceID) }
    }

    /// Whether a resolved list is worth publishing.
    ///
    /// CoreAudio pushes more often than anything changes — `kAudioHardwarePropertyDevices` fires for
    /// input devices arriving, for a virtual driver reconfiguring itself, and (measured) once for
    /// each end of an aggregate device's life, none of which the island has anything to say about.
    /// Exact equality on the whole list is the test, which covers the default moving, a device being
    /// renamed, and a device appearing or leaving, and drops everything else.
    ///
    /// Deliberately not "the ids changed": a default-device change leaves every id in place and is
    /// the single most important thing this source reports.
    public static func changed(
        from previous: [NowPlayingOutputDevice],
        to resolved: [NowPlayingOutputDevice]
    ) -> Bool {
        previous != resolved
    }

    /// `'hdpn'` as the `UInt32` CoreAudio uses. Four ASCII characters, big-endian.
    static func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - The real one

/// The system output device list and switch, through public CoreAudio.
///
/// # Push, never poll
///
/// Two listeners on the system object and nothing else: one on `kAudioHardwarePropertyDevices` for
/// hardware coming and going, one on `kAudioHardwarePropertyDefaultOutputDevice` for the output
/// moving. §9's idle path never sees a timer, and the list is re-read only inside a callback.
/// Measured on macOS 27.0 against a temporary aggregate device: the devices listener fired 1 ms
/// after `AudioHardwareCreateAggregateDevice` returned and once more on destroy, and the
/// default-output listener fired 1.1 ms after each `AudioObjectSetPropertyData`, with the new value
/// already readable by the time the block ran.
///
/// # `AudioObjectHasProperty` is the only gate
///
/// A listener registered for a property an object does not have returns `noErr` and then never
/// fires — the trap `SystemHUDAudioObserver` documents and the reason its volume listener asks
/// first. Every registration and every read below is gated the same way, and the status from
/// `AudioObjectAddPropertyListenerBlock` is treated as a failure signal only, never as evidence the
/// listener will ever be called.
///
/// # Privacy
///
/// **A device name is user content in the same family as a track title.** People name their AirPods
/// after themselves, their speakers after the room and their aggregates after the band; the export
/// is a file emailed to strangers and the unified log is readable by every process on the machine.
/// So this class logs counts, kinds and ids, and never a name. `IslandLog.audio` is the category —
/// the concern is CoreAudio device state, which is what that category already carries for volume and
/// mute, rather than the media-remote route `nowPlaying` follows.
@MainActor
public final class CoreAudioOutputRouting: NowPlayingOutputRouting {

    public var onDevices: (([NowPlayingOutputDevice]) -> Void)?

    public private(set) var devices: [NowPlayingOutputDevice] = []

    public private(set) var isRunning = false

    /// Callbacks land here, off the main actor, and resolve the whole list before hopping —
    /// enumerating devices and reading each one's name and transport type is a few dozen HAL calls,
    /// which is not main-thread work. The hop is `DispatchQueue.main.async` rather than a `Task`
    /// because it is FIFO and a `Task` is not: out-of-order delivery here would publish a stale list
    /// as the newest one, which on screen is a ticked row next to the device the user just left.
    private let queue = DispatchQueue(label: "com.tryisleta.isleta.nowplaying.outputdevices")

    private var registrations: [Registration] = []

    public init() {}

    deinit {
        // As in `SystemHUDAudioObserver`: `stop()` is main-actor isolated and `deinit` is not, so the
        // registrations are unwound here directly. A listener block outliving its observer is not
        // merely a leak — CoreAudio would go on invoking it against a freed capture.
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
    }

    /// How many listener blocks CoreAudio is holding for us. Internal, for the test that "stopped"
    /// means stopped: §9's idle budget is measured with the sources running, so a source that stops
    /// without unregistering spends it invisibly.
    var registrationCount: Int { registrations.count }

    /// Whether the system object can answer at all.
    ///
    /// Resolved once and remembered. Which properties the *system object* supports is fixed for the
    /// life of the process — what changes is which devices exist, and a Mac with no output device is
    /// a Mac with an empty list, not an unavailable route. Answering `false` for an empty list would
    /// be the mistake `SystemHUDAudioObserver.snapshot()` documents, where reporting the current
    /// state as a capability told the app that a Mac with working speakers had no volume.
    public private(set) lazy var isAvailable: Bool = {
        NowPlayingOutputDeviceReader.systemObjectAnswersDeviceProperties
    }()

    public func start() {
        guard !isRunning else { return }
        guard isAvailable else {
            IslandLog.audio.warning("output routing unavailable — the system object has no device properties")
            return
        }
        isRunning = true

        register(address: NowPlayingOutputDeviceReader.devicesAddress) { [weak self] in
            let resolved = NowPlayingOutputDeviceReader.outputDevices()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.publish(resolved)
                }
            }
        }

        register(address: SystemHUDAudioReader.defaultOutputDeviceAddress) { [weak self] in
            let resolved = NowPlayingOutputDeviceReader.outputDevices()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.publish(resolved)
                }
            }
        }

        publish(NowPlayingOutputDeviceReader.outputDevices())
        IslandLog.audio.info(
            "output routing started — \(registrations.count) listener(s), \(devices.count) output device(s)"
        )
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, queue, registration.block)
        }
        registrations.removeAll()
        devices = []
        IslandLog.audio.info("output routing stopped — no listeners registered")
    }

    /// Move the system output, and check that it moved.
    ///
    /// **The returned `OSStatus` is worth nothing here.** Measured three times on macOS 27.0:
    /// writing an id that names no device (`0xFFFF`), an id that names a real device with no output
    /// streams (the built-in microphone), and `kAudioObjectUnknown` each answered **`noErr`** and
    /// left the default output exactly where it was, 750 ms later. `AudioObjectIsPropertySettable`
    /// answers `true` throughout, so it is not a gate either. This is the same shape as
    /// `AXUIElementPerformAction` returning `.success` for an action that does not exist and
    /// `SLSSetWindowAlpha` returning 0 for another process's window: the API validates the request
    /// and reports success anyway. The read-back is the only evidence there is.
    ///
    /// The read-back can be synchronous: the write measured 0.37–0.45 ms and the value was already
    /// correct 0.1 ms after it returned, on both directions of a switch.
    public func select(_ id: UInt32) {
        guard isAvailable else { return }

        let kind = devices.first { $0.id == id }?.kind
        let landed = NowPlayingOutputDeviceReader.setDefaultOutputDevice(AudioObjectID(id))
        // Kind and id only — the device's name is the user's own words for their own hardware.
        if landed {
            IslandLog.audio.info("system output device set to \(id) (\(kind?.rawValue ?? "unknown kind"))")
        } else {
            IslandLog.audio.warning(
                "system output device \(id) (\(kind?.rawValue ?? "unknown kind")) refused — "
                + "the write reported success and the default did not move"
            )
        }
        // Not published from here. The write raises the default-output listener, which resolves and
        // publishes the list on the one path — so a switch made from the island and a switch made
        // from Control Center arrive identically, and a refused one publishes nothing at all.
    }

    // MARK: - Plumbing

    private func publish(_ resolved: [NowPlayingOutputDevice]) {
        guard NowPlayingOutputDeviceState.changed(from: devices, to: resolved) else { return }
        devices = resolved
        onDevices?(resolved)
    }

    /// - Parameter handler: runs on `queue`, not on the main actor. Each caller hops itself, so the
    ///   reads happen where they belong and only the resolved value crosses.
    private func register(address: AudioObjectPropertyAddress, handler: @escaping @Sendable () -> Void) {
        let object = AudioObjectID(kAudioObjectSystemObject)
        var address = address
        // The gate. Not the status below, which is `noErr` for a property that does not exist.
        guard AudioObjectHasProperty(object, &address) else {
            IslandLog.audio.warning("system object has no property \(address.mSelector) — not registering")
            return
        }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            IslandLog.audio.warning("output device listener registration failed with status \(status)")
            return
        }
        registrations.append(Registration(object: object, address: address, block: block))
    }

    /// `@unchecked Sendable` for the same reason and under the same guarantee as
    /// `SystemHUDAudioObserver`'s own registration record, which is private to that class: `deinit`
    /// is nonisolated and has to unwind the registrations it holds. The block is never called by us
    /// and never inspected — it is an opaque token handed straight back to
    /// `AudioObjectRemovePropertyListenerBlock` — and `deinit` has exclusive access to the array by
    /// definition.
    private struct Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}

// MARK: - The reads

/// The CoreAudio reads, with no state and no isolation, so a listener block can call them from
/// whatever queue CoreAudio hands it. The shape is `SystemHUDAudioReader`'s, and the default-output
/// address and read are *its* — one definition of that property, not two.
enum NowPlayingOutputDeviceReader {

    static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The **output** scope, which is what makes this the output configuration rather than the
    /// input one. The same selector in `kAudioObjectPropertyScopeInput` describes a microphone.
    static let outputStreamConfigurationAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static let transportTypeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let outputDataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// `kAudioObjectPropertyName`, and **only** that one.
    ///
    /// The obvious fallback is `kAudioDevicePropertyDeviceNameCFString`, and it is not a fallback:
    /// in `AudioHardwareDeprecated.h` it is defined as `= kAudioObjectPropertyName`. It is the same
    /// selector under a deprecated spelling, so a device that lacks one lacks the other and asking
    /// twice reads the same bytes twice. Measured on this machine, every device answered both with
    /// byte-identical strings. Keeping the pair would have looked like belt and braces and been a
    /// second name for one belt.
    static let nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Whether the system object supports both properties this route stands on.
    static var systemObjectAnswersDeviceProperties: Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = devicesAddress
        var output = SystemHUDAudioReader.defaultOutputDeviceAddress
        return AudioObjectHasProperty(system, &devices) && AudioObjectHasProperty(system, &output)
    }

    /// Every output device, the current default marked, in the HAL's own enumeration order.
    ///
    /// The order is left alone deliberately. Sorting by name is locale-dependent and reorders the
    /// list under a user who renames a device; sorting the default to the top makes every row move
    /// when the user picks one, which is the one moment a list must hold still.
    static func outputDevices() -> [NowPlayingOutputDevice] {
        let resolved = allDeviceIDs().compactMap(outputDevice(for:))
        let current = SystemHUDAudioReader.defaultOutputDevice()
        let defaultID: UInt32? = current == AudioObjectID(kAudioObjectUnknown) ? nil : UInt32(current)
        return NowPlayingOutputDeviceState.marking(defaultDeviceID: defaultID, in: resolved)
    }

    /// Nil for anything that is not an output — see `NowPlayingOutputDeviceState.hasOutputStreams`.
    static func outputDevice(for device: AudioObjectID) -> NowPlayingOutputDevice? {
        guard NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: outputChannelCounts(of: device)) else {
            return nil
        }
        // A device with no readable name is skipped rather than given a placeholder. "Unknown
        // device" in a picker is a row that does nothing a user can predict, and every device
        // measured answers this property.
        guard let name = name(of: device) else { return nil }
        return NowPlayingOutputDevice(
            id: UInt32(device),
            name: name,
            isDefault: false,
            kind: NowPlayingOutputDeviceState.kind(
                transportType: transportType(of: device),
                outputDataSource: outputDataSource(of: device)
            )
        )
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = devicesAddress
        guard AudioObjectHasProperty(system, &address) else { return [] }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // The reported size can come back smaller than the size that was asked for, so the array is
        // trimmed to what was actually written rather than trusted at its allocated length.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The channel count of each buffer in the device's output stream configuration.
    static func outputChannelCounts(of device: AudioObjectID) -> [UInt32] {
        var address = outputStreamConfigurationAddress
        guard AudioObjectHasProperty(device, &address) else { return [] }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        // An `AudioBufferList` is a header plus a variable-length tail, so it cannot be a Swift
        // value of known size: the memory is allocated raw at the size CoreAudio asked for and read
        // through `UnsafeMutableAudioBufferListPointer`, which knows how to walk it.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    static func transportType(of device: AudioObjectID) -> UInt32? {
        integer(of: device, at: transportTypeAddress)
    }

    static func outputDataSource(of device: AudioObjectID) -> UInt32? {
        integer(of: device, at: outputDataSourceAddress)
    }

    static func name(of device: AudioObjectID) -> String? {
        var address = nameAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        // CoreAudio hands back a +1 `CFString` for this property — the caller owns it — so it is
        // read as an `Unmanaged` and consumed with `takeRetainedValue()`. Reading it into a bridged
        // `CFString` variable instead compiles with a warning about forming a raw pointer to a
        // value that may contain an object reference, and leaks the string.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Writes the default output device and answers whether it actually moved. See
    /// `CoreAudioOutputRouting.select(_:)` for why the write's own status is not the answer.
    static func setDefaultOutputDevice(_ device: AudioObjectID) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = SystemHUDAudioReader.defaultOutputDeviceAddress
        guard AudioObjectHasProperty(system, &address) else { return false }

        var value = device
        let status = AudioObjectSetPropertyData(
            system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
        // The status is logged nowhere and checked for nothing: it was `noErr` for all three
        // refused writes measured. Only the read-back counts.
        _ = status
        return SystemHUDAudioReader.defaultOutputDevice() == device
    }

    private static func integer(of device: AudioObjectID, at address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
