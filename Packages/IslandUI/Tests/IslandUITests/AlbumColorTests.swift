import CoreGraphics
import Testing

@testable import IslandUI

/// The color taken off a cover, as arithmetic.
///
/// The failure this suite exists for is not "the accent is the wrong shade". It is **a transport row
/// nobody can see**: the island is pure `#000000`, and a cover that averages dark — a black sleeve,
/// a night photograph, most metal records ever pressed — hands back a near-black accent that draws
/// three invisible buttons on an invisible background. Nothing in a build catches that, and on a
/// screenshot it looks like the transport row failing to render.
@Suite("Album color")
struct AlbumColorTests {

    // MARK: - HSB, which everything else rests on

    @Test("hue, saturation and brightness round-trip")
    func hsbRoundTrips() {
        let samples = [
            AlbumColor(red: 0.9, green: 0.2, blue: 0.1),
            AlbumColor(red: 0.1, green: 0.7, blue: 0.4),
            AlbumColor(red: 0.2, green: 0.3, blue: 0.95),
            AlbumColor(red: 0.5, green: 0.5, blue: 0.5),
            AlbumColor(red: 1, green: 1, blue: 0),
            AlbumColor(red: 0, green: 0, blue: 0),
        ]
        for sample in samples {
            let (hue, saturation, brightness) = AlbumColor.hsb(sample)
            let back = AlbumColor.rgb(hue: hue, saturation: saturation, brightness: brightness)
            #expect(abs(back.red - sample.red) < 1e-9)
            #expect(abs(back.green - sample.green) < 1e-9)
            #expect(abs(back.blue - sample.blue) < 1e-9)
        }
    }

    // MARK: - Legibility

