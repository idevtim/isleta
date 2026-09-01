import AppKit
import IslandActivities
import IslandKit
import IslandSources
import IslandUI

/// What Isleta has done with the files it was given, remembered across launches.
///
/// Wiring, like `ShelfController` and `ShelfActionController` beside it. `DropHistoryModel` owns the
/// list, `DropHistoryArchive` owns what it is written down as, `DropHistoryLayout` owns where a row
/// is, and `DropHistoryResolver` owns the four answers to "where is that file now" — all four are
/// pure and tested. What belongs here is what needs more than one of them: the disk, the pasteboard,
/// the Finder, and turning a click on a row into one of those.
///
/// ## What is logged, and what can never be
///
/// Counts and `DropHistoryAction` values. **Never a file name, a path, a folder name, a link or a
/// volume name** — the record this class keeps is precisely the kind of thing `IslandLog` forbids,
/// for the reason every list of the user's own content is held to: the log file is emailed to strangers and
/// the unified log is readable by every process on the machine. `IslandLog.shelf` rather than a
/// category of its own, because this is the shelf's own labor and the taxonomy is a fixed list of
/// concerns rather than a list of features.
///
/// It is also deliberately **absent from the "Export Logs…" bundle**: nothing here writes to the
/// log, so there is nothing for the bundle to pick up, which is the only version of that promise
/// that cannot be got wrong later.
@MainActor
final class DropHistoryController {

    let model: DropHistoryModel

    private let reduceMotion: @MainActor () -> Bool

    /// How far the list is scrolled. App-wide, for the reason `AppDelegate` owns one `RecentsScroll`:
    /// two islands showing this list must be looking at the same part of it.
    private var scroll = DropHistoryScroll()

    private let resolver = DropHistoryResolver()

    /// Ask for a piece of work to be done again. Set by the app shell, which owns
    /// `ShelfActionController` — this class deliberately does not, so that reading the history
    /// cannot become a second route into performing actions with its own idea of the rules.
    var onRunAgain: ((DropAction, [URL]) -> Void)?

    init(model: DropHistoryModel, reduceMotion: @escaping @MainActor () -> Bool) {
        self.model = model
        self.reduceMotion = reduceMotion
        model.onReveal = { [weak self] id in self?.reveal(id) }
        model.onRunAgain = { [weak self] id in self?.runAgain(id) }
        model.onCopyLink = { [weak self] id in self?.copyLink(id) }
    }

    // MARK: - Recording

    /// Records one completed piece of work.
    ///
    /// Called from `ShelfActionController` at the three moments a piece of work is over — see the
    /// wiring note in this file's commit. Everything is recorded, **including failures**: a history
    /// that only remembered what worked would be silent in the one case somebody goes looking.
    ///
    /// - Parameters:
    ///   - action: the menu row that was performed, for its title, its glyph and its offer id.
    ///   - sources: the files it was given, resolved at the moment of the work.
    ///   - produced: the files it wrote, if any.
    ///   - link: the link it minted, if any.
    ///   - failure: Isleta's own words for why it did not work, or nil.
    func record(
        _ action: DropAction,
        sources: [URL],
        produced: [URL] = [],
        link: String? = nil,
        failure: String? = nil
    ) {
        guard model.isEnabled else { return }
        // Reveal changes nothing and produces nothing, so it is not history — see the note on
        // `DropHistoryAction`. Checked here rather than at every call site, so a caller that
        // records everything it performs cannot accidentally start logging the user's browsing.
        guard let kind = Self.kind(of: action) else { return }

        let entry = DropHistoryEntry(
            action: kind,
            title: action.title,
            offerID: Self.offerID(of: action),
            sources: sources.map(Self.file(for:)),
            results: produced.map(Self.file(for:)),
            link: link,
            failure: failure
        )
        model.record(entry, reduceMotion: reduceMotion())
        save()

        // Counts and the enum value. Nothing that names a file, a folder or a link.
        IslandLog.shelf.info(
            "drop history recorded \(kind.rawValue) — \(sources.count) in, \(produced.count) out, \(failure == nil ? "ok" : "failed")"
        )
    }

