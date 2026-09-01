import IslandActivities
import Testing

@testable import IslandSources

/// The gray-area guardrails from §2.6, written as tests because they are promises to the user
/// rather than implementation details.
///
/// **Four of these have been inverted**, and the history is the useful part. They asserted that
/// nothing was suppressible and that nothing outlived the process, and both were right for as long
/// as they were measured facts. On 2026-08-30 consuming a level key was measured to stop the key —
/// and then the feature turned out to need a CoreAudio write that wakes Apple's helper anyway, so
/// the mechanism became a `SIGSTOP` and the promise about process death could no longer be kept.
///
/// A test that pins a *decision* changes when the decision does. A test that pins a *promise* should
/// not — and this suite no longer has one, which is exactly what the owner signed up for. What is
/// left guards the next best thing: that the code says out loud what it actually does.
@Suite("SystemHUDSuppression")
struct SystemHUDSuppressionTests {

    /// **This assertion is inverted, and that is the point of it.**
    ///
    /// It read `== false` for the life of this file, guarding CLAUDE.md's rule that suppression must
    /// be restored on quit *and* on crash and uninstall. The rule was knowingly overridden by the
    /// owner on 2026-08-30: consuming the key turned out not to be enough — Isleta's own CoreAudio
    /// write wakes the helper — so suppression is now a `SIGSTOP` on `OSDUIHelper`, which outlives
    /// the process that sent it.
    ///
    /// The test still exists, still fails loudly on a change, and now pins the opposite fact. What
    /// it is really guarding is that **the constant tells the truth**: a mechanism that writes state
    /// outliving the process must say so, because `repairAtLaunch()` and the synchronous `resume()`
    /// are built on that admission. Flipping this back to `false` without removing the SIGSTOP would
    /// make every mitigation around it look unnecessary.
    @Test("the SIGSTOP mechanism admits that it outlives the process")
    func suppressionOutlivesTheProcess() {
        #expect(SystemHUDSuppression.survivesProcessDeath)
    }

    /// All three levels, as of 2026-08-30.
    ///
    /// This assertion read `== [.volume, .mute]` and said brightness was "a deliberate scope line…
    /// it should fail loudly the day somebody adds the case without adding the ramp behind it."
    /// It did fail loudly, and the ramp is behind it: `BrightnessStep` holds a measured ladder —
    /// thirteen lit levels of 0.0825 from a floor of 0.01, plus an off — and
    /// `SystemBrightnessControl` writes through `DisplayServicesSetBrightnessSmooth` so the panel
    /// glides the way every other brightness change on the Mac does.
    ///
    /// The scope line that remains is **external displays**, which are unmeasured. The keys drive the
    /// built-in panel regardless of where the menu bar is, and that is the only panel this was tested
    /// against.
    @Test("all three levels are suppressible")
    func suppressibleSet() {
        #expect(SystemHUDSuppression.suppressible == [.volume, .mute, .brightness])
    }

    /// **Off unless asked.** CLAUDE.md's first condition, and the reason `apply` takes the setting
    /// rather than reading a capability and assuming consent.
    @Test("nothing is suppressed unless the user asked for it")
    func offByDefault() {
        #expect(SystemHUDSuppression.apply(enabled: false, accessibilityGranted: true).isEmpty)
    }

    /// Without the grant the tap receives nothing at all — a non-nil mach port and an empty stream,
    /// measured twice. A Mac that has not granted Accessibility suppresses nothing however the
    /// setting reads, and saying otherwise would put a stored lie in front of the user.
    @Test("without Accessibility nothing is suppressed, whatever the setting says")
    func requiresTheGrant() {
        #expect(SystemHUDSuppression.apply(enabled: true, accessibilityGranted: false).isEmpty)
    }

    @Test("with the setting on and the grant held, the level keys are suppressed")
    func suppressesWhenAskedAndPermitted() {
        #expect(SystemHUDSuppression.apply(enabled: true, accessibilityGranted: true) == SystemHUDSuppression.suppressible)
    }

    /// The grant is passed in rather than read, so this suite answers the same on a machine that has
    /// granted Accessibility and one that has not. A test whose result depends on the developer's
    /// own TCC database is the kind that passes everywhere except CI.
    @Test("apply never reports more than it could possibly do")
    func applyReportsWhatItDid() {
        for granted in [true, false] {
            for enabled in [true, false] {
                let suppressed = SystemHUDSuppression.apply(enabled: enabled, accessibilityGranted: granted)
                #expect(suppressed.isSubset(of: SystemHUDSuppression.suppressible))
            }
        }
    }

    /// `@MainActor` because `restore()` now touches another process — the rest of the suite is
    /// pure value logic and deliberately stays off the actor.
    @Test("restoring is safe to call at any time, including when nothing was suppressed")
    @MainActor
    func restoreIsSafe() {
        SystemHUDSuppression.restore()
        SystemHUDSuppression.restore()
        SystemHUDSuppression.apply(enabled: true, accessibilityGranted: true)
        SystemHUDSuppression.restore()
        // `restore()` thaws Apple's helper, and is a no-op when nothing was frozen — including on a
        // machine where no helper is running at all, which is what makes it safe to call from a
        // termination path that cannot know.
        #expect(SystemHUDSuppression.apply(enabled: true, accessibilityGranted: true) == SystemHUDSuppression.suppressible)
    }

    /// The sentence a user reads beside a switch. It says what Isleta does, never which API it uses
    /// — and after 2026-08-30 it must also not claim the platform makes something impossible, which
    /// is what the brightness string said for a year while `DisplayServicesSetBrightness` worked.
    @Test("every HUD has a user-facing reason, and none of them names an API")
    func everyHUDExplainsItself() {
        for hud in SystemHUD.allCases {
            let explanation = SystemHUDSuppression.explanation(for: hud)
            #expect(!explanation.isEmpty)
            for jargon in ["launchctl", "CGEventTap", "OSDUIHelper", "CoreAudio", "DisplayServices"] {
                #expect(!explanation.contains(jargon), "\(hud.rawValue) names \(jargon) to the user")
            }
            #expect(!explanation.contains("no public way"),
                    "\(hud.rawValue) still claims the platform cannot do something it can")
        }
    }
}
