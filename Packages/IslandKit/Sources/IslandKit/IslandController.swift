import AppKit
import QuartzCore

/// Everything IslandUI needs to render the debug overlay without importing AppKit.
public struct IslandDebugInfo: Equatable, Sendable {
    public let screen: IslandScreen
    public let panelFrame: CGRect
    public let metrics: IslandShapeMetrics
    public let bodyOrigin: CGPoint
    public let shapeBounds: CGRect
    public let cornerExtents: CGPoint      // x = top (convex), y = inverted (concave)
    public let windowNumber: Int
    public let trackingAreas: [CGRect]
    public let isHovering: Bool

    public init(
        screen: IslandScreen,
        panelFrame: CGRect,
        metrics: IslandShapeMetrics,
        bodyOrigin: CGPoint,
        shapeBounds: CGRect,
        cornerExtents: CGPoint,
        windowNumber: Int,
        trackingAreas: [CGRect],
        isHovering: Bool
    ) {
        self.screen = screen
        self.panelFrame = panelFrame
        self.metrics = metrics
        self.bodyOrigin = bodyOrigin
        self.shapeBounds = shapeBounds
        self.cornerExtents = cornerExtents
        self.windowNumber = windowNumber
        self.trackingAreas = trackingAreas
        self.isHovering = isHovering
    }
}

/// Owns one `IslandPanel` per screen and keeps them in step with the display configuration (§4.3).
///
/// Panels are keyed by `CGDirectDisplayID` rather than by index into `NSScreen.screens`, because
/// that array reorders when displays are connected, disconnected or rearranged. Screen-parameter
/// notifications are debounced: a single resolution change or a clamshell open emits several in
/// quick succession, and rebuilding on each one tears panels down mid-flight.
@MainActor
public final class IslandController {

    public typealias ContentFactory = @MainActor (IslandScreen) -> NSView

    private struct Attachment {
        let panel: IslandPanel
        /// The window the open island's blur is drawn into, beneath `panel` and inert. Separate
        /// because an `NSVisualEffectView` claims every point its mask covers whatever its tint —
        /// see `IslandBlurPanel`.
        let blurPanel: IslandBlurPanel
        let hitTestView: IslandHitTestView
        var screen: IslandScreen
        /// What the hit region is currently set to, so the debug overlay reports the region that is
        /// actually live rather than the one it assumes should be.
        var hitRegionMetrics: IslandShapeMetrics
        /// Where the blur is drawn, in the panel's y-down space, or empty when the island is not
        /// open and there is none. Stored rather than recomputed for `isPointInBlur`'s reason: the
        /// question it answers is about the band as it is *right now*.
        var blurRegion: CGRect = .zero
    }

    private var attachments: [CGDirectDisplayID: Attachment] = [:]
    private let contentFactory: ContentFactory
    private let blurContentFactory: ContentFactory
    private var observation: (any NSObjectProtocol)?

    /// Separate from `observation` because it is registered on `NSWorkspace`'s notification center,
    /// not `NotificationCenter.default`. A token returned by one center removes nothing when handed
    /// to the other — no error, no log line, just an observer that stays live for the life of the
    /// process.
    private var spaceObservation: (any NSObjectProtocol)?

