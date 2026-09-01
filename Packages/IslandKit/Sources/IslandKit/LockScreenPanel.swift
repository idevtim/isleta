import AppKit

/// The panel the lock-screen card is drawn into — one per screen, like `IslandPanel`.
///
/// ## This surface takes no input, and that is not a limitation to work around
///
/// Measured on macOS 27.0 (26A5421a): with the screen locked, `NSWindow.windowNumber(at:)` at the
/// center of **every** window — ours and a shipping competitor's, at every level, in every space —
/// resolves to loginwindow's shield. loginwindow captures all input at the lock, and it should: a
/// third-party process must not be able to see keystrokes at a password prompt.
///
/// So this panel is a **readout**. Nothing inside it may look pressable: no buttons, no scrubber
/// handle, no hover affordance, no cursor change. A control that cannot be operated is worse than an
/// absent one, because the user tries it, nothing happens, and they conclude the app is broken —
/// which is the same argument `NowPlayingController.canSkip` already makes about dimming skip
/// buttons a player has prohibited.
///
/// `LockScreenCardLayout` and `LockScreenCardView` enforce this on the drawing side. This class
/// enforces it on the window side by refusing key and main unconditionally: there is no
/// `acceptsKeyboardInput` escape hatch here, and CLAUDE.md's rule that the island's single exception
/// must not be widened to a second caller is exactly why one is not added.
///
/// ## Do not set `ignoresMouseEvents`
///
/// Not even to `false`. The same trap as `IslandPanel`: *assigning* it
/// replaces the window server's alpha-derived event shape with the whole frame. It would look
/// completely correct — this panel wants no events anyway — right up until the user unlocks and
/// finds a transparent rectangle across their desktop swallowing every click. The panel is ordered
/// out on unlock, but an ordering that is late by one frame is a click the user loses, and there is
/// no reason to take the risk for a property whose default is already what we want.
///
/// ## The level is high, and it is above the cursor
///
/// `CGShieldingWindowLevel()` is 2147483628, and `kCGCursorWindowLevel` is 2147483630 — so this
/// panel is drawn *under* the pointer, which is the right way round and is the reason not to reach
/// for `Int32.max` even though the probe showed it works too. It only matters for the moments this
/// panel exists on an unlocked desktop, which are the few hundred milliseconds around an unlock
/// before it is ordered out.
///
/// ## Its frame never animates
///
/// `IslandPanel`'s rule, for `IslandPanel`'s reason: animating `NSWindow.setFrame` produces stepped,
/// tearing motion. The card grows and shrinks by animating SwiftUI content inside a panel sized once
/// to `LockScreenCardLayout.panelSize`.
@MainActor
public final class LockScreenPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        // Drawn in the same view as the card, so the two fade together. `NSWindow.hasShadow` caches
        // a shape derived from the backing store's alpha and would leave a rectangle on the lock
        // screen while the card fades out under it. The shadow is drawn in the view instead, with
        // the margin the card's own layout leaves for it.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // **This is the measured configuration. Do not reason it into something tidier.**
        //
        // The space's absolute level of 400 is what lifts this panel above loginwindow's shield —
        // but "the window level is not the mechanism" is a claim about the two levels the probe
        // actually tested, `CGShieldingWindowLevel()` and `Int32.max`, both of which composited
        // above with a 400 space. It is *not* a claim that any level does. The first build of this
        // file used `.statusBar` (25) and `[.stationary, .fullScreenAuxiliary, .ignoresCycle]`, on
        // the arguments that a low level was tidier on the unlocked desktop and that
        // `canJoinAllSpaces` would fight a panel that belongs to exactly one space. Both arguments
        // read well and **neither was measured**: the space was created, the panels were built, and
        // the lock screen was empty.
        //
        // So these two lines are the probe's own arm, copied.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        animationBehavior = .none
    }

    /// Unconditional. See the type comment: this surface can never receive input, so a panel that
    /// could take focus would be claiming something the window server will not honor.
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// Belt and braces alongside `canBecomeKey` — some AppKit paths route through this instead.
    override public func makeKey() {}
}
