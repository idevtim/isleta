import AppKit
import IslandActivities
import IslandKit
import IslandUI

/// Joins the shelf to the island: drags in, drops, drags back out, and the island opening and
/// closing around all three — plus, since 1.5.0, everything that turns a landing strip into a
/// workbench: it survives a launch, it scrolls, it can be searched, reordered and previewed.
///
/// Wiring only, like `SourceHub`. `ShelfModel` owns what is held, `ShelfStore` owns the bytes,
/// `ShelfLayout` owns where a tile is, `ShelfSearch` owns what a query matches, and
/// `IslandHitTestView` owns which window the pointer is over. What genuinely belongs here is what
/// needs more than one of those: turning a pasteboard into shelf items, turning a point into a tile,
/// deciding when the island is open, and knowing that a change to the list is a reason to write to
/// disk.
///
/// ## The interaction, and why each half of it is that way
///
/// **A drag entering opens the island.** It has to be the island *opening* rather than a fourth
/// presentation, because a drop target has to be big enough to drop into and the vocabulary already
/// has a word for the island being big: `.expanded`. Nothing new is invented, so the widen-then-
/// tighten protocol in `AppDelegate.transition` covers the shape change with no new proof needed —
/// every form the island passes through on the way is one of `IslandForm.allCases`.
///
/// **A drag leaving closes it again**, and a drop leaves it open for a moment so the user sees what
/// they now have. It is closed by two mechanisms that cover each other's blind spot, which is
/// deliberate rather than belt-and-braces for its own sake: the pointer leaving the island closes
/// it (`hoverChanged`), and a one-shot task closes it if no hover was ever reported. Tracking-area
/// crossings during a drag session are not something to rely on — `IslandHitTestView` already
/// carries a watchdog for the `mouseExited` that does not always arrive — and an island that stays
/// open across the top of someone's screen because a message went missing is the worst failure this
/// feature has.
///
/// **The island only closes itself if it opened itself.** A click-opened island still behaves
/// exactly as it did in Milestone 1: it stays open until the user closes it. `openedByDrag` is what
/// separates the two, per screen. It is also why a shelf being *used* — searched, scrolled,
/// reordered — is never closed by the timer: those all happen on an island the user opened.
///
/// ## One press, three meanings
///
/// A press on a tile is a drag out if it moves, a reorder if it is held, and a preview if it is
/// released. `IslandDragAndDrop.trackPress` decides which and this decides what each means; the
/// division is the same one everywhere else in this file — IslandKit knows the events, the shell
/// knows what they are about.
@MainActor
final class ShelfController {

    private let shelf: ShelfModel
    private let store: ShelfStore
    private let activities: ActivityCoordinator
    private let preview = ShelfPreview()

    /// What the island can *do* with what it is holding — the actions menu and the conversion
    /// workers behind it. Owned here rather than beside this in the app delegate for the reason this
    /// class exists at all: the shelf reads as one file, and everything the menu needs from the app
    /// shell it already has.
    private let actions: ShelfActionController

    /// Called when a drop action finishes, so the drop history can record it.
    ///
    /// Forwarded rather than exposing `actions`, which is private for a reason: the shell asks the
    /// shelf to do things, and a shell reaching past it into the action controller is a second way
    /// to start a conversion.
    var onDidWork: ((DropAction, [URL], [URL], String?) -> Void)? {
        get { actions.onDidWork }
        set { actions.onDidWork = newValue }
    }

    /// Whether a file can produce an iCloud link, and how to copy one. Forwarded for `onDidWork`'s
    /// reason — the shell asks the shelf to do things and does not reach past it.
    var canCopyLink: ((URL) -> Bool)? {
        get { actions.canCopyLink }
        set { actions.canCopyLink = newValue }
    }

    var copyLink: ((URL) -> Void)? {
        get { actions.copyLink }
        set { actions.copyLink = newValue }
    }

    /// Runs a recorded action again, on files the history has already resolved.
    func runAgain(_ action: DropAction, on urls: [URL]) {
        actions.runAgain(action, on: urls)
    }
    private let reduceMotion: @MainActor () -> Bool
    private let setExpanded: @MainActor (IslandScreen, Bool) -> Void
    private let screenModel: @MainActor (CGDirectDisplayID) -> IslandScreenModel?

    /// The screens themselves, for the geometry a layout needs when the question is not about the
    /// screen the pointer is on — asking how far the grid can scroll, and which island should take
    /// the keyboard.
    private let screens: @MainActor () -> [IslandScreen]

    /// Asks the app shell to let one island's panel take key, or to give the keyboard back.
    ///
    /// Handed in rather than reached for, and it goes through the shell rather than straight to
    /// `IslandController` because there is exactly one keyboard: the reply composer wants it too,
    /// and the shell is the layer that knows which surface has it. Returns whether the panel
    /// actually became key — **the effect, never the request**, which is the rule the reply surface
    /// already keeps: a panel that did not take key is a field that will never see a keystroke, and
    /// letting the user type into it is worse than saying so.
    private let takeKeyboard: @MainActor (CGDirectDisplayID?) -> Bool