    /// One per panel, watching whether the window server is actually showing it.
    ///
    /// This is what finally caught the flash on a fullscreen switch. Re-ordering our own calls could
    /// not: the panel is restored by the window server *itself*, part way through the transition and
    /// before `activeSpaceDidChangeNotification` arrives, so by the time we are told the space
    /// changed the island has already been on screen for a frame.
    ///
    /// `occlusionState` is the signal that is actually tied to "is this being shown", and it changes
    /// when the transition covers us rather than when the transition ends.
    ///
    /// It carries the panel's transparency as well as its content, because between two fullscreen
    /// spaces the transition composites a snapshot rather than the live window — see the handler.
    private var occlusionObservations: [any NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?

    /// Ends the transition the island was hidden for, once the signals stop arriving.
    ///
    /// **Fallback only.** With the panels hosted in the private overlay space nothing here runs —
    /// they are in no transition to hide from. This, the occlusion observers and `TransitionSettle`
    /// exist for a macOS where that API has gone, and describe what shipped before it existed.
    ///
    /// There is no notification that marks the end of a space transition, and the ones that exist
    /// disagree about the start: measured on macOS 27.0 with one switch in isolation, the occlusion
    /// drop opens the animation and `activeSpaceDidChange` lands 779–782ms later, at the end — but
    /// entering fullscreen posts its change *before* the drop instead. Reading the order was worth
    /// three attempts and all three were wrong, because consecutive switches overlap and look
    /// exactly like one transition with two halves.
    ///
    /// So this stops trying to tell them apart. Anything that could be a transition hides the island
    /// immediately and pushes this out; when nothing has arrived for `transitionSettleDelay` the
    /// transition is over and the island comes back. The delay clears the widest gap measured inside
    /// a single transition (~1.0s) without waiting for the ~2.2s that overlapping switches suggested.
    ///
    /// **Every** signal pushes it out, including `occlusion visible=true`, which restores nothing on
    /// its own but does prove the transition is still producing events. Leaving that one out is what
    /// made the island bounce half way in, vanish and bounce again: on a fullscreen→desktop switch
    /// the order is drop, `visible=true`, then the space change 779ms later, so the settle expired
    /// between the last two, restored mid-slide, and was hidden again by the change it had not
    /// waited for.
    ///
    /// One shot, armed only while the island is hidden, so it costs the idle budget nothing (§9).
    private var transitionSettle: DispatchWorkItem?

    /// The rule for how long to keep waiting after each signal. Pure and separately tested — every
    /// mistake made getting this right was about the order of signals, which needs no window server
    /// to reproduce. See `TransitionSettle` for the measurements behind the two delays.
    private var settleRule = TransitionSettle()

    /// Where the panels live so that a space transition cannot photograph them. See `OverlaySpace`.
    ///
    /// When this is hosting, none of the transition machinery below runs: the panels are in no
    /// desktop's picture, so there is nothing to hide from and nothing to restore. When it is not —
    /// the private API it needs is gone — the occlusion-driven hide is the fallback, and it is what
    /// shipped before this existed.
    private let overlaySpace: any OverlaySpaceHost

    /// For diagnostics. A host that silently did nothing would be indistinguishable from one that
    /// worked, and the symptom — the island riding along with a space slide — is easy to misread.
    public var isHostedInOverlaySpace: Bool { overlaySpace.isHosting }

    /// Fires after every rebuild so the app shell can refresh anything derived from the layout.
    public var onScreensChanged: (@MainActor ([IslandScreen]) -> Void)?

    /// Fires when the pointer arrives on or leaves a screen's island.
    public var onHoverChanged: (@MainActor (IslandScreen, Bool) -> Void)?

    /// Where the pointer is on one island, or nil once it has left.
    ///
    /// For the parts of the island that are smaller than the island — today the album cover, which
    /// grows the track lip. See `IslandHitTestView.onPointerMoved` for why this is a position
    /// rather than a tracking area of its own, which is a bug that was reported before it was
    /// understood.
    public var onPointerMoved: (@MainActor (IslandScreen, CGPoint?) -> Void)?

    /// Fires when a screen's island is clicked.
    /// A click on the island, and where on it. The point's origin is the island's own top-left,
    /// y down — see `IslandHitTestView.onClick`, which is what makes "was that the top strip?" a
    /// question the app shell can ask without knowing the shape.
    public var onClick: (@MainActor (IslandScreen, CGPoint) -> Void)?

    /// A right-click on a screen's island — the way into Isleta's own menu.
    ///
    /// Carries the event rather than a point, because `NSMenu.popUpContextMenu(_:with:for:)` wants
    /// the event it was raised by. See `IslandHitTestView.onSecondaryClick`.
    public var onSecondaryClick: (@MainActor (IslandScreen, NSEvent, NSView) -> Void)?


    /// Fires for each scroll event over a screen's island — the swipe (§5). Raw samples, because
    /// the gesture's physics belong to IslandUI and its policy to the app shell; this class only
    /// knows which screen the event landed on.
    public var onScroll: (@MainActor (IslandScreen, IslandScrollSample) -> Void)?

    /// Fires *before* the panels are put back on top, so the island can be taken off screen before
    /// the window server has a chance to composite a full-size frame of it.
    ///
    /// Fallback only: never fires while the panels are hosted in the overlay space, because they are
    /// never taken off screen for a transition there.
    public var onSpaceWillRestore: (@MainActor () -> Void)?

    /// Fires after the active space has changed and the panels have been put back on top.
    ///
    /// Separate from the re-ordering itself because they answer different questions: the controller
    /// owns *where the window sits*, and the app shell owns *what the island does about it*.
    ///
    /// Fallback only, like `onSpaceWillRestore`. The app shell's handler plays the re-entry, which
    /// the lock/unlock path also uses on its own schedule — that use is live regardless.
    public var onSpaceChanged: (@MainActor () -> Void)?

    /// The user moved to another space, whether or not the island was ever hidden for it.
    ///
    /// **Not `onSpaceChanged` above, and the difference is not cosmetic.** That one is the *end* of
    /// the transition the island was hidden for, and it fires only on the fallback path — with the
    /// panels hosted in the private overlay space (`OverlaySpace`) they are in no transition to
    /// hide from, nothing is ever hidden, and it never fires at all. This is the plain
    /// `NSWorkspace.activeSpaceDidChangeNotification`: it fires on every switch, on every machine,
    /// hosted or not, and it means only "the user is looking at a different desktop now".
    ///
    /// For the app shell to answer the question a space switch actually asks — is what the island
    /// is holding still worth the pixels over here? — see `AppDelegate.spaceChanged`.
    public var onActiveSpaceChanged: (@MainActor () -> Void)?

    // MARK: - Drag and drop (§5, Milestone 3)

    /// The types every island accepts, and the per-screen callbacks that answer for them.
    ///
    /// Held rather than applied once because panels are rebuilt whenever the display configuration
    /// changes: a display connected mid-session, or a resolution change, produces a new
    /// `IslandHitTestView`, and an island that had silently stopped accepting drops would look
    /// exactly like an island that never did. `makeAttachment` applies these to every panel it
    /// builds, so registration outlives the panel it was made for.
    private var acceptedDropTypes: [NSPasteboard.PasteboardType] = []
    private var dragHandlersForScreen: (@MainActor (IslandScreen) -> IslandDragHandlers?)?

    // MARK: - Hover tuning
    //
    // Held here rather than passed at each call for the same reason `acceptedDropTypes` is: panels
    // are rebuilt whenever the display configuration changes, and a setting that lived only in the
    // call that applied it would silently revert to the default the next time somebody plugged in a
    // monitor. Held here, `makeAttachment` re-applies it to every panel it builds.

    /// Everything the user has said about how big the island is. Feeds every region this class
    /// computes; the *drawn* shape comes from the app shell's `metricsByForm`, which must be built
    /// with the same value or the two disagree — see `IslandHitTestView` on subsets.
    ///
    /// One record rather than a property per dimension, for the reason `IslandSizing` states: a
    /// dimension that reaches the drawing and not this class is clicks landing on lit island pixels
    /// and being dropped, and four separate properties is four chances to set three of them.
    public var sizing: IslandSizing = .standard {
        didSet { guard sizing != oldValue else { return }; applyHoverTuning() }
    }

    /// How much drawable height the open island needs below the cutout, for whatever is on stage
    /// right now — or `nil` for `IslandLayout.expandedBodySize.height`.
    ///
    /// Here for the same reason `sizing` is: it feeds every region this class computes, and the
    /// drawn shape comes from the app shell's `metricsByForm`, which must be built with the same
    /// value or the clickable island is a different size from the visible one. The shell sets it
    /// *before* the transition that changes what is presented, so the widened region covers the
    /// height the island is heading for and not the one it is leaving.
    ///
    /// Unlike `sizing` it does not re-apply anything on its own. Every region it affects belongs
    /// to the expanded island, and the only way to be expanded is to have gone through
    /// `setHitRegion`/`setHoverRegion` — which the shell calls on the same change.
    public var expandedContentHeight: CGFloat?

    /// How wide the open island needs to be for whatever is on it right now — or `nil` for
    /// `IslandLayout.expandedBodySize.width`.
    ///
    /// `expandedContentHeight`'s twin, held here for its reason and set by the shell on the same
    /// schedule: before the transition, so the widened region covers the width the island is
    /// heading for and not the one it is leaving. The month grid is the one surface that asks for
    /// more than the default — see `IslandLayout.expandedWidth`, which is also why this can only
    /// ever make the island wider.
    ///
    /// It reaches the *hover* regions as well as the clickable one, and there it is not optional
    /// politeness: the open island's hover region is the blur ring around its own outline, so a
    /// region built at the default width while a wider island is drawn would read a pointer resting
    /// on real island as having left, and close it.
    public var expandedContentWidth: CGFloat?

    /// The strip the switcher row takes at the bottom of the open island, or 0 when there is no row.
    ///
    /// Held here for the same reason `expandedContentHeight` is: `widenHitRegionForTransition` asks
    /// the controller where the island is going, so the *clickable* shape and the *drawn* one have
    /// to be built from the same two numbers. A row added to the drawing and not to the hit region
    /// is 40pt of lit island that swallows clicks.
    public var pageIndicatorHeight: CGFloat = 0

    /// The user's hover delay (`IsletaConfiguration.hoverDelay`), in seconds.
    public var hoverDelay: TimeInterval = 0 {
        didSet { guard hoverDelay != oldValue else { return }; applyHoverTuning() }
    }

    // MARK: - Getting out of the way

    /// Whether every island is currently hidden because the frontmost app is one the user asked
    /// Isleta to stay out of.
    public private(set) var isSuppressed = false

    /// Takes every island off screen, or puts them back.
    ///
    /// `alphaValue` rather than `orderOut`, and for two reasons that are both written down
    /// elsewhere in this file. An ordered-out window stops posting `didChangeOcclusionState`
    /// entirely, which is what strands the fallback transition path; and the panels are hosted in a
    /// private window-server space, so ordering them out and back is a round trip through a
    /// membership this class went to some trouble to establish. A transparent window keeps
    /// reporting and keeps its space.
    ///
    /// It also does exactly what is wanted at the window server: the event shape is derived from
    /// the backing store's alpha, so an island at alpha 0 stops claiming clicks and the app the user
    /// switched to gets its whole menu bar back. The hover callbacks are gated below anyway, because
    /// a tracking area is not alpha-aware and an island that quietly opened an activity while
    /// invisible would be the app doing work nobody can see.
    public func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        for attachment in attachments.values {
            // No `mouseExited` is coming for a window that stopped taking events, exactly as at the
            // lock — see `cancelHover(forScreen:)`.
            attachment.hitTestView.cancelHover()
            attachment.panel.alphaValue = suppressed ? 0 : 1
            attachment.blurPanel.alphaValue = suppressed ? 0 : 1
        }
        // The app's name is the user's, so it is not in the line — only that the list matched.
        IslandLog.panel.info(
            suppressed
                ? "hidden — the frontmost app is on the hide list"
                : "shown — the frontmost app is not on the hide list"
        )
    }

