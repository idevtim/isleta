import AppKit
import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The keys, and the one question they are watched to answer.
///
/// Everything here runs with no keyboard and no permission: the decoding is a pure function of an
/// `NSEvent`, and the policy is a pure function of a level. What cannot be tested in this process is
/// whether the events *arrive* — that is a TCC question, and `--media-key-test` on the built app is
/// what answers it.
@Suite("Media keys")
@MainActor
struct MediaKeyTests {

    /// A media key as the window server delivers it: an aux-control system-defined event with the
    /// key code in the top half of `data1` and its state in the bottom half.
    private func event(_ keyCode: Int32, down: Bool = true, repeated: Bool = false) -> NSEvent? {
        let state: Int = down ? 0x0A : 0x0B
        let flags = (state << 8) | (repeated ? 1 : 0)
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
            data1: (Int(keyCode) << 16) | flags,
            data2: -1
        )
    }

    @Test("the four keys that drive a range are decoded")
    func decodesTheFourKeys() throws {
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_SOUND_UP))) == .volumeUp)
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_SOUND_DOWN))) == .volumeDown)
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_BRIGHTNESS_UP))) == .brightnessUp)
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_BRIGHTNESS_DOWN))) == .brightnessDown)
    }

    /// **Mute is decoded now, and it was not.** This assertion used to read `== nil`, on the correct
    /// argument that mute is a toggle rather than a range: there is no end to push against, so the
    /// limit rebound this file was written for has nothing to say about it.
    ///
    /// HUD *replacement* changed the question. A Mac whose volume-up and volume-down Isleta answers
    /// and whose mute key still reaches macOS would draw Apple's HUD for one key out of three, which
    /// is worse than drawing it for all of them. The rebound still ignores mute — see
    /// `SystemHUDSource.handle`, which returns early for it — so the original reasoning is intact;
    /// it just no longer decides whether the key is decoded.
    @Test("mute is decoded, for replacement rather than for the rebound")
    func decodesMute() throws {
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_MUTE))) == .mute)
    }

    /// Play/pause and the rest of the aux controls are still none of Isleta's business: it does not
    /// replace them, so swallowing one would take a key away for nothing.
    @Test("everything else is ignored")
    func ignoresEverythingElse() throws {
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_PLAY))) == nil)
    }

    /// The key going *up* is the same event with a different state, and answering both would double
    /// every press.
    @Test("only the key going down counts")
    func onlyKeyDown() throws {
        #expect(MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_SOUND_UP, down: false))) == nil)
    }

    /// **Repeats are the point.** A key held at the top of the range is exactly the gesture the
    /// rebound answers; filtering them would leave it firing once for a press the user is still
    /// making.
    @Test("a key repeat is a press like any other")
    func repeatsCount() throws {
        #expect(
            MediaKeyMonitor.mediaKey(in: try #require(event(NX_KEYTYPE_SOUND_UP, repeated: true)))
                == .volumeUp
        )
    }

    // MARK: - The policy

    /// A monitor that fires on demand, so the source's rule can be exercised with no keyboard.
    private final class FakeKeys: MediaKeyObserving {
        var isAvailable = true
        private var onPress: ((MediaKeyPress) -> Bool)?

        /// Which mode the source asked for. Asserted on rather than ignored: whether Isleta is
        /// *observing* the level keys or *replacing* them is the difference between a decorative
        /// rebound and taking over every volume press on the machine, and it must not be possible to
        /// switch that on by accident.
        private(set) var startedMode: MediaKeyMode?

        /// What the handler answered the last time a key was pressed — i.e. whether the key would
        /// have been swallowed.
        private(set) var lastConsumed = false

        func start(_ onPress: @escaping (MediaKey) -> Void) {
            startedMode = .observe
            self.onPress = { press in onPress(press.key); return false }
        }

        func start(mode: MediaKeyMode, onPress: @escaping (MediaKeyPress) -> Bool) {
            startedMode = mode
            self.onPress = onPress
        }

        func stop() { onPress = nil; startedMode = nil }

        @discardableResult
        func press(_ key: MediaKey, fine: Bool = false) -> Bool {
            lastConsumed = onPress?(MediaKeyPress(key: key, isFine: fine)) ?? false
            return lastConsumed
        }
    }

    /// The source with a known level already in it. `start()` rebases from the fake's snapshot, so
    /// the state machine holds the level without a reading ever having been published — which is
    /// exactly the situation a key press has to be judged against.
    private func source(volume: Double?, muted: Bool = false) -> (SystemHUDSource, FakeKeys) {
        let keys = FakeKeys()
        let audio = FakeAudioObserver(
            current: SystemHUDAudioSnapshot(volume: volume, isMuted: muted)
        )
        let source = SystemHUDSource(
            audio: audio, brightness: UnavailableBrightnessMonitor(), mediaKeys: keys
        )
        source.start()
        return (source, keys)
    }

    /// **The whole reason the keys are watched at all.** At the top of the range the level cannot
    /// report the press, because nothing changes and CoreAudio fires no listener — measured.
    @Test("volume-up at full volume asks for a rebound")
    func pushingTheTop() {
        let (source, keys) = source(volume: 1)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeUp)
        #expect(pushes == [.maximum])
    }

    @Test("volume-down at zero asks for one the other way")
    func pushingTheBottom() {
        let (source, keys) = source(volume: 0)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeDown)
        #expect(pushes == [.minimum])
    }

    /// **The other direction is not pushing against anything.** At full volume, volume-*down* moves
    /// the level — the CoreAudio callback reports it, a HUD is published, and answering the key as
    /// well would say the same thing twice.
    @Test("a key that will actually move the level says nothing here")
    func aKeyThatMovesSaysNothing() {
        let (source, keys) = source(volume: 1)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeDown)
        #expect(pushes.isEmpty)
    }

    @Test("nor does a key pressed anywhere in the middle of the range")
    func middleOfTheRangeSaysNothing() {
        let (source, keys) = source(volume: 0.5)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeUp)
        keys.press(.volumeDown)
        #expect(pushes.isEmpty)
    }

    /// **A muted Mac is at the bottom of its range.** This asserted the opposite until hardware said
    /// otherwise: volume-down on a silent Mac is somebody pushing at a floor that will not move.
    @Test("volume-down on a muted Mac is pushing at the bottom")
    func mutedIsTheFloor() {
        let (source, keys) = source(volume: 0.4, muted: true)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeDown)
        #expect(pushes == [.minimum])
    }

    /// And volume-*up* there is not pushing at anything: it unmutes, which is a real change the
    /// level observer reports as a reading like any other.
    @Test("volume-up on a muted Mac says nothing, because it unmutes")
    func volumeUpUnmutes() {
        let (source, keys) = source(volume: 0.4, muted: true)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeUp)
        #expect(pushes.isEmpty)
    }

    /// The dwell is restarted with what is **on screen** — a crossed-out speaker — not with a volume
    /// bar at nothing, which is what a `.volume` HUD at level zero would draw.
    @Test("pushing while muted keeps the mute HUD up, not a volume HUD at zero")
    func mutedPushKeepsTheMuteHUD() {
        let (source, keys) = source(volume: 0.4, muted: true)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        keys.press(.volumeDown)
        #expect(published.count == 1)
        #expect(published.first?.presentations.leading.symbol == SystemHUD.mute.symbol)
    }

    /// **Held, it keeps asking.** One press, one rebound; the island's own strike-from-zero is what
    /// turns a stream of these into a flutter rather than a single parked edge.
    @Test("a held key asks once per repeat")
    func heldKeyKeepsAsking() {
        let (source, keys) = source(volume: 1)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        for _ in 0..<5 { keys.press(.volumeUp) }
        #expect(pushes == Array(repeating: .maximum, count: 5))
    }

    /// The HUD is re-presented as well, so its dwell restarts — which is what macOS's own HUD does
    /// when you keep pressing at the top. Without it the island would rebound with nothing on it
    /// once the first press had expired.
    @Test("pushing keeps the HUD on screen")
    func pushingRestartsTheDwell() {
        let (source, keys) = source(volume: 1)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        keys.press(.volumeUp)
        #expect(published.count == 1)
        #expect(published.first?.kind == .systemHUD)
        #expect(published.first?.reachedLimit == .maximum)
    }

    /// A HUD the user has switched off must not move the island either. The set gates the watcher
    /// and the answer, for `enabledHUDs`' own reason.
    @Test("a level the user has switched off is not answered")
    func disabledLevelSaysNothing() {
        let (source, keys) = source(volume: 1)
        source.enabledHUDs = [.brightness]
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        keys.press(.volumeUp)
        #expect(pushes.isEmpty)
    }

    /// Stopping the source detaches the watcher, like every other monitor here — §9 measures the
    /// idle path, and an observer nobody reads is the purest way to spend it.
    @Test("stopping the source stops watching")
    func stopDetaches() {
        let (source, keys) = source(volume: 1)
        var pushes: [ActivityLimit] = []
        source.onLimitPushed = { _, limit in pushes.append(limit) }
        source.stop()
        keys.press(.volumeUp)
        #expect(pushes.isEmpty)
    }
}

