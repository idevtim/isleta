import Foundation

/// One file, as the drop history remembers it.
///
/// The same three fields `ShelfArchive.Entry` keeps, and for the same reasons: the **path** is
/// stored beside the bookmark rather than derived from it, because a bookmark that fails to resolve
/// has nothing to say about what it used to point at — so without the path a row for a deleted file
/// would have no name to show. The **name** is stored rather than taken from the path at draw time
/// so a row keeps reading correctly after the file has gone.
public struct DropHistoryFile: Codable, Equatable, Sendable {

    public var path: String

    /// What the row says. The file's own name — never a path, which would not fit and would put the
    /// shape of someone's home directory on the notch.
    public var name: String

    /// Reopens the file after a rename or a move. Nil when one could not be made, which is not
    /// fatal: the path still works for everything except relocation.
    public var bookmark: Data?

    public init(path: String, name: String? = nil, bookmark: Data? = nil) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.bookmark = bookmark
    }
}

/// What Isleta did with a file the user dropped.
///
/// A closed vocabulary rather than a free string, for `ShortcutAction`'s reason: the row's glyph,
/// its verb, whether it can be run again and whether it could have produced a link are all decided
/// from this, and a free string would let each of those four questions be answered somewhere else.
///
/// It deliberately does **not** include `revealInFinder`. Every other row here records something
/// that changed — a file written, a file sent, a file moved, a link minted — and a history whose
/// rows include "you looked at this in the Finder" is a log of the user's browsing rather than a
/// record of work. Revealing is also the one action a row *performs*, so recording it would make
/// reading the history write to it.
public enum DropHistoryAction: String, Codable, Sendable, CaseIterable {

    /// A conversion. `offerID` says which one, so the row can be run again.
    case convert

    /// `SpeechAnalyzer`, in the same child process. Separate from `convert` because the verb is
    /// different and because what it produced is a transcript rather than another copy of the file.
    case transcribe

    /// The video compression route (`mediaHEVC`), which is a conversion whose target is the same
    /// container. Its own case for the same reason `DropAction` gives it its own title: "Convert to
    /// MP4" is not what happened.
    case compress

    /// Apple's picker was raised and the transfer was handed to it. **We are told it was shared,
    /// never to whom** — `NSSharingServiceDelegate` reports items, not recipients — so a row can
    /// say a file went out by AirDrop and can never say where.
    case airDrop

    case copyToFolder

    case moveToFolder

    /// A shareable link (Stage 3.7). The one action whose *result* is not a file, which is why
    /// `link` exists beside `results` and why `ShortcutAction.copyLastLink` has something to read.
    case shareLink

    /// SF Symbols only (§6.5). The same glyphs `DropAction.symbol` uses, so a row in the history
    /// and the menu row that started it are the same picture.
    public var symbol: String {
        switch self {
        case .convert: "wand.and.rays"
        case .transcribe: "text.bubble"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .airDrop: "airplayaudio"
        case .copyToFolder: "doc.on.doc"
        case .moveToFolder: "arrow.right.doc.on.clipboard"
        case .shareLink: "link"
        }
    }

    /// Whether asking for this again is a sensible offer.
    ///
    /// False for the three that would need the user to answer a question we did not record. AirDrop
    /// raises a picker, and the two folder rows raise a panel — running one of those "again" would
    /// put a modal window on screen from a list the user is reading, which is not a repeat of
    /// anything. A conversion took no input beyond the file, so it genuinely can be repeated; a
    /// share link is a request to the same service about the same file.
    public var isRepeatable: Bool {
        switch self {
        case .convert, .transcribe, .compress, .shareLink: true
        case .airDrop, .copyToFolder, .moveToFolder: false
        }
    }
}

/// One thing the island did to one or more of the user's files, and what came of it.
///
/// ## What is in it, and the one thing that never is
///
/// Names, paths and bookmarks for the files involved, plus Isleta's own words for the work. **Not
/// the contents of anything** — above all not a transcript, which is written to disk by the worker
/// and never enters this process at all (`ShelfActionController` records the same rule). A history
/// row for a transcription holds the name of the text file and not a syllable of what is in it.
///
/// None of it may ever reach `IslandLog` or the "Export Logs…" bundle. `DropHistoryModel` states
/// that rule where it is enforced.
public struct DropHistoryEntry: Codable, Equatable, Sendable, Identifiable {