    /// Hands the keyboard back to whatever had it.
    private let releaseKeyboard: @MainActor () -> Void

    /// Screens whose island was opened by a drag rather than by the user.
    private var openedByDrag: Set<CGDirectDisplayID> = []

    /// How far the grid is scrolled. One for the app, like the shelf itself — see `pushScroll`.
    private var gridScroll = ShelfScroll()

    /// The one outstanding auto-collapse. At most one, canceled by anything that makes it wrong —
    /// a new drag arriving, or the island being closed some other way. A one-shot `Task.sleep`
    /// rather than a `Timer`, and none exists at any other time (§9).
    private var autoCollapse: Task<Void, Never>?

    /// How long the island stays open after a drop before closing itself.
    ///
    /// Long enough to read the tile that just landed, short enough that it is not something the
    /// user has to dismiss. It is a backstop rather than the main mechanism — with the pointer
    /// still on the island (which it is, immediately after a drop) the hover path takes over.
    private static let autoCollapseDelay = Duration.milliseconds(2000)

    init(
        shelf: ShelfModel,
        store: ShelfStore,
        activities: ActivityCoordinator,
        reduceMotion: @escaping @MainActor () -> Bool,
        setExpanded: @escaping @MainActor (IslandScreen, Bool) -> Void,
        screenModel: @escaping @MainActor (CGDirectDisplayID) -> IslandScreenModel?,
        screens: @escaping @MainActor () -> [IslandScreen] = { [] },
        takeKeyboard: @escaping @MainActor (CGDirectDisplayID?) -> Bool = { _ in false },
        releaseKeyboard: @escaping @MainActor () -> Void = {}
    ) {
        self.shelf = shelf
        self.store = store
        self.activities = activities
        self.reduceMotion = reduceMotion
        self.setExpanded = setExpanded
        self.screenModel = screenModel
        self.screens = screens
        self.takeKeyboard = takeKeyboard
        self.releaseKeyboard = releaseKeyboard
        self.actions = ShelfActionController(
            shelf: shelf, store: store, activities: activities, reduceMotion: reduceMotion
        )
        // A converted file is a real file in the user's own folder, so the tile that appears for it
        // has to survive a relaunch like any other. Without this the shelf would be one item short
        // at the next launch — and only for the files Isleta itself made, which is the worst set to
        // lose.
        actions.onContentsChanged = { [weak self] in self?.afterContentsChanged() }

        // Return in the field. The model cannot release the keyboard itself — only the shell knows
        // whether some other surface wants it next — so the view raises it and this answers.
        shelf.onSubmitSearch = { [weak self] in self?.submitSearch() }
        // Every keystroke changes how long the grid is, so the offset the user last scrolled to now
        // points somewhere else. Back to the top rather than clamped: a user who has scrolled and
        // then types is asking to see the matches, not to stay where they were.
        shelf.onQueryChanged = { [weak self] in
            guard let self else { return }
            self.gridScroll.reset()
            self.pushScroll(animated: false)
        }
    }

    // MARK: - Island wiring

    /// The callbacks one screen's panel answers dragging with.
    func handlers(for screen: IslandScreen) -> IslandDragHandlers {
        IslandDragHandlers(
            entered: { [weak self] pasteboard in self?.dragEntered(pasteboard, on: screen) ?? NSDragOperation() },
            exited: { [weak self] in self?.dragExited(on: screen) },
            drop: { [weak self] pasteboard in self?.drop(pasteboard, on: screen) ?? false },
            itemsToDragOut: { [weak self] point in self?.itemsToDragOut(at: point, on: screen) ?? [] },
            mouseDown: { [weak self] point in self?.mouseDown(at: point, on: screen) ?? false },
            pressBegan: { [weak self] point in self?.pressBegan(at: point, on: screen) ?? false },
            pressHeld: { [weak self] point in self?.pressHeld(at: point, on: screen) ?? false },
            pressDragged: { [weak self] point in self?.pressDragged(to: point, on: screen) },
            pressEnded: { [weak self] _ in self?.pressEnded() },
            contextMenu: { [weak self] point in self?.contextMenu(at: point, on: screen) ?? false }
        )
    }

    /// Reads the shelf back and makes QuickLook reachable. Called once, at launch, after the panels
    /// exist.
    ///
    /// The restore is deliberately **not** an activity: putting the shelf on stage at every login
    /// would mean the island wore a tray glyph from the moment the user's Mac came up, which is the
    /// app announcing itself about something that has not happened. `syncActivity` publishes it the
    /// first time it is asked for — a drag arriving, or the shortcut.
    func start() {
        preview.install()
        let restored = store.restore()
        guard !restored.isEmpty else { return }
        shelf.restore(restored)
    }

