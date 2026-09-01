import AppKit

/// The borderless, non-activating panel the island is drawn into — one per screen (§4.1).
///
/// Two rules matter more than the rest:
///
/// 1. **It never becomes key or main** — with one deliberate, temporary exception, `acceptsKeyboardInput`.
///    Clicking the island must not deactivate whatever the user was working in: no title-bar
///    flicker, no lost caret. `canBecomeMain` returns false unconditionally and `canBecomeKey`
///    returns false until something asks for a typing surface, rather than relying on
///    `.nonactivatingPanel` alone.
/// 2. **Its frame never changes.** The panel is created at the maximum expanded bounds and left
///    there for the lifetime of the screen. Expansion happens to SwiftUI content inside it (§4.2).
///
/// ## Do not set `ignoresMouseEvents`
///
/// Not even to `false`, which is already the default. The window server normally derives a window's
/// event shape from the alpha channel of its backing store, which is what lets a click land on the
/// app underneath wherever the panel is transparent. *Assigning* `ignoresMouseEvents` — either
/// value — replaces that derived shape with the window's whole frame, and the panel silently starts
/// swallowing every click in a 603x200pt region across the top of the display. It looks completely
/// correct on screen, because nothing about what is drawn changes.
///
/// Measured on macOS 27.0 (26A5416b) by bisecting the panel configuration one property at a time;
/// `ignoresMouseEvents = false` was the only line that broke pass-through. `PassThroughSelfTest`
/// exists to catch a regression here, because nothing else will.
@MainActor
public final class IslandPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                    // we draw our own
        isMovableByWindowBackground = false
        isMovable = false
        acceptsMouseMovedEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Without this the first click on the island is swallowed activating the panel's app.
        // Combined with `.nonactivatingPanel` it lets the island respond on the very first click
        // while the user's frontmost app keeps focus.
        animationBehavior = .none
    }

    /// Whether the panel may take key **for the length of one deliberate typing act**, and nothing
    /// else. False at rest, false during every hover, click, drag, scrub and drop.
    ///
    /// ## Why this exists at all
    ///
    /// A window that is not key receives no keystrokes. That is not an AppKit policy with a way
    /// around it — it is what key *means* — so a text field on this panel is inert while the rule
    /// above holds unconditionally, and there is no supported alternative: a global `NSEvent`
    /// monitor observes keys without consuming them, so every character would also land in the
    /// user's editor, and a consuming `CGEventTap` would mean re-implementing selection, dead keys,
    /// marked text and the candidate window by hand — which is not a text field, it is a worse one.
    ///
    /// ## What taking key actually costs, measured
    ///
    /// Three probes on macOS 27.0, run from a `.accessory` process with a real app frontmost, this
    /// panel's exact style mask and level, sampling before / during / after:
    ///
    /// ```
    /// at rest         frontmost=Code  isActive=false  panelKey=false  Code's focused window main=true
    /// key, composing  frontmost=Code  isActive=true   panelKey=true   Code's focused window main=true
    /// after resignKey frontmost=Code  isActive=false  panelKey=false  Code's focused window main=true
    /// ```
    ///
    /// - `NSWorkspace.frontmostApplication` **never moves**. No Dock switch, no menu-bar swap —
    ///   `.nonactivatingPanel` is doing its job, and this is the half of the promise that matters.
    /// - The frontmost app's focused window stays `AXMain = true` throughout: **no title-bar
    ///   flicker**, which is the symptom §Interaction names.
    /// - `NSApp.isActive` does flip true for the duration, and back on `resignKey()`. That is the
    ///   entire cost, and on an `LSUIElement` app with no Dock tile and no menu bar there is nothing
    ///   on screen that draws it.
    /// - Handing key back is `acceptsKeyboardInput = false` then `resignKey()`. `NSApp.hide(nil)`
    ///   and `NSApp.deactivate()` were both measured unnecessary, and `hide` is actively wrong — it
    ///   takes the island off screen with everything else.
    ///
    /// The one thing no probe can show is the **caret** in the app behind, which stops blinking
    /// while another window is key. That is macOS, it is true of every typing surface on the system,
    /// and it is what the user asked for by clicking into a reply field. It is also why this is a
    /// flag rather than a policy: it is affordable exactly once, for as long as somebody is typing.
    public var acceptsKeyboardInput = false

    public override var canBecomeKey: Bool { acceptsKeyboardInput }
    public override var canBecomeMain: Bool { false }

    /// Belt and braces alongside `canBecomeKey`: some AppKit paths route through this instead, so
    /// the gate has to be repeated here rather than assumed.
    public override func makeKey() {
        guard acceptsKeyboardInput else { return }
        super.makeKey()
    }
}
