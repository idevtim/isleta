import Foundation

/// What the shelf is written down as, so a file dropped yesterday is still there today.
///
/// Pure: it encodes, decodes, and states the two rules that decide what survives a launch. Nothing
/// here opens a file — `ShelfStore` owns the disk, and hands the resolver in — which is what lets
/// the rules be tested against a list of names with nothing on disk at all.
///
/// ## Where it is written, and why not the two obvious places
///
/// **Not SwiftData.** CLAUDE.md's measurement for the config record applies unchanged and more
/// strongly: a `ModelContainer` costs 15–21 ms and ~6 MB at launch against a 300 ms budget, to hold
/// a list of at most thirty records with no queries, no relationships and no history.
///
/// **Not `UserDefaults` either**, which is where the config record lives. A bookmark is about a
/// kilobyte, so a full shelf is ~30 KB of base64 in a plist that cfprefsd reads, caches and
/// rewrites for every unrelated setting change. The config record is five values; this is a data
/// file, and it goes in a file.
///
/// ## The two rules
///
/// **A materialised file is not written down.** Bytes received from a file promise live in a
/// directory named for this process, which `ShelfStore.cleanUpSession()` deletes on quit — so an
/// entry pointing into it is guaranteed dead on the next launch. Writing it anyway would restore a
/// shelf of tiles that are all missing, on a Mac where nothing went wrong.
///
/// **A file that is gone keeps its tile.** `restore` marks it and does not drop it, because a tile
/// that vanishes between launches is indistinguishable from the shelf having failed to load — and
/// the shelf then has no way to tell the user that the file *they* deleted is the reason. A dead
/// tile says so, does not drag out (`ShelfController.itemsToDragOut` resolves at the moment of the
/// drag), and can be removed like any other.
public struct ShelfArchive: Codable, Equatable, Sendable {

    /// One held file, as written down.
    ///
    /// The path is stored **beside** the bookmark rather than derived from it, and it is not
    /// redundancy for its own sake: a bookmark that fails to resolve has nothing to say about what
    /// it used to point at, so without the path a dead tile would have no name to show and would be
    /// a blank chip with a warning glyph. It is also the fallback for a bookmark that could not be
    /// made in the first place.
    public struct Entry: Codable, Equatable, Sendable {

        public var id: UUID
        public var path: String
        public var name: String
        public var bookmark: Data?

        public init(id: UUID, path: String, name: String, bookmark: Data?) {
            self.id = id
            self.path = path
            self.name = name
            self.bookmark = bookmark
        }
    }

    /// Bumped when the shape of `Entry` changes in a way an older build cannot read.
    ///
    /// Read strictly in one direction only: a record from a *newer* version is discarded rather than
    /// half-decoded, because a user who has run a later build and gone back is better served by an
    /// empty shelf than by one where half the tiles are wrong. A record from an older version is
    /// decoded on a best effort — every field added since must therefore be optional, which is the
    /// same discipline `SettingsMigration` keeps.
    public static let currentVersion = 1

    public var version: Int
    public var entries: [Entry]

    public init(version: Int = ShelfArchive.currentVersion, entries: [Entry]) {
        self.version = version
        self.entries = entries
    }

    /// What to write for a shelf, materialised files left out.
    ///
    /// - Parameter bookmark: how to make a bookmark for one item. Handed in rather than called,
    ///   because making one is I/O and this type does none — and because the caller already has the
    ///   bookmark from the drop in the overwhelmingly common case, so re-deriving it here would
    ///   touch the disk once per item per save.
    public static func record(
        _ items: [ShelfItem],
        bookmark: (ShelfItem) -> Data? = { $0.bookmark }
    ) -> Self {
        Self(entries: items.compactMap { item in
            guard !item.isMaterialized else { return nil }
            return Entry(
                id: item.id,
                path: item.url.path,
                name: item.name,
                bookmark: bookmark(item)
            )
        })
    }

    /// The shelf this record restores to.
    ///
    /// - Parameter locate: where an entry's file is now, or nil if it is gone. The whole of the
    ///   filesystem's involvement, in one closure, so the rule below can be exercised with a
    ///   dictionary.
    ///
    /// Three outcomes, and each is a decision:
    ///
    /// - **Resolved somewhere new** — the user filed the file away after dropping it, which is the
    ///   case bookmarks exist for. The tile adopts the new URL *and the new name*, because a tile
    ///   that says `screenshot.png` for a file now called `receipt.png` is worse than one that
    ///   says nothing.
    /// - **Resolved where it was** — the ordinary case, and nothing changes.
    /// - **Gone** — kept, marked, named from the path that was written down.
    ///
    /// The order is the order it was written in, and the capacity clamp keeps the newest, which is
    /// `ShelfContents(items:)`'s own rule rather than a second one stated here.
    public func restore(locate: (Entry) -> URL?) -> [ShelfItem] {
        entries.map { entry in
            guard let url = locate(entry) else {
                return ShelfItem(
                    id: entry.id,
                    url: URL(fileURLWithPath: entry.path),
                    name: entry.name,
                    bookmark: entry.bookmark,
                    isMaterialized: false,
                    isStale: true
                )
            }
            return ShelfItem(
                id: entry.id,
                url: url,
                name: url.lastPathComponent,
                bookmark: entry.bookmark,
                isMaterialized: false,
                isStale: false
            )
        }
    }

    // MARK: - Bytes

    /// JSON, and pretty-printing is deliberately off: this is a data file rather than something a
    /// person edits, and 30 KB of base64 bookmark is not made readable by newlines.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a record, or nil for one this build must not read.
    ///
    /// Throws for a corrupt file — which the caller reports and then starts empty — and returns nil
    /// for a *newer* schema, which is not an error and must not be logged as one.
    public static func decoded(from data: Data) throws -> Self? {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.version <= currentVersion else { return nil }
        return archive
    }
}