/// A volume writer that records instead of touching the machine.
///
/// The reason `SystemVolumeWriting` is a protocol at all: a test that drove the real one would move
/// the volume of the Mac running it, and a refusal — the case that matters most, because it decides
/// whether Isleta swallows a key it cannot act on — cannot be produced on working hardware.
@MainActor
final class FakeVolumeControl: SystemVolumeWriting {

    var volume: Double
    var isMuted: Bool

    /// Makes every write fail, standing in for a device that answers reads and refuses writes.
    var refusesWrites = false

    private(set) var volumeWrites: [Double] = []
    private(set) var muteWrites: [Bool] = []
    private(set) var feedbackCount = 0

    init(volume: Double = 0.5, isMuted: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
    }

    func current() -> (volume: Double, isMuted: Bool)? { (volume, isMuted) }

    func setVolume(_ value: Double) -> Double? {
        guard !refusesWrites else { return nil }
        volumeWrites.append(value)
        volume = value
        return value
    }

    func setMuted(_ muted: Bool) -> Bool? {
        guard !refusesWrites else { return nil }
        muteWrites.append(muted)
        isMuted = muted
        return muted
    }

    func playFeedback() { feedbackCount += 1 }
}

/// Replacing the volume keys: what happens once Isleta swallows the key instead of watching it.
///
/// Everything here is about the *seam* — which key is consumed, what gets written, and what happens
/// when the write is refused. Where the level lands is `VolumeStepTests`, deliberately separate:
/// that half is pure arithmetic and this half is wiring, and mixing them makes both harder to read.
@Suite("Replacing the volume keys")
@MainActor
struct VolumeKeyReplacementTests {

