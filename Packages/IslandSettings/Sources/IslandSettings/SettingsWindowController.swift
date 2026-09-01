import AppKit
import SwiftUI

/// Presents the settings window from an agent app.
///
/// Isleta is `LSUIElement` with `.accessory` activation policy (§3), which changes three things
/// about showing a window and each of them is a bug if it is missed:
///
/// 1. **The app is not active, and clicking a status-bar menu does not make it active.** Ordering
///    the window front without activating puts a visible, correctly drawn settings window on screen
///    behind whatever the user was doing, with no key focus — the toggles work but the window looks
///    dead and cannot be closed with the keyboard. Activating is also not the one-liner it appears
///    to be: `NSApp.activate()` is cooperative and does nothing for us. See `show()`.
/// 2. **An accessory app has no menu bar.** So there is no Close item and no ⌘W, and nothing in
///    AppKit will map Escape to dismissal for us. `SettingsWindow` supplies both itself. The
///    alternative — switching to `.regular` while the window is open — hands Isleta a Dock icon
///    and a menu bar, which is precisely the app this one is not.
/// 3. **`isReleasedWhenClosed` defaults to true for a programmatically created `NSWindow`.** The
///    first close deallocates it while this controller still holds the reference, and the second
///    "Settings…" either shows a zombie or crashes. It is set false here.
///
/// None of this touches the island panel. That panel must never become key or main (§4.1) and this
/// window must, which is exactly why it is a separate `NSWindow` rather than anything layered onto
/// `IslandPanel`.
@MainActor
public final class SettingsWindowController {

    private let store: SettingsStore
    private let updater: any SoftwareUpdater
    private let sourceRows: @MainActor () -> [SourceSettingsRow]
    private let hasSynthesizedIsland: @MainActor () -> Bool
    private let exportLogs: (@MainActor () -> Void)?
    private let glanceState: @MainActor () -> GlanceSettingsState

    /// The Sources pane's notification roster, Focus permission and window-preview
    /// permission. See `SourcesPaneState`.
    private let sourcesState: @MainActor () -> SourcesPaneState

    /// Reopens the first-run flow, and quits Isleta — the two things that were reachable
    /// only from a status-item menu the user can switch off. See `SettingsView`.
    private let openSetupGuide: (@MainActor () -> Void)?
    private let quit: (@MainActor () -> Void)?

    /// Internal rather than private so the tests can assert on the window itself. Not public:
    /// nothing outside this module has any business reaching past `show()`.
    private(set) var window: SettingsWindow?

    /// - Parameters:
    ///   - sourceRows: a closure, not an array. The window outlives every state it shows, and the
    ///     authorizations behind these rows change while the user is away in System Settings — an
    ///     array captured at construction would still be showing "not granted" after they granted it.
    ///   - hasSynthesizedIsland: whether any display in use lacks a notch. A closure for the same
    ///     reason: a display is plugged in and unplugged while this window is open.
    ///   - exportLogs: writes the "Export Logs…" bundle. Supplied by the app shell, which is where
    ///     the diagnostics report inside that file comes from; nil leaves the About pane without a
    ///     Diagnostics card.
    ///   - glanceState: the calendar's authorization, the user's calendars, the location status and
    ///     whether this build holds the WeatherKit entitlement. A closure for the same reason
    ///     `sourceRows` is one — every field behind it changes while the user is away in System
    ///     Settings — and supplied by the app shell because IslandSettings must build with no
    ///     permission granted and therefore cannot import IslandSources.
    ///   - sourcesState: the notification roster, the Focus permission and whether window previews
    ///     are possible. A closure for the same reasons again — the roster grows while this window
    ///     is shut, and both permissions are granted somewhere other than here.
    public init(
        store: SettingsStore = .shared,
        updater: any SoftwareUpdater = UnavailableUpdater(),
        sourceRows: @escaping @MainActor () -> [SourceSettingsRow] = { [] },
        hasSynthesizedIsland: @escaping @MainActor () -> Bool = { true },
        exportLogs: (@MainActor () -> Void)? = nil,
        glanceState: @escaping @MainActor () -> GlanceSettingsState = { GlanceSettingsState() },
        sourcesState: @escaping @MainActor () -> SourcesPaneState = { SourcesPaneState() },
        openSetupGuide: (@MainActor () -> Void)? = nil,
        quit: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.updater = updater
        self.sourceRows = sourceRows
        self.hasSynthesizedIsland = hasSynthesizedIsland
        self.exportLogs = exportLogs
        self.glanceState = glanceState
        self.sourcesState = sourcesState
        self.openSetupGuide = openSetupGuide
        self.quit = quit
    }

