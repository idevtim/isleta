import CoreGraphics
import Foundation
import IslandKit
import Testing

@testable import IslandUI

@Suite("Shelf contents")
struct ShelfContentsTests {

    private func item(_ path: String) -> ShelfItem {
        ShelfItem(url: URL(fileURLWithPath: path))
    }

    @Test("items arrive oldest first")
    func ordering() {
        var contents = ShelfContents()
        contents.insert(item("/a.txt"))
        contents.insert(item("/b.txt"))
        #expect(contents.items.map(\.name) == ["a.txt", "b.txt"])
    }

    /// Dropping the same file twice is the user telling us something we already know. A second tile
    /// for one file would be a lie about what the shelf holds, and reordering under a drop the user
    /// thought was a no-op reads as a fault.
    @Test("a file already held is not held twice")
    func duplicates() {
        var contents = ShelfContents()
        contents.insert(item("/a.txt"))
        contents.insert(item("/b.txt"))
        #expect(contents.insert(item("/a.txt")) == .alreadyHeld)
        #expect(contents.count == 2)
        #expect(contents.items.map(\.name) == ["a.txt", "b.txt"], "the shelf reordered under a duplicate")
    }

    /// The same file can reach the pasteboard spelled more than one way. Comparing raw paths would
    /// let `/x/./a.txt` in beside `/x/a.txt`.
    @Test("paths are compared standardised")
    func standardisedPaths() {
        var contents = ShelfContents()
        contents.insert(item("/x/a.txt"))
        #expect(contents.insert(item("/x/./a.txt")) == .alreadyHeld)
    }

    @Test("the oldest leaves when the shelf is full")
    func eviction() {
        var contents = ShelfContents()
        for index in 0..<ShelfContents.capacity {
            contents.insert(item("/\(index).txt"))
        }
        let result = contents.insert(item("/extra.txt"))
        guard case .added(let evicted) = result else {
            Issue.record("a full shelf refused an insertion instead of evicting")
            return
        }
        #expect(evicted?.name == "0.txt")
        #expect(contents.count == ShelfContents.capacity)
        #expect(contents.items.last?.name == "extra.txt")
    }

    @Test("initializing past capacity keeps the newest")
    func initializerClamps() {
        let items = (0..<(ShelfContents.capacity + 3)).map { item("/\($0).txt") }
        let contents = ShelfContents(items: items)
        #expect(contents.count == ShelfContents.capacity)
        #expect(contents.items.first?.name == "3.txt")
    }

    @Test("removing by id, and clearing")
    func removal() {
        var contents = ShelfContents()
        let first = item("/a.txt")
        contents.insert(first)
        contents.insert(item("/b.txt"))

        #expect(contents.remove(id: first.id)?.name == "a.txt")
        #expect(contents.count == 1)
        #expect(contents.removeAll().count == 1)
        #expect(contents.isEmpty)
    }

    /// A missing file keeps its tile rather than vanishing: a tile that disappears on its own is
    /// indistinguishable from a bug, and a tile that says the file is gone is information.
    @Test("a missing file is marked, not dropped")
    func staleness() {
        var contents = ShelfContents()
        let held = item("/a.txt")
        contents.insert(held)
        contents.markStale(id: held.id)

        #expect(contents.count == 1)
        #expect(contents.items[0].isStale)

        contents.relocate(id: held.id, to: URL(fileURLWithPath: "/moved/b.txt"))
        #expect(contents.items[0].isStale == false)
        #expect(contents.items[0].name == "b.txt")
    }

    /// A renewed bookmark is not a relocation. Only one of them is visible, and folding them would
    /// make every renewal look like a move to anything watching for one.
    @Test("a renewed bookmark changes nothing else")
    func bookmarkRenewal() {
        var contents = ShelfContents()
        let held = item("/a.txt")
        contents.insert(held)
        contents.refreshBookmark(id: held.id, to: Data([1, 2, 3]))

        #expect(contents.items[0].bookmark == Data([1, 2, 3]))
        #expect(contents.items[0].name == "a.txt")
        #expect(contents.items[0].isStale == false)
    }

