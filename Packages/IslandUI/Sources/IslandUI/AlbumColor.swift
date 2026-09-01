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

    /// The same color, guaranteed to read as an accent against `#000000`.
    ///
    /// Pure arithmetic on the components — no `NSColor`, no `Color`, no appearance — so the rule
    /// "a black cover does not produce an invisible transport row" is a test rather than a look.
    public static func legible(_ color: AlbumColor) -> AlbumColor {
        var (hue, saturation, brightness) = hsb(color)
        saturation = min(max(saturation, minimumSaturation), maximumSaturation)
        brightness = max(brightness, minimumBrightness)
        return rgb(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// The accent a cover gives, or nil if it gives none. One call, so nobody averages without
    /// lifting.
    public static func accent(from image: CGImage) -> AlbumColor? {
        average(of: image).map(legible)
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

    /// How dark the far end of the row goes, as a fraction of the accent's own brightness.
    ///
    /// **Slight, on purpose.** The row is one color with a lean in it, not a gradient: past about a
    /// third the leading bars stop reading as the same color further away and start reading as a
    /// second color, which is the thing the accent exists to avoid. At the accent's guaranteed
    /// `minimumBrightness` this floor still leaves the dimmest bar well clear of the `#000000` it is
    /// drawn on.
    static let rowFadeFloor = 0.65

    /// One accent, spread across the bars — full strength at the trailing end and fading slightly
    /// toward the leading one.
    ///
    /// **The same color the scrub bar's played portion wears**, and that is the whole point: the
    /// island's Now Playing chrome has exactly one album color, and a row that read six of them off
    /// the sleeve was a second, unrelated answer to "what color is this record" sitting 40pt from
    /// the first. The lean is what keeps the row from being a flat block of tint — it gives the bars
    /// a direction, toward the transport controls and away from the cutout, without introducing a
    /// color the rest of the player does not use.
    ///
    /// Pure arithmetic on the components, like everything else in this type: no view, no image, and
    /// no second read of the artwork. The fade multiplies **brightness** rather than lowering alpha,
    /// because a translucent bar shows whatever the island is made of — a synthesized island is
    /// Liquid Glass, and a faded bar there would take the color of the user's wallpaper.
    public static func row(_ accent: AlbumColor, count: Int = defaultBandCount) -> [AlbumColor]? {
        guard count > 0 else { return nil }
        guard count > 1 else { return [accent] }
        return (0..<count).map { index in
            let position = Double(index) / Double(count - 1)
            let scale = rowFadeFloor + (1 - rowFadeFloor) * position
            return AlbumColor(
                red: accent.red * scale,
                green: accent.green * scale,
                blue: accent.blue * scale
            )
        }
    }
}
