import CoreGraphics

/// What a press on the open shelf landed on.
///
/// The shelf is drawn by SwiftUI but hit-tested by `IslandHitTestView`, which is in IslandKit and
/// knows nothing about tiles. So the mapping from a point to a thing has to be a value both sides
/// can hold: the app shell asks this, and hands IslandKit either a dragging item or a "consumed".
///
/// **Not a SwiftUI gesture, and that is deliberate.** The panel never becomes key (§4.1), so
/// SwiftUI's gesture system — which expects a key window and a first responder — is the route by
/// which "the first click sometimes does nothing" gets into an app like this. `IslandHitTestView`
/// already handles clicks for the same reason, and having the shelf's controls go through the same
/// path means there is one answer to "is this point on the island", not two that can disagree.
///
/// The drop history next door *does* use SwiftUI `Button`s and they work — `hitTest` returns
/// `super.hitTest`, so the hosting view gets first refusal and only what it declines bubbles to
/// `IslandHitTestView.mouseDown`. The shelf still does not, and the reason is the tiles rather than
/// the buttons: a press on a tile has to be able to become an AppKit dragging session begun from
/// *that* mouse-down event, so the press is already ours before anything is decided. Two mechanisms
/// for two controls sitting 8pt apart is how a header ends up with one control that works when the
/// island is settled and one that works when it is not.
public enum ShelfRegion: Equatable, Sendable {

    /// The tile at this index **into what is on screen** — the filtered items while a search is
    /// live, the whole shelf otherwise. `ShelfController` resolves it back to an item; nothing here
    /// knows that a filter exists.
    ///
    /// Indices beyond the visible items are the drop placeholder, which is drawn while a drag is
    /// over an island that has room for it.
    case tile(Int)

    /// The remove badge on the tile at this index.
    case remove(Int)

    /// The magnifier in the header: begins a search, or ends the one that is running.
    case search

    /// The wand in the header: opens the actions menu over what is on screen.
    ///
    /// **Over what is on screen, not over the whole shelf**, which is the one place a live search
    /// has a consequence other than hiding tiles — and a deliberate one. A user who has typed `png`
    /// and then asks to convert is asking about the matches; offering them the other twenty-seven
    /// files would be answering a question they narrowed on purpose.
    case actions

    /// The clear-everything control in the header.
    case clear

    /// The island, but nothing on it. The click falls through to the island's own behavior, which
    /// is to collapse.
    case none
}

/// Where the shelf's tiles and controls sit inside the open island.
///
/// Pure geometry, resolved from the body region `ActivitySlotLayout` has already carved out of the
/// island (everything below the cutout). It never invents space: if the body is too small for a
/// row of tiles, `resolve` returns nil and the shelf draws nothing rather than clipping.
///
/// All rects are in the **island body's** y-down space, the same space `ActivitySlotLayout` uses.
/// The caller offsets by `IslandLayout.bodyOrigin` to get to the panel.
///
/// ## The grid scrolls, and this owns both halves of that
///
/// `tiles` are the rects **as drawn**, with the scroll offset already taken off, and they are what
/// a press is tested against. `contentTiles` are the same rects before the offset, which is what
/// `ShelfLayerView` lays out inside its `ScrollView` — the view is scrolled by the scroll view and
/// the hit test is scrolled by arithmetic, and the two agree because they come from one function.
/// Keeping only one of them and deriving the other at the call site is how a tile ends up clickable
/// one row away from where it is drawn.
public struct ShelfLayout: Equatable, Sendable {

    /// One tile: a 50pt chip with a 10pt name under it.
    ///
    /// 50 is not a taste: five of them plus four 8pt gaps plus 2×18pt of padding is 318pt against
    /// the 368pt expanded island, which leaves 25pt of gutter each side for the scroll indicator
    /// without reserving a lane on the tiles themselves — the thing `DropHistoryLayout.indicatorLane`
    /// has to do, because its rows are full width and this grid is centerd.
    public static let tileSize = CGSize(width: 50, height: 60)

    /// The chip itself, inside the tile. The remaining height is the name.
    public static let chipHeight: CGFloat = 44

    public static let tileGap: CGFloat = 8

    /// Air between rows. Larger than `tileGap` because the vertical run already carries the file
    /// names, and 8pt between a name and the chip under it reads as one crowded column rather than
    /// as two rows.
    public static let rowGap: CGFloat = 10

