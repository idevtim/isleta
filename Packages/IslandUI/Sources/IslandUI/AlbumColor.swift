import CoreGraphics
import SwiftUI

/// A color taken off a piece of cover art.
///
/// Three doubles rather than a `Color`, for the reason every color in `ActivityPalette` is spelled
/// in sRGB components: a `Color` is opaque, cannot be compared for "is this too dark to read on
/// black", and resolves against an environment the island does not have. Components can be
/// reasoned about and tested with no view, no window server and no image.
public struct AlbumColor: Equatable, Sendable {

    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// As SwiftUI sees it. sRGB explicitly, like everything else drawn on the island — a named or
    /// semantic color resolves differently by appearance, and a shade shift against pure `#000000`
    /// in a notch reads as a different color rather than as the same one lit differently.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    // MARK: - Reading it off the artwork

    /// The side of the square the cover is resampled into before being averaged.
    ///
    /// Small on purpose. This runs once per track change — never on the hot path, never on a
    /// timer — and the whole of what it has to produce is one accent. Resampling to 8×8 and
    /// averaging 64 pixels costs a single CoreGraphics draw of an image that is already decoded.
    static let sampleSide = 8

    /// The average color of a cover.
    ///
    /// **An average, deliberately, and not a dominant-color clustering.** A k-means or histogram
    /// pass finds the color a person would *name* if asked, and is a great deal more work; an
    /// average finds the color the cover *is*, and its failure mode is a muddy near-gray for a busy
    /// sleeve. That failure is fixed downstream by `legible(_:)` rather than by better clustering,
    /// because a lifted muddy gray is a perfectly reasonable accent and a mis-clustered vivid one is
    /// not.
    ///
    /// Nil when the image cannot be drawn — a context that will not allocate, a zero-sized image.
    /// Nil is the whole of the degraded path: `ActivityPalette.albumAccent` falls back to the
    /// palette's own color, so a cover that cannot be read looks exactly like the setting being off.
    public static func average(of image: CGImage) -> AlbumColor? {
        let side = sampleSide
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var totals = (red: 0.0, green: 0.0, blue: 0.0, weight: 0.0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // Premultiplied, so a transparent corner of a square-on-transparent cover contributes
            // its *alpha* rather than a black pixel. Ignoring alpha here is how a logo on a clear
            // background comes out near-black however bright the logo is.
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0 else { continue }
            totals.red += Double(pixels[index]) / 255
            totals.green += Double(pixels[index + 1]) / 255
            totals.blue += Double(pixels[index + 2]) / 255
            totals.weight += alpha
        }
        guard totals.weight > 0 else { return nil }
        return AlbumColor(
            red: totals.red / totals.weight,
            green: totals.green / totals.weight,
            blue: totals.blue / totals.weight
        )
    }

    // MARK: - Making it readable on a black island

    /// The least saturation an accent may have.
    ///
    /// Under it the color stops being an accent and becomes a gray the user will read as the island
    /// having lost its tint. A busy cover averages to something close to gray far more often than
    /// not, so this is the common path rather than the edge case.
    static let minimumSaturation = 0.42

    /// The least brightness an accent may have.
    ///
    /// The island is `#000000`. A dark accent on it is not a subtle accent, it is an invisible
    /// control — and the controls this tints are the transport buttons, which is the failure mode
    /// this project's brief calls "a control nobody can hit is a control that does not exist".
    static let minimumBrightness = 0.68

    /// The most saturation an accent may have.
    ///
    /// A fully saturated primary against pure black is the one combination that fringes on an OLED
    /// and vibrates on an LCD, and a cover that is genuinely one flat color will average to exactly
    /// that. Pulling it back a little costs nothing anybody can name and removes the worst case.
    static let maximumSaturation = 0.88