    @Test("moving a tile rearranges the shelf")
    func reorder() {
        var contents = ShelfContents(items: ["a", "b", "c", "d"].map { item("/\($0).txt") })
        var moved = contents.move(from: 0, to: 2)
        #expect(moved)
        #expect(contents.items.map(\.name) == ["b.txt", "c.txt", "a.txt", "d.txt"])

        moved = contents.move(from: 3, to: 0)
        #expect(moved)
        #expect(contents.items.map(\.name) == ["d.txt", "b.txt", "c.txt", "a.txt"])
    }

    /// The pointer sits inside one tile for tens of samples, so "did anything move" is the question
    /// the caller asks before opening an animation transaction, playing a haptic, or scheduling a
    /// write to disk.
    @Test("a move that changes nothing reports so")
    func reorderNoOp() {
        var contents = ShelfContents(items: ["a", "b"].map { item("/\($0).txt") })
        let sameSlot = contents.move(from: 0, to: 0)
        let noSuchSlot = contents.move(from: 5, to: 0)
        #expect(sameSlot == false)
        #expect(noSuchSlot == false)
        #expect(contents.items.map(\.name) == ["a.txt", "b.txt"])
    }

    /// A destination past the end is what the pointer produces on the last row of a part-full grid,
    /// where there are slots drawn and nothing in them.
    @Test("a move past the end lands on the end")
    func reorderClamps() {
        var contents = ShelfContents(items: ["a", "b", "c"].map { item("/\($0).txt") })
        let moved = contents.move(from: 0, to: 99)
        #expect(moved)
        #expect(contents.items.map(\.name) == ["b.txt", "c.txt", "a.txt"])
    }
}

@Suite("Shelf item")
struct ShelfItemTests {

    /// Asked of `UTType` rather than of an extension table, so every spelling of a format resolves
    /// together and the next one Apple ships is not a silent miss.
    @Test("glyphs follow the file's type", arguments: [
        ("png", "photo"), ("jpeg", "photo"), ("heic", "photo"),
        ("mp4", "film"), ("mov", "film"),
        ("mp3", "music.note"),
        ("pdf", "doc.richtext"),
        ("zip", "doc.zipper"),
        ("swift", "chevron.left.forwardslash.chevron.right"),
        ("txt", "doc.text"),
        ("", "doc"),
        ("thereisnosuchformat", "doc"),
    ])
    func symbols(pathExtension: String, expected: String) {
        #expect(ShelfItem.symbolName(forPathExtension: pathExtension) == expected)
    }

    @Test("a name is the file's own, never a path")
    func naming() {
        let item = ShelfItem(url: URL(fileURLWithPath: "/Users/someone/Downloads/receipt.pdf"))
        #expect(item.name == "receipt.pdf")
        #expect(item.symbolName == "doc.richtext")
    }
}

@Suite("Shelf search")
struct ShelfSearchTests {

    private func items(_ names: [String]) -> [ShelfItem] {
        names.map { ShelfItem(url: URL(fileURLWithPath: "/files/\($0)")) }
    }

    @Test("an empty or blank query is not a search")
    func inactive() {
        #expect(ShelfSearch.isActive("") == false)
        #expect(ShelfSearch.isActive("   ") == false)
        #expect(ShelfSearch.isActive("\t\n") == false)
        #expect(ShelfSearch.isActive("a"))

        let held = items(["a.txt", "b.txt"])
        #expect(ShelfSearch.filter(held, query: "  ").count == 2)
    }

    @Test("matching is on the name, and is case insensitive")
    func caseInsensitive() {
        let held = items(["Q3 Report.pdf", "notes.txt"])
        #expect(ShelfSearch.filter(held, query: "report").map(\.name) == ["Q3 Report.pdf"])
        #expect(ShelfSearch.filter(held, query: "REPORT").map(\.name) == ["Q3 Report.pdf"])
    }

    /// `resume` has to find `Résumé.pdf`, or the file is unreachable by any spelling somebody would
    /// type on a keyboard that does not have those keys on it.
    @Test("diacritics do not have to be typed")
    func diacriticInsensitive() {
        let held = items(["Résumé.pdf", "notes.txt"])
        #expect(ShelfSearch.filter(held, query: "resume").map(\.name) == ["Résumé.pdf"])
    }

