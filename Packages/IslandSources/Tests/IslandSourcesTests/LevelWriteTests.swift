import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A brightness writer that records instead of dimming the machine.
///
/// The reason `SystemBrightnessWriting` is a protocol at all, said again for the panel: a test that
/// drove the real one would dim the screen of the Mac running it, and a *refusal* — the case that
/// decides whether Isleta claims to have done something it did not — cannot be produced on working
/// hardware at all.
@MainActor
final class FakeBrightnessControl: SystemBrightnessWriting {

    var level: Double

    /// Makes every write fail, standing in for a panel that answers reads and refuses writes.
    var refusesWrites = false

    private(set) var writes: [Double] = []

    init(level: Double = 0.5) {
        self.level = level
    }

    func current() -> Double? { level }

    func setBrightness(_ value: Double) -> Double? {
        guard !refusesWrites else { return nil }
        writes.append(value)
        level = value
        return value
    }
}

/// Setting a level from the island's own bar, rather than from a key.
///
/// The third way a level changes on this Mac, and it publishes on exactly the terms the second one
/// does: **volume says nothing and brightness says it itself**. That asymmetry is the whole of what
/// can go wrong here — a volume write that also published would give the island two publishers for
/// one level, and a brightness write that did not would move the panel with nothing on screen to
/// say so.
@Suite("Setting a level from the island")
@MainActor
struct LevelWriteTests {

    /// Runs `body` with a live source and **holds it alive for the duration** — the trap
    /// `VolumeKeyReplacementTests.withSource` records: a source bound to `_` is released before the
    /// first line of the test, and every write then answers false against correct code.
    ///
    /// - Returns: everything the source published while `body` ran, which is half of what each test
    ///   here is about — the two levels deliberately publish differently.
    @discardableResult
    private func withSource(
        volume: Double = 0.5,
        brightness: Double = 0.5,
        enabled: Set<SystemHUD> = Set(SystemHUD.allCases),
        volumeControl: FakeVolumeControl? = nil,
        brightnessControl: FakeBrightnessControl? = nil,
        _ body: (SystemHUDSource, FakeVolumeControl, FakeBrightnessControl) -> Void
    ) -> [BuiltInActivity] {
        let volumeControl = volumeControl ?? FakeVolumeControl(volume: volume)
        let brightnessControl = brightnessControl ?? FakeBrightnessControl(level: brightness)
        let source = SystemHUDSource(
            audio: FakeAudioObserver(current: SystemHUDAudioSnapshot(volume: volume, isMuted: false)),
            brightness: UnavailableBrightnessMonitor(),
            mediaKeys: FakeKeysForReplacement(),
            volumeControl: volumeControl,
            brightnessControl: brightnessControl
        )
        source.enabledHUDs = enabled
        var published: [BuiltInActivity] = []
        source.onActivity = { activity in
            if let built = activity as? BuiltInActivity { published.append(built) }
        }
        source.start()
        body(source, volumeControl, brightnessControl)
        source.stop()
        return published
    }

    // MARK: - Volume

    @Test("a drag writes the volume it was given")
    func volumeIsWritten() {
        withSource { source, volumeControl, _ in
            #expect(source.setLevel(.volume, to: 0.25))
            #expect(volumeControl.volumeWrites == [0.25])
        }
    }

    /// **Nothing is published here**, and that is the design rather than an omission: the write
    /// fires a CoreAudio property listener, which produces the reading and the activity by the one
    /// route every other cause of a volume change already uses.
    @Test("the volume says nothing on its own — CoreAudio reports it")
    func volumePublishesNothing() {
        let published = withSource { source, _, _ in
            _ = source.setLevel(.volume, to: 0.25)
        }
        #expect(published.isEmpty)
    }

    /// A device that answers reads and refuses writes leaves the island having claimed nothing.
    @Test("a refused volume write is reported as refused")
    func refusedVolumeWrite() {
        withSource { source, volumeControl, _ in
            volumeControl.refusesWrites = true
            #expect(source.setLevel(.volume, to: 0.25) == false)
        }
    }

    /// Apple plays its click for a key and not for a slider, and one per frame of a drag would be a
    /// rattle.
    @Test("dragging a level makes no sound")
    func noFeedbackClick() {
        withSource { source, volumeControl, _ in
            _ = source.setLevel(.volume, to: 0.25)
            _ = source.setLevel(.volume, to: 0.30)
            #expect(volumeControl.feedbackCount == 0)
        }
    }

    // MARK: - Brightness

    /// **The asymmetry.** The change notification DisplayServices posts was only ever measured for
    /// changes Isleta did not cause, so a brightness write publishes its own reading — exactly as
    /// the key-replacement path does, and for the same reason.
    @Test("brightness publishes the level it landed on")
    func brightnessPublishesItself() {
        let published = withSource { source, _, _ in
            _ = source.setLevel(.brightness, to: 0.8)
        }
        #expect(published.count == 1)
        #expect(published.first?.kind == .systemHUD)
        #expect(published.first?.presentations.trailing.value?.normalized == 0.8)
        // Reaching an end is a fact about a *reading*; a drag is the user placing the level, and the
        // island is not asked to lean for it.
        #expect(published.first?.reachedLimit == nil)
    }

    @Test("a refused brightness write publishes nothing and says so")
    func refusedBrightnessWrite() {
        let control = FakeBrightnessControl()
        control.refusesWrites = true
        let published = withSource(brightnessControl: control) { source, _, _ in
            #expect(source.setLevel(.brightness, to: 0.8) == false)
        }
        #expect(published.isEmpty)
    }

    // MARK: - What may not be dragged

    /// The bar beside a crossed-out speaker is drawn at zero whatever volume is held behind the
    /// mute, so it is a statement rather than a setting — `BuiltInActivity.systemHUD` publishes no
    /// `adjustableLevel` for it, and this is the same refusal said at the other end of the wire.
    @Test("a mute is not a level and cannot be set")
    func muteRefuses() {
        withSource { source, volumeControl, _ in
            #expect(source.setLevel(.mute, to: 0.5) == false)
            #expect(volumeControl.volumeWrites.isEmpty)
        }
    }

    /// A HUD the user has switched off has no bar on screen to drag, so a write for it is a caller
    /// that has lost track of what is showing — the same filter `enabledHUDs` applies to publishing.
    @Test("a level the user switched off is not written")
    func disabledLevelRefuses() {
        withSource(enabled: [.brightness]) { source, volumeControl, _ in
            #expect(source.setLevel(.volume, to: 0.25) == false)
            #expect(volumeControl.volumeWrites.isEmpty)
        }
    }

    // MARK: - The fraction

    /// Clamped here as well as in the island, because it arrives from a pointer that is allowed to
    /// leave the bar mid-drag — and CoreAudio's own range has no opinion about what is past its end.
    @Test("a fraction outside the range is clamped rather than refused", arguments: [
        (-0.5, 0.0), (1.5, 1.0),
    ])
    func fractionIsClamped(asked: Double, written: Double) {
        withSource { source, volumeControl, _ in
            #expect(source.setLevel(.volume, to: asked))
            #expect(volumeControl.volumeWrites == [written])
        }
    }
}
