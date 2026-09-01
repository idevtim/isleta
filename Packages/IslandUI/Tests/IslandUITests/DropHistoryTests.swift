import Foundation
import IslandKit
import Testing
@testable import IslandUI

@Suite("Drop history layout")
struct DropHistoryLayoutTests {

    /// **The rule this surface has to keep**, and the one the Up Next bug broke earlier today: the
    /// height is agreed before the transition and cannot move while the surface is up. Making it a
    /// constant is how that is enforced rather than remembered — there is no row count to pass in,
    /// so there is no flag whose staleness could answer the wrong height on the way out.
    @Test("The height does not depend on what is in the list")
    func heightIsAConstant() {
        let height = DropHistoryLayout.contentHeight
        #expect(height > 0)
        // Stated arithmetic, so a change to any one number has to be a deliberate change to this.
        #expect(
            height == DropHistoryLayout.topPadding
                + DropHistoryLayout.headerHeight
                + DropHistoryLayout.headerSpacing
                + DropHistoryLayout.viewportHeight
                + DropHistoryLayout.bottomPadding
        )
    }

    /// `contentHeight` and `rowsHeight(inContentHeight:)` are the same arithmetic asked in opposite
    /// directions. `DropHistoryLayerView.viewport` records what happens when the two are allowed to
    /// drift: the last row is sliced in half by the island's own bottom edge and every test passes.
    @Test("rowsHeight is the exact inverse of contentHeight")
    func inverseAgrees() {
        #expect(
            DropHistoryLayout.rowsHeight(inContentHeight: DropHistoryLayout.contentHeight)
                == DropHistoryLayout.viewportHeight
        )
    }

    @Test("It fits inside the island the panel was built for")
    func fitsTheMaximumIsland() {
        // The panel is created once at max expanded bounds and never resized (§4.2), so a surface
        // asking for more than this is a surface that would be clipped by the shape rather than one
        // that makes the island bigger.
        #expect(
            DropHistoryLayout.contentHeight
                <= IslandLayout.maxExpandedBodySize.height
        )
    }

    @Test("A list that fits draws no indicator, and a longer one does")
    func indicatorAppearsOnlyWhenThereIsMore() {
        #expect(DropHistoryLayout.scrollExtent(rowCount: DropHistoryLayout.visibleRows) == 0)
        #expect(DropHistoryLayout.indicator(offset: 0, rowCount: DropHistoryLayout.visibleRows) == nil)

        let full = DropHistoryModel.capacity
        #expect(DropHistoryLayout.scrollExtent(rowCount: full) > 0)
        let top = DropHistoryLayout.indicator(offset: 0, rowCount: full)
        #expect(top != nil)
        #expect(top?.top == 0)
        // Never a speck: forty rows in a four-row viewport is a thumb of a few points without the
        // floor, which reads as dust on a black island rather than as a control.
        #expect((top?.length ?? 0) >= DropHistoryLayout.indicatorMinimumLength)

        let bottom = DropHistoryLayout.indicator(
            offset: DropHistoryLayout.scrollExtent(rowCount: full), rowCount: full
        )
        #expect((bottom?.top ?? 0) > (top?.top ?? 0))
        // And it does not run off the end of its own track.
        #expect((bottom?.top ?? 0) + (bottom?.length ?? 0) <= DropHistoryLayout.viewportHeight + 0.001)
    }

    @Test("An empty list has no rows to scroll")
    func emptyListDoesNotScroll() {
        #expect(DropHistoryLayout.contentExtent(rowCount: 0) == 0)
        #expect(DropHistoryLayout.scrollExtent(rowCount: 0) == 0)
        #expect(DropHistoryLayout.indicator(offset: 0, rowCount: 0) == nil)
    }
}

@Suite("Drop history entries")
struct DropHistoryEntryTests {

    private func entry(
        action: DropHistoryAction = .convert,
        title: String = "Convert to JPEG",
        offerID: String? = "imageEncode.JPEG.jpg",
        sources: [String] = ["/tmp/holiday.heic"],
        results: [String] = ["/tmp/holiday.jpg"],
        link: String? = nil,
        failure: String? = nil,
        finishedAt: Date = Date()
    ) -> DropHistoryEntry {
        DropHistoryEntry(
            action: action,
            title: title,
            offerID: offerID,
            sources: sources.map { DropHistoryFile(path: $0) },
            results: results.map { DropHistoryFile(path: $0) },
            link: link,
            failure: failure,
            finishedAt: finishedAt
        )
    }