    /// Every token, in any order. Typing more can only ever narrow, which is the property that makes
    /// a search field feel like it is working — a query that suddenly matched *more* as it grew
    /// would read as a fault.
    @Test("every token must appear, in any order")
    func allTokens() {
        let held = items(["Q3 report.pdf", "report-final.pdf", "Q3 notes.txt"])
        #expect(ShelfSearch.filter(held, query: "report").count == 2)
        #expect(ShelfSearch.filter(held, query: "report q3").map(\.name) == ["Q3 report.pdf"])
        #expect(ShelfSearch.filter(held, query: "q3 report").map(\.name) == ["Q3 report.pdf"])
        #expect(ShelfSearch.filter(held, query: "q3 report missing").isEmpty)
    }

    /// The path is not on screen, so matching it would produce hits with no visible reason — and it
    /// would put the shape of someone's home directory into a search they can see the results of but
    /// not the cause.
    @Test("the path is never matched")
    func pathIsNotSearched() {
        let held = [ShelfItem(url: URL(fileURLWithPath: "/Users/someone/Downloads/receipt.pdf"))]
        #expect(ShelfSearch.filter(held, query: "downloads").isEmpty)
        #expect(ShelfSearch.filter(held, query: "receipt").count == 1)
    }

    /// A filter hides; it does not rearrange. The shelf's order is the user's — they dropped it, and
    /// they can drag it — so ranking the matches would leave them hunting for the file that was
    /// third a moment ago.
    @Test("matches keep the shelf's own order")
    func orderIsPreserved() {
        let held = items(["c report.txt", "a report.txt", "b other.txt", "d report.txt"])
        #expect(ShelfSearch.filter(held, query: "report").map(\.name)
            == ["c report.txt", "a report.txt", "d report.txt"])
    }
}

@Suite("Shelf scroll")
struct ShelfScrollTests {

    private func sample(_ deltaY: CGFloat, phase: IslandScrollSample.Phase = .changed) -> IslandScrollSample {
        IslandScrollSample(phase: phase, deltaX: 0, deltaY: deltaY, isPrecise: true)
    }

    /// A positive `deltaY` is content moving down the screen, which is the grid moving back towards
    /// the file that was dropped first. Getting this backwards would make the island's grid the one
    /// scrollable thing on the machine that runs the wrong way.
    @Test("a scroll moves the grid the way the fingers do")
    func direction() {
        var scroll = ShelfScroll()
        #expect(scroll.consume(sample(-40), extent: 280) == 40)
        #expect(scroll.consume(sample(15), extent: 280) == 25)
    }

    @Test("the offset is clamped to what there is")
    func clamping() {
        var scroll = ShelfScroll()
        #expect(scroll.consume(sample(-1000), extent: 280) == 280)
        #expect(scroll.consume(sample(1000), extent: 280) == 0)
        // A shelf that fits cannot be scrolled at all, which is what makes the indicator and the
        // gesture both disappear without either asking.
        #expect(scroll.consume(sample(-100), extent: 0) == 0)
    }

    /// Removing the last two files, or a search narrowing thirty tiles to one, leaves the offset
    /// pointing past the end at a viewport of nothing — which reads as the shelf having emptied
    /// itself.
    @Test("a grid that got shorter pulls the offset back")
    func reclamping() {
        var scroll = ShelfScroll()
        _ = scroll.consume(sample(-280), extent: 280)
        #expect(scroll.offset == 280)
        #expect(scroll.clamped(to: 70) == 70)
        #expect(scroll.clamped(to: 0) == 0)
    }

    /// A gesture starting is not a request to go back to the top, and the trackpad routinely reports
    /// (0, 0) at `.began` anyway.
    @Test("beginning a gesture does not reset the offset")
    func beganIsNotAReset() {
        var scroll = ShelfScroll()
        _ = scroll.consume(sample(-100), extent: 280)
        let afterBegan = scroll.consume(sample(0, phase: .began), extent: 280)
        #expect(afterBegan == 100)
    }

