import ApplicationServices
import Foundation
import IslandActivities

/// Whether Isleta can hide Apple's own volume/brightness HUD, and what it does about it.
///
/// This type is the *mechanism*, not the policy. `IslandSettings` stores `suppressSystemHUDs`;
/// the app shell reads it and calls `apply(enabled:)`. This package must not read the setting —
/// it does not depend on IslandSettings, and a source that reaches for user preferences is a
/// source that cannot be tested without them.
///
/// # The conclusion: Isleta ships alongside the system HUD
///
/// §2.6 allows either. Suppression is a gray area and CLAUDE.md sets three conditions — off by
/// default, one-click reversible, restored on quit *and* on crash and uninstall. Each candidate
/// mechanism on macOS 26 was weighed against those:
///
/// - **`launchctl disable gui/$UID/com.apple.OSDUIHelper`** writes to launchd's override database,
///   which survives reboot. A crash mid-session leaves the user with no volume HUD and no idea
///   which app took it. Fails the hard requirement outright.
/// - **`launchctl bootout`** is session-scoped rather than permanent, but it still outlives the
///   process: after a crash the HUD stays gone until logout. Fails the same requirement, more
///   quietly.
/// - **Killing `OSDUIHelper` as it launches** restores itself on the next keypress, so it passes the
///   crash test, but it is a race with the thing it is racing to suppress: the HUD gets a frame or
///   two on screen before it dies. A visible flicker is worse than the HUD it is trying to hide.
/// - **Consuming the key in a `CGEventTap`** is the only mechanism whose restoration is guaranteed
///   by construction: the tap is process-scoped kernel state, so quit, crash, force-quit and
///   uninstall all restore Apple's HUD with no action from Isleta and nothing to get wrong. It is
///   also the only one that never flickers, because the system never sees the key. But consuming
///   the key means Isleta must *become* the implementation of the thing the key does:
///   - For **brightness** this was recorded as impossible, and **that was wrong — measured
///     2026-08-30.** See "The brightness objection has fallen" below.
///   - For **volume** it is possible, but Isleta would have to reproduce the system's sixteen
///     notches, its ⇧⌥ quarter-notches, its auto-unmute on volume-up and its feedback click, all
///     undocumented, all instantly visible when wrong — and it would cost an Accessibility grant
///     that Isleta otherwise never asks for, in exchange for hiding a HUD the island is already
///     showing a better version of next to. **The second half of that sentence is also now
///     obsolete**: Isleta asks for Accessibility on the first-run flow's `accessibility` page as of
///     2026-08-29, for the media keys. The grant is no longer a cost this feature has to justify on
///     its own.
///
/// # Re-searched 2026-08-22, and the two frameworks that look like the answer are not
///
/// The list above is a list of *mechanisms*, and the obvious objection to it is that it never
/// mentions the framework whose name is the feature. So:
///
/// - **`OSD.framework` is the API behind Apple's HUD, and it only draws.** It loads by path and
///   `OSDManager` is real, and every method on it is a `show`:
///   `showImage:onDisplayID:priority:msecUntilFade:`, the `filledChiclets:totalChiclets:locked:`
///   variant that draws the sixteen volume notches, `showFullScreenImage:…`,
///   `fadeClassicImageOnDisplay:`. There is no hide, no mute, no suppress and no enable flag. It is
///   a client of the same XPC service the system uses, so it would let Isleta *post* a HUD of
///   Apple's own design — the opposite of the request.
/// - **SkyLight has nothing for this.** Its 2,915 exported symbols contain no OSD suppression of
///   any kind, and the cross-process route people reach for next is worse than absent:
///   `SLSSetWindowAlpha` called against another process's window **returns success and does
///   nothing** — measured, with `SLSGetWindowAlpha` reading the window back at 1.0 immediately
///   afterwards. A design built on it would look correct in every review and never work once.
/// - **One new mechanism, which fails the same test more elegantly.** `com.apple.OSDUIHelper` is a
///   launchd agent whose only job is a MachService of that name. Boot the agent out and claim the
///   name and Isleta *becomes* the HUD: the system asks us, so there is no race and no flicker,
///   which is what killed the "kill it as it launches" candidate. It still needs the bootout, so a
///   crash still leaves the user with no volume HUD until they log out — the one requirement
///   nothing in this list can satisfy.
///
/// # The brightness objection has fallen — measured 2026-08-30
///
/// The bullet above said swallowing a brightness key would leave the user unable to change
/// brightness, because `IODisplaySetFloatParameter` answers `kIOReturnUnsupported` on Apple Silicon
/// internal panels. The API's refusal is real and still reproduces. **The conclusion drawn from it
/// was not**, and it is the same error `SystemHUDBrightness` already documents for the *getter*:
/// treating one API's refusal as the platform's answer. `IODisplayGetFloatParameter` refuses too,
/// and `DisplayServicesGetBrightness` has read the panel since 2026-08-22.
///
/// `DisplayServicesSetBrightness` **writes** it, on the same terms:
///
/// ```
/// DisplayServicesSetBrightness resolves: true
///   DisplayServicesCanChangeBrightness resolves: true
///   DisplayServicesSetBrightnessSmooth resolves: true
/// original brightness = 1.0
/// set(0.75) returned 0; read back 0.7499999
/// EFFECT: MOVED     (restored to 1.0)
/// ```
///
/// macOS 27.0, built-in panel, from an ordinary unentitled process with no Accessibility grant. The
/// **read-back is the measurement** — the `0` return value is worth nothing on its own, which is the
/// rule this file's own history is an argument for. That is the fourth instance in this codebase of
/// a capability declared absent on the evidence of one API declining it.
///
/// So the honest statement of the remaining cost is: consuming the keys is buildable, and what it
/// costs is that Isleta becomes the implementation of volume *and* brightness — sixteen notches,
/// quarter-notches, auto-unmute, the feedback click, and a brightness ramp that has to feel like
/// Apple's. That is a fidelity problem, which is a different and much smaller thing than the
/// impossibility this file used to claim.
///
/// # And the consumption step is measured too — 2026-08-30
///
/// Whether a tap at `.cghidEventTap` in `.defaultTap` returning nil actually stops the HUD had never
/// been measured; this file asserted it ("it never flickers, because the system never sees the key")
/// as reasoning. It is now a reading. `HUDConsumeSelfTest` (`--hud-consume-test`), signed Debug
/// build, Accessibility granted, macOS 27.0 (26A5421a), Mac15,9:
///
/// ```
/// phase A (passed through): 5 presses, 0.2000 -> 0.5000     HUD appeared
/// phase B (consumed):       5 presses, 0.5000 -> 0.5000     HUD did NOT appear
/// ```
///
/// Five presses, five notches, in a phase that is a **control** rather than a preamble — and then
/// nothing at all. So consumption works, and it works for the volume HUD specifically, which is the
/// one that had a competing explanation: Atoll's `SystemOSDManager` records that "the CoreAudio
/// volume write wakes/respawns the helper to draw the native OSD", which would have meant the HUD
/// follows the *level change* rather than the key and could not be stopped by swallowing it. It does
/// not: with the key consumed the level never changes, so neither trigger fires.
///
/// **Two earlier attempts at this measurement were wrong, and both failure modes are worth keeping.**
/// A standalone shell binary reported `AXIsProcessTrusted() == true` with a tap that received
/// *nothing at all* — a shell-launched process inherits Terminal's grant, and what it inherits is the
/// answer rather than the capability, so "volume frozen" meant "nothing arriving". Then the in-app
/// version read its phase boundary synchronously inside the tap callback, while the fifth
/// pass-through key was still travelling: it under-read by exactly one notch, that notch landed in
/// phase B's column, and the run reported FAIL with phase A up four notches for five presses.
/// Arithmetic that only makes sense as an artifact is the tell.
///
/// # Why Atoll's mechanism is not the one to copy
///
/// A local reference implementation (`~/Sites/Atoll`, `SystemOSDManager`) suppresses the HUD by
/// **`killall -STOP OSDUIHelper`** — freezing the helper rather than killing it, with a background
/// watcher that re-freezes each incarnation launchd spawns, and `killall -CONT` to restore. It is a
/// better mechanism than the four this file rejected: no flicker, no launchd override database
/// write, and reversible. It still fails on the two rules that decide it here:
///
/// - **It survives process death.** A SIGSTOPped helper stays stopped after a crash, a force-quit
///   or an uninstall, and the user is left with no volume HUD and nothing naming the app that took
///   it. Atoll handles only the graceful path (`resumeOSDUIHelperForTermination`, sending SIGCONT
///   inline because a detached `Task` never completes during termination) and its own comments say
///   so. That is exactly the requirement CLAUDE.md singles out.
/// - **It polls on the idle path.** The watcher runs at 150 ms–1 s for as long as the app lives,
///   because the helper is jetsam-exited when idle and respawned on the next key. §9 forbids that
///   outright. Atoll's own note measures `pgrep` at 67 ms wall and ~5 ms CPU per call and replaces
///   it with `proc_listpids` at 0.6 ms — a real optimisation of a loop Isleta may not run at all.
///
/// Consuming the key needs neither: it is process-scoped kernel state, so every exit path restores
/// Apple's HUD with nothing to undo, and it is driven by the event rather than by a clock.
///
/// # So nothing is suppressed *yet*, and what remains is fidelity
///
/// Nothing is suppressed. `ActivityKind.systemHUD.defaultExpiry` was already tuned for this
/// case: 1500ms so that Isleta's HUD and Apple's do not read as two different lengths when both are
/// on screen.
///
/// # What that buys
///
/// The "restored on quit and uninstall" guarantee holds *vacuously and permanently*: Isleta writes
/// no system state to restore. `survivesProcessDeath` is the executable form of that promise, and
/// `SystemHUDSuppressionTests` is what stops a later milestone quietly breaking it.
public enum SystemHUDSuppression {

