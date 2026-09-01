import Foundation
import Observation
import SwiftUI

/// What the shelf is holding and what it is doing, for the whole app.
///
/// **One instance, not one per screen** — the same reason `ActivityCoordinator` is app-wide. There
/// is one user holding one thing; a shelf per display would let the laptop and the external monitor
/// hold different files and there would be no answer to which one "the shelf" is. What genuinely
/// differs per screen is geometry, and that is `IslandScreenModel`.
///
/// The contents live here rather than in the app shell's `ShelfStore`, which is the layer that
/// touches the pasteboard and the filesystem. The shell owns the *bytes*; this owns the *list*, and
/// there is exactly one of it — a store that kept its own copy and pushed it here would be two
/// answers to "what is on the shelf", which is the failure `IslandPresentation` exists to prevent
/// one layer up.
@MainActor
@Observable
public final class ShelfModel {

    public private(set) var contents = ShelfContents()

    /// A drag is over the island right now.
    ///
    /// Not a presentation state and deliberately not modelled as one: `IslandPresentation` says how
    /// big the island is, and the island being open to receive a drop is the same `.expanded` it is
    /// open in for any other reason. This is what the *content* says while that is true — "Drop to
    /// add" instead of a count, and a placeholder tile where the file will land.
    public var isDropTargeted = false

    /// Whether the shelf is the activity currently on stage.
    ///
    /// Pushed in by the app shell from `ActivityCoordinator.presented`, because the shelf can be
    /// preempted: a volume HUD is `.interrupting` and takes the island from a `.standard` shelf
    /// mid-drag. Without this the shelf's tiles would draw straight over the HUD that displaced it.
    public var isPresented = false

    /// What the user has typed into the header's search field, or empty for no search.
    public private(set) var query = ""

    /// Whether the search field is on the island and holding the keyboard.
    ///
    /// **Separate from `isSearching`, and the two are genuinely different states.** The field can be
    /// up with nothing typed in it (the moment after the magnifier is clicked), and a filter can be
    /// live with the field gone — that is what Return does: keep these matches, give the keyboard
    /// back. Folding them would mean either a filter that cannot survive the field closing, or a
    /// panel that holds key for as long as a query is set, which is the one thing
    /// `IslandPanel.acceptsKeyboardInput` must never be asked to do.
    ///
    /// Set by the app shell rather than here, because taking key is the shell's to arrange (see
    /// `ShelfController.beginSearch`) and a flag that could be true while no panel had key would be
    /// a caret nobody can type into.
    public var isSearchOpen = false

    /// Where the grid should be sitting, and whether it should travel there.
    ///
    /// Pushed in by the app shell, which owns the one `ShelfScroll` for the same reason it owns one
    /// `NowPlayingController`: two islands showing the same shelf must be looking at the same part of
    /// it. See `ShelfScrollTarget` for why this is a value rather than a `CGFloat`.
    public var scrollTarget = ShelfScrollTarget()

    /// Return was pressed in the search field. Set by the app shell, which is the only layer that
    /// can give the keyboard back — see `ShelfController.submitSearch`.
    public var onSubmitSearch: (() -> Void)?

    /// The query changed. Set by the app shell, which owns the scroll offset that a change to the
    /// query invalidates — every keystroke changes how long the grid is.
    public var onQueryChanged: (() -> Void)?

    /// The actions menu the island is showing, or nil for the grid.
    ///
    /// **One layer or the other, never both**, which is what lets the menu live in the shelf's own
    /// body rectangle and change nothing about the island's outline — see `ShelfActionLayout`. It is
    /// a value rather than a flag because every row's meaning depends on *which files the menu is
    /// about*, and a flag cannot carry that.
    public private(set) var actionMenu: ShelfActionMenu?

    /// Where the actions list should be sitting. Its own target, not the grid's: the two layers
    /// scroll independently and a shared offset would put a menu of nine rows wherever the user had
    /// left a grid of thirty tiles.
    public var actionScrollTarget = ShelfScrollTarget()

    /// Whether the drop actions are switched on (`SourceToggles.dropActions`).
    ///
    /// Pushed in by the app shell, which owns the configuration. Off means the wand is not drawn and
    /// the right click does nothing — not a menu of rows that refuse, which is the shape of "off"
    /// that makes a user think the feature is broken rather than absent.
    public var areDropActionsEnabled = true

    /// What the island is working on, drawn in the header while the shelf is open.
    ///
    /// Pushed in by the app shell, which owns the worker. Nil when nothing is running, which is the
    /// state that puts the item count back.
    public var job: ShelfJobStatus?

    /// The item the user is holding, mid-reorder, or nil.
    ///
    /// The identifier rather than the index, because the index is exactly what a reorder changes:
    /// the array is rearranged live under the pointer (see `ShelfController.pressDragged`), so a
    /// stored index would name a different file after the first move.
    public var reorderingID: UUID?

    public var items: [ShelfItem] { contents.items }
    public var isEmpty: Bool { contents.isEmpty }
    public var count: Int { contents.count }

    public init() {}

    /// Whether a query is narrowing what is on screen. See `ShelfSearch.isActive`.
    public var isSearching: Bool { ShelfSearch.isActive(query) }

