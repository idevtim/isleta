import CoreGraphics
import Foundation
import IslandActivities

/// Where the weather surface's parts sit.
///
/// `GlanceScheduleLayout`'s counterpart, and it inherits that type's one non-negotiable property:
///
/// # Every number here is a constant, and the height most of all
///
/// `contentHeight` does not depend on the reading, on how many days came back, or on whether the
/// service answered a humidity. The open island's height is agreed **before** the transition through
/// `IslandController.expandedContentHeight`, and `islandPath` has to track a shape that has settled
/// — so a surface that grew when a refresh arrived with one more day in it would move its own bottom
/// edge under a pointer resting on it, on a spring, through the widen-then-tighten protocol, fifteen
/// minutes after the user stopped touching anything.
///
/// A forecast row that has no day to draw is therefore **empty** rather than absent, exactly as a
/// month's padding cells are `Color.clear` of the same size rather than omitted views.
public enum GlanceWeatherLayout {

    public static let horizontalPadding: CGFloat = GlanceLayout.horizontalPadding

    public static let topPadding: CGFloat = GlanceLayout.topPadding

    public static let bottomPadding: CGFloat = 12

    /// The place, and the way back to the day.
    public static let headerHeight: CGFloat = 22

    public static let headerSpacing: CGFloat = 8

    /// The temperature, the condition, and today's range.
    public static let currentHeight: CGFloat = 54

    public static let currentSpacing: CGFloat = 10

    /// The row of four readings — the percentages this surface exists for, and the two numbers that
    /// go with them.
    public static let metricsHeight: CGFloat = 32

    public static let metricsSpacing: CGFloat = 10

    /// One day of the forecast.
    public static let forecastRowHeight: CGFloat = 22

    public static let forecastRowSpacing: CGFloat = 2

    /// How many rows the surface draws, whether or not there are that many days.
    ///
    /// The same number the provider fetches, read from the one place both can see it — see
    /// `WeatherPolicy.forecastDays` for why it may not be spelled twice.
    public static let forecastRows = WeatherPolicy.forecastDays

    /// The day's name — "Today", "Wed". Fixed, so every symbol in the column starts at the same x;
    /// a column sized to its contents gives five rows a ragged edge, which reads as a layout fault
    /// rather than as typography. Wide enough for a translated abbreviation — Spanish's "mié" and
    /// German's "Mi" both fit, and so does "Heute".
    public static let dayColumnWidth: CGFloat = 52

    /// The condition glyph on a forecast row.
    public static let daySymbolWidth: CGFloat = 20

    /// The chance of precipitation, right-aligned so the percent signs line up down the column.
    public static let chanceColumnWidth: CGFloat = 38

    /// A temperature at either end of the range bar. Fixed for the day column's reason, and sized
    /// for "-10°" rather than for "8°" — a Mac in Fahrenheit in January is the wide case.
    public static let temperatureColumnWidth: CGFloat = 30

    /// The bar between the low and the high. Four points rather than three since it carries the
    /// temperature colors — a three-point line of orange reads as a hairline with a tint.
    public static let rangeBarHeight: CGFloat = 4

    /// The current temperature's mark on today's bar, and the dark ring that separates it from a
    /// bar of the same lightness. Larger than the bar, as Weather.app draws it, so it reads as a
    /// point on the line rather than a gap in it.
    public static let currentMarkDiameter: CGFloat = 6

    public static let currentMarkRing: CGFloat = 1.5

    public static let rangeBarSpacing: CGFloat = 6

    /// Below this the bar says nothing a person can read and is not drawn — the row keeps its
    /// temperatures, which are the information. A narrow island loses the picture, not the numbers.
    public static let minimumRangeBarWidth: CGFloat = 40

    /// The whole surface's height, and it is the same for every reading.
    public static var contentHeight: CGFloat {
        topPadding
            + headerHeight + headerSpacing
            + currentHeight + currentSpacing
            + metricsHeight + metricsSpacing
            + forecastExtent
            + bottomPadding
    }

    /// Air between the sentence that says there is no forecast and the button that fixes it.
    ///
    /// Inside the space the readings and the forecast would have occupied, which is why it is a
    /// number here and not a guess in the view: `contentHeight` is a constant (see the note at the
    /// top of this type), so the empty state has the whole surface to lay out in and must not ask
    /// for a point more than the state it replaced.
    public static let setupSpacing: CGFloat = 10

