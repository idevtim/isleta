import Foundation
import Testing

@testable import IslandActivities

/// What the island offers to do with a dropped file, and what it must never offer.
///
/// Everything here runs against strings. There are no files on disk, no `qlmanage`, no
/// `AVAssetExportSession` and no worker — which is the point: the parts of this feature that can be
/// *wrong* rather than merely broken are the mapping from a format to a route, the rule about what a
/// multi-file menu may claim, and the rule about which work is worth an island. The parts that need
/// real bytes live in `FileConversionEngine`, where they cannot be tested without them.
@Suite("File conversion catalog")
struct FileConversionTests {

    // MARK: - The mapping

    @Test("an image offers the other image formats, a PDF, and never itself",
          arguments: ["png", "jpg", "jpeg", "heic", "tiff", "gif"])
    func imageOffers(pathExtension: String) {
        let offers = FileConversion.offers(forPathExtension: pathExtension)
        #expect(!offers.isEmpty)
        #expect(offers.contains { $0.route == .imagesToPDF })
        // Every image route is ImageIO, and none of them is the format the file already is —
        // including through the other spelling, which is the case the filter exists for: a `.jpeg`
        // must not be offered "Convert to JPEG".
        let normalized = pathExtension == "jpeg" ? "jpg" : (pathExtension == "tif" ? "tiff" : pathExtension)
        for offer in offers where offer.route == .imageEncode {
            #expect(offer.target.pathExtension != normalized)
        }
    }

    @Test("SVG never goes through ImageIO")
    func vectorRoute() {
        let offers = FileConversion.offers(forPathExtension: "svg")
        #expect(!offers.isEmpty)
        // `CGImageSourceCreateWithURL` returns a *non-nil* source for an SVG whose type is nil and
        // whose count is 0, so a catalog that routed vectors through `imageEncode` would produce a
        // guard that passes and a conversion that silently writes nothing.
        #expect(offers.allSatisfy { $0.route == .vectorRaster })
    }

    @Test("a spreadsheet or a deck never goes through the rich-text importer",
          arguments: ["xlsx", "xls", "pptx", "ppt", "csv", "numbers", "key", "pages"])
    func sheetRoute(pathExtension: String) {
        let offers = FileConversion.offers(forPathExtension: pathExtension)
        // `NSAttributedString(url:)` reads an XLSX *successfully*, reports the correct document
        // type, and returns `length == 0` — a blank 3,740-byte PDF with a zero exit code. This is
        // the one mapping in the file whose failure is silent rather than loud.
        #expect(offers.allSatisfy { $0.route == .quickLookPDF })
        #expect(offers.allSatisfy { $0.target.pathExtension == "pdf" })
    }

    @Test("a Word document does go through the rich-text importer",
          arguments: ["doc", "docx", "rtf", "html", "txt"])
    func documentRoute(pathExtension: String) {
        let offers = FileConversion.offers(forPathExtension: pathExtension)
        #expect(offers.allSatisfy { $0.route == .textKitPDF })
    }

    @Test("an unknown extension offers nothing rather than guessing")
    func unknown() {
        #expect(FileConversion.offers(forPathExtension: "sparkle").isEmpty)
        #expect(FileConversion.offers(forPathExtension: "").isEmpty)
        #expect(FileConversion.hasOffers(forPathExtension: "png"))
    }

