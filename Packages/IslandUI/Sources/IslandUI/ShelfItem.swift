import Foundation
import UniformTypeIdentifiers

/// One thing the shelf is holding.
///
/// ## What the shelf actually holds, and what it costs
///
/// A **reference**, not a copy: the `url` of the file where the user already had it, plus the
/// bookmark that keeps that reference alive across a rename or a move. Three options were weighed
/// and this is the only one that is honest about what a shelf is.
///
/// - **Copying every drop into a private store** makes the shelf robust against the original being
///   deleted, and wrong in every other way. Dropping a 4GB video would stall the drag on a file
///   copy and then hold a second 4GB on disk that the user cannot see and did not ask for; and
///   dragging it back out would produce a copy of a copy, so a file "moved" through the shelf would
///   still be sitting in Downloads.
/// - **A bare `URL`** is free and dies at the first rename. `Downloads/screenshot.png` renamed to
///   `receipt.png` is a dead reference with no way to notice, and the shelf would offer the user a
///   file that is not there.
/// - **A bookmark** (`isReferenced`) survives renames and moves, which is the case that actually
///   happens: the user drops a download onto the shelf and then files it away. It dies only if the
///   file is genuinely deleted, which `isStale` records and the tile shows — the shelf says "this
///   is gone" rather than handing a dead URL to whatever the user drags it into.
///
/// The accepted trade is therefore: **a deleted original empties its slot, and the shelf never
/// silently doubles the user's disk usage.** No security scoping is needed or used — Isleta is not
/// sandboxed (§3), so the bookmark is a plain one.
///
/// **Promised files are the exception, and they have to be.** A drag out of Mail, Photos or a
/// browser carries no file at all, only a promise to produce one; there is no URL to hold, so the
/// bytes are received into the session's own directory and `isMaterialized` records that we own
/// them. Those are the only files Isleta ever writes, and they are deleted together when it quits.
public struct ShelfItem: Identifiable, Equatable, Sendable {

    public let id: UUID

    /// Where the file is now. Refreshed from `bookmark` when it is resolved, so a file the user
    /// moved after dropping it still drags out correctly.
    public var url: URL

    /// What the tile says. The file's own name — never a path, which would not fit and would leak
    /// the shape of someone's home directory onto their screen.
    public var name: String

    /// SF Symbol only (§6.5). See `ShelfItem.symbolName(for:)`.
    public var symbolName: String

    /// Reopens `url` after a rename or a move. Nil when the bookmark could not be made, which is
    /// not fatal: the raw URL still works for everything except relocation.
    public var bookmark: Data?

    /// True when Isleta wrote these bytes itself, receiving a file promise. Materialised files are
    /// the only ones it may delete.
    public var isMaterialized: Bool

    /// The reference no longer resolves — the user deleted the original. Recorded rather than
    /// acted on: the tile shows it, and the item is not draggable.
    public var isStale: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        symbolName: String? = nil,
        bookmark: Data? = nil,
        isMaterialized: Bool = false,
        isStale: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.symbolName = symbolName ?? Self.symbolName(for: url)
        self.bookmark = bookmark
        self.isMaterialized = isMaterialized
        self.isStale = isStale
    }

    /// The glyph a file gets, by type rather than by extension.
    ///
    /// Asked of `UTType`, which resolves `.jpeg`, `.jpg`, `.heic` and every other spelling to the
    /// same conformance — an extension table would need every one of them and would still miss the
    /// next format Apple ships. Nothing here touches the filesystem: the type is derived from the
    /// name, so this is pure enough to test and cheap enough to call while a drag is in flight.
    ///
    /// **SF Symbols rather than the file's real Finder icon**, which is the obvious alternative and
    /// is deliberately not taken. §6.5 allows SF Pro and SF Symbols and nothing else, and the
    /// island is pure `#000000` against the bezel — a row of full-color app icons on it reads as a
    /// palette of stickers stuck to the notch rather than as part of the machine. It also keeps
    /// `ShelfItem` `Sendable` and this whole file free of AppKit, which is what lets IslandUI still
    /// build and preview with nothing granted. The cost is that two PNGs look identical on the
    /// shelf; the name under the tile is what tells them apart. A QuickLook thumbnail is the
    /// obvious upgrade and needs an async image cache, which is a milestone of its own.
    public static func symbolName(for url: URL) -> String {
        symbolName(forPathExtension: url.pathExtension)
    }

    public static func symbolName(forPathExtension pathExtension: String) -> String {
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return "doc"
        }
        if type.conforms(to: .folder) { return "folder" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