    public let id: UUID

    public var action: DropHistoryAction

    /// What the row says, in the words the menu used: "Convert to JPEG", "Transcribe", "Move to
    /// Folder". Recorded rather than rebuilt from `action`, because the menu's own title is the only
    /// spelling that can be relied on to still mean the same thing after the catalog changes.
    public var title: String

    /// `ConversionOffer.id`, for the rows that can be run again. Nil for everything else.
    ///
    /// The identifier and not the offer: `ConversionOffer` is not `Codable` and is a *catalog* entry
    /// — a build that drops a measured route should drop the "Run again" button with it, which is
    /// exactly what happens when the id no longer resolves.
    public var offerID: String?

    /// The files the work was done to.
    public var sources: [DropHistoryFile]

    /// The files it produced, if any. Empty for AirDrop and for a copy or a move, which produce a
    /// file the shelf never sees and a file that is the same file.
    public var results: [DropHistoryFile]

    /// The link, for the one action that mints one. What `ShortcutAction.copyLastLink` copies.
    public var link: String?

    /// Isleta's own words for why it did not work — never the system's error text, and never
    /// anything carrying a path. Nil for the ordinary case.
    public var failure: String?

    public var finishedAt: Date

    public init(
        id: UUID = UUID(),
        action: DropHistoryAction,
        title: String,
        offerID: String? = nil,
        sources: [DropHistoryFile] = [],
        results: [DropHistoryFile] = [],
        link: String? = nil,
        failure: String? = nil,
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.offerID = offerID
        self.sources = sources
        self.results = results
        self.link = link
        self.failure = failure
        self.finishedAt = finishedAt
    }

    public var succeeded: Bool { failure == nil }

    /// The glyph, which is the action's unless it failed.
    ///
    /// A failed row is drawn as a failure first and as a conversion second: the question somebody
    /// scanning this list is asking is "did that work", and answering it with the same wand the
    /// successful row above uses makes them read every row's text to find out.
    public var symbol: String {
        succeeded ? action.symbol : "exclamationmark.triangle.fill"
    }

    /// The file a click on this row reveals: what it produced, or failing that what it was given.
    ///
    /// Results before sources, because the thing the user is looking for is the thing that did not
    /// exist before — "where did the JPEG go" is the question, and the HEIC was never lost. A failed
    /// row has no result, so it falls back to the source, which is the only file it can honestly
    /// point at.
    public var fileToReveal: DropHistoryFile? {
        results.first ?? sources.first
    }

    /// The second line: what came of it, or why it did not.
    ///
    /// A count once there is more than one, for `FileActionJob`'s reason — a row is one line of text
    /// on a notch, and three file names in it is a row nobody can read. The count is not a
    /// concession: "3 files" is what the user asked for and is what they will recognize.
    public var detail: String {
        if let failure { return failure }
        if let link { return link }
        if results.count == 1 { return results[0].name }
        if results.count > 1 { return islandText("dropHistory.fileCount", "\(results.count) files") }
        if sources.count == 1 { return sources[0].name }
        if sources.count > 1 { return islandText("dropHistory.fileCount", "\(sources.count) files") }
        return ""
    }

    /// Whether this row can offer to do the same thing again.
    ///
    /// Both halves are needed and neither is enough. The *action* has to be one that took no answer
    /// from the user (`isRepeatable`), and there has to be something recorded to act on — a failed
    /// conversion with no source left on file is a button that would raise an error, which is worse
    /// than no button. Whether the source still exists is **not** asked here: that costs a bookmark
    /// resolution per row per frame, and the answer is only needed at the moment the button is
    /// pressed. See `DropHistoryFileState`.
    public var canRunAgain: Bool {
        action.isRepeatable && !sources.isEmpty && (offerID != nil || action == .shareLink)
    }

    /// What VoiceOver reads: the work, then what came of it. The age is spoken by the row's own
    /// label, because "2h" read aloud is not a duration.
    public var accessibilityLabel: String {
        detail.isEmpty ? title : islandText("dropHistory.row.a11y", "\(title), \(detail)")
    }
}
