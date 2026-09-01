import Foundation

/// Where a file named by a drop-history row actually is, now.
///
/// ## Four answers, because "the file is gone" is four different things
///
/// A row in the drop history names a file the user's own machine may have done anything to since.
/// The naive implementation asks `FileManager.fileExists` and has two answers; that is wrong in
/// three separate directions, and each wrong answer tells the user something false about their own
/// disk.
///
/// - **Renamed in place** is the case that looks like death and is not. A bookmark to a renamed file
///   resolves *correctly, to the new name*, and comes back with `bookmarkDataIsStale == true` —
///   measured on macOS 27.0 and recorded in CLAUDE.md. A row reading that flag as "gone" would mark
///   every file the user has since tidied up as missing while holding a URL that works perfectly.
///   `isStale` means "remake this bookmark", never "this file has been deleted".
/// - **Moved** is the same answer with a different rectangle: the bookmark resolves somewhere else,
///   and the record follows it — new path, new name, renewed bookmark — so the row takes the file's
///   current name rather than saying `screenshot.png` for a file now called `receipt.png`.
/// - **Deleted** is the genuine one. The bookmark throws (`NSCocoaErrorDomain` 4) and there is
///   nothing at the recorded path either. The entry is **kept and marked**, not dropped: this list's
///   claim is that the act happened, which stays true whatever the disk says afterwards, and a
///   history that quietly deleted the row for a deleted file would answer "where did that go" with
///   silence in exactly the case somebody is asking.
/// - **On a disk that is not connected** is the one the two-answer version gets actively wrong. It
///   is indistinguishable from deletion at the filesystem — the bookmark fails, the path is not
///   there — and it is not the same fact at all: telling somebody the video they converted onto
///   their external drive has been thrown away is a lie the app has no business telling. The
///   discriminator is free and needs no bookmark decoding: a path whose volume root is absent from
///   `FileManager.mountedVolumeURLs` is on a disk that is away, and the answer goes away by itself
///   when the disk comes back.
///
/// The decision is a **pure function of four facts** (`state(bookmarkResolved:...)`), so all four
/// branches — including the unmounted-volume one, which otherwise needs an external disk to
/// exercise — are testable with no filesystem at all. `DropHistoryResolver` is the thin layer that
/// goes and gets those four facts.
public enum DropHistoryFileState: Equatable, Sendable {

    /// It is where the record says it is.
    case here(URL)

    /// It resolved somewhere else — a rename, a move, or both. The record should follow, and the
    /// bookmark should be renewed if `isStale` said so.
    case moved(URL, renewedBookmark: Data?)

    /// The volume it lives on is not mounted. Carries the volume's own name so the row can say
    /// which disk to plug in rather than "it is somewhere else".
    case volumeUnavailable(volumeName: String)

    /// Deleted, on a disk that is present. The only one of the four that means what it says.
    case missing
}

/// The rule, and the I/O that feeds it.
///
/// The rule is `static` and pure; the resolver is a value that touches the disk exactly twice per
/// call and holds nothing. **Nothing here polls.** The question is only asked when a row is
/// clicked, which is the one moment the answer is needed and the one moment being wrong is
/// expensive — the same reasoning `ShelfStore.resolve` gives for not keeping bookmarks fresh in the
/// background over files that mostly do not move.
public struct DropHistoryResolver: Sendable {

    /// Every mounted volume's path, longest first. Injected so the rule can be exercised without a
    /// disk, and read once per call rather than once per row: a click resolves one row.
    private let mountedVolumePaths: @Sendable () -> [String]

    private let fileExists: @Sendable (String) -> Bool

    public init(
        mountedVolumePaths: @escaping @Sendable () -> [String] = { Self.systemMountedVolumePaths() },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.mountedVolumePaths = mountedVolumePaths
        self.fileExists = fileExists
    }

