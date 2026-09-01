import CoreGraphics
import Foundation
import IslandActivities

/// What a press on the shelf's actions menu landed on.
///
/// The same shape as `ShelfRegion` and for the same reason: the menu is drawn by SwiftUI and
/// hit-tested by `IslandHitTestView`, so the mapping from a point to a thing has to be a value both
/// sides can hold.
public enum ShelfActionRegion: Equatable, Sendable {

    /// The control that puts the grid back.
    case back

    /// The action at this index into what is on screen.
    case row(Int)

    /// The island, but nothing on it.
    case none
}

/// Where the actions menu's rows and controls sit inside the open island.
///
/// ## It is drawn in the shelf's own body rectangle, and that is the whole design
///
/// `ShelfLayout.contentHeight` is a constant — `islandPath` has to track a *settled* shape, so the
/// island must not grow with the sixth file — and this layer honors the same constant rather than
/// asking for a height of its own. Opening the menu therefore changes **nothing** about the island's
/// outline: no widen-then-tighten, no new form for `PassThroughSelfTest` to prove, no transition at
/// all. What changes is which of two layers is drawn inside a rectangle that was already agreed.
///
/// That is also why the menu scrolls rather than growing: a shelf of images offers nine actions and
/// a body four rows tall, and the answer to "more rows than fit" is the one the grid already
/// established — a viewport, an indicator, and `ShelfScroll`.
///
/// All rects are in the island body's y-down space, like `ShelfLayout`'s.
public struct ShelfActionLayout: Equatable, Sendable {

    /// One row: a glyph well and a label.
    ///
    /// 28pt, which is four rows plus their gaps inside the 130pt the grid's two rows of tiles
    /// occupy — so the menu fills exactly the space the tiles vacated with nothing left over and
    /// nothing clipped. A row the height of a tile (60pt) would show two actions and look like a
    /// list that had failed to load.
    public static let rowHeight: CGFloat = 28

    public static let rowGap: CGFloat = 4

    /// The glyph well at the leading edge of a row.
    public static let symbolWidth: CGFloat = 22

    public static let symbolSpacing: CGFloat = 8

    public static let rowCornerRadius: CGFloat = 8

    /// The back control, square, at the trailing end of the header.
    ///
    /// **Where Clear All sits on the grid**, which is the trailing-most control on either layer —
    /// so the last thing in the strip is always the one that ends what you are doing. It is
    /// deliberately *not* the wand's own position: a control that both opened and closed the menu
    /// would have to be in a place the menu can also draw, and the header's leading half is the one
    /// that says what the menu is about.
    public static let backSide: CGFloat = ShelfLayout.searchSide

    public let body: CGRect
    public let header: CGRect
    public let back: CGRect

    /// The rectangle the rows are seen through. A press outside it is not a press on a row however
    /// close the arithmetic says it is.
    public let viewport: CGRect

    /// How far the list is scrolled, in points.
    public let offset: CGFloat

    /// Every row **as drawn** — the offset is already taken off. What a press is tested against.
    public let rows: [CGRect]

    /// The same rows before the offset, which is what the view lays out inside its scroll view.
    /// Keeping only one of the two and deriving the other at the call site is how a row ends up
    /// clickable one place away from where it is drawn.
    public let contentRows: [CGRect]

    public static func resolve(body: CGRect?, rowCount: Int, offset: CGFloat = 0) -> Self? {
        guard let body, rowCount > 0 else { return nil }
        guard body.height >= ShelfLayout.minimumBodyHeight else { return nil }
        let available = body.width - 2 * ShelfLayout.horizontalPadding
        guard available > 0 else { return nil }

        let header = CGRect(
            x: body.minX + ShelfLayout.horizontalPadding,
            y: body.minY + ShelfLayout.headerTopPadding,
            width: available,
            height: ShelfLayout.headerHeight
        )
        let back = CGRect(
            x: header.maxX - backSide,
            y: header.minY,
            width: backSide,
            height: header.height
        )
        let viewport = CGRect(
            x: header.minX,
            y: header.maxY + ShelfLayout.headerGap,
            width: available,
            height: max(0, body.maxY - ShelfLayout.bottomPadding - (header.maxY + ShelfLayout.headerGap))
        )
        guard viewport.height >= rowHeight else { return nil }

        let extent = max(0, rowsExtent(rowCount: rowCount) - viewport.height)
        let scrolled = min(max(0, offset), extent)

        let contentRows = (0..<rowCount).map { index in
            CGRect(
                x: viewport.minX,
                y: viewport.minY + CGFloat(index) * (rowHeight + rowGap),
                width: viewport.width,
                height: rowHeight
            )
        }

        return Self(
            body: body,
            header: header,
            back: back,
            viewport: viewport,
            offset: scrolled,
            rows: contentRows.map { $0.offsetBy(dx: 0, dy: -scrolled) },
            contentRows: contentRows
        )
    }

