import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit.hidsystem
import IslandKit
import IslandSources

/// Whether consuming a level key in a `CGEventTap` actually stops macOS drawing its own HUD.
///
/// **The one measurement that decides whether Isleta can replace the system HUDs**, and the reason
/// it has to live inside the app rather than in a scratch binary.
///
/// ## Why a shell probe cannot answer this
///
/// Attempted 2026-08-30 as a standalone Swift binary run from a terminal. It reported
/// `AXIsProcessTrusted() == true`, `CGEvent.tapCreate` returned a non-nil port, `tapIsEnabled` read
/// true for the whole run — and the tap received **nothing at all**: zero mouse-moved, zero key,
/// zero flags-changed events across twenty seconds of deliberate input, on a broad mask that would
/// have caught any of them.
///
/// That is `MediaKeyMonitor`'s trap in a third place, with a new wrinkle. TCC judges a request
/// against the *responsible* process, so a shell-launched binary inherits Terminal's grant — and
/// what it inherits is the **answer**, not the capability. `AXIsProcessTrusted()` says yes about a
/// process that then gets an empty stream, so every reading taken through it is of a tap that was
/// never receiving. An earlier run of that probe reported "66 keys consumed, volume frozen" and was
/// used to claim the mechanism worked; the volume was frozen because nothing was arriving, and the
/// pass-through control was frozen too, which is what gave it away.
///
/// **So: `open -a`, always, for this class of question.** CLAUDE.md's rule is not only about usage
/// strings.
///
/// ## The design
///
/// Two phases in one run, advancing on **presses rather than on a clock**. A fixed window produced
/// one run with events and one with none, because the person pressing the key is reading an
/// instruction that arrives when it arrives; a press-driven phase cannot be missed.
///
/// - **Phase A — control.** The tap is installed and passes every event through. Volume-up must
///   raise the volume and macOS must draw its HUD. A phase A that does not move the volume is a
///   void run, not a result: it means the tap is not receiving, and phase B's silence would then
///   mean nothing.
/// - **Phase B — test.** The same tap returns nil for the same key. If the volume holds *and* the
///   HUD does not appear, the system never saw the key.
///
/// The volume reading is **directional** — volume-up must *raise* it. An absolute delta reads a run
/// of ups and downs that cancel out as "did not move", which is what made the first attempt at this
/// inconclusive.
///
/// The one thing this cannot read is whether the HUD appeared, because that is a window in another
/// process (`SLSGetWindowAlpha` on a foreign window is a documented no-op here). The operator
/// reports it, and the phase A control is what makes their report trustworthy: they have just seen
/// the HUD appear under identical conditions.
///
/// ## It restores itself
///
/// The tap is process-scoped kernel state, so quitting, crashing or force-quitting this test hands
/// the keys straight back to macOS with nothing to undo. That property is the whole reason the
/// event tap is the only suppression candidate `SystemHUDSuppression` did not reject on the
/// restore-after-crash requirement.
///
///     open -a Isleta.app --args --hud-consume-test --no-sources
///
/// Run from a shell instead and it answers about Terminal, which is the mistake above.
@MainActor
enum HUDConsumeSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--hud-consume-test")
    }

    /// Presses per phase. Five is enough for the volume to move well clear of the reading noise and
    /// few enough that nobody gives up halfway.
    private static let pressesPerPhase = 5

    /// Held for the run, and **the reason it exists is that the callback may capture nothing.**
    ///
    /// A `CGEventTapCallBack` is a `@convention(c)` function pointer, so its closure has no context:
    /// every value it touches has to be reachable statically or through `userInfo`. The first
    /// version of this file captured the `completion` closure inside it, which is not expressible —
    /// and rather than the clean diagnostic that deserves, **swift-frontend crashed** (macOS 27.0,
    /// Xcode 26.5, `-swift-version 6`), printing a stack trace and the whole compiler command line
    /// with no line number and no message. A `BUILD FAILED` with no error attached to a file is
    /// worth recognising: look for a capture in a C-convention closure before anything else.
    private final class Run {
        var consuming = false
        var pressesA = 0
        var pressesB = 0
        var volumeAtStart: Float?
        var volumeAfterA: Float?
        var tap: CFMachPort?
        var finished = false
        /// True between the last phase-A press and the boundary reading. See `record(isDown:)`.
        var settling = false
        /// Carried here rather than captured, for the reason above.
        let completion: @MainActor (String) -> Void
        init(completion: @escaping @MainActor (String) -> Void) { self.completion = completion }
    }

    private static var current: Run?

    static func run(completion: @escaping @MainActor (String) -> Void) {
        let trusted = AXIsProcessTrusted()

        guard trusted else {
            completion("""
                FAIL (expected) — Isleta is not trusted for Accessibility, so a tap would receive \
                nothing. Grant it and run again:
                      Tools/sign-debug.sh   (so the grant survives the next build)
                      open -a Isleta.app --args --request-accessibility
                """)
            return
        }

        let state = Run(completion: completion)
        current = state

        // Captures nothing — everything it needs is on `HUDConsumeSelfTest.current` — and it
        // **decodes outside the isolated block**, handing in only the two `Sendable` values it
        // learned. `CGEvent` is not `Sendable`, so passing the event itself into
        // `MainActor.assumeIsolated` is a compile error under Swift 6; the fix is not
        // `@preconcurrency` on the import, which would silence a rule that is telling the truth.
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let passThrough = Unmanaged.passUnretained(event)
            guard type.rawValue == 14,
                  let key = LevelKeyProbe(event: event),
                  key.code == NX_KEYTYPE_SOUND_UP
            else { return passThrough }
            // Safe: an event tap callback runs on the thread owning the run loop its source was
            // added to, which is the main one here.
            let consume = MainActor.assumeIsolated { HUDConsumeSelfTest.record(isDown: key.isDown) }
            return consume ? nil : passThrough
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // `.defaultTap`, not `.listenOnly` — a listen-only tap cannot consume, and consuming is
            // the entire subject of this measurement.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: callback,
            userInfo: nil
        ) else {
            current = nil
            completion("FAIL — tapCreate returned nil even though Accessibility is granted.")
            return
        }
        state.tap = tap
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
            .commonModes
        )
        CGEvent.tapEnable(tap: tap, enable: true)
        state.volumeAtStart = outputVolume()

        print("""
            hud-consume self-test: PHASE A — the tap passes events through (this is the control).
                              **Press volume up \(pressesPerPhase) times.**
                              Apple's HUD SHOULD appear and the volume SHOULD rise.
                              accessibility: \(trusted), volume: \(format(state.volumeAtStart))
            """)
        fflush(stdout)

        // A ceiling rather than a window. Nothing here depends on it firing; it exists so an
        // unattended run reports a void rather than hanging a process holding an event tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            MainActor.assumeIsolated {
                guard let state = current, !state.finished else { return }
                state.finished = true
                finish()
            }
        }
    }

    /// One volume-up event, and the answer to whether it should be swallowed.
    ///
    /// Extracted from the callback so that the callback captures nothing and touches no
    /// non-`Sendable` value. Returns `true` while phase B is running, which is the whole
    /// measurement — everything else here is bookkeeping around that one bit.
    private static func record(isDown: Bool) -> Bool {
        guard let state = current else { return false }

        if state.consuming {
            if isDown {
                state.pressesB += 1
                if state.pressesB >= pressesPerPhase, !state.finished {
                    state.finished = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
                }
            }
            return true
        }

        if isDown {
            state.pressesA += 1
            if state.pressesA >= pressesPerPhase, !state.settling {
                // **The boundary reading has to wait for the system to catch up.**
                //
                // The first version read the volume synchronously right here and flipped
                // `consuming` in the same breath. But this call is happening *while the fifth
                // pass-through key is still travelling*: the system has not applied it yet, so
                // `volumeAfterA` under-read by exactly one notch and that notch then landed in
                // phase B's column. The run reported FAIL with phase A up four notches for five
                // presses and phase B up one — arithmetic that only makes sense as an artifact.
                //
                // So: keep passing events through, let CoreAudio settle, *then* read the boundary
                // and start consuming. `settling` stops the fifth-press branch re-arming on the
                // presses that arrive during the wait.
                state.settling = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        guard let state = current else { return }
                        state.volumeAfterA = outputVolume()
                        state.consuming = true
                        print("""
                            hud-consume self-test: PHASE B — the tap now CONSUMES the key.
                                              **Press volume up \(pressesPerPhase) more times.**
                                              Watch whether Apple's HUD appears. It should not.
                                              volume at the boundary: \(format(state.volumeAfterA))
                            """)
                        fflush(stdout)
                    }
                }
            }
        }
        return false
    }

    private static func finish() {
        guard let state = current else { return }
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: false) }
        let after = outputVolume()

        let lines = [
            "phase A (passed through): \(state.pressesA) presses, "
                + "\(format(state.volumeAtStart)) → \(format(state.volumeAfterA))",
            "phase B (consumed): \(state.pressesB) presses, "
                + "\(format(state.volumeAfterA)) → \(format(after))",
        ]

        let verdict: String
        if state.pressesA < pressesPerPhase {
            // **The void case, and the one that matters most.** A tap that receives nothing looks
            // exactly like a tap that is consuming everything, and reading the second from the
            // first is how this measurement was got wrong once already.
            verdict = "VOID — phase A never completed, so the tap was not receiving. This proves "
                + "nothing about consumption. An absence is not a measurement."
        } else if let start = state.volumeAtStart, let afterA = state.volumeAfterA,
                  afterA - start <= 0.001 {
            verdict = "VOID — the control failed: volume-up did not raise the volume while the tap "
                + "was passing events through. Nothing downstream of a broken control can be read."
        } else if state.pressesB < pressesPerPhase {
            verdict = "INCOMPLETE — phase B did not finish. Run it again and press the key \(pressesPerPhase) times."
        } else if let afterA = state.volumeAfterA, let after, abs(after - afterA) > 0.001 {
            verdict = "FAIL — the volume still moved while the tap was consuming, so the key "
                + "reached the system anyway. Consuming at .cghidEventTap does not suppress it."
        } else {
            verdict = "PASS — the volume held while the tap consumed, so the system never saw the "
                + "key. **Confirm on screen that Apple's HUD stopped appearing in phase B**; the "
                + "HUD belongs to another process and cannot be read from here."
        }

        IslandLog.system.info("hud-consume self-test finished")
        let completion = state.completion
        current = nil
        completion(([verdict] + lines).joined(separator: "\n                  "))
    }

    private static func format(_ value: Float?) -> String {
        guard let value else { return "unreadable" }
        return String(format: "%.4f", value)
    }

    /// The system's output level, read the way `SystemHUDAudioObserver` reads it —
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on the default output device, which
    /// is the one the volume keys drive.
    private static func outputVolume() -> Float? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return nil }

        var volume: Float = 0
        var volumeSize = UInt32(MemoryLayout<Float>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            device, &volumeAddress, 0, nil, &volumeSize, &volume
        ) == noErr else { return nil }
        return volume
    }
}

/// One decoded `NX_SYSDEFINED` press.
///
/// A local decoder rather than a reach into `MediaKeyMonitor`'s: this one has to see key *up* as
/// well as key down, because a tap that consumes only the down half leaves the up half to reach the
/// system, and whether that alone is enough to draw a HUD is part of what is being measured.
private struct LevelKeyProbe: Sendable {
    let code: Int32
    let isDown: Bool

    init?(event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }
        code = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
        isDown = ((nsEvent.data1 & 0x0000_FFFF) & 0xFF00) >> 8 == 0x0A
    }
}
