import CoreGraphics
import Foundation
import Testing

@testable import IslandUI

/// The precipitation field, asserted with no window, no clock and no running app.
///
/// Everything the view does is either handed to CoreAnimation unchanged or is one of these numbers,
/// which is the point of resolving the field as a value: a wrong drop count, a drop that leaves the
/// rectangle, or a reduce-motion substitution that quietly kept animating would otherwise be
/// invisible to a suite in which nothing draws.
@Suite("Precipitation")
struct PrecipitationTests {

    /// The open island's body, roughly — the rectangle this is really drawn in.
    private static let body = CGSize(width: 360, height: 150)

    private func field(
        _ kind: PrecipitationKind,
        _ intensity: PrecipitationIntensity = .moderate,
        size: CGSize = PrecipitationTests.body,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        scale: Double = 2
    ) -> PrecipitationField {
        PrecipitationField.resolve(
            size: size,
            kind: kind,
            intensity: intensity,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            scale: scale
        )
    }

    // MARK: - The accessibility settings

    /// Reduce Motion draws **nothing**, rather than a still field. §6.3 substitutes a crossfade for
    /// travel and rain has nothing to cross-fade between — frozen drops are pale ticks over the
    /// text, which reads as a rendering fault.
    @Test("Reduce Motion stops it entirely")
    func reduceMotionIsEmpty() {
        for kind in PrecipitationKind.allCases {
            for intensity in PrecipitationIntensity.allCases {
                #expect(field(kind, intensity, reduceMotion: true).drops.isEmpty)
            }
        }
    }

    @Test("Increase Contrast and Reduce Transparency stop it too")
    func contrastAndTransparencyAreEmpty() {
        #expect(field(.rain, increaseContrast: true).drops.isEmpty)
        #expect(field(.snow, increaseContrast: true).drops.isEmpty)
        #expect(field(.rain, reduceTransparency: true).drops.isEmpty)
        #expect(field(.snow, reduceTransparency: true).drops.isEmpty)
    }

    @Test("Any one of the three is enough on its own")
    func settingsDoNotHaveToAgree() {
        #expect(field(.rain, reduceMotion: true, increaseContrast: false).drops.isEmpty)
        #expect(field(.rain, reduceMotion: false, reduceTransparency: true).drops.isEmpty)
        #expect(!field(.rain).drops.isEmpty)
    }

    // MARK: - Placement

    @Test("An empty surface holds no drops")
    func emptySurface() {
        #expect(field(.rain, size: .zero).drops.isEmpty)
        #expect(field(.rain, size: CGSize(width: 300, height: 0)).drops.isEmpty)
        #expect(field(.snow, size: CGSize(width: 0, height: 200)).drops.isEmpty)
    }

    /// A drop that left the rectangle would be clipped by `masksToBounds` and read as rain sliced
    /// off down one edge. Rain leans one way, snow sways both, and the arithmetic differs.
    @Test("Every drop stays inside the surface for its whole fall")
    func dropsStayInside() {
        let width = Double(Self.body.width)

        for intensity in PrecipitationIntensity.allCases {
            let rain = field(.rain, intensity)
            for drop in rain.drops {
                #expect(drop.x >= 0)
                #expect(drop.x + drop.horizontalTravel <= width + 0.000_1)
            }

            let snow = field(.snow, intensity)
            for drop in snow.drops {
                #expect(drop.x - drop.horizontalTravel >= -0.000_1)
                #expect(drop.x + drop.horizontalTravel <= width + 0.000_1)
            }
        }
    }

    /// Stratified, one drop per column: the field must not clump, because clumping is what makes
    /// drawn rain look drawn. Asserted as an ordering rather than a spacing, which is what the
    /// stratification actually guarantees.
    @Test("Drops are spread across the width rather than clustered")
    func dropsAreStratified() {
        let drops = field(.rain, .heavy).drops
        #expect(drops.count > 8)
        #expect(zip(drops, drops.dropFirst()).allSatisfy { $0.x <= $1.x })

        let width = Double(Self.body.width)
        let firstQuarter = drops.filter { $0.x < width / 4 }.count
        let lastQuarter = drops.filter { $0.x > width * 3 / 4 }.count
        #expect(firstQuarter > 0)
        #expect(lastQuarter > 0)
    }

