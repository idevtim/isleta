import Foundation

/// One weather reading, in the units it was measured in.
///
/// **Celsius throughout, converted at the edge.** The user's Fahrenheit preference is a fact about
/// how they read a number, not about the number — storing whichever unit they happen to prefer would
/// mean a value whose meaning changes when they open Settings, and a cached reading that is silently
/// wrong by 32 until the next refresh. `WeatherFormat` is the one place the conversion happens.
public struct WeatherReading: Equatable, Sendable {

    public let temperatureCelsius: Double

    /// Today's range. Nil where the daily forecast could not be fetched but the current conditions
    /// could — which is a real state, not a defensive one: they are two calls into WeatherKit.
    public let highCelsius: Double?

    public let lowCelsius: Double?

    /// 0…1.
    public let humidity: Double?

    /// Apple's own words for the condition — "Mostly Cloudy". Displayed, never logged: it is not the
    /// user's content, but it is a fact about where they are.
    public let conditionDescription: String

    /// The SF Symbol WeatherKit itself names for the condition. Taken from the service rather than
    /// mapped here, because Apple's mapping already knows about day and night variants and a table
    /// of our own would be a second answer that drifts every time they add a condition.
    public let symbolName: String

    /// What to call the place on screen. Nil where only coordinates were available.
    public let placeName: String?

    /// When the reading was taken, so the glance can say "as of" rather than implying it is live.
    public let readAt: Date

    // MARK: - What the weather surface adds
    //
    // **Appended, never inserted.** Every field below arrived after 2.0.0 for the weather surface,
    // and a stored property inserted into the middle of a struct that four packages read is the
    // cross-package memory-layout trap CLAUDE.md documents — dependent packages keep the old layout
    // and read every field at the wrong offset, with no compile error. All of them are optional or
    // empty by default for the same reason: a provider that cannot answer them (the stub in a test
    // bundle, `UnavailableWeatherProvider`, a `--glance-demo` reading) stays a legal `WeatherReading`
    // rather than becoming a compile error in five files.

    /// What it feels like, which is the number a person dresses for. Nil where the service did not
    /// say.
    public let apparentTemperatureCelsius: Double?

    /// Today's chance of precipitation, 0…1. **Not "it is raining"** — `symbolName` already answers
    /// that, and `Precipitation.matching` draws it. This is the forecast's own probability, which is
    /// the one number a person opens a weather page to read.
    public let precipitationChance: Double?

    /// Wind speed in km/h, converted at the edge for the reason the temperature is: the unit a
    /// person reads it in is a fact about them, not about the air.
    public let windSpeedKPH: Double?

    /// The forecast, today first.
    ///
    /// Empty rather than nil, because "no days" and "a provider that has none" are the same state on
    /// screen and an optional array would give two spellings of it. Comes free with the reading —
    /// `WeatherService.weather(for:)` returns the daily forecast in the same call as the current
    /// conditions, so the page costs no second request against the pooled quota.
    public let days: [WeatherDay]

    public init(
        temperatureCelsius: Double,
        highCelsius: Double? = nil,
        lowCelsius: Double? = nil,
        humidity: Double? = nil,
        conditionDescription: String,
        symbolName: String,
        placeName: String? = nil,
        readAt: Date = Date(),
        apparentTemperatureCelsius: Double? = nil,
        precipitationChance: Double? = nil,
        windSpeedKPH: Double? = nil,
        days: [WeatherDay] = []
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.humidity = humidity
        self.conditionDescription = conditionDescription
        self.symbolName = symbolName
        self.placeName = placeName
        self.readAt = readAt
        self.apparentTemperatureCelsius = apparentTemperatureCelsius
        self.precipitationChance = precipitationChance
        self.windSpeedKPH = windSpeedKPH
        self.days = days
    }

