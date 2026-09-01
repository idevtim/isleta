import AppKit

/// The panel's content view. Owns hit testing and hover tracking for one island.
///
/// The panel is a fixed rectangle far larger than the visible island, so without this the island
/// would swallow clicks across a 603x200pt region of the user's screen.
///
/// ## Two layers decide where a click lands
///
/// The **window server** routes a click by the alpha of our backing store: transparent pixels go to
/// the app underneath and never reach us at all. That is the authority, it is exact, and it tracks
/// the rendered frame with no help from us. **`hitTest`** then decides where the click goes *inside*
/// our view tree.
///
/// This makes the safe direction to err obvious. If `islandPath` is a **superset** of what is
/// rendered, the extra area is unreachable anyway — the window server already sent those clicks
/// elsewhere. If it is a **subset**, clicks land on opaque island pixels, reach us, and then get
/// dropped on the floor: they neither activate Isleta nor fall through. So during a transition the
/// path is set to the largest state the island can be in, and tightened to the exact shape once it
/// settles.
@MainActor
public final class IslandHitTestView: NSView {

    /// The island outline in this view's own (flipped, y-down) coordinate space.
    /// Nil means "nothing is on screen": every point misses.
    public var islandPath: CGPath?

    /// Region watched for the pointer **leaving**. Covers the island's largest state so the island
    /// growing under the pointer cannot itself trigger an exit.
    ///
    /// This is the tracking area's rect, and it is deliberately generous. What it is *not* any more
    /// is the test for arriving — see `hoverEnterRegion`.
    public var hoverRegion: CGRect = .zero {
        didSet {
            guard hoverRegion != oldValue else { return }
            rebuildTrackingArea()
        }
    }

    /// Region the pointer must actually be inside for hover to **begin**.
    ///
    /// The island's resting shape, where `hoverRegion` is its peeked one. Two regions rather than
    /// one, because a single region cannot be both things at once and the version that used only
    /// `hoverRegion` was reported from hardware as "I can hover close to the island and it acts like
    /// my mouse is on it directly" — 6pt of slop each side and 8pt below, on a 32pt island.
    ///
    /// Shrinking the one region instead is the fix that looks obvious and reintroduces a known bug,
    /// which `IslandLayout.hoverRegion` still records: an island sized to its resting shape grows
    /// out from under its own tracking rect on peek, hands itself a `mouseExited`, shrinks, and
    /// oscillates under a stationary pointer. **Hysteresis is what makes both true at once** — tight
    /// to arrive, generous to leave — and it is the same asymmetry `hoverDelay` already applies in
    /// time rather than in space.
    ///
    /// Empty means "same as `hoverRegion`", which is the behavior every caller had before this
    /// existed and what the open island still wants: it is not growing, so it needs no slack.
    public var hoverEnterRegion: CGRect = .zero

    /// Where the pointer is inside `hoverRegion`, or nil once it has gone.
    ///
    /// **A position, not a crossing, and that distinction is the whole reason this exists.** A
    /// nested `NSTrackingArea` over one part of the island — the album cover, say — is only told
    /// about *crossings of its own rect*, and the pointer arriving on the island somewhere else and
    /// then sliding sideways onto that part produces no crossing this window reliably delivers. The
    /// symptom is precise and was reported that way: approaching the cover from outside the island
    /// works and sliding to it from the middle of the notch does nothing.
    ///
    /// It is the same lesson `mouseMoved` above records for this view's own hysteresis, applied one
    /// level down: the crossing already happened at the outer edge, so everything inside the island
    /// has to be answered from where the pointer *is*. One rect-contains test per move event, on a
    /// stream that only flows while the pointer is on the island (§9).
    public var onPointerMoved: ((CGPoint?) -> Void)?

    /// Called on the main actor when the pointer enters or leaves `hoverRegion`.
    public var onHoverChanged: ((Bool) -> Void)?

