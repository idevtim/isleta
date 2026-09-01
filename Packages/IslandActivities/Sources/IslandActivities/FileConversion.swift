import Foundation

/// What a conversion is worth on screen.
///
/// The three classes come straight out of the conversion measurements in
/// `docs/PLATFORM-CONSTRAINTS.md` and they are
/// a *design* decision rather than a description: they say which jobs get an island and which do
/// not.
///
/// - **`.instant`** — under 100 ms. Nothing is drawn at all, because anything drawn for 80 ms is a
///   flicker. The result arriving on the shelf is the whole of the feedback.
/// - **`.beat`** — 100–500 ms. Still nothing of its own: the tile arriving animates on
///   `Motion.contentSwap`, which is already longer than the work, so an activity would be a
///   progress bar that appears after the job it describes has finished.
/// - **`.tracked`** — seconds. A real `fileAction` activity, with a fraction in it, for as long as
///   the work runs.
///
/// **Where a route's measured time straddles a boundary, the slower class wins**, and the asymmetry
/// is the point: an announced job that finishes early is an island that was quick, while an
/// unannounced job that takes two and a half seconds is an island that has hung. `qlmanage` is the
/// case that forces the rule — an 8-column sheet is 80 ms and a 2,000-row one is 2.5 s, and nothing
/// short of reading the file says which is in front of you.
public enum ConversionProgressClass: String, Equatable, Sendable, CaseIterable {

    case instant
    case beat
    case tracked

    /// Whether this class publishes a `fileAction` activity. Exactly one of them does.
    public var isWorthAnActivity: Bool { self == .tracked }
}

/// The machinery behind one conversion.
///
/// Nine routes, each measured, each with a specific reason it is not the obvious call. This enum is
/// the shared vocabulary between the menu that offers a conversion (IslandUI) and the worker that
/// performs it (IslandSources) — the two must not each carry their own idea of what "convert an
/// XLSX" means, because the failure when they drift is a menu offering something nothing can do.
public enum ConversionRoute: String, Codable, Equatable, Sendable, CaseIterable {

    /// `CGImageSource` → `CGImageDestination`. JPEG 80 ms, HEIC 167 ms, PNG 371 ms on a 12 Mpx
    /// source.
    case imageEncode

    /// `CGImageDestinationCreateWithURL(url, "com.adobe.pdf", n, nil)` — n images, n pages.
    ///
    /// **Never `CGPDFContext`**, which is what multi-page PDF is *for* and is therefore what
    /// everyone reaches for: it re-encodes every image losslessly, so three photos came back as
    /// **65.7 MB in 1,885 ms** against **6.5 MB in 497 ms** for byte-identical pages through the
    /// image destination. `CGImageDestination` taking a page count is documented nowhere as a
    /// paginator and is ten times better at being one.
    case imagesToPDF

    /// `NSImage(contentsOf:)` → `NSBitmapImageRep`, for SVG. 23 ms off-main.
    ///
    /// **`CGImageSourceCreateWithURL` on an SVG returns a non-nil source**, which is the trap:
    /// the `guard let` passes, `CGImageSourceGetType` is nil, `GetCount` is 0, and everything after
    /// it is nil. ImageIO has no SVG reader and hands you a live object anyway.
    case vectorRaster

    /// `AVAssetExportSession` with `AVAssetExportPresetPassthrough` — a container remux. 10 s of
    /// 1080p in 42 ms, 60 s in 103 ms.
    case mediaPassthrough

    /// `AVAssetExportPresetAppleM4A`, 34 ms. The audio track out of anything AVFoundation can read,
    /// video included.
    case mediaAudioM4A

    /// `/usr/bin/afconvert`, 26–40 ms, for the uncompressed formats AVFoundation will not write.
    ///
    /// A system binary rather than a vendored one, and the distinction is the whole reason MP3 is
    /// absent from this file: **macOS decodes MP3 and will not encode it, below AVFoundation.**
    /// `kAudioFormatProperty_EncodeFormatIDs` has no `.mp3` while `DecodeFormatIDs` does;
    /// `AVAssetWriter(fileType: .mp3)` raises an *uncatchable* ObjC exception rather than returning
    /// an error, past a Swift `try` and out through `libc++abi`; and `afconvert -hf` lists
    /// **`'MPG3' = MPEG Layer 3`** as a file format and `'.mp3'` as a data format inside `m4af` and
    /// `caff` — both being a container's ability to *hold* an MP3 stream — while asking for either
    /// fails with `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')`. The table reads as a
    /// capability list and is not one. MP3 out needs a vendored `lame`, which this build does not
    /// carry; see the note in `Packages/IslandSources/README.md` for what shipping it would owe.
    case audioEncode