    /// How tall `rowCount` rows are, gaps included.
    public static func rowsExtent(rowCount: Int) -> CGFloat {
        let rows = max(0, rowCount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
    }

    public var contentExtent: CGFloat { Self.rowsExtent(rowCount: rows.count) }

    /// How far this list can scroll. Zero for a menu that fits, which is what makes the indicator
    /// and the gesture both disappear without either asking.
    public var scrollExtent: CGFloat { max(0, contentExtent - viewport.height) }

    /// The rows worth building a view for: everything intersecting the viewport, plus one either
    /// side. The same window `ShelfLayout.visibleSlots` computes, for the same reason — and out of
    /// the same value, so there is nothing for it to disagree with.
    public var visibleRows: Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let pitch = Self.rowHeight + Self.rowGap
        let first = max(0, Int((offset / pitch).rounded(.down)) - 1)
        let last = Int(((offset + viewport.height) / pitch).rounded(.down)) + 1
        let lower = min(rows.count, first)
        let upper = min(rows.count, last + 1)
        return lower..<max(lower, upper)
    }

    /// The scroll indicator, in the same gutter the grid's uses.
    public func indicator() -> (length: CGFloat, top: CGFloat)? {
        let extent = scrollExtent
        guard extent > 0 else { return nil }
        let length = max(
            ShelfLayout.indicatorMinimumLength,
            viewport.height * (viewport.height / contentExtent)
        )
        let travel = viewport.height - length
        let progress = min(max(0, offset / extent), 1)
        return (length, travel * progress)
    }

    /// What a point in the island body's y-down space lands on.
    ///
    /// The header is tested before the list, and the list only inside the viewport: a row scrolled
    /// out of sight is at a rect the arithmetic still answers for, and accepting a press there
    /// would let a click on the header run a conversion the user cannot see.
    public func region(at point: CGPoint) -> ShelfActionRegion {
        if back.contains(point) { return .back }
        guard viewport.contains(point) else { return .none }
        for (index, row) in rows.enumerated() where row.contains(point) {
            return .row(index)
        }
        return .none
    }
}

/// The menu the island is showing, and what it is about.
///
/// Held as a value on `ShelfModel` rather than as a set of flags, because "which files is this menu
/// for" is the question every row's meaning depends on and a flag cannot answer it. The identifiers
/// rather than the items: the shelf can change underneath an open menu — a drop lands, a file is
/// removed — and an index or a copy would then act on something else.
public struct ShelfActionMenu: Equatable, Sendable {

    /// The items this menu acts on, by identity.
    public let itemIDs: [UUID]

    /// What the rows are, already narrowed to what applies to every one of those items. See
    /// `DropAction.menu(for:)`.
    public let actions: [DropAction]

    public init(itemIDs: [UUID], actions: [DropAction]) {
        self.itemIDs = itemIDs
        self.actions = actions
    }

    /// What the header says while this menu is up.
    public var title: String {
        islandText("shelf.itemCount", "\(itemIDs.count) items")
    }

    public var isEmpty: Bool { actions.isEmpty }
}

/// A running job, as the shelf's header draws it.
///
/// The shelf's own copy of what the `fileAction` activity says, and it exists because of where the
/// island is looking: while the shelf is **open** the flanks are not on screen at all, so the
/// activity's progress — which is drawn in the trailing sliver of the *collapsed* island — is
/// invisible to exactly the person who just asked for the work. The header says it instead, in the
/// place the item count already occupies, so the island neither grows nor gains a second surface.
public struct ShelfJobStatus: Equatable, Sendable {

    /// What is being done, in the menu's own words.
    public let title: String

    /// 0...1, or nil where the route cannot report one — the same distinction `FileActionStage`
    /// makes, and for the same reason: a bar sitting at zero for the whole job is a worse lie than
    /// an indeterminate one.
    public let fraction: Double?

    public init(title: String, fraction: Double?) {
        self.title = title
        self.fraction = fraction
    }

    /// What the header line reads. A percentage where there is one, because the header is one short
    /// line of text and a bar in it would be a second control in a place that has room for neither.
    public var label: String {
        guard let fraction else { return title }
        // `.percent` rather than a hand-written `%`, and that is a correctness fix rather than a
        // translation: French and German put a no-break space before the sign and the old string
        // never could. The rounding is unchanged — a whole percent, never a fraction of one.
        let percent = min(max(0, fraction), 1)
            .formatted(.percent.precision(.fractionLength(0)))
        return islandText("shelf.job.progress", "\(title) · \(percent)")
    }
}