    /// The question the list answers is "where did the new file go", so the result comes first. The
    /// source was never lost.
    @Test("A click reveals what the work produced, falling back to what it was given")
    func revealsTheResultFirst() {
        #expect(entry().fileToReveal?.name == "holiday.jpg")
        #expect(entry(results: []).fileToReveal?.name == "holiday.heic")
        #expect(entry(sources: [], results: []).fileToReveal == nil)
    }

    @Test("A row says one thing: a name, a count, a link, or why it failed")
    func detailIsOneLine() {
        #expect(entry().detail == "holiday.jpg")
        #expect(entry(results: ["/tmp/a.jpg", "/tmp/b.jpg"]).detail == "2 files")
        #expect(entry(action: .airDrop, offerID: nil, results: []).detail == "holiday.heic")
        #expect(entry(link: "https://example.com/x").detail == "https://example.com/x")
        // The failure outranks everything, because it is the answer to the question somebody
        // scanning this list is actually asking.
        #expect(entry(failure: "That file cannot be opened").detail == "That file cannot be opened")
    }

    @Test("A failed row is drawn as a failure rather than as the work it was")
    func failureChangesTheGlyph() {
        #expect(entry().symbol == DropHistoryAction.convert.symbol)
        #expect(entry(failure: "nope").symbol == "exclamationmark.triangle.fill")
        #expect(!entry(failure: "nope").succeeded)
    }

    /// The three actions that raised a picker or a panel cannot be repeated: running one "again"
    /// would put a modal window on screen from a list somebody is reading, which is not a repeat of
    /// anything the user did.
    @Test("Only the actions that took no answer from the user can be run again")
    func onlyUnattendedWorkRepeats() {
        #expect(entry(action: .convert).canRunAgain)
        #expect(entry(action: .transcribe, offerID: "transcribe.Text.txt").canRunAgain)
        #expect(entry(action: .compress, offerID: "mediaHEVC.HEVC.mp4").canRunAgain)
        #expect(!entry(action: .airDrop, offerID: nil).canRunAgain)
        #expect(!entry(action: .copyToFolder, offerID: nil).canRunAgain)
        #expect(!entry(action: .moveToFolder, offerID: nil).canRunAgain)
        // A conversion with nothing recorded to act on offers no button — better than a button that
        // raises an error.
        #expect(!entry(action: .convert, sources: []).canRunAgain)
        #expect(!entry(action: .convert, offerID: nil).canRunAgain)
        // A failed conversion is the case the button is most wanted for.
        #expect(entry(failure: "That folder cannot be written to").canRunAgain)
    }

    /// Every action has a glyph and every one of them is an SF Symbol name (§6.5). The list is
    /// `CaseIterable` so a case added later cannot arrive without one.
    @Test("Every action has a glyph")
    func everyActionHasAGlyph() {
        for action in DropHistoryAction.allCases {
            #expect(!action.symbol.isEmpty)
        }
    }
}

@Suite("Drop history model")
@MainActor
struct DropHistoryModelTests {

    private func entry(at date: Date, link: String? = nil, failure: String? = nil) -> DropHistoryEntry {
        DropHistoryEntry(
            action: link == nil ? .convert : .shareLink,
            title: link == nil ? "Convert to JPEG" : "Copy Link",
            sources: [DropHistoryFile(path: "/tmp/x.heic")],
            link: link,
            failure: failure,
            finishedAt: date
        )
    }

    @Test("Newest first, and the oldest is what falls off the end")
    func evictsTheOldest() {
        let model = DropHistoryModel()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(DropHistoryModel.capacity + 5) {
            model.record(entry(at: start.addingTimeInterval(Double(index))), reduceMotion: true)
        }
        #expect(model.count == DropHistoryModel.capacity)
        // Recorded newest-last above and inserted at the head, so the head is the most recent.
        #expect(model.entries.first?.finishedAt == start.addingTimeInterval(Double(DropHistoryModel.capacity + 4)))
        // And the five oldest are gone rather than the five newest.
        #expect(model.entries.last?.finishedAt == start.addingTimeInterval(5))
    }