    /// The newest file is at the *end* of the shelf, unlike the drop history where an arrival is at
    /// the top — so a drop is revealed by scrolling to the extent, not to zero.
    @Test("a drop is revealed at the end")
    func revealingTheEnd() {
        var scroll = ShelfScroll()
        scroll.revealEnd(extent: 280)
        #expect(scroll.offset == 280)
        scroll.reset()
        #expect(scroll.offset == 0)
    }

    /// Two drops in a row both target the same offset, and an `onChange` watching the number alone
    /// would play nothing for the second.
    @Test("a repeated target still arrives as a change")
    func sequenceAdvances() {
        let first = ShelfScrollTarget().revealing(280)
        let second = first.revealing(280)
        #expect(first != second)
        #expect(second.sequence == first.sequence + 1)
        #expect(second.isAnimated)
        #expect(first.dragged(to: 280).isAnimated == false)
    }
}

@Suite("Shelf archive")
struct ShelfArchiveTests {

    private func item(_ path: String, materialised: Bool = false) -> ShelfItem {
        ShelfItem(url: URL(fileURLWithPath: path), bookmark: Data([9]), isMaterialized: materialised)
    }

    /// Bytes received from a file promise live in a directory named for this process, which is
    /// deleted on quit — so an entry pointing into it is guaranteed dead at the next launch. Writing
    /// it anyway would restore a shelf of tiles that are all missing, on a Mac where nothing went
    /// wrong.
    @Test("files Isleta materialised are not written down")
    func materialisedFilesAreDropped() {
        let archive = ShelfArchive.record([
            item("/a.txt"),
            item("/tmp/promise.png", materialised: true),
            item("/b.txt"),
        ])
        #expect(archive.entries.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test("an entry carries the path as well as the bookmark")
    func entriesCarryBothIdentities() {
        let held = item("/Users/someone/receipt.pdf")
        let archive = ShelfArchive.record([held])
        #expect(archive.entries.first?.path == "/Users/someone/receipt.pdf")
        #expect(archive.entries.first?.name == "receipt.pdf")
        #expect(archive.entries.first?.id == held.id)
        #expect(archive.entries.first?.bookmark == Data([9]))
    }

    /// The rule the whole feature turns on: a file that is gone keeps its tile, marked. A tile that
    /// vanished between launches would be indistinguishable from the shelf having failed to load.
    @Test("a file that cannot be found is restored as visibly dead")
    func deadEntriesSurvive() {
        let archive = ShelfArchive.record([item("/a.txt"), item("/gone.txt")])
        let restored = archive.restore { entry in
            entry.path == "/gone.txt" ? nil : URL(fileURLWithPath: entry.path)
        }
        #expect(restored.count == 2)
        #expect(restored[0].isStale == false)
        #expect(restored[1].isStale)
        // Named from what was written down, because a bookmark that failed to resolve has nothing to
        // say about what it used to point at — without the path the tile would be a blank chip.
        #expect(restored[1].name == "gone.txt")
    }

    /// The case bookmarks exist for: the user files the file away after dropping it. The tile takes
    /// the new name too, because a tile saying `screenshot.png` for a file now called `receipt.png`
    /// is worse than one saying nothing.
    @Test("a file that moved is restored where it is now")
    func movedEntriesFollow() {
        let archive = ShelfArchive.record([item("/Downloads/screenshot.png")])
        let restored = archive.restore { _ in URL(fileURLWithPath: "/Filed/receipt.png") }
        #expect(restored[0].url.path == "/Filed/receipt.png")
        #expect(restored[0].name == "receipt.png")
        #expect(restored[0].isStale == false)
    }

    /// Identity survives, so a shelf restored from disk and then reordered writes back entries the
    /// next launch can still match up.
    @Test("identity survives a round trip")
    func roundTrip() throws {
        let held = [item("/a.txt"), item("/b.txt")]
        let data = try ShelfArchive.record(held).encoded()
        let decoded = try #require(try ShelfArchive.decoded(from: data))
        #expect(decoded.entries.map(\.id) == held.map(\.id))
        #expect(decoded.version == ShelfArchive.currentVersion)
    }

    /// A user who has run a later build and gone back is better served by an empty shelf than by one
    /// where half the tiles are wrong — and the record is left alone rather than overwritten, so
    /// going forward again finds it intact.
    @Test("a record from a newer build is refused rather than half-read")
    func newerVersionsAreRefused() throws {
        var archive = ShelfArchive.record([item("/a.txt")])
        archive.version = ShelfArchive.currentVersion + 1
        #expect(try ShelfArchive.decoded(from: archive.encoded()) == nil)
    }

    @Test("a corrupt record throws rather than restoring nonsense")
    func corruptRecordsThrow() {
        #expect(throws: (any Error).self) {
            try ShelfArchive.decoded(from: Data("not json".utf8))
        }
    }
}