    /// `AVAssetExportPresetHEVC1920x1080`, the one video re-encode offered.
    ///
    /// **The cheaper-looking presets are the expensive ones.** This one genuinely re-encodes every
    /// frame and costs +18.5 MB; `1280x720` and `640x480` cost twenty-three times that, because the
    /// H.264 scaler takes a fixed ~450 MB allocation that is *flat in duration*. And
    /// `HighestQuality` / `1920x1080` on a 1080p source are silently passthrough — byte-identical
    /// to the passthrough preset — so timing a preset is not evidence it re-encoded anything.
    case mediaHEVC

    /// `NSAttributedString(url:)` → `NSTextStorage` + `NSLayoutManager` + one `NSTextContainer` per
    /// page → `CGPDFContext`. Nine pages of a 33 k-character DOCX in **62 ms, off-thread**.
    ///
    /// **Never `NSPrintOperation(view: NSTextView)`**, which is the documented way to paginate rich
    /// text and is main-thread-only in a way that does not fail politely: touching `NSTextView` from
    /// a background thread constructs a `TUINSWindow` and aborts the process with "NSWindow should
    /// only be instantiated on the main thread!", uncatchable. The trap underneath it is that the
    /// *expensive* half is fine off-thread — parsing a DOCX is 6 ms and an HTML file 290 ms — so
    /// parse-in-background-lay-out-on-main is exactly backwards from what the code permits.
    case textKitPDF

    /// `qlmanage -p -o <dir>` → the `Preview.html` inside the resulting `.qlpreview` bundle → the
    /// TextKit route above.
    ///
    /// Apple's Office QuickLook generator is on every Mac **with no Office and no LibreOffice
    /// installed**, which is what makes spreadsheets and decks reachable with no dependency at all.
    ///
    /// **Never `NSAttributedString(url:)` for XLSX or PPTX.** It reads them *successfully* — no
    /// throw, `documentAttributes[.documentType] == NSOfficeOpenXML`, the correct type — and returns
    /// `length == 0`, which through TextKit is a one-page, 3,740-byte, blank PDF with a zero exit
    /// code. Apple's OOXML importer is a *Word* importer that recognizes the container family and
    /// has no spreadsheet or presentation reader behind it.
    ///
    /// `qlmanage` needs a hard timeout **and** a did-a-file-appear check, because neither half of
    /// its reporting is load-bearing: `-p` prints `EXCEPTION TCMessageException: (null)`, says it
    /// "did not produce any preview", and **exits 0**; `-t` never returns at all.
    case quickLookPDF

    /// `SpeechAnalyzer` + `SpeechTranscriber`, 34–57× realtime, no permission of any kind.
    case transcribe

    /// Whether this route must ask `AVURLAsset.load(.isReadable)` before it offers to do anything.
    ///
    /// **True for everything that goes through AVFoundation, and the reason is that the session
    /// lies.** `AVAssetExportSession.supportedFileTypes` answered **thirteen** compatible types —
    /// mov, mp4, m4a, m4v, 3gp, wav, aiff, caf — for a Matroska file that `load(.isReadable)` throws
    /// `-11828 "Cannot Open"` for, and the list was identical to the one for a working MP4. So a
    /// menu driven off `supportedFileTypes` offers every conversion for a file AVFoundation cannot
    /// open and then fails at `-11800`. **Ask the asset; the session will tell you anything.**
    public var asksTheAsset: Bool {
        switch self {
        case .mediaPassthrough, .mediaAudioM4A, .mediaHEVC, .transcribe: true
        // `afconvert` opens the file itself and reports honestly when it cannot, so this one is not
        // gated on AVFoundation's opinion — it does not go through AVFoundation at all.
        case .audioEncode: false
        case .imageEncode, .imagesToPDF, .vectorRaster, .textKitPDF, .quickLookPDF: false
        }
    }

