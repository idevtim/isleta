import Foundation

/// The seam Sparkle plugs into, and nothing more.
///
/// The point of the seam is what is *not* here: IslandSettings has no dependency on Sparkle, and
/// must not gain one. The settings window builds, tests and previews with no third-party framework
/// in its graph — the same layering rule that keeps IslandUI free of permissions. The real
/// conformance is `SparkleUpdater` in the app shell (`Isleta/SparkleUpdater.swift`), which is the
/// only file in the project that imports Sparkle, and it reaches the window through
/// `SettingsWindowController(store:updater:)`.
///
/// What still does not exist, as of this milestone, is the **EdDSA key pair**. `SUPublicEDKey` in
/// `Config/Isleta-Info.plist` is a placeholder, and `-[SPUUpdater startUpdater:]` validates that key
/// before it will start — so every build today lands on `canCheckForUpdates == false` and says so.
/// That is the safe direction to fail in: no key means no update can be verified, so no update is
/// installed. `Tools/release.sh` refuses to build a release while the placeholder is still there,
/// and its header carries the `generate_keys` command and where the private half goes.
///
/// `IsletaConfiguration.automaticUpdateChecks` was persisted before any of this existed, so a user
/// who had already answered keeps their answer rather than being reset to the default.
@MainActor
public protocol SoftwareUpdater: AnyObject {

    /// Whether this build can check at all. False in every build until the above exists, and the
    /// settings window says so out loud rather than showing a button that does nothing.
    var canCheckForUpdates: Bool { get }

    /// Honors `IsletaConfiguration.automaticUpdateChecks`.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)

    /// User-initiated check.
    func checkForUpdates()
}

/// What the settings window's Updates section shows, derived from the updater.
///
/// Pure and separate from the view for the same reason `SystemHUDLevelState` is: the rule worth
/// pinning down is not "a `Toggle` exists" but "a build that cannot update never shows a control
/// that looks like it works", and a rule living inside a `body` can only be tested by rendering.
/// SwiftUI does not build its accessibility tree in-process, so there is no headless way to ask the
/// window what it drew — measured, not assumed: `NSHostingView` reports a single childless `AXGroup`
/// to a test in the same process, and the real tree is only materialised for an external client.
///
/// The failure this guards against is specific. An enabled "Check Now" that is clicked and silently
/// does nothing is worse than no button at all, because the only reading available to the user is
/// that Isleta is broken — and that is precisely the state every build without a valid
/// `SUPublicEDKey` is in.
struct UpdatesSectionState: Equatable {

    /// Whether the controls do anything.
    let isEnabled: Bool

    /// Why not, when not. Nil when the controls work, so the view has nothing to decide.
    let unavailableReason: String?

    init(canCheckForUpdates: Bool) {
        isEnabled = canCheckForUpdates
        unavailableReason = canCheckForUpdates
            ? nil
            : settingsText("updates.unavailable", "Not available in this build.")
    }
}

/// The updater every current build gets: one that says it cannot check, and does nothing if asked.
///
/// A null object rather than an optional, for the same reason §2.4 insists on a `NullProvider` for
/// Now Playing: the UI has to be fully functional and honest with no updater present, and `if let
/// updater` scattered through it is how that stops being true.
@MainActor
public final class UnavailableUpdater: SoftwareUpdater {

    public init() {}

    public var canCheckForUpdates: Bool { false }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}

    public func checkForUpdates() {}
}