    /// How long the pointer must stay inside `hoverRegion` before the island peeks
    /// (`IsletaConfiguration.hoverDelay`). Zero — the default — peeks on the crossing itself.
    ///
    /// The delay gates *entering* hover only. Leaving is always immediate: a user who has moved the
    /// pointer away has already decided, and holding a peek open for another 300ms to be symmetrical
    /// would read as the island being slow to let go. That asymmetry is deliberate everywhere in
    /// this app — `Motion.collapse` is snappier than `Motion.expand` for the same reason.
    public var hoverDelay: TimeInterval = 0 {
        didSet {
            // A delay shortened while one is already pending must not leave the old, longer one
            // running: the user drags the slider watching for the island to answer sooner, and it
            // would answer at the previous delay exactly once, which reads as the setting not
            // working. Re-arming from the *original* entry instant rather than from now is what
            // makes "shorten it below the time already elapsed" fire immediately, as it should.
            guard hoverDelay != oldValue, let pendingEntry else { return }
            armHoverDelay(from: pendingEntry)
        }
    }

    /// Called when the island itself is clicked, with **where** it was clicked: the point in the
    /// island's own space, origin at the island's top-left, y down.
    ///
    /// The island's rectangle is `islandPath`'s bounding box, so the offset is subtracted here
    /// rather than recomputed by a caller that would have to know the shape to do it. A click on an
    /// island whose path has gone (nothing on screen) cannot reach this — `hitTest` has already
    /// rejected everything else.
    public var onClick: ((CGPoint) -> Void)?

    /// Called for each scroll event over the island — the swipe (§5). Same gate as `onClick`:
    /// `hitTest` has already rejected everything outside `islandPath`.
    public var onScroll: ((IslandScrollSample) -> Void)?

    /// A right-click on the island — the way into Settings, and anything else Isleta itself offers.
    ///
    /// Same gate as `onClick`: `hitTest` has already established the point is on the island, so
    /// there is nothing left to decide. The event is handed over whole rather than as a point,
    /// because `NSMenu.popUpContextMenu(_:with:for:)` wants the event it was raised by.
    public var onSecondaryClick: ((NSEvent) -> Void)?

    public private(set) var isHovering = false

    /// Drop and drag-out state for the shelf (§5, Milestone 3).
    ///
    /// One stored property carrying all of it, and it is here only because a class cannot gain
    /// stored properties in an extension. Every line of behavior — the `NSDraggingDestination`
    /// overrides, the `NSDraggingSource` conformance, and the enter/exit latch — is in
    /// `IslandDragAndDrop.swift`, so clicks and drags stay separable in this file.
    public var dragging = IslandDragging()

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverWatchdog: Timer?

    /// The one-shot timer counting down `hoverDelay`, and the instant the pointer arrived.
    ///
    /// Both nil whenever the pointer is outside the region, which is the §9 claim: the idle path
    /// holds no timer, a delay of zero creates none at all, and the only timer a hover can create
    /// lives for at most `hoverDelayRange.upperBound` — half a second.
    private var hoverDelayTimer: Timer?
    private var pendingEntry: Date?

    static let isVerbose = ProcessInfo.processInfo.arguments.contains("--probe-verbose")