    /// Where the file behind one recorded path and bookmark is now.
    ///
    /// - Parameters:
    ///   - path: what was written down when the work was done.
    ///   - bookmark: the bookmark taken at the same moment, or nil if one could not be made.
    ///
    /// **Resolved with no options at all**, which reads both forms. Measured on macOS 27.0 from an
    /// unsandboxed process: a security-scoped bookmark resolves with *or* without
    /// `.withSecurityScope`, while a plain one resolved *with* it throws `NSCocoaErrorDomain` 259 —
    /// so reading with no options is the single path that reads both, and the record needs no flag
    /// saying which kind of bytes it is holding. `ShelfStore.bookmark(for:)` writes the scoped form
    /// for the same reason and this reads whatever it is given.
    public func state(path: String, bookmark: Data?) -> DropHistoryFileState {
        var resolved: URL?
        var renewed: Data?
        if let bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), fileExists(url.path) {
                resolved = url
                // The one thing `isStale` is allowed to cause. It fires on an ordinary rename in
                // place — CLAUDE.md's measurement — so it is a request to remake the data and never
                // a statement about the file.
                if isStale { renewed = Self.bookmark(for: url) }
            }
        }

        return Self.state(
            bookmarkResolved: resolved,
            renewedBookmark: renewed,
            recordedPath: path,
            existsAtRecordedPath: fileExists(path),
            mountedVolumePaths: mountedVolumePaths()
        )
    }

    /// The whole decision, as arithmetic over four facts.
    ///
    /// The order is load-bearing. A bookmark that resolved wins over everything, because it is the
    /// only one of the four inputs that can find a file the record no longer names correctly. The
    /// volume check is asked **before** `missing` and not after: the two are indistinguishable at
    /// the filesystem, so a `missing` reached first would never be revisited.
    public static func state(
        bookmarkResolved: URL?,
        renewedBookmark: Data?,
        recordedPath: String,
        existsAtRecordedPath: Bool,
        mountedVolumePaths: [String]
    ) -> DropHistoryFileState {
        if let resolved = bookmarkResolved {
            let recorded = URL(fileURLWithPath: recordedPath).standardizedFileURL
            return resolved.standardizedFileURL == recorded
                ? .here(resolved)
                : .moved(resolved, renewedBookmark: renewedBookmark)
        }
        if existsAtRecordedPath {
            // No bookmark, or one that no longer resolves, but the path is still a file. Worth
            // saying `here`: the record was probably written before bookmarks worked for it, and the
            // caller renews the bookmark from the URL it is handed.
            return .here(URL(fileURLWithPath: recordedPath))
        }
        if let volume = unmountedVolumeName(forPath: recordedPath, mountedVolumePaths: mountedVolumePaths) {
            return .volumeUnavailable(volumeName: volume)
        }
        return .missing
    }

    /// The name of the disk this path is on, when that disk is not currently mounted.
    ///
    /// **`/Volumes` is named in this rule, and the structural version that avoids naming it does not
    /// work.** The obvious implementation — "a path is on a mounted volume when some mounted
    /// volume's path is a component prefix of it" — answers *mounted* for every path on the machine,
    /// because `/` is always in the list and `/` is a prefix of everything, `/Volumes/Backup`
    /// included. Written that way it compiles, reads correctly, and reports every absent disk as a
    /// deleted file, which is the exact failure this function exists to prevent.
    ///
    /// So the question has to be asked where the answer lives. On macOS, `/Volumes/<name>` is the
    /// mount point for every volume that is not the boot volume, and a path under one is on a disk
    /// that is present **iff that mount point is itself in the mounted list**. Everything else — the
    /// user's home, `/private/var`, anything under a firmlink — is on the boot volume, which cannot
    /// be absent while this process is running, so it is answered nil without further asking.
    ///
    /// The comparison is component-wise, not a string prefix: a mounted `/Volumes/Backup` must not
    /// answer for a path on `/Volumes/Backup2`, which would turn an absent disk back into a deleted
    /// file for exactly the pair of disks somebody is most likely to own.
    static func unmountedVolumeName(forPath path: String, mountedVolumePaths: [String]) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            .filter { $0 != "/" }
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        let name = components[1]
        let mountPoint = ["Volumes", name]
        for volume in mountedVolumePaths {
            let volumeComponents = URL(fileURLWithPath: volume).standardizedFileURL.pathComponents
                .filter { $0 != "/" }
            if volumeComponents == mountPoint { return nil }
        }
        return name
    }

    /// A bookmark for a file this history is about to follow.
    ///
    /// **Security-scoped, falling back to plain**, which is `ShelfStore.bookmark(for:)`'s rule and
    /// is written twice rather than shared because the shelf's copy is in the app shell and this one
    /// is in a package the app shell depends on. The measurement behind it: the scoped form is 872
    /// bytes against the plain form's 1172 and resolves under *either* option, while a plain one
    /// resolved with `.withSecurityScope` throws `NSCocoaErrorDomain` 259 — so the scoped form is
    /// strictly the more portable of the two and costs a `try?`.
    public static func bookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Every mounted volume, from the system.
    ///
    /// `skipHiddenVolumes` is deliberately **off**. A hidden volume is still mounted, and the only
    /// question being asked here is whether the disk is attached — filtering by visibility would
    /// report a file on an attached-but-hidden volume as being on a disk that is away.
    public static func systemMountedVolumePaths() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map(\.path)
    }
}

extension DropHistoryFileState {

    /// The URL a click can act on, or nil for the two states where there is nothing to act on.
    public var url: URL? {
        switch self {
        case .here(let url): url
        case .moved(let url, _): url
        case .volumeUnavailable, .missing: nil
        }
    }

    /// What Isleta says about this state, in its own words.
    ///
    /// Isleta's words rather than the system's, and never a path — the `volumeUnavailable` case is
    /// the one that names something, and a volume name is the user's own label for a disk they are
    /// being asked to plug in, which is the only way that sentence can be useful.
    ///
    /// Nil for the two states that need no sentence: the file is there and the click just worked.
    public var explanation: String? {
        switch self {
        case .here, .moved:
            nil
        case .volumeUnavailable(let name):
            // The volume's name is the user's own label for a disk and travels as an argument; the
            // sentence around it is Isleta's.
            sourceText("dropHistory.volumeUnavailable", "\(name) isn't connected")
        case .missing:
            sourceText("dropHistory.missing", "That file has been deleted")
        }
    }

    /// Whether the row should keep offering to act on this file.
    ///
    /// True for an absent *volume*, which is a temporary fact about a cable, and false for a
    /// deletion, which is not.
    public var mayReturn: Bool {
        switch self {
        case .here, .moved, .volumeUnavailable: true
        case .missing: false
        }
    }
}
