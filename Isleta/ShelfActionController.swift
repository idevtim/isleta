import AppKit
import IslandActivities
import IslandKit
import IslandSources
import IslandUI

/// What happens to a file dropped on the island: AirDrop it, reveal it, file it away, or convert it.
///
/// Wiring, like `ShelfController` beside it. `DropAction` owns what may be offered, `FileConversion`
/// owns what a conversion *is*, `FileConversionEngine` performs it in a child process, and
/// `ShelfActionLayout` owns where a row is. What belongs here is what needs more than one of those:
/// turning a menu row into either an AppKit call or a spawned worker, turning a worker's events into
/// an island, and putting whatever comes out of it onto the shelf.
///
/// ## The two halves of this menu are completely different mechanisms
///
/// **AirDrop, Reveal and the two folder rows are AppKit calls on the main thread** that are finished
/// before the next frame. Two of them raise a system panel, which for an `.accessory` app means
/// taking activation — the trade `ShelfPreview` already measured and states plainly: the user's
/// frontmost app loses key for the length of the panel and gets it back afterwards, best effort,
/// because activation is cooperative since macOS 14.
///
/// **Every conversion is a spawn.** Not because it might wedge — though `qlmanage -t` never returns
/// — but because of memory: measured peaks of +182 MB for AVIF, +452 MB for an H.264 downscale,
/// +95 MB for a 2,000-row spreadsheet. §9's 60 MB is an *idle* figure, and the only way it stays one
/// is for that memory to belong to a process that ends when the work does.
///
/// ## What is logged, and what can never be
///
/// Counts and enum values. Not a file name, not a path, not an extension typed by the user, and —
/// above all — not a word of a transcript, which never enters this process at all: the worker writes
/// the text to disk itself and reports a path back. `IslandLog.shelf` rather than a category of its
/// own, because this is the shelf's own labor and the taxonomy is meant to be a fixed list of
/// concerns rather than a list of files.
@MainActor
final class ShelfActionController {

    private let shelf: ShelfModel
    private let store: ShelfStore
    private let activities: ActivityCoordinator
    private let runner = FileActionRunner()
    private let reduceMotion: @MainActor () -> Bool

    /// How far the actions list is scrolled. Its own, not the grid's — see `ShelfModel.actionScrollTarget`.
    private var scroll = ShelfScroll()

    /// What each running job is, so an event can be turned back into an activity without the worker
    /// having to carry any of it. Keyed by the activity id, which is also the runner's job id: one
    /// identity for the work, the island and the process.
    private var jobs: [ActivityID: Job] = [:]

    /// Who was frontmost before a panel took activation, so it can be handed back.
    private var previousApplication: NSRunningApplication?

    /// Something was added to or moved on the shelf. Set by `ShelfController`, which owns the three
    /// things that have to follow a change to what the shelf holds — republish, re-clamp the scroll,
    /// write it down — and is the only place that list is kept.
    var onContentsChanged: (@MainActor () -> Void)?

    private struct Job {
        var activity: FileActionJob
        var produced: [URL] = []
        var failure: String?

        /// What this job *was*, and what it was given — held so the drop history can record it when
        /// the job ends. `FileActionJob` is deliberately URL-free (it is what the island draws, and
        /// the island never says a file name), so the two facts the history needs have to be kept
        /// beside it rather than read back out of it.
        var action: DropAction
        var sources: [URL]

        /// Whether this job's progress is worth an island at all. `.instant` and `.beat` work
        /// publishes nothing on the way — see `ConversionProgressClass`, where the rule is argued —
        /// but a *failure* always does, whatever the class, because it is the one outcome the user
        /// cannot see by looking at the shelf.
        var isTracked: Bool
    }

    /// Whether a given file can produce an iCloud link, asked at the moment the menu is built.
    ///
    /// A closure rather than the provider itself, so this file needs no import from IslandSources
    /// and a build without the extension is a build where this answers false. Asked per menu, never
    /// cached: `CloudDriveShareLinkProvider.isAvailable` is resolved every time for its own reason,
    /// and whether a *file* is eligible changes when the user moves it into iCloud Drive.
    var canCopyLink: ((URL) -> Bool)?

    /// Copies an iCloud link for one file. Set by the app shell alongside `canCopyLink`.
    var copyLink: ((URL) -> Void)?

