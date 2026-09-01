import AppKit

/// The accessibility settings the island's motion and material must respect (§6.3).
///
/// §6.3 calls these a correctness requirement rather than polish, and it's right: the island's
/// entire vocabulary is motion, so a user who has asked for less of it is asking about the main
/// thing this app does.
///
/// Observed, never polled — `NSWorkspace` posts a notification when any of them change.
@MainActor
@Observable
public final class AccessibilityPreferences {

    public private(set) var reduceMotion: Bool
    public private(set) var reduceTransparency: Bool
    public private(set) var increaseContrast: Bool

    private var observation: (any NSObjectProtocol)?

    public init() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast

        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
    }

    private func refresh() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}