    /// y-down, so the view agrees with SwiftUI and with `IslandShapeGeometry`.
    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space; for a window's content view the
        // superview may be nil, in which case `convert(_:from:)` reads it as window coordinates.
        // Passing `superview` directly is correct in both cases.
        let local = convert(point, from: superview)
        guard let islandPath, islandPath.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Respond on the first click without the panel's app having to become active.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Handled here rather than left to a SwiftUI gesture.
    ///
    /// The panel never becomes key (§4.1), so routing clicks through SwiftUI's gesture system —
    /// which expects a key window and a first responder — is asking for trouble that only shows up
    /// as "the first click sometimes does nothing". `hitTest` has already established that this
    /// point is on the island, so there is nothing left to decide.
    ///
    /// Deliberately not calling `super`: the default implementation passes the event up the
    /// responder chain, which for a non-key panel can end at `NSApp` and provoke activation.
    public override func mouseDown(with event: NSEvent) {
        // A press that starts a drag out of the shelf, or lands on one of its controls, is not a
        // click on the island and must not open it. See `beginDragOut(with:)`.
        if beginDragOut(with: event) { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = islandPath?.boundingBox.origin ?? .zero
        onClick?(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    // MARK: - Swipe

    /// The trackpad swipe that cycles activities (§5).
    ///
    /// **`scrollWheel:` is the event that reaches us, and a `DragGesture` is not.** Two independent
    /// reasons, both structural rather than a matter of taste:
    ///
    /// - A scroll event is routed by *location*, not by focus. AppKit's own header says it: "All
    ///   the gesture events are sent to the view under the cursor when the `NSEventPhaseBegan`
    ///   occurred." That is the whole of why this works on a panel that returns false from
    ///   `canBecomeKey` — key status decides where *keyboard* events go, and a swipe is not one.
    /// - SwiftUI would never see a drag anyway. `mouseDown` below deliberately does not call
    ///   `super`, so nothing reaches `NSHostingView`'s gesture recognizers to start one; and a
    ///   `DragGesture` on a trackpad means click-and-drag, which is a different gesture from the
    ///   two-finger swipe a user expects on an island.
    ///
    /// `NSEvent.trackSwipeEvent(options:...)` is the other AppKit route, and it would hand us
    /// rubber-banding and momentum for free. It is not used because it is gated on the user's
    /// "swipe between pages" trackpad preference (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`)
    /// — a user who has that off would find the island simply did not respond, with nothing on
    /// screen to explain why. `SwipeTracker` does the physics instead and works either way.
    ///
    /// Deliberately not calling `super`, for the same reason `mouseDown` does not: the default
    /// implementation walks the responder chain, which for a non-key panel can reach `NSApp`.
    public override func scrollWheel(with event: NSEvent) {
        guard let sample = IslandScrollSample(event) else { return }
        onScroll?(sample)
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard !hoverRegion.isEmpty else { return }

        // `.activeAlways` because Isleta is an agent app that is never frontmost — without it the
        // island would only respond to hover while some other window of ours had focus, which never
        // happens.
        //
        // **`.mouseMoved` is now present**, and the note that used to sit here explaining its
        // absence has been overtaken: hysteresis needs it. `mouseEntered` fires once, at the edge of
        // the *outer* region, and a pointer that then travels inward to the island itself generates
        // no second crossing — so without move events the inner test could only ever be evaluated at
        // the moment it is guaranteed to be false.
        //
        // The §9 cost is bounded by the rect, which is the reason this is affordable: an
        // `NSTrackingArea`'s move events are delivered **only while the pointer is inside it**, and
        // this one is the peeked island — roughly 277x40 at the top of one display. A pointer
        // crossing the notch produces a short burst; a pointer anywhere else produces nothing at
        // all, which is what the idle budget actually measures.
        let area = NSTrackingArea(
            rect: hoverRegion,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if Self.isVerbose { NSLog("[tracking] mouseEntered") }
        reportPointer(from: event)
        evaluateHoverEntry()
    }

    /// Move events inside the outer region. The pointer crossing *into* the island is a move rather
    /// than a crossing, because the crossing already happened at the outer edge.
    public override func mouseMoved(with event: NSEvent) {
        reportPointer(from: event)
        evaluateHoverEntry()
    }

    /// The pointer's position in this view's space, for anything inside the island that has to know
    /// *where* on it the pointer is. See `onPointerMoved`.
    private func reportPointer(from event: NSEvent) {
        guard onPointerMoved != nil else { return }
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    /// Promotes to hovering once the pointer is genuinely on the island.
    ///
    /// Only ever promotes. Leaving is `mouseExited`'s job and is tested against the *outer* region,
    /// which is the whole of the hysteresis: an island that has peeked does not un-peek because the
    /// pointer is no longer within its smaller resting shape.
    private func evaluateHoverEntry() {
        guard !isHovering else { return }
        // With no entry region configured there is nothing extra to test: `mouseEntered` has
        // already proved the pointer is inside the tracking rect, and that was the whole test
        // before hysteresis existed. Keeping that path literally unchanged is what lets a caller —
        // or a test — opt out by simply not setting one.
        if !hoverEnterRegion.isEmpty, !pointerIsInsideEnterRegion {
            // Inside the outer region but not yet on the island. A delay armed on the way in is
            // canceled, so a pointer that pauses in the slop and leaves never peeks.
            cancelPendingHover()
            return
        }
        guard hoverDelay > 0 else {
            setHovering(true)
            return
        }
        guard pendingEntry == nil else { return }
        let entry = Date()
        pendingEntry = entry
        armHoverDelay(from: entry)
    }

    /// The pointer left the tracking rect — **or the tracking rect stopped hearing about it.**
    ///
    /// The event is a hint and the pointer's position is the truth, so this asks before it acts. Two
    /// things make the hint unreliable, and the second is new:
    ///
    /// - The rect is rebuilt whenever the island changes size, and a rect rebuilt under a stationary
    ///   pointer reports an exit and a fresh entry.
    /// - **The open island's `hoverRegion` is its blur, and the blur is not in this window.** It is
    ///   drawn in `IslandBlurPanel` so that clicks in it reach the app underneath, which means this
    ///   panel is fully transparent out there and the window server stops sending it mouse events
    ///   the moment the pointer crosses the island's own edge. AppKit reads that as leaving. It is
    ///   not: the band is exactly where the pointer is allowed to rest without the island closing.
    ///
    /// Genuine departures are not lost by ignoring the hint, because `startHoverWatchdog` is already
    /// asking the same question every 100ms for the same reason — this only declines to act *early*
    /// on an answer the watchdog would contradict.
    public override func mouseExited(with event: NSEvent) {
        if Self.isVerbose { NSLog("[tracking] mouseExited inside=\(pointerIsInsideHoverRegion)") }
        guard !pointerIsInsideHoverRegion else { return }
        cancelPendingHover()
        setHovering(false)
    }

    /// Schedules the peek for `hoverDelay` after `entry`, replacing any timer already counting.
    ///
    /// Measured from the entry instant rather than from now so that re-arming — which the `didSet`
    /// above does whenever the setting changes mid-hover — cannot extend a delay the pointer has
    /// already served most of. A deadline already in the past fires on the next run-loop pass,
    /// which `Timer` does for an interval of zero.
    private func armHoverDelay(from entry: Date) {
        hoverDelayTimer?.invalidate()
        let remaining = max(0, hoverDelay - Date().timeIntervalSince(entry))
        hoverDelayTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverDelayTimer = nil
                self.pendingEntry = nil
                // The same trap `startHoverWatchdog` exists for, and the delay is the window in
                // which it is most likely: a pointer that leaves across the panel's transparent
                // pixels stops generating events for this window, so the `mouseExited` that would
                // have canceled this timer may never arrive. Firing regardless would peek an island
                // the pointer left 300ms ago, and — with no pointer in the region to leave it — the
                // watchdog would take another 100ms to notice and put it back. Asking where the
                // pointer actually is costs one call and closes it.
                //
                // Against the **entry** region, not the outer one: the delay is part of arriving,
                // and a pointer that armed it on the island and then drifted out into the slop has
                // not arrived. Checking the outer region here would let the slop peek the island
                // after all, one `hoverDelay` late — the exact behavior hysteresis is removing.
                guard self.pointerIsInsideEnterRegion else { return }
                self.setHovering(true)
            }
        }
    }

    private func cancelPendingHover() {
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        pendingEntry = nil
    }

    /// Where the pointer actually is, against `hoverRegion`. False when there is no window, which
    /// is a panel that has been torn down mid-hover.
    /// Whether the pointer is inside the region it must leave to stop counting as hovering —
    /// the peek while the island is closed, the **blur** while it is open.
    ///
    /// Public because closing the island behind the pointer has to be decided on a position rather
    /// than on a crossing: see `AppDelegate.pointerExitChanged`, and `mouseExited` above for why a
    /// crossing is no longer evidence of anything on an open island.
    public var pointerIsInsideHoverRegion: Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return hoverRegion.contains(local)
    }

    /// Where the pointer actually is, against the **entry** region. Falls back to `hoverRegion` when
    /// no entry region has been set, which is what every caller did before hysteresis existed.
    private var pointerIsInsideEnterRegion: Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let region = hoverEnterRegion.isEmpty ? hoverRegion : hoverEnterRegion
        return region.contains(local)
    }

    /// Whether a peek is counting down but has not landed. Read by the tests, which is the only way
    /// to tell "waiting out the delay" from "the pointer never arrived" — both report `isHovering`
    /// as false, and only one of them is about to change its mind.
    public var isAwaitingHoverDelay: Bool { pendingEntry != nil }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        hovering ? startHoverWatchdog() : stopHoverWatchdog()
        // The pointer is gone, whichever of the three routes noticed — the crossing, the watchdog,
        // or the screen being taken away. Reported here rather than from `mouseExited` alone,
        // because that event is a hint the rest of this view already refuses to trust.
        if !hovering { onPointerMoved?(nil) }
        onHoverChanged?(hovering)
    }

