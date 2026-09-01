import IslandKit
import AppKit
import IslandUI
import UniformTypeIdentifiers

/// The half of the shelf that touches the pasteboard and the filesystem.
///
/// It lives in the app shell rather than in a package for the same reason `SourceHub` does: this is
/// the layer that is allowed to do I/O. `ShelfModel` owns the list, `ShelfLayout` owns the geometry
/// and both are pure and tested; everything here is the part that can only be exercised against a
/// real drag, so it is kept as thin as it can be made.
///
/// ## What it writes, and the only thing it ever deletes
///
/// Nothing of the user's, for an ordinary file drop — the shelf holds a reference (see `ShelfItem`).
/// Two exceptions, and both are Isleta's own:
///
/// - **A file promise**: a drag out of Mail, Photos or a browser carries no file, only an
///   undertaking to produce one, so the bytes have to be received somewhere. They go into a
///   directory named for this process, under the user's temporary directory, and `cleanUpSession()`
///   removes the whole thing on quit.
/// - **The shelf record**: `~/Library/Application Support/Isleta/shelf.json`, which is what makes a
///   file dropped yesterday still be there today. Bookmarks and names, no contents. See
///   `ShelfArchive` for why it is a file rather than SwiftData or the config record.
///
/// That is the entire filesystem footprint, and both halves are bounded by the shelf's capacity
/// rather than by how long Isleta has been running.
@MainActor
final class ShelfStore {