    /// Whether there is enough here to be worth a surface of its own.
    ///
    /// The chip on the glance is worth drawing for a temperature alone; a page is not. A reading
    /// with no forecast and no detail behind it would open onto one number in a large rectangle,
    /// which reads as a surface that failed to load rather than as a weather page — so the chip is
    /// not a button in that state, and `GlanceModel.canOpenWeather` asks this.
    public var hasDetail: Bool {
        !days.isEmpty || humidity != nil || precipitationChance != nil || apparentTemperatureCelsius != nil
    }
}

/// The numbers the weather half is bounded by.
///
/// `GlancePolicy`'s counterpart, and here for its reason: a cap that the *provider* applies and the
/// *layout* draws to has to be one number, or the day the two disagree is the day six rows are
/// fetched into an island with room for five and nobody notices which two went missing. IslandSources
/// and IslandUI both depend on this package and neither depends on the other, so this is the only
/// place both can read it from.
public enum WeatherPolicy {

    /// How many days the forecast holds, today included.
    ///
    /// Five, and the ceiling is the island rather than the service — WeatherKit answers with ten.
    /// Past five rows the surface stops reading as the notch having opened onto the weather and
    /// starts reading as a weather app bolted to one, which is the same objection that caps the
    /// glance at three events. It is also what keeps the surface shorter than
    /// `IslandLayout.maxExpandedBodySize.height` on a notched Mac with the switcher row up.
    public static let forecastDays = 5
}

/// One day of the forecast.
///
/// Celsius throughout, like `WeatherReading`, and converted at the edge by `WeatherFormat` — the
/// user's Fahrenheit preference is a fact about how they read a number, not about the number.
///
/// `Identifiable` on the date rather than on a `UUID`: the same day fetched twice is the same row,
/// and a fresh identity every refresh would make `ForEach` tear down and rebuild seven rows to
/// redraw the two that changed.
public struct WeatherDay: Equatable, Sendable, Identifiable {

    /// The start of the day, in the forecast's own calendar.
    public let date: Date

    public let highCelsius: Double

    public let lowCelsius: Double

    /// 0…1. The reason this type exists — a week of temperatures is available from the chip's
    /// high and low, and a week of *probabilities* is not.
    public let precipitationChance: Double

    /// The SF Symbol WeatherKit itself names for the day, day and night variants included. Taken
    /// from the service rather than mapped here, for `WeatherReading.symbolName`'s reason.
    public let symbolName: String

    /// Apple's own localized words for the condition. Displayed and read aloud, never logged.
    public let conditionDescription: String

    public var id: Date { date }

    public init(
        date: Date,
        highCelsius: Double,
        lowCelsius: Double,
        precipitationChance: Double,
        symbolName: String,
        conditionDescription: String
    ) {
        self.date = date
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.precipitationChance = precipitationChance
        self.symbolName = symbolName
        self.conditionDescription = conditionDescription
    }
}

