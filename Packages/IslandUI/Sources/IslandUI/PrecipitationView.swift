import AppKit
import IslandKit
import QuartzCore
import SwiftUI

/// What is falling.
///
/// Two kinds and not five, because the island draws atmosphere rather than a forecast: sleet and
/// hail read as fast small particles and are drawn as rain, and everything that settles is drawn as
/// snow. A third kind would be a distinction nobody can see at 30pt behind three lines of text.
public enum PrecipitationKind: String, CaseIterable, Sendable {
    case rain
    case snow
}

/// How much of it there is.
///
/// Three steps rather than a continuous rate. WeatherKit reports a condition, not millimetres per
/// hour, so a `Double` here would be a precision the source does not have — and the three steps are
/// what the eye separates anyway: a few streaks, a shower, a downpour.
public enum PrecipitationIntensity: String, CaseIterable, Sendable {
    case light
    case moderate
    case heavy
}

/// A kind and an intensity together, and the one place a weather symbol is turned into them.
///
/// **Matched on the SF Symbol name, never on the condition description.** `WeatherReading` carries
/// both, and `conditionDescription` is Apple's *localized* prose — matching on it is the mistake
/// CLAUDE.md already records for the notification banner's action titles, right down to being
/// invisible until the first machine that is not in English. `symbolName` is an identifier.
public struct Precipitation: Equatable, Sendable {

    public var kind: PrecipitationKind

    public var intensity: PrecipitationIntensity

    public init(kind: PrecipitationKind, intensity: PrecipitationIntensity) {
        self.kind = kind
        self.intensity = intensity
    }

    /// The precipitation an SF Symbol name implies, or nil where nothing is falling.
    ///
    /// Nil is the common answer and the important one: a clear sky, cloud, fog, wind and haze all
    /// land here, and they must draw nothing rather than a light drizzle. Substring matching rather
    /// than a table of exact names, because WeatherKit composes these — `cloud.sun.rain.fill`,
    /// `cloud.moon.rain.fill` and `cloud.bolt.rain.fill` are all rain with something else in front,
    /// and an exhaustive list would go quietly stale the next time Apple adds a condition.
    public static func matching(weatherSymbolName name: String) -> Precipitation? {
        let symbol = name.lowercased()

        let kind: PrecipitationKind
        if symbol.contains("snow") || symbol.contains("blizzard") || symbol.contains("flurries")
            || symbol.contains("snowflake") {
            kind = .snow
        } else if symbol.contains("rain") || symbol.contains("drizzle") || symbol.contains("sleet")
            || symbol.contains("hail") || symbol.contains("bolt") {
            // Sleet and hail fall fast and straight, so they are drawn as rain rather than as snow
            // however they are classified. `bolt` with no `rain` in it is Apple's thunderstorm
            // symbol, which is not a dry condition.
            kind = .rain
        } else {
            return nil
        }

        let intensity: PrecipitationIntensity
        if symbol.contains("heavy") || symbol.contains("blizzard") {
            intensity = .heavy
        } else if symbol.contains("drizzle") || symbol.contains("flurries") {
            intensity = .light
        } else {
            intensity = .moderate
        }

        return Precipitation(kind: kind, intensity: intensity)
    }
}

/// Where every drop starts, how long it takes to fall, and how it is shaped — resolved once, with no
/// window, no clock and no view.
///
/// ## Why this is a value and not a renderer
///
/// PERF.md's 9.6 correction is the whole design: per-frame drawing from this process through
/// SwiftUI's `Canvas`/`TimelineView` costs **17.7 % of a core and 279 MB regardless of how big the
/// drawing is**, and the same animation handed to CoreAnimation costs **0.007–0.010 % and 14.6 MB**
/// because the render server owns it and this process draws nothing. So the field is arithmetic
/// done once, and every drop's fall is a `CAKeyframeAnimation` the compositor runs on its own.
/// Being a plain value is what makes the placement, the speeds and the reduce-motion substitution
/// answerable in tests, the way `EqualiserBarGeometry` and `NowPlayingEqualiserView.heights(at:)`
/// are.
///
/// ## Coordinates
///
/// **y-down**, like `IslandShapeGeometry` and SwiftUI: `x` is measured from the leading edge and a
/// drop falls towards increasing y. `PrecipitationLayersView` converts at the boundary, because a
/// `CALayer` in an unflipped `NSView` is y-up. Every drop starts one `extent` *above* the top edge,
/// so nothing pops into existence there; where it finishes is the difference between the two kinds,
/// and it is the whole subject of `Landing`.
///
/// ## Randomness
///
/// Deterministic, from a fixed seed. Rain that is laid out differently on every relayout would
/// re-shuffle when the user resizes their display or the glance gains a row, and a test could assert
/// nothing about it. `Double.random` is banned here for the same reason `ActivityClock` is not a
/// `Timer`: not cost, but that the result has to be reproducible.
public struct PrecipitationField: Equatable {

    /// One drop.
    public struct Drop: Equatable {

        /// Where the drop's center is when it is at the top of its fall, in y-down space.
        public var x: Double

        /// How far the drop moves horizontally over one fall. For rain that is the wind's lean —
        /// a single displacement to the right. For snow it is the **amplitude** of the sway either
        /// side of `x`.
        public var horizontalTravel: Double

        /// Where the drop's center begins, in y-down space — above the top edge, so it enters from
        /// off-surface rather than appearing at a boundary.
        public var startY: Double

        /// Where its center ends. **Rain stops on the ground and snow does not**, which is the one
        /// place the two kinds differ in shape rather than in numbers: a rain drop finishes with its
        /// tip on the landing line, and a flake finishes below the bottom edge, still falling.
        public var endY: Double