    /// The empty state's one control. `IslandHomeLayout.accessButtonHeight` read rather than
    /// repeated: the empty day's "Open Settings" and this one are the same capsule on two pages of
    /// one island, and a button that changed height between them would read as two controls. A
    /// second 20 beside it is how the two would drift.
    public static let setupButtonHeight: CGFloat = IslandHomeLayout.accessButtonHeight

    /// What the forecast rows take together, drawn or not.
    public static var forecastExtent: CGFloat {
        CGFloat(forecastRows) * forecastRowHeight + CGFloat(forecastRows - 1) * forecastRowSpacing
    }

    /// The width left for the range bar, given the island's drawable width.
    ///
    /// Nil when there is not enough of it to be worth drawing, which is `eventColumnWidth`'s rule on
    /// the month surface and is here for the same reason: a bar squeezed to twelve points is not a
    /// smaller picture, it is a mark that means nothing.
    public static func rangeBarWidth(inBodyWidth width: CGFloat) -> CGFloat? {
        let available = width
            - 2 * horizontalPadding
            - dayColumnWidth
            - daySymbolWidth
            - chanceColumnWidth
            - 2 * temperatureColumnWidth
            - 2 * rangeBarSpacing
        return available >= minimumRangeBarWidth ? available : nil
    }
}

/// Where one day's range sits inside the week's.
///
/// A pure function, and separate from the view for the reason `GlanceSchedulePlan` is: this is the only
/// arithmetic on the surface that can be *wrong* rather than merely ugly, and a test can ask it
/// about a week with no spread in it, a week with one day in it, and a week where every day is the
/// same temperature — none of which a person is going to produce on demand by looking at a screen.
///
/// Fractions rather than points, so the view multiplies by whatever width it was given and the
/// arithmetic does not have to know how wide the island is.
public enum WeatherRangeBar {

    /// The start and the length of one day's segment, each 0…1.
    ///
    /// - Parameters:
    ///   - low: the day's low, in whatever unit the caller is drawing — the answer is a ratio, so
    ///     Celsius and Fahrenheit give the same bar. That is not a coincidence worth relying on and
    ///     it is not relied on: the view converts once, up front, and passes one unit throughout.
    ///   - coldest: the lowest low across the days on screen.
    ///   - warmest: the highest high across the days on screen.
    public static func segment(
        low: Double,
        high: Double,
        coldest: Double,
        warmest: Double
    ) -> (start: Double, length: Double) {
        // A week with no spread — five identical days, or one day on its own — has no meaningful
        // ratio to take, and dividing by that zero would make every bar `nan` and every bar's width
        // `nan`, which SwiftUI draws as nothing at all. A full bar is the honest picture: every day
        // covers the whole of a range that is one value wide.
        let span = warmest - coldest
        guard span > 0 else { return (0, 1) }
        let orderedLow = min(low, high)
        let orderedHigh = max(low, high)
        let start = (orderedLow - coldest) / span
        let end = (orderedHigh - coldest) / span
        let clampedStart = min(max(start, 0), 1)
        let clampedEnd = min(max(end, 0), 1)
        // A day whose low and high are the same still gets a visible mark rather than a zero-width
        // one — a flat day is a fact about the weather, and a bar that vanished would read as
        // missing data.
        let length = max(clampedEnd - clampedStart, 0.04)
        return (clampedStart, min(length, 1 - clampedStart))
    }

    /// Where the current temperature sits on today's bar, 0…1 — kept inside today's own segment.
    ///
    /// Clamped to the segment rather than to the bar because the two can disagree: the current
    /// reading and the daily forecast are separate answers from the service, and an afternoon that
    /// has run a degree past the forecast high would otherwise put the mark on bare track, off the
    /// day it belongs to.
    public static func currentPosition(
        _ current: Double,
        within segment: (start: Double, length: Double),
        coldest: Double,
        warmest: Double
    ) -> Double {
        let span = warmest - coldest
        let raw = span > 0 ? (current - coldest) / span : 0.5
        let lower = segment.start
        let upper = segment.start + segment.length
        guard raw.isFinite else { return lower + segment.length / 2 }
        return min(max(raw, lower), upper)
    }

