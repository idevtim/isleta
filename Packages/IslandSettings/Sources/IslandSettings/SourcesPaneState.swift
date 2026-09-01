import AppKit
import IslandActivities

/// What the Sources pane needs from the running app that a `SourceSettingsRow` cannot carry.
///
/// The same arrangement `GlanceSettingsState` uses, for the same two reasons — IslandSettings must
/// build and preview with nothing granted (§3), so it cannot import the package that links
/// ScreenCaptureKit and Intents; and every field here is a live system read, so it is snapshotted
/// when Isleta comes back to the front rather than called from `body`.
///
/// What lives here rather than in `SourceSettingsRow` does so for one structural reason:
/// **`SourceSettingsRow` is keyed on `ActivityKind`, and none of this is a source.** Focus is a gate
/// consulted at the hub's funnel, not something that publishes — `ActivityKind.focusChanged` exists
/// and has no publisher; see `SourceToggles.respectsFocus`.
public struct SourcesPaneState {

    public enum FocusAccess: Equatable, Sendable {
        case unavailable
        case notDetermined
        case granted
        case denied
    }

    public var focusAccess: FocusAccess

    /// Raise the Focus dialog. Nil unless a prompt would actually show — §10's no-nagging rule, the
    /// same one `GlanceSettingsState` enforces by having no closure rather than a disabled button.
    public var requestFocusAccess: (@MainActor () -> Void)?

    /// Open System Settings at the right privacy pane for a permission already refused.
    ///
    /// An enum rather than a URL string, for `GlanceSettingsState.PrivacyPane`'s reason: the deep
    /// links live in the app shell beside the ones that already exist rather than being invented a
    /// second time here.
    public var openPrivacySettings: (@MainActor (PrivacyPane) -> Void)?

    public enum PrivacyPane: Sendable {
        case focus
    }

    public init(
        focusAccess: FocusAccess = .unavailable,
        requestFocusAccess: (@MainActor () -> Void)? = nil,
        openPrivacySettings: (@MainActor (PrivacyPane) -> Void)? = nil
    ) {
        self.focusAccess = focusAccess
        self.requestFocusAccess = requestFocusAccess
        self.openPrivacySettings = openPrivacySettings
    }

    // MARK: - Copy

    /// What the per-app card says under its title.
    ///
    /// Two sentences, chosen by whether anything has arrived, because the empty state here is not a
    /// failure and would read as one. A user who has just installed Isleta opens this pane and finds
    /// nothing; they are owed the reason rather than an empty box.
    /// What the Focus card says.
    ///
    /// The `unavailable` sentence is the one worth having: it is a build problem rather than a user
    /// one, and a card that said "not granted" there would send somebody to System Settings to look
    /// for a row that is not in the list.
    public var focusSummary: String {
        switch focusAccess {
        case .granted:
            settingsText("sources.focus.summary.granted", """
                While a Focus is on, Isleta holds back calendar alerts. Everything you do \
                yourself — a volume key, a timer, a track change — still shows.
                """)
        case .notDetermined:
            settingsText("sources.focus.summary.notDetermined", """
                Isleta hasn’t asked whether it may see your Focus. Until it does, a Focus quiets \
                nothing here: the island keeps showing calendar alerts through Do Not Disturb.
                """)
        case .denied:
            settingsText("sources.focus.summary.denied", """
                Focus access is off, so the island shows calendar alerts through Do Not Disturb. \
                Turning it on in System Settings is what makes the switch above do anything.
                """)
        case .unavailable:
            settingsText("sources.focus.summary.unavailable", """
                This build cannot ask about Focus, so the island shows calendar alerts through Do \
                Not Disturb whatever the switch says.
                """)
        }
    }
}
