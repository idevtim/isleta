import Foundation
import Testing

@testable import IslandActivities

@Suite("Weather formatting")
struct WeatherFormatTests {

    @Test("rounding is half away from zero, not truncation")
    func rounding() {
        // `Int(3.7)` is 3, and a thermometer that reads a degree low all afternoon is the kind of
        // wrongness nobody reports and everybody notices.
        #expect(WeatherFormat.rounded(3.7, unit: .celsius) == 4)
        #expect(WeatherFormat.rounded(-0.6, unit: .celsius) == -1)
    }

    @Test("Fahrenheit is a conversion, not a second stored value")
    func fahrenheit() {
        #expect(WeatherFormat.rounded(0, unit: .fahrenheit) == 32)
        #expect(WeatherFormat.rounded(100, unit: .fahrenheit) == 212)
    }

    @Test("the compact form drops the unit letter and the full form keeps it")
    func compactAndFull() {
        #expect(WeatherFormat.compact(4, unit: .celsius) == "4°")
        #expect(WeatherFormat.full(4, unit: .celsius) == "4°C")
        #expect(WeatherFormat.full(4, unit: .fahrenheit) == "39°F")
    }

    @Test("a missing daily forecast draws no range rather than an empty one")
    func rangeIsOptional() {
        #expect(WeatherFormat.range(high: nil, low: 1, unit: .celsius) == nil)
        #expect(WeatherFormat.range(high: 8, low: 1, unit: .celsius) != nil)
    }

    @Test("humidity is clamped, because a fraction from a service is not always one")
    func humidityClamped() {
        #expect(WeatherFormat.humidity(0.625) == "63%")
        #expect(WeatherFormat.humidity(1.0000001) == "100%")
        #expect(WeatherFormat.humidity(nil) == nil)
    }

    @Test("a percentage is clamped and whole, whatever the service answered")
    func percentages() {
        #expect(WeatherFormat.percentage(0.4) == "40%")
        #expect(WeatherFormat.percentage(0.625) == "63%")
        // A forecast that comes back a shade over one must not draw "104%", which would look
        // broken in a way nobody would think to test for.
        #expect(WeatherFormat.percentage(1.04) == "100%")
        #expect(WeatherFormat.percentage(-0.2) == "0%")
        #expect(WeatherFormat.percentage(nil) == nil)
    }

    @Test("wind follows the measurement system, not the temperature preference")
    func windUnits() {
        // The two agree for almost everybody and they are not the same question: a user reading
        // Celsius on a US Mac has said something about temperatures and nothing about distances.
        let metric = WeatherFormat.wind(16, locale: Locale(identifier: "de_DE"))
        let imperial = WeatherFormat.wind(16, locale: Locale(identifier: "en_US"))
        #expect(metric?.contains("16") == true)
        #expect(imperial?.contains("10") == true)
        #expect(WeatherFormat.wind(nil) == nil)
    }

    @Test("a reading with nothing behind it does not earn a surface of its own")
    func detailGatesTheSurface() {
        // The chip is worth drawing for a temperature alone; a page is not. See
        // `GlanceModel.canOpenWeather`, which is what makes the chip stop being a button.
        let bare = WeatherReading(temperatureCelsius: 4, conditionDescription: "Clear", symbolName: "sun.max.fill")
        #expect(!bare.hasDetail)

        let withHumidity = WeatherReading(
            temperatureCelsius: 4, humidity: 0.7,
            conditionDescription: "Clear", symbolName: "sun.max.fill"
        )
        #expect(withHumidity.hasDetail)

        let withForecast = WeatherReading(
            temperatureCelsius: 4, conditionDescription: "Clear", symbolName: "sun.max.fill",
            days: [
                WeatherDay(
                    date: Date(), highCelsius: 8, lowCelsius: 1, precipitationChance: 0.2,
                    symbolName: "sun.max.fill", conditionDescription: "Clear"
                )
            ]
        )
        #expect(withForecast.hasDetail)
    }

    @Test("a day of the forecast is identified by its date, not by a fresh identity per fetch")
    func forecastDayIdentity() {
        // A fresh identity every refresh would make `ForEach` tear down and rebuild every row to
        // redraw the one that changed.
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let first = WeatherDay(
            date: day, highCelsius: 8, lowCelsius: 1, precipitationChance: 0.2,
            symbolName: "sun.max.fill", conditionDescription: "Clear"
        )
        let refetched = WeatherDay(
            date: day, highCelsius: 9, lowCelsius: 1, precipitationChance: 0.3,
            symbolName: "cloud.fill", conditionDescription: "Cloudy"
        )
        #expect(first.id == refetched.id)
        #expect(first != refetched)
    }

    @Test("the default unit follows the Mac's own region")
    func unitFromLocale() {
        // A setting whose default is wrong for a third of users is a setting everybody has to visit.
        #expect(TemperatureUnit.fromLocale(Locale(identifier: "en_US")) == .fahrenheit)
        #expect(TemperatureUnit.fromLocale(Locale(identifier: "en_GB")) == .celsius)
    }
}