    /// The saturation under which a color is treated as having no hue at all.
    ///
    /// A black-and-white sleeve — or a white glyph on a black icon, which is what a browser hands
    /// over for a site — does not average to an exact gray. Compression and antialiasing leave it a
    /// percent or two off, and lifting *that* to `minimumSaturation` turned a monochrome Apple logo
    /// into a violet row, reported from hardware. The hue of a color this close to gray is noise,
    /// so it is not saturated; it is drawn as the gray it is, at a readable brightness.
    static let neutralSaturation = 0.12

    /// The same color, guaranteed to read as an accent against `#000000`.
    ///
    /// Pure arithmetic on the components — no `NSColor`, no `Color`, no appearance — so the rule
    /// "a black cover does not produce an invisible transport row" is a test rather than a look.
    public static func legible(_ color: AlbumColor) -> AlbumColor {
        var (hue, saturation, brightness) = hsb(color)
        saturation = saturation < neutralSaturation
            ? 0
            : min(max(saturation, minimumSaturation), maximumSaturation)
        brightness = max(brightness, minimumBrightness)
        return rgb(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// The accent a cover gives, or nil if it gives none. One call, so nobody averages without
    /// lifting.
    ///
    /// Read off `centre(of:)` rather than the whole sleeve: a border, a label strip or a
    /// letterboxed icon's background is at the edges, and the thing a person would say the cover
    /// *is* sits in the middle of it.
    public static func accent(from image: CGImage) -> AlbumColor? {
        average(of: centre(of: image) ?? image).map(legible)
    }

    // MARK: - The middle of the cover

    /// The part of the cover that is read: the middle 70% across and the middle half down.
    ///
    /// Wide rather than square because the row reads the cover left to right, and cutting the sides
    /// in as far as the top and bottom would leave the outer bars reading the same pixels as their
    /// neighbours. Short because the top and bottom of a sleeve are where the title, the label and
    /// the parental-advisory box live — text, not the record's color.
    static let sampleRegion = CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.5)

    /// The cover cropped to `sampleRegion`, or nil for an image too small to crop. A crop shares
    /// the source's pixels rather than copying them.
    static func centre(of image: CGImage) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let rect = CGRect(
            x: (sampleRegion.minX * width).rounded(.down),
            y: (sampleRegion.minY * height).rounded(.down),
            width: max((sampleRegion.width * width).rounded(), 1),
            height: max((sampleRegion.height * height).rounded(), 1)
        )
        return image.cropping(to: rect)
    }

    // MARK: - HSB, by hand

    /// Written out rather than reached for from AppKit, because `NSColor`'s conversion is
    /// color-space aware and this arithmetic must be exactly reproducible in a test that has no
    /// display attached. Standard HSB; hue in 0..<1.
    static func hsb(_ color: AlbumColor) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        guard delta > 0, maximum > 0 else { return (0, 0, maximum) }

        let hue: Double
        switch maximum {
        case color.red: hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
        case color.green: hue = (color.blue - color.red) / delta + 2
        default: hue = (color.red - color.green) / delta + 4
        }
        return ((hue < 0 ? hue + 6 : hue) / 6, delta / maximum, maximum)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> AlbumColor {
        guard saturation > 0 else {
            return AlbumColor(red: brightness, green: brightness, blue: brightness)
        }
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector)
        let fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return AlbumColor(red: brightness, green: t, blue: p)
        case 1: return AlbumColor(red: q, green: brightness, blue: p)
        case 2: return AlbumColor(red: p, green: brightness, blue: t)
        case 3: return AlbumColor(red: p, green: q, blue: brightness)
        case 4: return AlbumColor(red: t, green: p, blue: brightness)
        default: return AlbumColor(red: brightness, green: p, blue: q)
        }
    }
}

// MARK: - The row the equaliser wears

extension AlbumColor {

    /// The number of bars a row is built for.
    ///
    /// Deliberately not `NowPlayingEqualiserView.count` by reference: this type knows nothing about
    /// views, and the equaliser asks for the count it wants. The default exists so a caller building
    /// a row for "the bars" does not have to name a number.
    public static let defaultBandCount = 6