    /// What the island is actually showing: the whole shelf, or the matches for a live query.
    ///
    /// **Every index the view and the hit test speak in is an index into this**, never into
    /// `contents.items`. `ShelfController` converts at the one boundary where it has to — a reorder,
    /// which is refused while searching precisely because the conversion has no honest answer there
    /// (see `ShelfContents.move`).
    public var visibleItems: [ShelfItem] {
        ShelfSearch.filter(contents.items, query: query)
    }

    /// Tiles to lay out: everything on screen, plus one placeholder while a drag is over the island.
    ///
    /// The placeholder is what makes an *empty* shelf legible. Without it the island opens on a
    /// drag to show a header and nothing else, which reads as an island that opened for no reason
    /// rather than as a place to put the thing being dragged.
    public var slotCount: Int {
        visibleItems.count + (isDropTargeted && contents.count < ShelfContents.capacity ? 1 : 0)
    }

    /// The item behind a tile index, resolved through the filter.
    public func visibleItem(at index: Int) -> ShelfItem? {
        let items = visibleItems
        return items.indices.contains(index) ? items[index] : nil
    }

    /// Sets the query, animating whatever appears and disappears as a result.
    ///
    /// `Motion.contentSwap` — the token for "the same thing, saying something new" (§6.2). Filtering
    /// is not the island arriving and not a nudge: the shape does not move (`ShelfLayout.contentHeight`
    /// is a constant precisely so that it cannot), and what changes is which tiles are in it.
    ///
    /// The field writes through here rather than binding `query` directly, which is what keeps the
    /// animation with the state it belongs to. A `TextField($shelf.query)` would put a
    /// `withAnimation` — or worse, an inline `.animation` — in the view, once per keystroke.
    public func setQuery(_ query: String, reduceMotion: Bool) {
        guard query != self.query else { return }
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            self.query = query
        }
        onQueryChanged?()
    }

    /// Whether the actions menu is the layer on screen.
    public var isShowingActions: Bool { actionMenu != nil }

    /// Puts the actions menu up, or takes it away.
    ///
    /// `Motion.contentSwap` — the token for "the same thing, saying something new" (§6.2) — because
    /// that is exactly what this is: the island's shape does not move (`ShelfLayout.contentHeight` is
    /// a constant precisely so it cannot), and what changes is which layer is inside it. Using
    /// `Motion.expand` here would put the island-arriving curve on a swap that arrives nowhere.
    public func setActionMenu(_ menu: ShelfActionMenu?, reduceMotion: Bool) {
        guard menu != actionMenu else { return }
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            actionMenu = menu
        }
    }

    /// Moves a tile, by identity, to a slot in the **whole** shelf.
    ///
    /// Returns whether anything moved, so the caller can tell a real reorder — which is worth an
    /// animation and a write to disk — from the pointer crossing back onto the slot it is already
    /// in, which happens continuously while a tile is being held.
    @discardableResult
    public func move(id: UUID, to destination: Int, reduceMotion: Bool) -> Bool {
        guard let source = contents.index(of: id) else { return false }
        var moved = false
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            moved = contents.move(from: source, to: destination)
        }
        return moved
    }

    /// Adds items, returning whatever was evicted to make room so the caller can dispose of any
    /// bytes it owns.
    ///
    /// Animated on `Motion.contentSwap`, which is the token for "the same thing, saying something
    /// new" (§6.2). A drop does not change the island's *shape* unless it is the first item — that
    /// transition belongs to the activity arriving, and it travels on `Motion.expand` through
    /// `ActivityChange.presented`. Using `expand` here as well would put two curves on one event.
    @discardableResult
    public func insert(_ incoming: [ShelfItem], reduceMotion: Bool) -> [ShelfItem] {
        var evicted: [ShelfItem] = []
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            for item in incoming {
                if case .added(let gone) = contents.insert(item), let gone {
                    evicted.append(gone)
                }
            }
        }
        return evicted
    }

    @discardableResult
    public func remove(id: UUID, reduceMotion: Bool) -> ShelfItem? {
        var removed: ShelfItem?
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            removed = contents.remove(id: id)
        }
        return removed
    }

    @discardableResult
    public func removeAll(reduceMotion: Bool) -> [ShelfItem] {
        var removed: [ShelfItem] = []
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            removed = contents.removeAll()
        }
        return removed
    }

    public func markStale(id: UUID) {
        contents.markStale(id: id)
    }

    public func relocate(id: UUID, to url: URL) {
        contents.relocate(id: id, to: url)
    }

    public func refreshBookmark(id: UUID, to bookmark: Data?) {
        contents.refreshBookmark(id: id, to: bookmark)
    }

    /// Adopts a shelf read back from disk.
    ///
    /// Un-animated on purpose, and it is not an oversight that this is the one mutation here with
    /// no `withAnimation` around it. Every other one is a thing the user just did; this one runs
    /// before the first island frame, and a spring played against a view that has never been drawn
    /// is a spring nobody sees — worse, it would leave the tiles arriving a beat after the island
    /// on the one launch where the user has not touched anything.
    public func restore(_ items: [ShelfItem]) {
        contents = ShelfContents(items: items)
    }
}