    /// Whether the route spawns something of its own *inside* the worker.
    ///
    /// Two do, and the QuickLook one is why this is worth asking: it is the only route whose
    /// failure mode is a subprocess that never returns rather than an error, so both of these are
    /// run with a hard deadline and judged on whether a file appeared rather than on an exit code.
    public var spawnsHelper: Bool { self == .quickLookPDF || self == .audioEncode }
}

/// What a conversion produces: a name for the menu, and the file extension it writes.
///
/// A value rather than a `UTType`, because the two questions a target has to answer — "what does
/// the row say" and "what is the new file called" — are both display concerns, and because the
/// catalog below is a list of *measured* conversions rather than of everything the system claims it
/// can write. `CGImageDestinationCopyTypeIdentifiers` lists 22 writable image UTIs; offering all of
/// them would put JPEG-2000 (1,256 ms) and PSD next to JPEG with nothing to say which is which.
public struct ConversionTarget: Equatable, Sendable, Identifiable {

    /// What the row says: "JPEG", "PDF", "M4A (audio)".
    public let name: String

    /// The extension the written file gets, lower case and without a dot.
    public let pathExtension: String

    /// The uniform type the writer is given, where the route needs one. Empty for routes that do
    /// not take a type — the TextKit and QuickLook chains only ever write PDF.
    public let identifier: String

    public var id: String { "\(name).\(pathExtension)" }

    public init(name: String, pathExtension: String, identifier: String = "") {
        self.name = name
        self.pathExtension = pathExtension
        self.identifier = identifier
    }
}

/// One thing the island is offering to do to a file: a route, a target, and what it will cost on
/// screen.
public struct ConversionOffer: Equatable, Sendable, Identifiable {

    public let route: ConversionRoute
    public let target: ConversionTarget
    public let progress: ConversionProgressClass

    public var id: String { "\(route.rawValue).\(target.id)" }

    /// What the row says. "Convert to JPEG", and for the two routes that are not conversions at all
    /// the verb changes with them.
    public var title: String {
        switch route {
        case .transcribe: activityText("convert.transcribe", "Transcribe")
        case .mediaHEVC: activityText("convert.compressVideo", "Compress video")
        // `target.name` is a format acronym — JPEG, PNG, HEIC, PDF — and stays verbatim in every
        // language; the sentence around it is what gets translated, with the acronym as an argument.
        default: activityText("convert.to", "Convert to \(target.name)")
        }
    }

    public init(route: ConversionRoute, target: ConversionTarget, progress: ConversionProgressClass) {
        self.route = route
        self.target = target
        self.progress = progress
    }
}

/// Which conversions Isleta offers for a file, and nothing about how they are performed.
///
/// ## Keyed on the path extension, deliberately, where the rest of the shelf asks `UTType`
///
/// `ShelfItem.symbolName(for:)` asks `UTType` and says why: an extension table needs every spelling
/// of every format and still misses the next one Apple ships. That argument is right for a *glyph*,
/// which is a guess about what a file is, and wrong for this, which is a promise about what Isleta
/// can do to it. Every entry below was measured on a real file; a `UTType.conforms(to: .image)`
/// rule would offer HEIC → JPEG for a RAW file nobody has tried and a PDF for every
/// `public.composite-content` on the disk. **The catalog is short because the measurements are.**
///
/// The one thing this borrows from `UTType`'s argument is the failure mode: an unknown extension
/// gets an empty list and the shelf offers the actions that need no conversion at all, rather than
/// an error.
///
/// ## Pure, and that is what makes it testable
///
/// Nothing here touches the filesystem, so the whole mapping — including the rules that say what
/// gets a progress island and what asks AVFoundation whether it can read the file — is exercised
/// against strings with no files on disk. The parts that need real bytes are in the worker, where
/// they cannot be tested without them.
public enum FileConversion {

    // MARK: - Targets

    public static let jpeg = ConversionTarget(name: "JPEG", pathExtension: "jpg", identifier: "public.jpeg")
    public static let png = ConversionTarget(name: "PNG", pathExtension: "png", identifier: "public.png")
    public static let heic = ConversionTarget(name: "HEIC", pathExtension: "heic", identifier: "public.heic")
    public static let tiff = ConversionTarget(name: "TIFF", pathExtension: "tiff", identifier: "public.tiff")
    public static let gif = ConversionTarget(name: "GIF", pathExtension: "gif", identifier: "com.compuserve.gif")

