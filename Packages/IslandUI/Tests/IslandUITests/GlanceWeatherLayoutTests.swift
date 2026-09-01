import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The weather surface's geometry, and the one piece of arithmetic on it that can be *wrong* rather
/// than merely ugly.
@Suite("The weather surface's layout")
struct GlanceWeatherLayoutTests {

    @Test("the height does not depend on the reading, or on how many days came back")
    func theHeightIsAConstant() {
        // The open island's height is agreed *before* the transition, through
        // `IslandController.expandedContentHeight`, and `islandPath` has to track a shape that has
        // settled. `contentHeight` takes no arguments at all, which is the strongest statement of
        // that: a refresh landing while the page is open cannot move the island's bottom edge under
        // a pointer resting on it. It is also why a forecast row with no day is empty rather than
        // absent.
        #expect(GlanceWeatherLayout.contentHeight > 0)
        let again = GlanceWeatherLayout.contentHeight
        #expect(GlanceWeatherLayout.contentHeight == again)
    }

    @Test("it fits inside the island's ceiling, with the cutout taken off the top")
    func itFitsTheIsland() {
        // The panel is created once at `maxExpandedBodySize` and never resized, so a surface taller
        // than that is one the island cannot draw — it would be clipped by the panel rather than by
        // anything anybody chose. The switcher row is taken off too, because the weather can be up
        // while music is playing beside it.
        let cutout: CGFloat = 32
        #expect(
            GlanceWeatherLayout.contentHeight + cutout + IslandPageIndicatorLayout.height
                <= IslandLayout.maxExpandedBodySize.height
        )
    }

    @Test("the surface draws as many rows as the provider fetches, and neither spells it twice")
    func theRowCountIsOneNumber() {
        // A cap the provider applies and the layout draws to has to be one number, or the day the
        // two disagree is the day six days are fetched into an island with room for five and nobody
        // notices which one went missing.
        #expect(GlanceWeatherLayout.forecastRows == WeatherPolicy.forecastDays)
    }

    @Test("the forecast's height is its rows and the gaps between them")
    func theForecastMeasuresWhatItDraws() {
        let rows = CGFloat(GlanceWeatherLayout.forecastRows)
        let expected = rows * GlanceWeatherLayout.forecastRowHeight
            + (rows - 1) * GlanceWeatherLayout.forecastRowSpacing
        #expect(GlanceWeatherLayout.forecastExtent == expected)
    }

    @Test("a narrow island keeps its numbers and loses the picture")
    func theRangeBarGivesWayFirst() {
        // A bar squeezed to twelve points is not a smaller picture, it is a mark that means nothing
        // — the same rule the month's event column follows.
        #expect(GlanceWeatherLayout.rangeBarWidth(inBodyWidth: 200) == nil)
        let wide = GlanceWeatherLayout.rangeBarWidth(inBodyWidth: IslandLayout.expandedBodySize.width)
        #expect(wide != nil)
        #expect((wide ?? 0) >= GlanceWeatherLayout.minimumRangeBarWidth)
    }
}

/// The range bar's arithmetic, which is the only thing on this surface a test can catch being wrong.
@Suite("The forecast's range bar")
struct WeatherRangeBarTests {

    @Test("a day's segment sits where its range sits inside the week's")
    func segmentsArePositioned() {
        // Coldest 0, warmest 10: a day of 0…5 fills the first half, and 5…10 the second.
        let cold = WeatherRangeBar.segment(low: 0, high: 5, coldest: 0, warmest: 10)
        #expect(abs(cold.start - 0) < 0.0001)
        #expect(abs(cold.length - 0.5) < 0.0001)

        let warm = WeatherRangeBar.segment(low: 5, high: 10, coldest: 0, warmest: 10)
        #expect(abs(warm.start - 0.5) < 0.0001)
        #expect(abs(warm.length - 0.5) < 0.0001)
    }

    @Test("a week with no spread draws a full bar rather than a NaN one")
    func aFlatWeekIsNotADivisionByZero() {
        // Five identical days, or one day on its own. Dividing by that zero would make every bar's
        // width `nan`, which SwiftUI draws as nothing at all — a surface that silently loses its
        // bars for a week of steady weather.
        let flat = WeatherRangeBar.segment(low: 4, high: 4, coldest: 4, warmest: 4)
        #expect(flat.start == 0)
        #expect(flat.length == 1)
    }

    @Test("a flat day inside a varied week still draws a visible mark")
    func aFlatDayKeepsAMark() {
        // A day whose low and high are the same is a fact about the weather, and a bar that
        // vanished would read as missing data.
        let segment = WeatherRangeBar.segment(low: 5, high: 5, coldest: 0, warmest: 10)
        #expect(segment.length > 0)
        #expect(segment.start + segment.length <= 1)
    }

