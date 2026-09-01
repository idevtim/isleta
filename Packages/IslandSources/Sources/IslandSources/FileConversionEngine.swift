import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import IslandActivities
import IslandKit
import UniformTypeIdentifiers

/// What the parent asks the worker to do.
///
/// One request per process. It is written to the child's stdin as a single JSON line rather than
/// passed in `argv`, and that is not tidiness: `argv` is readable with `ps` by anyone on the machine
/// and by `KERN_PROCARGS2` by anything that asks, and the file names a user drops on the island are
/// theirs. The only thing in the child's `argv` is the flag — which is also what makes the orphan
/// sweep able to recognize one of ours without reading a path.
public struct FileConversionRequest: Codable, Sendable {

    public let route: ConversionRoute
    public let targetIdentifier: String
    public let targetExtension: String
    public let inputs: [String]

    /// Where the result is written. The parent decides this, because the parent is the one that
    /// knows whether the user picked a folder — the worker never opens a panel and never guesses.
    public let outputDirectory: String

    /// BCP-47, for the transcription route only. Empty means "pick the best installed model".
    public let localeIdentifier: String

    public init(
        route: ConversionRoute,
        targetIdentifier: String,
        targetExtension: String,
        inputs: [String],
        outputDirectory: String,
        localeIdentifier: String = ""
    ) {
        self.route = route
        self.targetIdentifier = targetIdentifier
        self.targetExtension = targetExtension
        self.inputs = inputs
        self.outputDirectory = outputDirectory
        self.localeIdentifier = localeIdentifier
    }
}

/// One line the worker writes back.
///
/// Newline-delimited JSON, the same framing `NowPlayingAdapterReader` reads, because the failure
/// modes are already understood there: a partial line is held until its newline arrives, and a line
/// that does not parse is dropped rather than taken as a truncated success.
public enum FileConversionEvent: Codable, Sendable {

    /// 0...1, only from routes that can honestly report one.
    case progress(Double)

    /// A file was written, at this path.
    case produced(String)

    /// The job failed, in Isleta's own words. Never the system's error text — a `localizedDescription`
    /// from Foundation carries the path it failed on, and that is exactly what must not travel back
    /// into a log line.
    case failed(String)
}

/// The conversions themselves. **This runs in the child process and nowhere else.**
///
/// ## Why a child process, and it is not about wedging
///
/// Every conversion family breaches §9's 60 MB resident ceiling while it works. Measured peak
/// `phys_footprint` deltas: AVIF **+182 MB**, an H.264 downscale **+452 MB**, a multi-image PDF
/// +82 MB, a 2,000-row sheet +95 MB, GIF +84 MB, HEIC +53 MB. The video figure is *flat in
/// duration* — 60 s peaks at 451 MB and 10 s at 442 MB — so it is a fixed allocation in the scaler
/// rather than a leak, which is the part that decides the design: there is no file small enough to
/// make it safe, and no amount of releasing anything gets it back inside the budget. §9's 60 MB is
/// an **idle** figure, and the way to keep it one is for the memory to belong to a process that
/// ends when the work does.
///
/// The second reason is the one the `mediaremote-adapter` route already carries: a helper that can
/// wedge on a malformed file should be something the parent can kill. `qlmanage -t` never returns.
///
/// ## Everything here runs off the main thread, and the exception is what would abort the process
///
/// Measured off a plain utility queue, all correct and none deadlocked: ImageIO decode plus HEIC
/// encode 206 ms, `NSAttributedString(url: .docx)` 6 ms, `(url: .html)` 290 ms, SVG to a 1600×1200
/// PNG 23 ms, TextKit into a `CGPDFContext` for nine pages 67 ms. The one thing that must never
/// happen on a background thread is touching `NSTextView`, which constructs a `TUINSWindow` and
/// aborts with "NSWindow should only be instantiated on the main thread!" — uncatchable — and the
/// route below has no `NSTextView` in it at all.
public enum FileConversionEngine {