    /// Shows the window, creating it the first time and reusing it afterwards.
    ///
    /// Reuse rather than rebuild: a fresh window on every invocation loses the position the user
    /// dragged it to, and — because SwiftUI state would be rebuilt with it — would silently
    /// abandon an in-progress shortcut recording.
    /// - Parameter section: which pane the window opens on, honored only the first time it is
    ///   built. A second "Settings…" reuses the existing window — see `makeWindow` on why reuse
    ///   rather than rebuild — and re-seeding its selection would take a user who had navigated
    ///   somewhere and put them back, which is not what re-opening a window means.
    public func show(section: SettingsSection = .general) {
        let window = window ?? makeWindow(section: section)
        self.window = window

        // Activation first, then key: `makeKeyAndOrderFront` on an inactive accessory app orders
        // the window in without giving it keyboard focus.
        //
        // **`NSApp.activate()` cannot work from here, and it is the API the compiler steers you
        // to.** Since macOS 14 it is a *cooperative* request: the header says outright that the
        // framework "does not guarantee that the app will be activated at all", and that the other
        // application should call `yieldActivation(to:)` *before* the target invokes `activate`.
        // Nothing yields to a status-item click. Whatever the user was working in stays frontmost,
        // and the settings window arrives on screen, correctly drawn, behind it and without key
        // focus — the toggles work, the window looks dead, and Escape does nothing because the
        // keystrokes are going to the other app.
        //
        // Measured on macOS 27.0 with an accessory-policy probe driving six variants from a status
        // menu, with another app frontmost. `active`/`key` one second after the click:
        //
        //   NSApp.activate()                                       false / false
        //   NSApp.activate() on the next runloop pass              false / false
        //   NSApp.activate() + orderFrontRegardless()              false / false   (visible, behind)
        //   NSRunningApplication.current.activate(.activateAllWindows)  false / false
        //   NSApp.activate(ignoringOtherApps: true)                 true / true
        //   ...the same + orderFrontRegardless()                    true / true    (no better)
        //
        // So only the uncooperative call does it, and `orderFrontRegardless()` adds nothing once it
        // is there — ordering front was never the failure. Note the third and fourth rows are the
        // plausible fixes: the window *does* come to the screen, which makes them look like they
        // worked until you notice the title bar is inactive.
        //
        // `activateIgnoringOtherApps:` is annotated `API_TO_BE_DEPRECATED`, not deprecated — it
        // raises no warning on the macOS 26 SDK and so survives `-warnings-as-errors`. If a future
        // SDK does deprecate it, the replacement is not `activate()` unless that release also gives
        // an accessory app a way to activate on its own; re-run the probe before believing it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Bring the window to the Space the user is looking at, rather than the one it was last on.
    ///
    /// The window is **reused** across invocations — see `show()` — and a reused `NSWindow` belongs
    /// to the Space it was last ordered front on. Open Settings, switch desktops, and open it again
    /// from the status item: macOS honors the window's Space, not yours. Reported from hardware as
    /// Settings opening "on a previous window", and it is intermittent for the reason every
    /// Space-assignment bug is — it only shows when the two Spaces differ.
    ///
    /// **This is the one collection-behavior flag this window may carry**, and the surrounding
    /// comment in `makeWindow` says why the rule is otherwise absolute: the full-screen flags make
    /// it never appear at all, silently. `.moveToActiveSpace` is not one of those — it does not
    /// touch the full-screen group and so cannot conflict with the default behavior it joins — but
    /// the failure it would cause is invisible, so it is `insert`ed rather than assigned and it was
    /// verified by opening the window and looking, not by reading the diff.
    ///
    /// Deliberately **not** `.canJoinAllSpaces`: that would leave Settings hanging over every
    /// desktop the user switches to, which is what a HUD does, not a window.
    private static func followTheActiveSpace(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    public func close() {
        window?.performClose(nil)
    }

    private func makeWindow(section: SettingsSection) -> SettingsWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(
                store: store,
                updater: updater,
                sourceRows: sourceRows,
                hasSynthesizedIsland: hasSynthesizedIsland,
                exportLogs: exportLogs,
                glanceState: glanceState,
                sourcesState: sourcesState,
                openSetupGuide: openSetupGuide,
                quit: quit,
                initialSection: section
            )
        )

        let window = SettingsWindow(
            contentRect: .zero,          // the hosting controller's SwiftUI frame sizes it
            // `.resizable` because the content is a split view now: without it the sidebar cannot
            // be dragged and the divider is a decoration. `.fullSizeContentView` because
            // `SettingsBackdrop` has to run behind the title bar — a gradient that stops at the
            // title bar and leaves AppKit's own material above it is two windows stacked.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = settingsText("settings.window.title", "Isleta Settings")
        // Transparent rather than hidden. Hiding the title bar would take the close button with it,
        // and this window has no menu bar behind it to put one back — see `SettingsWindow` on what
        // an `.accessory` app does not get.
        window.titlebarAppearsTransparent = true
        // The *title* is hidden, though, and that is a separate switch from the bar.
        //
        // The detail column used to draw the pane's name here via `navigationTitle`, with a band of
        // `.ultraThinMaterial` behind it so the cards had something to scroll under. Both are gone:
        // the name was already the first heading inside the pane, so the window said "Sources"
        // twice — and the band it needed was the one surface in the window that resolved to gray
        // instead of the backdrop's teal, which is what it looked like from across the room.
        //
        // Without this the bar would fall back to `window.title` and the cards would scroll through
        // *that* instead, which is the same collision with a different word in it. The title still
        // exists for the Window menu and for VoiceOver; it is only not drawn.
        window.titleVisibility = .hidden

        // **Never set `collectionBehavior` on this window.** Both `= [.fullScreenNone]` and
        // `= [.managed, .fullScreenNone]` make it never appear at all: `show()` runs to completion,
        // `isVisible` is true, and the screen stays empty, with no warning, no exception and nothing
        // in the log. `.insert(.fullScreenNone)` fails the same way, because the default behavior it
        // joins already carries a conflicting full-screen flag. Verified twice on macOS 27.0 by
        // building and launching.
        //
        // Recorded because it was reached for while chasing a button that flashed at the top right
        // during the sidebar animation — a wrong diagnosis, since that turned out to be SwiftUI's
        // *second* sidebar toggle (see `SettingsView`), and because the failure is indistinguishable
        // from the window having been broken by anything else in the same build.

        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        Self.followTheActiveSpace(window)
        window.setContentSize(hosting.view.fittingSize)
        // Remembered across launches, so a user who moved it off the notch does not have to again.
        window.setFrameAutosaveName("IsletaSettingsWindow")
        // `setFrameUsingName` answers the question `frame.origin == .zero` was trying to ask, and
        // gets it right: false means no frame was ever saved, so this is a first run and the window
        // needs centring.
        //
        // The origin test that used to be here could not work. `setContentSize` holds the frame's
        // *top-left* corner, so growing this window from `.zero` to its fitting size drags the y
        // origin to about -623 and leaves x at 0 — measured on macOS 27.0. The guard therefore never
        // fired, and AppKit constrained the off-screen frame back onto the display at
        // `visibleFrame.minY`, so a first-ever launch put the settings window flush against the left
        // edge, low. It reads as "not centerd" rather than "never centerd", and one drag fixes it
        // for good on that Mac, so it is invisible to anyone who has opened Settings once.
        //
        // **It only moves because the window already has a `contentViewController`.** A bare
        // `NSWindow` grown the same way keeps its origin at `.zero` exactly, which makes the obvious
        // two-line disproof of all this pass. `SettingsWindowTests` pins both halves.
        //
        // A saved frame is re-applied here rather than trusted from `setFrameAutosaveName`, which
        // is harmless — it is the same rect the autosave just restored.
        if !window.setFrameUsingName("IsletaSettingsWindow") { window.center() }
        return window
    }
}

/// An `NSWindow` that can be dismissed with the keyboard in an app that has no menu bar.
///
/// Both overrides exist only because an `.accessory` app's menu bar is never installed, so the
/// standard Close item that would carry ⌘W does not exist and `cancelOperation` has nothing above
/// it in the responder chain to reach. In a `.regular` app neither would be written.
final class SettingsWindow: NSWindow {

    /// Escape. Reaches here only if nothing nearer consumed it — notably, the shortcut recorder's
    /// local event monitor sees key events before the window does, so Escape cancels a recording
    /// in progress rather than closing the window out from under it.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
