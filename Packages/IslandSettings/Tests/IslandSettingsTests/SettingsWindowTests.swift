import AppKit
import SwiftUI
import Testing

@testable import IslandSettings

/// The settings window is the one window in Isleta that is *supposed* to take focus, and it is
/// presented from an app with no Dock icon and no menu bar. These pin the properties that look
/// right and are wrong.
@Suite("Settings window")
@MainActor
struct SettingsWindowTests {

    /// Each test builds its own controller and holds it, rather than searching `NSApp.windows`:
    /// windows here deliberately survive being closed, so a search would find a previous test's.
    private func makeController() -> SettingsWindowController {
        // Touching `NSApplication.shared` first — an `NSWindow` created before the application
        // object exists comes up without a valid graphics context.
        _ = NSApplication.shared
        let controller = SettingsWindowController(
            store: SettingsStore(storage: InMemorySettingsStorage()),
            updater: UnavailableUpdater()
        )
        controller.show()
        return controller
    }

    /// The trap. A programmatically created `NSWindow` releases itself on close, so the first
    /// dismissal deallocates it while the controller still holds the reference — and the second
    /// "Settings…" shows a zombie or crashes.
    @Test("the window survives being closed and can be shown again")
    func windowIsNotReleasedWhenClosed() throws {
        let controller = makeController()
        let window = try #require(controller.window)
        #expect(window.isReleasedWhenClosed == false)

        controller.close()
        controller.show()
        #expect(controller.window === window)
        #expect(window.isVisible)
        controller.close()
    }

    @Test("the window follows the active Space, and carries no full-screen behavior")
    func windowFollowsTheActiveSpace() throws {
        // Reported from hardware: Settings opening on a previous desktop rather than the one the
        // user is on. The window is reused across invocations, and a reused NSWindow belongs to the
        // Space it was last ordered front on — so opening it, switching desktops, and opening it
        // again gives you the window's Space, not yours.
        let controller = makeController()
        let window = try #require(controller.window)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))

        // The other half, and the reason this test exists rather than a one-line change: setting a
        // full-screen behavior on this window makes it **never appear** — `show()` runs, isVisible
        // is true, and the screen stays empty, with nothing in the log. Verified twice on macOS 27.
        // A future edit that reaches for `collectionBehavior` again fails here instead of on a Mac.
        #expect(window.collectionBehavior.contains(.fullScreenNone) == false)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary) == false)

        // Not `.canJoinAllSpaces`: that leaves the window hanging over every desktop the user
        // switches to, which is what a HUD does, not a settings window.
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces) == false)
        controller.close()
    }

    /// Unlike `IslandPanel`, which must never become key or main (§4.1), this one must    /// Unlike `IslandPanel`, which must never become key or main (§4.1), this one must — otherwise
    /// the toggles work and the window looks dead, with no keyboard focus anywhere in it.
    @Test("the window can take focus, unlike the island panel")
    func windowCanBecomeKey() throws {
        let controller = makeController()
        #expect(try #require(controller.window).canBecomeKey)
        controller.close()
    }

    /// An `.accessory` app has no menu bar, so there is no Close item to carry ⌘W and nothing above
    /// the window in the responder chain to turn Escape into a dismissal.
    @Test("the window closes itself from the keyboard, since there is no menu bar to do it")
    func windowHandlesItsOwnDismissal() throws {
        let controller = makeController()
        let window = try #require(controller.window)

        window.cancelOperation(nil)
        #expect(window.isVisible == false)

        controller.show()
        let commandW = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        #expect(window.performKeyEquivalent(with: commandW))
        #expect(window.isVisible == false)
    }

    @Test("the window is sized by its content rather than left at zero")
    func windowHasASize() throws {
        let controller = makeController()
        let window = try #require(controller.window)
        #expect(window.frame.width > 400)
        #expect(window.frame.height > 300)
        controller.close()
    }

    /// Why the first-run guard is `setFrameUsingName` and not a test on the origin.
    ///
    /// `makeWindow` builds the window at `.zero` and then grows it to the hosting controller's
    /// fitting size. `setContentSize` holds the frame's **top-left** corner, so in AppKit's y-up
    /// space growing the window drags the y origin far negative — it is never `.zero` again, and an
    /// `if frame.origin == .zero { center() }` guard is dead code that reads as live. The window is
    /// then constrained back onto the screen, which is what turns "never centerd" into the milder
    /// looking "opens against the left edge, low".
    ///
    /// **The window must have content for this to reproduce**, which is the trap inside the trap: a
    /// bare `NSWindow` grown the same way keeps its origin at `.zero` exactly, so the obvious
    /// two-line disproof of this test passes and says the guard was fine.
    @Test("growing a window with content moves its origin, so an origin test cannot detect a first run")
    func setContentSizeMovesTheOriginAwayFromZero() {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: Color.clear.frame(width: 760, height: 592))
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        #expect(window.frame.origin == .zero)   // still true here — the move happens below

        window.setContentSize(hosting.view.fittingSize)
        #expect(window.frame.origin != .zero)
        #expect(window.frame.origin.y < 0)
    }

    /// With nothing remembered, the window is centerd. Measured before the fix: it opened flush
    /// against the left edge of the screen and low, because the guard above never fired.
    ///
    /// One drag fixes it permanently on any given Mac, which is what kept it hidden — it is only
    /// ever wrong on a machine that has not opened Settings before.
    @Test("with no remembered frame the window is centerd rather than left against the screen edge")
    func windowIsCenterdOnFirstRun() throws {
        _ = NSApplication.shared
        let key = "NSWindow Frame IsletaSettingsWindow"
        let remembered = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let remembered {
                UserDefaults.standard.set(remembered, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let controller = SettingsWindowController(
            store: SettingsStore(storage: InMemorySettingsStorage()),
            updater: UnavailableUpdater()
        )
        controller.show()
        let window = try #require(controller.window)
        let screen = try #require(window.screen ?? NSScreen.main)

        // Only x is asserted exactly: `center()` centers horizontally but sits the window about a
        // third from the top, so its midY is deliberately above the screen's.
        #expect(abs(window.frame.midX - screen.visibleFrame.midX) < 1)
        #expect(window.frame.minX > screen.visibleFrame.minX)
        #expect(window.frame.maxY <= screen.visibleFrame.maxY + 1)
        controller.close()
    }
}