    /// Records a shareable link (Stage 3.7).
    ///
    /// Its own entry point rather than a case of `record(_:sources:...)` because `DropAction` has no
    /// `shareLink` row yet — the link surface is another agent's — and inventing one here to make a
    /// signature fit would be this file deciding what that menu offers. When the row lands, the call
    /// site is one line at the moment the link comes back.
    ///
    /// - Parameter link: the URL as a string. It is stored and it is copied and it is never logged —
    ///   a share link is a capability, and one in a file emailed to strangers is the file being
    ///   shared with them too.
    func recordLink(
        _ link: String,
        for sources: [URL],
        title: String = appText("dropHistory.copyLink", "Copy Link")
    ) {
        guard model.isEnabled else { return }
        model.record(
            DropHistoryEntry(
                action: .shareLink,
                title: title,
                sources: sources.map(Self.file(for:)),
                link: link
            ),
            reduceMotion: reduceMotion()
        )
        save()
        IslandLog.shelf.info("drop history recorded shareLink — \(sources.count) in")
    }

    private static func kind(of action: DropAction) -> DropHistoryAction? {
        switch action {
        case .revealInFinder: nil
        case .airDrop: .airDrop
        case .copyToFolder: .copyToFolder
        case .moveToFolder: .moveToFolder
        case .copyLink: .shareLink
        case .convert(let offer):
            switch offer.route {
            case .transcribe: .transcribe
            case .mediaHEVC: .compress
            default: .convert
            }
        }
    }

    private static func offerID(of action: DropAction) -> String? {
        guard case .convert(let offer) = action else { return nil }
        return offer.id
    }

    private static func file(for url: URL) -> DropHistoryFile {
        DropHistoryFile(
            path: url.path,
            name: url.lastPathComponent,
            bookmark: DropHistoryResolver.bookmark(for: url)
        )
    }

    // MARK: - What a row does

