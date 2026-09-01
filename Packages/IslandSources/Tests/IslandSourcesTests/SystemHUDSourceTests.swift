import IslandActivities
import Testing

@testable import IslandSources

/// Stands in for CoreAudio so every path below — including the one where the machine has no audio
/// output at all — is a test rather than a hardware configuration nobody can arrange.
@MainActor
final class FakeAudioObserver: SystemHUDAudioObserving {

    var onEvent: ((SystemHUDAudioEvent) -> Void)?
    var isRunning = false
    var startCount = 0
    var stopCount = 0
    var current: SystemHUDAudioSnapshot

    init(current: SystemHUDAudioSnapshot = SystemHUDAudioSnapshot(volume: 0.5, isMuted: false)) {
        self.current = current
    }

    func snapshot() -> SystemHUDAudioSnapshot { current }

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// Drive the source the way CoreAudio would.
    func emit(_ event: SystemHUDAudioEvent) {
        if case .changed(let snapshot) = event { current = snapshot }
        if case .deviceChanged(let snapshot) = event { current = snapshot }
        onEvent?(event)
    }
}

/// Stands in for DisplayServices, for the same reason `FakeAudioObserver` stands in for CoreAudio —
/// and for one more: the real monitor registers a process-wide callback with the window server, so
/// a suite that used it would have every test in the bundle observing the developer's own screen.
@MainActor
final class FakeBrightnessMonitor: DisplayBrightnessMonitoring {

    var isAvailable: Bool
    var level: Double?
    var startCount = 0
    var stopCount = 0
    private var onChange: ((Double) -> Void)?

    init(level: Double? = 0.5, isAvailable: Bool = true) {
        self.level = level
        self.isAvailable = isAvailable
    }

    func currentBrightness() -> Double? { level }

    func start(onChange: @escaping (Double) -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    /// Drive the source the way DisplayServices would.
    func emit(_ level: Double) {
        self.level = level
        onChange?(level)
    }
}

@MainActor
@Suite("SystemHUDSource")
struct SystemHUDSourceTests {

    private func makeSource(
        _ snapshot: SystemHUDAudioSnapshot = SystemHUDAudioSnapshot(volume: 0.5, isMuted: false),
        brightness: FakeBrightnessMonitor = FakeBrightnessMonitor()
    ) -> (SystemHUDSource, FakeAudioObserver, Box) {
        let audio = FakeAudioObserver(current: snapshot)
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        let box = Box()
        source.onActivity = { activity in box.activities.append(activity) }
        source.onDismiss = { id in box.dismissals.append(id) }
        return (source, audio, box)
    }

    final class Box {
        var activities: [any IslandActivity] = []
        var dismissals: [ActivityID] = []
    }

    // MARK: - Lifecycle contract

    @Test("start is idempotent")
    func startIsIdempotent() {
        let (source, audio, _) = makeSource()
        source.start()
        source.start()
        #expect(audio.startCount == 1)
        #expect(source.isRunning)
    }

    @Test("stop is idempotent and leaves nothing observing")
    func stopIsIdempotent() {
        let (source, audio, _) = makeSource()
        source.start()
        source.stop()
        source.stop()
        #expect(audio.stopCount == 1)
        #expect(audio.onEvent == nil)
        #expect(!source.isRunning)
    }

    @Test("stopping before starting does nothing")
    func stopBeforeStart() {
        let (source, audio, _) = makeSource()
        source.stop()
        #expect(audio.stopCount == 0)
    }