    /// The page-writer's own identifier, spelled as ImageIO wants it. Not a `UTType` constant,
    /// because `UTType.pdf.identifier` is the same string reached through a framework this package
    /// has no other reason to import.
    public static let pdf = ConversionTarget(name: "PDF", pathExtension: "pdf", identifier: "com.adobe.pdf")

    public static let mov = ConversionTarget(name: "MOV", pathExtension: "mov", identifier: "com.apple.quicktime-movie")
    public static let mp4 = ConversionTarget(name: "MP4", pathExtension: "mp4", identifier: "public.mpeg-4")
    public static let m4a = ConversionTarget(name: "M4A", pathExtension: "m4a", identifier: "com.apple.m4a-audio")
    public static let wav = ConversionTarget(name: "WAV", pathExtension: "wav", identifier: "com.microsoft.waveform-audio")
    public static let aiff = ConversionTarget(name: "AIFF", pathExtension: "aiff", identifier: "public.aiff-audio")

    /// A smaller H.264/HEVC copy of a video. The target's extension matches the source container's
    /// family rather than renaming it, so the file beside the original is obviously the same thing.
    public static let hevc = ConversionTarget(name: "HEVC", pathExtension: "mov", identifier: "com.apple.quicktime-movie")

    /// **"Text" is the one target name that is a word rather than a format acronym, and it is still
    /// not localized — because it is never drawn and because it is inside a persisted id.**
    ///
    /// `ConversionTarget.id` is `"\(name).\(pathExtension)"`, `ConversionOffer.id` wraps that, and
    /// `DropHistoryEntry.offerID` stores it and matches it back against a freshly rebuilt catalog
    /// (`DropHistoryController.action(rebuilding:)`). A locale-dependent `name` would therefore make
    /// every history row minted before a language change stop matching, and its "Run again" button
    /// silently do nothing — the exact failure the persisted-keys rule exists to prevent.
    ///
    /// Nothing is lost by leaving it: the only route that targets this is `.transcribe`, whose row
    /// says "Transcribe" and never interpolates the target name at all. It is a record, not a caption.
    public static let text = ConversionTarget(name: "Text", pathExtension: "txt", identifier: "public.plain-text")

    // MARK: - Families

    /// Raster images ImageIO reads *and* that were measured re-encoding correctly.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    /// The one vector format, and it does not go through ImageIO at all.
    static let vectorExtensions: Set<String> = ["svg"]

    /// Containers AVFoundation opens. **MKV and WebM are deliberately absent**: AVFoundation reads
    /// no Matroska (`-11828`), and the remux needs an `ffmpeg` this build does not vendor.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"]