    /// Shows what the work produced, in the Finder.
    ///
    /// The result before the source, because the thing the user is looking for is the thing that did
    /// not exist before. Where it cannot be reached, the row says why and nothing else happens — see
    /// `DropHistoryModel.unavailable` for why the message goes in the row rather than on the stage.
    private func reveal(_ id: UUID) {
        guard var entry = model.entry(id: id), let file = entry.fileToReveal else { return }
        switch resolver.state(path: file.path, bookmark: file.bookmark) {
        case .here(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .moved(let url, let renewedBookmark):
            // **The record follows the file.** This is the case CLAUDE.md warns about — a bookmark to
            // a renamed file resolves correctly and reports `isStale` — so it is a success, and the
            // entry takes the new path and name so the row stops naming a file that no longer exists
            // and the *next* click does not have to resolve it again.
            entry = Self.relocating(entry, from: file, to: url, bookmark: renewedBookmark)
            model.replace(entry)
            save()
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .volumeUnavailable(let name):
            model.markUnavailable(
                id: id,
                because: DropHistoryFileState.volumeUnavailable(volumeName: name).explanation ?? "",
                reduceMotion: reduceMotion()
            )
            IslandLog.shelf.info("drop history row could not be revealed — the volume is not mounted")

        case .missing:
            model.markUnavailable(
                id: id,
                because: DropHistoryFileState.missing.explanation ?? "",
                reduceMotion: reduceMotion()
            )
            IslandLog.shelf.info("drop history row could not be revealed — the file is gone")
        }
    }

    /// The same entry, pointing at where its file turned out to be.
    ///
    /// Whichever list the file was in — it is looked up by path in both, because a result and a
    /// source are the same shape and the caller already knows which one it handed in.
    private static func relocating(
        _ entry: DropHistoryEntry,
        from file: DropHistoryFile,
        to url: URL,
        bookmark: Data?
    ) -> DropHistoryEntry {
        var updated = entry
        let replacement = DropHistoryFile(
            path: url.path,
            name: url.lastPathComponent,
            bookmark: bookmark ?? file.bookmark
        )
        if let index = updated.results.firstIndex(where: { $0.path == file.path }) {
            updated.results[index] = replacement
        } else if let index = updated.sources.firstIndex(where: { $0.path == file.path }) {
            updated.sources[index] = replacement
        }
        return updated
    }

    /// Does the same thing again, to the same files.
    ///
    /// The **sources** are resolved, never the results: running a conversion again means converting
    /// the original a second time, and running it against its own output would produce a JPEG of a
    /// JPEG. A source that cannot be reached takes the row's `unavailable` message, exactly as a
    /// reveal does — and nothing is started, because handing a converter a path to a file that is
    /// not there is how a shelf turns into a source of empty files (`ShelfActionController` states
    /// the same rule).
    private func runAgain(_ id: UUID) {
        guard let entry = model.entry(id: id), entry.canRunAgain else { return }
        var urls: [URL] = []
        for source in entry.sources {
            switch resolver.state(path: source.path, bookmark: source.bookmark) {
            case .here(let url), .moved(let url, _):
                urls.append(url)
            case .volumeUnavailable(let name):
                model.markUnavailable(
                    id: id,
                    because: DropHistoryFileState.volumeUnavailable(volumeName: name).explanation ?? "",
                    reduceMotion: reduceMotion()
                )
                return
            case .missing:
                model.markUnavailable(
                    id: id,
                    because: DropHistoryFileState.missing.explanation ?? "",
                    reduceMotion: reduceMotion()
                )
                return
            }
        }
        guard !urls.isEmpty, let action = Self.action(rebuilding: entry, firstSource: urls[0]) else {
            IslandLog.shelf.info("drop history could not repeat \(entry.action.rawValue)")
            return
        }
        IslandLog.shelf.info("drop history repeating \(entry.action.rawValue) on \(urls.count) file(s)")
        onRunAgain?(action, urls)
    }

    /// The menu row this entry came from, rebuilt from the catalog as it is **today**.
    ///
    /// Rebuilt rather than stored, and the failure that buys is the right one: a build that drops a
    /// measured route drops the ability to repeat it, and the button simply does nothing rather than
    /// spawning a worker for a route that is no longer there. `FileConversion.offers` is keyed on the
    /// path extension, so the source's *current* extension is what is asked — a file renamed from
    /// `.heic` to `.jpg` in the meantime correctly offers what a JPEG offers.
    private static func action(rebuilding entry: DropHistoryEntry, firstSource url: URL) -> DropAction? {
        guard let offerID = entry.offerID else { return nil }
        guard let offer = FileConversion.offers(forPathExtension: url.pathExtension)
            .first(where: { $0.id == offerID })
        else { return nil }
        return .convert(offer)
    }

    /// Puts one entry's link on the pasteboard.
    private func copyLink(_ id: UUID) {
        guard let link = model.entry(id: id)?.link else { return }
        Self.copy(link)
        IslandLog.shelf.info("drop history copied a link")
    }

    /// `ShortcutAction.copyLastLink`: the most recent link Isleta produced, on the pasteboard.
    ///
    /// Returns whether there was one, so the caller can decide what to do about a shortcut that had
    /// nothing to answer with — this class does not put anything on the stage, because a global
    /// shortcut's feedback is the app shell's business and not the history's.
    @discardableResult
    func copyLastLink() -> Bool {
        guard let link = model.lastLink else {
            IslandLog.shelf.info("copy last link: nothing recorded")
            return false
        }
        Self.copy(link)
        IslandLog.shelf.info("copy last link: copied")
        return true
    }

    private static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Forgets everything, and writes that down immediately rather than in half a second.
    ///
    /// The debounce below is for coalescing a burst of records; **clearing is a privacy act** and a
    /// user who clears the history and quits inside the debounce window must not find it back
    /// tomorrow. Same reasoning as `ShelfStore.flushPendingSave`, applied at the one call site where
    /// the delay would be a broken promise rather than a slow write.
    func clear() {
        let removed = model.removeAll(reduceMotion: reduceMotion())
        pendingArchive = DropHistoryArchive.record([])
        flushPendingSave()
        IslandLog.shelf.info("drop history cleared — \(removed) entr(ies) forgotten")
    }

    // MARK: - Scrolling

    /// How far the list can scroll, from what it is holding.
    var scrollExtent: CGFloat {
        DropHistoryLayout.scrollExtent(rowCount: model.entries.count)
    }

    func scroll(_ sample: IslandScrollSample) {
        scroll.consume(sample, extent: scrollExtent)
        model.scrollTarget = model.scrollTarget.dragged(to: scroll.offset)
    }

    /// Back to the newest, opening *and* closing, for the reason a list
    /// reopened where it was left opens on rows the user has already read.
    func resetScroll() {
        scroll.reset()
        model.scrollTarget = model.scrollTarget.dragged(to: 0)
    }

    /// Called when the surface opens or closes. See `DropHistoryModel.unavailable`.
    func didToggle(isShowing: Bool) {
        model.clearUnavailable()
        resetScroll()
        IslandLog.shelf.info(
            "drop history \(isShowing ? "opened" : "closed") — \(model.entries.count) held"
        )
    }

    // MARK: - Across launches

    /// `~/Library/Application Support/Isleta/drop-history.json`. Beside `shelf.json`, for the reasons
    /// `DropHistoryArchive` gives — not Caches, which the system may delete, and not `UserDefaults`,
    /// which cfprefsd rewrites for every unrelated setting change.
    private lazy var recordURL: URL? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("Isleta", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // The path is ours, not the user's files.
            IslandLog.shelf.error(
                "could not create the drop history's storage directory: \(error.localizedDescription)"
            )
            return nil
        }
        return directory.appendingPathComponent("drop-history.json", isDirectory: false)
    }()