    /// Runs one request to completion, reporting as it goes.
    ///
    /// Never throws: every failure is a `.failed` event, because the caller is a process boundary
    /// and an uncaught error there is an exit code with nothing to say.
    public static func run(
        _ request: FileConversionRequest,
        emit: @Sendable @escaping (FileConversionEvent) -> Void
    ) async {
        let inputs = request.inputs.map { URL(fileURLWithPath: $0) }
        let directory = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
        guard !inputs.isEmpty else {
            emit(.failed(sourceText("fileAction.failed.nothingToConvert", "Nothing to convert")))
            return
        }

        do {
            switch request.route {
            case .imageEncode:
                try each(inputs, emit: emit) { input in
                    try encodeImage(input, to: output(for: input, request: request, in: directory), request: request)
                }
            case .imagesToPDF:
                let name = inputs.count == 1 ? base(of: inputs[0]) : "Images"
                let url = try unique(in: directory, base: name, pathExtension: "pdf")
                try imagesToPDF(inputs, to: url)
                emit(.produced(url.path))
            case .vectorRaster:
                try each(inputs, emit: emit) { input in
                    try rasterizeVector(input, to: output(for: input, request: request, in: directory), request: request)
                }
            case .mediaPassthrough, .mediaAudioM4A, .mediaHEVC:
                try await eachAsync(inputs, emit: emit) { input, report in
                    try await export(
                        input,
                        to: output(for: input, request: request, in: directory),
                        route: request.route,
                        target: request.targetIdentifier,
                        report: report
                    )
                }
            case .audioEncode:
                try each(inputs, emit: emit) { input in
                    try afconvert(input, to: output(for: input, request: request, in: directory), request: request)
                }
            case .textKitPDF:
                try each(inputs, emit: emit) { input in
                    let url = try output(for: input, request: request, in: directory)
                    try writePDF(try richText(at: input), to: url)
                    return url
                }
            case .quickLookPDF:
                try each(inputs, emit: emit) { input in
                    let url = try output(for: input, request: request, in: directory)
                    try writePDF(try quickLookRichText(at: input), to: url)
                    return url
                }
            case .transcribe:
                try await eachAsync(inputs, emit: emit) { input, report in
                    try await SpeechTranscription.write(
                        transcriptOf: input,
                        to: try output(for: input, request: request, in: directory),
                        localeIdentifier: request.localeIdentifier,
                        report: report
                    )
                }
            }
        } catch let error as ConversionFailure {
            emit(.failed(error.message))
        } catch {
            // Deliberately not `error.localizedDescription`: Foundation's file errors quote the path
            // they failed on, and this string travels into a log the user emails to strangers.
            emit(.failed(sourceText("fileAction.failed.generic", "Could not convert this file")))
        }
    }

    /// A failure with words Isleta chose. The only error type that reaches the parent.
    struct ConversionFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Running over a set of files

    private static func each(
        _ inputs: [URL],
        emit: @Sendable (FileConversionEvent) -> Void,
        body: (URL) throws -> URL
    ) rethrows {
        for (index, input) in inputs.enumerated() {
            emit(.produced(try body(input).path))
            emit(.progress(Double(index + 1) / Double(inputs.count)))
        }
    }

    /// The same, for routes that report progress *within* one file.
    ///
    /// The fraction is scaled into that file's share of the whole job, so a three-file transcription
    /// runs one bar from 0 to 1 rather than three from 0 to 1 — which is what the user is watching:
    /// the job, not the file.
    private static func eachAsync(
        _ inputs: [URL],
        emit: @Sendable @escaping (FileConversionEvent) -> Void,
        body: (URL, @Sendable @escaping (Double) -> Void) async throws -> URL
    ) async rethrows {
        let count = Double(inputs.count)
        for (index, input) in inputs.enumerated() {
            let base = Double(index) / count
            let produced = try await body(input) { fraction in
                emit(.progress(base + min(max(0, fraction), 1) / count))
            }
            emit(.produced(produced.path))
            emit(.progress(Double(index + 1) / count))
        }
    }

    // MARK: - Naming what comes out