@Suite("Shelf layout")
struct ShelfLayoutTests {

    private let screen = IslandScreen(
        id: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    )

    /// The body the *shelf's* island opens to, which is `ShelfLayout.contentHeight` plus the screen's
    /// own cutout — the same arithmetic `AppDelegate.expandedContentHeightForStage` does for it.
    /// Resolving against the default expanded body instead would test a shape the shelf is never
    /// drawn in.
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

    /// The property that replaced "everything the shelf holds is on screen": what is on screen is a
    /// whole number of rows, and everything else is **reachable** — the extent covers it exactly.
    @Test("the open island shows two full rows and can reach the rest")
    func viewportAndExtent() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: ShelfContents.capacity))
        #expect(layout.columns == 5)
        #expect(layout.rows == ShelfLayout.visibleRows)
        #expect(layout.viewport.height == ShelfLayout.rowsExtent(rowCount: ShelfLayout.visibleRows))
        #expect(layout.tiles.count == ShelfContents.capacity)

        let rows = ShelfContents.capacity / layout.columns
        #expect(layout.contentExtent == ShelfLayout.rowsExtent(rowCount: rows))
        #expect(layout.scrollExtent == layout.contentExtent - layout.viewport.height)
        #expect(layout.scrollExtent > 0, "a full shelf that cannot scroll is a shelf with hidden files")
    }

    /// A shelf that fits scrolls not at all, which is what makes the indicator and the gesture both
    /// disappear on a short shelf without either asking.
    @Test("a shelf that fits has nothing to scroll and no indicator")
    func shortShelvesDoNotScroll() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 4))
        #expect(layout.scrollExtent == 0)
        #expect(layout.indicator() == nil)
        #expect(layout.visibleSlots == 0..<4)
    }

    /// Tiles must stay inside the island body, because everything drawn is masked to the island
    /// outline: a tile that overhung would not merely look wrong, it would be sliced by the mask.
    @Test("nothing on screen is laid out outside the island body")
    func staysInsideTheBody() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfLayout.resolve(body: body, slotCount: ShelfContents.capacity))

        #expect(body.contains(layout.header))
        #expect(body.contains(layout.viewport))
        for index in layout.visibleSlots where layout.tiles[index].intersects(layout.viewport) {
            let tile = layout.tiles[index]
            #expect(body.contains(tile), "tile \(index) at \(tile) escapes the body \(body)")
        }
    }

    /// The badge used to hang half outside the chip, which is right for a single row and wrong the
    /// moment the grid scrolls: a scroll view's clipping is exact, so the top row's badge was drawn
    /// with its top sliced off.
    @Test("the remove badge is inside the tile it belongs to")
    func badgesAreInsideTheirTiles() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 3))
        for index in 0..<3 {
            let badge = try #require(layout.removeBadge(at: index))
            #expect(layout.tiles[index].contains(badge))
            #expect(layout.viewport.contains(badge))
        }
    }

    @Test("a body too short for a row of tiles draws nothing at all")
    func refusesToClip() {
        let short = CGRect(x: 0, y: 0, width: 368, height: ShelfLayout.minimumBodyHeight - 1)
        #expect(ShelfLayout.resolve(body: short, slotCount: 1) == nil)
        #expect(ShelfLayout.resolve(body: nil, slotCount: 1) == nil)
        #expect(ShelfLayout.resolve(body: short, slotCount: 0) == nil)
    }

    /// A narrower island shows fewer columns correctly rather than a row that runs off the shape and
    /// gets sliced into half-tiles by the mask; a shorter one shows one row and scrolls more.
    @Test("a narrow or short island shows fewer tiles rather than clipped ones")
    func degradesGracefully() throws {
        let narrow = CGRect(x: 0, y: 0, width: 160, height: 178)
        let layout = try #require(ShelfLayout.resolve(body: narrow, slotCount: ShelfContents.capacity))
        #expect(layout.columns == 2)
        #expect(narrow.contains(layout.viewport))

        let short = CGRect(x: 0, y: 0, width: 368, height: ShelfLayout.minimumBodyHeight)
        let shortLayout = try #require(ShelfLayout.resolve(body: short, slotCount: 10))
        #expect(shortLayout.rows == 1)
        #expect(short.contains(shortLayout.viewport))
    }

    /// The badge sits on top of the tile, so the point belongs to the badge. Testing tiles first
    /// would make the remove control unclickable while looking completely correct on screen.
    @Test("a remove badge wins over the tile it sits on")
    func badgeBeatsTile() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 2))
        let badge = try #require(layout.removeBadge(at: 0))

        #expect(layout.region(at: CGPoint(x: badge.midX, y: badge.midY), itemCount: 2) == .remove(0))
        #expect(layout.region(at: CGPoint(x: layout.tiles[0].midX, y: layout.tiles[0].maxY - 4), itemCount: 2) == .tile(0))
        #expect(layout.region(at: CGPoint(x: layout.tiles[1].midX, y: layout.tiles[1].midY), itemCount: 2) == .tile(1))
    }

    /// The drop placeholder is a slot with no item behind it. It must not offer a remove badge for
    /// something that is not there.
    @Test("the drop placeholder has nothing to remove")
    func placeholderHasNoBadge() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 2))
        let badge = try #require(layout.removeBadge(at: 1))
        #expect(layout.region(at: CGPoint(x: badge.midX, y: badge.midY), itemCount: 1) == .tile(1))
    }

    @Test("the header's two controls answer for themselves")
    func headerControls() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 1))
        let clear = CGPoint(x: layout.clear.midX, y: layout.clear.midY)
        let search = CGPoint(x: layout.search.midX, y: layout.search.midY)

        #expect(layout.region(at: clear, itemCount: 1) == .clear)
        #expect(layout.region(at: search, itemCount: 1) == .search)
        // Clear is only offered when there is something to clear. Search stays reachable either way
        // — it is drawn beside the count, and an empty shelf simply has nothing to find.
        #expect(layout.region(at: clear, itemCount: 0) == .none)
        #expect(layout.region(at: search, itemCount: 0) == .search)
        #expect(layout.clear.intersects(layout.search) == false, "the two header controls overlap")
    }

    /// Everything else on the island is a click on the island, and must stay one — otherwise the
    /// shelf would quietly stop the island collapsing when the user clicks it.
    @Test("empty island is not a shelf control")
    func emptySpaceFallsThrough() throws {
        let body = try #require(shelfBody)
        let layout = try #require(ShelfLayout.resolve(body: body, slotCount: 1))
        #expect(layout.region(at: CGPoint(x: body.minX + 2, y: body.maxY - 2), itemCount: 1) == .none)
    }

    // MARK: - Scrolled

    /// The whole of what an offset has to do: the tiles move up by exactly it, and the rects the hit
    /// test uses move with them. A layout that scrolled the drawing and not the arithmetic is a tile
    /// that is clickable one row from where it is drawn.
    @Test("the offset moves the tiles and the hit test together")
    func offsetMovesEverything() throws {
        let settled = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30))
        let scrolled = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30, offset: 70))

        #expect(scrolled.offset == 70)
        #expect(scrolled.tiles[0].minY == settled.tiles[0].minY - 70)
        #expect(scrolled.contentTiles == settled.contentTiles, "the unscrolled rects moved")

        // Row 1 is now where row 0 was, so a press at the first row's position lands on slot 5.
        let firstRow = CGPoint(x: settled.tiles[0].midX, y: settled.tiles[0].midY)
        #expect(settled.region(at: firstRow, itemCount: 30) == .tile(0))
        #expect(scrolled.region(at: firstRow, itemCount: 30) == .tile(5))
    }

    @Test("the offset is clamped to what the grid can scroll")
    func offsetIsClamped() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30, offset: 10_000))
        #expect(layout.offset == layout.scrollExtent)
        #expect(try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30, offset: -50)).offset == 0)
    }

    /// A tile scrolled out of sight is at a rect the arithmetic still answers for. Accepting a press
    /// there would let a click on the header remove a file the user cannot see.
    @Test("a press outside the viewport is not a press on a tile")
    func pressesOutsideTheViewportAreRefused() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30, offset: 70))
        // Slot 0 has been scrolled above the viewport; its rect is still computable.
        let scrolledAway = CGPoint(x: layout.tiles[0].midX, y: layout.tiles[0].midY)
        #expect(layout.viewport.contains(scrolledAway) == false)
        #expect(layout.region(at: scrolledAway, itemCount: 30) == .none)
    }

    /// The window `ShelfLayerView` builds views for: what is visible, plus a row either side so a
    /// tile does not pop into existence at the edge of the viewport mid-scroll.
    @Test("only the slots near the viewport are worth building")
    func visibleSlotsAreBounded() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 30, offset: 140))
        let visible = layout.visibleSlots
        #expect(visible.count < 30, "every tile is being built on a grid six rows deep")
        for slot in visible where layout.tiles[slot].intersects(layout.viewport) {
            #expect(slot >= visible.lowerBound && slot < visible.upperBound)
        }
        // Everything actually on screen is in the window — the failure this guards against is a hole
        // in the middle of the grid rather than a slow one.
        for (slot, tile) in layout.tiles.enumerated() where tile.intersects(layout.viewport) {
            #expect(visible.contains(slot), "slot \(slot) is on screen and would not be built")
        }
    }

    /// A reorder target is not the same question as "what is under the pointer": the gaps between
    /// tiles and the run past the last one are still positions, or a drag would stop rearranging for
    /// the 8pt it is over nothing.
    @Test("a reorder snaps to a slot, including in the gaps")
    func reorderTargets() throws {
        let layout = try #require(ShelfLayout.resolve(body: shelfBody, slotCount: 12))
        let firstTile = layout.tiles[0]

        #expect(layout.reorderTarget(at: CGPoint(x: firstTile.midX, y: firstTile.midY), itemCount: 12) == 0)
        // The gap between the first two tiles belongs to one of them, not to nothing.
        let gap = CGPoint(x: firstTile.maxX + ShelfLayout.tileGap / 2, y: firstTile.midY)
        #expect(layout.reorderTarget(at: gap, itemCount: 12) != nil)
        // The slot under the pointer is a slot on **screen**: row 2 of twelve items is scrolled
        // away at rest, so the far corner of the viewport is slot 9 and not slot 11.
        let corner = CGPoint(x: layout.viewport.maxX - 2, y: layout.viewport.maxY - 2)
        #expect(layout.reorderTarget(at: corner, itemCount: 12) == 9)

        // Scrolled to the end, that same corner is in the last row — which holds two of five — and
        // the empty slots beside them clamp back onto the last item rather than being refused. That
        // is the case a part-full grid produces on every reorder that ends at the bottom.
        let scrolled = try #require(
            ShelfLayout.resolve(body: shelfBody, slotCount: 12, offset: layout.scrollExtent)
        )
        let end = CGPoint(x: scrolled.viewport.maxX - 2, y: scrolled.viewport.maxY - 2)
        #expect(scrolled.reorderTarget(at: end, itemCount: 12) == 11)
        // Off the grid altogether is the one case with no answer.
        #expect(layout.reorderTarget(at: CGPoint(x: 0, y: 0), itemCount: 12) == nil)
        #expect(layout.reorderTarget(at: CGPoint(x: firstTile.midX, y: firstTile.midY), itemCount: 0) == nil)
    }
}