    /// Runs `body` with a live source, and **holds it alive for the duration**.
    ///
    /// A closure rather than a returned tuple, and that is not style. The first version returned
    /// `(source, keys, control)` and every test bound the source to `_`; ARC then released it
    /// immediately, the `[weak self]` inside the tap handler was already nil, and *every* press
    /// answered false. Nine tests failed identically against correct code. A helper that cannot be
    /// used without keeping its subject alive is the fix that stays fixed.
    private func withSource(
        volume: Double = 0.5,
        muted: Bool = false,
        replacing: Bool = true,
        enabled: Set<SystemHUD> = [.volume],
        control: FakeVolumeControl? = nil,
        _ body: (SystemHUDSource, FakeKeysForReplacement, FakeVolumeControl) -> Void
    ) {
        let keys = FakeKeysForReplacement()
        let control = control ?? FakeVolumeControl(volume: volume, isMuted: muted)
        let source = SystemHUDSource(
            audio: FakeAudioObserver(current: SystemHUDAudioSnapshot(volume: volume, isMuted: muted)),
            brightness: UnavailableBrightnessMonitor(),
            mediaKeys: keys,
            volumeControl: control
        )
        source.enabledHUDs = enabled
        source.replacesVolumeKeys = replacing
        source.start()
        body(source, keys, control)
        withExtendedLifetime(source) {}
    }