    /// What the coordinator has on stage, pushed in from the app shell.
    ///
    /// The shelf can be preempted — a volume HUD is `.interrupting` and a shelf is `.standard`, so
    /// pressing the volume key mid-drag takes the island. Without this the shelf's tiles would go
    /// on drawing over whatever displaced them, and a search field would be left floating over an
    /// island that is now showing something else.
    func presentedKindChanged(to kind: ActivityKind?) {
        shelf.isPresented = kind == .shelf
        guard !shelf.isPresented else { return }
        endSearch(clearing: true)
        actions.closeMenu()
    }

    /// The pointer arriving on or leaving an island, forwarded from the app shell's hover handler.
    ///
    /// Only the leaving edge does anything, and only for an island the user did not open: a drag
    /// that opened the island and then went elsewhere, or a drop the user has finished looking at.
    func hoverChanged(_ hovering: Bool, on screen: IslandScreen) {
        guard !hovering, openedByDrag.contains(screen.id) else { return }
        collapse(screen)
    }

    /// Every island has closed. Ends anything that only makes sense on an open one.
    ///
    /// Called from the app shell's `collapseAll`, which is the one path Escape, an outside click and
    /// the close gesture all take. A search field left floating over a closed island would be a
    /// caret in the menu bar.
    func islandsClosed() {
        endSearch(clearing: true)
        // The menu is drawn inside the open island's body and has no meaning outside it. Closed
        // rather than remembered, for the same reason the search is cleared: reopening the island
        // should show the shelf, not the state of a decision the user walked away from.
        actions.closeMenu()
        shelf.reorderingID = nil
    }

    /// Ends every conversion worker, synchronously. Called from `applicationWillTerminate`, which
    /// returns into `exit()` — see `FileActionRunner`.
    func stopAndWait() {
        actions.stopAndWait()
    }

    /// Turns the drop actions on or off, from `SourceToggles.dropActions`.
    ///
    /// Switching them off closes an open menu rather than leaving it up: the flag is read at the
    /// moment of a press, so a menu still on screen would be a list of rows that silently do
    /// nothing.
    func setDropActionsEnabled(_ enabled: Bool) {
        guard shelf.areDropActionsEnabled != enabled else { return }
        shelf.areDropActionsEnabled = enabled
        if !enabled { actions.closeMenu() }
    }

    /// Opens the island on the shelf, for the `openShelf` shortcut.
    ///
    /// Nothing to show is a real answer: an empty shelf publishes no activity (see `syncActivity`),
    /// so opening the island would open it onto whatever else is on stage, or onto the quiet menu.
    /// The shortcut says nothing rather than saying the wrong thing.
    func openFromShortcut() {
        guard !shelf.isEmpty else {
            IslandLog.shelf.info("open-shelf shortcut with an empty shelf — nothing to show")
            return
        }
        syncActivity()
        for screen in screens() {
            guard screenModel(screen.id)?.isExpanded != true else { continue }
            setExpanded(screen, true)
        }
    }

    // MARK: - Receiving

    private func dragEntered(_ pasteboard: NSPasteboard, on screen: IslandScreen) -> NSDragOperation {
        guard store.canAccept(pasteboard) else { return NSDragOperation() }
        autoCollapse?.cancel()
        autoCollapse = nil

        // A drop into a filtered shelf lands somewhere the user cannot see — the new tile is at the
        // end of an array most of which is hidden, and the grid would appear not to have taken it.
        // Ending the search is the honest resolution: what the user is doing now is dropping.
        endSearch(clearing: true)
        // The menu goes for the same reason and one stronger: it is a list of things to do to a
        // *named set of files*, and the user is in the middle of changing what the shelf holds.
        actions.closeMenu()

        setDropTargeted(true)
        syncActivity()
        // Only an island that was *closed* counts as opened by the drag. One the user clicked open
        // is theirs, and a drag passing over it must not take away their decision to leave it open.
        if screenModel(screen.id)?.isExpanded != true {
            openedByDrag.insert(screen.id)
        }
        setExpanded(screen, true)
        return .copy
    }

    private func dragExited(on screen: IslandScreen) {
        setDropTargeted(false)
        syncActivity()
        collapse(screen)
    }

