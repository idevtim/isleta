import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The actions menu's geometry and the one press-to-thing mapping it owns.
///
/// The same shape as `ShelfLayoutTests` next door, and against the same body: the menu is drawn in
/// the shelf's own rectangle, so testing it against the default expanded body would test a shape it
/// is never drawn in.
@Suite("Shelf actions layout")
struct ShelfActionLayoutTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    private var shelfBody: CGRect? {
        let cutout = ActivitySlotLayout.cutoutSize(for: screen.notch)
        return ActivitySlotLayout.resolve(
            bodySize: CGSize(
                width: IslandLayout.expandedBodySize.width,
                height: IslandLayout.expandedHeight(
                    contentHeight: ShelfLayout.contentHeight, cutoutHeight: cutout.height
                )
            ),
            cutoutSize: cutout
        ).body
    }

    // MARK: - The rectangle it lives in

    /// The whole design in one assertion: the menu occupies the grid's body and asks for nothing of
    /// its own, so opening it moves no part of the island's outline — no widen-then-tighten, no new
    /// form for `PassThroughSelfTest` to prove, and no way for `islandPath` to be tracking a shape
    /// that is still settling.
    @Test("the menu is drawn inside the shelf's own body and asks for no height of its own")
    func sameRectangle() throws {
        let body = try #require(shelfBody)
        let grid = try #require(ShelfLayout.resolve(body: body, slotCount: 10))
        let menu = try #require(ShelfActionLayout.resolve(body: body, rowCount: 9))
        #expect(menu.body == grid.body)
        #expect(menu.header == grid.header)
        // The way out sits where Clear All does — the trailing-most control on either layer, so the
        // last thing in the strip is always the one that ends what you are doing.
        #expect(menu.back.maxX == grid.clear.maxX)
        #expect(menu.back.minY == grid.clear.minY)
    }

    @Test("the list never draws outside the body")
    func containment() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 20))
        #expect(body.contains(layout.viewport))
        #expect(body.contains(layout.header))
        for row in layout.rows where layout.viewport.intersects(row) {
            #expect(row.minX >= layout.viewport.minX - 0.01)
            #expect(row.maxX <= layout.viewport.maxX + 0.01)
        }
    }

    @Test("no rows, no menu")
    func refusals() throws {
        let body = try #require(shelfBody)
        #expect(ShelfActionLayout.resolve(body: body, rowCount: 0) == nil)
        #expect(ShelfActionLayout.resolve(body: nil, rowCount: 4) == nil)
        // A body too short for the grid is too short for this too, and the answer is the same:
        // draw nothing rather than clip.
        #expect(ShelfActionLayout.resolve(body: CGRect(x: 0, y: 0, width: 368, height: 30), rowCount: 4) == nil)
    }

    // MARK: - Scrolling

    @Test("a menu that fits cannot scroll and draws no indicator")
    func shortMenu() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 3))
        #expect(layout.scrollExtent == 0)
        #expect(layout.indicator() == nil)
        #expect(layout.offset == 0)
    }

    @Test("a long menu scrolls, and the offset is clamped where the extent is known")
    func longMenu() throws {
        let body = try #require(shelfBody)
        let settled = try #require(ShelfActionLayout.resolve(body: body, rowCount: 12))
        #expect(settled.scrollExtent > 0)
        #expect(settled.indicator() != nil)

        let scrolled = try #require(ShelfActionLayout.resolve(body: body, rowCount: 12, offset: 30))
        #expect(scrolled.offset == 30)
        // Drawn rows move by exactly the offset; the content rows do not, because the scroll view
        // applies it. Keeping only one of the two is how a row ends up clickable one place away
        // from where it is drawn.
        #expect(abs(scrolled.rows[0].minY - (settled.rows[0].minY - 30)) < 0.01)
        #expect(scrolled.contentRows == settled.contentRows)

        let overscrolled = try #require(ShelfActionLayout.resolve(body: body, rowCount: 12, offset: 10_000))
        #expect(abs(overscrolled.offset - settled.scrollExtent) < 0.01)
        #expect(try #require(ShelfActionLayout.resolve(body: body, rowCount: 12, offset: -40)).offset == 0)
    }

    // MARK: - What a press lands on

    @Test("the way out is where the grid's last control is")
    func backControl() throws {
        let body = try #require(shelfBody)
        let grid = try #require(ShelfLayout.resolve(body: body, slotCount: 10))
        let menu = try #require(ShelfActionLayout.resolve(body: body, rowCount: 9))
        #expect(menu.back.maxX == grid.header.maxX)
        #expect(menu.back.width == ShelfLayout.searchSide)
    }

    @Test("the header is tested before the list")
    func headerFirst() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 9))
        #expect(layout.region(at: CGPoint(x: layout.back.midX, y: layout.back.midY)) == .back)
        #expect(layout.region(at: CGPoint(x: layout.rows[0].midX, y: layout.rows[0].midY)) == .row(0))
    }

    /// A row scrolled out of sight is at a rect the arithmetic still answers for. Accepting a press
    /// there would let a click on the header run a conversion the user cannot see.
    @Test("a row scrolled out of the viewport is not pressable")
    func scrolledOut() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 12, offset: 60))
        let firstRow = layout.rows[0]
        #expect(!layout.viewport.intersects(firstRow))
        #expect(layout.region(at: CGPoint(x: firstRow.midX, y: firstRow.midY)) != .row(0))
    }

    @Test("a press on the island but not on the menu falls through")
    func background() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 2))
        // Below the last row and inside the viewport is the menu's own empty space, which is not a
        // row and must not be one — a menu of two actions has two clickable things in it.
        let empty = CGPoint(x: layout.viewport.midX, y: layout.viewport.maxY - 1)
        #expect(layout.region(at: empty) == .none)
        #expect(layout.region(at: CGPoint(x: body.minX + 1, y: body.maxY - 1)) == .none)
    }

    @Test("the built window covers the viewport with a row of overscan either side")
    func window() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfActionLayout.resolve(body: body, rowCount: 20, offset: 96))
        let window = layout.visibleRows
        for (index, row) in layout.rows.enumerated() where layout.viewport.intersects(row) {
            #expect(window.contains(index))
        }
        #expect(window.count < 20)
    }
}