@Suite("Shelf model")
@MainActor
struct ShelfModelTests {

    private func item(_ path: String) -> ShelfItem {
        ShelfItem(url: URL(fileURLWithPath: path))
    }

    @Test("a drop targeted empty shelf still has a slot to draw")
    func placeholderSlot() {
        let model = ShelfModel()
        #expect(model.slotCount == 0)

        model.isDropTargeted = true
        #expect(model.slotCount == 1, "an empty island opened by a drag would show nothing at all")

        model.insert([item("/a.txt")], reduceMotion: true)
        #expect(model.slotCount == 2)
    }

    /// A full shelf under a drag must not offer a slot for a file it would have to evict something
    /// to take.
    @Test("a full shelf offers no placeholder")
    func placeholderStopsAtCapacity() {
        let model = ShelfModel()
        model.isDropTargeted = true
        model.insert((0..<ShelfContents.capacity).map { item("/\($0).txt") }, reduceMotion: true)
        #expect(model.slotCount == ShelfContents.capacity)
    }

    @Test("inserting reports what was evicted")
    func eviction() {
        let model = ShelfModel()
        model.insert((0..<ShelfContents.capacity).map { item("/\($0).txt") }, reduceMotion: true)
        let evicted = model.insert([item("/extra.txt")], reduceMotion: true)
        #expect(evicted.map(\.name) == ["0.txt"])
    }