    /// Whether any suppression Isleta performs could outlive the process.
    ///
    /// **True as of 2026-08-30, and it was false for the whole life of this file.** This is a
    /// deliberate reversal of the rule CLAUDE.md states, taken by the owner with the cost named, and
    /// it is flagged here rather than quietly flipped because this constant exists precisely to stop
    /// it being flipped quietly.
    ///
    /// The mechanism is a `SIGSTOP` on `OSDUIHelper` (`SystemOSDSuppressor`). A stopped process
    /// stays stopped when the process that stopped it dies, so a crash, a panic or a force-quit
    /// leaves the user with **no volume HUD from anything** — not merely no Isleta HUD — and nothing
    /// on screen naming the app responsible.
    ///
    /// Consuming the key was supposed to avoid all of this, and it does not: the key is genuinely
    /// swallowed, but Isleta must then write the level itself and **the CoreAudio write is what
    /// wakes the helper**. There is no quieter write on this hardware — the default output publishes
    /// `VirtualMainVolume` and no per-channel `VolumeScalar` at all, measured. So the helper has to
    /// be stopped, and stopping it is state that outlives us.
    ///
    /// What bounds the exposure:
    ///
    /// - `SystemOSDSuppressor.repairAtLaunch()` runs **unconditionally** at every launch, before any
    ///   setting is read, so a crash costs the HUD until Isleta next starts rather than until logout.
    /// - `resume()` is synchronous and runs first in `applicationWillTerminate`, which the app's
    ///   SIGTERM/SIGINT sources also reach.
    /// - The feature is off by default, so nobody who has not asked for it can be exposed at all.
    ///
    /// It is still an uninstall away from a Mac with no volume HUD and no Isleta to repair it. If
    /// that is judged too expensive later, the way back is `suppressible = []` — the machinery below
    /// it stays correct and the switch simply stops being offered.
    public static let survivesProcessDeath = true