    private func drop(_ pasteboard: NSPasteboard, on screen: IslandScreen) -> Bool {
        let arrived = store.items(from: pasteboard)
        disposeOfEvicted(shelf.insert(arrived, reduceMotion: reduceMotion()))

        // Promised files land later and each on its own, so the shelf grows as they arrive rather
        // than all at once at the end — see `ShelfStore.receivePromises`.
        let promised = store.receivePromises(from: pasteboard) { [weak self] item in
            guard let self else { return }
            self.disposeOfEvicted(self.shelf.insert([item], reduceMotion: self.reduceMotion()))
            self.syncActivity()
            self.revealNewest()
            // Materialised files are not written down (see `ShelfArchive`), but the *rest* of the
            // shelf still is: an eviction caused by a promise landing changes what survives the
            // night, and nothing else would record it.
            self.persist()
        }

        setDropTargeted(false)
        syncActivity()
        revealNewest()
        persist()
        // Counts only. What was dropped is the user's business; that a drop of N items landed on
        // display X, and whether any were promises still to arrive, is ours.
        IslandLog.shelf.info("drop on display \(screen.id): \(arrived.count) item(s)\(promised ? " plus promised files" : ""), shelf now \(shelf.items.count)")

        let accepted = !arrived.isEmpty || promised
        if accepted {
            // The one moment in this feature where a haptic is unambiguously right: the user's hand
            // is on the trackpad by construction (they are mid-drag), and something they did just
            // landed. `.alignment` is the same "you have arrived on something" tap the island uses
            // for a peek — a drop is the same kind of event, not a different one.
            Haptics.peek()
            scheduleAutoCollapse(on: screen)
        } else {
            // Refused after having been accepted on the way in — the promise receivers went away
            // with the drag. Nothing is coming to close the island otherwise: `performDragOperation`
            // has already ended the drag, so no exit message follows.
            collapse(screen)
        }
        return accepted
    }

    // MARK: - Giving back

    private func itemsToDragOut(at point: CGPoint, on screen: IslandScreen) -> [NSDraggingItem] {
        guard !actions.isShowingMenu else { return [] }
        guard case .tile(let index) = region(at: point, on: screen),
              let item = shelf.visibleItem(at: index),
              let placed = tileFrame(at: index, on: screen) else { return [] }

        // Resolved at the moment of the drag, never in the background. If the file has moved the
        // bookmark finds it and the tile quietly updates; if it is gone the tile says so and
        // nothing is dragged — handing a destination a URL to a file that no longer exists is how
        // a shelf turns into a source of empty files.
        guard let resolution = adopt(store.resolve(item), for: item) else { return [] }
        return [store.draggingItem(for: item, url: resolution.url, in: placed)]
    }

    /// Takes what a resolution says and writes it back onto the shelf: a new location, a renewed
    /// bookmark, or a tile that is now dead.
    ///
    /// One place, because all three callers — a drag out, a preview, and the launch — have to agree
    /// about what happened. Returns nil for a file that is gone, which every caller then refuses to
    /// act on.
    @discardableResult
    private func adopt(_ resolution: ShelfStore.Resolution?, for item: ShelfItem) -> ShelfStore.Resolution? {
        guard let resolution else {
            shelf.markStale(id: item.id)
            persist()
            return nil
        }
        if resolution.url != item.url { shelf.relocate(id: item.id, to: resolution.url) }
        if let renewed = resolution.renewedBookmark { shelf.refreshBookmark(id: item.id, to: renewed) }
        // A relocation and a renewal both change what is written down. A resolution that changed
        // nothing does not, which is the common case and the reason this is conditional: resolving
        // is what happens on every drag out, and writing on every drag out would be a file write per
        // gesture.
        if resolution.url != item.url || resolution.renewedBookmark != nil { persist() }
        return resolution
    }

    private func mouseDown(at point: CGPoint, on screen: IslandScreen) -> Bool {
        // The actions menu is a layer in the same rectangle, so it owns every press while it is up.
        // Asked first, and exhaustively: a press that fell through to the grid's arithmetic would
        // find a tile at the coordinates a row is drawn at and remove a file.
        if actions.isShowingMenu {
            switch actionRegion(at: point, on: screen) {
            case .back:
                actions.closeMenu()
                return true
            case .row(let index):
                guard let action = actions.action(at: index) else { return true }
                actions.perform(action, resolving: menuItems()) { [weak self] id, url in
                    self?.shelf.relocate(id: id, to: url)
                }
                afterContentsChanged()
                return true
            case .none:
                return false
            }
        }

        switch region(at: point, on: screen) {
        case .remove(let index):
            guard let item = shelf.visibleItem(at: index) else { return false }
            shelf.remove(id: item.id, reduceMotion: reduceMotion())
            afterContentsChanged()
            collapseIfEmpty(screen)
            return true
        case .clear:
            shelf.removeAll(reduceMotion: reduceMotion())
            endSearch(clearing: true)
            afterContentsChanged()
            collapseIfEmpty(screen)
            return true
        case .search:
            toggleSearch(on: screen)
            return true
        case .actions:
            guard shelf.areDropActionsEnabled else { return false }
            // Over what is on screen, which while a search is live is the matches — the one place
            // the filter has a consequence other than hiding tiles, and a deliberate one. The field
            // is put away first, keeping the filter: the menu is a different surface and a caret
            // left blinking behind it would be an island holding the keyboard for nothing.
            endSearch(clearing: false)
            actions.openMenu(over: shelf.visibleItems)
            return true
        case .tile(let index):
            // A press on a tile that produced neither a drag nor a hold. That is a click, and a
            // click previews — the same thing the space bar does in the Finder, on the same kind of
            // object. Consumed either way: the island must not collapse under a press aimed at a
            // tile, including a press on a tile whose file has gone.
            previewItem(at: index, on: screen)
            return true
        case .none:
            return false
        }
    }