    @Test("removing the last item empties the shelf")
    func emptying() {
        let model = ShelfModel()
        let held = item("/a.txt")
        model.insert([held], reduceMotion: true)
        #expect(model.isEmpty == false)
        #expect(model.remove(id: held.id, reduceMotion: true)?.name == "a.txt")
        #expect(model.isEmpty)
    }

    /// Every index the view and the hit test speak in is an index into what is *on screen*, so a
    /// filter has to move them together — a tile index that meant something different to the two
    /// would remove the wrong file.
    @Test("a query narrows what the island shows, and the slots with it")
    func filtering() {
        let model = ShelfModel()
        model.insert(["a report.txt", "b other.txt", "c report.txt"].map { item("/\($0)") }, reduceMotion: true)

        #expect(model.isSearching == false)
        model.setQuery("report", reduceMotion: true)
        #expect(model.isSearching)
        #expect(model.visibleItems.map(\.name) == ["a report.txt", "c report.txt"])
        #expect(model.slotCount == 2)
        #expect(model.visibleItem(at: 1)?.name == "c report.txt")
        // The shelf still holds everything: a filter hides, it does not remove.
        #expect(model.count == 3)

        model.setQuery("", reduceMotion: true)
        #expect(model.isSearching == false)
        #expect(model.slotCount == 3)
    }

