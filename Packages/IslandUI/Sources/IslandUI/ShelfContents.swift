import Foundation

/// What one insertion did. Returned rather than inferred so the caller — which owns the bytes of a
/// materialised file — can tell "already here" from "added, and something fell off the end".
public enum ShelfInsertion: Equatable, Sendable {

    /// The item went on the shelf. `evicted` is whatever had to leave to make room for it.
    case added(evicted: ShelfItem?)

    /// The shelf already holds this file. Nothing moved.
    ///
    /// Deliberately not "added again": re-dropping a file the shelf already has must not produce a
    /// second tile for one file, and must not reorder the shelf either. A user who drops something
    /// twice has told us nothing new, and a row of tiles that reshuffles under a drop the user
    /// thought was a no-op reads as a fault.
    case alreadyHeld
}

/// The shelf's contents, as a value.
///
/// Pure and free of AppKit, Foundation I/O and SwiftUI, for the same reason `ActivityStack` is: the
/// rules about capacity, duplicates and eviction are the part that is easy to get subtly wrong and
/// impossible to check by looking at a running island. The app shell owns the bytes; this owns the
/// list.
public struct ShelfContents: Equatable, Sendable {

    /// How many things the shelf holds at once.
    ///
    /// **Thirty, and the rule this replaces was "however many are visible at once".** Through 1.4.x
    /// the capacity was five, and the argument for it was a good one: the island cannot grow to fit
    /// more (a body whose size followed its contents would move the hit region on every drop and
    /// never settle — `IslandLayout` says why), so a shelf holding more than it draws would be a
    /// place things get lost. The flank would count seven while the island showed five, and the
    /// other two would be reachable by no gesture at all.
    ///
    /// That argument was never about the number; it was about **reachability**, and the viewport
    /// answers it. `ShelfLayout` now scrolls (`ShelfScroll`), so every item is reachable, has an
    /// indicator saying how much shelf there is, and can be found by name (`ShelfSearch`). What the
    /// island shows at once is two rows of five; what the shelf holds is six rows of five.
    ///
    /// Thirty rather than unbounded, and the ceiling is not arbitrary either. Every item is a
    /// bookmark that is written to disk on every change and resolved on every launch, so an
    /// unbounded shelf is an unbounded launch cost against §9's 300ms — and a shelf someone has
    /// dropped four hundred files into is a folder with worse tools, not a workbench.
    ///
    /// Dropping a thirty-first evicts the oldest, which costs the user nothing: what is evicted is a
    /// *reference*, and the file is still where they left it.
    public static let capacity = 30

    public private(set) var items: [ShelfItem]

    public init(items: [ShelfItem] = []) {
        self.items = Array(items.suffix(Self.capacity))
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Adds an item, oldest first, evicting the oldest when the shelf is full.
    ///
    /// Identity is the file's path, not the `ShelfItem.id`: two drops of the same file arrive as
    /// two freshly minted items and are the same thing to the user. Compared through
    /// `standardizedFileURL`, which folds away `.`, `..` and a trailing slash without touching the
    /// filesystem — resolving symlinks here would be more thorough and would make this function's
    /// answer depend on the machine it runs on, which is exactly what a pure value type must not do.
    @discardableResult
    public mutating func insert(_ item: ShelfItem) -> ShelfInsertion {
        let key = Self.key(for: item.url)
        guard !items.contains(where: { Self.key(for: $0.url) == key }) else { return .alreadyHeld }

        var evicted: ShelfItem?
        if items.count >= Self.capacity {
            evicted = items.removeFirst()
        }
        items.append(item)
        return .added(evicted: evicted)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ShelfItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    public mutating func removeAll() -> [ShelfItem] {
        defer { items = [] }
        return items
    }

    /// Records that an item's file is gone. Kept on the shelf rather than removed, because a tile
    /// vanishing on its own is indistinguishable from a bug; a tile that says the file is missing
    /// is information.
    public mutating func markStale(id: UUID, _ isStale: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isStale = isStale
    }

    /// Replaces an item's location after its bookmark resolved somewhere new.
    public mutating func relocate(id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].url = url
        items[index].name = url.lastPathComponent
        items[index].isStale = false
    }

    /// Replaces an item's bookmark, after the one on file was reported stale and remade.
    ///
    /// Separate from `relocate` because the two are not the same event and only one of them is
    /// visible: a file that moved changes the tile's name, and a bookmark that was merely *renewed*
    /// changes nothing on screen. Folding them would make every renewal look like a relocation to
    /// anything watching for one.
    public mutating func refreshBookmark(id: UUID, to bookmark: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bookmark = bookmark
    }

    /// Moves one item to another position, as a reorder does.
    ///
    /// Indices into `items`, which is the **whole** shelf and never a filtered view of it. A search
    /// is a lens over the same array, and a move expressed in the lens's indices has no honest
    /// meaning in the array underneath — dropping between the second and third *match* says nothing
    /// about where that is among thirty items. `ShelfController` refuses to start a reorder while a
    /// query is live for exactly that reason, and this signature is the reason it has to.
    ///
    /// Returns whether anything moved, so the caller can tell a real reorder from the pointer
    /// crossing back onto the tile it started on — which happens continuously during a drag and
    /// must not open an animation transaction or schedule a write each time.
    @discardableResult
    public mutating func move(from source: Int, to destination: Int) -> Bool {
        guard items.indices.contains(source) else { return false }
        let clamped = min(max(0, destination), items.count - 1)
        guard clamped != source else { return false }
        let item = items.remove(at: source)
        items.insert(item, at: clamped)
        return true
    }

    /// Where an item sits in the whole shelf, or nil if it has been removed under the caller.
    public func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    public func item(at index: Int) -> ShelfItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