    @Test("a segment never runs past the end of the bar")
    func segmentsStayInsideTheBar() {
        // Including the case where a day's own range exceeds the bounds it was given, which a
        // caller can produce by rounding the two in different directions.
        let segment = WeatherRangeBar.segment(low: -5, high: 20, coldest: 0, warmest: 10)
        #expect(segment.start >= 0)
        #expect(segment.start + segment.length <= 1.0001)
    }

    @Test("a low and a high the wrong way round are taken in order rather than negatively")
    func reversedInputsDoNotProduceANegativeBar() {
        let segment = WeatherRangeBar.segment(low: 8, high: 2, coldest: 0, warmest: 10)
        #expect(segment.length > 0)
        #expect(abs(segment.start - 0.2) < 0.0001)
    }

    @Test("the bounds are taken across the days drawn, in the unit they are drawn in")
    func boundsFollowTheDrawnDays() {
        // The reader is comparing these five days with each other, so the bar's ends are their
        // coldest and warmest — not a fixed scale, and not the whole forecast the service sent.
        let days = (0..<3).map { index in
            WeatherDay(
                date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400),
                highCelsius: Double(index) * 5,
                lowCelsius: Double(index) * 5 - 3,
                precipitationChance: 0.1,
                symbolName: "sun.max.fill",
                conditionDescription: "Clear"
            )
        }
        let celsius = WeatherRangeBar.bounds(of: days, unit: .celsius)
        #expect(celsius?.coldest == -3)
        #expect(celsius?.warmest == 10)

        // Fahrenheit is the same days through the conversion the rows themselves use, so the bar
        // and the numbers beside it cannot describe different scales.
        let fahrenheit = WeatherRangeBar.bounds(of: days, unit: .fahrenheit)
        #expect(fahrenheit?.coldest == 27)
        #expect(fahrenheit?.warmest == 50)

        #expect(WeatherRangeBar.bounds(of: [], unit: .celsius) == nil)
    }

    // MARK: - The page with no weather on it

    /// **The empty state lays out inside room that is already reserved.** `contentHeight` is a
    /// constant, so the sentence and the button that replace a forecast have the whole surface to
    /// sit in and must not ask for a point more than the readings they stand in for — a page that
    /// grew to fit its own apology would move the island's bottom edge, and the hit region with it,
    /// as a *consequence of a refresh failing*.
    @Test("the setup state fits in the space the forecast would have taken")
    func theSetupStateFitsTheReservedSpace() {
        let reserved = GlanceWeatherLayout.currentHeight
            + GlanceWeatherLayout.currentSpacing
            + GlanceWeatherLayout.metricsHeight
            + GlanceWeatherLayout.metricsSpacing
            + GlanceWeatherLayout.forecastExtent
        // Two lines of the sentence, the air under it, and the capsule.
        let asked = 2 * 16 + GlanceWeatherLayout.setupSpacing + GlanceWeatherLayout.setupButtonHeight
        #expect(asked < reserved)
    }

    /// The empty day's "Open Settings" and the empty weather's are the same capsule on two pages of
    /// one island. Read rather than repeated, so a second 20 cannot drift from the first.
    @Test("the setup button is the same height as the day's")
    func theSetupButtonMatchesTheDay() {
        #expect(GlanceWeatherLayout.setupButtonHeight == IslandHomeLayout.accessButtonHeight)
    }
}

/// Which of the two empty states the weather page is in.
@MainActor
@Suite("The weather page with nothing to show")
struct GlanceWeatherSetupTests {

    /// **False until the shell says otherwise**, which is §3's layering test: this package draws
    /// with nothing wired, and a default of true would offer a preview a button to a settings
    /// window that does not exist.
    @Test("a model nobody configured offers no way in")
    func silentByDefault() {
        #expect(!GlanceModel().weatherNeedsPlace)
    }

    /// A refresh that failed is a fault with nothing on this surface to do about it; a place nobody
    /// picked is a setting. The flag is the only thing that separates them — the reading is nil
    /// either way.
    @Test("the two empty states are told apart by the flag, not by the reading")
    func theFlagIsTheDiscriminator() {
        let glance = GlanceModel()
        #expect(glance.snapshot.weather == nil)
        #expect(!glance.weatherNeedsPlace)

        glance.weatherNeedsPlace = true
        #expect(glance.snapshot.weather == nil)
        #expect(glance.weatherNeedsPlace)
    }
}