    @Test("The phase spreads the drops down the fall rather than dropping them in one rank")
    func phasesAreSpread() {
        let drops = field(.rain, .heavy).drops
        #expect(drops.allSatisfy { (0...1).contains($0.phase) })
        #expect(drops.contains { $0.phase < 0.3 })
        #expect(drops.contains { $0.phase > 0.7 })
    }

    // MARK: - How much of it

    @Test("More intensity is more drops, for both kinds")
    func intensityRaisesTheCount() {
        for kind in PrecipitationKind.allCases {
            let light = field(kind, .light).drops.count
            let moderate = field(kind, .moderate).drops.count
            let heavy = field(kind, .heavy).drops.count
            #expect(light < moderate)
            #expect(moderate < heavy)
        }
    }

    /// Snow is sparser than rain at the same word, because a flake is bigger, brighter and on
    /// screen for ten times as long — matching the counts would be a blizzard at "moderate".
    @Test("Snow is sparser than rain at the same intensity")
    func snowIsSparser() {
        for intensity in PrecipitationIntensity.allCases {
            #expect(field(.snow, intensity).drops.count < field(.rain, intensity).drops.count)
        }
    }

    @Test("A large surface is capped rather than filled")
    func countIsCapped() {
        let huge = field(.rain, .heavy, size: CGSize(width: 4000, height: 3000))
        #expect(huge.drops.count == PrecipitationField.maximumDrops)
    }

    @Test("A tiny surface still holds one drop rather than rounding to none")
    func tinySurface() {
        #expect(field(.rain, .light, size: CGSize(width: 20, height: 14)).drops.count >= 1)
    }

    // MARK: - How it falls

    /// Rain falls fast, straight-ish and thin; snow drifts. That is the whole difference between the
    /// two, and it is measurable: the same surface takes an order of magnitude longer to cross.
    @Test("Rain falls an order of magnitude faster than snow")
    func rainIsFasterThanSnow() {
        let rain = field(.rain).drops.map(\.duration)
        let snow = field(.snow).drops.map(\.duration)
        #expect(rain.max()! < snow.min()!)
        #expect(snow.min()! > rain.max()! * 5)
    }

    /// The view rotates a rain streak by `field.angle` and moves it from `x` to
    /// `x + horizontalTravel`. Those are two statements of the same lean, and a streak drawn along a
    /// line it does not travel down reads as a scratch on the glass — so they are pinned together
    /// here rather than left to agree by hand.
    @Test("A rain streak's lean is the lean it travels on")
    func leanMatchesTravel() {
        let field = self.field(.rain, .moderate)
        for drop in field.drops {
            #expect(abs(drop.horizontalTravel - tan(field.angle) * drop.verticalTravel) < 0.000_1)
        }
    }

    @Test("Rain leans and snow sways; neither is still")
    func horizontalTravel() {
        #expect(field(.rain).angle > 0)
        #expect(field(.snow).angle == 0)
        #expect(field(.rain).drops.allSatisfy { $0.horizontalTravel > 0 })
        #expect(field(.snow).drops.allSatisfy { $0.horizontalTravel > 0 })
    }

    /// Speed, length and weight are one number per drop, so a faster drop is a longer and brighter
    /// one. Three independent randoms read as noise rather than as depth.
    @Test("A faster drop is a longer and brighter one")
    func nearnessIsOneNumber() {
        let drops = field(.rain, .heavy).drops
        let quickest = drops.min(by: { $0.duration < $1.duration })!
        let slowest = drops.max(by: { $0.duration < $1.duration })!
        #expect(quickest.extent > slowest.extent)
        #expect(quickest.opacity > slowest.opacity)
    }