    /// Which HUDs Isleta is *able* to suppress, given the grant and the implementation behind them.
    ///
    /// **Volume and mute, as of 2026-08-30.** `MediaKeyMonitor` in `.replace` swallows the key and
    /// `SystemVolumeControl` does what the key would have done, with `VolumeStep` deciding where the
    /// level lands — sixteen notches, ⇧⌥ quarter-notches, volume-up unmuting rather than raising,
    /// volume-down walking to zero without muting, and the feedback click only when the user's own
    /// Sound setting asks for one.
    ///
    /// **Brightness joined them on 2026-08-30**, once its ladder had been measured rather than
    /// assumed. It is not volume's: thirteen lit levels of 0.0825 starting at a floor of 0.01, plus
    /// an off below that — where volume has sixteen even notches from zero. And the panel *ramps*,
    /// so `SystemBrightnessControl` writes through `DisplayServicesSetBrightnessSmooth`; a direct
    /// write is correct and feels wrong, because it would be the only brightness change on the Mac
    /// that jumps. `BrightnessStep` holds the readings.
    ///
    /// **External displays are still not covered.** The keys drive the built-in panel regardless of
    /// where the menu bar is, and that is the only panel measured.
    ///
    /// **Ability is not the same as doing it.** Nothing is suppressed until the app shell turns it
    /// on from `IsletaConfiguration.suppressSystemHUDs`, which is off by default — CLAUDE.md's first
    /// condition. This set says what *could* be, so a UI can offer it honestly; `apply(enabled:)` is
    /// what says what is.
    public static let suppressible: Set<SystemHUD> = [.volume, .mute, .brightness]

