import ApplicationServices
import AppKit
import IslandActivities
import IslandKit

/// Whether this process is trusted for Accessibility, and the one call that offers to change it.
///
/// ## Why this type exists at all
///
/// Accessibility was the permission Isleta used without ever asking for it. `MediaKeyMonitor`
/// needs it — a `CGEventTap` at `.cghidEventTap` receives nothing without it, and reports that by
/// handing back a perfectly good mach port that never fires — and until this type, the only call in
/// the whole app that could raise the prompt was behind `#if DEBUG` in `AppDelegate`. The first-run
/// flow's Accessibility page had been withdrawn along with notifications, and three doc comments
/// went on asserting that "Isleta already asks for Accessibility in onboarding" after it had stopped
/// being true.
///
/// So this is not a wrapper for tidiness. It is the shipping path that the rest of the codebase had
/// already been written as though it had.
///
/// ## `AXIsProcessTrusted` has no `notDetermined`
///
/// Every other permission here distinguishes *never asked* from *refused*, because §10 turns on the
/// difference: an offer in the first case, an explanation and a deep link in the second. **The
/// Accessibility API cannot express it.** There is no authorization-status call — only
/// `AXIsProcessTrusted()`, a `Bool`, and a process that was refused is indistinguishable from one
/// that was never listed.
///
/// The consequence is deliberate rather than a limitation to route around: `access` reports
/// `.notDetermined` for every untrusted process, and `request()` is safe to call repeatedly.
/// `AXIsProcessTrustedWithOptions` is the one prompt on macOS that *will* show again after a
/// refusal — it adds the app to the Accessibility list and its button opens the exact pane — which
/// is why "ask again" is an honest offer here and is not for Calendar, Location or Automation.
///
/// ## There is no usage-description key
///
/// Unlike Calendar, Location, Bluetooth and Focus, Accessibility has no `Info.plist` string —
/// macOS supplies its own sentence naming the app. `Config/Isleta-Info.plist` says so explicitly;
/// this note is here so nobody adds one looking for the sentence to change.
@MainActor
public enum AccessibilityAccess {

    /// The two states the platform can actually tell apart.
    ///
    /// Two cases rather than `SourceAuthorization`'s four, and named so at the point of use rather
    /// than being mapped into a shape that would imply a `denied` this API cannot report. A caller
    /// that wants the four-case vocabulary is asking a question the system will not answer.
    public enum Access: Equatable, Sendable {

        /// `AXIsProcessTrusted()` is true. Media keys arrive, and the HUDs can be replaced.
        case granted

        /// Untrusted — never listed, listed and switched off, or listed under a signature that has
        /// since changed. The three are one state to this API and to the user's next action, which
        /// is the same in all three.
        case notGranted
    }

    /// Read live, never cached.
    ///
    /// A grant can be revoked in System Settings while Isleta runs, and — on a Debug build — is
    /// revoked by the next `xcodebuild`, because TCC keys the grant to the code signature and an
    /// ad-hoc cdhash changes on every build. `Tools/sign-debug.sh` is what makes it survive; a
    /// cached answer here would make a stale grant look live for the length of a session.
    public static var access: Access {
        AXIsProcessTrusted() ? .granted : .notGranted
    }

    /// Raise the system's own Accessibility prompt.
    ///
    /// **The only thing that reliably puts Isleta in that list.** Privacy & Security has been
    /// reorganised more than once and the pane is not where a written instruction says it is — as of
    /// macOS 27.0 there is no Accessibility section where the previous release put one. The prompt
    /// sidesteps the layout entirely: it names the app, adds it to the list, and its button opens
    /// the exact pane.
    ///
    /// Call this **only from a control the user clicked** (§10). Nothing in Isleta's launch path may
    /// reach it, which is what `SourceHub.didPromptDuringLaunch` exists to check.
    ///
    /// - Returns: whether the process was already trusted *before* the prompt. False is not a
    ///   failure — the dialog is modal to the user rather than to us, so the answer arrives later,
    ///   through `access` at the next `didBecomeActive`.
    @discardableResult
    public static func request() -> Bool {
        // The option key spelled literally rather than through `kAXTrustedCheckOptionPrompt`, which
        // is a `var` in the SDK and so not concurrency-safe to touch. The string is
        // ApplicationServices' own and has never changed.
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        IslandLog.system.info("accessibility: prompt raised — already trusted: \(trusted)")
        return trusted
    }
}

/// The deep link into Accessibility, beside the code that knows why it is needed.
///
/// Same arrangement as `BluetoothPrivacySettings`, `GlancePrivacySettings` and
/// `FocusPrivacySettings`: the URL lives next to the permission rather than in a table of strings
/// somewhere central, so the one that breaks is the one you are already reading.
///
/// **The prompt is the better route and this is the fallback**, which is the reverse of every other
/// permission here. Elsewhere the system refuses to ask twice and a deep link is all that is left;
/// Accessibility will ask again, and its dialog's own button opens this pane more reliably than the
/// URL does — see the note in `AccessibilityAccess.request()` about the pane moving.
public enum AccessibilityPrivacySettings {
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