    @Test("the tap is asked for replace mode only when the user turned it on")
    func modeFollowsTheSetting() {
        withSource(replacing: true) { _, keys, _ in #expect(keys.startedMode == .replace) }
        withSource(replacing: false) { _, keys, _ in #expect(keys.startedMode == .observe) }
    }

    /// **The switch must not swallow keys it will draw nothing for.** A user who turned the volume
    /// HUD off and replacement on would otherwise get keys that do nothing visible at all.
    @Test("a disabled volume HUD is never replaced, whatever the setting says")
    func requiresTheHUDToBeEnabled() {
        withSource(replacing: true, enabled: [.brightness]) { _, keys, _ in
            #expect(keys.startedMode == .observe)
        }
    }

    @Test("volume-up writes the next notch and is swallowed")
    func volumeUpWritesAndConsumes() {
        withSource(volume: 0.5) { _, keys, control in
            #expect(keys.press(.volumeUp))
            #expect(control.volumeWrites.count == 1)
            #expect(abs((control.volumeWrites.first ?? 0) - 0.5625) < 1e-9)
        }
    }

    @Test("⇧⌥ writes a quarter notch")
    func fineStepWrites() {
        withSource(volume: 0.5) { _, keys, control in
            #expect(keys.press(.volumeUp, fine: true))
            #expect(abs((control.volumeWrites.first ?? 0) - (0.5 + 1.0 / 64.0)) < 1e-9)
        }
    }

    /// Volume-up while muted spends the press on the unmute and writes **no level at all** — the
    /// behaviour `VolumeStepTests` pins arithmetically, checked here as the writes that reach the
    /// device.
    @Test("volume-up while muted unmutes and writes no level")
    func volumeUpUnmutesWithoutWritingLevel() {
        withSource(volume: 0.5, muted: true) { _, keys, control in
            #expect(keys.press(.volumeUp))
            #expect(control.muteWrites == [false])
            #expect(control.volumeWrites.isEmpty, "the press unmuted; it must not also move the level")
        }
    }

    @Test("the mute key toggles and never touches the level")
    func muteToggles() {
        withSource(volume: 0.375, muted: false) { _, keys, control in
            #expect(keys.press(.mute))
            #expect(control.muteWrites == [true])
            #expect(control.volumeWrites.isEmpty)
        }
    }

    /// **The case that decides whether a Mac is left usable.** A device that answers reads and
    /// refuses writes must get its key back, so the system moves the level and draws its own HUD.
    /// Swallowing a key Isleta cannot act on is the worst outcome available here — the volume keys
    /// would simply stop working.
    @Test("a refused write hands the key back rather than swallowing it")
    func refusedWriteDoesNotConsume() {
        withSource(volume: 0.5) { _, keys, control in
            control.refusesWrites = true
            #expect(keys.press(.volumeUp) == false)
        }
    }

    /// A device that answers nothing at all. `UnavailableVolumeControl` is the shipped fallback, so
    /// this is the real path a Mac with no writable output takes rather than a contrivance.
    @Test("no readable output device hands the key back")
    func noDeviceDoesNotConsume() {
        let keys = FakeKeysForReplacement()
        let source = SystemHUDSource(
            audio: FakeAudioObserver(current: SystemHUDAudioSnapshot(volume: nil, isMuted: nil)),
            brightness: UnavailableBrightnessMonitor(),
            mediaKeys: keys,
            volumeControl: UnavailableVolumeControl()
        )
        source.enabledHUDs = [.volume]
        source.replacesVolumeKeys = true
        source.start()
        #expect(keys.press(.volumeUp) == false)
        withExtendedLifetime(source) {}
    }

    /// Brightness is not replaced, so its keys must reach the system untouched — otherwise a user
    /// loses brightness control entirely, which is the failure `SystemHUDSuppression` has always
    /// refused to risk.
    @Test("brightness keys are never swallowed")
    func brightnessIsNeverConsumed() {
        withSource { _, keys, _ in
            #expect(keys.press(.brightnessUp) == false)
            #expect(keys.press(.brightnessDown) == false)
        }
    }

    /// The click is the user's own Sound setting, and a press that moves nothing makes no sound —
    /// Apple's does not either. Checked through the fake rather than through `UserDefaults`, because
    /// reading the global domain in a test would answer about the developer's Mac.
    @Test("a press at the ceiling writes nothing and clicks nothing")
    func limitWritesNothing() {
        withSource(volume: 1.0) { _, keys, control in
            #expect(keys.press(.volumeUp))
            #expect(control.volumeWrites.isEmpty)
            #expect(control.feedbackCount == 0)
        }
    }

    @Test("a press that moves the level clicks once")
    func changeClicksOnce() {
        withSource(volume: 0.5) { _, keys, control in
            #expect(keys.press(.volumeUp))
            #expect(control.feedbackCount == 1)
        }
    }
}

/// The replacement suite's own fake, kept separate from `MediaKeyTests.FakeKeys` because it has to
/// report the mode it was started in and hand back what the handler answered.
@MainActor
final class FakeKeysForReplacement: MediaKeyObserving {
    var isAvailable = true
    private var onPress: ((MediaKeyPress) -> Bool)?
    private(set) var startedMode: MediaKeyMode?

    func start(_ onPress: @escaping (MediaKey) -> Void) {
        startedMode = .observe
        self.onPress = { press in onPress(press.key); return false }
    }

    func start(mode: MediaKeyMode, onPress: @escaping (MediaKeyPress) -> Bool) {
        startedMode = mode
        self.onPress = onPress
    }

    func stop() { onPress = nil; startedMode = nil }

    @discardableResult
    func press(_ key: MediaKey, fine: Bool = false) -> Bool {
        onPress?(MediaKeyPress(key: key, isFine: fine)) ?? false
    }
}