    /// The two rules are enforced in different places on purpose. Recording is not allowed to
    /// consult the wall clock, or a machine whose clock has just been corrected — and any test
    /// holding a fixed date — would find the list silently discarding what it was told to remember.
    @Test("Recording enforces capacity and never the age rule")
    func recordDoesNotAgeOut() {
        let model = DropHistoryModel()
        let ancient = entry(at: Date().addingTimeInterval(-DropHistoryModel.retention * 4))
        model.record(ancient, reduceMotion: true)
        #expect(model.count == 1)
        #expect(model.entry(id: ancient.id) != nil)
    }

    /// Both eviction rules run on the way back in as well as on the way in, so a record written by a
    /// build with a larger capacity — or left on a disk over a long absence — cannot come back
    /// longer or older than this build allows.
    @Test("Restoring applies capacity and retention rather than trusting the file")
    func restoreEnforcesBothRules() {
        let model = DropHistoryModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = (0..<10).map { entry(at: now.addingTimeInterval(-Double($0) * 60)) }
        // Comfortably past the edge rather than on it. `retention` is a `>` and an entry landing
        // exactly on the boundary is kept, which is a correct answer to an ambiguous question and a
        // terrible thing for a test to depend on either way.
        let ancient = (0..<10).map {
            entry(at: now.addingTimeInterval(-DropHistoryModel.retention - 60 - Double($0) * 60))
        }
        model.restore(fresh + ancient, now: now)
        #expect(model.count == 10)
        #expect(model.entries.allSatisfy { now.timeIntervalSince($0.finishedAt) <= DropHistoryModel.retention })

        let tooMany = (0..<(DropHistoryModel.capacity * 2)).map {
            entry(at: now.addingTimeInterval(-Double($0)))
        }
        model.restore(tooMany, now: now)
        #expect(model.count == DropHistoryModel.capacity)
        // Sorted newest-first regardless of the order the file happened to be in.
        #expect(model.entries.first?.finishedAt == now)
    }

    /// `ShortcutAction.copyLastLink` is the reason this list is written to disk at all, so what it
    /// reads has to be exactly right in both directions.
    @Test("The last link is the newest successful one, and a failure is not one")
    func lastLinkIgnoresFailures() {
        let model = DropHistoryModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(model.lastLink == nil)

        model.record(entry(at: now.addingTimeInterval(-120), link: "https://example.com/first"), reduceMotion: true)
        #expect(model.lastLink == "https://example.com/first")

        // A conversion in between must not become "the last link".
        model.record(entry(at: now.addingTimeInterval(-60)), reduceMotion: true)
        #expect(model.lastLink == "https://example.com/first")

        // A share that failed has a reason and no link, and must not answer either.
        model.record(
            DropHistoryEntry(
                action: .shareLink,
                title: "Copy Link",
                failure: "That link could not be made",
                finishedAt: now
            ),
            reduceMotion: true
        )
        #expect(model.lastLink == "https://example.com/first")

        model.record(entry(at: now, link: "https://example.com/second"), reduceMotion: true)
        #expect(model.lastLink == "https://example.com/second")
    }

    /// The row is where "that disk isn't connected" is said, and it is not persisted and does not
    /// survive the surface being closed — the fact it carries is temporary, and a row that went on
    /// saying it after the disk came back would be worse than silence.
    @Test("An unreachable file marks its own row, and the mark is transient")
    func unavailableIsPerRowAndTransient() {
        let model = DropHistoryModel()
        let one = entry(at: Date())
        model.record(one, reduceMotion: true)

        #expect(model.detail(for: one) == one.detail)
        #expect(!model.isTroubled(one))

        model.markUnavailable(id: one.id, because: "Backup isn't connected", reduceMotion: true)
        #expect(model.detail(for: one) == "Backup isn't connected")
        #expect(model.isTroubled(one))
        // The record of what happened is untouched — that is the one thing the list is for.
        #expect(model.entry(id: one.id)?.failure == nil)
        #expect(model.entry(id: one.id)?.detail == one.detail)

        model.clearUnavailable()
        #expect(model.detail(for: one) == one.detail)
        #expect(!model.isTroubled(one))
    }

