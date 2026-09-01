import AppKit

/// Drag and drop for the island panel: receiving a drag, and lifting something back out of it.
///
/// All of it lives here rather than in `IslandHitTestView` so the two shapes of change stay
/// separable — that file owns clicks and hover, this one owns dragging. The only lines it has in
/// there are one stored property (a class cannot gain stored properties in an extension) and one
/// line in `mouseDown`.
///
/// ## What is actually verified about dragging onto a borderless, non-activating panel
///
/// Two mechanisms decide whether a drag reaches us, and they are the *same two* that decide whether
/// a click does — which is the whole reason this is written the way it is:
///
/// 1. **The window server** picks the destination window by the window's event shape, which for a
///    non-opaque window is derived from the alpha of its backing store. This is the mechanism
///    `PassThroughSelfTest` measures for clicks, and it is why `NSWindow.ignoresMouseEvents` must
///    never be assigned (see `IslandPanel`): assigning it replaces the alpha-derived shape with the
///    whole frame, and a 603x200pt panel then swallows every click *and* every drag across the top
///    of the display.
/// 2. **AppKit** then finds the deepest view under the point that is registered for one of the
///    dragged types. `IslandHitTestView.hitTest` returns nil outside `islandPath`, so the same
///    outline that gates clicks gates drops — there is one definition of "on the island", not two.
///
/// Because of (2) the accepted region is the *animated* island outline, not the panel: it is
/// whatever `applyHitRegion` last set, which during a transition is `IslandShapeMetrics.union` of
/// the endpoints. A superset is safe here for exactly the reason it is safe for clicks — the window
/// server has already routed drags over transparent pixels somewhere else — and a subset is the
/// dangerous direction, because a drag over lit island pixels that we refuse does *not* fall
/// through to the app underneath. Once a window is the drag destination, returning
/// `NSDragOperation()` shows a "no drop" cursor; it does not hand the drag back.
///
/// ## Enter and exit are latched here, not trusted from AppKit
///
/// `draggingExited:` is documented to arrive, but the island is in a mostly transparent panel and
/// `IslandHitTestView` already carries a watchdog for the equivalent `mouseExited` that is *not*
/// guaranteed. Rather than add a second timer, `draggingUpdated:` re-asks `islandPath` on every
/// update and synthesises the edges itself: the pointer crossing off the drawn island collapses the
/// island even if no exit message ever comes. That cannot oscillate, because the two directions are
/// monotone — entering grows the island *under* the pointer (still inside), leaving shrinks it
/// *away* from the pointer (still outside).
///
/// `wantsPeriodicDraggingUpdates` returns false: nothing here depends on being told the pointer has
/// not moved, and §9's "no polling" applies during a drag as much as at rest.
extension IslandHitTestView {

    // MARK: - Destination

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragEdge(with: sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragEdge(with: sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endDrag()
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        endDrag()
    }

    public override func wantsPeriodicDraggingUpdates() -> Bool { false }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let handlers = dragging.handlers else { return false }
        // The latch is cleared *before* the drop, not after: accepting is the end of the drag as
        // far as this view is concerned, and `draggingEnded:` arriving afterwards must not then
        // report an exit and collapse the island the user just dropped into.
        dragging.isInside = false
        return handlers.drop(sender.draggingPasteboard)
    }

    /// Whether the point a drag is at lands on the island as it is currently drawn, and the
    /// operation that follows from it.
    ///
    /// The one place enter and exit are decided, so both messages and every update agree about
    /// where the boundary is.
    private func updateDragEdge(with sender: any NSDraggingInfo) -> NSDragOperation {
        guard let handlers = dragging.handlers else { return NSDragOperation() }
        let point = convert(sender.draggingLocation, from: nil)
        let inside = islandPath?.contains(point) ?? false

        guard inside else {
            endDrag()
            return NSDragOperation()
        }
        guard !dragging.isInside else { return dragging.operation }

        dragging.isInside = true
        let operation = handlers.entered(sender.draggingPasteboard)
        dragging.operation = operation
        return operation
    }

    private func endDrag() {
        guard dragging.isInside else { return }
        dragging.isInside = false
        dragging.operation = NSDragOperation()
        dragging.handlers?.exited()
    }

    /// Registers the types this island accepts, replacing any previous registration.
    public func acceptDrops(of types: [NSPasteboard.PasteboardType]) {
        unregisterDraggedTypes()
        guard !types.isEmpty else { return }
        registerForDraggedTypes(types)
    }

    // MARK: - Source

