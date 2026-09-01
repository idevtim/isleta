import AppKit

/// The panel the open island's blur is drawn into — one per screen, directly beneath `IslandPanel`.
///
/// ## Why the blur is not simply drawn in the island's own panel
///
/// It was, and it cost every click in the band. The window server derives a window's event shape
/// from the alpha of its backing store, so anything painted outside `islandPath` starts routing its
/// clicks to us — and an `NSVisualEffectView` claims **every point its mask covers**, at any tint
/// whatsoever. Measured 2026-08-26 with `--click-test`, sweeping the band at 2, 6, 12 and 20pt
/// outside the island's wall, at blur strengths of 0.34, 0.20, 0.12 and 0.06: *claimed at every
/// point and every strength*. The mask does bound it — the panel's far corner reports `NOT Isleta`
/// throughout, so the shape is honored — but inside that shape the surface is opaque to the window
/// server however faint it looks.
///
/// So there is no strength at which a blur drawn in the island's panel lets a click through, and the
/// only way to have both is to put it in a window that takes no events at all.
///
/// ## `ignoresMouseEvents = true`, which is forbidden on `IslandPanel`
///
/// The rule in CLAUDE.md is "never assign `NSWindow.ignoresMouseEvents` — not even `false`", and it
/// is about `IslandPanel`, where the alpha-derived event shape is the whole mechanism: *assigning*
/// the property replaces that derived shape with the window's entire frame, and the island silently
/// swallows every click across 603x200pt.
///
/// This window wants the opposite thing and is the case the rule does not cover. It draws no
/// control, accepts no click, and has no hit testing of its own; `true` is the documented way to say
/// exactly that, and there is no alpha-derived shape here worth preserving. The check that this is
/// true rather than argued is `--click-test`'s `panel corner` and blur probes and
/// `--perf-report`'s pass-through run, which are what caught the problem this panel exists to fix.
///
/// ## Ordered below the island, hosted in the same space
///
/// The same level as `IslandPanel` and explicitly ordered beneath it, so the island always draws
/// over the middle of its own blur. It joins the private overlay space with the island for the
/// reason `OverlaySpace` gives: a window in a space the user can never switch to belongs to no
/// desktop's picture, so a space slide does not carry it — and a blur that stayed behind while the
/// island was pinned would be worse than no blur at all.
@MainActor
public final class IslandBlurPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none

        // The whole point of this window. See the note above for why the rule that forbids this on
        // `IslandPanel` does not reach here, and what measures it.
        ignoresMouseEvents = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