    /// Matches `ActivityContentView`'s expanded inset, so the shelf's header sits on the same
    /// left margin as every other expanded activity.
    public static let horizontalPadding: CGFloat = 18

    /// The strip above the grid: what the shelf is holding, the magnifier, and Clear All.
    ///
    /// 22pt, which is `DropHistoryLayout.headerHeight` — the two headers carry the same kind of control
    /// in the same place and the eye reads them as one piece of chrome, so they are one number
    /// rather than two that happen to agree today.
    public static let headerHeight: CGFloat = 22

    public static let headerTopPadding: CGFloat = 10
    public static let headerGap: CGFloat = 8
    public static let bottomPadding: CGFloat = 8

    /// The Clear All capsule, at the size `DropHistoryLayerView` draws its own.
    public static let clearWidth: CGFloat = 62

    /// The magnifier, square.
    public static let searchSide: CGFloat = 22

    /// Air between the two header controls.
    public static let headerControlGap: CGFloat = 6

    /// The badge that removes one item. Big enough to hit at the top of the screen, small enough
    /// not to cover the glyph it sits on.
    public static let removeBadgeSize: CGFloat = 15

    /// How many rows of tiles the open island shows at once.
    ///
    /// Two. Three would be 70pt more island hanging under the notch for a surface the user is
    /// mostly passing files through, and the shelf is the one activity that can be on stage for
    /// hours. What is off screen is reachable — `ShelfScroll` scrolls it, the indicator says there
    /// is more, and `ShelfSearch` finds it by name — which is the whole of what the old
    /// everything-is-visible capacity rule was protecting.
    public static let visibleRows = 2

    public static let indicatorWidth: CGFloat = 2

    public static let indicatorMinimumLength: CGFloat = 20

    /// The shortest body a shelf can be drawn in: padding, header, gap, one row of tiles, padding.
    public static var minimumBodyHeight: CGFloat {
        headerTopPadding + headerHeight + headerGap + tileSize.height + bottomPadding
    }

    /// What the open island opens to for the shelf, below the cutout.
    ///
    /// A **constant**, like `NowPlayingExpandedLayout`'s and unlike a notification's, and that is
    /// the rule `IslandLayout` writes down rather than a preference: `islandPath` has to track a
    /// settled shape, so a body that grew with the sixth file would move the clickable region under
    /// a pointer that is mid-drag. The grid scrolls inside a fixed rectangle instead — which is
    /// also why a search, which changes how many tiles there are, changes nothing about the island.
    public static var contentHeight: CGFloat {
        headerTopPadding + headerHeight + headerGap + rowsExtent(rowCount: visibleRows) + bottomPadding
    }

