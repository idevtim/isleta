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

    /// The bar between the low and the high.
    public static let rangeBarHeight: CGFloat = 3

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
