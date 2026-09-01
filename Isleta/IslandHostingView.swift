import AppKit
import SwiftUI

/// The island's `NSHostingView`, with the one override a non-key panel needs.
///
/// ## `acceptsFirstMouse` is not about the first click
///
/// The name is a leftover from a world where windows become key. `IslandPanel` returns false from
/// `canBecomeKey` unconditionally (§4.1) — clicking the island must never take focus from whatever
/// the user is typing in — so it is *never* key, and therefore **every** click on it is a first-mouse
/// click, forever. AppKit asks the view under the pointer whether it wants an event delivered to an
/// inactive window; a view that says no gets the click spent activating a window that then refuses
/// to activate, and the press simply does not arrive.
///
/// `IslandHitTestView` has answered true since Milestone 0, with the same reasoning, and that is why
/// clicking the island has always worked. What is new is that `hitTest` now resolves to the hosting
/// view for the transport controls — `IslandHitTestView.hitTest` returns `super.hitTest(point)`, the
/// deepest subview that wants the point — so the hosting view is the one AppKit asks.
///
/// **This is the one claim in this milestone that the self-test cannot settle either way, and it is
/// recorded rather than dressed up.** `TransportSelfTest` synthesises its events into
/// `NSApp.sendEvent` rather than posting them through the window server, for the same reason
/// `ClickSelfTest` does — `CGEventPost` needs the Accessibility permission Isleta deliberately never
/// asks for. Measured on 2026-08-19: the test passes identically with this override removed, because
/// the first-mouse decision belongs to the routing half that `sendEvent` skips. So the override is
/// kept on the argument rather than on the measurement, it costs one line, and the failure it
/// prevents is the kind that gets "fixed" the wrong way: transport buttons that highlight on hover
/// and do nothing when pressed, while the island still expands and collapses perfectly.
///
/// The wrong fix, for the avoidance of doubt, is making the panel key. That trades a working caret
/// in the user's editor for a working button, and §4.1 is not negotiable.
///
/// Nothing else is overridden. In particular this must never gain an `ignoresMouseEvents`, an
/// `.allowsHitTesting(false)` on its root view, or a `hitTest` of its own — all three are catalogd
/// in CLAUDE.md as things that look correct and silently collapse the window's event shape.
@MainActor
final class IslandHostingView<Content: View>: NSHostingView<Content> {

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Required by `NSHostingView`'s designated initializer and never called: Isleta has no nib
    /// (see `IsletaMain.swift`), so nothing decodes this view from an archive.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IslandHostingView is created in code; Isleta has no nib")
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }
}