    /// How tall `rowCount` rows of tiles are, gaps included.
    public static func rowsExtent(rowCount: Int) -> CGFloat {
        let rows = max(0, rowCount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * rowGap
    }

    public let body: CGRect
    public let header: CGRect
    public let search: CGRect

    /// The wand, square, immediately leading of the magnifier. Same size as it, because the two are
    /// the same kind of control — a mode the header enters — and a wider one would read as the more
    /// important of the two.
    public let actions: CGRect

    public let clear: CGRect

    /// The rectangle the grid is seen through. Everything outside it is scrolled away, and a press
    /// outside it is not a press on a tile however close the arithmetic says it is.
    public let viewport: CGRect

    public let columns: Int

    /// How many rows this body has room for — `visibleRows`, or fewer on an island too short.
    public let rows: Int

    /// How far the grid has been scrolled up, in points.
    public let offset: CGFloat

    /// Every slot, in the order they are held, **as drawn** — the offset is already taken off.
    public let tiles: [CGRect]

    /// The same slots before the offset, which is what the view lays out inside its scroll view.
    public let contentTiles: [CGRect]

    /// - Parameters:
    ///   - body: the drawable region below the cutout, from `ActivitySlotLayout.body`.
    ///   - slotCount: tiles to place — what the shelf is showing, plus one for the drop placeholder
    ///     while a drag is over the island.
    ///   - offset: how far the grid is scrolled, from `ShelfScroll`. Clamped here as well as there,
    ///     because the extent depends on the layout this call is producing — a caller cannot clamp
    ///     against a number it does not have yet.
    public static func resolve(body: CGRect?, slotCount: Int, offset: CGFloat = 0) -> Self? {
        guard let body, slotCount > 0 else { return nil }
        guard body.height >= minimumBodyHeight else { return nil }

        let available = body.width - 2 * horizontalPadding
        guard available >= tileSize.width else { return nil }

        // How many tiles this island can actually show across, rather than how many were asked for.
        // The expanded island fits five; a narrower island — a future smaller expanded size, or a
        // display so narrow the panel is clamped — shows fewer and shows them correctly, instead of
        // a row that runs off the edge of the shape and gets sliced into half-tiles by the mask.
        let columns = max(1, Int((available + tileGap) / (tileSize.width + tileGap)))

        // Rows are the same question asked vertically. A body one row tall is a shelf that scrolls
        // more, not a shelf that draws over its own header.
        let forRows = body.height - headerTopPadding - headerHeight - headerGap - bottomPadding
        let rows = max(1, min(visibleRows, Int((forRows + rowGap) / (tileSize.height + rowGap))))

        let rowWidth = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * tileGap
        let gridX = body.midX - rowWidth / 2
        let gridY = body.minY + headerTopPadding + headerHeight + headerGap

        let header = CGRect(
            x: body.minX + horizontalPadding,
            y: body.minY + headerTopPadding,
            width: available,
            height: headerHeight
        )
        let clear = CGRect(
            x: header.maxX - clearWidth,
            y: header.minY,
            width: clearWidth,
            height: header.height
        )
        let search = CGRect(
            x: clear.minX - headerControlGap - searchSide,
            y: header.minY,
            width: searchSide,
            height: header.height
        )
        let actions = CGRect(
            x: search.minX - headerControlGap - searchSide,
            y: header.minY,
            width: searchSide,
            height: header.height
        )
        let viewport = CGRect(
            x: gridX,
            y: gridY,
            width: rowWidth,
            height: rowsExtent(rowCount: rows)
        )

        let usedRows = Int((slotCount + columns - 1) / columns)
        let extent = max(0, rowsExtent(rowCount: usedRows) - viewport.height)
        let scrolled = min(max(0, offset), extent)

        let contentTiles = (0..<slotCount).map { index in
            CGRect(
                x: gridX + CGFloat(index % columns) * (tileSize.width + tileGap),
                y: gridY + CGFloat(index / columns) * (tileSize.height + rowGap),
                width: tileSize.width,
                height: tileSize.height
            )
        }

        return Self(
            body: body,
            header: header,
            search: search,
            actions: actions,
            clear: clear,
            viewport: viewport,
            columns: columns,
            rows: rows,
            offset: scrolled,
            tiles: contentTiles.map { $0.offsetBy(dx: 0, dy: -scrolled) },
            contentTiles: contentTiles
        )
    }

    /// How tall the grid would be with every slot drawn at once.
    public var contentExtent: CGFloat {
        Self.rowsExtent(rowCount: Int((tiles.count + columns - 1) / columns))
    }

    /// How far this grid can scroll. Zero for a shelf that fits, which is what makes the indicator
    /// and the gesture both disappear on a short shelf without either asking.
    public var scrollExtent: CGFloat {
        max(0, contentExtent - viewport.height)
    }

    /// The slots worth building a view for: everything intersecting the viewport, plus a row either
    /// side.
    ///
    /// **Slicing the array by hand, which `DropHistoryLayerView` explicitly refuses to do** — and the
    /// difference is where the arithmetic lives. There, a hand-sliced window would be a second
    /// place that knows how tall a row is, free to disagree with `DropHistoryLayout`; here the window
    /// and the rects come out of the same value, so there is nothing for it to disagree with. It is
    /// worth having for the reason that file records: building every row up front is what dropped
    /// frames on the island's one animated list, and thirty tiles is well past the count where that
    /// started to show.
    ///
    /// The row of overscan is what stops a tile popping into existence at the edge of the viewport
    /// mid-scroll.
    public var visibleSlots: Range<Int> {
        guard !tiles.isEmpty else { return 0..<0 }
        let rowHeight = Self.tileSize.height + Self.rowGap
        let firstRow = max(0, Int((offset / rowHeight).rounded(.down)) - 1)
        let lastRow = Int(((offset + viewport.height) / rowHeight).rounded(.down)) + 1
        let lower = min(tiles.count, firstRow * columns)
        let upper = min(tiles.count, (lastRow + 1) * columns)
        return lower..<max(lower, upper)
    }

    /// The scroll indicator down the trailing edge of the body: a thumb whose length says how much
    /// shelf there is and whose position says where in it you are.
    ///
    /// Returns nil when everything fits, so a shelf of three files draws no chrome at all.
    public func indicator() -> (length: CGFloat, top: CGFloat)? {
        let extent = scrollExtent
        guard extent > 0 else { return nil }
        // Proportional, with a floor, for the reason `DropHistoryLayout.indicator` has one: a shelf six
        // rows deep in a two-row viewport would otherwise draw a thumb a few points long, which
        // reads as a speck of dust on a black island rather than as a control.
        let length = max(Self.indicatorMinimumLength, viewport.height * (viewport.height / contentExtent))
        let travel = viewport.height - length
        let progress = min(max(0, offset / extent), 1)
        return (length, travel * progress)
    }

    /// The remove badge for a tile: the chip's top-right corner, **inside** it.
    ///
    /// It used to hang half outside, so that it read as attached to the tile rather than drawn on
    /// the file. That was right for a single row on open island and is wrong the moment the grid
    /// scrolls: the top row's badge then overhangs the viewport by 3pt, and a scroll view's
    /// clipping is exact — so the badge on the row the user is most likely to aim at was drawn with
    /// its top sliced off. Inside costs a little of the glyph and nothing else.
    public func removeBadge(at index: Int) -> CGRect? {
        guard tiles.indices.contains(index) else { return nil }
        let tile = tiles[index]
        let size = Self.removeBadgeSize
        return CGRect(x: tile.maxX - size, y: tile.minY, width: size, height: size)
    }

    /// The same rect before the scroll offset, for the view — which draws inside the scroll view and
    /// must not apply the offset twice.
    public func contentRemoveBadge(at index: Int) -> CGRect? {
        removeBadge(at: index)?.offsetBy(dx: 0, dy: offset)
    }

    /// What a point in the island body's y-down space lands on.
    ///
    /// The header is tested before the grid, and the grid only inside the viewport: a tile scrolled
    /// out of sight is at a rect that arithmetic still answers for, and accepting a press there
    /// would let a click on the header remove a file the user cannot see.
    ///
    /// Remove badges are tested before tiles because they overlap them: the badge is the smaller,
    /// more specific target and it sits on top, so the point belongs to whichever is drawn last.
    /// Testing tiles first would make the badge unclickable while looking completely correct.
    ///
    /// - Parameter itemCount: how many of the slots hold a real item. Slots past it are the drop
    ///   placeholder, which is not draggable and has nothing to remove.
    public func region(at point: CGPoint, itemCount: Int) -> ShelfRegion {
        if search.contains(point) { return .search }
        // Both header controls are gated on there being something on screen, for the reason the
        // view draws neither on an empty shelf: a wand that opens a menu of rows that all refuse is
        // worse than an empty corner.
        if itemCount > 0, actions.contains(point) { return .actions }
        if itemCount > 0, clear.contains(point) { return .clear }
        guard viewport.contains(point) else { return .none }

        for index in tiles.indices where index < itemCount {
            if let badge = removeBadge(at: index), badge.contains(point) { return .remove(index) }
        }
        for (index, tile) in tiles.enumerated() where tile.contains(point) {
            return .tile(index)
        }
        return .none
    }

    /// The slot a reorder in progress would drop into, for a point in the body's y-down space.
    ///
    /// Deliberately **not** `region(at:)`. That one answers "what is under the pointer", and during
    /// a reorder the honest answer for the gaps between tiles and for the run past the last one is
    /// still a position: a drag that crosses a gap must not stop rearranging for the 8pt it is over
    /// nothing. So this snaps to the nearest column and row and clamps into the shelf, and returns
    /// nil only when the pointer has left the viewport altogether — which is the one case where
    /// there genuinely is no answer.
    public func reorderTarget(at point: CGPoint, itemCount: Int) -> Int? {
        guard itemCount > 0, viewport.contains(point) else { return nil }
        let column = Int((point.x - viewport.minX) / (Self.tileSize.width + Self.tileGap))
        let row = Int((point.y - viewport.minY + offset) / (Self.tileSize.height + Self.rowGap))
        let slot = row * columns + min(max(0, column), columns - 1)
        return min(max(0, slot), itemCount - 1)
    }
}