    /// A right click on a tile: the actions menu for **that one file**.
    ///
    /// The two ways in are scoped differently on purpose, and the difference is the whole reason
    /// there are two. The wand in the header is about *what is on screen* — which after a search is
    /// the matches — and `DropAction.menu` therefore offers only the conversions every one of them
    /// can do, an intersection that is empty for a mixed shelf. That is honest and it is also
    /// useless for the commonest case there is: one file, one conversion. A right click names a
    /// single tile, so the menu is that tile's own list.
    ///
    /// It closes an open menu rather than replacing it, if the click is not on a tile — the same
    /// thing a click on the island's background does, and for the same reason.
    private func contextMenu(at point: CGPoint, on screen: IslandScreen) -> Bool {
        guard shelf.areDropActionsEnabled else { return false }
        guard !actions.isShowingMenu else {
            actions.closeMenu()
            return true
        }
        guard case .tile(let index) = region(at: point, on: screen),
              let item = shelf.visibleItem(at: index) else { return false }
        endSearch(clearing: false)
        actions.openMenu(over: [item])
        return true
    }

    // MARK: - The press

    private func pressBegan(at point: CGPoint, on screen: IslandScreen) -> Bool {
        // Nothing on the actions menu means three things depending on what the press does next —
        // there are no tiles to lift out and none to reorder — so the press is acted on immediately
        // rather than tracked, and every row responds on the way down like a button.
        guard !actions.isShowingMenu else { return false }
        guard case .tile = region(at: point, on: screen) else { return false }
        return true
    }

    /// A tile held still: pick it up.
    ///
    /// **Refused while a search is running**, and that is the one place the filter has a
    /// consequence rather than being invisible. A position among the *matches* has no honest
    /// meaning in the shelf underneath — dropping between the second and third match says nothing
    /// about where that is among thirty items — so rather than guess, the gesture does nothing and
    /// the user is left holding a tile that does not move. See `ShelfContents.move`.
    private func pressHeld(at point: CGPoint, on screen: IslandScreen) -> Bool {
        guard !shelf.isSearching,
              case .tile(let index) = region(at: point, on: screen),
              let item = shelf.visibleItem(at: index) else { return false }
        shelf.reorderingID = item.id
        // The same "you have arrived on something" tap a peek uses. The hand is on the trackpad by
        // construction — the button is down — and the tap is the only thing on a black island that
        // says the hold registered before the tile has moved anywhere.
        Haptics.peek()
        return true
    }

    private func pressDragged(to point: CGPoint, on screen: IslandScreen) {
        guard let id = shelf.reorderingID,
              let (layout, origin) = resolvedLayout(on: screen) else { return }
        let inBody = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let target = layout.reorderTarget(at: inBody, itemCount: shelf.count) else { return }
        // A tap per slot crossed, not per sample: `move` reports whether anything actually moved,
        // and the pointer sits inside one tile for tens of samples. Without that test this would be
        // a haptic at trackpad frequency, which is a buzz rather than a series of ticks.
        guard shelf.move(id: id, to: target, reduceMotion: reduceMotion()) else { return }
        Haptics.peek()
    }

    private func pressEnded() {
        guard shelf.reorderingID != nil else { return }
        shelf.reorderingID = nil
        persist()
        IslandLog.shelf.info("shelf reordered — \(shelf.count) item(s)")
    }

    // MARK: - Preview

    /// QuickLook for one tile, or closing the preview that is already showing it.
    ///
    /// The second click on the same tile closes, which is what the space bar does in the Finder for
    /// the same object — and it matters more here, because the preview panel takes the keyboard from
    /// whatever the user was doing (see `ShelfPreview`) and the way out has to be as easy as the way
    /// in.
    private func previewItem(at index: Int, on screen: IslandScreen) {
        guard let item = shelf.visibleItem(at: index) else { return }
        guard let resolution = adopt(store.resolve(item), for: item) else {
            // The file is gone and the tile now says so. Nothing to preview, and deliberately no
            // alert: the shelf answering a click by explaining itself on screen is more than a
            // missing file is worth.
            return
        }
        guard !preview.isPreviewing(resolution.url) else {
            preview.close()
            return
        }
        preview.show(resolution.url, from: tileScreenFrame(at: index, on: screen))
    }

    // MARK: - Search

    private func toggleSearch(on screen: IslandScreen) {
        if shelf.isSearchOpen || shelf.isSearching {
            endSearch(clearing: true)
        } else {
            beginSearch(on: screen)
        }
    }