    /// What Apple's own rich-text importer genuinely reads. **`doc` is included and `xls` is not**,
    /// which is the whole finding: the importer recognizes the Office family and only has a Word
    /// reader behind it.
    static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "html", "htm", "txt", "md"]

    /// Spreadsheets, decks, and the two flat formats that share their route.
    ///
    /// The three iWork extensions are here **untested**, and that is recorded rather than hidden:
    /// the iWork QuickLook generator ships with the OS and claims every `.pages`/`.key`/`.numbers`
    /// UTI, so the chain is very likely the same one — but none of the three applications was
    /// installed on the machine the probes ran on, and making a `.pages` file requires Pages.
    /// The failure if that guess is wrong is the one this route already guards against: `qlmanage`
    /// writes nothing, the did-a-file-appear check fails, and the row reports that it could not
    /// convert. Note also that the availability check anyone would reach for to gate this —
    /// `osascript -e 'tell application "Pages" to name'` — answers **"Pages" and exits 0 on a
    /// machine with no Pages on it**, because AppleScript resolves the term without resolving the
    /// application. `NSWorkspace.urlForApplication(withBundleIdentifier:)` is the honest check, and
    /// this route needs neither: it never talks to iWork.
    static let sheetExtensions: Set<String> = [
        "xlsx", "xls", "pptx", "ppt", "csv", "tsv", "numbers", "key", "pages",
    ]

    // MARK: - The catalog

    /// Everything Isleta offers for one file, in the order the menu draws it.
    ///
    /// - Parameter pathExtension: the file's extension, in any case, with or without a leading dot.
    public static func offers(forPathExtension pathExtension: String) -> [ConversionOffer] {
        let ext = normalized(pathExtension)
        guard !ext.isEmpty else { return [] }

        if imageExtensions.contains(ext) {
            return imageTargets(excluding: ext).map {
                ConversionOffer(route: .imageEncode, target: $0, progress: imageProgress(for: $0))
            } + [ConversionOffer(route: .imagesToPDF, target: pdf, progress: .beat)]
        }
        if vectorExtensions.contains(ext) {
            return [png, jpeg, pdf].map {
                ConversionOffer(route: .vectorRaster, target: $0, progress: .instant)
            }
        }
        if videoExtensions.contains(ext) {
            return [mov, mp4].filter { $0.pathExtension != ext }.map {
                ConversionOffer(route: .mediaPassthrough, target: $0, progress: .instant)
            } + [
                ConversionOffer(route: .mediaAudioM4A, target: m4a, progress: .instant),
                ConversionOffer(route: .mediaHEVC, target: hevc, progress: .tracked),
                ConversionOffer(route: .transcribe, target: text, progress: .tracked),
            ]
        }
        if audioExtensions.contains(ext) {
            var offers: [ConversionOffer] = []
            if ext != "m4a" {
                offers.append(ConversionOffer(route: .mediaAudioM4A, target: m4a, progress: .instant))
            }
            offers += [wav, aiff].filter { $0.pathExtension != ext }.map {
                ConversionOffer(route: .audioEncode, target: $0, progress: .instant)
            }
            offers.append(ConversionOffer(route: .transcribe, target: text, progress: .tracked))
            return offers
        }
        if documentExtensions.contains(ext) {
            return [ConversionOffer(route: .textKitPDF, target: pdf, progress: .instant)]
        }
        if sheetExtensions.contains(ext) {
            // `.tracked` for the reason `ConversionProgressClass` gives: 80 ms for an 8-column
            // sheet and 2.5 s for a 2,000-row one, with nothing short of reading the file to say
            // which this is.
            return [ConversionOffer(route: .quickLookPDF, target: pdf, progress: .tracked)]
        }
        return []
    }

    /// Whether anything at all is on offer. Cheaper than building the list, and it is asked once per
    /// tile while the actions menu is being laid out.
    public static func hasOffers(forPathExtension pathExtension: String) -> Bool {
        !offers(forPathExtension: pathExtension).isEmpty
    }

    /// Whether a file can be transcribed — audio, or a video container carrying an audio track.
    ///
    /// `AVAudioFile(forReading:)` is the whole decoder and opens MP4 and MOV directly by pulling the
    /// audio track, so there is no `AVAssetReader` step and no separate list here. The one thing
    /// this cannot know is whether a video *has* audio: a silent video and a corrupt file throw
    /// indistinguishably (`'dta?'` against `'wht?'`), so the worker asks
    /// `AVURLAsset.loadTracks(withMediaType: .audio)` to tell them apart and this offers the row.
    public static func isTranscribable(pathExtension: String) -> Bool {
        let ext = normalized(pathExtension)
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// The image formats offered for an image, minus the one it already is.
    ///
    /// **No AVIF, no JPEG-2000 and no WebP**, and each absence is a measurement. AVIF peaks at
    /// **+182 MB** and JPEG-2000 takes 1,256 ms, so both would be `.tracked` conversions of a
    /// photograph — an island with a progress bar on it for a format almost nobody asked for. WebP
    /// is in the 62 *readable* UTIs and not in the 22 writable ones, so it can only ever be a
    /// source.
    private static func imageTargets(excluding pathExtension: String) -> [ConversionTarget] {
        let all = [jpeg, png, heic, tiff, gif]
        // "jpg" and "jpeg" are the same format under two spellings and the menu must not offer a
        // file its own format under the other one.
        let normalizedSource = pathExtension == "jpeg" ? "jpg" : (pathExtension == "tif" ? "tiff" : pathExtension)
        return all.filter { $0.pathExtension != normalizedSource }
    }

    /// Measured, per target, on a 12 Mpx source: JPEG 80 ms, TIFF 62 ms, HEIC 167 ms, GIF 268 ms,
    /// PNG 371 ms.
    private static func imageProgress(for target: ConversionTarget) -> ConversionProgressClass {
        switch target.pathExtension {
        case "jpg", "tiff": .instant
        default: .beat
        }
    }

    static func normalized(_ pathExtension: String) -> String {
        var ext = pathExtension.lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        return ext.trimmingCharacters(in: .whitespaces)
    }
}