    /// Called from `mouseDown` before the click is reported. Returns true when the press was
    /// something other than a click on the island — a drag out of the shelf, a reorder, or a press
    /// on one of its controls — in which case the island must not toggle.
    ///
    /// ## One press, three meanings, decided by what happens next
    ///
    /// A press on a tile can become any of three things and the difference is *time and distance*,
    /// which is information no single event carries:
    ///
    /// | | |
    /// |---|---|
    /// | move more than `pressSlop` | lift the file out of the island, as an AppKit dragging session |
    /// | hold still for `longPressDelay` | pick the tile up and reorder the shelf |
    /// | release before either | a click — which previews the file |
    ///
    /// So the press has to be *tracked*, and it is tracked the way AppKit's own controls track one:
    /// a nested `nextEvent(matching:until:inMode:)` loop in `.eventTracking`, with every piece of
    /// state on the stack. The alternative — overriding `mouseDragged`/`mouseUp` and running a
    /// one-shot task for the deadline — needs three stored properties in a view whose whole design
    /// is that it holds no mouse state, and it puts the press's three outcomes in three methods that
    /// have to agree about which of them is in progress.
    ///
    /// **What it costs, stated rather than discovered later:** the main thread is inside this loop
    /// for as long as the user holds the button, up to `longPressDelay` before anything is decided.
    /// That is the same thing AppKit does during any drag, `.eventTracking` is a common run-loop
    /// mode so CoreAnimation still commits (which is what lets the tiles rearrange under the
    /// pointer), and the one thing that genuinely pauses is a `Timer` scheduled in `.default` mode —
    /// `IslandHitTestView`'s hover watchdog, for the length of a press that is by definition on the
    /// island. A press that moves — the common case, dragging a file out — leaves the loop on the
    /// first sample past the slop and pays none of it.
    ///
    /// The dragging session is begun from the *dragged* event rather than the mouse-down, which is
    /// the one behavioral difference from the version before reordering existed. AppKit applies its
    /// own threshold either way; beginning from the event that crossed our slop simply means the
    /// session starts already knowing the drag is real.
    func beginDragOut(with event: NSEvent) -> Bool {
        guard let handlers = dragging.handlers else { return false }
        let point = convert(event.locationInWindow, from: nil)

        // Not a tile: a badge, a header control, or island. Those act on the press itself — there is
        // nothing about them that a hold or a drag could turn into something else, and tracking them
        // would make every click on Clear All wait out the long-press delay before doing anything.
        guard handlers.pressBegan(point) else { return handlers.mouseDown(point) }

        trackPress(from: point, handlers: handlers)
        return true
    }

    // MARK: - The other button