        /// A rain streak's length, or a snowflake's diameter.
        public var extent: Double

        /// The streak's width, or the flake's diameter again. Snapped to the pixel grid.
        public var thickness: Double

        /// 0…1. Kept well below 1 on purpose: this is behind the glance's text.
        public var opacity: Double

        /// One fall, top to bottom.
        public var duration: TimeInterval

        /// 0…1 — where in that fall the drop is at the moment the field is handed over, so the
        /// drops are spread down the surface instead of arriving in one rank.
        public var phase: Double

        /// What happens when it arrives. Nil for snow, and nil for a rain drop landing in a corner
        /// where there is no flat ground under it — see `PrecipitationField.landingEdgeMargin`.
        public var landing: Landing?

        /// How far the drop actually travels.
        public var verticalTravel: Double { endY - startY }

        public init(
            x: Double,
            horizontalTravel: Double,
            startY: Double,
            endY: Double,
            extent: Double,
            thickness: Double,
            opacity: Double,
            duration: TimeInterval,
            phase: Double,
            landing: Landing? = nil
        ) {
            self.x = x
            self.horizontalTravel = horizontalTravel
            self.startY = startY
            self.endY = endY
            self.extent = extent
            self.thickness = thickness
            self.opacity = opacity
            self.duration = duration
            self.phase = phase
            self.landing = landing
        }
    }

    /// What a rain drop does when it arrives: a flare, and for the nearest drops two droplets
    /// thrown off it.
    ///
    /// ## Why a flare rather than a crown
    ///
    /// A drop striking a hard surface throws a **crown** — a ring of liquid that rises, thins and
    /// breaks into secondary droplets — and it is about a hundredth of a second of geometry that
    /// nobody has ever resolved with the naked eye. Every convincing implementation of rain fakes
    /// it the same way, because the eye is reading two things only: *something happened at that
    /// point*, and *it happened fast*. So the landing is a short horizontal streak that appears at
    /// the instant of impact, spreads outward and fades — the crown flattened into one mark — plus,
    /// for the drops drawn as nearest, two small droplets that arc up and out and come back down.
    /// Nothing here is simulated, and a simulation would need per-frame work in this process, which
    /// is the one thing the whole design exists to avoid.
    ///
    /// ## Phase-locking, which is what makes this free
    ///
    /// The landing is *not* scheduled. It is another `CAAnimation` on another layer, with the
    /// **same period and the same wall-clock `timeOffset` as the drop's own fall**, whose visible
    /// window sits at the start of the cycle. The start of a cycle is the instant the previous
    /// cycle ended — which is the instant that drop reached the ground — so the flare fires exactly
    /// when its drop arrives, forever, with nothing in this process ever waking up to arrange it.
    public struct Landing: Equatable {

        /// Where the drop meets the ground, in y-down space.
        public var x: Double

        public var y: Double

        /// How wide the flare spreads. Scaled down towards the corners, where the island's own
        /// bottom edge is curving away and there is progressively less ground to hit.
        public var width: Double

        public var thickness: Double

        /// The flare's weight at the instant of impact, before it fades to nothing.
        public var opacity: Double

        /// How long the whole landing lasts. Short: an impact that lingers is a puddle.
        public var duration: TimeInterval

        /// Two, or none. The nearest drops throw droplets; the far ones are a mark and nothing more,
        /// which is the same `nearness` that already decides a drop's speed, length and weight.
        public var droplets: [Droplet]

        public init(
            x: Double,
            y: Double,
            width: Double,
            thickness: Double,
            opacity: Double,
            duration: TimeInterval,
            droplets: [Droplet]
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.thickness = thickness
            self.opacity = opacity
            self.duration = duration
            self.droplets = droplets
        }
    }

    /// One piece thrown off a landing: up, out, and back down inside the landing's own window.
    public struct Droplet: Equatable {

        /// Signed: one droplet goes each way, and the pair is deliberately asymmetric because two
        /// mirrored droplets read as a graphic rather than as a splash.
        public var spread: Double

        /// How high it goes above the landing line.
        public var rise: Double

        public var size: Double

        public var opacity: Double

        public init(spread: Double, rise: Double, size: Double, opacity: Double) {
            self.spread = spread
            self.rise = rise
            self.size = size
            self.opacity = opacity
        }

        /// The arc, sampled — in y-down space, relative to the landing point.
        ///
        /// A parabola rather than a curve chosen by eye, and sampled here rather than in the view so
        /// the shape of the throw is a value a test can hold: up to `rise` at halfway, back to the
        /// ground at the end, traveling `spread` sideways throughout.
        public func arc(steps: Int = 6) -> [CGPoint] {
            (0...steps).map { step in
                let t = Double(step) / Double(steps)
                return CGPoint(x: spread * t, y: -rise * 4 * t * (1 - t))
            }
        }
    }

    public var kind: PrecipitationKind

    public var drops: [Drop]

    /// How far a rain streak is tilted from vertical, in radians — the same angle the streak's own
    /// travel makes, so a drop is drawn along the line it moves down. Zero for snow, which has no
    /// single direction to point at.
    public var angle: Double

    public init(kind: PrecipitationKind, drops: [Drop], angle: Double) {
        self.kind = kind
        self.drops = drops
        self.angle = angle
    }

    /// The ceiling on how many drops a surface may hold, whatever its size.
    ///
    /// A cap rather than a pure density, because the island's body is one size today and the field
    /// is asked for whatever rectangle it is handed. Sixty-four layers is already well past the
    /// point where a person could count them; see the measurement in PERF.md's precipitation note.
    public static let maximumDrops = 64