    /// Puts the field up and gives it the keyboard.
    ///
    /// **Key is taken before the flag flips**, and the order is the whole of why the first keystroke
    /// lands. `ShelfLayerView` focuses the field on `isSearchOpen` becoming true; a field that gains
    /// focus in a window that is not yet key is the first responder of nothing, and the characters
    /// the user types while that is true go to the app behind. The reply surface establishes the
    /// same order for the same reason.
    ///
    /// A panel that refuses key leaves the search unopened rather than opening a field nobody can
    /// type in — measure the effect, never the request.
    private func beginSearch(on screen: IslandScreen) {
        guard takeKeyboard(screen.id) else {
            IslandLog.shelf.warning("shelf search could not take keyboard focus — not opening the field")
            return
        }
        shelf.isSearchOpen = true
        // A filtered grid the user is looking at halfway down is a grid whose matches are mostly
        // above the fold.
        gridScroll.reset()
        pushScroll(animated: false)
        IslandLog.shelf.info("shelf search opened over \(shelf.count) item(s)")
    }

    /// Return: keep the matches, give the keyboard back.
    ///
    /// The field goes and the filter stays, which is the state `ShelfLayerView.isSearchEngaged`
    /// draws the magnifier as an ✕ for. It is the one exit that leaves something behind, and it is
    /// worth having because the reason to search is usually to then drag one of the matches
    /// somewhere — which needs the pointer, not the keyboard.
    private func submitSearch() {
        guard shelf.isSearchOpen else { return }
        shelf.isSearchOpen = false
        releaseKeyboard()
    }

    /// Takes the field away, and optionally the filter with it.
    ///
    /// Safe to call at any time and from anywhere — a collapse, the shelf being preempted, a drag
    /// arriving, the shelf being cleared — which is what makes "the island never keeps the keyboard"
    /// checkable rather than hoped for. The keyboard is released whenever the field was up, before
    /// anything else, because that is the half whose failure is a machine that has stopped
    /// responding to typing.
    private func endSearch(clearing: Bool) {
        let wasOpen = shelf.isSearchOpen
        let wasFiltering = shelf.isSearching
        if wasOpen {
            shelf.isSearchOpen = false
            releaseKeyboard()
        }
        if clearing { shelf.setQuery("", reduceMotion: reduceMotion()) }
        guard wasOpen || wasFiltering else { return }
        gridScroll.reset()
        pushScroll(animated: false)
    }

    // MARK: - Scrolling

    /// Whether the shelf can use a vertical scroll right now.
    ///
    /// Asked by `SwipeController` before it hands the axis over, and the answer being *conditional*
    /// is the point. The drop history takes the vertical axis unconditionally, which it can afford
    /// because it carries its own exits — Clear All, the ✕, Escape. The shelf has none of those, so
    /// a shelf whose contents fit gives the axis back to `IslandCloseGesture` and stays closable
    /// with a flick. Only a shelf that genuinely has something off screen takes it.
    var canScroll: Bool {
        guard shelf.isPresented else { return false }
        // Whichever layer is up owns the axis, and only if it has somewhere to go. A menu of four
        // rows in a four-row viewport hands the vertical axis back to `IslandCloseGesture`, exactly
        // as a shelf that fits does — the rule is about the *layer*, not about the shelf.
        return actions.isShowingMenu ? actionScrollExtent > 0 : scrollExtent > 0
    }

    /// One scroll sample, while the shelf has the vertical axis.
    ///
    /// Writes the offset straight into every model with no animation and no transaction, for the
    /// reason `AppDelegate.scrollRecents` does: a scroll follows the fingers or it is not a scroll,
    /// and none of `Motion`'s four springs describes a drag.
    ///
    /// The island's *outline* cannot move as a result, so this takes none of the widen-then-tighten
    /// path a content change does: the viewport is a fixed rectangle the island was already sized
    /// for (`ShelfLayout.contentHeight`), and only what is drawn inside it changes.
    func scroll(_ sample: IslandScrollSample) {
        guard !actions.isShowingMenu else {
            actions.scroll(sample, extent: actionScrollExtent)
            return
        }
        gridScroll.consume(sample, extent: scrollExtent)
        pushScroll(animated: false)
    }

    /// Scrolls to where a drop just landed.
    ///
    /// The newest item is at the *end* of the shelf, which on a full grid is off screen — so a drop
    /// onto a scrolled shelf would otherwise appear to have been swallowed. Animated, on
    /// `Motion.nudge`, because the user is meant to see it arrive; the equivalent in the recents
    /// list is a notification landing while somebody is reading.
    private func revealNewest() {
        guard !shelf.isSearching else { return }
        gridScroll.revealEnd(extent: scrollExtent)
        pushScroll(animated: true)
    }

    /// Publishes the offset to the one place every island reads it from.
    ///
    /// `ShelfModel`, not the per-screen models, and that is the same call the drop history makes in
    /// the opposite direction: there the list lives per screen and the offset has to be pushed into
    /// each. The shelf is already app-wide — one model in the environment of every island — so two
    /// islands cannot disagree about where the grid is scrolled to without somebody deliberately
    /// making a second copy.
    private func pushScroll(animated: Bool) {
        let offset = gridScroll.clamped(to: scrollExtent)
        shelf.scrollTarget = animated
            ? shelf.scrollTarget.revealing(offset)
            : shelf.scrollTarget.dragged(to: offset)
    }

