import AppKit
import IslandKit
import IslandSettings
import Sparkle

/// The real `SoftwareUpdater`: Sparkle, owned by the app shell.
///
/// It lives here and not in IslandSettings on purpose. IslandSettings defines `SoftwareUpdater` and
/// nothing else about updating, so the settings window builds and previews without a third-party
/// framework anywhere in its dependency graph — the same layering rule that keeps IslandUI free of
/// permissions. The seam exists so that this file is the only one that imports Sparkle.
///
/// **Why `SPUUpdater` directly rather than `SPUStandardUpdaterController`.** The standard controller
/// is the documented path and it is the wrong one here. Its `startUpdater` calls
/// `-[SPUUpdater startUpdater:]`, and when that fails it schedules a **modal `NSAlert`** one second
/// later ("Unable to Check For Updates"). `startUpdater:` fails whenever `SUPublicEDKey` is missing
/// or malformed — verified by reading `-checkIfConfiguredProperlyAndRequireFeedURL:` in Sparkle
/// 2.9.6, which validates the EdDSA key inside the very call `startUpdater:` makes. Isleta ships
/// today with a placeholder key (see `Config/Isleta-Info.plist`), so the standard controller would
/// put a modal alert on screen at every launch of an app that has no Dock icon to dismiss it from.
/// Driving `SPUUpdater` ourselves turns the same condition into `canCheckForUpdates == false`, which
/// the settings window already renders honestly.
///
/// That is also the security posture, not a workaround for it: Sparkle refuses to check for updates
/// at all without a valid public key, so an unsigned or misconfigured build simply never updates.
/// The failure is safe in the direction that matters.
@MainActor
final class SparkleUpdater: NSObject, SoftwareUpdater, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    /// Nil until `start()` succeeds. Its absence *is* "this build cannot check", which is why
    /// `canCheckForUpdates` reads through it rather than caching a `Bool` that could disagree.
    private var updater: SPUUpdater?

    /// Held for the updater's lifetime. `SPUUpdater` takes the driver as a parameter and this class
    /// is the driver's delegate, so letting it go would break the activation hooks below.
    private var driver: SPUStandardUserDriver?

    /// The user's answer, remembered from before Sparkle exists.
    ///
    /// `AppDelegate.apply(_:)` pushes the stored configuration in during
    /// `applicationDidFinishLaunching`, but `start()` deliberately runs after the first frame (§9).
    /// Without somewhere to put the answer in between, the setting would be applied to nothing and
    /// Sparkle would come up on the Info.plist default instead of on what the user chose.
    private var automaticChecks: Bool

    /// Why the updater could not start, if it could not. Kept for diagnostics rather than discarded:
    /// "updates are unavailable" with no reason is the same shape of unhelpfulness that
    /// `SettingsStore.loadFailure` exists to avoid.
    private(set) var startFailure: String?

    /// - Parameter automaticallyChecksForUpdates: the shipped default, overwritten by the stored
    ///   configuration before `start()` in every real launch.
    init(automaticallyChecksForUpdates: Bool = true) {
        automaticChecks = automaticallyChecksForUpdates
        super.init()
    }

    // MARK: - Starting

    /// Builds and starts Sparkle. Idempotent, and safe to never call.
    ///
    /// **Called after the first frame, not from `applicationDidFinishLaunching`** — the same rule
    /// `SourceHub` follows. Constructing `SPUUpdater` reads the host bundle, parses the feed URL and
    /// decodes the public key, and `startUpdater:` walks the framework's XPC service directory; none
    /// of that is work the user is waiting on, and §9's 300 ms cold-launch budget is build-failing.
    ///
    /// Nothing here touches the network. Sparkle's first scheduled check happens on its own cycle a
    /// runloop turn later and asynchronously, so a machine with no network and no appcast launches
    /// at exactly the same speed as one with both.
    func start() {
        guard updater == nil, startFailure == nil else { return }

        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )

        // Set before starting, for two reasons. Sparkle brings up its own "check automatically?"
        // permission prompt during the first update cycle *unless* the answer is already known —
        // and Isleta asks that question in its own settings window, so a second modal asking it
        // again would be Sparkle's UI contradicting ours. It also means the first cycle runs on the
        // user's answer rather than on the Info.plist default and then correcting itself.
        updater.automaticallyChecksForUpdates = automaticChecks

        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
            IslandLog.updates.info("Sparkle started — automatic checks \(automaticChecks ? "on" : "off")")
        } catch {
            // The expected outcome in any build without a real `SUPublicEDKey`. Not a crash, not an
            // alert: the settings window says updates are unavailable, and Isleta carries on.
            startFailure = "\(error)"
            IslandLog.updates.error("Sparkle did not start, updates are unavailable: \(error)")
        }
    }

    // MARK: - SoftwareUpdater

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticChecks = enabled
        updater?.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        activateForUpdateUI()
        updater.checkForUpdates()
    }

    // MARK: - Activation

    /// Brings Isleta forward so Sparkle's window is reachable.
    ///
    /// Isleta is `LSUIElement` with `.accessory` activation policy, so it has no Dock icon and no
    /// menu bar. Sparkle's update window is an ordinary `NSWindow`: ordered in from an inactive
    /// accessory app it appears *behind* whatever the user is doing, and there is nothing to click
    /// to bring it forward — no Dock tile, and ⌘-Tab does not list an accessory app either. The
    /// window is drawn, correct, and unreachable.
    ///
    /// This is the exact opposite of the rule that governs `IslandPanel`, which must never become
    /// key or main (§4.1) so that clicking the island cannot deactivate the user's frontmost app.
    /// Both are true at once because they are different windows: the panel is a transparent overlay
    /// the user clicks *through*, and this is a dialog they have to answer.
    ///
    /// `activate(ignoringOtherApps:)` rather than `activate()`, matching `SettingsWindowController`
    /// — which is where the measurement and the full reasoning live. In short: `activate()` is a
    /// *cooperative* request that only lands if the currently-active app yielded first, and nothing
    /// yields to a background update check. It leaves the app inactive and the dialog behind, which
    /// for this window is the failure described above rather than merely an untidy one.
    private func activateForUpdateUI() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - SPUUpdaterDelegate

    /// Fires before Sparkle shows anything, including for a *scheduled* check that the user did not
    /// ask for — which is the case `checkForUpdates()` cannot cover, because nobody is there to have
    /// clicked anything.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        IslandLog.updates.info("update available: \(item.displayVersionString)")
        activateForUpdateUI()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Offline, DNS failure, a 404 on the appcast: entirely normal and not worth an alert.
        // Sparkle already suppresses its own UI for background checks; this is only a log line.
        if let error {
            IslandLog.updates.debug("update cycle finished with error: \(error)")
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// `nonisolated` because `SPUStandardUserDriverDelegate` is the one Sparkle protocol in this
    /// file that is *not* declared `NS_SWIFT_UI_ACTOR`, so a `@MainActor` conformance will not
    /// compile without it. The hop is `assumeIsolated` rather than a `Task`: `SPUStandardUserDriver`
    /// itself is `NS_SWIFT_UI_ACTOR` and calls its delegate synchronously on the main thread, and a
    /// `Task` would land the activation a turn *after* the alert it is supposed to precede.
    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { activateForUpdateUI() }
    }

    /// The same hook for the non-modal path — the update window Sparkle shows when it has found a
    /// version, which is what a scheduled check actually puts on screen.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated { activateForUpdateUI() }
    }
}
