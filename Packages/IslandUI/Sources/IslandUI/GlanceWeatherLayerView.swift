import IslandActivities
import IslandKit
import SwiftUI

/// The weather behind the chip: what it is doing now, and what it is going to do.
///
/// Reached by clicking the weather chip on the glance — or on the month, where the same chip is the
/// same affordance — or by swiping to it, and left the way any page is: by turning to another one
/// or by closing the island. Drawn in place of the glance's own body, the way the month and the
/// drop history are drawn in place of theirs, so the island keeps its flanks and goes on saying
/// what it was saying.
///
/// # What this is not
///
/// **Not a weather app.** There is no map, no radar, no hourly strip and no ten-day list. It answers
/// the two questions a chip cannot: *what does that temperature actually feel like*, and *is it going
/// to rain* — the first as a row of readings, the second as a percentage against each of the next
/// few days. Anything past that is what Weather.app is for, and it is one click away.
///
/// **Not a second request.** Everything drawn here arrived in the same `weather(for:)` the chip's
/// temperature came from — see `WeatherKitProvider.reading(at:)` — so opening this costs nothing
/// against WeatherKit's pooled quota and nothing on the network. It is a second *view* of one
/// reading, which is also why it cannot disagree with the chip.
///
/// # Nothing here moves on its own
///
/// No clock, no timer, nothing on the idle path. The surface changes when `WeatherSource` publishes
/// a new reading — at most once every fifteen minutes, and only while a page drawing one is open — and
/// at no other time.
///
/// The one thing that moves is the rain, and it is the same `GlancePrecipitationLayer` the day
/// surface draws — behind the numbers, resolved from the same reading, costing this process nothing
/// per frame. It was left off here at first on the argument that drops crossing a five-row table are
/// decoration in front of information; the owner's call is that the page *about* the weather is the
/// last surface that should be the dry one, and the layer is already suppressed under Reduce Motion,
/// Reduce Transparency and Increase Contrast — which is where a reader who cannot spare the contrast
/// is answered.
struct GlanceWeatherLayerView: View {

    let model: IslandScreenModel

    let glance: GlanceModel

    /// The instant "today" is judged against, so the first row can say "Today" and a test can ask
    /// about any day of any year. Passed in for `GlanceScheduleLayerView.now`'s reason.
    let now: Date

    private var calendar: Calendar { .current }

    private var unit: TemperatureUnit { glance.temperatureUnit }

    private var weather: WeatherReading? { glance.snapshot.weather }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The sky the numbers are describing, behind them. Measured against the island's own
            // body rather than against this content's box — see `GlancePrecipitationLayer` for why
            // the bottom of that rectangle is load-bearing.
            GlancePrecipitationLayer(
                model: model,
                glance: glance,
                // **This page's own settled height**, for `IslandPageHeight`'s reason and for the
                // frame clock's — see `GlancePrecipitationLayer.groundBelowCutout`. The strip is
                // added back because `layoutHeight` does not carry it and the rain does fall behind
                // the dots; `contentShowsPageIndicator` is the question that decides whether that
                // room exists at all.
                groundBelowCutout: IslandPageHeight.layoutHeight(
                    for: .weather, glance: glance, cutoutHeight: model.cutoutSize.height
                ) + (model.contentShowsPageIndicator ? IslandPageIndicatorLayout.height : 0)
            )

            GeometryReader { proxy in
                // The width and nothing else — see `IslandScreenModel.contentBodyWidth`, which
                // is why a page does not read the shape a drag is interpolating.
                let bodyWidth = model.contentBodyWidth
                let origin = IslandLayout.bodyOrigin(bodyWidth: bodyWidth, in: proxy.size)

                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, GlanceWeatherLayout.headerSpacing)

                    if let weather {
                        current(weather)
                            .padding(.bottom, GlanceWeatherLayout.currentSpacing)
                        readings(weather)
                            .padding(.bottom, GlanceWeatherLayout.metricsSpacing)
                        forecast(weather)
                    } else {
                        // The reading went away while the surface was up — a refresh that failed
                        // publishes nil rather than leaving an hour-old temperature on screen with
                        // nothing to say it is old. The rectangle stays exactly the size it was,
                        // because the island has already been sized for it and cannot shrink under
                        // the pointer.
                        unavailable
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, GlanceWeatherLayout.horizontalPadding)
                .frame(width: bodyWidth, alignment: .topLeading)
                .padding(.top, GlanceWeatherLayout.topPadding)
                .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Header

