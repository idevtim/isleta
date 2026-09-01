import AppKit
import SwiftUI

/// Presents the first-run flow, and is the only thing that writes the ledger.
///
/// Everything `SettingsWindowController` documents about showing a window from an `.accessory` app
/// applies here unchanged, and for once literally: `NSApp.activate()` is cooperative and does nothing
/// for us, `isReleasedWhenClosed` defaults to true for a programmatically built window, and there is
/// no menu bar to supply ⌘W or map Escape. The differences from that controller are three:
///
/// 1. **Not resizable, not remembered, and chromeless.** The content is a fixed 560×540 and there
///    is nothing in it to make bigger. The title bar is emptied rather than removed — see
///    `makeWindow` for why a `.borderless` window would be the wrong shape for a Mac. A saved frame
///    would be worse than useless — the window is normally seen once, so the frame it saved would
///    only ever be restored on a Mac where the user had reopened it deliberately.
/// 2. **Closing is finishing.** Every exit marks the ledger: the last page's button, Escape, ⌘W —
///    and `NSWindow.close()` itself, which is what makes hiding the traffic lights safe rather than
///    merely tidy. A flow that only counts as done when completed on its own terms comes back at
///    every launch until it gets its way, and §10 rules that out. It stays reachable from the status
///    menu, which is the honest second offer.
/// 3. **It centers itself and stays centerd.** `setContentSize` holds a window's *top-left*, so a
///    window built at `.zero` and grown ends up somewhere off-screen that AppKit then constrains
///    back onto the display — see `SettingsWindowController` for the measurement. Centring after the
///    size is set is the whole fix here, because there is no saved frame to consult.
@MainActor
public final class OnboardingWindowController {

    private let store: SettingsStore
    private let ledger: OnboardingLedger
    private let state: @MainActor () -> OnboardingState
    private var window: OnboardingWindow?

    /// - Parameters:
    ///   - state: what each permission page draws, read fresh every time the flow asks. A closure
    ///     rather than a value for `GlanceSettingsState`'s reason — every field behind it is a live
    ///     system query, and the answers change while the user is away in System Settings, which on
    ///     the Accessibility page is the expected path rather than an edge case.
    ///   - ledger: injected so a test can drive the flow against its own `UserDefaults` suite rather
    ///     than marking the developer's own copy of Isleta as onboarded.
    public init(
        store: SettingsStore = .shared,
        state: @escaping @MainActor () -> OnboardingState = { OnboardingState() },
        ledger: OnboardingLedger = OnboardingLedger()
    ) {
        self.store = store
        self.state = state
        self.ledger = ledger
    }

    /// Whether this launch should put the flow up. Asked by the app shell, answered by the ledger.
    public var shouldPresentAtLaunch: Bool { ledger.shouldPresent }

    /// Shows the flow, building it the first time.
    ///
    /// Called at launch on a fresh install, and from the status menu whenever somebody asks for it
    /// again. Reuse rather than rebuild for the same reason Settings does it: a second call while
    /// the window is already up should bring it forward, not restart the user on page one.
    /// - Parameter step: which page it opens on, honored only the first time the window is built —
    ///   a second `show()` brings the existing window forward rather than restarting the user on a
    ///   page they have moved past. Same rule as `SettingsWindowController.show(section:)`.
    public func show(step: OnboardingStep = .welcome) {
        let window = window ?? makeWindow(step: step)
        self.window = window

        // Only the uncooperative call activates an accessory app — see `SettingsWindowController`
        // for the six-variant measurement. Without it the flow arrives correctly drawn, behind
        // whatever the user was doing, with no key focus: every button works and the window looks
        // dead.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Marks the ledger and closes. The one exit, whichever control the user reached it through.
    public func finish() {
        ledger.markComplete()
        window?.close()
        window = nil
    }

    private func makeWindow(step: OnboardingStep) -> OnboardingWindow {
        let hosting = NSHostingController(
            rootView: OnboardingView(
                store: store,
                initialStep: step,
                state: state,
                onFinish: { [weak self] in self?.finish() }
            )
        )

        let window = OnboardingWindow(
            contentRect: .zero,
            // No `.resizable`: the content is a fixed size and a resizable window with nothing to
            // reflow is an invitation to make it wrong. `.fullSizeContentView` because
            // `SettingsBackdrop` has to run behind the title bar — a gradient that stops at the
            // title bar with AppKit's own material above it is two windows stacked.
            //
            // **`.titled` stays even though nothing titled is drawn**, and that is the whole trick
            // to the chromeless look. A `.borderless` window is not a stock macOS window: it loses
            // the system's corner radius and shadow, cannot become key without an override, and
            // ends up as a rounded rectangle that is *nearly* a Mac window — which is the one
            // outcome ruled out by "a Mac user cannot tell it isn't an Apple feature". So the
            // window stays a real titled window and its title bar is emptied instead.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Kept, though nothing draws it: it is what the Window menu, Mission Control and VoiceOver
        // read, and an untitled window is announced as "window".
        window.title = settingsText("onboarding.welcome.title", "Welcome to Isleta")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Chromeless: no traffic lights, and the page's own button is the only control.
        //
        // **The close button going is a real cost and it is paid deliberately.** Escape and ⌘W both
        // still close, both still mark the ledger, and the status menu's "Open Setup Guide" is the
        // second offer — so the flow is still leaveable, and closing still counts as finished. What
        // is gone is the *visible* exit, which is the thing that was making the window look like a
        // dialog rather than a sequence. Anyone reconsidering this: unhide `.closeButton` alone and
        // leave the other two hidden, rather than restoring the whole title bar.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // The title bar is empty, so the whole window has to be the drag handle — otherwise a
        // 560×540 panel with no chrome cannot be moved off whatever it landed on top of.
        window.isMovableByWindowBackground = true
        // **Never assign `collectionBehavior` on this window.** `= [.fullScreenNone]` makes it never
        // appear at all — `makeKeyAndOrderFront` runs to completion, `isVisible` is true, the screen
        // stays empty, and nothing is logged. Verified twice on macOS 27.0; see
        // `SettingsWindowController` for the full note.
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        // The close button is an exit like any other, so it has to mark the ledger rather than
        // merely hide the window. Without this the flow returns at the next launch to somebody who
        // has already dismissed it.
        window.onClose = { [weak self] in self?.ledger.markComplete() }
        return window
    }
}

/// An `NSWindow` that can be dismissed with the keyboard in an app that has no menu bar, and that
/// tells its controller when it goes.
///
/// Both overrides exist only because an `.accessory` app installs no menu bar: there is no Close
/// item to carry ⌘W, and `cancelOperation` has nothing above it in the responder chain to reach.
final class OnboardingWindow: NSWindow {

    /// Run on every close, including the close button and the two keyboard paths. Set rather than
    /// delegated because `NSWindowDelegate` on this window would be a second object holding one
    /// fact — and the fact is one line long.
    var onClose: (() -> Void)?

    override func close() {
        onClose?()
        // Cleared before `super`, so a `close()` reached from the controller's own `finish()` — which
        // has already marked the ledger — cannot mark it a second time or re-enter through the
        // callback it is inside.
        onClose = nil
        super.close()
    }

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
