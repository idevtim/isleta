import Foundation

/// One file, as much of it as the actions menu needs to know.
///
/// A name and an extension rather than a `URL`, for the reason `ShelfSearch` takes names: the rule
/// about what may be offered is the part that is easy to get subtly wrong, and it should be
/// checkable against a list of strings with no files, no island and no Finder. The app shell holds
/// the URLs.
public struct DropActionItem: Equatable, Sendable {

    public let pathExtension: String

    /// The reference no longer resolves — the file has been deleted. Kept here rather than filtered
    /// out by the caller because "what is offered for a shelf holding one live file and two dead
    /// ones" is exactly the question this type exists to answer, and a caller that pre-filters is a
    /// caller that can forget to.
    public let isStale: Bool

    public init(pathExtension: String, isStale: Bool = false) {
        self.pathExtension = pathExtension
        self.isStale = isStale
    }
}

/// Something the island can do with the files it is holding.
///
/// ## What is here, and the two that are deliberately not
///
/// **AirDrop ships and cannot be targeted.** `NSSharingService(named: .sendViaAirDrop)` reports
/// `canPerform` true for local and iCloud files alike and raises Apple's own picker.
/// `NSSharingService.recipients` is honored by Mail and Messages and **has no meaning for
/// AirDrop** — it is a picker, not an address — so there is no "send to Tim's iPhone" row and the
/// menu does not pretend there is. `Sharing.framework` vends `SFAirDropBrowser` /
/// `SFAirDropDiscoveryController` / `SFAirDropTransfer`, which would address a peer directly; the
/// 2026-08-23 decision permits private paths, so that is now a cost question rather than a policy
/// one, and it is a whole private surface for a picker Apple already draws well.
///
/// **A shareable link is here after all, and the note that said it was impossible was wrong about
/// the caller rather than about the evidence.** It said the CloudDocs call behind
/// `com.apple.CloudSharingUI.CopyLink` is refused at `bird` with `NSCocoaErrorDomain 4099`. It is —
/// when *we* make it. Invoking the extension is a different caller, and `bird` then does the
/// CloudKit work in its own name: measured 2026-08-23, a real
/// `https://www.icloud.com/iclouddrive/<token>` comes back in 1.68–4.13 s from a Developer ID
/// bundle signed `--options runtime`, with no consent sheet.
///
/// What survives from the old note, because it is still true and still load-bearing:
/// `NSSharingServiceNameCloudSharing` is not the route (it shares a `CKShare` over your own
/// container's records), Finder is not scriptable for it, and **`pbcopy` of a `file://` URL is not
/// a share link** however much it looks like one — it resolves for exactly one person on Earth.
/// `canPerform` is useless as a discriminator in both directions: true for `/private/tmp`, and
/// true for a synced file where an earlier measurement recorded false.
///
/// The row is drawn only when the provider says this file can produce one — see
/// `ShareLinkAffordance`, which answers `.copyLink` or `.airDropInstead(reason)`. That is the
/// difference between a menu that offers what it can do and one that offers everything and
/// apologizes.
public enum DropAction: Equatable, Sendable, Identifiable {

    case airDrop

    /// Finder, with the files selected. `NSWorkspace.activateFileViewerSelecting(_:)`.
    case revealInFinder

    /// Copy the files into a folder the user picks, leaving the originals where they are.
    case copyToFolder

    /// Move them. Separate from `copyToFolder` rather than a modifier on it, because these are the
    /// only two rows in this menu whose difference the user cannot undo by looking at the result:
    /// after a move the original is gone, and a menu that expressed that as a held-⌥ variant of one
    /// row would hide the destructive half behind a key nobody presses on a notch.
    case moveToFolder

    /// Copy a public iCloud link to the file, so it can be pasted to somebody who is not on this
    /// Mac. Only ever offered for a file iCloud Drive actually has — `ShareLinkAffordance` decides,
    /// and the fallback it names is AirDrop.
    case copyLink

    case convert(ConversionOffer)

    public var id: String {
        switch self {
        case .airDrop: "airdrop"
        case .revealInFinder: "reveal"
        case .copyToFolder: "copy"
        case .moveToFolder: "move"
        case .copyLink: "copylink"
        case .convert(let offer): "convert.\(offer.id)"
        }
    }