    /// How far the grid can scroll, from whichever island is currently laid out for it.
    ///
    /// Zero when no island is open, which is correct rather than a fallback: a shelf nobody is
    /// looking at cannot be scrolled, and `canScroll` reads this to decide whether to take the
    /// vertical axis at all.
    private var scrollExtent: CGFloat {
        for screen in screens() {
            if let (layout, _) = resolvedLayout(on: screen) { return layout.scrollExtent }
        }
        return 0
    }

    private var actionScrollExtent: CGFloat {
        for screen in screens() {
            if let (layout, _) = resolvedActionLayout(on: screen) { return layout.scrollExtent }
        }
        return 0
    }

    // MARK: - What the island is showing

    /// Publishes the shelf to the coordinator, or takes it off the stage when there is nothing left
    /// to say.
    ///
    /// **An empty shelf is dismissed rather than shown empty**, and that is the answer to what
    /// happens when the last item goes: the island returns to whatever it was doing before — Now
    /// Playing, or nothing at all. A tray glyph that sits in the flank forever, saying zero, would
    /// hold the island in its flanked resting shape permanently to report the absence of anything;
    /// the shelf is a place things are, not a feature that advertises itself.
    ///
    /// The expanded slot is deliberately left empty: `ShelfLayerView` draws the open island's body,
    /// and `ActivitySlotLayout.bodySlot` returns nil for an empty slot, so the two cannot overlap.
    private func syncActivity() {
        guard let id = ActivityKind.shelf.singletonID else { return }
        guard !shelf.isEmpty || shelf.isDropTargeted else {
            activities.dismiss(id)
            return
        }

        var activity = BuiltInActivity.shelf(itemCount: shelf.count)
        activity.presentations.expanded = .empty
        if shelf.isEmpty {
            // Nothing held yet, so there is no count worth showing — only that the island is
            // waiting for something.
            activity.presentations.leading = ActivityContent(
                symbol: "tray.and.arrow.down.fill", tint: .accent,
                accessibilityLabel: appText("shelf.a11y", "Shelf")
            )
            activity.presentations.trailing = .empty
            activity.presentations.compact = ActivityContent(
                symbol: "tray.and.arrow.down.fill",
                title: appText("shelf.dropToAdd", "Drop to add"), tint: .accent
            )
        }
        activities.present(activity)
    }

    /// The three things that follow a change to what the shelf holds: republish it, re-clamp the
    /// scroll against a grid that is now a different length, and write it down.
    ///
    /// One method because forgetting any one of them fails quietly. Without the re-clamp the grid
    /// draws a viewport of nothing after the last two files are removed, which reads as the shelf
    /// having emptied itself; without the write, the removal comes back at the next launch.
    private func afterContentsChanged() {
        syncActivity()
        pushScroll(animated: false)
        persist()
    }

    private func persist() {
        store.scheduleSave(shelf.items)
    }

    private func setDropTargeted(_ targeted: Bool) {
        guard shelf.isDropTargeted != targeted else { return }
        shelf.isDropTargeted = targeted
    }

    /// Materialised bytes are never deleted here — see `ShelfStore.cleanUpSession`.
    private func disposeOfEvicted(_ evicted: [ShelfItem]) {
        guard !evicted.isEmpty else { return }
        IslandLog.shelf.info("\(evicted.count) item(s) evicted at capacity \(ShelfContents.capacity)")
    }

    // MARK: - Closing