    @Test("the extension is read the way a user would type it")
    func normalization() {
        #expect(FileConversion.offers(forPathExtension: ".PNG").isEmpty == false)
        #expect(
            FileConversion.offers(forPathExtension: "PNG").map(\.id)
                == FileConversion.offers(forPathExtension: "png").map(\.id)
        )
    }

    // MARK: - MP3

    /// macOS decodes MP3 and will not encode it, below AVFoundation:
    /// `kAudioFormatProperty_EncodeFormatIDs` has no `.mp3`, `AVAssetWriter(fileType: .mp3)` raises
    /// an **uncatchable** ObjC exception rather than returning an error, and `afconvert -hf` lists
    /// `'MPG3'` as a file format while failing on it. So no route may target it — and the failure if
    /// one ever did would not be an error the user could see, it would be a process that dies.
    @Test("nothing offers to write an MP3",
          arguments: ["mp3", "wav", "m4a", "aiff", "flac", "mp4", "mov"])
    func mp3IsNeverATarget(pathExtension: String) {
        let offers = FileConversion.offers(forPathExtension: pathExtension)
        #expect(offers.allSatisfy { $0.target.pathExtension != "mp3" })
    }

    /// MKV is out for a different reason and must stay out for it: AVFoundation reads no Matroska,
    /// and the remux needs an `ffmpeg` this build does not vendor.
    @Test("Matroska is not offered at all")
    func matroska() {
        #expect(FileConversion.offers(forPathExtension: "mkv").isEmpty)
        #expect(FileConversion.offers(forPathExtension: "webm").isEmpty)
    }

    // MARK: - The readability gate

    /// `AVAssetExportSession.supportedFileTypes` answered thirteen compatible types for a file
    /// `load(.isReadable)` throws `-11828` for — the same list as for a working MP4. Every route
    /// that goes through AVFoundation therefore has to ask the *asset*, and this is where that rule
    /// is written down rather than left to the engine remembering it.
    @Test("every AVFoundation route asks the asset and no other route pretends to",
          arguments: ConversionRoute.allCases)
    func readabilityGate(route: ConversionRoute) {
        let usesAVFoundation: Set<ConversionRoute> = [
            .mediaPassthrough, .mediaAudioM4A, .mediaHEVC, .transcribe,
        ]
        #expect(route.asksTheAsset == usesAVFoundation.contains(route))
    }

    /// The two routes that spawn something inside the worker are the two that need a hard deadline:
    /// `qlmanage -p` exits 0 having produced nothing and `qlmanage -t` never returns at all, so
    /// neither an exit code nor stderr is load-bearing for either of them.
    @Test("only the routes that spawn a tool are marked as spawning one")
    func helpers() {
        #expect(ConversionRoute.quickLookPDF.spawnsHelper)
        #expect(ConversionRoute.audioEncode.spawnsHelper)
        #expect(!ConversionRoute.textKitPDF.spawnsHelper)
        #expect(!ConversionRoute.imageEncode.spawnsHelper)
    }

    // MARK: - What is worth an island

    @Test("only seconds-long work gets a progress activity")
    func progressClasses() {
        #expect(ConversionProgressClass.tracked.isWorthAnActivity)
        #expect(!ConversionProgressClass.beat.isWorthAnActivity)
        #expect(!ConversionProgressClass.instant.isWorthAnActivity)
    }

    /// Measured: JPEG 80 ms and TIFF 62 ms against HEIC 167 ms, GIF 268 ms and PNG 371 ms. The
    /// boundary is 100 ms and the two below it draw nothing at all.
    @Test("the image classes follow the measurements rather than the format's reputation")
    func imageProgress() {
        let fromPNG = FileConversion.offers(forPathExtension: "png")
        let jpeg = fromPNG.first { $0.target.pathExtension == "jpg" }
        let heic = fromPNG.first { $0.target.pathExtension == "heic" }
        #expect(jpeg?.progress == .instant)
        #expect(heic?.progress == .beat)
    }

    /// A sheet is 80 ms at eight columns and 2.5 s at two thousand rows, and nothing short of
    /// reading the file says which is in front of you — so it takes the slower class. An announced
    /// job that finishes early is an island that was quick; an unannounced one that takes two and a
    /// half seconds is an island that has hung.
    @Test("work whose cost depends on the file takes the slower class")
    func straddlingClasses() {
        #expect(FileConversion.offers(forPathExtension: "xlsx").allSatisfy { $0.progress == .tracked })
        #expect(FileConversion.offers(forPathExtension: "mp4").first { $0.route == .mediaHEVC }?.progress == .tracked)
        #expect(FileConversion.offers(forPathExtension: "m4a").first { $0.route == .transcribe }?.progress == .tracked)
        // A container remux is 42 ms for ten seconds of 1080p and 103 ms for sixty. It stays silent.
        #expect(FileConversion.offers(forPathExtension: "mov").first { $0.route == .mediaPassthrough }?.progress == .instant)
    }

    @Test("transcription is offered for audio and for video containers, and for nothing else")
    func transcribable() {
        #expect(FileConversion.isTranscribable(pathExtension: "m4a"))
        #expect(FileConversion.isTranscribable(pathExtension: "mp4"))
        #expect(FileConversion.isTranscribable(pathExtension: "mov"))
        #expect(!FileConversion.isTranscribable(pathExtension: "png"))
        #expect(!FileConversion.isTranscribable(pathExtension: "docx"))
    }
}