    /// Called when a drop action finishes, so the drop history can record it. Set by the app shell.
    ///
    /// A closure rather than a reference to `DropHistoryController`, for the reason every seam in
    /// this file is one: this controller performs actions and knows nothing about what remembers
    /// them, and a build with no history is a build where this is nil.
    var onDidWork: ((DropAction, [URL], [URL], String?) -> Void)?

    init(
        shelf: ShelfModel,
        store: ShelfStore,
        activities: ActivityCoordinator,
        reduceMotion: @escaping @MainActor () -> Bool
    ) {
        self.shelf = shelf
        self.store = store
        self.activities = activities
        self.reduceMotion = reduceMotion
    }

    // MARK: - The menu

    /// Opens the actions menu over the items the island is currently showing.
    ///
    /// Over the *visible* items rather than the whole shelf, which is the one place a live search
    /// has a consequence beyond hiding tiles — see `ShelfRegion.actions`.
    ///
    /// A menu with no rows is not opened. That happens for a shelf whose every item is a dead
    /// reference, and the honest answer there is the tile that already says the file is missing
    /// rather than a second surface saying it again.
    func openMenu(over items: [ShelfItem]) {
        let menu = ShelfActionMenu(
            itemIDs: items.map(\.id),
            actions: DropAction.menu(
                for: items.map { DropActionItem(pathExtension: $0.url.pathExtension, isStale: $0.isStale) },
                // Only ever asked about a single live file — `menu(for:canCopyLink:)` ignores it for
                // a multi-file selection, because a link is per file.
                canCopyLink: items.count == 1
                    && !items[0].isStale
                    && (canCopyLink?(items[0].url) ?? false)
            )
        )
        guard !menu.isEmpty else {
            IslandLog.shelf.info("shelf actions asked for over \(items.count) item(s) with nothing on offer")
            return
        }
        scroll.reset()
        pushScroll(animated: false)
        shelf.setActionMenu(menu, reduceMotion: reduceMotion())
        IslandLog.shelf.info("shelf actions opened over \(items.count) item(s): \(menu.actions.count) row(s)")
    }

    /// Puts the grid back. Safe to call at any time and from anywhere, which is what makes "the menu
    /// never outlives the island it is drawn in" checkable rather than hoped for.
    func closeMenu() {
        guard shelf.isShowingActions else { return }
        shelf.setActionMenu(nil, reduceMotion: reduceMotion())
    }

    var isShowingMenu: Bool { shelf.isShowingActions }

    /// The row at an index into the open menu, or nil.
    func action(at index: Int) -> DropAction? {
        guard let menu = shelf.actionMenu, menu.actions.indices.contains(index) else { return nil }
        return menu.actions[index]
    }

    // MARK: - Scrolling

    /// How far the open menu can scroll, from a layout the caller has already resolved.
    func canScroll(extent: CGFloat) -> Bool { shelf.isShowingActions && extent > 0 }

    func scroll(_ sample: IslandScrollSample, extent: CGFloat) {
        scroll.consume(sample, extent: extent)
        pushScroll(animated: false)
    }

    private func pushScroll(animated: Bool) {
        let offset = scroll.offset
        shelf.actionScrollTarget = animated
            ? shelf.actionScrollTarget.revealing(offset)
            : shelf.actionScrollTarget.dragged(to: offset)
    }

    // MARK: - Performing

    /// Runs one row against the files the menu was opened over.
    ///
    /// The items are resolved **now**, through `ShelfStore.resolve`, for the reason a drag out
    /// resolves then: if the file has moved the bookmark finds it, and if it is gone the tile says
    /// so and it is left out. Handing a converter a path to a file that is not there is how a shelf
    /// turns into a source of empty files.
    func perform(_ action: DropAction, resolving items: [ShelfItem], relocate: (UUID, URL) -> Void) {
        var urls: [URL] = []
        for item in items {
            guard let resolution = store.resolve(item) else { continue }
            if resolution.url != item.url { relocate(item.id, resolution.url) }
            urls.append(resolution.url)
        }
        guard !urls.isEmpty else {
            IslandLog.shelf.warning("shelf action \(action.id) had nothing left to act on")
            return
        }

        // The menu closes on every path. It has said its piece, and a menu left up over a running
        // conversion would offer to start the same one again.
        closeMenu()
        dispatch(action, on: urls)
    }

