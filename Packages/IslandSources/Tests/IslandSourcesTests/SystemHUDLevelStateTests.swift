import IslandActivities
import Testing

@testable import IslandSources

/// The rules about *when not to speak*. Every one of these is a HUD a user would have seen for
/// something they did not do.
@Suite("SystemHUDLevelState")
struct SystemHUDLevelStateTests {

    private func snapshot(_ volume: Double?, muted: Bool? = false) -> SystemHUDAudioSnapshot {
        SystemHUDAudioSnapshot(volume: volume, isMuted: muted)
    }

    @Test("the first reading is a baseline, never a HUD")
    func firstReadingIsSilent() {
        var state = SystemHUDLevelState()
        #expect(state.apply(snapshot(0.5)) == nil)
        #expect(state.hasBaseline)
        #expect(state.volume == 0.5)
    }

    @Test("a volume change publishes a volume HUD at the new level")
    func volumeChangePublishes() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5))
        #expect(state.apply(snapshot(0.625)) == SystemHUDReading(hud: .volume, level: 0.625))
    }

    /// CoreAudio delivers eight identical callbacks for one keypress — measured on macOS 26. Seven
    /// of them must produce nothing, or the HUD restarts its dwell eight times.
    @Test("repeated callbacks carrying the same level publish once")
    func duplicateCallbacksAreDropped() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5))

        var published: [SystemHUDReading] = []
        for _ in 0..<8 {
            if let reading = state.apply(snapshot(0.625)) { published.append(reading) }
        }
        #expect(published == [SystemHUDReading(hud: .volume, level: 0.625)])
    }

    /// The mute listener fires on volume changes too, with mute unchanged — also measured. Trusting
    /// "the mute listener fired" would show a mute HUD on every volume keypress.
    @Test("an unchanged mute flag alongside an unchanged volume publishes nothing")
    func unchangedSnapshotIsSilent() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5, muted: false))
        #expect(state.apply(snapshot(0.5, muted: false)) == nil)
    }

    @Test("muting publishes a mute HUD with an empty bar")
    func mutingPublishesEmptyBar() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.8, muted: false))
        #expect(state.apply(snapshot(0.8, muted: true)) == SystemHUDReading(hud: .mute, level: 0))
    }

    @Test("unmuting publishes the volume the user gets back")
    func unmutingPublishesVolume() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.8, muted: true))
        #expect(state.apply(snapshot(0.8, muted: false)) == SystemHUDReading(hud: .volume, level: 0.8))
    }

    @Test("a volume change while muted still reads as muted")
    func volumeChangeWhileMutedStaysMuted() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5, muted: true))
        #expect(state.apply(snapshot(0.4, muted: true)) == SystemHUDReading(hud: .mute, level: 0))
    }

    @Test("rebasing adopts a level without publishing it")
    func rebaseIsSilent() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5))
        state.rebase(to: snapshot(0.1))
        #expect(state.volume == 0.1)
        #expect(state.apply(snapshot(0.1)) == nil)
    }

    // MARK: - Devices that report nothing

    @Test("a device with no volume and no mute never publishes")
    func silentDeviceNeverPublishes() {
        var state = SystemHUDLevelState()
        state.rebase(to: .unavailable)
        #expect(state.apply(.unavailable) == nil)
        #expect(state.apply(snapshot(nil, muted: nil)) == nil)
    }

    @Test("a device that reports mute but no volume can still publish mute")
    func muteOnlyDevicePublishesMute() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(nil, muted: false))
        #expect(state.apply(snapshot(nil, muted: true)) == SystemHUDReading(hud: .mute, level: 0))
    }

    @Test("losing the volume property publishes nothing rather than zero")
    func losingVolumePublishesNothing() {
        var state = SystemHUDLevelState()
        state.rebase(to: snapshot(0.5))
        #expect(state.apply(snapshot(nil)) == nil)
    }

    // MARK: - The activity it becomes

    @Test("the activity carries the kind's own priority, expiry and singleton id")
    func activityUsesKindDefaults() {
        let activity = SystemHUDReading(hud: .volume, level: 0.5).activity
        #expect(activity.kind == .systemHUD)
        #expect(activity.priority == ActivityKind.systemHUD.defaultPriority)
        #expect(activity.expiry == ActivityKind.systemHUD.defaultExpiry)
        #expect(activity.id == ActivityKind.systemHUD.singletonID)
    }

    @Test("volume and brightness share one id, as Apple's HUD does")
    func volumeAndBrightnessShareOneID() {
        #expect(
            SystemHUDReading(hud: .volume, level: 0.5).activity.id
                == SystemHUDReading(hud: .brightness, level: 0.5).activity.id
        )
    }
}
