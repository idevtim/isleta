import Foundation
import IslandActivities
import IslandKit

/// §2.6 / §8.1.5. Volume, mute, brightness — the HUD for a level the user just changed.
///
/// # What actually ships
///
/// **Volume and mute.** Observed, not polled: CoreAudio property listeners on the default output
/// device push a callback whenever the level moves, from any cause — the keys, Control Center, a
/// slider in Music, `osascript`. No permission, no helper, no timer, nothing on the idle path.
///
/// **Brightness, since 2026-08-22.** Observed the same way and for the same reason: DisplayServices
/// pushes a callback whenever the display brightness moves, from any cause. No permission, no
/// helper, no timer. It is a private symbol resolved at runtime — the fourth such path, and the
/// reasoning is in `DisplayBrightnessMonitor` — so it degrades to `UnavailableBrightnessMonitor`
/// and the pre-1.3.0 behavior if the symbol ever stops answering.
///
/// **Keyboard brightness is not one of the levels**, and it was for five days. The route works —
/// CoreBrightness answers an unentitled process and pushes, which is what disproved an earlier
/// measurement against HID — and it was removed anyway: the ambient-light sensor moves the backlight
/// on its own, so the island kept interrupting itself over a change nobody had made. See `SystemHUD`.
/// `supportedHUDs` reports what this machine can actually do, so the answer is a value the app can
/// show rather than a comment somebody has to find.
///
/// # Why the levels are observed and not the keys
///
/// An event tap on the volume keys would need Input Monitoring, would miss every change the user
/// made with the mouse, and would show a HUD for a keypress that another app had already swallowed.
/// Watching the level itself is strictly better on all three counts, and free.
@MainActor
public final class SystemHUDSource: ActivitySource {

    public static let sourceName = "SystemHUD"

    /// Nothing to grant. CoreAudio's property listeners are unentitled, which is what makes this
    /// the one source in §2 that works identically for every user.
    ///
    /// Deliberately *not* `.denied` on a Mac with no audio output. Denied means "you could have
    /// this and don't", and offering an explanation for a HUD the user never expected on a machine
    /// with no volume control is the nagging §10 forbids. `supportedHUDs` is where absence is
    /// reported.
    public var authorization: SourceAuthorization { .notRequired }

    public var onActivity: ((any IslandActivity) -> Void)?

    public var onDismiss: ((ActivityID) -> Void)?

    public private(set) var isRunning = false

    private let audio: any SystemHUDAudioObserving
    private let brightness: any DisplayBrightnessMonitoring
    private let mediaKeys: any MediaKeyObserving
    private var state = SystemHUDLevelState()
    private var brightnessState = SystemHUDBrightnessState()

    /// Which monitors are attached right now. Tracked rather than asked, because neither protocol
    /// has an `isRunning` — and both wrap C callbacks where registering twice is two callbacks and
    /// unregistering once leaves one.
    private var observingAudio = false
    private var observingBrightness = false
    private var observingMediaKeys = false

    /// **The one thing the media keys are watched for**: the user asked for more of a level that has
    /// none left to give, so the island should rebound again.
    ///
    /// Separate from `onActivity` because it is not an activity and must not become one. Nothing has
    /// changed — no new level, no new reading, nothing to draw — so a re-presented HUD would be
    /// content identical to what is already on stage and `ActivityStack` would correctly report
    /// `.none`. What is left is an *event*, and this is it: a keypress that produced no change,
    /// which is the only kind the level observers cannot see.
    ///
    /// Fired only while the corresponding HUD is enabled and only while its level is already at the
    /// end the key is pushing toward — everything else is somebody adjusting their volume, which the
    /// level observer reports properly.
    public var onLimitPushed: ((SystemHUD, ActivityLimit) -> Void)?

    /// Whether this Mac is delivering the key events the rebound repeat needs. Read by the
    /// diagnostics report; see `MediaKeyMonitor` for why it is not evidence of anything on its own.
    public var isWatchingMediaKeys: Bool { observingMediaKeys && mediaKeys.isAvailable }