    /// Runs an action again on URLs that have already been resolved.
    ///
    /// The drop history's entry point. It resolves its own rows — the file may have been renamed
    /// since, which is the case bookmarks exist for — so it arrives with URLs rather than
    /// `ShelfItem`s, and there is no tile to relocate. Everything after resolution is identical,
    /// which is why both callers go through `dispatch` rather than each having a switch.
    func runAgain(_ action: DropAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        dispatch(action, on: urls)
    }

    private func dispatch(_ action: DropAction, on urls: [URL]) {
        IslandLog.shelf.info("shelf action \(action.id) on \(urls.count) file(s)")

        switch action {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .airDrop:
            airDrop(urls)
        case .copyToFolder:
            fileAway(urls, moving: false)
        case .moveToFolder:
            fileAway(urls, moving: true)
        case .copyLink:
            // One file, guaranteed by `menu(for:canCopyLink:)`. Guarded anyway rather than
            // force-unwrapped, because `runAgain` reaches this switch too and the history's rows are
            // whatever the user recorded.
            if let url = urls.first, urls.count == 1 { copyLink?(url) }
        case .convert(let offer):
            convert(urls, with: offer, action: action)
        }
    }

    // MARK: - AirDrop

    /// Apple's own picker, raised on our behalf.
    ///
    /// **It cannot be targeted, and that is the API rather than a limitation of this code.**
    /// `NSSharingService.recipients` is honored by Mail and Messages and has no meaning for
    /// AirDrop — it is a picker, not an address — so there is no "send to Tim's iPhone" row in the
    /// island and none is drawn. `Sharing.framework`'s `SFAirDropBrowser` /
    /// `SFAirDropDiscoveryController` / `SFAirDropTransfer` would address a peer directly and is a
    /// whole private surface for a picker Apple already draws well.
    ///
    /// `canPerform(withItems:)` is asked and is not trusted as evidence of anything beyond
    /// "the service exists here": measured, it answers **true** for a file on `/private/tmp` that
    /// iCloud has never seen. It is checked so that a machine with AirDrop switched off gets a
    /// stated failure rather than a picker that never appears.
    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            IslandLog.shelf.warning("AirDrop is not available for this selection")
            return
        }
        takeActivation()
        // Held so the drop history can record what was sent when the picker reports back. The
        // delegate is a shared object with no per-share state of its own, and one AirDrop is up at
        // a time because the picker is modal.
        pendingAirDrop = urls
        service.delegate = sharingDelegate
        service.perform(withItems: urls)
    }

    /// What the open AirDrop picker was given, or empty when none is up.
    private var pendingAirDrop: [URL] = []

    private lazy var sharingDelegate = SharingDelegate { [weak self] shared in
        MainActor.assumeIsolated {
            guard let self else { return }
            self.restoreActivation()
            let urls = self.pendingAirDrop
            self.pendingAirDrop = []
            // **Only on success.** The picker's other ending is the user pressing Escape, and a
            // history that recorded that would answer "what did I do with this file" with something
            // they deliberately did not do. Nothing distinguishes a cancel from a refusal here, and
            // the safe direction is to record neither.
            guard shared, !urls.isEmpty else { return }
            self.onDidWork?(.airDrop, urls, [], nil)
        }
    }

    /// Hands the sharing service's ending back to us, so activation can be returned.
    ///
    /// A separate object because `NSSharingServiceDelegate` is an `NSObjectProtocol` and this
    /// controller is a plain class — making it an `NSObject` to reach two methods would put a
    /// framework's plumbing in the file that is supposed to be wiring only. The same reasoning
    /// `ShelfPreview` gives for not putting QuickLook's three methods on the app delegate.
    private final class SharingDelegate: NSObject, NSSharingServiceDelegate {
        /// `true` when the share actually happened. The failure path also fires for a cancel — the
        /// picker does not separate them — so the flag is "we were told it worked" rather than
        /// "it did not fail".
        private let ended: @Sendable (Bool) -> Void
        init(ended: @escaping @Sendable (Bool) -> Void) { self.ended = ended }

        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { ended(true) }

        func sharingService(
            _ service: NSSharingService, didFailToShareItems items: [Any], error: any Error
        ) {
            ended(false)
        }
    }

    // MARK: - Copy and move

    /// A destination panel, then a copy or a move.
    ///
    /// **A move updates the shelf rather than emptying it.** The tile is the same file in a
    /// different place, which is precisely the case bookmarks are held for — and re-resolving it
    /// here rather than waiting for the next drag means the tile takes its new name immediately
    /// instead of appearing to have gone stale.
    ///
    /// A failure part-way through leaves the files that already moved where they went. There is no
    /// undo, which is why the row that does this is drawn in `.warning` and why the panel — whose
    /// Cancel is the last exit — is the confirmation rather than a sheet of our own.
    private func fileAway(_ urls: [URL], moving: Bool) {
        takeActivation()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = moving
            ? appText("shelf.fileAway.prompt.move", "Move Here")
            : appText("shelf.fileAway.prompt.copy", "Copy Here")
        panel.message = moving
            ? appText("shelf.fileAway.message.move", "Choose where to move these files.")
            : appText("shelf.fileAway.message.copy", "Choose where to copy these files.")

        let response = panel.runModal()
        restoreActivation()
        guard response == .OK, let destination = panel.url else { return }

        var moved = 0
        var failed = 0
        for url in urls {
            let target = uniqueDestination(for: url, in: destination)
            do {
                if moving {
                    try FileManager.default.moveItem(at: url, to: target)
                    relocateOnShelf(from: url, to: target)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
                moved += 1
            } catch {
                // The path is in `error.localizedDescription`, so only the count travels.
                failed += 1
            }
        }
        onDidWork?(
            moving ? .moveToFolder : .copyToFolder,
            urls,
            [],
            failed > 0
                ? (moving
                    ? appText("shelf.fileAway.failure.move", "\(failed) of \(urls.count) could not be moved")
                    : appText("shelf.fileAway.failure.copy", "\(failed) of \(urls.count) could not be copied"))
                : nil
        )
        IslandLog.shelf.info(
            "\(moving ? "moved" : "copied") \(moved) file(s), \(failed) refused"
        )
        if failed > 0 {
            present(
                FileActionJob(
                    id: ActivityID("shelf.action.\(UUID().uuidString)"),
                    action: moving
                        ? appText("shelf.action.moveToFolder", "Move to Folder")
                        : appText("shelf.action.copyToFolder", "Copy to Folder"),
                    symbol: moving ? "arrow.right.doc.on.clipboard" : "doc.on.doc",
                    fileCount: urls.count,
                    stage: .failed(reason: appText("shelf.fileAway.failedCount", "\(failed) files could not be filed"))
                )
            )
        }
    }

    /// Finder's own collision rule — " 2", " 3" — because the file lands in the user's folder and
    /// has to look like something the system made.
    private func uniqueDestination(for url: URL, in directory: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = directory.appendingPathComponent(url.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path), suffix < 1000 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    private func relocateOnShelf(from url: URL, to target: URL) {
        guard let item = shelf.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
        else { return }
        shelf.relocate(id: item.id, to: target)
        shelf.refreshBookmark(id: item.id, to: store.bookmark(for: target))
    }

    // MARK: - Conversion

    /// Spawns a worker and turns its events into an island.
    ///
    /// The output goes **beside the source file**, which is what every converter on this platform
    /// does and the only destination that needs no panel: a conversion the user asked for from a
    /// notch should not open a window. What comes out is put on the shelf, which is both the
    /// confirmation and the way to drag it somewhere.
    private func convert(_ urls: [URL], with offer: ConversionOffer, action: DropAction) {
        guard let executable = Bundle.main.executableURL else { return }
        let id = ActivityID("shelf.action.\(UUID().uuidString)")
        let request = FileConversionRequest(
            route: offer.route,
            targetIdentifier: offer.target.identifier,
            targetExtension: offer.target.pathExtension,
            inputs: urls.map(\.path),
            outputDirectory: urls[0].deletingLastPathComponent().path,
            localeIdentifier: Locale.current.identifier(.bcp47)
        )
        var job = FileActionJob(
            id: id,
            action: action.title,
            symbol: action.symbol,
            fileCount: urls.count,
            stage: .running(fraction: nil)
        )

        let started = runner.start(id: id, request: request, executable: executable) { [weak self] id, report in
            self?.handle(report, for: id)
        }
        guard started else {
            job.stage = .failed(reason: appText("shelf.convert.couldNotStart", "That conversion could not be started"))
            present(job)
            return
        }

        jobs[id] = Job(activity: job, action: action, sources: urls,
                       isTracked: offer.progress.isWorthAnActivity)
        if offer.progress.isWorthAnActivity {
            present(job)
            shelf.job = ShelfJobStatus(title: action.title, fraction: nil)
        }
    }

    private func handle(_ report: FileActionRunner.Report, for id: ActivityID) {
        guard var job = jobs[id] else { return }

        switch report {
        case .progress(let fraction):
            job.activity.stage = .running(fraction: fraction)
            jobs[id] = job
            guard job.isTracked else { return }
            present(job.activity)
            shelf.job = ShelfJobStatus(title: job.activity.action, fraction: fraction)

        case .produced(let url):
            job.produced.append(url)
            jobs[id] = job
            // On the shelf as it lands, rather than all at once at the end, for the reason
            // `ShelfStore.receivePromises` reports each promised file as it arrives: a surface that
            // shows nothing until the last file is done looks like one that failed.
            shelf.insert([store.adopted(url)], reduceMotion: reduceMotion())
            onContentsChanged?()

        case .failed(let reason):
            job.failure = reason
            jobs[id] = job

        case .ended(let producedAnything):
            jobs[id] = nil
            shelf.job = nil
            // Recorded whatever the outcome and whatever the progress class. A conversion that
            // failed is exactly the one somebody comes back asking about, and an 80 ms JPEG encode
            // that was not worth an island is still worth a row — the history answers "what did I
            // do with that file", which does not depend on whether the island said anything.
            onDidWork?(
                job.action,
                job.sources,
                job.produced,
                producedAnything && job.failure == nil
                    ? nil
                    : (job.failure ?? appText("shelf.convert.didNotFinish", "That conversion did not finish"))
            )
            if producedAnything, job.failure == nil {
                IslandLog.shelf.info("shelf conversion finished — \(job.produced.count) file(s) produced")
                // The success is published only for work that was worth announcing. A JPEG encode
                // is 80 ms and an island that arrives and leaves inside five frames is a flicker;
                // the tile appearing on the shelf is the whole of the feedback there.
                if job.isTracked {
                    present(job.activity.advanced(to: .finished(produced: job.produced.count)))
                }
            } else {
                // A failure is always published, whatever the progress class, because it is the one
                // outcome the user cannot see by looking at the shelf.
                let reason = job.failure ?? appText("shelf.convert.didNotFinish", "That conversion did not finish")
                IslandLog.shelf.warning("shelf conversion failed")
                present(job.activity.advanced(to: .failed(reason: reason)))
            }
        }
    }

    private func present(_ job: FileActionJob) {
        activities.present(BuiltInActivity.fileAction(job))
    }

    // MARK: - Teardown

    /// Ends every worker, synchronously, and does not return until they are gone.
    ///
    /// Called from `applicationWillTerminate`, which returns straight into `exit()` — so teardown
    /// that is merely *scheduled* never happens. See `FileActionRunner`, where the measurement that
    /// cost a milestone is written down.
    func stopAndWait() {
        runner.stopAndWait()
        jobs.removeAll()
        shelf.job = nil
    }

    // MARK: - Activation

    /// Isleta becomes the active app for the length of a system panel, and gives it back.
    ///
    /// The same trade `ShelfPreview` makes for QuickLook and states plainly: an `.accessory` app
    /// whose only window refuses key cannot show a modal panel any other way, and the user's
    /// frontmost app loses key while it is up. `activate(ignoringOtherApps: true)` and not
    /// `NSApp.activate()`, which is cooperative since macOS 14 and cannot activate an accessory app
    /// at all — measured, it leaves the app inactive with the panel drawn behind the frontmost one.
    private func takeActivation() {
        if previousApplication == nil {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApplication = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmost
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Best effort, and it says so: activation is cooperative, so `yieldActivation(to:)` is the half
    /// that makes it likely to be honored.
    private func restoreActivation() {
        guard let previousApplication, !previousApplication.isTerminated else {
            self.previousApplication = nil
            return
        }
        self.previousApplication = nil
        NSApp.yieldActivation(to: previousApplication)
        previousApplication.activate()
    }
}
