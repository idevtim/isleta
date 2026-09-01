import Foundation

/// What the drop history is written down as.
///
/// Pure: it encodes, decodes and states the one rule about what survives a launch. Nothing here
/// opens a file — `DropHistoryController` owns the disk — which is what lets the rules be exercised
/// against a list of values with nothing on disk at all. `ShelfArchive` next door is the same shape
/// for the same reasons, and the two deliberately do not share a type: they hold different records
/// with different lifetimes, and a shared envelope would give them one version number that neither
/// could bump on its own.
///
/// ## Where it goes, and not the two obvious places
///
/// `~/Library/Application Support/Isleta/drop-history.json`, beside `shelf.json`.
///
/// **Not SwiftData**, for the measurement CLAUDE.md records for the config record and `ShelfArchive`
/// repeats: a `ModelContainer` is 15–21 ms and ~6 MB at launch against a 300 ms budget, to hold at
/// most forty records with no queries and no relationships.
///
/// **Not `UserDefaults`**, where the config record lives. Every entry can carry a bookmark of about
/// a kilobyte, so a full history is tens of KB of base64 in a plist that cfprefsd reads, caches and
/// rewrites for every unrelated setting change.
///
/// **Not Caches**, which the system may delete. A history that empties itself when the disk gets
/// tight is a history nobody trusts, and this one is the answer to "where did that file go".
public struct DropHistoryArchive: Codable, Equatable, Sendable {

    /// Bumped when the shape of `DropHistoryEntry` changes in a way an older build cannot read.
    ///
    /// Read strictly in one direction, exactly as `ShelfArchive` reads its own: a record from a
    /// *newer* version is discarded rather than half-decoded, because a user who has run a later
    /// build and gone back is better served by an empty history than by one whose rows point at the
    /// wrong files. A record from an older version is decoded on a best effort, so every field added
    /// after this line must be optional — the discipline `SettingsMigration` keeps.
    public static let currentVersion = 1

    public var version: Int
    public var entries: [DropHistoryEntry]

    public init(version: Int = DropHistoryArchive.currentVersion, entries: [DropHistoryEntry]) {
        self.version = version
        self.entries = entries
    }

    /// What to write for a history.
    ///
    /// **Every entry is written, including the failures and including the ones whose files have
    /// since gone.** That is the difference between this record and the shelf's, and it is the whole
    /// point of the surface: the shelf claims that what it shows is *there*, so a dead tile is a
    /// problem it has to report; this claims only that the act *happened*, which stays true whatever
    /// the disk says afterwards. A history that quietly dropped the rows whose files were deleted
    /// would be a history that answers "where did that go" with silence in precisely the case
    /// somebody is asking.
    public static func record(_ entries: [DropHistoryEntry]) -> Self {
        Self(entries: entries)
    }

    /// JSON, sorted keys, no pretty-printing: a data file rather than something a person edits, and
    /// base64 bookmarks are not made readable by newlines.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decodes a record, or nil for one this build must not read.
    ///
    /// Throws for a corrupt file — which the caller reports and then starts empty — and returns nil
    /// for a *newer* schema, which is not an error and must not be logged as one.
    public static func decoded(from data: Data) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.version <= currentVersion else { return nil }
        return archive
    }
}