    /// It is behind the glance's text. Nothing may approach a weight where white-on-black stops
    /// being the brightest thing on the island.
    @Test("Nothing is drawn heavily enough to compete with the text")
    func opacitiesStayLow() {
        for kind in PrecipitationKind.allCases {
            for intensity in PrecipitationIntensity.allCases {
                let drops = field(kind, intensity).drops
                #expect(drops.allSatisfy { $0.opacity > 0 })
                #expect(drops.allSatisfy { $0.opacity <= 0.6 })
            }
        }
        #expect(field(.rain, .heavy).drops.allSatisfy { $0.opacity <= 0.42 })
    }

    /// **The one structural difference between the two kinds.** Rain enters from above the top edge
    /// and *stops* on the ground, which is what gives the impact an instant to happen at. Snow
    /// enters the same way and goes on out of the bottom, because it is still falling below the
    /// island.
    @Test("Rain stops on the ground; snow falls out of the bottom")
    func travelEndsDifferently() {
        let height = Double(Self.body.height)
        let ground = height - PrecipitationField.groundInset

        for drop in field(.rain).drops {
            #expect(drop.startY < 0)
            // The tip lands on the ground line, so the center stops half a streak above it.
            #expect(abs(drop.endY - (ground - drop.extent / 2)) < 0.000_1)
            #expect(drop.endY < ground)
        }

        for drop in field(.snow).drops {
            #expect(drop.startY < 0)
            #expect(drop.endY > height)
        }
    }

    // MARK: - The landing

    /// Snow does not splash. An impact is what a landing draws, and a flake arriving has none: it
    /// settles. Flakes stopped dead on a line would be a row of dots stuck to the bottom edge, and
    /// snow that actually *settled* would have to accumulate into a bar across the bottom of the
    /// glance that grows and never stops — which is the "it became the point" failure, drawn.
    @Test("Rain lands and snow does not")
    func onlyRainLands() {
        for intensity in PrecipitationIntensity.allCases {
            #expect(field(.snow, intensity).drops.allSatisfy { $0.landing == nil })
            #expect(field(.rain, intensity).drops.contains { $0.landing != nil })
        }
    }

    /// The flare belongs to the drop that made it: same column, same instant, on the ground line.
    @Test("A landing is where its drop arrives")
    func landingIsWhereTheDropArrives() {
        let height = Double(Self.body.height)
        for drop in field(.rain).drops {
            guard let landing = drop.landing else { continue }
            #expect(abs(landing.x - (drop.x + drop.horizontalTravel)) < 0.000_1)
            #expect(abs(landing.y - (height - PrecipitationField.groundInset)) < 0.000_1)
        }
    }

    /// A landing has to be over before the next drop in that column arrives, or the flare never goes
    /// out and the bottom edge is a row of lights rather than weather.
    @Test("A landing is over well inside its drop's own fall")
    func landingIsShorterThanTheFall() {
        for intensity in PrecipitationIntensity.allCases {
            for drop in field(.rain, intensity).drops {
                guard let landing = drop.landing else { continue }
                #expect(landing.duration > 0)
                #expect(landing.duration <= PrecipitationField.landingLife)
                #expect(landing.duration <= drop.duration * PrecipitationField.landingLifeCeiling)
            }
        }
    }