    /// Where, and when it was read.
    ///
    /// **No ✕.** There was one, from when the weather was a drill-down from the day that had to be
    /// closed back to it. It is a page now — one of the three the island turns between — and a page
    /// is left by turning to another one or by closing the island, exactly as home and music are.
    /// A dismiss on one page of three and not the other two is a control whose meaning depends on
    /// where you are standing, and it dropped the reader onto home whether or not that is where
    /// they came from.
    ///
    /// The place name is the title here where it is only an accessibility label on the chip, and the
    /// difference is room: on a 368pt island beside three event titles "London" costs a line of
    /// somebody's afternoon, and on a surface that is *about* the weather it is the first thing a
    /// reader needs — a forecast for an unnamed place is a forecast for nowhere.
    private var header: some View {
        HStack(spacing: 8) {
            Text(placeTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            if let readAt = weather?.readAt {
                // "as of 14:20", never "now". The reading is up to fifteen minutes old by design —
                // see `WeatherSource.refreshInterval` — and a surface that implied it was live would
                // be lying about the one thing a person checks a weather page to be sure of.
                Text(islandText("glance.weather.asOf", "as of \(readAtText(readAt))"))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .frame(height: GlanceWeatherLayout.headerHeight)
    }

    private var placeTitle: String {
        weather?.placeName ?? islandText("glance.weather.title", "Weather")
    }

    private func readAtText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = .current
        return date.formatted(style)
    }

    // MARK: - Now

    /// The glyph, the temperature, and what to make of it.
    ///
    /// The number is drawn at 34pt against 11pt everywhere else on the island, which is the largest
    /// type in this application by some distance. That is the point: this surface exists because the
    /// chip's 12pt temperature is a *label*, and a page that answered with the same size type in
    /// more space would not have answered anything.
    private func current(_ weather: WeatherReading) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: weather.symbolName)
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34)