    public var title: String {
        switch self {
        // Apple's own name for the feature, and not localized — the same rule "Finder" and "Dock"
        // are held to. Recorded because macOS's own zh-Hans does translate it (隔空投送), so this
        // is a deliberate choice rather than an omission; see `README.md`'s Localization section.
        case .airDrop: "AirDrop"
        case .revealInFinder: activityText("dropAction.revealInFinder", "Reveal in Finder")
        case .copyToFolder: activityText("dropAction.copyToFolder", "Copy to Folder…")
        case .moveToFolder: activityText("dropAction.moveToFolder", "Move to Folder…")
        case .copyLink: activityText("dropAction.copyLink", "Copy Link")
        case .convert(let offer): offer.title
        }
    }

    /// SF Symbols only (§6.5).
    public var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .revealInFinder: "folder"
        case .copyToFolder: "doc.on.doc"
        case .moveToFolder: "arrow.right.doc.on.clipboard"
        case .copyLink: "link"
        case .convert(let offer):
            switch offer.route {
            case .transcribe: "text.bubble"
            case .mediaHEVC: "arrow.down.right.and.arrow.up.left"
            case .imagesToPDF, .textKitPDF, .quickLookPDF: "doc.richtext"
            default: "wand.and.rays"
            }
        }
    }

    /// Whether performing this leaves the user's original file somewhere else, or not at all.
    ///
    /// One row answers true, and the flag exists so the view can say so rather than so the runner
    /// can behave differently: a move is drawn in `.warning`, which is the same color the shelf
    /// already gives a file it can no longer find.
    public var movesTheOriginal: Bool { self == .moveToFolder }

    /// Whether this action's work happens in a child process, which is the whole of the difference
    /// between the two halves of this menu. AirDrop, Reveal and the two folder rows are AppKit calls
    /// on the main thread that finish before the next frame; every conversion is a spawn.
    public var runsInAChildProcess: Bool {
        if case .convert = self { return true }
        return false
    }

    // MARK: - What is offered

    /// The menu for a set of files, in the order it is drawn.
    ///
    /// ## Three rules, and the third is the only interesting one
    ///
    /// **A dead reference is not acted on.** Stale items are dropped before anything is decided, so
    /// a shelf holding one live file and two deleted ones offers exactly what the live one offers.
    /// Nothing is grayed: the tile already says the file is missing, and a second, quieter statement
    /// of the same fact in a menu is how a surface ends up explaining itself twice.
    ///
    /// **Nothing at all for an empty set.** Not a menu of disabled rows — an empty list, which the
    /// caller draws as "nothing to do here". A menu whose every row refuses is worse than no menu.
    ///
    /// **A conversion is offered only when it applies to *every* file.** The intersection, not the
    /// union, and it is the rule that makes a multi-file menu honest: "Convert to JPEG" over a PNG
    /// and a spreadsheet cannot mean anything, and offering it would either convert one file and
    /// silently skip the other or fail halfway with two files in two states. With one file selected
    /// the intersection is that file's own list, so the common case pays nothing for the rule.
    /// Order comes from the first item, so a menu does not reshuffle as the selection grows.
    /// - Parameter canCopyLink: whether *this* file can produce an iCloud link. Decided by the app
    ///   shell, because the answer needs `ShareLinkProviding` and this package cannot see
    ///   IslandSources — the same layering `SourceSettingsRow` follows, and the reason the row is
    ///   never drawn as a dead one. Ignored for a multi-file selection: a link is per file, and
    ///   "Copy Link" over three files would put one link on the clipboard and silently drop two,
    ///   or three and mean none of them.
    public static func menu(for items: [DropActionItem], canCopyLink: Bool = false) -> [DropAction] {
        let live = items.filter { !$0.isStale }
        guard !live.isEmpty else { return [] }

        var actions: [DropAction] = [.airDrop]
        // Beside AirDrop, because they are the two rows that answer the same question — "get this
        // to somebody else" — and `ShareLinkAffordance` names AirDrop as this row's own fallback.
        if canCopyLink, live.count == 1 { actions.append(.copyLink) }
        actions += [.revealInFinder, .copyToFolder, .moveToFolder]
        actions += sharedOffers(for: live).map { DropAction.convert($0) }
        return actions
    }

    /// The conversions every one of these files can do, in the first file's order.
    static func sharedOffers(for items: [DropActionItem]) -> [ConversionOffer] {
        guard let first = items.first else { return [] }
        let firstOffers = FileConversion.offers(forPathExtension: first.pathExtension)
        guard items.count > 1 else { return firstOffers }

        let shared = items.dropFirst().reduce(into: Set(firstOffers.map(\.id))) { result, item in
            let ids = Set(FileConversion.offers(forPathExtension: item.pathExtension).map(\.id))
            result.formIntersection(ids)
        }
        return firstOffers.filter { shared.contains($0.id) }
    }
}