@Suite("Drop actions")
struct DropActionTests {

    private func item(_ pathExtension: String, stale: Bool = false) -> DropActionItem {
        DropActionItem(pathExtension: pathExtension, isStale: stale)
    }

    @Test("nothing at all is offered for an empty set")
    func empty() {
        #expect(DropAction.menu(for: []).isEmpty)
    }

    /// Not a menu of disabled rows. A menu whose every row refuses is worse than no menu, and the
    /// tile already says the file is missing.
    @Test("a shelf of dead references offers nothing")
    func allStale() {
        #expect(DropAction.menu(for: [item("png", stale: true), item("mp4", stale: true)]).isEmpty)
    }

    @Test("dead references are dropped before anything is decided")
    func someStale() {
        let mixed = DropAction.menu(for: [item("png"), item("xlsx", stale: true)])
        let live = DropAction.menu(for: [item("png")])
        #expect(mixed.map(\.id) == live.map(\.id))
    }

    @Test("the four that need no conversion are always there")
    func fixedRows() {
        let menu = DropAction.menu(for: [item("sparkle")])
        #expect(menu.map(\.id) == ["airdrop", "reveal", "copy", "move"])
    }

    /// The intersection, not the union, and it is the rule that makes a multi-file menu honest:
    /// "Convert to JPEG" over a PNG and a spreadsheet cannot mean anything, and offering it would
    /// either convert one file and skip the other or fail halfway with two files in two states.
    @Test("a conversion is offered only when every file can do it")
    func intersection() {
        let mixed = DropAction.menu(for: [item("png"), item("xlsx")])
        #expect(!mixed.contains { if case .convert = $0 { return true } else { return false } })

        let bothImages = DropAction.menu(for: [item("png"), item("heic")])
        let conversions = bothImages.compactMap { action -> ConversionOffer? in
            if case .convert(let offer) = action { return offer } else { return nil }
        }
        // Both can become JPEG and both can become a PDF; neither may be offered its own format,
        // so PNG is absent because one of the two already is one.
        #expect(conversions.contains { $0.target.pathExtension == "jpg" })
        #expect(conversions.contains { $0.route == .imagesToPDF })
        #expect(!conversions.contains { $0.target.pathExtension == "png" })
    }

    /// Order comes from the first item, so a menu does not reshuffle as the selection grows.
    @Test("the order is the first file's order")
    func order() {
        let one = DropAction.menu(for: [item("png")])
        let two = DropAction.menu(for: [item("png"), item("heic")])
        let onlyShared = Set(two.map(\.id))
        #expect(one.filter { onlyShared.contains($0.id) }.map(\.id) == two.map(\.id))
    }

    @Test("exactly one row leaves the user's original somewhere else")
    func destructive() {
        let menu = DropAction.menu(for: [item("png")])
        #expect(menu.filter(\.movesTheOriginal).map(\.id) == ["move"])
    }

    /// The two halves of this menu are completely different mechanisms — an AppKit call that is
    /// finished before the next frame, and a spawn that can peak at 450 MB — and the app shell
    /// branches on exactly this.
    @Test("only conversions run in a child process")
    func childProcesses() {
        let menu = DropAction.menu(for: [item("mp4")])
        for action in menu {
            if case .convert = action {
                #expect(action.runsInAChildProcess)
            } else {
                #expect(!action.runsInAChildProcess)
            }
        }
    }

    @Test("every row has a glyph and words of its own", arguments: [
        DropAction.airDrop, .revealInFinder, .copyToFolder, .moveToFolder,
    ])
    func labels(action: DropAction) {
        #expect(!action.title.isEmpty)
        #expect(!action.symbol.isEmpty)
    }
}

@Suite("File action activity")
struct FileActionActivityTests {

    private func job(_ stage: FileActionStage) -> FileActionJob {
        FileActionJob(
            id: ActivityID("test.job"),
            action: "Convert to JPEG",
            symbol: "wand.and.rays",
            fileCount: 3,
            stage: stage
        )
    }

    /// `fileAction`'s kind default is `.never` — work ends when the source says it ends — and the
    /// *instance* carries the dwell for the two states that are over. A finished job with no expiry
    /// is an island stuck on a checkmark.
    @Test("a running job never expires and a finished one always does")
    func expiry() {
        #expect(BuiltInActivity.fileAction(job(.running(fraction: nil))).expiry == .never)
        #expect(BuiltInActivity.fileAction(job(.finished(produced: 3))).expiry != .never)
        #expect(BuiltInActivity.fileAction(job(.failed(reason: "no"))).expiry != .never)
    }