    /// Pushes the tuning onto every live panel.
    ///
    /// The hover *region* is deliberately not recomputed here. Its size depends on whether each
    /// island is expanded and whether it is carrying flank content, and this class cannot know
    /// either without IslandKit depending on IslandActivities — the same boundary `applyRestShape`
    /// documents. The app shell knows both, and re-syncs the regions after changing `sizing`;
    /// `onScreensChanged` is the existing path that does exactly this after a rebuild.
    private func applyHoverTuning() {
        for attachment in attachments.values {
            attachment.hitTestView.hoverDelay = hoverDelay
        }
    }

    /// `overlaySpace` is injectable so the fallback can be exercised in a test or a probe without
    /// taking the private API away from the machine; nil resolves the real thing, or the fallback if
    /// the API is not there.
    /// - Parameter blurContentFactory: what to draw in the inert panel beneath each island. Its own
    ///   factory rather than a second view out of `contentFactory`, because the two go into
    ///   different windows and only one of them may ever see a click. Defaults to an empty view, so
    ///   a test or a probe that only wants islands does not have to supply one.
    public init(
        contentFactory: @escaping ContentFactory,
        blurContentFactory: @escaping ContentFactory = { _ in NSView() },
        overlaySpace: (any OverlaySpaceHost)? = nil
    ) {
        self.overlaySpace = overlaySpace ?? SkyLightOverlaySpace.make() ?? UnavailableOverlaySpace()
        self.contentFactory = contentFactory
        self.blurContentFactory = blurContentFactory
    }

    /// Makes every island a drop destination for `types`, now and after any rebuild.
    ///
    /// The handlers are built per screen so the app shell can close over which display the drag is
    /// on — the shelf itself is app-wide (there is one user holding one thing), but the island that
    /// has to open to receive it is not.
    public func acceptDrops(
        of types: [NSPasteboard.PasteboardType],
        handlers: (@MainActor (IslandScreen) -> IslandDragHandlers?)?
    ) {
        acceptedDropTypes = types
        dragHandlersForScreen = handlers
        for attachment in attachments.values {
            applyDragHandling(to: attachment.hitTestView, on: attachment.screen)
        }
    }

    private func applyDragHandling(to view: IslandHitTestView, on screen: IslandScreen) {
        let handlers = dragHandlersForScreen?(screen)
        view.dragging.handlers = handlers
        // Registering for no types un-registers, which is what makes turning the shelf off actually
        // turn it off: an island still registered would go on claiming drags from the window server
        // and refusing them, and a refused drag does not fall through to the app underneath.
        view.acceptDrops(of: handlers == nil ? [] : acceptedDropTypes)
    }