    private var pendingSave: Task<Void, Never>?
    private var pendingArchive: DropHistoryArchive?

    /// Half a second, doing the same job it does for the shelf: **coalescing**. A multi-file
    /// conversion records once, but a user working through a shelf can finish several jobs inside a
    /// second, and each record would otherwise be an encode and a file write. A one-shot
    /// `Task.sleep`, never a `Timer`, and none exists at any other time.
    private static let saveDebounce = Duration.milliseconds(500)

    /// Reads the history back, applies this build's capacity and retention rules, and hands it to
    /// the model.
    ///
    /// **Nothing is resolved here**, which is the one place this differs from `ShelfStore.restore`
    /// and is deliberate. The shelf resolves all thirty bookmarks at launch because its whole claim
    /// is that what it shows is *there*, so a dead tile has to be visibly dead from the first frame.
    /// This list's claim is only that the act happened, which stays true whatever the disk says — so
    /// a launch costs one JSON decode and nothing else, and the four answers about a missing file are
    /// worked out at the moment a row is clicked.
    func restore() {
        guard let recordURL, FileManager.default.fileExists(atPath: recordURL.path) else { return }
        do {
            let data = try Data(contentsOf: recordURL)
            guard let archive = try DropHistoryArchive.decoded(from: data) else {
                // A record from a later build. Not an error, and not something to overwrite: leaving
                // it alone is what lets the user go back to the newer build with it intact.
                IslandLog.shelf.info("drop history record is from a newer version — starting empty")
                return
            }
            let before = archive.entries.count
            model.restore(archive.entries)
            let kept = model.entries.count
            IslandLog.shelf.info("drop history restored: \(kept) entr(ies), \(before - kept) aged out")
            // Only if the rules actually dropped something, so an ordinary launch writes nothing.
            if kept != before { save() }
        } catch {
            IslandLog.shelf.error("could not read the drop history record: \(error.localizedDescription)")
        }
    }