    /// A secondary click on the island.
    ///
    /// Here rather than in `IslandHitTestView` beside `mouseDown` because it is part of the same
    /// story this file already tells — what a press on a *tile* means — and the division that file
    /// states is clicks and hover there, dragging and pressing here.
    ///
    /// **A fourth meaning could not be added to the left button.** That press is already a drag out
    /// if it moves, a reorder if it is held, and a preview if it is released, decided by time and
    /// distance in `trackPress`; a fourth outcome would need a fourth discriminator and there is no
    /// axis left. The right button carries no meaning on the island at all, and on macOS it already
    /// means exactly this — "what can I do with the thing under the pointer" — everywhere else.
    ///
    /// Deliberately not calling `super`, for the same reason `mouseDown` does not: the default
    /// implementation walks the responder chain, which for a non-key panel can end at `NSApp` and
    /// provoke activation.
    ///
    /// ## Two meanings, and the shelf's comes first
    ///
    /// A right-click on a **shelf tile** opens that tile's actions, drawn as a layer *inside* the
    /// island. A right-click anywhere else opens Isleta's own menu — Settings and the rest — which
    /// is a real `NSMenu` over the notch.
    ///
    /// The order is not arbitrary. The tile menu is about the thing under the pointer and the island
    /// menu is about the island, so the more specific one is offered the point first;
    /// `IslandDragHandlers.contextMenu` returns whether it took it, which is exactly the seam that
    /// makes the fallback possible without this view knowing what a tile is. A shelf with no
    /// handlers — every island that is not the shelf — falls straight through.
    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handlers = dragging.handlers, handlers.contextMenu(point) { return }
        onSecondaryClick?(event)
    }

    /// Waits for the press to declare itself: movement, a hold, or a release.
    private func trackPress(from origin: CGPoint, handlers: IslandDragHandlers) {
        guard let window else { return }
        let deadline = Date().addingTimeInterval(IslandDragHandlers.longPressDelay)

        while let event = window.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: deadline,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseUp:
                // A click. The press is over and nothing was picked up, so it means whatever the
                // shell says a click on a tile means.
                _ = handlers.mouseDown(origin)
                return

            case .leftMouseDragged:
                // Jitter is not a drag. Without the slop a hand that is merely resting could never
                // reach the hold at all, because the first 1pt tremor would lift the file out
                // instead — and the user would have no way to discover that reordering exists.
                guard hypot(point.x - origin.x, point.y - origin.y) > IslandDragHandlers.pressSlop else {
                    continue
                }
                let items = handlers.itemsToDragOut(origin)
                guard !items.isEmpty else { return }
                beginDraggingSession(with: items, event: event, source: self)
                return

            default:
                continue
            }
        }

        // The deadline passed with the button still down and the pointer still there.
        guard handlers.pressHeld(origin) else { return }
        trackReorder(from: origin, handlers: handlers)
    }

    /// Follows a tile the user has picked up, until they let go.
    ///
    /// The wait is bounded and then re-checked rather than left at `.distantFuture`, which is the
    /// obvious way to write "until the mouse comes up" and is a main thread wedged forever the one
    /// time the mouse-up is delivered somewhere else — a display disconnecting mid-reorder, or the
    /// panel being rebuilt underneath the press. `NSEvent.pressedMouseButtons` is the ground truth,
    /// and asking it once a second costs nothing during a gesture that is already holding the
    /// thread.
    private func trackReorder(from origin: CGPoint, handlers: IslandDragHandlers) {
        guard let window else {
            handlers.pressEnded(origin)
            return
        }
        var last = origin
        while true {
            guard let event = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: Date().addingTimeInterval(1),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                // Nothing for a second. Either the user is holding a tile still — in which case
                // carry on waiting — or the button is up and its event went elsewhere.
                guard NSEvent.pressedMouseButtons & 1 != 0 else { break }
                continue
            }
            last = convert(event.locationInWindow, from: nil)
            guard event.type != .leftMouseUp else { break }
            handlers.pressDragged(last)
        }
        handlers.pressEnded(last)
    }
}

extension IslandHitTestView: NSDraggingSource {

    /// What a drag *out* of the island is allowed to do.
    ///
    /// Deliberately not `.every`, and the omissions are the interesting part. **`.move` is excluded**
    /// because the shelf holds a reference to a file that still lives wherever the user put it — a
    /// destination that decided to move (which Finder does by default within a volume) would
    /// relocate the original out from under whatever else has it open, in response to a gesture the
    /// user reads as "give a copy of this to that app". **`.delete` is excluded** for the same
    /// reason with the stakes raised: dragging to the Trash would trash the original.
    ///
    /// `.generic` is included because a great many destinations that simply *open* what they are
    /// given ask for it and nothing else; refusing it would make the shelf useless for the most
    /// ordinary drag there is.
    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        IslandDragHandlers.dragOutOperations
    }
}

/// The drop and drag-out callbacks for one island, plus the latch that turns AppKit's continuous
/// stream of dragging updates into enter and exit edges.
///
/// A struct of closures rather than a delegate protocol because the values differ per screen — the
/// controller builds one of these per attachment, closing over the `IslandScreen` — and because the
/// alternative is a second object per panel whose only job is to remember which screen it is on.
///
/// Every closure is main-actor isolated: dragging is AppKit event delivery, and everything these
/// reach (the coordinator, the screen models) is main-actor already.
public struct IslandDragHandlers {

    /// A drag has arrived on the island. Return the operation to advertise, or `NSDragOperation()`
    /// to refuse it. Refusing does *not* pass the drag to the app underneath — see the note on
    /// `IslandHitTestView`'s extension.
    public var entered: @MainActor (NSPasteboard) -> NSDragOperation

    /// The drag left the island without dropping, or ended elsewhere.
    public var exited: @MainActor () -> Void

    /// The drag was released on the island. Return whether anything was taken from it.
    public var drop: @MainActor (NSPasteboard) -> Bool

    /// Items to lift out of the island for a press at a point in the panel's y-down space, or an
    /// empty array if nothing there is draggable.
    public var itemsToDragOut: @MainActor (CGPoint) -> [NSDraggingItem]

    /// A press at a point in the panel's y-down space that did not start a drag. Return true to
    /// consume it, which stops the island toggling — that is what makes a control drawn *on* the
    /// island (a remove badge, a clear button) something other than a click on the island itself.
    public var mouseDown: @MainActor (CGPoint) -> Bool