    /// `nil` is a real answer rather than zero: the TextKit and ImageIO routes have nothing to
    /// report, and a bar sitting at 0 % for a whole job is a worse lie than an indeterminate one.
    @Test("a route that cannot report progress draws an indeterminate value")
    func indeterminate() {
        let activity = BuiltInActivity.fileAction(job(.running(fraction: nil)))
        #expect(activity.presentations.trailing.value == .indeterminate)
        let measured = BuiltInActivity.fileAction(job(.running(fraction: 0.5)))
        #expect(measured.presentations.trailing.value == .fraction(0.5))
    }

    /// The activity ends up in a log line and on a screen somebody might be sharing. It carries a
    /// count and the menu's own words, and there is no field on `FileActionJob` that could hold a
    /// name — which is the point of the type.
    @Test("nothing in the activity can carry a file name")
    func noNames() {
        let activity = BuiltInActivity.fileAction(job(.finished(produced: 2)))
        let strings = [
            activity.presentations.compact.title,
            activity.presentations.expanded.title,
            activity.presentations.expanded.subtitle,
        ].compactMap { $0 }
        #expect(strings.allSatisfy { !$0.contains("/") })
        #expect(activity.presentations.expanded.subtitle == "2 files on the shelf")
    }

    /// `fileAction` is plural — two files can convert at once — so each job needs its own identity
    /// or the second would be an *update* to the first and the user would watch one bar do the work
    /// of two.
    @Test("two jobs are two activities")
    func plural() {
        #expect(ActivityKind.fileAction.singletonID == nil)
        let a = BuiltInActivity.fileAction(job(.running(fraction: 0)))
        let b = BuiltInActivity.fileAction(
            FileActionJob(id: ActivityID("other"), action: "Transcribe", symbol: "text.bubble", fileCount: 1)
        )
        #expect(a.id != b.id)
    }
}

/// Copy link's row, and the two cases where it must not be drawn.
@Suite("Copy link in the actions menu")
struct CopyLinkMenuTests {

    private func item(_ ext: String, stale: Bool = false) -> DropActionItem {
        DropActionItem(pathExtension: ext, isStale: stale)
    }

    @Test("it is not offered unless the provider says this file can produce one")
    func theProviderDecides() {
        // The row is never drawn as a dead one — the provider answers `.copyLink` or
        // `.airDropInstead(reason)`, and this package cannot see it, which is why the answer is a
        // parameter rather than a rule here.
        #expect(DropAction.menu(for: [item("png")]).contains(.copyLink) == false)
        #expect(DropAction.menu(for: [item("png")], canCopyLink: true).contains(.copyLink))
    }

    @Test("it is never offered for more than one file")
    func oneFileOnly() {
        // A link is per file. "Copy Link" over three of them would put one link on the clipboard
        // and silently drop two, or three and mean none of them.
        let many = DropAction.menu(for: [item("png"), item("heic")], canCopyLink: true)
        #expect(many.contains(.copyLink) == false)
    }

    @Test("a dead reference is not offered a link")
    func staleIsNotOffered() {
        // Consistent with every other row: stale items are dropped before anything is decided, and
        // the tile already says the file is missing.
        #expect(DropAction.menu(for: [item("png", stale: true)], canCopyLink: true).isEmpty)
    }

    @Test("it sits beside AirDrop, which is its own fallback")
    func itSitsBesideAirDrop() {
        // The two rows answer the same question — get this to somebody else — and
        // `ShareLinkAffordance` names AirDrop as what to draw when the link cannot be made. Next to
        // each other, so the substitution is a row changing rather than the menu reshuffling.
        let menu = DropAction.menu(for: [item("png")], canCopyLink: true)
        let air = try! #require(menu.firstIndex(of: .airDrop))
        let link = try! #require(menu.firstIndex(of: .copyLink))
        #expect(link == air + 1)
    }

    @Test("the rest of the menu is unchanged by it")
    func nothingElseMoves() {
        let without = DropAction.menu(for: [item("png")])
        let with = DropAction.menu(for: [item("png")], canCopyLink: true)
        #expect(with.filter { $0 != .copyLink } == without)
    }
}