    @Test("A relocated entry keeps its place in the list")
    func replaceKeepsOrder() {
        let model = DropHistoryModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = entry(at: now.addingTimeInterval(-60))
        let newer = entry(at: now)
        model.record(older, reduceMotion: true)
        model.record(newer, reduceMotion: true)

        var moved = older
        moved.results = [DropHistoryFile(path: "/tmp/somewhere-else/holiday.jpg")]
        model.replace(moved)

        #expect(model.entries.count == 2)
        #expect(model.entries[1].id == older.id)
        #expect(model.entries[1].results.first?.name == "holiday.jpg")
        #expect(model.entries[1].results.first?.path == "/tmp/somewhere-else/holiday.jpg")
    }

    @Test("Clearing forgets the rows and their marks")
    func clearingForgetsEverything() {
        let model = DropHistoryModel()
        let one = entry(at: Date())
        model.record(one, reduceMotion: true)
        model.markUnavailable(id: one.id, because: "gone", reduceMotion: true)
        #expect(model.removeAll(reduceMotion: true) == 1)
        #expect(model.isEmpty)
        #expect(model.unavailable.isEmpty)
        #expect(model.lastLink == nil)
    }
}

@Suite("Drop history record")
struct DropHistoryArchiveTests {

    private let entry = DropHistoryEntry(
        action: .convert,
        title: "Convert to JPEG",
        offerID: "imageEncode.JPEG.jpg",
        sources: [DropHistoryFile(path: "/tmp/holiday.heic", bookmark: Data([1, 2, 3]))],
        results: [DropHistoryFile(path: "/tmp/holiday.jpg")],
        finishedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test("It survives a round trip, bookmarks and dates included")
    func roundTrips() throws {
        let data = try DropHistoryArchive.record([entry]).encoded()
        let decoded = try #require(try DropHistoryArchive.decoded(from: data))
        #expect(decoded.entries == [entry])
        #expect(decoded.version == DropHistoryArchive.currentVersion)
    }

    /// A record from a newer build is discarded rather than half-decoded — `ShelfArchive`'s rule and
    /// its reason: a user who has run a later build and gone back is better served by an empty
    /// history than by one whose rows point at the wrong files. Nil, not a throw, because it is not
    /// an error and must not be logged as one.
    @Test("A newer record is declined, not decoded and not an error")
    func newerRecordIsDeclined() throws {
        let future = DropHistoryArchive(version: DropHistoryArchive.currentVersion + 1, entries: [entry])
        let data = try future.encoded()
        #expect(try DropHistoryArchive.decoded(from: data) == nil)
    }

    @Test("A corrupt record throws so the caller can report it")
    func corruptRecordThrows() {
        #expect(throws: (any Error).self) {
            try DropHistoryArchive.decoded(from: Data("not json".utf8))
        }
    }

    /// The difference between this record and the shelf's: everything is written, including the
    /// failures. A history that dropped the rows whose work did not succeed would be silent in the
    /// one case somebody goes looking.
    @Test("Failures are written down too")
    func failuresAreKept() throws {
        let failed = DropHistoryEntry(
            action: .convert,
            title: "Convert to PDF",
            failure: "macOS could not preview that file"
        )
        let data = try DropHistoryArchive.record([entry, failed]).encoded()
        let decoded = try #require(try DropHistoryArchive.decoded(from: data))
        #expect(decoded.entries.count == 2)
        #expect(decoded.entries.contains { !$0.succeeded })
    }

    /// **Nothing in the encoded record is a transcript, a message or a file's contents.** The rule
    /// is stated on `DropHistoryModel`; this is the assertion that it is true of the bytes actually
    /// written, in the same spirit as `RecentsPrivacyTests`.
    @Test("The record holds names and paths and nothing that was inside a file")
    func recordHoldsNoContents() throws {
        let data = try DropHistoryArchive.record([entry]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("holiday.jpg"))
        // The fields that exist are exactly these; there is nowhere for content to hide.
        for forbidden in ["transcript", "text", "body", "contents"] {
            #expect(!text.lowercased().contains("\"\(forbidden)\""))
        }
    }
}