    /// Isolated so it can touch main-actor state; without it the observer token would outlive
    /// the controller and leave a dead block registered on the default center.
    isolated deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    public var screens: [IslandScreen] {
        attachments.values.map(\.screen).sorted { $0.id < $1.id }
    }

    /// Lets exactly one island take key for the length of a typing act, and hands key back after.
    ///
    /// The panel refuses key at every other moment — see `IslandPanel.acceptsKeyboardInput` for the
    /// three-probe measurement of what taking it costs and what it does not. This is the only route
    /// to that flag, so the whole of the exception is one call with one screen id in it, and there
    /// is no path that leaves *two* islands willing to take key: every other panel is put back to
    /// refusing before the named one is offered.
    ///
    /// Returns whether the panel actually took key. Measure the effect, never the request — a panel
    /// on a display that has just been unplugged is gone, and a composer that trusted this call
    /// would sit waiting for keystrokes that have nowhere to come from.
    @discardableResult
    public func setAcceptingKeyboardInput(_ accepting: Bool, forScreen id: CGDirectDisplayID?) -> Bool {
        for (displayID, attachment) in attachments where displayID != id || !accepting {
            guard attachment.panel.acceptsKeyboardInput else { continue }
            attachment.panel.acceptsKeyboardInput = false
            // Order matters: the flag has to be false *before* the resign, or AppKit is entitled to
            // hand key straight back to a window that still says it wants it.
            attachment.panel.resignKey()
        }
        guard accepting, let id, let attachment = attachments[id] else { return false }
        attachment.panel.acceptsKeyboardInput = true
        attachment.panel.makeKeyAndOrderFront(nil)
        return attachment.panel.isKeyWindow
    }

    /// The hosting view of one island, so the app shell can put the first responder inside it.
    ///
    /// Deliberately the *content* view rather than the panel: nothing outside IslandKit is given a
    /// window it could order out, resize, or make key behind this class's back.
    public func contentView(forScreen id: CGDirectDisplayID) -> NSView? {
        attachments[id]?.panel.contentView
    }