    /// The coldest low and the warmest high across the days on screen, or nil for no days.
    ///
    /// Taken across what is *drawn* rather than across what was fetched, so the bars answer the
    /// question the reader is actually asking — how these five days compare with each other.
    public static func bounds(of days: [WeatherDay], unit: TemperatureUnit) -> (coldest: Double, warmest: Double)? {
        guard !days.isEmpty else { return nil }
        let lows = days.map { Double(WeatherFormat.rounded($0.lowCelsius, unit: unit)) }
        let highs = days.map { Double(WeatherFormat.rounded($0.highCelsius, unit: unit)) }
        guard let coldest = lows.min(), let warmest = highs.max() else { return nil }
        return (coldest, warmest)
    }
}

/// The color a temperature is drawn in, on the forecast's range bars.
///
/// **A fixed scale of absolute temperatures, not the week's own spread.** Weather.app draws a
/// tropical week in yellows and oranges and a January one in blues, and that is the information the
/// color carries that the bar's position cannot: position says how a day compares with the rest of
/// *this* week, color says what the week is like at all. A scale stretched to the week would paint
/// every week blue-to-red and say nothing.
///
/// Stops are in Celsius, whatever the reader's unit, because the scale is a fact about the weather
/// and not about the numbers printed beside it; the bar's ends are converted back to Celsius before
/// they are looked up. Colors are sRGB components rather than `Color` so a nonisolated test can
/// read them — the reason `WeatherFormat` is an `enum`.
public enum WeatherTemperatureScale {

    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public struct Stop: Equatable, Sendable {
        public let celsius: Double
        public let color: RGB
    }

    /// Cold to hot, coldest first. Matched by eye against Weather.app on macOS 27 with a week of
    /// 23–31 °C on screen (yellow into orange), and placed so that a mild day is green and a
    /// freezing one is blue — every stop is bright enough for 11pt white type to sit beside it.
    public static let stops: [Stop] = [
        Stop(celsius: -15, color: RGB(0.55, 0.45, 0.98)),
        Stop(celsius: 0, color: RGB(0.29, 0.62, 0.99)),
        Stop(celsius: 9, color: RGB(0.33, 0.82, 0.86)),
        Stop(celsius: 16, color: RGB(0.55, 0.85, 0.38)),
        Stop(celsius: 22, color: RGB(0.99, 0.78, 0.22)),
        Stop(celsius: 30, color: RGB(0.97, 0.52, 0.16)),
        Stop(celsius: 37, color: RGB(0.93, 0.29, 0.21)),
    ]

    /// The color at one temperature: interpolated between the two stops either side, and the end
    /// stop's own color past either end of the scale.
    public static func color(atCelsius celsius: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return RGB(1, 1, 1) }
        guard celsius.isFinite else { return first.color }
        if celsius <= first.celsius { return first.color }
        if celsius >= last.celsius { return last.color }
        for (lower, upper) in zip(stops, stops.dropFirst()) where celsius <= upper.celsius {
            let t = (celsius - lower.celsius) / (upper.celsius - lower.celsius)
            return RGB(
                lower.color.red + (upper.color.red - lower.color.red) * t,
                lower.color.green + (upper.color.green - lower.color.green) * t,
                lower.color.blue + (upper.color.blue - lower.color.blue) * t
            )
        }
        return last.color
    }

    /// The gradient across one bar whose ends are `coldest` and `warmest` °C, as locations 0…1.
    ///
    /// The ends are looked up exactly and every scale stop strictly between them is carried at its
    /// own location, so a bar spanning a stop bends where the scale does rather than drawing a
    /// straight line between two colors that skips the green in the middle. Locations always rise
    /// and always lie in 0…1 — what `Gradient` requires of them — and a bar with no spread is one
    /// color drawn twice.
    public static func gradient(coldest: Double, warmest: Double) -> [(location: Double, color: RGB)] {
        let low = min(coldest, warmest)
        let high = max(coldest, warmest)
        guard high > low else {
            let color = color(atCelsius: low)
            return [(0, color), (1, color)]
        }
        var result: [(location: Double, color: RGB)] = [(0, color(atCelsius: low))]
        for stop in stops where stop.celsius > low && stop.celsius < high {
            result.append(((stop.celsius - low) / (high - low), stop.color))
        }
        result.append((1, color(atCelsius: high)))
        return result
    }

    /// A temperature drawn in `unit`, back in Celsius — for the bar's ends, which are taken in the
    /// unit the rows are printed in.
    public static func celsius(_ value: Double, from unit: TemperatureUnit) -> Double {
        switch unit {
        case .celsius: value
        case .fahrenheit: (value - 32) * 5 / 9
        }
    }
}