    /// The two are genuinely different states: the field can be up with nothing typed, and a filter
    /// can be live with the field gone — which is what Return does.
    @Test("the field being open and a filter being live are separate")
    func searchOpenAndSearching() {
        let model = ShelfModel()
        model.insert([item("/a.txt")], reduceMotion: true)

        model.isSearchOpen = true
        #expect(model.isSearching == false)
        model.setQuery("a", reduceMotion: true)
        model.isSearchOpen = false
        #expect(model.isSearching)
    }

    @Test("a query change tells the shell, so the scroll can follow it")
    func queryChangesAreAnnounced() {
        let model = ShelfModel()
        var changes = 0
        model.onQueryChanged = { changes += 1 }

        model.setQuery("a", reduceMotion: true)
        #expect(changes == 1)
        // The same string twice is not a change. A field that reported one per keystroke regardless
        // would reset the scroll under a user who pressed a modifier key.
        model.setQuery("a", reduceMotion: true)
        #expect(changes == 1)
    }

    @Test("a tile is moved by identity, so a rearranged shelf still names the right file")
    func reorderByIdentity() {
        let model = ShelfModel()
        let items = ["a", "b", "c"].map { item("/\($0).txt") }
        model.insert(items, reduceMotion: true)

        #expect(model.move(id: items[0].id, to: 2, reduceMotion: true))
        #expect(model.items.map(\.name) == ["b.txt", "c.txt", "a.txt"])
        #expect(model.move(id: items[0].id, to: 2, reduceMotion: true) == false)
        #expect(model.move(id: UUID(), to: 0, reduceMotion: true) == false)
    }

    @Test("a restored shelf replaces whatever was there")
    func restoring() {
        let model = ShelfModel()
        model.insert([item("/old.txt")], reduceMotion: true)
        model.restore([item("/a.txt"), item("/b.txt")])
        #expect(model.items.map(\.name) == ["a.txt", "b.txt"])
    }
}