    public func start() {
        guard observation == nil else { return }
        IslandLog.panel.info(
            overlaySpace.isHosting
                ? "overlay space: private SkyLight space created — the island is in no desktop's picture"
                : "overlay space: unavailable — falling back to hiding on occlusion"
        )
        observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRebuild()
            }
        }

        // Re-assert our place in the window order when the active space changes.
        //
        // Measured on macOS 27.0, because the symptom invites the wrong fix: switching into or out
        // of a fullscreen space makes the island appear to vanish for about a second and then snap
        // back. It looks exactly like the panel being destroyed and rebuilt — but a probe standing
        // up a panel with this same level and collection behavior showed the notch geometry never
        // changes (`auxiliaryTopLeftArea` stays set, so no rebuild is triggered) and the panel never
        // stops being visible. What changes is *ownership of the pixel*: for ~1s during the
        // transition, two other windows come above ours at the notch, then ours returns by itself.
        //
        // So the panel is alive and covered, not gone, and raising `level` would be the wrong answer
        // — it would put the island over system UI permanently to fix a one-second overlap.
        // Ordering front on the space change addresses exactly the window in which it is wrong.
        //
        // `orderFrontRegardless` and not `makeKeyAndOrderFront`: §4.1 says clicking the island must
        // never deactivate the user's frontmost app, and a space switch is even less of a reason to
        // steal focus than a click is.
        spaceObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertWindowOrder()
                // After the window order, never before: the shell's handler may stow, which runs a
                // transition and rebuilds a hit region, and doing that while another app still owns
                // the pixel at the notch would tighten the region against a shape nobody can see.
                self?.onActiveSpaceChanged?()
            }
        }

        rebuild()
    }

    /// Puts every panel back on top without touching key or main status.
    ///
    /// Cheap and idempotent: ordering a window that is already frontmost is a no-op in the window
    /// server, so this costs nothing on the space changes where nothing covered us.
    /// Anything that might be a space transition: hide at once, and push the settle out.
    ///
    /// Hiding is `alphaValue`, not a redraw, because the transition composites a snapshot taken the
    /// instant it begins — a repaint cannot win that race however early it is flushed, and a
    /// window-server property lands without a render pass. Idempotent: a second signal during the
    /// same transition only moves the settle.
    private func noteTransitionSignal(_ signal: TransitionSettle.Signal) {
        // Already off screen for the frontmost app, and there is nothing for a space transition to
        // photograph. Left out, the settle would fire mid-suppression and put the island back.
        guard !isSuppressed else { return }
        if !attachments.values.contains(where: { $0.panel.alphaValue < 1 }) {
            // `alphaValue` first, before anything that draws. It is the only part of this that beats
            // the snapshot — a window-server-side property, applied with no render pass — and the
            // margin is a few milliseconds. Putting `onSpaceWillRestore` and its `CATransaction`
            // flush ahead of it, which reads as the natural order, spends a synchronous render
            // commit before the one write that had to land instantly, and the island is briefly
            // painted into the picture before going transparent.
            for attachment in attachments.values {
                attachment.panel.alphaValue = 0
            }
            // Now the content, whose only job is to be reset so the re-entry has somewhere to play
            // from. Nothing here is racing the snapshot: the panel is already invisible.
            onSpaceWillRestore?()
            settleRule.begin()
            // After the writes, never before: the log line is a string format and a dispatch, and
            // the margin against the snapshot is a few milliseconds.
            IslandLog.space.info("hidden on \(signal) — fallback path")
        }

        let delay = settleRule.delay(after: signal)

        transitionSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transitionSettle = nil
                guard self.attachments.values.contains(where: { $0.panel.alphaValue < 1 }) else {
                    return
                }
                self.restoreAfterTransition()
            }
        }
        transitionSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pushes the settle out without hiding anything, for signals that prove a transition is still
    /// running but must not start one. Doing this unconditionally would hide the island every time
    /// a window stopped covering the notch.
    private func noteTransitionSignalIfHidden() {
        guard !isSuppressed else { return }
        guard attachments.values.contains(where: { $0.panel.alphaValue < 1 }) else { return }
        noteTransitionSignal(.stillRunning)
    }

    /// Puts every island back and plays it in.
    ///
    /// The order is the whole fix for the flash: hide, commit, *then* raise. Raising first is what
    /// this did originally, on the reasoning that an animation spent underneath another window is an
    /// animation nobody sees. That was wrong in a way only visible on hardware — `orderFrontRegardless`
    /// puts the panel back at full size immediately, so the window server composites one fully-drawn
    /// frame before the hide lands, and the island blinks before it bounces.
    ///
    /// `CATransaction.flush()` is not decoration. Setting the model's value only marks the view
    /// dirty; without forcing that frame out first the raise can still beat the render.
    ///
    /// Every path back on screen goes through here. When one of them only set `alphaValue`, the
    /// island returned without its re-entry: `onSpaceChanged` had already fired while the panel was
    /// transparent, so the animation ran where nobody could see it and left the content settled, and
    /// the island appeared instead of arriving.
    private func restoreAfterTransition() {
        transitionSettle?.cancel()
        transitionSettle = nil
        onSpaceWillRestore?()
        CATransaction.flush()
        for attachment in attachments.values {
            // Never over the top of the hide list: a space change while the user is in an app they
            // asked Isleta to stay out of must not be what brings the island back.
            attachment.panel.alphaValue = isSuppressed ? 0 : 1
            attachment.blurPanel.alphaValue = isSuppressed ? 0 : 1
            attachment.blurPanel.orderFrontRegardless()
            attachment.panel.orderFrontRegardless()
            attachment.panel.order(.above, relativeTo: attachment.blurPanel.windowNumber)
        }
        onSpaceChanged?()
        IslandLog.space.info("restored after the transition settled")
    }

    func reassertWindowOrder() {
        for attachment in attachments.values {
            attachment.blurPanel.orderFrontRegardless()
            attachment.panel.orderFrontRegardless()
            attachment.panel.order(.above, relativeTo: attachment.blurPanel.windowNumber)
        }
        // Hosted panels were never in the transition; there is nothing to close.
        guard !overlaySpace.isHosting else { return }

        // Fallback only. A space change may *close* a hide but never start one: without the private
        // space the picture is already taken by the time this arrives, so hiding here paints the
        // island through the slide and then blips it out and back — two artifacts where there was
        // one. Fullscreen transitions lead with the occlusion drop and are handled there.
        guard attachments.values.contains(where: { $0.panel.alphaValue < 1 }) else { return }
        noteTransitionSignal(.spaceChange)
    }

    public func stop() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        transitionSettle?.cancel()
        transitionSettle = nil
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        if let spaceObservation {
            // Removed from the center that issued it — see the property's own note.
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObservation)
            self.spaceObservation = nil
        }
        for token in occlusionObservations {
            NotificationCenter.default.removeObserver(token)
        }
        occlusionObservations.removeAll()
        for attachment in attachments.values {
            overlaySpace.release(attachment.panel)
            overlaySpace.release(attachment.blurPanel)
            attachment.panel.orderOut(nil)
            attachment.panel.close()
            attachment.blurPanel.orderOut(nil)
            attachment.blurPanel.close()
        }
        attachments.removeAll()
        // Synchronous through to the window server, on purpose: this runs from
        // `applicationWillTerminate`, which returns into `exit()`, and the space lives in the window
        // server rather than in this process — see `OverlaySpace`.
        overlaySpace.tearDown()
    }

    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        IslandLog.panel.debug("display parameters changed — rebuild in 200 ms")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reconciles live panels against the current display configuration.
    public func rebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = nil

        let current = IslandPlacement.displays(from: Self.currentScreens())
        let currentIDs = Set(current.map(\.id))

        for (id, attachment) in attachments where !currentIDs.contains(id) {
            overlaySpace.release(attachment.panel)
            overlaySpace.release(attachment.blurPanel)
            attachment.panel.orderOut(nil)
            attachment.panel.close()
            attachment.blurPanel.orderOut(nil)
            attachment.blurPanel.close()
            attachments[id] = nil
            IslandLog.panel.info("display \(id) gone — island removed")
        }

        for screen in current {
            if var existing = attachments[screen.id] {
                guard existing.screen != screen else { continue }
                // Geometry moved under us — reposition rather than rebuild, so the panel keeps its
                // content and its window number.
                existing.screen = screen
                attachments[screen.id] = existing
                let frame = IslandLayout.panelFrame(for: screen)
                existing.panel.setFrame(frame, display: true)
                existing.blurPanel.setFrame(frame, display: true)
                applyRestShape(to: existing)
                IslandLog.panel.info("display \(screen.id) moved — panel now \(frame.logDescription)")
            } else {
                attachments[screen.id] = makeAttachment(for: screen)
                let notch = "\(screen.notch.kind) notch \(screen.notch.rect.logDescription)"
                let geometry = "screen \(screen.frame.logDescription) @\(screen.backingScaleFactor)x"
                let panel = "panel \(IslandLayout.panelFrame(for: screen).logDescription)"
                IslandLog.panel.info("display \(screen.id) \"\(screen.name)\" — \(notch), \(geometry), \(panel)")
            }
        }

        onScreensChanged?(screens)
    }

    private func makeAttachment(for screen: IslandScreen) -> Attachment {
        let frame = IslandLayout.panelFrame(for: screen)
        let panel = IslandPanel(contentRect: frame)

        // The same frame as the island's panel, so the blur's view can lay itself out against the
        // identical rectangle and `IslandLayout.bodyOrigin` puts the two shapes in the same place
        // without either of them knowing about the other. Its *content* is built further down, after
        // the island's — see there.
        let blurPanel = IslandBlurPanel(contentRect: frame)

        let hitTestView = IslandHitTestView(frame: CGRect(origin: .zero, size: frame.size))
        hitTestView.autoresizingMask = [.width, .height]

        // A new panel starts at rest with nothing on stage. If something *is* on stage — a display
        // connected while Now Playing is up — the app shell corrects both regions from
        // `onScreensChanged`, which fires after every attachment in this rebuild exists.
        hitTestView.hoverDelay = hoverDelay
        hitTestView.hoverRegion = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .none, on: screen, in: frame.size, sizing: sizing
        )
        // Each of the three is gated on `isSuppressed`. A tracking area is not alpha-aware, so a
        // hidden island would go on noticing the pointer and opening activities where nobody can see
        // them — and the pointer is *often* up there, because the hide list exists for apps the user
        // is looking at full screen.
        hitTestView.onPointerMoved = { [weak self] point in
            guard let self, !self.isSuppressed, let attachment = self.attachments[screen.id] else { return }
            self.onPointerMoved?(attachment.screen, point)
        }
        hitTestView.onHoverChanged = { [weak self] hovering in
            guard let self, !self.isSuppressed, let attachment = self.attachments[screen.id] else { return }
            self.onHoverChanged?(attachment.screen, hovering)
        }
        hitTestView.onClick = { [weak self] point in
            guard let self, !self.isSuppressed, let attachment = self.attachments[screen.id] else { return }
            self.onClick?(attachment.screen, point)
        }
        hitTestView.onScroll = { [weak self] sample in
            guard let self, !self.isSuppressed, let attachment = self.attachments[screen.id] else { return }
            self.onScroll?(attachment.screen, sample)
        }
        hitTestView.onSecondaryClick = { [weak self, weak hitTestView] event in
            guard let self, !self.isSuppressed, let attachment = self.attachments[screen.id],
                  let hitTestView
            else { return }
            self.onSecondaryClick?(attachment.screen, event, hitTestView)
        }

        // Registration has to survive panel rebuilds — see `acceptDrops(of:handlers:)`.
        applyDragHandling(to: hitTestView, on: screen)

        let content = contentFactory(screen)
        content.frame = hitTestView.bounds
        content.autoresizingMask = [.width, .height]
        hitTestView.addSubview(content)

        // **After the island's content, never before**, and the ordering is load-bearing rather than
        // tidy. Both views are built from the app shell's per-screen model, and it is
        // `contentFactory` that *creates* that model — so a blur built first finds nothing to read,
        // returns an empty view, and the island draws with no blur behind it for the life of that
        // panel. It fails silently, because an absent blur looks exactly like a closed island's.
        let blurContent = blurContentFactory(screen)
        blurContent.frame = CGRect(origin: .zero, size: frame.size)
        blurContent.autoresizingMask = [.width, .height]
        blurPanel.contentView = blurContent

        panel.contentView = hitTestView
        panel.setFrame(frame, display: false)

        // Fallback only: a hosted panel is in no space's picture and is never occluded by a
        // transition, so there is nothing for this observer to do and it is not registered.
        if !overlaySpace.isHosting {
            // Hide the island the moment the window server stops showing this panel, and bounce it back
            // when it starts again. Registered per window, because `didChangeOcclusionState` is posted
            // by the window rather than by the workspace.
            let occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: panel,
                queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel else { return }
                    if panel.occlusionState.contains(.visible) {
                        // Restores nothing — but it is evidence the transition is still running, so it
                        // keeps the settle alive. It is not the end of anything: measured in isolation it arrives in
                        // the middle of a slide with the animation still running, and both spaces are
                        // photographed — becoming opaque here puts the island into the *incoming*
                        // space's picture, so it slides in welded to the arriving window, adrift from
                        // the notch. Playing the re-entry here was just as wrong in the other direction:
                        // the animation ran while the panel was transparent, where nobody could see it,
                        // and left the content settled so the island later appeared instead of arriving.
                        // The settle owns coming back.
                        self.noteTransitionSignalIfHidden()
                    } else {
                        // The transition has begun. Hiding is `alphaValue` and not a redraw because the
                        // transition composites a *snapshot* taken at this instant — the picture the
                        // user watches slide past was captured before any frame of ours could exist, so
                        // no amount of flushing wins that race, while a window-server-side property
                        // lands with no render pass at all.
                        //
                        // **Not `orderOut`, which also hides it and then never brings it back.** An
                        // ordered-out window stops posting `didChangeOcclusionState` altogether: the
                        // panel went off screen on the first transition and stayed off through ten more
                        // space changes, waiting for the notification that no longer arrives. A
                        // transparent window keeps reporting.
                        self.noteTransitionSignal(.occlusionDrop)
                    }
                }
            }
            occlusionObservations.append(occlusion)
        }

        // The blur first, then the island above it — `order(.above:)` rather than two
        // `orderFrontRegardless` calls in sequence, which race with anything else ordering windows
        // in the same pass and would let the blur land over its own island.
        blurPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: blurPanel.windowNumber)
        // A display connected while the user is in an app on the hide list arrives hidden, rather
        // than flashing an island onto the screen they just plugged in.
        if isSuppressed {
            panel.alphaValue = 0
            blurPanel.alphaValue = 0
        }
        // After ordering front, so the window number is live. See `OverlaySpace` for why a window
        // here stays pinned through every space slide. The blur joins too: a blur left behind in the
        // desktop's picture while the island was pinned would slide away from under it.
        overlaySpace.host(panel)
        overlaySpace.host(blurPanel)

        var attachment = Attachment(
            panel: panel,
            blurPanel: blurPanel,
            hitTestView: hitTestView,
            screen: screen,
            hitRegionMetrics: IslandLayout.restMetrics(for: screen)
        )
        Self.applyHitRegion(IslandLayout.restMetrics(for: screen), to: &attachment)
        return attachment
    }

    /// Tightens a screen's hit region to exactly the given metrics. Call once the island has
    /// settled, never mid-transition.
    public func setHitRegion(to metrics: IslandShapeMetrics, forScreen id: CGDirectDisplayID) {
        guard var attachment = attachments[id] else { return }
        Self.applyHitRegion(metrics, to: &attachment)
        attachments[id] = attachment
    }

    /// Sets the hit region on an attachment directly.
    ///
    /// Takes the attachment rather than a display id because `makeAttachment` has to call it before
    /// the attachment is in `attachments` — going through the id-based path there silently did
    /// nothing, leaving `islandPath` nil and every click on the island falling on the floor. The
    /// window server still routed those clicks to us, because the island's pixels are opaque; our
    /// own `hitTest` then rejected them, so they neither opened the island nor reached the app
    /// underneath. `PassThroughSelfTest` cannot see this — it asks the window server, which was
    /// behaving correctly throughout. `ClickSelfTest` is what caught it.
    private static func applyHitRegion(_ metrics: IslandShapeMetrics, to attachment: inout Attachment) {
        let size = attachment.panel.frame.size
        let origin = IslandLayout.bodyOrigin(for: metrics, in: size)
        attachment.hitTestView.islandPath = IslandShapeGeometry.path(metrics: metrics, bodyOrigin: origin)
        attachment.hitRegionMetrics = metrics
    }

    /// Tracks the pointer over the largest state reachable without another click.
    /// Sets both halves of the hover hysteresis for one screen.
    ///
    /// `hoverRegion` is where the pointer must *leave* — the island's largest reachable state, so
    /// growing on peek cannot hand the island its own `mouseExited`. `hoverEnterRegion` is where it
    /// must *arrive* — the resting shape, so the island does not react to a pointer that is merely
    /// near it. See `IslandHitTestView.hoverEnterRegion` for why one region cannot be both.
    public func setHoverRegion(isExpanded: Bool, flanks: IslandFlanks, forScreen id: CGDirectDisplayID) {
        guard var attachment = attachments[id] else { return }
        // The band, recorded as it is set, so `isPointInBlur` and the region the pointer is tracked
        // against are the same arithmetic rather than two copies of it.
        attachment.blurRegion = IslandLayout.blurRegion(
            isExpanded: isExpanded, on: attachment.screen,
            in: attachment.panel.frame.size, sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
        attachments[id] = attachment
        attachment.hitTestView.hoverRegion = IslandLayout.hoverRegion(
            isExpanded: isExpanded, flanks: flanks, on: attachment.screen,
            in: attachment.panel.frame.size, sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
        attachment.hitTestView.hoverEnterRegion = IslandLayout.hoverEnterRegion(
            isExpanded: isExpanded, flanks: flanks, on: attachment.screen,
            in: attachment.panel.frame.size, sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
    }

    /// Whether a point in **global screen** coordinates is inside one island's blur.
    ///
    /// The blur takes no clicks of its own — it is drawn in `IslandBlurPanel`, which ignores mouse
    /// events entirely, so a click there lands on whatever is behind Isleta. This is what the app
    /// shell's outside-click monitor asks before treating that click as "not this": the band is the
    /// island's grace region, and a click passing through it is aimed at the app underneath rather
    /// than at dismissing the island.
    ///
    /// Answered from the *live* hover region rather than recomputed, so it cannot disagree with the
    /// region the pointer is actually being tracked against.
    public func isPointInBlur(_ screenPoint: CGPoint, forScreen id: CGDirectDisplayID) -> Bool {
        guard let attachment = attachments[id] else { return false }
        // Empty unless the island is open, which is the whole guard: `hoverRegion` would have been
        // the tempting thing to test and it is wrong, because on a *closed* island that region is
        // the peek — so a click beside a resting island on a second display would be spared as
        // though it had landed in a band that is not drawn anywhere.
        guard !attachment.blurRegion.isEmpty else { return false }
        let inWindow = attachment.panel.convertPoint(fromScreen: screenPoint)
        return attachment.blurRegion.contains(attachment.hitTestView.convert(inWindow, from: nil))
    }

    /// Widens a screen's hit region to cover every state a transition can pass through.
    ///
    /// A superset is safe and a subset is not — see `IslandHitTestView`. The region is
    /// `IslandShapeMetrics.union` of where the island is and where it is going, which contains both
    /// endpoints and every intermediate `IslandShapeMetrics.lerp` produces between them; the
    /// argument is written out on `union` itself. `PeekTests` pins it down by sampling.
    ///
    /// This used to be "whichever endpoint is taller", justified by the island's corners curving
    /// inward so that each state is inset from the next on all four sides. That justification still
    /// holds for the corners, but it stopped being enough once the island gained a flanked resting
    /// size: flanked rest is 265x32 and unflanked peek is 197x40, so neither contains the other and
    /// the taller endpoint — peek — is a subset across 68pt of lit island. Dismissing an activity
    /// while the pointer sat on a flank would have dropped the click on the floor.
    public func widenHitRegionForTransition(
        to form: IslandForm,
        forScreen id: CGDirectDisplayID
    ) {
        guard let attachment = attachments[id] else { return }
        let current = attachment.hitRegionMetrics
        let target = IslandLayout.metrics(
            for: form,
            on: attachment.screen,
            sizing: sizing,
            expandedContentHeight: expandedContentHeight,
            expandedContentWidth: expandedContentWidth,
            pageIndicatorHeight: pageIndicatorHeight
        )
        setHitRegion(to: IslandShapeMetrics.union(current, target), forScreen: id)
    }

    /// Widens one screen's hit region to also contain `metrics`.
    ///
    /// The same widen as above with the target handed in rather than derived from a form, for the
    /// one caller that knows a shape this class cannot compute: a page being dragged toward is a
    /// *different page's* height, and `expandedContentHeight` here is still the page being left.
    ///
    /// Unions rather than replaces, like everything on this path, so repeated calls during one
    /// gesture accumulate and a reversal under the finger cannot narrow the region against a shape
    /// the island is still partly drawn at.
    public func widenHitRegion(toContain metrics: IslandShapeMetrics, forScreen id: CGDirectDisplayID) {
        guard let attachment = attachments[id] else { return }
        setHitRegion(
            to: IslandShapeMetrics.union(attachment.hitRegionMetrics, metrics),
            forScreen: id
        )
    }

    /// Drops a live hover on one screen without waiting for a `mouseExited` that is not coming.
    ///
    /// For the screen going away underneath a live hover — locking, or the displays sleeping. The
    /// window server's shield takes the pointer's events with it, so the tracking rect's crossing is
    /// never reported and `IslandHitTestView`'s watchdog, which only runs while hovered, keeps
    /// answering with a pointer position frozen where it was.
    public func cancelHover(forScreen id: CGDirectDisplayID) {
        attachments[id]?.hitTestView.cancelHover()
    }

    /// Asks one screen where the pointer actually is and reports the answer through `onHoverChanged`.
    ///
    /// The other half of `cancelHover(forScreen:)`, for the unlock. See
    /// `IslandHitTestView.refreshHover()` for why a position has to be asked for rather than waited
    /// on.
    public func refreshHover(forScreen id: CGDirectDisplayID) {
        attachments[id]?.hitTestView.refreshHover()
    }

    /// Whether the pointer is on one screen's island **right now**, or nil where there is no such
    /// screen.
    ///
    /// Asked rather than remembered, and that is the point of it. The app shell keeps its own set of
    /// hovered screens from the `onHoverChanged` edges, and an edge can be about the tracking rect
    /// having been rebuilt rather than about the pointer having moved — see
    /// `AppDelegate.pointerExitChanged`, which uses this to tell one from the other before closing
    /// an island behind a pointer that never left it.
    public func isHovering(forScreen id: CGDirectDisplayID) -> Bool? {
        attachments[id]?.hitTestView.isHovering
    }

    /// The panel's content size on one screen — the space `onPointerMoved`'s points, `islandPath`
    /// and every `IslandLayout` region are all expressed in.
    ///
    /// Exposed rather than recomputed by the caller, for `IslandSizing`'s reason one level up: a
    /// second copy of "how big is the panel" is a second chance to answer it differently from the
    /// one the pointer was measured against.
    public func panelContentSize(forScreen id: CGDirectDisplayID) -> CGSize? {
        attachments[id]?.panel.frame.size
    }

    /// Whether the pointer is inside one screen's hover region **right now** — the peek while the
    /// island is closed, the blur while it is open.
    ///
    /// A position rather than a crossing, and that is the point of it. On an open island the band
    /// the pointer may rest in is drawn in `IslandBlurPanel`, so the island's own panel stops
    /// receiving mouse events out there and AppKit reports an exit that did not happen. See
    /// `IslandHitTestView.mouseExited`.
    public func isPointerInsideHoverRegion(forScreen id: CGDirectDisplayID) -> Bool? {
        attachments[id]?.hitTestView.pointerIsInsideHoverRegion
    }

    /// Resets a repositioned panel to the unflanked resting shape, canceling any live hover.
    ///
    /// Unflanked because this class knows nothing about what is on stage — that lives in
    /// IslandActivities, which IslandKit must not depend on. `rebuild()` calls `onScreensChanged`
    /// immediately afterwards and the app shell restores the flanked regions from its models there,
    /// which is the only place both facts are known at once.
    private func applyRestShape(to attachment: Attachment) {
        var attachment = attachment
        attachment.hitTestView.cancelHover()
        // Back at rest means no band, and a stale one here would spare clicks around an island that
        // is not drawing anything.
        attachment.blurRegion = .zero
        attachment.hitTestView.hoverRegion = IslandLayout.hoverRegion(
            isExpanded: false, flanks: .none, on: attachment.screen,
            in: attachment.panel.frame.size, sizing: sizing
        )
        Self.applyHitRegion(IslandLayout.restMetrics(for: attachment.screen), to: &attachment)
        attachments[attachment.screen.id] = attachment
    }

    public func debugInfo() -> [IslandDebugInfo] {
        attachments.values
            .sorted { $0.screen.id < $1.screen.id }
            .map { attachment in
                let metrics = attachment.hitRegionMetrics
                let panelFrame = attachment.panel.frame
                let origin = IslandLayout.bodyOrigin(for: metrics, in: panelFrame.size)
                let extents = IslandShapeGeometry.resolvedExtents(for: metrics)
                let bounds = IslandShapeGeometry.path(metrics: metrics, bodyOrigin: origin).boundingBoxOfPath
                return IslandDebugInfo(
                    screen: attachment.screen,
                    panelFrame: panelFrame,
                    metrics: metrics,
                    bodyOrigin: origin,
                    shapeBounds: bounds,
                    cornerExtents: CGPoint(x: extents.top, y: extents.bottom),
                    windowNumber: attachment.panel.windowNumber,
                    trackingAreas: attachment.hitTestView.trackingAreas.map(\.rect),
                    isHovering: attachment.hitTestView.isHovering
                )
            }
    }

    /// Asks the window server which window owns a screen point, and reports whether it is ours.
    ///
    /// This is the honest version of "clicks pass through": rather than asserting that a
    /// transparent panel lets events by, it asks the same subsystem that routes the click.
    public func windowNumberAtScreenPoint(_ point: CGPoint) -> Int {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    }

    public func ownsWindowNumber(_ number: Int) -> Bool {
        attachments.values.contains { $0.panel.windowNumber == number }
    }

    static func currentScreens() -> [IslandScreen] {
        NSScreen.screens.compactMap { screen in
            // `NSScreen.CGDirectDisplayID` is new in macOS 26 but is NS_REFINED_FOR_SWIFT and not
            // surfaced under an obvious Swift name in this SDK; the device description key is the
            // long-standing route and returns the same value.
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let notch = NotchResolver.resolve(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                auxiliaryTopRight: screen.auxiliaryTopRightArea
            )
            return IslandScreen(
                id: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                notch: notch
            )
        }
    }
}

extension CGRect {
    /// `x,y w×h` in whole points, for a log line. Geometry in this app is pixel-snapped, so the
    /// fraction is noise; the space a rect is in is the caller's to say.
    var logDescription: String {
        "\(Int(origin.x.rounded())),\(Int(origin.y.rounded())) \(Int(width.rounded()))×\(Int(height.rounded()))"
    }
}