    /// The rain's lean, in radians. One constant for every intensity: wind is not what "heavy"
    /// means, and rain leaning further as it gets heavier reads as the island tilting.
    public static let rainAngle = 12.0 * .pi / 180

    /// How far above the bottom edge the ground sits.
    ///
    /// **The ground is the bottom of the rectangle this view is given, and the caller decides where
    /// that is.** Inside the island that edge is a curve — the shape's bottom corners turn *inward*
    /// — and the root masks everything to `IslandShape`, so a flare drawn on the boundary is clipped
    /// rather than drawn wrong. Clipping is not enough on its own though: a mark that is half there
    /// reads as a rendering fault where a mark that is not there reads as nothing. So the landing
    /// row is lifted a few points clear of the edge *and* tapered towards the corners, and the mask
    /// is left as the backstop it should be rather than as the mechanism.
    public static let groundInset: Double = 3

    /// How far in from each side the ground is treated as curving away.
    ///
    /// Roughly the island's own bottom corner radius. Inside it a landing's flare and weight are
    /// scaled down to nothing, so rain still falls into the corners and simply stops marking them —
    /// which is what a surface that is sloping away from you looks like.
    public static let landingEdgeMargin: Double = 30

    /// How long a landing lasts, and the ceiling on it as a fraction of the fall it belongs to.
    ///
    /// 0.11 s is about as long as a mark can sit on the bottom edge before it stops reading as an
    /// impact and starts reading as a light that came on. The fraction matters because a drop's
    /// whole fall is only ~0.27 s: the landing has to be over well before the next drop in that
    /// column arrives, or the flare never goes out.
    public static let landingLife: TimeInterval = 0.11
    public static let landingLifeCeiling: Double = 0.45

    /// Above this nearness a landing throws droplets.
    ///
    /// The nearest drops only. Every landing throwing two would be sixty-four flares and a hundred
    /// and twenty-eight droplets along one edge, which is a decorated line rather than weather.
    public static let dropletNearness: Double = 0.55

    // MARK: - Resolving

    /// The field for a surface, or an empty one where nothing should be drawn.
    ///
    /// ## The three ways this answers with nothing, and why each is the honest answer
    ///
    /// - **Reduce Motion.** Nothing at all — not frozen drops. §6.3 substitutes a crossfade for
    ///   travel, and rain has nothing to cross-fade between: its entire content *is* the falling.
    ///   A still field is a scatter of pale ticks over the text, which reads as a rendering fault
    ///   rather than as weather, and the same information is already on the glance's own weather
    ///   chip as a symbol and a description. So the substitution for motion here is absence.
    /// - **Increase Contrast.** The user has asked for the strongest possible separation between
    ///   content and background. Drops behind three lines of text are exactly the competition that
    ///   setting exists to remove.
    /// - **Reduce Transparency.** The same answer for a different reason. The setting's own
    ///   remedy — make the translucent thing opaque — would turn a 30 % veil into solid white marks
    ///   across the middle of the glance, which is worse in the direction the user was complaining
    ///   about. Atmosphere is the thing that can be dropped; the calendar is not.
    public static func resolve(
        size: CGSize,
        kind: PrecipitationKind,
        intensity: PrecipitationIntensity,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        scale: Double
    ) -> PrecipitationField {
        let angle = kind == .rain ? rainAngle : 0
        guard !reduceMotion, !reduceTransparency, !increaseContrast else {
            return PrecipitationField(kind: kind, drops: [], angle: angle)
        }
        guard size.width > 0, size.height > 0 else {
            return PrecipitationField(kind: kind, drops: [], angle: angle)
        }

        // A backing scale of zero or less is what a view reports before it has a window; treat it as
        // 1× rather than dividing by it, exactly as `EqualiserBarGeometry` does.
        let pixel = 1.0 / max(scale, 1)
        func snap(_ value: Double) -> Double { max(pixel, (value / pixel).rounded() * pixel) }

        let recipe = Recipe(kind: kind, intensity: intensity)
        let width = Double(size.width)
        let height = Double(size.height)
        let area = width * height
        let count = min(
            maximumDrops,
            max(1, Int((area / 10_000 * recipe.dropsPerTenThousandSquarePoints).rounded()))
        )

        // Seeded from the kind and the intensity so a shower and a downpour are different fields
        // rather than the same one with more of it, and so both are the same on every launch.
        var generator = PrecipitationRandom(seed: recipe.seed)

        let drops = (0..<count).map { index -> Drop in
            // Nearness: one number per drop, driving speed, size and opacity together. A drop that
            // is faster is also longer and brighter, which is what reads as depth — three
            // independent randoms read as noise.
            let nearness = generator.next()
            let speed = recipe.speed.lerp(nearness)
            let extent = snap(recipe.extent(speed: speed, nearness: nearness))
            let thickness = snap(recipe.thickness.lerp(nearness))
            let opacity = recipe.opacity.lerp(nearness)

            // Where the fall begins and ends. **This is the one structural difference between the
            // two kinds.** Rain stops: it starts one `extent` above the top edge and finishes with
            // its tip on the landing line, which is what gives the impact an instant to happen at.
            // Snow does not stop — it goes on out of the bottom of the island, because a flake that
            // halted on a line would be a dot stuck to the edge, and snow that *settled* would have
            // to accumulate into a bright bar across the bottom of the glance and never stop
            // growing.
            let startY = -extent
            let endY: Double
            switch kind {
            case .rain: endY = max(startY, height - groundInset - extent / 2)
            case .snow: endY = height + extent
            }
            let travel = endY - startY

            let reach: Double
            switch kind {
            case .rain: reach = tan(rainAngle) * travel
            case .snow: reach = recipe.sway.lerp(generator.next())
            }

            // Stratified across the width — one drop per column, jittered inside it — so the field
            // has no bald patches and no accidental pairs. Uniform sampling clumps visibly at these
            // counts, which is the thing that makes drawn rain look drawn.
            // Rain leans one way, so it needs room on that side only; snow sways both ways and
            // needs room on both. Either way a drop's center line stays inside the rectangle for
            // its whole fall, so the rectangular clip in the view is a guarantee against arithmetic
            // going wrong rather than something the layout leans on.
            let leading = kind == .rain ? 0 : reach
            let span = max(0, width - reach - leading)
            let column = span / Double(count)
            let x = leading + (Double(index) + generator.next()) * column

            let duration = travel / speed
            let landing = kind == .rain
                ? Self.landing(
                    at: x + reach,
                    y: height - groundInset,
                    width: width,
                    nearness: nearness,
                    drop: (thickness: thickness, opacity: opacity),
                    fallDuration: duration,
                    generator: &generator,
                    snap: snap
                )
                : nil

            return Drop(
                x: x,
                horizontalTravel: reach,
                startY: startY,
                endY: endY,
                extent: extent,
                thickness: thickness,
                opacity: opacity,
                duration: duration,
                phase: generator.next(),
                landing: landing
            )
        }

        return PrecipitationField(kind: kind, drops: drops, angle: angle)
    }

