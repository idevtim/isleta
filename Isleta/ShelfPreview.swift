import AppKit
import IslandKit
import QuickLookUI

/// QuickLook for a shelf tile: the same preview the space bar gives in the Finder, from the island.
///
/// ## The island panel does not become key, and this is not a loophole — it is a second window
///
/// §4.1's rule is that **`IslandPanel` never becomes key or main**, so that clicking the island
/// cannot deactivate whatever the user was working in. `QLPreviewPanel` is Apple's own panel, it
/// arrives with its own window, and it is useless without key status: space, escape, the arrow keys
/// and its toolbar are all keyboard-driven, and the panel refuses to open at all unless something in
/// the **key window's responder chain** answers `acceptsPreviewPanelControl:`. So the preview is a
/// different window taking key, and `IslandPanel` is untouched — `canBecomeKey` still returns false
/// unconditionally, and `PassThroughSelfTest` and `ClickSelfTest` are unaffected.
///
/// **What it does cost, stated plainly because it is a real cost and not a detail:** to give a
/// window of ours key status, Isleta has to become the active application. For the life of the
/// preview the user's frontmost app is no longer frontmost — its title bar dims and its caret stops
/// blinking — and it comes back when the preview closes. There is no version of this that does not:
/// a preview panel that cannot take keys cannot be dismissed with escape, and one that cannot be
/// dismissed with escape is worse than not having one. It is exactly the trade Finder's own space-bar
/// preview makes, on an explicit click, and it is undone the moment the panel closes (see
/// `restoreActivation`).
///
/// **`activate(ignoringOtherApps:)`, and the compiler steers you to the wrong one.** CLAUDE.md
/// records the measurement: `NSApp.activate()` is cooperative since macOS 14 and cannot activate an
/// `.accessory` app, because nothing yields activation to a status-item click — the window arrives
/// on screen, correctly drawn, behind the user's frontmost app and without key focus. Only
/// `activate(ignoringOtherApps: true)` works, and it raises no deprecation warning under
/// `-warnings-as-errors`.
///
/// ## Why this object is spliced into `NSApp`'s responder chain
///
/// QuickLook finds its controller by walking the responder chain from the key window's first
/// responder. Isleta's key window at the moment of the click is *nobody* — the island panel refuses
/// key status — so there is no chain to find anything in, and the panel would open empty or not at
/// all. `NSApplication` is the end of every chain, and its `nextResponder` is settable, so this
/// object is inserted there once at launch. The app delegate would be the conventional place, and it
/// is an `NSObject` rather than an `NSResponder`; making it one to reach three QuickLook methods
/// would put a framework's plumbing in the file that is supposed to be wiring only.
@MainActor
final class ShelfPreview: NSResponder, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {

    /// What the panel is showing. Files, resolved at the moment of the click — never bookmarks, and
    /// never a stale URL: `ShelfController` asks `ShelfStore.resolve` first, so a file that has been
    /// deleted is marked on the shelf instead of handed to QuickLook, which would draw a blank
    /// window with a generic icon and no explanation.
    private var urls: [URL] = []

    /// The tile the preview came out of, in screen coordinates, so the panel zooms out of it and
    /// back into it. Nil when the tile could not be located, in which case QuickLook falls back to
    /// its own center-of-screen animation.
    private var sourceFrame: CGRect?

    /// Who was frontmost before Isleta took activation, so it can be given back.
    private var previousApplication: NSRunningApplication?

    /// Splices this object into the application's responder chain, keeping whatever was there.
    ///
    /// Called once, at launch. `NSApp.nextResponder` is normally nil for an app with no document
    /// architecture, but assuming that and assigning over it is how a framework that *did* put
    /// something there loses it silently.
    func install() {
        guard NSApp.nextResponder !== self else { return }
        nextResponder = NSApp.nextResponder
        NSApp.nextResponder = self
    }

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Whether the panel is currently showing this exact file, which is what makes a second click on
    /// the same tile close it rather than reopen it — the behavior the space bar has in the Finder.
    func isPreviewing(_ url: URL) -> Bool {
        isOpen && urls.first?.standardizedFileURL == url.standardizedFileURL
    }

    /// Opens the preview on one file.
    ///
    /// - Parameter sourceFrame: the tile, in screen coordinates.
    func show(_ url: URL, from sourceFrame: CGRect?) {
        urls = [url]
        self.sourceFrame = sourceFrame

        // Recorded before activating, not after — by the time the panel is up, the frontmost
        // application is us, and the app we are meant to give focus back to would be Isleta.
        if previousApplication == nil {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApplication = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmost
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = QLPreviewPanel.shared()
        // `updateController` is what makes QuickLook re-walk the responder chain. Without it a panel
        // that has been open once keeps the controller it found then, which after a relaunch of the
        // chain is nobody — the panel opens, and stays empty.
        panel?.updateController()
        panel?.makeKeyAndOrderFront(nil)
        panel?.reloadData()

        // Counts and flags only: never the file's name, its path or its type. That a preview was
        // opened is ours; what was in it is the user's.
        IslandLog.shelf.info("shelf preview opened")
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// Hands activation back to whoever had it.
    ///
    /// Best effort, and it says so: activation is cooperative since macOS 14, so this is a request
    /// rather than an instruction. `yieldActivation(to:)` is the half that makes it likely to be
    /// honored — it is the call the header says the *other* app should make first, and here we are
    /// the other app.
    private func restoreActivation() {
        guard let previousApplication, !previousApplication.isTerminated else {
            self.previousApplication = nil
            return
        }
        self.previousApplication = nil
        NSApp.yieldActivation(to: previousApplication)
        previousApplication.activate()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> any QLPreviewItem {
        urls[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel, sourceFrameOnScreenFor item: any QLPreviewItem) -> NSRect {
        sourceFrame ?? .zero
    }

    // MARK: - Responder chain
    //
    // Nonisolated because the declarations they override are: QuickLook adds them to `NSResponder`
    // in a category that carries no actor annotation, so an isolated override does not compile. They
    // are called on the main thread by AppKit — this is the panel talking to the responder chain
    // during an event — which is what `assumeIsolated` asserts rather than assumes.

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !urls.isEmpty }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            urls = []
            sourceFrame = nil
            restoreActivation()
        }
    }
}