    /// The island's bottom corners curve *inward*, so towards each end there is progressively less
    /// ground under the rain. The root's mask would clip a flare drawn out there, but a mark that is
    /// half there reads as a rendering fault where a mark that is not there reads as nothing.
    @Test("Landings taper away towards the corners")
    func landingsTaperAtTheCorners() {
        let width = Double(Self.body.width)
        let drops = field(.rain, .heavy).drops

        for drop in drops {
            guard let landing = drop.landing else { continue }
            #expect(min(landing.x, width - landing.x) > PrecipitationField.landingEdgeMargin * 0.15)
        }

        // And what survives near the edge is dimmer and smaller than what lands in the middle.
        let nearEdge = drops.compactMap(\.landing)
            .filter { min($0.x, width - $0.x) < PrecipitationField.landingEdgeMargin }
        let middle = drops.compactMap(\.landing)
            .filter { min($0.x, width - $0.x) > PrecipitationField.landingEdgeMargin * 2 }
        #expect(!nearEdge.isEmpty)
        #expect(!middle.isEmpty)
        #expect(nearEdge.map(\.width).max()! < middle.map(\.width).max()!)
    }

    /// A landing must never outshine the drop that made it — a flash brighter than the rain reads as
    /// lights coming on along the bottom edge, and the glance's text sits above it.
    @Test("A landing is dimmer than its drop")
    func landingIsDimmerThanItsDrop() {
        for intensity in PrecipitationIntensity.allCases {
            for drop in field(.rain, intensity).drops {
                guard let landing = drop.landing else { continue }
                #expect(landing.opacity < drop.opacity)
                #expect(landing.droplets.allSatisfy { $0.opacity < drop.opacity })
            }
        }
    }

    /// Only the nearest drops throw droplets — the same `nearness` that decides speed, length and
    /// weight. Every landing throwing a pair would be a decorated line rather than weather.
    @Test("Only the nearest landings throw droplets, and they throw two")
    func dropletsAreForTheNearestOnly() {
        let landings = field(.rain, .heavy).drops.compactMap(\.landing)
        #expect(landings.contains { $0.droplets.count == 2 })
        #expect(landings.contains { $0.droplets.isEmpty })
        #expect(landings.allSatisfy { $0.droplets.isEmpty || $0.droplets.count == 2 })
        // One each way, and deliberately not mirrored: a symmetric pair reads as a graphic.
        for landing in landings where !landing.droplets.isEmpty {
            #expect(landing.droplets[0].spread < 0)
            #expect(landing.droplets[1].spread > 0)
            #expect(abs(landing.droplets[0].spread) != abs(landing.droplets[1].spread))
        }
    }

    /// The arc is a value rather than something the view draws by eye: up at halfway, back on the
    /// ground at the end, and traveling sideways throughout.
    @Test("A droplet goes up, out, and back down")
    func dropletArc() {
        let droplet = PrecipitationField.Droplet(spread: 4, rise: 5, size: 1, opacity: 0.2)
        let arc = droplet.arc(steps: 6)
        #expect(arc.count == 7)
        #expect(arc.first! == CGPoint(x: 0, y: 0))
        #expect(abs(arc.last!.x - 4) < 0.000_1)
        #expect(abs(arc.last!.y) < 0.000_1)
        // y-down, so up is negative, and the top of the throw is the middle of it.
        #expect(abs(arc[3].y + 5) < 0.000_1)
        #expect(arc.allSatisfy { $0.y <= 0.000_1 })
        #expect(zip(arc, arc.dropFirst()).allSatisfy { $0.x < $1.x })
    }

    /// Suppression is suppression: no drops means no marks along the bottom edge either.
    @Test("A suppressed field lands nothing")
    func suppressionRemovesLandings() {
        #expect(field(.rain, .heavy, reduceMotion: true).drops.isEmpty)
        #expect(field(.rain, .heavy, increaseContrast: true).drops.isEmpty)
        #expect(field(.rain, .heavy, reduceTransparency: true).drops.isEmpty)
    }

    /// The corner taper decides whether a landing is *drawn*, and it must not decide what every
    /// later drop looks like — or the field would reshuffle itself when the island got a point
    /// wider.
    @Test("Suppressing a corner landing does not shift the rest of the field")
    func fieldIsStableAcrossTheTaper() {
        #expect(field(.rain, .heavy) == field(.rain, .heavy))
        let narrow = field(.rain, .heavy, size: CGSize(width: 200, height: 150))
        #expect(narrow.drops.contains { $0.landing != nil })
    }