/// Which units the user reads temperatures in.
public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {

    case celsius
    case fahrenheit

    /// The unit symbol. Localized, and the same string in every language Isleta speaks so far —
    /// `°C` and `°F` are SI/derived symbols rather than words, and Apple writes them identically in
    /// German, French and Simplified Chinese. The key exists because the *spacing* around them is
    /// not universal, and a language that needs a different symbol has somewhere to put it.
    public var suffix: String {
        switch self {
        case .celsius: activityText("weather.unit.celsius", "°C")
        case .fahrenheit: activityText("weather.unit.fahrenheit", "°F")
        }
    }

    /// What this Mac's region already implies, for the default.
    ///
    /// Read from `Locale` rather than defaulting to Celsius, because a setting whose default is
    /// wrong for a third of users is a setting everybody has to visit. `Locale.measurementSystem`
    /// answers `.us` for exactly the region that uses Fahrenheit.
    public static func fromLocale(_ locale: Locale = .current) -> Self {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

/// Temperatures as the island draws them.
///
/// A plain `enum` and not a `static func` on a view: `View` conformance is main-actor isolated, so a
/// formatter declared on one is too, and the first nonisolated test to call it is an **error** under
/// `Tools/check.sh`'s `-warnings-as-errors`. CLAUDE.md records that trap; `RecentsFormat` is the
/// other type that exists for it.
public enum WeatherFormat {

    /// "4°" — the degree sign, no unit letter, no decimal.
    ///
    /// The unit letter is dropped on purpose: the island's flank is 40pt wide, a person knows which
    /// units their own Mac is set to, and "4°C" costs a glyph to say something nobody was asking.
    /// The open island's card carries the letter, where there is room for it to be reassuring.
    public static func compact(_ celsius: Double, unit: TemperatureUnit) -> String {
        activityText("weather.temperature.compact", "\(rounded(celsius, unit: unit))°")
    }

    /// "4°C".
    ///
    /// The unit is an argument rather than part of the format, so a language whose typography puts a
    /// space between the number and the symbol — French does — can say so once, here, without every
    /// unit having to carry its own leading space.
    public static func full(_ celsius: Double, unit: TemperatureUnit) -> String {
        activityText("weather.temperature.full", "\(rounded(celsius, unit: unit))\(unit.suffix)")
    }

    /// "H:8° L:1°", or nil when the daily forecast is missing.
    ///
    /// **"H" and "L" are English abbreviations for high and low**, not symbols, and they are
    /// translated: Apple's own German Weather says `H:`/`T:` (Tief), its French says `Max`/`Min`,
    /// and its Simplified Chinese says 最高/最低. This is one row of the glance's weather card, on
    /// the `.lineLimit(1)` budget — see `README.md` for where that is tight.
    public static func range(high: Double?, low: Double?, unit: TemperatureUnit) -> String? {
        guard let high, let low else { return nil }
        return activityText(
            "weather.temperature.range",
            "H:\(rounded(high, unit: unit))°  L:\(rounded(low, unit: unit))°"
        )
    }

    /// Rounded **half away from zero**, not truncated. `Int(3.7)` is 3, and a thermometer that reads
    /// a degree low all afternoon is the kind of wrongness nobody reports and everybody notices.
    public static func rounded(_ celsius: Double, unit: TemperatureUnit) -> Int {
        let value = switch unit {
        case .celsius: celsius
        case .fahrenheit: celsius * 9 / 5 + 32
        }
        return Int(value.rounded())
    }

    /// "62%", or nil.
    public static func humidity(_ fraction: Double?) -> String? {
        percentage(fraction)
    }

    /// A 0…1 fraction as a whole percentage — "40%" — or nil.
    ///
    /// Clamped rather than trusted. A probability is a number from a service, and a page that drew
    /// "104%" because a forecast came back slightly over one would look broken in a way nobody would
    /// think to test for.
    ///
    /// One key for every percentage on the weather surface: humidity, the chance of rain, and the
    /// chance on each day of the week are the same typography, and a language that puts a space
    /// before the sign — French does — says so once here rather than in four places.
    public static func percentage(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        return activityText("weather.percentage", "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
    }

    /// "12 km/h", or "7 mph" on a Mac whose region uses miles. Nil where the service did not say.
    ///
    /// **The measurement system rather than `TemperatureUnit`.** They agree for almost everybody and
    /// they are not the same question: a user who reads Celsius on a US Mac has said something about
    /// temperatures and nothing about distances, and reading a wind speed off their degree
    /// preference would answer the wrong one. `Measurement.formatted` supplies the unit's own
    /// localized abbreviation, which is why there is no string key here.
    public static func wind(_ kilometresPerHour: Double?, locale: Locale = .current) -> String? {
        guard let kilometresPerHour else { return nil }
        let usesMiles = locale.measurementSystem == .us || locale.measurementSystem == .uk
        let speed = Measurement(value: kilometresPerHour, unit: UnitSpeed.kilometersPerHour)
        let converted = usesMiles ? speed.converted(to: .milesPerHour) : speed
        return Measurement(value: converted.value.rounded(), unit: converted.unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }
}