    private func scheduleAutoCollapse(on screen: IslandScreen) {
        autoCollapse?.cancel()
        autoCollapse = Task { [weak self] in
            try? await Task.sleep(for: Self.autoCollapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.autoCollapse = nil
            // With the pointer still on the island the hover path owns the closing: the user is
            // looking at what they dropped, or reaching for it to drag it out, and closing under
            // them is worse than staying open.
            guard self.screenModel(screen.id)?.isHovering != true else { return }
            self.collapse(screen)
        }
    }

    /// Closes an island **the shelf opened**. An island the user clicked open is left alone.
    private func collapse(_ screen: IslandScreen) {
        guard openedByDrag.remove(screen.id) != nil else { return }
        close(screen)
    }

    private func close(_ screen: IslandScreen) {
        autoCollapse?.cancel()
        autoCollapse = nil
        guard screenModel(screen.id)?.isExpanded == true else { return }
        endSearch(clearing: true)
        setExpanded(screen, false)
    }

    /// Closes an island the user emptied. A shelf with nothing in it has nothing to show, and the
    /// activity has just been dismissed, so leaving the island open would leave it open on nothing.
    private func collapseIfEmpty(_ screen: IslandScreen) {
        guard shelf.isEmpty, !shelf.isDropTargeted else { return }
        openedByDrag.remove(screen.id)
        // `close`, not `collapse`: this one applies however the island came to be open, because the
        // user emptied it from a control drawn on the island itself. There is nothing left to look
        // at, and the activity behind it has just been dismissed.
        close(screen)
    }

    // MARK: - Geometry

    /// Which part of the open shelf a point in the panel's y-down space lands on.
    ///
    /// Resolved against `contentMetrics`, not `metrics`, because that is what the tiles are drawn
    /// against: the content lags the container by `Motion.contentFollowDelay` (§6.2), so asking the
    /// container's target would map a press to where the tile is *going* to be.
    private func region(at point: CGPoint, on screen: IslandScreen) -> ShelfRegion {
        guard let (layout, origin) = resolvedLayout(on: screen) else { return .none }
        let inBody = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        return layout.region(at: inBody, itemCount: shelf.visibleItems.count)
    }

    private func tileFrame(at index: Int, on screen: IslandScreen) -> CGRect? {
        guard let (layout, origin) = resolvedLayout(on: screen),
              layout.tiles.indices.contains(index) else { return nil }
        return layout.tiles[index].offsetBy(dx: origin.x, dy: origin.y)
    }

    /// A tile in **global screen** coordinates, y-up, for the two things that live outside the
    /// panel: QuickLook's zoom origin and the search field's own window.
    ///
    /// The conversion is the one place this file crosses coordinate spaces, and it is written out
    /// rather than folded into a helper elsewhere because getting it wrong is invisible in a test —
    /// a preview that zooms out of the wrong place still shows the right file.
    private func tileScreenFrame(at index: Int, on screen: IslandScreen) -> CGRect? {
        guard let (layout, origin) = resolvedLayout(on: screen),
              layout.tiles.indices.contains(index) else { return nil }
        return screenRect(layout.tiles[index], offsetBy: origin, on: screen)
    }

    private func screenRect(_ rect: CGRect, offsetBy origin: CGPoint, on screen: IslandScreen) -> CGRect {
        let panel = IslandLayout.panelFrame(for: screen)
        let inPanel = rect.offsetBy(dx: origin.x, dy: origin.y)
        return CGRect(
            x: panel.minX + inPanel.minX,
            // The panel is y-down and the screen is y-up, so the rect flips about the panel's top.
            y: panel.maxY - inPanel.maxY,
            width: inPanel.width,
            height: inPanel.height
        )
    }

    /// The items the open menu is about, resolved back through identity.
    ///
    /// By id and not by index, because the shelf can change underneath an open menu — a drop lands,
    /// a promised file arrives — and an index would then name a different file. Anything that has
    /// since been removed simply is not there, which is the honest answer: the menu acts on what is
    /// still on the shelf.
    private func menuItems() -> [ShelfItem] {
        guard let menu = shelf.actionMenu else { return [] }
        let held = Dictionary(uniqueKeysWithValues: shelf.items.map { ($0.id, $0) })
        return menu.itemIDs.compactMap { held[$0] }
    }

    private func actionRegion(at point: CGPoint, on screen: IslandScreen) -> ShelfActionRegion {
        guard let (layout, origin) = resolvedActionLayout(on: screen) else { return .none }
        return layout.region(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    private func resolvedActionLayout(on screen: IslandScreen) -> (ShelfActionLayout, CGPoint)? {
        guard shelf.isPresented,
              let menu = shelf.actionMenu,
              let model = screenModel(screen.id),
              model.contentPresentation == .expanded,
              let layout = ShelfActionLayout.resolve(
                body: model.slotLayout.body,
                rowCount: menu.actions.count,
                offset: shelf.actionScrollTarget.offset
              )
        else { return nil }

        let panelSize = IslandLayout.panelFrame(for: screen).size
        return (layout, IslandLayout.bodyOrigin(for: model.contentMetrics, in: panelSize))
    }

    private func resolvedLayout(on screen: IslandScreen) -> (ShelfLayout, CGPoint)? {
        guard shelf.isPresented,
              let model = screenModel(screen.id),
              model.contentPresentation == .expanded,
              let layout = ShelfLayout.resolve(
                body: model.slotLayout.body,
                slotCount: shelf.slotCount,
                offset: gridScroll.offset
              )
        else { return nil }

        let panelSize = IslandLayout.panelFrame(for: screen).size
        return (layout, IslandLayout.bodyOrigin(for: model.contentMetrics, in: panelSize))
    }

    #if DEBUG
    /// `--shelf-demo`: puts files on the shelf without dragging any.
    ///
    /// Debug only, like every other demo flag, and it goes through the same `insert` a drop does so
    /// that what is looked at is the real path — eviction at capacity included.
    func addForDemo(_ urls: [URL]) {
        disposeOfEvicted(shelf.insert(urls.map { ShelfItem(url: $0) }, reduceMotion: reduceMotion()))
        syncActivity()
    }

    /// `--convert-demo`: the actions menu, open over the first `count` tiles.
    ///
    /// Goes through the same `openMenu` a right click does, so what is looked at is the real path —
    /// including the rule that a menu with nothing on offer is not opened at all.
    func openActionsForDemo(count: Int) {
        actions.openMenu(over: Array(shelf.visibleItems.prefix(max(1, count))))
    }
    #endif
}