    /// The one that matters. Every color a cover can produce, lifted, has to clear the floor.
    @Test("no color survives the lift below the readable floor")
    func everyColorBecomesReadable() {
        for red in stride(from: 0.0, through: 1.0, by: 0.125) {
            for green in stride(from: 0.0, through: 1.0, by: 0.125) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.125) {
                    let lifted = AlbumColor.legible(AlbumColor(red: red, green: green, blue: blue))
                    let (_, saturation, brightness) = AlbumColor.hsb(lifted)
                    #expect(brightness >= AlbumColor.minimumBrightness - 1e-9)
                    // A gray cover has no hue to saturate, so the floor cannot apply to it — and it
                    // must not, or every monochrome sleeve would be assigned an arbitrary color.
                    let isGray = red == green && green == blue
                    if !isGray {
                        #expect(saturation >= AlbumColor.minimumSaturation - 1e-9)
                    }
                    #expect(saturation <= AlbumColor.maximumSaturation + 1e-9)
                    #expect(lifted.red <= 1 && lifted.green <= 1 && lifted.blue <= 1)
                    #expect(lifted.red >= 0 && lifted.green >= 0 && lifted.blue >= 0)
                }
            }
        }
    }

    @Test("a black cover does not produce an invisible accent")
    func blackIsLifted() {
        let lifted = AlbumColor.legible(AlbumColor(red: 0, green: 0, blue: 0))
        let (_, _, brightness) = AlbumColor.hsb(lifted)
        #expect(brightness >= AlbumColor.minimumBrightness)
    }

    /// A fully saturated primary against pure black is the one combination that fringes on an OLED,
    /// and a cover that is genuinely one flat color averages to exactly that.
    @Test("a flat primary is pulled back from full saturation")
    func fullSaturationIsCapped() {
        let lifted = AlbumColor.legible(AlbumColor(red: 1, green: 0, blue: 0))
        let (hue, saturation, _) = AlbumColor.hsb(lifted)
        #expect(saturation <= AlbumColor.maximumSaturation + 1e-9)
        #expect(saturation < 1)
        // The hue is untouched: it is still red, just not shouting.
        #expect(abs(hue) < 1e-9)
    }

    /// The lift moves saturation and brightness and **never the hue**. A cover's color is the one
    /// thing the user can name, and an accent that arrived a different color from the sleeve would
    /// read as the feature picking at random.
    @Test("the lift never changes the hue")
    func hueIsPreserved() {
        for hue in stride(from: 0.0, to: 1.0, by: 0.05) {
            let dull = AlbumColor.rgb(hue: hue, saturation: 0.1, brightness: 0.08)
            let (liftedHue, _, _) = AlbumColor.hsb(AlbumColor.legible(dull))
            #expect(abs(liftedHue - hue) < 1e-6)
        }
    }

    @Test("a color already inside the bounds is left alone")
    func alreadyLegibleIsUntouched() {
        let good = AlbumColor.rgb(hue: 0.55, saturation: 0.6, brightness: 0.8)
        let lifted = AlbumColor.legible(good)
        #expect(abs(lifted.red - good.red) < 1e-9)
        #expect(abs(lifted.green - good.green) < 1e-9)
        #expect(abs(lifted.blue - good.blue) < 1e-9)
    }

    // MARK: - Reading it off an image

    @Test("a flat image averages to its own color")
    func flatImageAverages() throws {
        let image = try #require(Self.flatImage(red: 0.25, green: 0.5, blue: 0.75))
        let average = try #require(AlbumColor.average(of: image))
        #expect(abs(average.red - 0.25) < 0.01)
        #expect(abs(average.green - 0.5) < 0.01)
        #expect(abs(average.blue - 0.75) < 0.01)
    }

    /// Premultiplied alpha is the trap: a logo on a transparent background averages to near-black
    /// if the transparent pixels are counted as pixels, however bright the logo is.
    @Test("transparent pixels do not drag the average towards black")
    func transparencyIsWeighted() throws {
        let image = try #require(Self.halfTransparentWhite())
        let average = try #require(AlbumColor.average(of: image))
        // White in the opaque half, nothing in the other. Weighted by alpha, the answer is white.
        #expect(average.red > 0.9)
        #expect(average.green > 0.9)
        #expect(average.blue > 0.9)
    }

    @Test("a fully transparent image gives no accent at all")
    func emptyImageGivesNothing() throws {
        let image = try #require(Self.flatImage(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(AlbumColor.average(of: image) == nil)
        #expect(AlbumColor.accent(from: image) == nil)
    }

    /// Nil is the whole degraded path, and it has to look the same as the setting being off — which
    /// is what `NowPlayingController.accent` answering with the fallback means.
    @Test("accent is average then lift, in that order and with no way round it")
    func accentLifts() throws {
        let image = try #require(Self.flatImage(red: 0.04, green: 0.03, blue: 0.05))
        let accent = try #require(AlbumColor.accent(from: image))
        let (_, _, brightness) = AlbumColor.hsb(accent)
        #expect(brightness >= AlbumColor.minimumBrightness)
    }

    // MARK: - The row the equaliser wears

    /// The direction is the design: full strength at the trailing end, fading toward the leading
    /// one. Reversed, the row would lean into the cutout instead of away from it — which looks
    /// deliberate either way and is only wrong if you know which way it was meant to go.
    @Test("the row is brightest at the trailing end and fades toward the leading one")
    func theRowLeans() throws {
        let accent = AlbumColor.legible(AlbumColor(red: 0.9, green: 0.3, blue: 0.2))
        let row = try #require(AlbumColor.row(accent))
        #expect(row.count == AlbumColor.defaultBandCount)
        #expect(row.last == accent)
        for (dimmer, brighter) in zip(row, row.dropFirst()) {
            #expect(AlbumColor.hsb(dimmer).brightness < AlbumColor.hsb(brighter).brightness)
        }
    }

    /// One color, not a gradient between two. The fade multiplies brightness and leaves hue and
    /// saturation alone, which is what makes the leading bars read as the same color further away
    /// rather than as a second color.
    @Test("the fade changes brightness and nothing else")
    func theFadeKeepsTheColor() throws {
        let accent = AlbumColor.legible(AlbumColor(red: 0.2, green: 0.5, blue: 0.9))
        let row = try #require(AlbumColor.row(accent))
        let reference = AlbumColor.hsb(accent)
        for band in row {
            let (hue, saturation, _) = AlbumColor.hsb(band)
            #expect(abs(hue - reference.hue) < 1e-9)
            #expect(abs(saturation - reference.saturation) < 1e-9)
        }
    }

    /// "Slightly." Past about a third the leading bars stop reading as the same color further away,
    /// and the accent's guaranteed floor stops being any guarantee about what is on screen.
    @Test("the dimmest bar is still plainly the accent")
    func theFadeIsSlight() throws {
        let accent = AlbumColor.legible(AlbumColor(red: 0, green: 0, blue: 0))
        let row = try #require(AlbumColor.row(accent))
        let dimmest = AlbumColor.hsb(try #require(row.first)).brightness
        #expect(dimmest >= AlbumColor.minimumBrightness * AlbumColor.rowFadeFloor - 1e-9)
        #expect(dimmest > 0.4)
    }

    @Test("a row of one bar is the accent itself, with nowhere to lean")
    func aSingleBarIsTheAccent() throws {
        let accent = AlbumColor(red: 0.4, green: 0.8, blue: 0.6)
        #expect(AlbumColor.row(accent, count: 1) == [accent])
    }

    @Test("a row of no bars is no row")
    func zeroBandsIsNil() {
        #expect(AlbumColor.row(AlbumColor(red: 0.5, green: 0.5, blue: 0.5), count: 0) == nil)
    }

    // MARK: - Fixtures

    private static func flatImage(
        red: Double, green: Double, blue: Double, alpha: Double = 1
    ) -> CGImage? {
        let side = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func halfTransparentWhite() -> CGImage? {
        let side = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        return context.makeImage()
    }
}