    /// The cover read left to right as one smooth gradient — the leading bar is the left of the
    /// sleeve and the trailing bar its right, so the row runs the way the cover beside it does.
    ///
    /// **Two readings, not one per bar.** 2.4.1 averaged each bar's own vertical strip, and on a
    /// cover with any detail in it neighbouring strips land on unrelated colors — a pale face, then
    /// a red shirt, then a gray background — so the row read as six separate swatches rather than
    /// as the record, reported from hardware. Now only the two halves of `centre(of:)` are read, and
    /// the bars between them step evenly from one to the other (`blend(from:to:count:)`). The row
    /// keeps its direction and its two colors off the cover, and loses the jumps.
    ///
    /// Read across `centre(of:)`, not the full width, for the reason the accent is: the edges of a
    /// sleeve are borders and type. Each end is `legible(_:)`, so no bar is invisible on `#000000`
    /// and a near-gray half stays gray.
    ///
    /// A half with no opaque pixels in it — a cover with a transparent margin — takes the other
    /// half's color rather than leaving a black bar. Nil when nothing in the region is opaque, which
    /// is the same "no cover" `accent(from:)` answers.
    ///
    /// One CoreGraphics draw of an already-decoded image into a 2×4 context, once per track change,
    /// like `average(of:)`. Never on a frame.
    public static func row(from image: CGImage, count: Int = defaultBandCount) -> [AlbumColor]? {
        guard count > 0 else { return nil }
        let region = centre(of: image) ?? image
        let columns = 2
        let rows = 4
        let bytesPerRow = columns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: columns,
                      height: rows,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(region, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }

        // Premultiplied, so weighted by alpha exactly as `average(of:)` is.
        var halves = [(red: Double, green: Double, blue: Double, weight: Double)](
            repeating: (0, 0, 0, 0), count: columns
        )
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * bytesPerRow + column * 4
                halves[column].red += Double(pixels[index]) / 255
                halves[column].green += Double(pixels[index + 1]) / 255
                halves[column].blue += Double(pixels[index + 2]) / 255
                halves[column].weight += Double(pixels[index + 3]) / 255
            }
        }
        let ends = halves.map { half -> AlbumColor? in
            guard half.weight > 0 else { return nil }
            return legible(AlbumColor(
                red: half.red / half.weight,
                green: half.green / half.weight,
                blue: half.blue / half.weight
            ))
        }
        guard let left = ends[0] ?? ends[1], let right = ends[1] ?? ends[0] else { return nil }
        return blend(from: left, to: right, count: count)
    }

    /// `count` colors stepping evenly from `start` to `end`, both included.
    ///
    /// **In hue, saturation and brightness, the short way round the hue circle** — not in RGB,
    /// where the midpoint of a red and a green is a muddy brown and the row would dip through a
    /// color neither end has. A gray end (no saturation) has no hue worth keeping, so it borrows
    /// the other end's and the row fades in saturation alone; two gray ends give a row of grays.
    static func blend(from start: AlbumColor, to end: AlbumColor, count: Int) -> [AlbumColor] {
        guard count > 1 else { return count == 1 ? [start] : [] }
        var a = hsb(start)
        var b = hsb(end)
        if a.saturation == 0 { a.hue = b.hue }
        if b.saturation == 0 { b.hue = a.hue }
        var hueDelta = b.hue - a.hue
        if hueDelta > 0.5 { hueDelta -= 1 }
        if hueDelta < -0.5 { hueDelta += 1 }
        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            var hue = a.hue + hueDelta * t
            if hue < 0 { hue += 1 }
            if hue >= 1 { hue -= 1 }
            return rgb(
                hue: hue,
                saturation: a.saturation + (b.saturation - a.saturation) * t,
                brightness: a.brightness + (b.brightness - a.brightness) * t
            )
        }
    }
}