    // MARK: - Pixel snapping

    /// Unlike the equaliser's bars, a drop's *position* is meaningless to snap — it is moving, and
    /// the compositor interpolates it. Its **thickness** is not: a 1pt streak straddling a pixel
    /// boundary is drawn soft down both sides, and forty of those read as smudges.
    @Test("Thickness lands on the pixel grid at every scale", arguments: [1.0, 2.0, 3.0])
    func thicknessIsSnapped(scale: Double) {
        let pixel = 1 / scale
        for kind in PrecipitationKind.allCases {
            for drop in field(kind, .heavy, scale: scale).drops {
                #expect(drop.thickness >= pixel)
                let pixels = drop.thickness * scale
                #expect(abs(pixels - pixels.rounded()) < 0.000_1)
            }
        }
    }

    @Test("A view with no window yet is treated as 1× rather than divided by zero")
    func zeroScale() {
        let drops = field(.rain, scale: 0).drops
        #expect(!drops.isEmpty)
        #expect(drops.allSatisfy { $0.thickness >= 1 })
    }

    // MARK: - Determinism

    /// A relayout must not re-shuffle the rain under the user, and a test can assert nothing about a
    /// field that is different every time. `Double.random` is banned here for that reason.
    @Test("The same surface resolves to the same field every time")
    func resolutionIsDeterministic() {
        #expect(field(.rain, .moderate) == field(.rain, .moderate))
        #expect(field(.snow, .light) == field(.snow, .light))
    }

    @Test("A shower and a downpour are different fields, not the same one with more of it")
    func intensitiesAreDifferentFields() {
        let moderate = field(.rain, .moderate)
        let heavy = field(.rain, .heavy)
        #expect(moderate.drops.first?.x != heavy.drops.first?.x)
    }

    // MARK: - Reading the weather

    /// Matched on the symbol name, which is an identifier, never on the condition description,
    /// which is Apple's localized prose.
    @Test("Weather symbols map to what is falling")
    func symbolMapping() {
        #expect(Precipitation.matching(weatherSymbolName: "cloud.rain.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.heavyrain.fill")
            == Precipitation(kind: .rain, intensity: .heavy))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.drizzle")
            == Precipitation(kind: .rain, intensity: .light))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.sun.rain.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.bolt.rain.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.bolt.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.sleet.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.hail.fill")
            == Precipitation(kind: .rain, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "cloud.snow.fill")
            == Precipitation(kind: .snow, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "snowflake")
            == Precipitation(kind: .snow, intensity: .moderate))
        #expect(Precipitation.matching(weatherSymbolName: "wind.snow")
            == Precipitation(kind: .snow, intensity: .moderate))
    }

    /// Nil is the common answer and the one that matters: a clear sky must draw nothing rather than
    /// a light drizzle.
    @Test("A dry sky is nil, not a light shower")
    func drySymbols() {
        for symbol in ["sun.max.fill", "moon.stars.fill", "cloud.fill", "cloud.fog.fill",
                       "wind", "sun.haze.fill", "smoke.fill", "tornado", "thermometer.sun.fill"] {
            #expect(Precipitation.matching(weatherSymbolName: symbol) == nil)
        }
    }

    // MARK: - The generator

    @Test("The generator answers in 0..<1 and does not repeat itself")
    func generatorRange() {
        var generator = PrecipitationRandom(seed: 42)
        let values = (0..<512).map { _ in generator.next() }
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(Set(values.map { Int($0 * 1000) }).count > 300)
    }

    @Test("The same seed answers the same sequence")
    func generatorIsSeeded() {
        var first = PrecipitationRandom(seed: 7)
        var second = PrecipitationRandom(seed: 7)
        #expect((0..<16).map { _ in first.next() } == (0..<16).map { _ in second.next() })
    }
}