    /// `mouseExited` is not guaranteed to arrive.
    ///
    /// The island sits in a mostly transparent panel, and the window server routes events over
    /// transparent pixels to the application underneath. A pointer that leaves the island across
    /// that transparent area can therefore stop generating events for this window before AppKit
    /// notices it crossed the tracking rect — and the island stays peeked with nothing coming to
    /// clear it. Observed roughly one time in four while driving the pointer under test.
    ///
    /// So while — and only while — the island is hovered, the pointer's actual position is checked
    /// directly. This does not violate §9's "no polling when idle": there is no timer at rest, one
    /// exists solely for the second or so the pointer is on the island, and it does no layout work.
    private func startHoverWatchdog() {
        stopHoverWatchdog()
        hoverWatchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let window = self.window else {
                    self.setHovering(false)
                    return
                }
                let global = NSEvent.mouseLocation
                let local = self.convert(window.convertPoint(fromScreen: global), from: nil)
                if IslandHitTestView.isVerbose {
                    NSLog("[watchdog] global=\(global) local=\(local) region=\(self.hoverRegion) inside=\(self.hoverRegion.contains(local))")
                }
                if !self.pointerIsInsideHoverRegion {
                    self.setHovering(false)
                }
            }
        }
    }

    private func stopHoverWatchdog() {
        hoverWatchdog?.invalidate()
        hoverWatchdog = nil
    }

    /// Force the hover state back to false — used when the panel is rebuilt or the display
    /// configuration changes underneath a live hover, where no `mouseExited` is coming.
    public func cancelHover() {
        cancelPendingHover()
        setHovering(false)
    }

    /// Brings `isHovering` back in step with where the pointer actually is.
    ///
    /// The counterpart to `cancelHover()`, for the moment the screen becomes the user's again after
    /// a lock or a display sleep. Those are cleared with `cancelHover()` on the way in, because no
    /// `mouseExited` is coming once the shield owns the pointer's events — and clearing it is what
    /// creates the need for this: a pointer that sat in the notch for the whole lock is *still* in
    /// the notch at the unlock, and `mouseEntered` fires on a crossing, not on a position. Without
    /// asking, the island would stay unresponsive to a pointer resting on it until the user moved
    /// out of the tracking rect and back in.
    ///
    /// `hoverDelay` is deliberately not applied. It exists to keep a pointer merely passing through
    /// the notch from peeking the island; a pointer that has been sitting there across a lock has
    /// waited out any delay several times over.
    public func refreshHover() {
        cancelPendingHover()
        setHovering(pointerIsInsideHoverRegion)
    }

    /// Whether a point in *global screen* coordinates lands on the island. Used by the debug
    /// overlay's probe and by the pass-through self-test.
    public func containsScreenPoint(_ screenPoint: CGPoint) -> Bool {
        guard let islandPath, let window else { return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let local = convert(inWindow, from: nil)
        return islandPath.contains(local)
    }
}