    /// Why `hud` is not suppressed, in words meant for a user reading a grayed-out switch.
    public static func explanation(for hud: SystemHUD) -> String {
        switch hud {
        case .volume, .mute:
            sourceText("hud.suppression.volume", """
                Isleta shows its own volume HUD alongside the system's rather than replacing it. \
                Hiding the system HUD would mean taking over the volume keys entirely, which Isleta \
                won't do for a cosmetic gain.
                """)
        case .brightness:
            // **Reworded 2026-08-30.** It used to say macOS "offers no public way to change
            // brightness — taking over the key would leave you unable to change it at all", which is
            // false: `DisplayServicesSetBrightness` moves the panel. A user-facing string is the
            // worst place for a platform claim that turns out to be wrong, because it is the one
            // place nobody re-reads. It now says what Isleta does, not what the platform cannot.
            sourceText("hud.suppression.brightness", """
                Isleta shows its own brightness HUD alongside the system's rather than replacing it. \
                Hiding the system HUD would mean taking over the brightness keys entirely.
                """)
        }
    }

    /// What suppression the user's setting asks for, given what this Mac can do.
    ///
    /// It returns rather than throws because "the user asked and we could not" is a UI state, not an
    /// error: the app shell compares what it asked for with what it got and can explain the
    /// difference with `explanation(for:)` instead of storing a preference that quietly means
    /// nothing.
    ///
    /// **This decides nothing on its own.** The suppression is `MediaKeyMonitor`'s tap option, which
    /// only `SystemHUDSource.replacesVolumeKeys` can set; this answers what that will amount to. The
    /// two are separate so the settings window can ask the question without starting a tap.
    ///
    /// - Parameter accessibilityGranted: without it the tap receives nothing at all — a non-nil mach
    ///   port and an empty stream, measured twice — so a Mac that has not granted it can suppress
    ///   nothing no matter what the setting says. Passed in rather than read here because this
    ///   package must stay callable from a preview and a test.
    @discardableResult
    public static func apply(enabled: Bool, accessibilityGranted: Bool = AXIsProcessTrusted()) -> Set<SystemHUD> {
        guard enabled, accessibilityGranted else { return [] }
        return suppressible
    }

    /// Undo everything `apply(enabled:)` did, for `applicationWillTerminate`.
    ///
    /// **No longer a no-op.** It was empty for as long as nothing was suppressed, and this is the
    /// call site that was deliberately kept in the API against the day something was — which is
    /// today. It thaws `OSDUIHelper`.
    ///
    /// Synchronous and idempotent, both load-bearing: it runs from a termination handler, where an
    /// asynchronous thaw would be scheduled onto a run loop that never turns again, and it may be
    /// reached more than once or never having suspended anything.
    ///
    /// The app shell calls `SystemOSDSuppressor.resume()` directly on its quit path rather than
    /// coming through here, because that path must not depend on this type having been consulted.
    /// This exists for callers that think in terms of the *setting* rather than the mechanism.
    /// `@MainActor` rather than the type, deliberately: `suppressible`, `apply` and
    /// `explanation(for:)` are consulted from a settings view being built and must stay callable
    /// from anywhere, where thawing another process's helper is main-actor work like every other
    /// system reach in this package.
    @MainActor
    public static func restore() {
        SystemOSDSuppressor.resume()
    }
}
