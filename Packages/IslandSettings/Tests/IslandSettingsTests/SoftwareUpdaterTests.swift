import AppKit
import Testing

@testable import IslandSettings

/// What the settings window promises about updating.
///
/// The real conformance is `SparkleUpdater` in the app shell, which cannot be reached from here —
/// deliberately, since the whole point of the `SoftwareUpdater` seam is that IslandSettings never
/// gains a Sparkle dependency. What *is* testable here is the half that matters to the user: an
/// updater that cannot check has to be inert and has to be visible as inert, and both of those are
/// properties of this module.
@Suite("Software updater")
@MainActor
struct SoftwareUpdaterTests {

    /// Records what it was told, and answers whatever it was built to answer.
    private final class SpyUpdater: SoftwareUpdater {
        let canCheckForUpdates: Bool
        private(set) var automaticChecks: [Bool] = []
        private(set) var checkCount = 0

        init(canCheckForUpdates: Bool) {
            self.canCheckForUpdates = canCheckForUpdates
        }

        func setAutomaticallyChecksForUpdates(_ enabled: Bool) { automaticChecks.append(enabled) }
        func checkForUpdates() { checkCount += 1 }
    }

    // MARK: - The null object

    /// The contract every build without a usable key falls back to, and the state Sparkle itself
    /// lands in when `SUPublicEDKey` is a placeholder: it says no, and asking anyway is harmless.
    ///
    /// This is a null object rather than an optional for the same reason §2.4 insists on a
    /// `NullProvider` for Now Playing — `if let updater` scattered through the settings window is
    /// how "the UI is fully functional with no updater" stops being true.
    @Test("an unavailable updater reports it cannot check, and does nothing if asked anyway")
    func unavailableUpdaterIsInert() {
        let updater = UnavailableUpdater()
        #expect(updater.canCheckForUpdates == false)

        // Neither call may trap, and neither may pretend to have worked.
        updater.setAutomaticallyChecksForUpdates(true)
        updater.setAutomaticallyChecksForUpdates(false)
        updater.checkForUpdates()

        #expect(updater.canCheckForUpdates == false)
    }

    // MARK: - What the Updates section says

    /// The honest-failure requirement. A build with no usable `SUPublicEDKey` — which is every build
    /// until the owner generates the key pair — must not offer a control that looks like it works.
    @Test("an updater that cannot check grays the controls and says why")
    func updatesSectionIsHonestWhenUnavailable() {
        let state = UpdatesSectionState(canCheckForUpdates: false)
        #expect(state.isEnabled == false)
        // Asserts against the source language: under `swift test` every lookup falls back to the
        // English `defaultValue`. `LocalizationCoverageTests` is what guards the other languages.
        #expect(state.unavailableReason == "Not available in this build.")
    }

    /// The other half. Without it, `isEnabled` could be `false` unconditionally and the test above
    /// would still pass — and the reason line must disappear rather than sit under a live button
    /// contradicting it.
    @Test("an updater that can check leaves the controls live and says nothing")
    func updatesSectionIsSilentWhenAvailable() {
        let state = UpdatesSectionState(canCheckForUpdates: true)
        #expect(state.isEnabled)
        #expect(state.unavailableReason == nil)
    }

    /// The section is derived from the updater, never stored — so the two cannot disagree, and an
    /// updater whose answer changes (Sparkle finishing `startUpdater:`) does not need to notify
    /// anything.
    @Test("the section state follows the updater it was built from")
    func updatesSectionFollowsTheUpdater() {
        for canCheck in [true, false] {
            let updater: any SoftwareUpdater = canCheck
                ? SpyUpdater(canCheckForUpdates: true)
                : UnavailableUpdater()
            #expect(UpdatesSectionState(canCheckForUpdates: updater.canCheckForUpdates).isEnabled == canCheck)
        }
    }

    /// The settings window still builds and shows with an updater that can do nothing — the null
    /// object has to keep the whole window functional, not just the Updates section.
    @Test("the settings window opens with an updater that cannot check")
    func windowOpensWithoutAnUpdater() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(
            store: SettingsStore(storage: InMemorySettingsStorage()),
            updater: UnavailableUpdater()
        )
        controller.show()
        defer { controller.close() }

        let window = try #require(controller.window)
        #expect(window.isVisible)
        #expect(window.frame.width > 400)
    }

    /// `automaticUpdateChecks` is persisted by `SettingsStore` and acted on by the app shell, which
    /// pushes it into the updater from `AppDelegate.apply(_:)`. This pins the half of that handshake
    /// this module owns: a change to the setting has to reach a subscriber at all, and it has to
    /// arrive as the value the user chose rather than as a notification to go and re-read.
    @Test("a change to automatic update checks reaches whoever is driving the updater")
    func automaticChecksReachTheUpdater() {
        let store = SettingsStore(storage: InMemorySettingsStorage())
        let updater = SpyUpdater(canCheckForUpdates: true)

        // The shell's `apply(_:)`, in miniature: one function, called at launch and on every change.
        let token = store.addChangeHandler { updater.setAutomaticallyChecksForUpdates($0.automaticUpdateChecks) }
        defer { store.removeChangeHandler(token) }
        updater.setAutomaticallyChecksForUpdates(store.configuration.automaticUpdateChecks)

        store.update { $0.automaticUpdateChecks = false }
        store.update { $0.automaticUpdateChecks = true }

        #expect(updater.automaticChecks == [true, false, true])
    }

}