@Suite("Shelf actions state")
struct ShelfActionMenuTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    @Test("the header shows a percentage while a job reports one, and the job's name when it does not")
    func jobLabel() {
        #expect(ShelfJobStatus(title: "Transcribe", fraction: nil).label == "Transcribe")
        #expect(ShelfJobStatus(title: "Transcribe", fraction: 0.421).label == "Transcribe · 42%")
        // Clamped, because a route is free to report 1.0000000149 and an island that says 100 % of
        // something and then keeps going reads as broken.
        #expect(ShelfJobStatus(title: "Compress video", fraction: 1.4).label == "Compress video · 100%")
        #expect(ShelfJobStatus(title: "Compress video", fraction: -0.2).label == "Compress video · 0%")
    }

    @Test("the menu says how many files it is about")
    func menuTitle() {
        let one = ShelfActionMenu(itemIDs: [UUID()], actions: [.airDrop])
        let three = ShelfActionMenu(itemIDs: [UUID(), UUID(), UUID()], actions: [.airDrop])
        #expect(one.title == "1 item")
        #expect(three.title == "3 items")
    }

    /// The menu is one layer or the other, never both, and `ShelfLayerView` branches on exactly
    /// this. Two flags would let the island be in a state with a grid and a menu in one rectangle.
    @Test("showing the menu is a value, and clearing it is the grid")
    @MainActor
    func modelState() {
        let shelf = ShelfModel()
        #expect(!shelf.isShowingActions)
        shelf.setActionMenu(
            ShelfActionMenu(itemIDs: [UUID()], actions: [.airDrop, .revealInFinder]),
            reduceMotion: true
        )
        #expect(shelf.isShowingActions)
        #expect(shelf.actionMenu?.actions.count == 2)
        shelf.setActionMenu(nil, reduceMotion: true)
        #expect(!shelf.isShowingActions)
        #expect(shelf.actionMenu == nil)
    }

    /// The grid and the menu scroll independently. A shared offset would put a menu of nine rows
    /// wherever the user had last left a grid of thirty tiles.
    @Test("the two layers keep their own scroll targets")
    @MainActor
    func separateScroll() {
        let shelf = ShelfModel()
        shelf.scrollTarget = shelf.scrollTarget.dragged(to: 40)
        #expect(shelf.actionScrollTarget.offset == 0)
        shelf.actionScrollTarget = shelf.actionScrollTarget.dragged(to: 12)
        #expect(shelf.scrollTarget.offset == 40)
    }

    /// The wand and the magnifier are two controls of the same kind in the same strip, and both are
    /// gated on the shelf having something on it — a wand over an empty shelf opens a menu whose
    /// every row refuses.
    @Test("the wand is a header control that only exists when there is something to act on")
    func wandRegion() throws {
        let cutout = ActivitySlotLayout.cutoutSize(for: screen.notch)
        let body = try #require(
            ActivitySlotLayout.resolve(
                bodySize: CGSize(
                    width: IslandLayout.expandedBodySize.width,
                    height: IslandLayout.expandedHeight(
                        contentHeight: ShelfLayout.contentHeight, cutoutHeight: cutout.height
                    )
                ),
                cutoutSize: cutout
            ).body
        )
        let layout = try #require(ShelfLayout.resolve(body: body, slotCount: 3))
        let point = CGPoint(x: layout.actions.midX, y: layout.actions.midY)
        #expect(layout.region(at: point, itemCount: 3) == .actions)
        #expect(layout.region(at: point, itemCount: 0) == .none)
        // Leading of the magnifier, not over it: two header controls that overlap is a lottery.
        #expect(layout.actions.maxX <= layout.search.minX)
        #expect(!layout.actions.intersects(layout.clear))
    }
}