    /// What one drop does when it arrives, or nil where it should leave no mark.
    ///
    /// The generator is drawn from **before** the taper is applied and before the nearness test, so
    /// a landing that is suppressed still consumes exactly what a landing that is drawn consumes.
    /// Otherwise a drop near a corner would shift every later drop's numbers, and the field would
    /// reshuffle itself when the island got wider by a point.
    private static func landing(
        at x: Double,
        y: Double,
        width: Double,
        nearness: Double,
        drop: (thickness: Double, opacity: Double),
        fallDuration: TimeInterval,
        generator: inout PrecipitationRandom,
        snap: (Double) -> Double
    ) -> Landing? {
        let spreadJitter = generator.next()
        let riseJitter = generator.next()
        let asymmetry = generator.next()

        // Towards a corner the island's own edge is curving away underneath, so there is less and
        // less to hit. Below a sixth of the taper there is nothing worth drawing.
        let taper = min(1, max(0, min(x, width - x) / landingEdgeMargin))
        guard taper > 0.15, fallDuration > 0 else { return nil }

        let life = min(landingLife, fallDuration * landingLifeCeiling)
        let droplets: [Droplet]
        if nearness > dropletNearness, taper > 0.6 {
            let spread = 2 + 2.5 * spreadJitter
            let rise = 3 + 2.5 * riseJitter
            let lean = 0.7 + 0.6 * asymmetry
            droplets = [
                Droplet(
                    spread: -spread * lean,
                    rise: rise,
                    size: drop.thickness,
                    opacity: drop.opacity * 0.7 * taper
                ),
                Droplet(
                    spread: spread * (1.7 - lean),
                    rise: rise * 0.8,
                    size: drop.thickness,
                    opacity: drop.opacity * 0.7 * taper
                ),
            ]
        } else {
            droplets = []
        }

        return Landing(
            x: x,
            y: y,
            width: max(2, snap((4.5 + 6 * nearness) * taper)),
            // Half a point thicker than the streak that made it. A mark exactly as thin as the drop
            // reads as the drop lying down rather than as it breaking up, and this is the cheapest
            // way to say "this is a different thing now" without making it brighter.
            thickness: snap(drop.thickness * 1.5),
            // Dimmer than the drop that made it, not brighter. A flash brighter than the rain reads
            // as a row of lights coming on along the bottom edge, and the glance's text is the point.
            opacity: drop.opacity * 0.8 * taper,
            duration: life,
            droplets: droplets
        )
    }

    // MARK: - What each kind and intensity is made of

    /// A closed range written as two ends and read by interpolation, so every per-drop value is one
    /// `nearness` away from every other. `ClosedRange` would do, except that the whole point is that
    /// these are read together rather than sampled independently.
    struct Span: Equatable {
        var near: Double
        var far: Double
        func lerp(_ t: Double) -> Double { far + (near - far) * min(max(t, 0), 1) }
    }

    /// Everything that differs between rain and snow, and between the three intensities.
    ///
    /// ## The numbers, and why they are these numbers
    ///
    /// **Rain falls fast, straight-ish and thin.** 380–760 pt/s means a drop crosses the open
    /// island's body in a fifth of a second, which is about where the eye stops seeing individual
    /// objects and starts seeing rain. The streak's length is the distance it covers in 22 ms —
    /// motion blur, arrived at from the speed rather than chosen beside it, which is why a fast drop
    /// is automatically a long one.
    ///
    /// **Snow drifts.** 22–58 pt/s is roughly a tenth of rain's speed, and the sway is what makes it
    /// snow rather than slow rain: without the lateral travel the flakes read as dust settling.
    ///
    /// **The opacities are legibility numbers, not aesthetic ones.** Rain tops out at 0.42 and snow
    /// at 0.58 — a flake is brighter because there are a third as many of them and each is a dot
    /// rather than a stroke across the text. Neither approaches the white the glance's own type is
    /// set in, which is the test: the field is atmosphere behind the content, and the content is the
    /// point.
    struct Recipe {

        var dropsPerTenThousandSquarePoints: Double
        var speed: Span
        var thickness: Span
        var opacity: Span
        /// Snow only — the sway either side of the drop's column.
        var sway: Span
        var seed: UInt64
        var kind: PrecipitationKind