    /// Records the history, in half a second, unless something else changes first.
    ///
    /// The encode happens **now** and only the write is deferred, for `ShelfStore.scheduleSave`'s
    /// reason: capturing the model would write whatever it happens to hold when the task runs, which
    /// may be a history the user has since cleared.
    private func save() {
        pendingArchive = DropHistoryArchive.record(model.entries)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.writePendingRecord()
        }
    }

    /// Writes whatever is outstanding, now, on the calling thread.
    ///
    /// **Called from `applicationWillTerminate`, and it has to be synchronous**: that method returns
    /// straight into `exit()`, so teardown that is merely *scheduled* never happens. The debounced
    /// task above is exactly that shape — correct on every path but this one, where the process dies
    /// with the sleep still in flight and the user's last conversion is forgotten. This is the lesson
    /// `ActivitySource.stopAndWait()` and `ShelfStore.flushPendingSave()` both exist for.
    func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        writePendingRecord()
    }

    private func writePendingRecord() {
        guard let archive = pendingArchive, let recordURL else { return }
        pendingArchive = nil
        do {
            // Atomic, so a crash mid-write leaves the previous history rather than half of this one.
            try archive.encoded().write(to: recordURL, options: .atomic)
        } catch {
            IslandLog.shelf.error("could not write the drop history record: \(error.localizedDescription)")
        }
    }

    // MARK: - Demo

    #if DEBUG
    /// `--drophistory-demo [count]`: a full history, so the list can be looked at without dropping
    /// twenty files and converting each one.
    ///
    /// Worth its own flag for `--recents-demo`'s reason: this surface only exists once several
    /// pieces of work have *finished*, and each one is a spawn against a real file — so filling it
    /// honestly means sitting through twenty conversions, and the interesting states (a failure, a
    /// link, a row whose file has since been deleted) cannot be arranged to order at all.
    ///
    /// **It writes nothing to disk.** `record(_:...)` is not used and `save()` is never called, so a
    /// demo cannot leave twenty invented rows in the user's real history — which for a file the user
    /// cannot see and did not ask for is the difference between a demo and a bug. The entries name
    /// files that do not exist, which is also the point: clicking one exercises the missing-file path
    /// that is otherwise reached only by deleting something.
    ///
    /// The `let` this is guarded by is read **inside** this `#if`, never outside it. A `#if DEBUG`
    /// flag read into a `let` whose call site is not behind the same `#if` makes a branch provably
    /// dead in Release, which `SWIFT_TREAT_WARNINGS_AS_ERRORS` turns into a failed build that
    /// `Tools/check.sh` cannot see — it builds Debug. CLAUDE.md records the day that shipped.
    func presentDemoIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--drophistory-demo") else { return }
        let requested = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) : nil
        let count = min(max(1, requested ?? 12), DropHistoryModel.capacity)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("drophistory-demo", isDirectory: true)

        // Every shape a row can be, in the order somebody reviewing this would want to see them:
        // a plain conversion, a multi-file one, a transcription, a compression, a link, a filing,
        // an AirDrop, and a failure.
        let samples: [(DropHistoryAction, String, String?, [String], [String], String?, String?)] = [
            (.convert, "Convert to JPEG", "imageIO.JPEG.jpg", ["holiday.heic"], ["holiday.jpg"], nil, nil),
            (.convert, "Convert to PDF", "imagesToPDF.PDF.pdf", ["scan-1.png", "scan-2.png", "scan-3.png"], ["scan-1.pdf"], nil, nil),
            (.transcribe, "Transcribe", "transcribe.Text.txt", ["standup.m4a"], ["standup.txt"], nil, nil),
            (.compress, "Compress video", "mediaHEVC.HEVC 1080p.mp4", ["screen-recording.mov"], ["screen-recording-hevc.mp4"], nil, nil),
            (.shareLink, "Copy Link", nil, ["proposal.pdf"], [], "https://www.icloud.com/iclouddrive/0aBcDeFgHiJkLmNoP", nil),
            (.moveToFolder, "Move to Folder", nil, ["invoice-2026-08-final.pdf"], [], nil, nil),
            (.airDrop, "AirDrop", nil, ["keynote-deck.key"], [], nil, nil),
            (.convert, "Convert to PDF", "quickLookPDF.PDF.pdf", ["budget.xlsx"], [], nil, "macOS could not preview that file"),
        ]

        let entries = (0..<count).map { index -> DropHistoryEntry in
            let sample = samples[index % samples.count]
            return DropHistoryEntry(
                action: sample.0,
                title: sample.1,
                offerID: sample.2,
                sources: sample.3.map { DropHistoryFile(path: scratch.appendingPathComponent($0).path) },
                results: sample.4.map { DropHistoryFile(path: scratch.appendingPathComponent($0).path) },
                link: sample.5,
                failure: sample.6,
                // Spread back through the day so the age column is not a column of identical
                // "now"s, which is the one column that cannot be checked with them all the same.
                finishedAt: Date().addingTimeInterval(-Double(index) * 900)
            )
        }
        model.restore(entries)
    }

    /// Fills the history for `--hitch-test`, which measures the frames the tallest body drops.
    ///
    /// Reuses the demo's own entries rather than inventing a second set, so what the probe measures
    /// is what `--drophistory-demo` puts on screen. **Writes nothing to disk**, for the reason above:
    /// `restore(_:)` rather than `record(_:reduceMotion:)`, and `save()` is never called.
    ///
    /// - Parameter withoutIcons: leaves every row's source list empty, so no row asks
    ///   `ApplicationIconResolver` for anything. It is what separates the cost of the rows from the
    ///   cost of the icons in them — the two are only separable by varying one at a time.
    func recordForHitchTest(rows: Int, withoutIcons: Bool) {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hitch-history", isDirectory: true)
        let count = min(max(1, rows), DropHistoryModel.capacity)
        let entries = (0..<count).map { index -> DropHistoryEntry in
            DropHistoryEntry(
                action: .convert,
                title: "Convert to JPEG",
                offerID: "imageIO.JPEG.jpg",
                sources: withoutIcons
                    ? []
                    : [DropHistoryFile(path: scratch.appendingPathComponent("photo-\(index).heic").path)],
                results: [DropHistoryFile(path: scratch.appendingPathComponent("photo-\(index).jpg").path)],
                link: nil,
                failure: nil,
                finishedAt: Date().addingTimeInterval(-Double(index) * 900)
            )
        }
        model.restore(entries)
    }
    #endif
}