    /// Which of the three levels the user wants reported.
    ///
    /// **Two switches rather than one, since 2026-08-24.** Somebody who wants the island to answer
    /// their volume keys does not necessarily want it to answer a brightness ramp, and the shipped
    /// shape offered them the source or nothing. It was three switches for four levels until the
    /// keyboard backlight was removed outright — see `SystemHUD` for why a working route was still
    /// the wrong HUD.
    ///
    /// It gates the *monitors*, not just the publishing, and that is the whole point: a HUD the user
    /// has switched off must not leave a CoreAudio property listener or a DisplayServices callback
    /// attached, because §9 measures the idle path and an observer nobody reads is the purest form of
    /// spending it. Assigning while running attaches and detaches to match; the levels that stay on
    /// are untouched, so turning brightness off does not re-baseline the volume.
    ///
    /// The set is still filtered at publish time as well. `.volume` and `.mute` come from one
    /// observer, so a set holding one but not the other — which the settings switches cannot produce
    /// but a caller can — has to be honored somewhere that sees the reading.
    public var enabledHUDs: Set<SystemHUD> = Set(SystemHUD.allCases) {
        didSet {
            guard isRunning, enabledHUDs != oldValue else { return }
            synchronizeMonitors()
        }
    }

    /// Injectable so the whole of this class is testable with no audio device and no panel, and so
    /// the denied / unavailable path is a test rather than a hardware configuration nobody has.
    ///
    /// The brightness monitor resolves private symbols, so its default is the fallback whenever
    /// they are missing — `make()` returning nil is the OS having moved on, not an error.
    public init(
        audio: any SystemHUDAudioObserving = SystemHUDAudioObserver(),
        brightness: (any DisplayBrightnessMonitoring)? = nil,
        mediaKeys: (any MediaKeyObserving)? = nil,
        volumeControl: (any SystemVolumeWriting)? = nil,
        brightnessControl: (any SystemBrightnessWriting)? = nil
    ) {
        self.audio = audio
        self.brightness = brightness
            ?? DisplayServicesBrightnessMonitor.make()
            ?? UnavailableBrightnessMonitor()
        self.mediaKeys = mediaKeys ?? MediaKeyMonitor()
        self.volumeControl = volumeControl ?? SystemVolumeControl()
        // `make()` returning nil is the OS having moved the symbols, not an error — the fallback
        // refuses every write, so the key is handed back and Apple keeps its HUD.
        self.brightnessControl = brightnessControl
            ?? SystemBrightnessControl.make()
            ?? UnavailableBrightnessControl()
    }

    /// Writes the level once Isleta has swallowed the key that would have. Injected for the reason
    /// every other system reach here is: a test that drove the real one would move the volume of the
    /// Mac running it.
    private let volumeControl: any SystemVolumeWriting

    /// The same for the panel, and a test that drove the real one would dim the developer's screen.
    private let brightnessControl: any SystemBrightnessWriting

    /// Which of the three `SystemHUD` cases this Mac can actually produce, right now.
    ///
    /// Recomputed on each call rather than cached at launch, for the same reason `authorization` is
    /// read on demand: the answer changes when a display or an output device is plugged in, and a
    /// value captured at launch would be wrong for the rest of the session.
    public var supportedHUDs: Set<SystemHUD> {
        var supported: Set<SystemHUD> = []
        let snapshot = audio.snapshot()
        if snapshot.volume != nil { supported.insert(.volume) }
        if snapshot.isMuted != nil { supported.insert(.mute) }
        if brightness.currentBrightness() != nil { supported.insert(.brightness) }
        return supported
    }