    /// Whether a press at this point is on something whose meaning depends on what the press does
    /// next — a shelf tile. Return false for everything else, which is then acted on immediately.
    ///
    /// This is a question about the *point*, asked before any tracking begins, and it is deliberately
    /// not "can this be dragged out": a tile whose file has been deleted still has to be pickable up
    /// and reorderable, and `itemsToDragOut` correctly answers nothing for it.
    public var pressBegan: @MainActor (CGPoint) -> Bool

    /// The press has been held still for `longPressDelay`. Return true to begin a reorder, in which
    /// case `pressDragged` follows the pointer and `pressEnded` closes it out.
    ///
    /// False is a real answer and not a failure: the shelf refuses to reorder while a search is
    /// narrowing what is on screen, because a position among the *matches* means nothing in the
    /// array underneath (`ShelfContents.move` says why).
    public var pressHeld: @MainActor (CGPoint) -> Bool

    /// The pointer has moved while a tile is held.
    public var pressDragged: @MainActor (CGPoint) -> Void

    /// The tile has been let go. Always called once for a reorder that started, including the paths
    /// where the mouse-up was never seen — a reorder that ended by being abandoned still has to put
    /// the tile down.
    public var pressEnded: @MainActor (CGPoint) -> Void

    /// A secondary click at a point in the panel's y-down space. Return true if it was consumed.
    ///
    /// Defaulted to "nothing there", so an island with no shelf behind it — a preview, a test
    /// harness — answers a right click by doing nothing rather than by needing a handler written for
    /// it.
    public var contextMenu: @MainActor (CGPoint) -> Bool

    /// The operations a drag out of the island advertises. A constant rather than a literal at the
    /// point of use so the rule above is one value that a test can hold — see `ShelfDragTests`,
    /// which is what fails if `.move` or `.delete` is ever added to it.
    public static let dragOutOperations: NSDragOperation = [.copy, .generic, .link]

    /// How long a press has to be held before it becomes a reorder.
    ///
    /// Half a second, which is `LongPressGesture`'s own default. Matching it is worth more than
    /// tuning it: this is a gesture the user has to *discover*, and the way they discover it is that
    /// it behaves like the long press they already know from everywhere else on the system. Nobody
    /// waits it out by accident either, because any real movement inside the window ends the press
    /// as a drag instead.
    public static let longPressDelay: TimeInterval = 0.5

    /// How far the pointer may wander during that half second and still count as held still.
    ///
    /// Three points, the same order as AppKit's own drag threshold. Zero would make the hold
    /// unreachable for anyone whose hand is not perfectly still — the first tremor would lift the
    /// file out of the island instead — and the user would have no way to find out that the gesture
    /// exists at all.
    public static let pressSlop: CGFloat = 3

    public init(
        entered: @escaping @MainActor (NSPasteboard) -> NSDragOperation,
        exited: @escaping @MainActor () -> Void,
        drop: @escaping @MainActor (NSPasteboard) -> Bool,
        itemsToDragOut: @escaping @MainActor (CGPoint) -> [NSDraggingItem] = { _ in [] },
        mouseDown: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
        pressBegan: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
        pressHeld: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
        pressDragged: @escaping @MainActor (CGPoint) -> Void = { _ in },
        pressEnded: @escaping @MainActor (CGPoint) -> Void = { _ in },
        contextMenu: @escaping @MainActor (CGPoint) -> Bool = { _ in false }
    ) {
        self.entered = entered
        self.exited = exited
        self.drop = drop
        self.itemsToDragOut = itemsToDragOut
        self.mouseDown = mouseDown
        self.pressBegan = pressBegan
        self.pressHeld = pressHeld
        self.pressDragged = pressDragged
        self.pressEnded = pressEnded
        self.contextMenu = contextMenu
    }
}

/// One island's dragging state. Held by `IslandHitTestView` as a single stored property so that
/// adding drag and drop cost that file one line of storage rather than five.
public struct IslandDragging {

    public var handlers: IslandDragHandlers?

    /// Whether the last update put the drag inside the drawn island. See the note on latching in
    /// `IslandHitTestView`'s extension: this is what makes an exit an edge rather than a message we
    /// have to receive.
    var isInside = false

    /// The operation last advertised, replayed on every update so the answer cannot flicker while
    /// the pointer moves around inside the island.
    var operation = NSDragOperation()

    public init() {}
}
