import CoreAudio
import Testing

@testable import IslandSources

/// The rules that decide what a device *is*, which devices are outputs at all, and when a CoreAudio
/// push is worth publishing.
///
/// Nothing here touches CoreAudio. That is the point: the machine this was written on has exactly
/// one output device, so a test that needed hardware could exercise none of these — not a
/// disconnect, not a Bluetooth pair, not an AirPlay receiver, not the headphone jack.
@Suite("NowPlayingOutputDevices")
struct NowPlayingOutputDevicesTests {

    private func device(
        _ id: UInt32,
        name: String = "Device",
        isDefault: Bool = false,
        kind: NowPlayingOutputDeviceKind = .builtIn
    ) -> NowPlayingOutputDevice {
        NowPlayingOutputDevice(id: id, name: name, isDefault: isDefault, kind: kind)
    }

    // MARK: - Transport type → kind

    @Test("built-in speakers are the Mac itself")
    func builtInSpeakers() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    }

    /// The headphone jack reports transport `bltn` exactly as the speakers do — a mapping keyed on
    /// transport type alone draws a laptop next to a pair of wired headphones. The data source is
    /// the only thing that separates them.
    @Test("the headphone jack is separated from the speakers by its data source, not its transport")
    func headphoneJack() {
        let jack = NowPlayingOutputDeviceState.kind(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            outputDataSource: NowPlayingOutputDeviceState.headphoneDataSource
        )
        let speakers = NowPlayingOutputDeviceState.kind(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            outputDataSource: NowPlayingOutputDeviceState.internalSpeakerDataSource
        )
        #expect(jack == .headphones)
        #expect(speakers == .builtIn)
    }

    /// A data source only means anything on the built-in device. Nothing else should be pulled into
    /// `.headphones` by a coincidental code.
    @Test("a headphone data source on another transport does not make it the jack")
    func headphoneDataSourceElsewhere() {
        let kind = NowPlayingOutputDeviceState.kind(
            transportType: kAudioDeviceTransportTypeUSB,
            outputDataSource: NowPlayingOutputDeviceState.headphoneDataSource
        )
        #expect(kind == .external)
    }

    @Test("both Bluetooth transports are Bluetooth")
    func bluetoothTransports() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    }

    @Test("an AirPlay receiver is AirPlay")
    func airPlayTransport() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeAirPlay) == .airPlay)
    }

    @Test("the two display transports stay apart")
    func displayTransports() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeHDMI) == .hdmi)
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeDisplayPort) == .displayPort)
    }

    /// Aggregate, auto-aggregate and virtual are one thing to a user: something the Mac made up.
    /// The aggregate case is the one measured — a probe device created with
    /// `AudioHardwareCreateAggregateDevice` reported `grup`.
    @Test("aggregate, auto-aggregate and virtual devices are all virtual")
    func virtualTransports() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeAggregate) == .virtual)
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeAutoAggregate) == .virtual)
        #expect(NowPlayingOutputDeviceState.kind(transportType: kAudioDeviceTransportTypeVirtual) == .virtual)
    }

    @Test("every wired transport with no glyph of its own falls to external")
    func externalTransports() {
        let transports = [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeAVB,
            kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless,
            kAudioDeviceTransportTypeUnknown,
        ]
        for transport in transports {
            #expect(NowPlayingOutputDeviceState.kind(transportType: transport) == .external)
        }
    }

    /// A device that will not say how it is attached is still a device the user can pick.
    @Test("a device reporting no transport type is external, not an error")
    func absentTransportType() {
        #expect(NowPlayingOutputDeviceState.kind(transportType: nil) == .external)
    }

    @Test("the four-character codes are read big-endian, as CoreAudio writes them")
    func fourCharacterCodes() {
        #expect(NowPlayingOutputDeviceState.fourCharacterCode("hdpn") == 0x6864_706E)
        #expect(NowPlayingOutputDeviceState.headphoneDataSource == 0x6864_706E)
        #expect(NowPlayingOutputDeviceState.internalSpeakerDataSource == 0x6973_706B)
    }

    // MARK: - Symbols

    @Test("every kind names a symbol, and no kind is left blank")
    func everyKindHasASymbol() {
        for kind in NowPlayingOutputDeviceKind.allCases {
            #expect(!kind.symbolName.isEmpty)
        }
    }

    @Test("the symbols are the ones the picker was designed against")
    func symbolNames() {
        #expect(NowPlayingOutputDeviceKind.builtIn.symbolName == "laptopcomputer")
        #expect(NowPlayingOutputDeviceKind.headphones.symbolName == "headphones")
        #expect(NowPlayingOutputDeviceKind.airPlay.symbolName == "airplayaudio")
        #expect(NowPlayingOutputDeviceKind.hdmi.symbolName == "tv")
        #expect(NowPlayingOutputDeviceKind.displayPort.symbolName == "display")
        #expect(NowPlayingOutputDeviceKind.virtual.symbolName == "waveform")
    }

    /// Pinned rather than assumed: the transport type says a device is wireless and not whether it
    /// is earbuds or a speaker, so both share the neutral glyph on purpose. A future change that
    /// gives Bluetooth `headphones` has to fail here first.
    @Test("Bluetooth and external share the neutral speaker deliberately")
    func neutralGlyphIsShared() {
        #expect(NowPlayingOutputDeviceKind.bluetooth.symbolName == "speaker.wave.2.fill")
        #expect(NowPlayingOutputDeviceKind.external.symbolName == "speaker.wave.2.fill")
    }

    @Test("a device's symbol is its kind's")
    func deviceSymbolFollowsKind() {
        #expect(device(1, kind: .airPlay).symbolName == "airplayaudio")
    }

    // MARK: - The output filter

    @Test("a device with output channels is an output")
    func outputDeviceHasChannels() {
        #expect(NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: [2]))
    }

    /// This Mac's `MacBook Pro Microphone` and an iPhone's Continuity microphone both report zero
    /// output channels. A picker that lists them offers a destination that plays nothing.
    @Test("a device with no output channels is an input and is dropped")
    func inputDeviceIsDropped() {
        #expect(!NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: []))
        #expect(!NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: [0]))
    }

    /// The buffer count is not the test. A device can report several buffers of which some are
    /// empty, so a `!isEmpty` check on the list would call an input an output.
    @Test("several empty buffers are still no output")
    func severalEmptyBuffers() {
        #expect(!NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: [0, 0, 0]))
        #expect(NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: [0, 0, 1]))
    }

    @Test("channels are summed across buffers, not taken from the first")
    func channelsAreSummed() {
        #expect(NowPlayingOutputDeviceState.hasOutputStreams(bufferChannelCounts: [0, 2, 6]))
    }

    // MARK: - Marking the default

    @Test("exactly the device holding the default id is marked")
    func markingTheDefault() {
        let marked = NowPlayingOutputDeviceState.marking(
            defaultDeviceID: 81,
            in: [device(93), device(81), device(144)]
        )
        #expect(marked.map(\.isDefault) == [false, true, false])
        #expect(marked.map(\.id) == [93, 81, 144])
    }

    @Test("marking clears a stale flag rather than leaving it")
    func markingClearsStaleFlag() {
        let marked = NowPlayingOutputDeviceState.marking(
            defaultDeviceID: 144,
            in: [device(81, isDefault: true), device(144)]
        )
        #expect(marked.map(\.isDefault) == [false, true])
    }

    @Test("a machine with no default output marks nothing")
    func noDefaultMarksNothing() {
        let marked = NowPlayingOutputDeviceState.marking(defaultDeviceID: nil, in: [device(81), device(144)])
        #expect(marked.allSatisfy { !$0.isDefault })
    }

    @Test("a default id naming a device that is not in the list marks nothing")
    func unknownDefaultMarksNothing() {
        let marked = NowPlayingOutputDeviceState.marking(defaultDeviceID: 999, in: [device(81), device(144)])
        #expect(marked.allSatisfy { !$0.isDefault })
    }

    // MARK: - When a push is worth publishing

    /// CoreAudio pushes more often than anything changes: `kAudioHardwarePropertyDevices` fires for
    /// input devices arriving and for virtual drivers reconfiguring themselves, none of which the
    /// island has anything to say about.
    @Test("an identical list publishes nothing")
    func identicalListIsSilent() {
        let list = [device(81, kind: .builtIn), device(144, kind: .virtual)]
        #expect(!NowPlayingOutputDeviceState.changed(from: list, to: list))
    }

    /// The single most important thing this source reports, and the one an id-based comparison
    /// would miss: every id is unchanged and the tick has moved.
    @Test("the default moving is a change even though every id is the same")
    func defaultMovingIsAChange() {
        let before = [device(81, isDefault: true), device(144)]
        let after = [device(81), device(144, isDefault: true)]
        #expect(NowPlayingOutputDeviceState.changed(from: before, to: after))
    }

    @Test("a device arriving is a change")
    func deviceArrivingIsAChange() {
        #expect(NowPlayingOutputDeviceState.changed(from: [device(81)], to: [device(81), device(144)]))
    }

    @Test("a device leaving is a change")
    func deviceLeavingIsAChange() {
        #expect(NowPlayingOutputDeviceState.changed(from: [device(81), device(144)], to: [device(81)]))
    }

    @Test("a rename is a change")
    func renameIsAChange() {
        #expect(NowPlayingOutputDeviceState.changed(from: [device(81, name: "A")], to: [device(81, name: "B")]))
    }

    @Test("the same devices in a different order is a change")
    func reorderIsAChange() {
        #expect(NowPlayingOutputDeviceState.changed(from: [device(81), device(144)], to: [device(144), device(81)]))
    }

    @Test("the first push against an empty list is a change")
    func firstPushIsAChange() {
        #expect(NowPlayingOutputDeviceState.changed(from: [], to: [device(81)]))
        #expect(!NowPlayingOutputDeviceState.changed(from: [], to: []))
    }

    // MARK: - The value

    @Test("settingIsDefault changes the flag and nothing else")
    func settingIsDefaultKeepsEverythingElse() {
        let original = device(81, name: "Speakers", kind: .builtIn)
        let marked = original.settingIsDefault(true)
        #expect(marked.isDefault)
        #expect(marked.id == original.id)
        #expect(marked.name == original.name)
        #expect(marked.kind == original.kind)
        #expect(marked.settingIsDefault(false) == original)
    }

    // MARK: - The fallback

    /// The same discipline as `NowPlayingUnavailableTransport`: unavailable means the island draws
    /// no picker at all, so every member has to be inert rather than merely empty.
    @Test("UnavailableOutputRouting reports unavailable and does nothing")
    @MainActor
    func unavailableRoutingIsInert() {
        let routing = UnavailableOutputRouting()
        var published: [[NowPlayingOutputDevice]] = []
        routing.onDevices = { published.append($0) }

        #expect(!routing.isAvailable)
        #expect(routing.devices.isEmpty)

        routing.start()
        routing.select(81)
        routing.stop()

        #expect(routing.devices.isEmpty)
        #expect(published.isEmpty)
        #expect(!routing.isAvailable)
    }

    @Test("UnavailableOutputRouting conforms to the routing protocol the island is written against")
    @MainActor
    func unavailableRoutingConforms() {
        let routing: any NowPlayingOutputRouting = UnavailableOutputRouting()
        #expect(!routing.isAvailable)
        #expect(routing.devices.isEmpty)
    }
}