        init(kind: PrecipitationKind, intensity: PrecipitationIntensity) {
            self.kind = kind
            switch (kind, intensity) {
            case (.rain, .light):
                dropsPerTenThousandSquarePoints = 3.4
                speed = Span(near: 520, far: 380)
                thickness = Span(near: 1.2, far: 0.8)
                opacity = Span(near: 0.30, far: 0.14)
            case (.rain, .moderate):
                dropsPerTenThousandSquarePoints = 6.0
                speed = Span(near: 640, far: 440)
                thickness = Span(near: 1.3, far: 0.9)
                opacity = Span(near: 0.36, far: 0.16)
            case (.rain, .heavy):
                dropsPerTenThousandSquarePoints = 9.6
                speed = Span(near: 760, far: 520)
                thickness = Span(near: 1.4, far: 0.9)
                opacity = Span(near: 0.42, far: 0.18)
            case (.snow, .light):
                dropsPerTenThousandSquarePoints = 2.2
                speed = Span(near: 40, far: 22)
                thickness = Span(near: 2.8, far: 1.6)
                opacity = Span(near: 0.46, far: 0.24)
            case (.snow, .moderate):
                dropsPerTenThousandSquarePoints = 3.8
                speed = Span(near: 48, far: 26)
                thickness = Span(near: 3.2, far: 1.6)
                opacity = Span(near: 0.52, far: 0.26)
            case (.snow, .heavy):
                dropsPerTenThousandSquarePoints = 6.0
                speed = Span(near: 58, far: 32)
                thickness = Span(near: 3.4, far: 1.8)
                opacity = Span(near: 0.58, far: 0.28)
            }
            sway = kind == .rain ? Span(near: 0, far: 0) : Span(near: 14, far: 5)
            // Distinct per field, constant per launch.
            seed = UInt64(bitPattern: Int64(kind.rawValue.hashValueSeed &+ intensity.rawValue.hashValueSeed))
        }

        /// A rain streak is as long as the distance the drop covers in 22 ms — so speed and length
        /// cannot disagree. A flake is round, so its extent is simply its diameter.
        func extent(speed: Double, nearness: Double) -> Double {
            switch kind {
            case .rain: speed * 0.022
            case .snow: thickness.lerp(nearness)
            }
        }
    }
}

/// SplitMix64, so the field is reproducible.
///
/// A generator of our own rather than `SystemRandomNumberGenerator` because reproducibility is the
/// requirement: the same surface must lay out the same way on every launch, so a test can assert
/// where the drops are and a relayout cannot re-shuffle the rain under the user.
struct PrecipitationRandom {

    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    /// The next value in 0..<1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

private extension String {
    /// A stable hash for the seed. `hashValue` is salted per process and would give a different
    /// field on every launch, which is the one thing the generator exists to prevent.
    var hashValueSeed: Int64 {
        var value: Int64 = 5381
        for byte in utf8 { value = (value &* 33) &+ Int64(byte) }
        return value
    }
}

/// Precipitation falling behind the glance's content, and landing on the bottom of it.
///
/// Self-contained: it takes what to draw as parameters and fills whatever frame it is given. It
/// draws no text, reads no model and knows nothing about the weather — the caller decides there is
/// rain and how much of it, and `Precipitation.matching(weatherSymbolName:)` is there to do that
/// mapping in one place if the caller wants it.
///
/// ## The ground is the bottom of the frame you give it
///
/// Rain stops at the bottom edge of this view and marks it; snow falls out through it. So the frame
/// decides where the weather appears to be landing, and a frame that stops short of the island's
/// own bottom edge draws rain stopping in mid-air. Give it the rectangle whose bottom is the
/// surface you want the rain to hit.
///
/// ## Nothing per frame, ever
///
/// This is `NowPlayingEqualiserView`'s shape and it is that shape for PERF.md's measured reason: a
/// `Canvas` or a `TimelineView` here would cost 17.7 % of a core and 279 MB whether it drew forty
/// drops or one bar, and the size of the surface does not enter into it. Everything below is
/// `CALayer`s carrying `CAKeyframeAnimation`s that the render server runs; this process does no work
/// at all once the field is handed over.
public struct PrecipitationView: View {

    public let kind: PrecipitationKind

    public let intensity: PrecipitationIntensity

    /// §6.3. True stops the precipitation entirely — see `PrecipitationField.resolve`.
    public let reduceMotion: Bool

    /// §6.3. True stops it too, for a different reason given in the same place.
    public let reduceTransparency: Bool

    /// §6.3. True stops it as well.
    public let increaseContrast: Bool