    @Test("restarting takes a fresh baseline rather than replaying the old one")
    func restartRebaselines() {
        let (source, audio, box) = makeSource()
        source.start()
        source.stop()
        audio.current = SystemHUDAudioSnapshot(volume: 0.9, isMuted: false)
        source.start()
        #expect(box.activities.isEmpty)

        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.9, isMuted: false)))
        #expect(box.activities.isEmpty)
    }

    @Test("needs no permission")
    func needsNoPermission() {
        let (source, _, _) = makeSource()
        #expect(source.authorization == .notRequired)
        #expect(source.authorization.isUsable)
        #expect(SystemHUDSource.sourceName == "SystemHUD")
        #expect(source.sourceName == "SystemHUD")
    }

    // MARK: - Publishing

    @Test("starting publishes nothing, however loud the Mac already is")
    func startingIsSilent() {
        let (source, _, box) = makeSource(SystemHUDAudioSnapshot(volume: 1.0, isMuted: false))
        source.start()
        #expect(box.activities.isEmpty)
    }

    @Test("a volume change publishes one system HUD activity")
    func volumeChangePublishes() {
        let (source, audio, box) = makeSource()
        source.start()
        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.625, isMuted: false)))

        #expect(box.activities.count == 1)
        let activity = box.activities.first
        #expect(activity?.kind == .systemHUD)
        #expect(activity?.presentations.compact.symbol == SystemHUD.volume.symbol)
        #expect(activity?.presentations.compact.value?.normalized == 0.625)
    }

    @Test("muting publishes the mute glyph and a warning tint")
    func mutePublishesMuteGlyph() {
        let (source, audio, box) = makeSource()
        source.start()
        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.5, isMuted: true)))

        #expect(box.activities.count == 1)
        #expect(box.activities.first?.presentations.compact.symbol == SystemHUD.mute.symbol)
        #expect(box.activities.first?.presentations.compact.tint == .warning)
    }

    @Test("a default-device change publishes nothing, and does not arm a HUD for the next read")
    func deviceChangeIsSilent() {
        let (source, audio, box) = makeSource()
        source.start()
        audio.emit(.deviceChanged(SystemHUDAudioSnapshot(volume: 0.2, isMuted: false)))
        #expect(box.activities.isEmpty)

        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.2, isMuted: false)))
        #expect(box.activities.isEmpty)
    }

    @Test("events arriving after stop are ignored")
    func eventsAfterStopAreIgnored() {
        let (source, audio, box) = makeSource()
        source.start()
        source.stop()
        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.9, isMuted: false)))
        #expect(box.activities.isEmpty)
    }

    @Test("a HUD is never dismissed by its source — it expires")
    func neverDismisses() {
        let (source, audio, box) = makeSource()
        source.start()
        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.9, isMuted: false)))
        source.stop()
        #expect(box.dismissals.isEmpty)
    }

    // MARK: - The unavailable state (§10)

    @Test("a Mac with no audio output publishes nothing and supports no audio HUD")
    func noAudioOutput() {
        let (source, audio, box) = makeSource(.unavailable)
        source.start()
        audio.emit(.changed(.unavailable))

        #expect(box.activities.isEmpty)
        #expect(!source.supportedHUDs.contains(.volume))
        #expect(!source.supportedHUDs.contains(.mute))
        #expect(source.unavailabilityExplanation(for: .volume) != nil)
    }

    @Test("brightness is supported when the monitor answers")
    func brightnessIsSupported() {
        let (source, _, _) = makeSource(brightness: FakeBrightnessMonitor(level: 0.6))
        #expect(source.supportedHUDs.contains(.brightness))
        #expect(source.unavailabilityExplanation(for: .brightness) == nil)
    }

    /// The pre-1.3.0 behavior, which is what an OS that removes the symbols degrades back to.
    @Test("brightness is unsupported with an explanation when the monitor cannot read")
    func brightnessIsUnsupportedWhenUnavailable() {
        let (source, _, _) = makeSource(brightness: FakeBrightnessMonitor(level: nil, isAvailable: false))
        #expect(!source.supportedHUDs.contains(.brightness))
        #expect(source.unavailabilityExplanation(for: .brightness) != nil)
    }

    @Test("a brightness change becomes a brightness HUD")
    func brightnessChangePublishes() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let (source, _, box) = makeSource(brightness: brightness)
        source.start()
        brightness.emit(0.7)

        #expect(box.activities.count == 1)
        #expect(box.activities.first?.kind == .systemHUD)
    }

    /// The launch bug, at the level of the source rather than the state: starting must adopt the
    /// current brightness silently.
    @Test("starting does not announce the brightness the user is already looking at")
    func startingIsSilentForBrightness() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let (source, _, box) = makeSource(brightness: brightness)
        source.start()

        #expect(box.activities.isEmpty)
        #expect(brightness.startCount == 1)
        // And a callback carrying that same level is still not news.
        brightness.emit(0.5)
        #expect(box.activities.isEmpty)
    }

    @Test("stopping releases the brightness monitor")
    func stoppingReleasesBrightness() {
        let brightness = FakeBrightnessMonitor()
        let (source, _, box) = makeSource(brightness: brightness)
        source.start()
        source.stop()
        #expect(brightness.stopCount == 1)

        // A callback arriving after stop — the unregister racing an in-flight notification — must
        // not put a HUD on screen for a source that is no longer running.
        brightness.emit(0.9)
        #expect(box.activities.isEmpty)
    }

    @Test("a supported HUD has no unavailability explanation")
    func supportedHUDHasNoExplanation() {
        let (source, _, _) = makeSource()
        #expect(source.supportedHUDs.contains(.volume))
        #expect(source.unavailabilityExplanation(for: .volume) == nil)
    }

    // MARK: - The two switches

    /// The point of gating the monitors rather than the publishing. A level the user has switched
    /// off must leave **no observer attached** — a DisplayServices callback nobody reads is the
    /// purest way to spend the §9 idle budget, and it would be invisible in every test that only
    /// checked what was published.
    @Test("a level that is switched off attaches no monitor")
    func disabledLevelsAttachNothing() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        source.enabledHUDs = [.volume, .mute]
        source.start()

        #expect(audio.startCount == 1)
        #expect(brightness.startCount == 0)
    }

    @Test("with every level off the source observes nothing at all")
    func everyLevelOffObservesNothing() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        source.enabledHUDs = []
        source.start()

        #expect(source.isRunning)
        #expect(audio.startCount == 0)
        #expect(brightness.startCount == 0)
    }

    /// A settings change lands on a running source, so switching one level off must not disturb the
    /// one beside it. Re-baselining the volume here would be silent and would cost the user the next
    /// HUD they asked for.
    @Test("switching a level off while running detaches only that monitor")
    func switchingOffWhileRunningDetachesOne() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        source.start()

        source.enabledHUDs = [.volume, .mute]

        #expect(brightness.stopCount == 1)
        #expect(audio.stopCount == 0)
        #expect(audio.startCount == 1)
    }

    /// Switching a level back on takes a fresh baseline, for the reason `restartRebaselines` covers:
    /// the level moved while nobody was watching, and announcing where it has got to would be a HUD
    /// for something the user did not just do.
    @Test("switching a level back on attaches it and says nothing about where it is")
    func switchingOnWhileRunningIsSilent() {
        let brightness = FakeBrightnessMonitor(level: 0.4)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        let box = Box()
        source.onActivity = { box.activities.append($0) }
        source.enabledHUDs = [.volume, .mute]
        source.start()

        brightness.level = 0.9
        source.enabledHUDs = Set(SystemHUD.allCases)

        #expect(brightness.startCount == 1)
        #expect(box.activities.isEmpty)

        brightness.emit(0.2)
        #expect(box.activities.count == 1)
    }

    /// Assigning the same set is what every settings change that touched something else does — the
    /// hub writes this property on every `apply`. It has to be free, or changing the hot key would
    /// tear down both observers and re-read both baselines.
    @Test("assigning the same set attaches and detaches nothing")
    func assigningTheSameSetIsFree() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        source.start()
        source.enabledHUDs = Set(SystemHUD.allCases)

        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 0)
        #expect(brightness.startCount == 1)
    }

    /// The reason the set is filtered at publish time as well as at the monitor: one CoreAudio
    /// observer answers for two levels, so a set holding one without the other cannot be honored by
    /// attaching or not attaching it.
    @Test("mute alone is suppressed while the volume bar still shows")
    func muteCanBeFilteredWithoutStoppingTheObserver() {
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: FakeBrightnessMonitor(), mediaKeys: UnavailableMediaKeyMonitor())
        let box = Box()
        source.onActivity = { box.activities.append($0) }
        source.enabledHUDs = [.volume]
        source.start()

        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.5, isMuted: true)))
        #expect(box.activities.isEmpty)

        audio.emit(.changed(SystemHUDAudioSnapshot(volume: 0.8, isMuted: false)))
        #expect(box.activities.count == 1)
    }

    /// Whether this Mac *can report* a level is a fact about the hardware, and the user switching
    /// the HUD off does not change it. Settings reads both — one grays the switch, the other is the
    /// switch — so they must not collapse into each other.
    @Test("switching a level off does not make it unsupported")
    func disablingDoesNotChangeSupport() {
        let (source, _, _) = makeSource()
        source.enabledHUDs = []
        #expect(source.supportedHUDs.contains(.volume))
        #expect(source.unavailabilityExplanation(for: .volume) == nil)
    }

    @Test("stopping detaches whatever was attached and starting again honors the set")
    func stopThenStartHonorsTheSet() {
        let brightness = FakeBrightnessMonitor(level: 0.5)
        let audio = FakeAudioObserver()
        let source = SystemHUDSource(audio: audio, brightness: brightness, mediaKeys: UnavailableMediaKeyMonitor())
        source.enabledHUDs = [.brightness]
        source.start()
        source.stop()

        #expect(brightness.stopCount == 1)
        // Never attached, so never detached — `stop()` must not call `stop` on a monitor it did not
        // start. The real CoreAudio observer answers `success` either way, which is exactly the
        // class of bug CLAUDE.md's measurement rule is about.
        #expect(audio.stopCount == 0)

        source.start()
        #expect(brightness.startCount == 2)
        #expect(audio.startCount == 0)
    }
}