    private static func base(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func output(
        for input: URL,
        request: FileConversionRequest,
        in directory: URL
    ) throws -> URL {
        try unique(in: directory, base: base(of: input), pathExtension: request.targetExtension)
    }

    /// A name that is not taken.
    ///
    /// Never overwrites, and the reason is the one case this feature could destroy something: a
    /// user who converts `photo.png` to PNG-with-a-different-name, or converts twice, must not have
    /// the first result silently replaced. Finder's own suffix (" 2", " 3") rather than a counter in
    /// brackets, because the file lands in the user's folder and has to look like something the
    /// system made.
    private static func unique(in directory: URL, base: String, pathExtension: String) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConversionFailure(sourceText("fileAction.failed.noDestination", "The destination folder is not there"))
        }
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
            guard suffix < 1000 else { throw ConversionFailure(sourceText("fileAction.failed.noFreeName", "Could not find a free name")) }
        }
        guard manager.isWritableFile(atPath: directory.path) else {
            throw ConversionFailure(sourceText("fileAction.failed.folderNotWritable", "That folder cannot be written to"))
        }
        return candidate
    }

    // MARK: - Images

    /// One raster image, re-encoded.
    ///
    /// The `guard let` on the source is doing real work even for formats ImageIO does read:
    /// **`CGImageSourceCreateWithURL` returns a non-nil source for a file it has no reader for** —
    /// measured on SVG, where the type is nil and the count is 0 — so the count is what has to be
    /// checked, not the pointer.
    private static func encodeImage(
        _ input: URL,
        to url: URL,
        request: FileConversionRequest
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionFailure(sourceText("fileAction.failed.imageUnreadable", "That image could not be read"))
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, request.targetIdentifier as CFString, 1, nil
        ) else {
            throw ConversionFailure(sourceText("fileAction.failed.formatUnwritable", "That format cannot be written"))
        }
        // 0.9 rather than 1.0 for the lossy formats: 1.0 is a JPEG barely smaller than the TIFF it
        // came from, which is not what anyone converting to JPEG is asking for. Ignored by the
        // lossless ones.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionFailure(sourceText("fileAction.failed.imageUnwritable", "That image could not be written"))
        }
        return url
    }

    /// Several images, one PDF, one page each.
    ///
    /// **`CGImageDestinationCreateWithURL(url, "com.adobe.pdf", n, nil)`, and never
    /// `CGPDFContext`.** Multi-page PDF is what `CGPDFContext` is *for*, which is why it is the
    /// call everyone writes first, and it re-encodes every image losslessly: three photos came back
    /// as 65.7 MB in 1,885 ms — six `/FlateDecode` streams — against 6.5 MB in 497 ms and three
    /// `/DCTDecode` through this call, with identical pages and media boxes. It is documented
    /// nowhere as a paginator and is ten times better at it.
    private static func imagesToPDF(_ inputs: [URL], to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, FileConversion.pdf.identifier as CFString, inputs.count, nil
        ) else {
            throw ConversionFailure(sourceText("fileAction.failed.pdfNotStarted", "A PDF could not be started"))
        }
        var added = 0
        for input in inputs {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            added += 1
        }
        guard added > 0 else { throw ConversionFailure(sourceText("fileAction.failed.noImagesReadable", "None of those images could be read")) }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionFailure(sourceText("fileAction.failed.pdfUnwritable", "That PDF could not be written"))
        }
    }

    /// SVG, through AppKit, because ImageIO has no SVG reader at all.
    ///
    /// `NSImage(contentsOf:)` gives an `_NSSVGImageRep` and draws correctly at any size, 23 ms
    /// off-main. Rasterised at 2× the declared size, which is the same reason the island draws at
    /// 2×: an SVG is resolution-independent and the file that comes out of this is not, so the
    /// smallest honest answer is the one that still looks right on the display it was made on.
    private static func rasterizeVector(
        _ input: URL,
        to url: URL,
        request: FileConversionRequest
    ) throws -> URL {
        guard let image = NSImage(contentsOf: input), image.size.width > 0, image.size.height > 0 else {
            throw ConversionFailure(sourceText("fileAction.failed.vectorUnreadable", "That vector could not be read"))
        }
        let scale: CGFloat = 2
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        if request.targetExtension == "pdf" {
            var mediaBox = CGRect(origin: .zero, size: image.size)
            guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
                throw ConversionFailure(sourceText("fileAction.failed.thatPdfNotStarted", "That PDF could not be started"))
            }
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: mediaBox)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            return url
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ConversionFailure(sourceText("fileAction.failed.vectorNotRasterised", "That vector could not be rasterised"))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let type: NSBitmapImageRep.FileType = request.targetExtension == "jpg" ? .jpeg : .png
        guard let data = rep.representation(using: type, properties: [:]) else {
            throw ConversionFailure(sourceText("fileAction.failed.imageUnwritable", "That image could not be written"))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Media

    /// A container remux, an audio extraction, or the one re-encode.
    ///
    /// **The asset is asked whether it is readable, and the session is never asked anything.**
    /// `AVAssetExportSession.supportedFileTypes` answered thirteen compatible types for a Matroska
    /// file that `load(.isReadable)` throws `-11828` for — the same list as for a working MP4 — so a
    /// UI driven off the session offers every conversion for a file AVFoundation cannot open and
    /// then fails at `-11800`.
    private static func export(
        _ input: URL,
        to url: URL,
        route: ConversionRoute,
        target: String,
        report: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let readable = try? await asset.load(.isReadable), readable else {
            throw ConversionFailure(sourceText("fileAction.failed.fileNotOpenable", "That file cannot be opened"))
        }
        let preset = switch route {
        case .mediaAudioM4A: AVAssetExportPresetAppleM4A
        case .mediaHEVC: AVAssetExportPresetHEVC1920x1080
        default: AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionFailure(sourceText("fileAction.failed.conversionUnavailable", "That conversion is not available here"))
        }
        guard let fileType = AVFileType(rawValue: target) as AVFileType? else {
            throw ConversionFailure(sourceText("fileAction.failed.formatUnwritable", "That format cannot be written"))
        }

        // `states(updateInterval:)` rather than the `progress` property, which is deprecated at this
        // deployment target and therefore a build failure under `Tools/check.sh`. Every 200 ms:
        // often enough that a five-second export moves visibly, rare enough that it is not a write
        // per frame down a pipe.
        let states = session.states(updateInterval: 0.2)
        let watcher = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    report(progress.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }

        do {
            try await session.export(to: url, as: fileType)
        } catch {
            throw ConversionFailure(sourceText("fileAction.failed.fileNotConverted", "That file could not be converted"))
        }
        return url
    }

    /// WAV and AIFF, through `/usr/bin/afconvert`.
    ///
    /// A system binary, present on every Mac, and the reason it is here rather than AVFoundation is
    /// that AVFoundation writes M4A and not much else in this direction. **It is also where MP3
    /// would have gone and cannot**: `afconvert -hf` lists `'MPG3' = MPEG Layer 3` as a file format
    /// and asking for it fails with `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')` — the table
    /// reads as a capability list and is not one.
    private static func afconvert(
        _ input: URL,
        to url: URL,
        request: FileConversionRequest
    ) throws -> URL {
        let format = request.targetExtension == "wav" ? "WAVE" : "AIFF"
        let result = Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", format, "-d", "LEI16", input.path, url.path],
            timeout: 30
        )
        // Judged on whether a file appeared, not on the exit code — the same rule `qlmanage` forces
        // and a good habit for every tool spawned here.
        guard result.finished, FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionFailure(sourceText("fileAction.failed.audioNotConverted", "That audio could not be converted"))
        }
        return url
    }

    // MARK: - Rich text

    /// Apple's own importer, for the formats it genuinely reads.
    ///
    /// 33 k characters of DOCX in 11 ms with bold, italic, color and `NSTextTable` borders.
    /// **Never called for XLSX or PPTX**, which it reads *successfully* and returns `length == 0`
    /// for — the correct document type, no throw, and a blank 3,740-byte PDF at the end of it.
    /// `FileConversion` routes those to `quickLookPDF` and this guards the boundary anyway, because
    /// the failure if the two ever disagree is a blank file rather than an error.
    private static func richText(at url: URL) throws -> NSAttributedString {
        guard let string = try? NSAttributedString(
            url: url, options: [:], documentAttributes: nil
        ), string.length > 0 else {
            throw ConversionFailure(sourceText("fileAction.failed.noText", "There was no text in that file"))
        }
        return string
    }

    /// The `Preview.html` Apple's QuickLook generator writes for a spreadsheet or a deck.
    ///
    /// `qlmanage -p -o <dir>` is the only way to reach that generator: `QuickLookThumbnailing` has
    /// no PDF representation at all — every `QLThumbnailRepresentationType` is a `CGImage`, checked
    /// against the 26.5 header — and its thumbnails are page one, cropped.
    ///
    /// **Neither the exit code nor stderr is load-bearing**: `-p` prints
    /// `EXCEPTION TCMessageException: (null)`, says it "did not produce any preview", and **exits
    /// 0**, while `-t` never returns at all. So this has a hard deadline and then asks the only
    /// question that means anything — did a file appear.
    ///
    /// Known limit, stated rather than discovered: a PPTX preview's `PreviewProperties.plist`
    /// carries `PageElementXPath = /html/body/div`, the generator naming which DOM elements are
    /// slides. TextKit ignores it and collapses a two-slide deck into one long page. Honoring it
    /// means WebKit, and WebKit **cannot paginate** — `WKWebView.createPDF` produces exactly one
    /// page of the rect it is handed, and `printOperation(with:)` never returns in an `.accessory`
    /// process. Fidelity here is "readable and complete", not "identical to PowerPoint".
    private static func quickLookRichText(at url: URL) throws -> NSAttributedString {
        let manager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.tryisleta.isleta.quicklook", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        _ = Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/qlmanage"),
            arguments: ["-p", url.path, "-o", scratch.path],
            timeout: 30
        )

        let bundles = (try? manager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "qlpreview" } ?? []
        guard let preview = bundles.first else {
            throw ConversionFailure(sourceText("fileAction.failed.noPreview", "macOS could not preview that file"))
        }
        let html = preview.appendingPathComponent("Preview.html")
        guard manager.fileExists(atPath: html.path) else {
            throw ConversionFailure(sourceText("fileAction.failed.noPreview", "macOS could not preview that file"))
        }
        // The HTML importer, given the file's own URL so relative resources inside the bundle
        // resolve. **Never a `WKWebView`** — `loadFileURL` into a `.qlpreview` directory hangs
        // forever, with no `didFinish`, no `didFail` and no timeout, while the same file copied to a
        // plain directory loads in 200 ms.
        guard let string = try? NSAttributedString(
            url: html,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ), string.length > 0 else {
            throw ConversionFailure(sourceText("fileAction.failed.noText", "There was no text in that file"))
        }
        return string
    }

    /// Rich text into a paginated PDF, with no `NSTextView` anywhere.
    ///
    /// `NSTextStorage` + `NSLayoutManager` + **one `NSTextContainer` per page**, drawn straight into
    /// a `CGPDFContext`: 62 ms and +6.2 MB for nine pages, against `NSPrintOperation(view:
    /// NSTextView)`'s 164 ms and +11 MB — and, decisively, main-thread-only in a way that aborts the
    /// process rather than complaining.
    ///
    /// **`NSGraphicsContext(cgContext:flipped:)` must be given `true`.** With `false` the PDF has
    /// the right page count, the right 612×792 media boxes, the right colors, selectable text, and
    /// **every glyph mirrored left to right**. It differs from the correct file by 800 bytes, no API
    /// returns anything about it, and it was caught on a screenshot. The CTM flip below and that
    /// flag are two halves of one statement: the context is flipped, and AppKit is told so instead
    /// of flipping it again.
    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        // US Letter at 72 dpi with a half-inch margin. A page size is a choice this has to make and
        // there is no honest way to derive one from a DOCX: Word's own page setup is not in what
        // `NSAttributedString` imports.
        let page = CGSize(width: 612, height: 792)
        let margin: CGFloat = 36
        let textSize = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)

        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)

        var mediaBox = CGRect(origin: .zero, size: page)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionFailure(sourceText("fileAction.failed.thatPdfNotStarted", "That PDF could not be started"))
        }

        var glyph = 0
        var pages = 0
        while glyph < manager.numberOfGlyphs, pages < 2000 {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let range = manager.glyphRange(for: container)
            guard range.length > 0 else { break }

            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let origin = CGPoint(x: margin, y: margin)
            manager.drawBackground(forGlyphRange: range, at: origin)
            manager.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()

            glyph = NSMaxRange(range)
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else { throw ConversionFailure(sourceText("fileAction.failed.nothingToLayOut", "There was nothing to lay out")) }
    }
}
