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
                    let original = AlbumColor.hsb(AlbumColor(red: red, green: green, blue: blue))
                    if original.saturation < AlbumColor.neutralSaturation {
                        #expect(saturation < 1e-9)
                    } else {
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
            let dull = AlbumColor.rgb(hue: hue, saturation: 0.2, brightness: 0.08)
            let (liftedHue, _, _) = AlbumColor.hsb(AlbumColor.legible(dull))
            #expect(abs(liftedHue - hue) < 1e-6)
        }
    }

    /// The regression this rule is for: a white Apple logo on a black icon averaged a percent or two
    /// toward blue, the lift saturated that to 0.42, and a monochrome cover put a violet row on the
    /// island.
    @Test("a near-gray cover stays gray rather than being given a hue")
    func nearGrayStaysNeutral() {
        let almostGray = AlbumColor(red: 0.30, green: 0.30, blue: 0.32)
        let (_, saturation, brightness) = AlbumColor.hsb(AlbumColor.legible(almostGray))
        #expect(saturation < 1e-9)
        #expect(brightness >= AlbumColor.minimumBrightness - 1e-9)
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

    /// The direction is the design: the leading bar is the cover's left and the trailing bar its
    /// right, so the row runs the way the sleeve beside it does.
    @Test("the row reads the cover from left to right")
    func theRowRunsLeftToRight() throws {
        let image = try #require(Self.leftRightImage())
        let row = try #require(AlbumColor.row(from: image))
        #expect(row.count == AlbumColor.defaultBandCount)
        let first = try #require(row.first)
        let last = try #require(row.last)
        #expect(first.red > first.blue, "the left of the cover is red")
        #expect(last.blue > last.red, "the right of the cover is blue")
    }

    /// The middle of the cover, not its edges. A sleeve with a white border read edge to edge put
    /// that border on both outer bars; the region inside it is the record.
    @Test("the row ignores a border round the cover")
    func theRowReadsTheMiddle() throws {
        let image = try #require(Self.borderedImage())
        let row = try #require(AlbumColor.row(from: image))
        for bar in row {
            let (hue, saturation, _) = AlbumColor.hsb(bar)
            #expect(saturation >= AlbumColor.minimumSaturation - 1e-9)
            #expect(abs(hue - 1.0 / 3) < 0.02, "every bar is the green inside the border")
        }
    }

    @Test("every bar is lifted clear of the black it is drawn on")
    func everyBarIsLegible() throws {
        let image = try #require(Self.flatImage(red: 0.02, green: 0.02, blue: 0.03))
        let row = try #require(AlbumColor.row(from: image))
        for bar in row {
            #expect(AlbumColor.hsb(bar).brightness >= AlbumColor.minimumBrightness - 1e-9)
        }
    }

    /// The bug 2.4.1 shipped: a bar per strip of a detailed cover gave neighbours unrelated
    /// colors. Every step along the row is now the same size, so it reads as one gradient.
    @Test("the row steps evenly from one end to the other")
    func theRowIsAGradient() throws {
        let image = try #require(Self.leftRightImage())
        let row = try #require(AlbumColor.row(from: image))
        let hsb = row.map(AlbumColor.hsb)
        var steps: [Double] = []
        for (a, b) in zip(hsb, hsb.dropFirst()) {
            var delta = b.hue - a.hue
            if delta > 0.5 { delta -= 1 }
            if delta < -0.5 { delta += 1 }
            steps.append(delta)
        }
        let first = try #require(steps.first)
        for step in steps { #expect(abs(step - first) < 0.01) }
    }

    @Test("the blend goes the short way round the hue circle and keeps both ends")
    func blendTakesTheShortArc() {
        // Red-magenta (hue 0.95) to red-orange (0.05): through red, not through green.
        let start = AlbumColor.rgb(hue: 0.95, saturation: 0.8, brightness: 0.9)
        let end = AlbumColor.rgb(hue: 0.05, saturation: 0.8, brightness: 0.9)
        let row = AlbumColor.blend(from: start, to: end, count: 6)
        #expect(row.count == 6)
        #expect(row.first == start)
        for bar in row {
            let hue = AlbumColor.hsb(bar).hue
            #expect(hue > 0.9 || hue < 0.1, "every bar stays near red")
        }
        #expect(abs(AlbumColor.hsb(row[5]).hue - 0.05) < 0.001)
    }

    @Test("a gray end borrows the other end's hue rather than sweeping through red")
    func grayEndKeepsTheOtherHue() {
        let gray = AlbumColor(red: 0.7, green: 0.7, blue: 0.7)
        let blue = AlbumColor.rgb(hue: 0.6, saturation: 0.7, brightness: 0.9)
        let row = AlbumColor.blend(from: gray, to: blue, count: 6)
        for bar in row.dropFirst() {
            #expect(abs(AlbumColor.hsb(bar).hue - 0.6) < 0.001)
        }
        #expect(AlbumColor.blend(from: gray, to: gray, count: 1) == [gray])
        #expect(AlbumColor.blend(from: gray, to: blue, count: 0).isEmpty)
    }

    @Test("a transparent cover gives no row, and a row of no bars is no row")
    func noRow() throws {
        let clear = try #require(Self.flatImage(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(AlbumColor.row(from: clear) == nil)
        let solid = try #require(Self.flatImage(red: 0.5, green: 0.2, blue: 0.2))
        #expect(AlbumColor.row(from: solid, count: 0) == nil)
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

    /// Red on the left half, blue on the right.
    private static func leftRightImage() -> CGImage? {
        let side = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: side / 2, y: 0, width: side / 2, height: side))
        return context.makeImage()
    }

    /// Green, inside a white border a tenth of the side wide.
    private static func borderedImage() -> CGImage? {
        let side = 40
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: 0.1, green: 0.8, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 4, y: 4, width: side - 8, height: side - 8))
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