    /// Everything the island will accept.
    ///
    /// File URLs and file promises, and deliberately not `.string` or a non-file `.URL`. Accepting
    /// text would make the shelf hold *content* rather than references to the user's own files —
    /// it would have to invent a file to put a snippet in, name it, and own it forever. That is a
    /// different product, and it is the one that makes an empty shelf impossible to reason about.
    /// A text drag over the island is refused, which shows the "no drop" cursor and is honest.
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }

    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    /// Created on the first promise received, so a Mac that only ever drags real files never gets a
    /// directory made for it.
    private var sessionDirectory: URL?

    // MARK: - Reading a drag

    /// Whether a pasteboard carries anything the shelf can hold.
    ///
    /// Asked in `draggingEntered`, which is also where the island decides to open — so this has to
    /// be cheap and must not touch the promised files themselves. `canReadObject` inspects declared
    /// types only.
    func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions) {
            return true
        }
        return pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// The real files on a pasteboard, as shelf items. Synchronous: these already exist.
    func items(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLOptions) as? [URL] ?? []
        return urls.map { item(for: $0) }
    }

    /// Receives any file promises on a pasteboard, reporting each file as it lands.
    ///
    /// Incremental rather than a single completion at the end: a promise from Photos can take a
    /// noticeable moment to produce a full-size image, and a shelf that shows nothing until every
    /// file in a multi-file drag has arrived looks like a drop that failed.
    ///
    /// **Must be called from `performDragOperation`.** An `NSFilePromiseReceiver` is only valid for
    /// the drag that produced it; read later it answers nothing, with no error worth the name.
    func receivePromises(
        from pasteboard: NSPasteboard,
        onReceived: @escaping @MainActor (ShelfItem) -> Void
    ) -> Bool {
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty, let directory = makeSessionSubdirectory() else { return false }

        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: directory,
                options: [:],
                operationQueue: .main
            ) { url, error in
                // `.main` above, so this is already on the main thread — the same pattern every
                // other callback in this app uses rather than hopping and arriving a frame later.
                MainActor.assumeIsolated {
                    guard error == nil else {
                        IslandLog.shelf.error("file promise failed: \(error?.localizedDescription ?? "unknown")")
                        return
                    }
                    onReceived(self.item(for: url, isMaterialized: true))
                }
            }
        }
        return true
    }

    private func item(for url: URL, isMaterialized: Bool = false) -> ShelfItem {
        ShelfItem(url: url, bookmark: Self.bookmark(for: url), isMaterialized: isMaterialized)
    }

    /// A shelf item for a file **Isleta produced** — a conversion's output, a transcript.
    ///
    /// Deliberately **not** `isMaterialized`. That flag means "Isleta wrote these bytes and may
    /// delete them", and it is true of a received file promise, which lives in the session directory
    /// and is removed on quit. A converted file lives in the user's own folder beside the original,
    /// under a name the user can see; deleting it on quit would be the app throwing away the thing
    /// it was asked to make. See `cleanUpSession`.
    func adopted(_ url: URL) -> ShelfItem {
        item(for: url)
    }

    /// A bookmark for a file the shelf is about to follow. The instance-level door onto the rule
    /// below, for the one caller outside this type that relocates an item — a move to a folder,
    /// which is the shelf following a file the user just sent somewhere else.
    func bookmark(for url: URL) -> Data? {
        Self.bookmark(for: url)
    }

    // MARK: - Bookmarks

    /// A bookmark for a file the shelf is about to hold.
    ///
    /// **Security-scoped, falling back to plain**, and the reason is not the sandbox — Isleta is not
    /// sandboxed (§3) and has no scope to enter. Measured on macOS 27.0 from an unsandboxed process:
    ///
    /// | | |
    /// |---|---|
    /// | `bookmarkData(options: [.withSecurityScope])` | succeeds, 872 bytes against the plain form's 1172 |
    /// | resolving that data with `[]` — **no** option | succeeds |
    /// | resolving *plain* data with `[.withSecurityScope]` | throws `NSCocoaErrorDomain` 259, "isn't in the correct format" |
    /// | `startAccessingSecurityScopedResource()` on the resolved URL | returns true, and grants access nothing was denying |
    ///
    /// So the scoped form is strictly the more portable of the two — it is the one that resolves
    /// under either option — and taking it costs a `try?`. It is also the form that keeps working if
    /// this ever runs somewhere the plain one does not. `resolve` below reads with **no** options
    /// for the same measurement: one path that reads both forms, rather than a flag stored per item
    /// saying which kind it is, which is a field that can be wrong about the bytes beside it.
    ///
    /// Failing to make one at all is not a failure to hold the file: the raw URL still works for
    /// everything except relocation, so the item goes on the shelf either way.
    private static func bookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: - Dragging back out

    /// Where an item is now, and a fresh bookmark if the one on file has been outgrown.
    struct Resolution {

        let url: URL

        /// A replacement for the item's bookmark, or nil when the one it has is still good. Written
        /// back through `ShelfModel.refreshBookmark` so the *next* launch does not have to renew it
        /// again.
        let renewedBookmark: Data?
    }

    /// Where an item is *now*, resolving its bookmark, or nil if the file is gone.
    ///
    /// Called at the moment of the drag rather than kept fresh in the background, which would be a
    /// poll (§9) over files that mostly do not move. The answer is only needed when the user is
    /// about to hand the file to something else, and that is exactly when being wrong is expensive.
    /// The one other caller is the launch, where every restored item is resolved once.
    ///
    /// **`bookmarkDataIsStale` does not mean the file is gone, and the name is the trap.** Measured
    /// on macOS 27.0: a bookmark to a file that was then *renamed in place* resolves correctly, to
    /// the new name, and comes back with `isStale == true`. So a shelf that read that flag as death
    /// would mark every file the user filed away — which is the exact case the shelf holds bookmarks
    /// for — as missing, while handing back a URL that works perfectly. It means "this data is an
    /// older form, remake it", and remaking it is all that happens here. A genuinely deleted file
    /// throws instead: `NSCocoaErrorDomain` 4, measured in the same run.
    func resolve(_ item: ShelfItem) -> Resolution? {
        if let bookmark = item.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return Resolution(url: url, renewedBookmark: isStale ? Self.bookmark(for: url) : nil)
            }
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return nil }
        // No bookmark, or one that no longer resolves, but the path is still a file. Worth a
        // bookmark: the item was probably restored from a record written before bookmarks worked
        // for it, and without one it dies at the next rename.
        return Resolution(
            url: item.url,
            renewedBookmark: item.bookmark == nil ? Self.bookmark(for: item.url) : nil
        )
    }

    /// The dragging item for one shelf tile.
    ///
    /// - Parameter frame: the tile in the panel's y-down space, so the drag image lifts off the
    ///   island from exactly where the tile is drawn rather than jumping to the pointer.
    ///
    /// The pasteboard writer is the `NSURL` itself, not a promise. Isleta already has the file, so
    /// promising to produce it later would mean standing up an `NSFilePromiseProvider` and a queue
    /// to copy bytes the destination is perfectly capable of copying itself — and it would break
    /// the one thing that makes a shelf useful, which is that the receiving app gets a real file URL
    /// and can decide for itself whether to copy it, link it or just open it in place.
    func draggingItem(for item: ShelfItem, url: URL, in frame: CGRect) -> NSDraggingItem {
        let dragging = NSDraggingItem(pasteboardWriter: url as NSURL)
        // The system icon, not the tile's SF Symbol. The drag image is off the island, on the
        // user's own desktop, where the Finder icon is the shared vocabulary — §6.5's SF-Symbols
        // rule is about what Isleta draws *on* the notch.
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: frame.width, height: frame.width)
        dragging.setDraggingFrame(
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.width),
            contents: icon
        )
        return dragging
    }

    // MARK: - Across launches

    /// Where the shelf is written down.
    ///
    /// `~/Library/Application Support/Isleta/shelf.json`. Application Support rather than
    /// `~/Library/Logs` (where the log file lives, because Console lists it) or Caches (which the
    /// system may delete, and a shelf that empties itself when the disk gets tight is a shelf nobody
    /// trusts). Resolved once and held, because a failure to build the path is a failure to persist
    /// at all and there is nothing to gain by re-discovering it on every save.
    private lazy var recordURL: URL? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("Isleta", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // The path, not the user's files — this one is ours, and without it nothing below can
            // report anything either.
            IslandLog.shelf.error("could not create the shelf's storage directory: \(error.localizedDescription)")
            return nil
        }
        return directory.appendingPathComponent("shelf.json", isDirectory: false)
    }()

    /// The one outstanding write. At most one, replaced by whatever makes it wrong.
    private var pendingSave: Task<Void, Never>?

    /// What that write will contain. Held rather than captured, so a second change during the
    /// window updates the record instead of queueing a second write of a shelf that has moved on.
    private var pendingArchive: ShelfArchive?

    /// How long a change waits before it is written.
    ///
    /// Half a second, and the number is doing one job: **coalescing**. A reorder rearranges the
    /// array on every tile the pointer crosses, which for a drag across a full shelf is a dozen
    /// changes in under a second — and each one is a 30 KB encode and a file write. The debounce
    /// turns that into one write when the user lets go. It is not a performance flourish: §9 forbids
    /// work on the idle path, and a shelf that wrote on every drag sample would be doing filesystem
    /// I/O at trackpad frequency.
    ///
    /// A one-shot `Task.sleep`, not a `Timer`, and none exists at any other time.
    private static let saveDebounce = Duration.milliseconds(500)

    /// The shelf as it was left, resolved against the disk as it is now.
    ///
    /// Every entry is resolved here rather than lazily, which is the one place this class does I/O
    /// proportional to the shelf's size — thirty bookmark resolutions at launch, against §9's 300 ms
    /// budget. It is done up front because the alternative is a tile that looks fine until it is
    /// touched: the shelf's whole claim is that what it shows is there, and a dead entry has to be
    /// visibly dead from the first frame rather than at the moment the user tries to use it.
    ///
    /// A record that cannot be read is reported and then ignored. Starting empty is the only honest
    /// answer — there is no half of a shelf worth showing — and the report is what stops that being
    /// silent.
    func restore() -> [ShelfItem] {
        guard let recordURL, FileManager.default.fileExists(atPath: recordURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: recordURL)
            guard let archive = try ShelfArchive.decoded(from: data) else {
                // A record from a later build. Not an error, and not something to overwrite either:
                // leaving it alone is what lets the user go back to the newer build with their shelf
                // intact.
                IslandLog.shelf.info("shelf record is from a newer version — starting empty")
                return []
            }
            // Renewals collected on the way through rather than applied inside the closure, because
            // `ShelfArchive.restore` is pure and takes a *locator*: it answers where a file is, and
            // has no business knowing that resolving one can also produce a better bookmark.
            var renewals: [UUID: Data] = [:]
            var items = archive.restore { entry in
                let resolution = resolve(
                    ShelfItem(
                        id: entry.id,
                        url: URL(fileURLWithPath: entry.path),
                        name: entry.name,
                        bookmark: entry.bookmark
                    )
                )
                if let renewed = resolution?.renewedBookmark { renewals[entry.id] = renewed }
                return resolution?.url
            }

            // A bookmark that was renewed at launch has to be *kept*, or it is renewed again at
            // every launch and — worse — an entry that had no bookmark at all never gains one, so
            // the first rename while Isleta is closed kills a file the shelf could have followed.
            // The record written here is what makes the restore idempotent.
            if !renewals.isEmpty {
                for index in items.indices {
                    guard let renewed = renewals[items[index].id] else { continue }
                    items[index].bookmark = renewed
                }
                scheduleSave(items)
            }

            // Counts only. What is on someone's shelf is their business; how many survived the night
            // is ours, and the missing count is the one number worth having in a bug report.
            let missing = items.count(where: \.isStale)
            IslandLog.shelf.info(
                "shelf restored: \(items.count) item(s), \(missing) missing, \(renewals.count) bookmark(s) renewed"
            )
            return items
        } catch {
            IslandLog.shelf.error("could not read the shelf record: \(error.localizedDescription)")
            return []
        }
    }

    /// Records the shelf, in half a second, unless something else changes first.
    ///
    /// The encode happens **now** and only the write is deferred, which is deliberate: `ShelfItem`
    /// is a value but the shelf is not, and capturing the model would write whatever it happens to
    /// hold when the task runs — a reorder that was undone, or a shelf the user cleared in the
    /// meantime. Taking the snapshot at the moment of the change means the last change to be made is
    /// the one on disk.
    func scheduleSave(_ items: [ShelfItem]) {
        pendingArchive = ShelfArchive.record(items)
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
    /// **Called from `applicationWillTerminate`, and it has to be synchronous for the reason
    /// CLAUDE.md records about that method: it returns into `exit()`, so teardown that is merely
    /// *scheduled* never happens.** The debounced task above is exactly that shape — correct on
    /// every path but this one, where the process dies with the sleep still in flight and the user's
    /// last drop is lost with it. This is the same lesson `ActivitySource.stopAndWait()` exists for,
    /// one layer up.
    func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        writePendingRecord()
    }

    private func writePendingRecord() {
        guard let archive = pendingArchive, let recordURL else { return }
        pendingArchive = nil
        do {
            // Atomic, so a crash mid-write leaves the previous shelf rather than half of this one.
            try archive.encoded().write(to: recordURL, options: .atomic)
        } catch {
            IslandLog.shelf.error("could not write the shelf record: \(error.localizedDescription)")
        }
    }

    // MARK: - Session storage

    private func makeSessionSubdirectory() -> URL? {
        let root = sessionDirectory ?? {
            let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("com.tryisleta.isleta", isDirectory: true)
                .appendingPathComponent("shelf-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            sessionDirectory = url
            return url
        }()

        // One subdirectory per promise, because two promises can perfectly well be called
        // "image.png" and the second would otherwise silently overwrite the first.
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            NSLog("[Isleta] shelf: could not create a directory for a promised file: \(error)")
            return nil
        }
    }

    /// Removes everything Isleta materialised, in one call, on quit.
    ///
    /// Not per item: a materialised file removed from the shelf is deleted here and nowhere else,
    /// because the user may still be dragging it somewhere at the moment they remove the tile, and
    /// deleting the bytes out from under a live drag is the one way this feature can lose data.
    /// The cost is a directory that lives as long as the process, bounded by what was dropped into
    /// it; the alternative costs someone a file.
    func cleanUpSession() {
        guard let sessionDirectory else { return }
        self.sessionDirectory = nil
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}