            Text(WeatherFormat.compact(weather.temperatureCelsius, unit: unit))
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 1) {
                Text(weather.conditionDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let range = WeatherFormat.range(
                    high: weather.highCelsius, low: weather.lowCelsius, unit: unit
                ) {
                    Text(range)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: GlanceWeatherLayout.currentHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCurrent(weather))
    }

    private func spokenCurrent(_ weather: WeatherReading) -> String {
        let temperature = WeatherFormat.full(weather.temperatureCelsius, unit: unit)
        return "\(weather.conditionDescription), \(temperature)"
    }

    // MARK: - The readings

    /// Four readings, in fixed positions.
    ///
    /// A reading the service did not answer draws an em dash rather than disappearing, and the row
    /// is a fixed four columns rather than a stack of whatever came back. Both are the same
    /// decision: the *positions* are what make this readable at a glance on the second visit, and a
    /// row whose contents shuffled depending on what a particular forecast happened to include would
    /// have to be read from scratch every time.
    private func readings(_ weather: WeatherReading) -> some View {
        HStack(spacing: 0) {
            reading(
                islandText("glance.weather.metric.rain", "Rain"),
                WeatherFormat.percentage(weather.precipitationChance)
            )
            reading(
                islandText("glance.weather.metric.humidity", "Humidity"),
                WeatherFormat.percentage(weather.humidity)
            )
            reading(
                islandText("glance.weather.metric.feelsLike", "Feels like"),
                weather.apparentTemperatureCelsius.map { WeatherFormat.compact($0, unit: unit) }
            )
            reading(
                islandText("glance.weather.metric.wind", "Wind"),
                WeatherFormat.wind(weather.windSpeedKPH)
            )
        }
        .frame(height: GlanceWeatherLayout.metricsHeight)
    }

    private func reading(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.45))
                .lineLimit(1)
                // Translated labels are the ones that blow up — "Feels like" is "Sensación térmica"
                // in Spanish — and this column is a quarter of a 336pt island. Shrinking beats
                // truncating for a two-word caption whose second word carries the meaning.
                .minimumScaleFactor(0.7)
            Text(value ?? islandText("glance.weather.metric.unknown", "—"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The days

    /// The forecast: a day, a glyph, a chance of rain, and where its range sits inside the week's.
    ///
    /// **Always `GlanceWeatherLayout.forecastRows` rows**, padded with empty ones when the service
    /// answered with fewer. The island's height was agreed before the transition and cannot follow a
    /// row count — see that type's note — so a short forecast leaves air rather than a surface that
    /// is a different size from the one the shape settled on.
    private func forecast(_ weather: WeatherReading) -> some View {
        let days = Array(weather.days.prefix(GlanceWeatherLayout.forecastRows))
        let bounds = WeatherRangeBar.bounds(of: days, unit: unit)
        return VStack(spacing: GlanceWeatherLayout.forecastRowSpacing) {
            ForEach(0..<GlanceWeatherLayout.forecastRows, id: \.self) { index in
                if index < days.count, let bounds {
                    forecastRow(days[index], bounds: bounds)
                } else {
                    Color.clear
                        .frame(height: GlanceWeatherLayout.forecastRowHeight)
                }
            }
        }
    }

    private func forecastRow(_ day: WeatherDay, bounds: (coldest: Double, warmest: Double)) -> some View {
        let low = Double(WeatherFormat.rounded(day.lowCelsius, unit: unit))
        let high = Double(WeatherFormat.rounded(day.highCelsius, unit: unit))
        let segment = WeatherRangeBar.segment(
            low: low, high: high, coldest: bounds.coldest, warmest: bounds.warmest
        )
        return HStack(spacing: 0) {
            Text(dayName(day.date))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
                .lineLimit(1)
                .frame(width: GlanceWeatherLayout.dayColumnWidth, alignment: .leading)

            Image(systemName: day.symbolName)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: GlanceWeatherLayout.daySymbolWidth, alignment: .center)

            // The percentage the surface is here for. Drawn only where there is one worth reading —
            // a column of "0%" down five dry days is five rows spent saying nothing, and the blank
            // is unambiguous beside a sun.
            Text(chanceText(day.precipitationChance) ?? "")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.6))
                .lineLimit(1)
                .frame(width: GlanceWeatherLayout.chanceColumnWidth, alignment: .trailing)

            Text(WeatherFormat.compact(day.lowCelsius, unit: unit))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.55))
                .lineLimit(1)
                .frame(width: GlanceWeatherLayout.temperatureColumnWidth, alignment: .trailing)
                .padding(.leading, GlanceWeatherLayout.rangeBarSpacing)

            if let barWidth = GlanceWeatherLayout.rangeBarWidth(inBodyWidth: model.contentBodySize.width) {
                rangeBar(segment: segment, width: barWidth)
                    .padding(.horizontal, GlanceWeatherLayout.rangeBarSpacing)
            }

            Text(WeatherFormat.compact(day.highCelsius, unit: unit))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: GlanceWeatherLayout.temperatureColumnWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(height: GlanceWeatherLayout.forecastRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDay(day))
    }

    /// The day's range as a segment of the week's.
    ///
    /// Two capsules and no gradient. A gradient from blue to orange is what every weather app draws
    /// here and it carries no information the numbers either side do not — and under Increase
    /// Contrast it would have to be thrown away entirely, which is the test that says it was
    /// decoration. The *position* is the information, and it survives every accessibility setting.
    private func rangeBar(segment: (start: Double, length: Double), width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(model.increaseContrast ? 0.35 : 0.15))
                .frame(width: width, height: GlanceWeatherLayout.rangeBarHeight)
            Capsule()
                .fill(.white.opacity(model.increaseContrast ? 1 : 0.75))
                .frame(width: max(2, width * segment.length), height: GlanceWeatherLayout.rangeBarHeight)
                .offset(x: width * segment.start)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// "Today", then the abbreviated weekday. The first row is named rather than dated because that
    /// is the row a reader checks first and "Today" is the answer they are checking against.
    private func dayName(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return islandText("glance.weather.today", "Today") }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.locale = .current
        return date.formatted(style)
    }

    /// A chance worth printing, or nil.
    ///
    /// Under a tenth is drawn as nothing at all rather than as "4%". A forecast's own precision does
    /// not reach a single point of probability, and a number that specific invites a reader to act on
    /// it.
    private func chanceText(_ chance: Double) -> String? {
        guard chance >= 0.1 else { return nil }
        return WeatherFormat.percentage(chance)
    }

    private func spokenDay(_ day: WeatherDay) -> String {
        var parts = [dayName(day.date), day.conditionDescription]
        if let chance = chanceText(day.precipitationChance) {
            parts.append(islandText("glance.weather.day.chance.a11y", "\(chance) chance of precipitation"))
        }
        if let range = WeatherFormat.range(high: day.highCelsius, low: day.lowCelsius, unit: unit) {
            parts.append(range)
        }
        return parts.joined(separator: islandText("list.separator", ", "))
    }

    // MARK: - Nothing to show

    /// Why there is no forecast, and — where there is one — what the reader can do about it.
    ///
    /// **Two states, and they are not the same sentence with a button added.** A refresh that failed
    /// is a fault, and there is nothing on this surface a person can do about it; a place that was
    /// never set is a *setting*, and the whole of the fix is one window away. Telling the second
    /// group the weather "isn’t available" is the app reporting a fault where it has an unanswered
    /// question — and it is where every new install starts, since `GlanceSettings` defaults to no
    /// location and no city. `GlanceModel.weatherNeedsPlace` is the discriminator, and it is false
    /// wherever Settings would not actually change anything.
    ///
    /// The same argument the empty day makes between "Allow…" and "Open Settings", and the button
    /// is the same button: `IslandHomeLayerView.accessButton`’s capsule, drawn again here rather
    /// than shared, exactly as the schedule and the glance draw their own.
    ///
    /// One sentence either way, and the surface keeps its full height around it. Shrinking to fit
    /// would resize the island as a *consequence of a refresh failing* — the island moving under the
    /// pointer to report that nothing happened.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: GlanceWeatherLayout.setupSpacing) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.55))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Isleta’s own settings, not System Settings’ privacy pane: the thing that is missing is
            // a place, and a place is asked for in the Glance pane whether or not location is ever
            // granted. `onOpenSettings` is nil in a preview and wherever nothing is wired (§3), so
            // the button is absent rather than inert there.
            if glance.weatherNeedsPlace, let open = model.onOpenSettings {
                settingsButton(action: open)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GlanceWeatherLayout.currentHeight
                + GlanceWeatherLayout.currentSpacing
                + GlanceWeatherLayout.metricsHeight
                + GlanceWeatherLayout.metricsSpacing
                + GlanceWeatherLayout.forecastExtent,
            alignment: .topLeading
        )
    }

    private var message: String {
        guard glance.weatherNeedsPlace else {
            return islandText("glance.weather.unavailable", "The weather isn’t available right now.")
        }
        return islandText(
            "glance.weather.noPlace",
            "Isleta doesn’t know where to ask. Pick a place in Settings and the forecast shows up here."
        )
    }

    /// The one control on this surface.
    ///
    /// A SwiftUI `Button`, which is also why clicking it does not close the island first —
    /// `IslandHitTestView.mouseDown` toggles the island for any click that reaches it, and `hitTest`
    /// returns the deepest subview that wants the point. The island still goes, a moment later and
    /// deliberately: `AppDelegate` puts the settings window up and *then* takes the island away, so
    /// nothing flickers between them and no black bar is left over the window the user asked for.
    private func settingsButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(islandText("glance.weather.openSettings", "Open Settings"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: GlanceWeatherLayout.setupButtonHeight)
                .contentShape(Rectangle())
                .background(
                    Capsule().fill(.white.opacity(model.increaseContrast ? 0.28 : 0.14))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            islandText("glance.weather.openSettings.a11y", "Open Isleta settings to pick a place")
        )
    }
}