    public init(
        kind: PrecipitationKind,
        intensity: PrecipitationIntensity,
        reduceMotion: Bool,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) {
        self.kind = kind
        self.intensity = intensity
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    public init(
        _ precipitation: Precipitation,
        reduceMotion: Bool,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) {
        self.init(
            kind: precipitation.kind,
            intensity: precipitation.intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    public var body: some View {
        PrecipitationLayers(
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// The bridge from SwiftUI to the layers.
///
/// It holds no state: `updateNSView` hands the inputs across and the view decides whether anything
/// actually changed. SwiftUI re-runs this on every content change on the island — a title arriving,
/// a scrub, a row appearing — and rebuilding the field on each of those would re-phase every drop
/// and make the rain jump for reasons the user cannot see.
private struct PrecipitationLayers: NSViewRepresentable {

    let kind: PrecipitationKind
    let intensity: PrecipitationIntensity
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool

    func makeNSView(context: Context) -> PrecipitationLayersView {
        PrecipitationLayersView(
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    func updateNSView(_ view: PrecipitationLayersView, context: Context) {
        view.apply(
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

/// One `CALayer` per drop, and the animations the render server runs on them.
///
/// ## What this view must never do
///
/// - **Draw.** There is no `draw(_:)` and there must not be one. A drop is a background color and
///   a corner radius, which the compositor renders on the GPU without ever asking this process for
///   a pixel. `contents`, a `CAShapeLayer` path or a `CAGradientLayer` mask would put rasterisation
///   back on the table and give back what this shape bought.
/// - **Take a click.** `hitTest` returns nil unconditionally, so a press reaches
///   `IslandHitTestView.mouseDown` and can still close the island. This is the AppKit half of the
///   rule CLAUDE.md records for `.allowsHitTesting(false)`, which would collapse the whole window's
///   event shape rather than this view's.
/// - **Fill with a gradient.** The fade at each end of a drop's fall is an animation on the layer's
///   own `opacity`, not a gradient behind it: a gradient fill inside this panel widens the window's
///   event shape and breaks click pass-through *outside* the island, which `ClickSelfTest` cannot
///   see and `PassThroughSelfTest` reports as failures in the corner carve-outs.
final class PrecipitationLayersView: NSView {

    private struct Input: Equatable {
        var kind: PrecipitationKind
        var intensity: PrecipitationIntensity
        var reduceMotion: Bool
        var reduceTransparency: Bool
        var increaseContrast: Bool
    }

    private static let fallKey = "isleta.precipitation.fall"
    private static let fadeKey = "isleta.precipitation.fade"
    private static let landingKey = "isleta.precipitation.landing"
    private static let arrivalKey = "isleta.precipitation.arrival"

    /// How long the view waits for the island to stop moving before it resolves a field.
    ///
    /// **This is not a duration in §6.1's sense and it is not tunable to taste.** Nothing animates
    /// over it: it is how long a *burst of layout* has to be quiet before the field is worth
    /// resolving. It exists because the island's own morph animates this view's frame, so `layout()`
    /// runs on every frame of it — and resolving a field per frame would allocate sixty-four layers
    /// and a hundred and twenty-eight animations thirty times over a third of a second, which is
    /// exactly the per-frame work in this process that the whole design exists to avoid. One frame
    /// at 60 Hz is 16 ms; 50 ms is comfortably past the last frame of a morph and far below anything
    /// a person reads as a delay, because the rain is arriving into an island that has just stopped
    /// growing.
    private static let settleDelay: TimeInterval = 0.05

    private var input: Input
    private var appliedField: PrecipitationField?
    private var appliedSize: CGSize = .zero
    private var appliedScale: Double = 0
    private var appliedInput: Input?
    /// Bumped on every scheduled rebuild, so a later one cancels an earlier one without a
    /// `DispatchWorkItem` to keep hold of.
    private var rebuildToken = 0
    private var drops: [CALayer] = []
    /// The flares and droplets. Kept apart from `drops` only so both can be torn down together and
    /// counted separately in a measurement.
    private var splashes: [CALayer] = []

    init(
        kind: PrecipitationKind,
        intensity: PrecipitationIntensity,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        input = Input(
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        super.init(frame: .zero)
        wantsLayer = true
        // Rectangular, so it costs the compositor nothing, and it guarantees a drop never paints
        // outside the rectangle the caller handed us however the field is resolved.
        layer?.masksToBounds = true
        // Implicit animations off for good: a layer property assigned outside an explicit
        // transaction animates over CoreAnimation's own 0.25 s default, which is an inline duration
        // by the back door and §6.1 forbids those whichever framework writes them.
        layer?.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PrecipitationLayersView is not loaded from a nib") }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        kind: PrecipitationKind,
        intensity: PrecipitationIntensity,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        let next = Input(
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        guard next != input else { return }
        input = next
        // The weather changing is an event, not a frame of an animation, so it lands at once.
        rebuild(arriving: true)
    }

    override func layout() {
        super.layout()
        guard window != nil else { return }
        let scale = Double(window?.backingScaleFactor ?? 1)
        guard bounds.size != appliedSize || scale != appliedScale || input != appliedInput else { return }
        scheduleRebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Every thickness is snapped against the scale, so a scale change is a rebuild.
        appliedScale = 0
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Off screen is not a state the render server should be animating through. The island
            // takes its panels down on a space transition and rebuilds them on a display change; a
            // field left falling on a detached layer is work nobody can see.
            rebuildToken &+= 1
            drops.forEach { $0.removeAllAnimations() }
            splashes.forEach { $0.removeAllAnimations() }
            appliedField = nil
            appliedSize = .zero
        } else {
            // The field has to be forgotten on the way back in as well as on the way out. Coming
            // back to a surface of the same size with the same weather resolves to the *same*
            // field, so a rebuild keyed only on the field changing would take the early return and
            // leave every layer sitting at opacity zero with the animations that were removed when
            // the window went away.
            appliedField = nil
            appliedSize = .zero
            needsLayout = true
        }
    }

    // MARK: - Handing the field over

    /// Rebuild once the layout stops moving — see `settleDelay`.
    ///
    /// **Crossfaded, like a change of weather.** The field is arithmetic on the rectangle, so a
    /// rectangle that changed size resolves to a different field: every drop is re-placed and
    /// re-phased, and swapping the layers outright is a whole shower jumping in one frame. That is
    /// most visible on the one resize a user performs by accident — putting the pointer on the open
    /// island reveals the switcher row, the island grows to hold it, and the ground moves down with
    /// its bottom edge. So the new field arrives on §6.2's curve rather than cutting to it.
    private func scheduleRebuild() {
        rebuildToken &+= 1
        let token = rebuildToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rebuildToken == token else { return }
                self.rebuild(arriving: true)
            }
        }
    }

    private func rebuild(arriving: Bool) {
        guard window != nil else { return }
        // Anything already scheduled is answered by this pass.
        rebuildToken &+= 1
        let scale = Double(window?.backingScaleFactor ?? 1)
        appliedSize = bounds.size
        appliedScale = scale
        appliedInput = input
        let field = PrecipitationField.resolve(
            size: bounds.size,
            kind: input.kind,
            intensity: input.intensity,
            reduceMotion: input.reduceMotion,
            reduceTransparency: input.reduceTransparency,
            increaseContrast: input.increaseContrast,
            scale: scale
        )
        guard field != appliedField else { return }
        appliedField = field

        // Enum values and a count, at `debug`, on a path that only runs when the field actually
        // changed — so it is free when logging is off and silent while the rain simply falls. There
        // is no weather in it: what is falling is not where the user is.
        IslandLog.weather.debug(
            "precipitation kind=\(field.kind.rawValue) intensity=\(self.input.intensity.rawValue) drops=\(field.drops.count)"
        )

        // One wall-clock reading for the whole field. Every animation in it is anchored to this
        // instant, so a drop and its own landing cannot be a few microseconds out of step.
        let now = Date.timeIntervalSinceReferenceDate

        CATransaction.begin()
        // Implicit actions only. An explicit `add(_:forKey:)` is unaffected by this, which is why
        // the whole build — layers *and* their animations — can sit inside one transaction.
        CATransaction.setDisableActions(true)
        drops.forEach { $0.removeFromSuperlayer() }
        splashes.forEach { $0.removeFromSuperlayer() }
        splashes = []
        drops = field.drops.map { drop in
            let layer = layer(for: drop, in: field, scale: scale)
            self.layer?.addSublayer(layer)
            fall(layer, drop: drop, in: field, now: now)

            guard let landing = drop.landing else { return layer }
            let marks = self.marks(for: landing, drop: drop, scale: scale, now: now)
            marks.forEach { self.layer?.addSublayer($0) }
            splashes.append(contentsOf: marks)
            return layer
        }
        CATransaction.commit()

        guard arriving, !field.drops.isEmpty else { return }
        // A change of weather is a content change, so it crosses on §6.2's curve rather than
        // appearing. `Motion.contentSwapDuration` exists precisely because CoreAnimation takes a
        // `CFTimeInterval` where SwiftUI takes a spring; inventing a number here is what §6.1
        // forbids.
        let arrival = CABasicAnimation(keyPath: "opacity")
        arrival.fromValue = 0
        arrival.toValue = 1
        arrival.duration = Motion.contentSwapDuration
        arrival.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(arrival, forKey: Self.arrivalKey)
    }

    private func layer(for drop: PrecipitationField.Drop, in field: PrecipitationField, scale: Double) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = scale
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // White, spelled in sRGB for §6.4's reason: a named color can resolve to an
        // appearance-sensitive variant and lift off a pure-black island by a shade. The drop's own
        // opacity carries its weight, and it is animated, so the color stays at full alpha.
        layer.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        layer.opacity = 0
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "transform": NSNull()]

        switch field.kind {
        case .rain:
            layer.bounds = CGRect(x: 0, y: 0, width: drop.thickness, height: drop.extent)
            layer.cornerRadius = drop.thickness / 2
            // Along the line it travels, not merely leaning: a streak pointing anywhere else reads
            // as a scratch on the glass. Positive is counter-clockwise, and this view is not
            // flipped, so this leans the streak's top towards the leading edge — which is the way a
            // drop falling down and to the right is tilted.
            layer.transform = CATransform3DMakeRotation(field.angle, 0, 0, 1)
        case .snow:
            layer.bounds = CGRect(x: 0, y: 0, width: drop.extent, height: drop.extent)
            layer.cornerRadius = drop.extent / 2
        }
        return layer
    }

    /// Where in its own cycle a drop is at `now`.
    ///
    /// Anchored to the wall clock, as the equaliser's pattern is: a rebuild, a relayout or a second
    /// island on another display all land on the same instant of the same fall, so the field has no
    /// state of its own to drift. Every animation belonging to one drop — the fall, its fade, its
    /// flare and its droplets — is given this same offset, which is what phase-locks the landing to
    /// the arrival with nothing scheduling anything.
    private func timeOffset(for drop: PrecipitationField.Drop, now: TimeInterval) -> TimeInterval {
        (now + drop.phase * drop.duration).truncatingRemainder(dividingBy: drop.duration)
    }

    /// One drop's fall: a path the render server walks at a constant speed, forever.
    private func fall(
        _ layer: CALayer,
        drop: PrecipitationField.Drop,
        in field: PrecipitationField,
        now: TimeInterval
    ) {
        let height = Double(bounds.height)
        guard drop.verticalTravel > 0, drop.duration > 0 else { return }

        let fall = CAKeyframeAnimation(keyPath: "position")
        fall.path = path(for: drop, in: field, height: height)
        // Constant speed along the path. Without it the sway's curved segments would be walked in
        // equal times rather than at equal speeds, and the snow would hurry through its own drift.
        fall.calculationMode = .paced
        fall.duration = drop.duration
        fall.repeatCount = .infinity
        fall.isRemovedOnCompletion = false
        fall.fillMode = .both
        fall.timeOffset = timeOffset(for: drop, now: now)

        // The ends of the fall, as an animation rather than as a gradient — see the note on this
        // class.
        //
        // **The two kinds end differently, and it is the whole point of the landing.** A flake
        // fades out as it leaves the bottom of the island, because it is still falling below it. A
        // rain drop does not fade at all on the way down: it is put out in the last few per cent of
        // its travel, at the instant its tip reaches the ground and the flare takes over. A drop
        // that dimmed on approach would read as evaporating in front of the surface it is about to
        // hit.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, drop.opacity, drop.opacity, 0]
        fade.keyTimes = field.kind == .rain ? [0, 0.10, 0.97, 1] : [0, 0.12, 0.86, 1]
        fade.duration = drop.duration
        fade.repeatCount = .infinity
        fade.isRemovedOnCompletion = false
        fade.fillMode = .both
        fade.timeOffset = fall.timeOffset

        layer.removeAllAnimations()
        layer.add(fall, forKey: Self.fallKey)
        layer.add(fade, forKey: Self.fadeKey)
    }

    // MARK: - The landing

    /// The layers one landing needs — the flare, and the droplets if it throws any — already
    /// animated.
    ///
    /// ## The trick, and it is the only one here
    ///
    /// Every animation runs on the **drop's own period** with the **drop's own `timeOffset`**, and
    /// its visible window is the first `landing.duration` of that period. A cycle's start is the
    /// instant the previous cycle ended, which is the instant that drop's tip reached the ground —
    /// so the flare appears exactly when the drop lands, and goes on doing that forever with this
    /// process asleep. There is no `beginTime` arithmetic to get wrong, no timer, and nothing to
    /// re-synchronize when the view is rebuilt.
    ///
    /// The wrap is what sells it: at the end of a cycle the flare is fully spread and at zero
    /// opacity, and at the start of the next it is back to a point at full weight. Read on screen
    /// that is nothing, then a mark — which is what an impact is.
    private func marks(
        for landing: PrecipitationField.Landing,
        drop: PrecipitationField.Drop,
        scale: Double,
        now: TimeInterval
    ) -> [CALayer] {
        let period = drop.duration
        guard period > 0, landing.duration > 0 else { return [] }
        let window = min(0.9, landing.duration / period)
        let offset = timeOffset(for: drop, now: now)
        let ground = CGPoint(x: landing.x, y: Double(bounds.height) - landing.y)

        let flare = mark(size: CGSize(width: landing.thickness, height: landing.thickness), scale: scale)
        flare.position = ground

        // Outward, not upward. The crown a real drop throws is a ring rising off the surface, and
        // seen edge-on at this size the only part of it the eye can resolve is that it got wider.
        let spread = CAKeyframeAnimation(keyPath: "bounds.size.width")
        spread.values = [landing.thickness, landing.width, landing.width]
        spread.keyTimes = [0, NSNumber(value: window), 1]
        spread.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
        ]
        repeating(spread, period: period, offset: offset)
        flare.add(spread, forKey: Self.landingKey)

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [landing.opacity, 0, 0]
        flash.keyTimes = [0, NSNumber(value: window), 1]
        flash.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
        ]
        repeating(flash, period: period, offset: offset)
        flare.add(flash, forKey: Self.fadeKey)

        return [flare] + landing.droplets.map { droplet in
            let layer = mark(size: CGSize(width: droplet.size, height: droplet.size), scale: scale)
            layer.position = ground

            // The arc, sampled by the field and turned over into layer space here. Values rather
            // than a path, because a path animation cannot be held still for the rest of the period
            // — and the droplet has to be *gone* for the four fifths of the cycle in which its drop
            // is still on its way down.
            let points = droplet.arc().map { point in
                NSValue(point: NSPoint(x: ground.x + point.x, y: ground.y - point.y))
            }
            let steps = points.count - 1
            let throwOff = CAKeyframeAnimation(keyPath: "position")
            throwOff.values = points + [points[steps]]
            throwOff.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps) * window) }
                + [1]
            repeating(throwOff, period: period, offset: offset)
            layer.add(throwOff, forKey: Self.landingKey)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [droplet.opacity, droplet.opacity, 0, 0]
            fade.keyTimes = [0, NSNumber(value: window * 0.6), NSNumber(value: window), 1]
            repeating(fade, period: period, offset: offset)
            layer.add(fade, forKey: Self.fadeKey)

            return layer
        }
    }

    /// A landing's layer: white, round-ended, invisible until its animation says otherwise.
    private func mark(size: CGSize, scale: Double) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = scale
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.cornerRadius = min(size.width, size.height) / 2
        layer.opacity = 0
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        return layer
    }

    /// The settings every landing animation shares: one drop's period, that drop's phase, forever.
    private func repeating(_ animation: CAAnimation, period: TimeInterval, offset: TimeInterval) {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        animation.timeOffset = offset
    }

    /// The line a drop falls down, in **layer** coordinates.
    ///
    /// The field is y-down and this view is not flipped, so y is turned over here — at the boundary,
    /// which is where CLAUDE.md says the conversion belongs.
    private func path(
        for drop: PrecipitationField.Drop,
        in field: PrecipitationField,
        height: Double
    ) -> CGPath {
        let path = CGMutablePath()
        let travel = drop.verticalTravel
        let top = height - drop.startY
        switch field.kind {
        case .rain:
            path.move(to: CGPoint(x: drop.x, y: top))
            path.addLine(to: CGPoint(x: drop.x + drop.horizontalTravel, y: top - travel))
        case .snow:
            // A sine, sampled into short lines. Sampled rather than drawn with curves because the
            // path is built once and walked by the compositor: the segment count buys smoothness at
            // no per-frame cost, and 32 of them across a fall is well under a point of error.
            let steps = 32
            let cycles = 1.6
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let x = drop.x + sin(t * cycles * 2 * .pi) * drop.horizontalTravel
                let y = top - travel * t
                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        return path
    }
}