    /// Why a HUD this Mac cannot produce is missing, or nil if it can.
    ///
    /// §10: every gap gets a sentence the user can read. The strings live next to the measurement
    /// that produced them, in `SystemHUDBrightness`.
    public func unavailabilityExplanation(for hud: SystemHUD) -> String? {
        guard !supportedHUDs.contains(hud) else { return nil }
        switch hud {
        case .brightness:
            return SystemHUDBrightness.displayUnavailableExplanation
        case .volume, .mute:
            return sourceText(
                "hud.unavailable.volume",
                "This Mac's audio output doesn't report a level Isleta can show."
            )
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        synchronizeMonitors()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        stopAudio()
        stopBrightness()
        stopMediaKeys()
        // **Unconditional, and synchronous.** A source being torn down while it had Apple's helper
        // frozen must give it back — a display reconfiguration or a settings change rebuilds the
        // sources, and a thaw that only ran when `replacesVolumeKeys` was still true would miss the
        // case where the setting is what changed. `resume()` is a no-op if nothing was frozen.
        SystemOSDSuppressor.resume()
    }

    // MARK: - Monitors

    /// Attach the monitors `enabledHUDs` asks for and detach the rest.
    ///
    /// Idempotent per monitor, which is what lets `start()` and a settings change share it: each
    /// half guards on its own `observing` flag, so a set that changed one level leaves the other two
    /// attached and un-rebaselined.
    private func synchronizeMonitors() {
        // `.volume` and `.mute` share one CoreAudio observer — see `SystemHUDLevelState.apply`,
        // which decides between them from a single snapshot — so it runs while either is wanted.
        if enabledHUDs.contains(.volume) || enabledHUDs.contains(.mute) { startAudio() } else { stopAudio() }
        if enabledHUDs.contains(.brightness) { startBrightness() } else { stopBrightness() }
        // Only for the levels that are actually being reported. A key watcher attached for a HUD the
        // user has switched off is the idle-path cost `enabledHUDs` exists to refuse.
        if enabledHUDs.contains(.volume) || enabledHUDs.contains(.brightness) {
            startMediaKeys()
        } else {
            stopMediaKeys()
        }
    }

    /// Whether Isleta is replacing the volume keys rather than watching them.
    ///
    /// Set by the app shell from `IsletaConfiguration.suppressSystemHUDs`, and **off by default** —
    /// CLAUDE.md's first condition for suppression, and the reason this is a stored flag rather than
    /// a capability the source assumes. Changing it restarts the tap, because `CGEvent.tapCreate`
    /// takes `.listenOnly` / `.defaultTap` at creation.
    /// Whether Isleta replaces Apple's brightness HUD rather than appearing beside it.
    ///
    /// **Separate from `replacesVolumeKeys`, not folded into it**, because the two carry different
    /// risk and a user may reasonably want one and not the other. `SystemHUDSuppression` spent a year
    /// arguing that swallowing a brightness key could leave somebody unable to change brightness at
    /// all — the API claim behind that was wrong, but the *stakes* are still higher here than for
    /// volume, and a single switch would make accepting one mean accepting both.
    public var replacesBrightnessKeys = false {
        didSet {
            guard replacesBrightnessKeys != oldValue else { return }
            syncSuppression()
            guard observingMediaKeys else { return }
            stopMediaKeys()
            startMediaKeys()
        }
    }

    public var replacesVolumeKeys = false {
        didSet {
            guard replacesVolumeKeys != oldValue else { return }
            syncSuppression()
            guard observingMediaKeys else { return }
            stopMediaKeys()
            startMediaKeys()
        }
    }

    /// Freeze or thaw Apple's OSD helper to match what is being replaced.
    ///
    /// **One helper draws both HUDs**, so this is a single decision off two flags rather than two
    /// independent suppressions: replacing either level means the helper must not draw, and
    /// replacing neither means it must. Freezing Apple's helper is half the feature and swallowing
    /// the key is the other half — consuming alone leaves the HUD on screen, because Isleta's own
    /// write is what wakes the helper. See `SystemOSDSuppressor`.
    private func syncSuppression() {
        if replacesVolumeKeys || replacesBrightnessKeys {
            SystemOSDSuppressor.suspend()
        } else {
            SystemOSDSuppressor.resume()
        }
    }

    private func startMediaKeys() {
        guard !observingMediaKeys else { return }
        observingMediaKeys = true
        // `.replace` only where the user asked for it *and* Isleta is going to draw something for
        // the key. Swallowing a level key while showing nothing for it would leave the Mac with no
        // feedback at all, which is worse than Apple's HUD.
        let replacing = (replacesVolumeKeys && enabledHUDs.contains(.volume))
            || (replacesBrightnessKeys && enabledHUDs.contains(.brightness))
        mediaKeys.start(mode: replacing ? .replace : .observe) { [weak self] press in
            self?.handle(press) ?? false
        }
    }

    private func stopMediaKeys() {
        guard observingMediaKeys else { return }
        observingMediaKeys = false
        mediaKeys.stop()
    }

    /// A media key went down. Say something **only** if it asked for more of a level that is already
    /// at the end it is pushing toward.
    ///
    /// Everything else is deliberately ignored here and left to the level observers, which see it
    /// properly: a key that moves the volume produces a CoreAudio callback, a reading and a HUD, and
    /// answering the key as well would publish twice for one press. This is the complement of that —
    /// the press that produces no callback at all, because nothing changed.
    ///
    /// Reads the level from the state machine rather than re-querying the device: the state holds
    /// what was last observed, which is by definition what is on screen, and a fresh query would
    /// race the callback that is not coming.
    @discardableResult
    private func handle(_ press: MediaKeyPress) -> Bool {
        let key = press.key

        // **The replacement path, and it runs first.** When Isleta owns the volume keys the press
        // has to *become* the volume change before anything else is decided — the CoreAudio write
        // fires the level observer, which publishes the reading and the HUD exactly as it does for a
        // change from any other cause. Nothing here publishes an activity, and that is deliberate:
        // one publisher for a level means the island cannot show two different answers.
        if replacesVolumeKeys, key.isVolumeKey, enabledHUDs.contains(.volume) {
            return replaceVolumeKey(press)
        }
        if replacesBrightnessKeys, !key.isVolumeKey, enabledHUDs.contains(.brightness) {
            return replaceBrightnessKey(press)
        }

        // Mute has no level and no end to push against, so it has nothing to say to the rebound
        // below. It only reaches this file at all because replacement needs it.
        guard key != .mute else { return false }

        let limit: ActivityLimit = switch key {
        case .volumeUp, .brightnessUp: .maximum
        case .volumeDown, .brightnessDown: .minimum
        case .mute: .maximum
        }
        let hud: SystemHUD = switch key {
        case .volumeUp, .volumeDown, .mute: .volume
        case .brightnessUp, .brightnessDown: .brightness
        }
        guard enabledHUDs.contains(hud) else { return false }

        let level: Double? = switch hud {
        // **A muted Mac is at the bottom of its range, and that took a correction.** This read
        // `isMuted == true ? nil` on the argument that a mute has no range to push against — which
        // is right about *muting* and wrong about being muted: volume-down on a silent Mac is a
        // person pushing at a floor that will not move, which is exactly what this answers.
        // Reported from hardware, 2026-08-29, as nothing bouncing at all while muted.
        //
        // Zero rather than a special case, and the limit test below then does the rest for free:
        // volume-*down* matches `.minimum` and rebounds, while volume-*up* is asking for `.maximum`,
        // does not match, and stays silent — correctly, because that press **unmutes**, which is a
        // real change that reaches the island as a reading like any other.
        case .volume: state.isMuted == true ? 0 : state.volume
        case .brightness: brightnessState.level
        case .mute: nil
        }
        guard let level, SystemHUDReading.limit(atLevel: level) == limit else { return false }

        // **Re-presented as well as announced**, and both halves matter. The re-present restarts the
        // HUD's 1.5s dwell, which is what macOS's own HUD does when you keep pressing at the top —
        // without it the island would rebound with nothing on it once the first press had expired.
        // The activity is identical to the one already on stage, so `ActivityStack` reports `.none`
        // and nothing redraws: the dwell moves and the island holds still.
        // `debug`, not `info`, and the difference was measured rather than argued: a key *held* at
        // an end repeats about ten times a second, so this is not once per user action — twenty-six
        // of them arrived from one spell of leaning on the brightness key. `--verbose-logging` is
        // what answers "does the rebound repeat on this Mac", and it answers it in one press.
        IslandLog.sources.debug("\(hud.rawValue) pushed at its \(limit.rawValue)")
        // **The mute HUD while muted, not a volume HUD at zero.** The re-present exists to restart
        // the dwell, so it has to put back what is already on screen: a crossed-out speaker and the
        // word "Muted". Re-presenting `.volume` here would swap that for a volume bar at nothing
        // every time somebody leaned on the key, which is the island contradicting itself.
        let presented: SystemHUD = (hud == .volume && state.isMuted == true) ? .mute : hud
        onActivity?(BuiltInActivity.systemHUD(presented, level: level, limit: limit))
        onLimitPushed?(hud, limit)
        // Observing, so the key goes through untouched. The replacement path returned long before
        // this line.
        return false
    }

    /// Do what the brightness key would have done, now that Isleta has swallowed it.
    ///
    /// **This one publishes its own HUD, where the volume path deliberately does not**, and the
    /// asymmetry is the whole difference between the two levels.
    ///
    /// A volume write fires a CoreAudio property listener, so the reading and the activity arrive by
    /// the same route every other cause of a volume change uses and publishing here as well would
    /// give the island two publishers for one level. Brightness has no such guarantee: the change
    /// notification `DisplayServicesBrightnessMonitor` registers for is what the *system* posts, and
    /// a write Isleta made itself may or may not come back through it — measured only for changes
    /// Isleta did not cause. So this publishes, and `DisplayBrightnessMonitor` publishing the same
    /// level a moment later is harmless: the activity is identical, so `ActivityStack` reports
    /// `.none` and nothing redraws.
    ///
    /// The level published is where the panel is **going**, not where it is. Apple ramps, so a read
    /// taken now answers with the previous level — see `SystemBrightnessControl.setBrightness`.
    ///
    /// - Returns: whether to swallow the key. **False whenever the panel could not be written**, so a
    ///   Mac where DisplayServices refuses keeps working brightness keys and Apple's HUD.
    ///   `SystemHUDSuppression` was wrong that this was impossible and right that getting it wrong
    ///   means a screen somebody cannot dim.
    private func replaceBrightnessKey(_ press: MediaKeyPress) -> Bool {
        guard let current = brightnessControl.current() else {
            IslandLog.sources.info("brightness key not replaced: panel unreadable")
            return false
        }

        let direction: VolumeStep.Direction
        switch press.key {
        case .brightnessUp: direction = .up
        case .brightnessDown: direction = .down
        case .volumeUp, .volumeDown, .mute: return false
        }

        // Before the write, for the same reason the volume path does it: the write is what would
        // wake Apple's helper, and this is the last moment a respawned one can be frozen.
        SystemOSDSuppressor.ensureSuspended()

        // **`fine` is not passed.** ⇧⌥ quarter-steps are unverified for brightness — see
        // `BrightnessStep`. Passing the flag through would ship a behaviour nobody has measured.
        let outcome = BrightnessStep.apply(direction, level: current)

        if outcome.didChange {
            guard let landed = brightnessControl.setBrightness(outcome.level) else {
                IslandLog.sources.info("brightness key not replaced: write refused")
                return false
            }
            onActivity?(BuiltInActivity.systemHUD(.brightness, level: landed, limit: nil))
        } else if outcome.didReachLimit {
            // Nothing to write, so nothing will notify: the rebound has to come from here, exactly
            // as it does for a volume key pushed at an end.
            let limit: ActivityLimit = direction == .up ? .maximum : .minimum
            IslandLog.sources.debug("brightness pushed at its \(limit.rawValue) (replaced)")
            onActivity?(BuiltInActivity.systemHUD(.brightness, level: outcome.level, limit: limit))
            onLimitPushed?(.brightness, limit)
        }
        return true
    }

    /// Do what the volume key would have done, now that Isleta has swallowed it.
    ///
    /// **Nothing here publishes a HUD**, and that is the design rather than an omission. Writing the
    /// level fires the CoreAudio listener, which produces a reading and an activity by the same path
    /// every other cause of a volume change uses — Control Center, a slider in Music, `osascript`.
    /// Publishing here as well would give the island two publishers for one level and, on the press
    /// that actually changes something, two activities for one press.
    ///
    /// The exception is a press that changes *nothing* — volume-up at 1.0 — which fires no callback
    /// at all (measured 2026-08-29: writing a level equal to the one already held produces no
    /// listener call). That is the case the rebound already exists for, so it falls through to the
    /// limit path below rather than being handled twice.
    ///
    /// - Returns: whether to swallow the key. **False whenever the level could not be written**, so
    ///   a Mac where CoreAudio refuses the write is left with working volume keys and Apple's HUD
    ///   rather than with keys that do nothing. A swallowed key Isleta cannot act on is the worst
    ///   outcome available here.
    private func replaceVolumeKey(_ press: MediaKeyPress) -> Bool {
        guard let current = volumeControl.current() else {
            IslandLog.sources.info("volume key not replaced: no readable output device")
            return false
        }

        let outcome: VolumeStep.Outcome
        switch press.key {
        case .volumeUp:
            outcome = VolumeStep.apply(.up, volume: current.volume, isMuted: current.isMuted, fine: press.isFine)
        case .volumeDown:
            outcome = VolumeStep.apply(.down, volume: current.volume, isMuted: current.isMuted, fine: press.isFine)
        case .mute:
            outcome = VolumeStep.toggleMute(volume: current.volume, isMuted: current.isMuted)
        case .brightnessUp, .brightnessDown:
            return false
        }

        // **Before any write**, because the write is what would wake the helper. This is the
        // event-driven replacement for a respawn watcher: launchd spawns a fresh helper after an
        // idle exit, and this is the last moment it can be frozen before it would have drawn.
        SystemOSDSuppressor.ensureSuspended()

        // Mute first, so an unmuting volume-up is audible at the level it lands on rather than for
        // the instant between two writes.
        if outcome.isMuted != current.isMuted, volumeControl.setMuted(outcome.isMuted) == nil {
            IslandLog.sources.info("volume key not replaced: mute write refused")
            return false
        }

        if abs(outcome.volume - current.volume) > VolumeStep.tolerance {
            guard volumeControl.setVolume(outcome.volume) != nil else {
                IslandLog.sources.info("volume key not replaced: level write refused")
                return false
            }
        }

        // The click macOS would have played, and only if the user's own Sound setting asks for it.
        // Silent at a limit, because Apple's is: pushing at the top makes no sound.
        if outcome.didChange, !outcome.didReachLimit { volumeControl.playFeedback() }

        // A press that moved nothing produces no CoreAudio callback, so the rebound has to come from
        // here — the same complement `handle` documents, reached now from the key Isleta owns.
        if outcome.didReachLimit, !outcome.didChange {
            let limit: ActivityLimit = press.key == .volumeUp ? .maximum : .minimum
            let presented: SystemHUD = outcome.isMuted ? .mute : .volume
            IslandLog.sources.debug("volume pushed at its \(limit.rawValue) (replaced)")
            onActivity?(BuiltInActivity.systemHUD(presented, level: outcome.volume, limit: limit))
            onLimitPushed?(.volume, limit)
        }
        return true
    }

    /// **The race here is deliberately not guarded, because it is invisible.** The keypress that
    /// *arrives* at a limit produces both a CoreAudio callback and a key event, and whichever lands
    /// first, the other may find the level already at its end and ask for a second rebound. Two
    /// requests a few milliseconds apart are one beat on screen: `IslandScreenModel.limitBounce`
    /// strikes from zero, so the second replaces the first before it has travelled anywhere. A time
    /// window to suppress it would be a constant nobody could measure, guarding nothing anyone can
    /// see.

    private func startAudio() {
        guard !observingAudio else { return }
        observingAudio = true

        // The baseline is taken *before* the observer starts, and adopted with `rebase` rather than
        // `apply`, so the current volume is a reference point rather than news. Without this every
        // launch, and every display reconfiguration that rebuilds the controller, would open with a
        // volume HUD for something the user did not do.
        state = SystemHUDLevelState()
        state.rebase(to: audio.snapshot())

        audio.onEvent = { [weak self] event in self?.handle(event) }
        audio.start()
    }

    private func stopAudio() {
        guard observingAudio else { return }
        observingAudio = false
        audio.stop()
        audio.onEvent = nil
        state = SystemHUDLevelState()
    }

    private func startBrightness() {
        guard !observingBrightness else { return }
        observingBrightness = true

        // Same rule as the volume baseline above, and the same bug if it is skipped: the current
        // brightness is a reference point, not news. Without it every launch — and every display
        // reconfiguration that rebuilds the controller — would open with a brightness HUD for a
        // level the user set some time yesterday.
        brightnessState = SystemHUDBrightnessState()
        if let level = brightness.currentBrightness() {
            brightnessState.rebase(to: level)
        }
        brightness.start { [weak self] level in self?.handleBrightness(level) }
    }

    private func stopBrightness() {
        guard observingBrightness else { return }
        observingBrightness = false
        brightness.stop()
        brightnessState = SystemHUDBrightnessState()
    }

    // MARK: - Publishing

    private func handle(_ event: SystemHUDAudioEvent) {
        switch event {
        case .deviceChanged(let snapshot):
            state.rebase(to: snapshot)
        case .changed(let snapshot):
            guard let reading = state.apply(snapshot) else { return }
            // The set is consulted here as well as at the monitor, because this one observer answers
            // for two levels — see `enabledHUDs`.
            guard enabledHUDs.contains(reading.hud) else { return }
            onActivity?(reading.activity)
        }
    }

    /// One callback from the brightness ramp.
    ///
    /// `Date()` rather than an injected clock, matching every other deadline in this codebase —
    /// see PROGRESS.md on why activity deadlines are `Date` and not a monotonic clock. The
    /// throttle here is a hundred milliseconds; a clock step large enough to disturb it is one that
    /// has already disturbed every activity's expiry.
    private func handleBrightness(_ level: Double) {
        guard isRunning else { return }
        guard let reading = brightnessState.apply(level, at: Date()) else { return }
        onActivity?(reading.activity)
    }

    // `onDismiss` is deliberately never called.
    //
    // The contract distinguishes a source knowing its activity is over from the clock assuming it.
    // A HUD is over when its 1.5s of relevance elapses and never before: there is no moment at
    // which "the volume is 40%" stops being true, so a dismissal from here would be the source
    // guessing. Even `stop()` leaves it alone — a HUD already on screen when the source stops is
    // still accurate, and yanking it would put a disappearance on screen that the user did not
    // cause.
}
