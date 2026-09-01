import IslandActivities
import IslandKit
import SwiftUI

/// The day, drawn in the open island's body in place of the activity's own content.
///
/// Two surfaces, one view, because they are two views of one thing:
///
/// - **`.glance`** — the day header with the weather beside it, and up to three events under it.
/// - **`.meeting`** — one event and a Join button, which is the same information at the one moment
///   it is an instruction rather than a report.
///
/// Both draw here for the same reason the shelf does: the glance activity publishes an **empty**
/// `expanded` slot, `ActivitySlotLayout.bodySlot` returns nil for one, and `ActivityLayerView`
/// therefore draws nothing in the body. There is no overlap to arbitrate and no z-order to get
/// right. The flanks keep drawing throughout — a track playing beside the calendar is exactly the
/// pair `ActivityStack` exists to form.
///
/// ## Coordinates
///
/// The panel is a fixed rectangle far larger than the island (§4.2), so everything is offset by
/// `IslandLayout.bodyOrigin` and then again by the cutout's height — the notch is a **hole**, not a
/// dark rectangle, and there are no pixels to draw on above that line. Read from `contentMetrics`
/// and never from `metrics`: the content lags the container by `Motion.contentFollowDelay` (§6.2),
/// so laying out against the container's target would put the rows where the island is *going* to be.
///
/// ## Motion
///
/// There is none of its own, and that is deliberate rather than an omission. The island arriving and
/// resizing is `Motion.expand`, opened by `IslandScreenModel.setActivity`; this view is inside that
/// transaction and inherits it. §6.1 forbids an inline `.animation(...)` anywhere in this codebase,
/// and a second curve here would be the surface animating separately from the island it is in.
struct GlanceLayerView: View {

    let model: IslandScreenModel

    let glance: GlanceModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Weather that is *happening*, behind what the glance says — and measured against the
            // island's own body rather than against this content's box, for the reason written on
            // that type: the bottom of the rectangle it is handed **is** the ground.
            GlancePrecipitationLayer(
                model: model,
                glance: glance,
                // The island's own box. This surface is the meeting, which is never a page and
                // never dragged, so there is nothing here for the shape to be interpolating.
                groundBelowCutout: model.contentMetrics.bodySize.height - model.cutoutSize.height
            )

            GeometryReader { proxy in
                let metrics = model.contentMetrics
                let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)

                Group {
                    if model.presentedKind == .meeting, let event = glance.joinableMeeting {
                        meeting(event)
                    } else {
                        day
                    }
                }
                .padding(.horizontal, GlanceLayout.horizontalPadding)
                .frame(
                    width: metrics.bodySize.width,
                    // The room actually left, asked of the box rather than recomputed from the
                    // layout. The two agree — `GlanceLayout.contentHeight` is what sized the island
                    // — right up until they do not, and the way that fails on screen is a row
                    // sliced in half by the island's own bottom edge while every test still passes.
                    height: max(0, model.contentBodySize.height - model.cutoutSize.height),
                    alignment: .topLeading
                )
                .padding(.top, GlanceLayout.topPadding)
                .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
        }
    }

    // MARK: - The day

    private var day: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, GlanceLayout.headerSpacing)

            if glance.rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: GlanceLayout.rowSpacing) {
                    ForEach(glance.rows) { event in
                        row(event)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "Today" on the left, the weather on the right.
    ///
    /// One strip rather than a weather card of its own: a separate card would push the third event
    /// out of the island's height ceiling to say two things that fit here with room to spare, and it
    /// would make the weather look like the point of a surface whose point is the calendar.
    /// The day on the left — and it is a **button**, which is the way into today and tomorrow.
    ///
    /// The date is the affordance rather than a separate calendar icon beside it, because the date
    /// *is* what the surface behind it is about: a person looking for "what else is on" reaches for
    /// the day they are reading, and a second glyph next to it would be a second control for one
    /// idea. It carries the chevron every disclosing control on macOS carries, so it does not
    /// have to be discovered by clicking things to see which move.
    ///
    /// Wrapped in a `Button` and not a tap gesture: a gesture would swallow the press without
    /// reaching `IslandHitTestView.mouseDown`, and the island would sit open under a click that
    /// appeared to be ignored — which is the failure `--transport-test` was written to catch on the
    /// artwork.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                glance.onOpenSchedule?()
            } label: {
                HStack(spacing: 3) {
                    Text(GlanceFormat.day(glance.snapshot.asOf, relativeTo: glance.snapshot.asOf))
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .opacity(model.increaseContrast ? 1 : 0.7)
                }
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.55))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(glance.onOpenSchedule == nil)
            .accessibilityLabel(islandText("glance.schedule.open.a11y", "Show today and tomorrow"))

            Spacer(minLength: 4)

            if let weather = glance.snapshot.weather {
                weatherChip(weather)
            }
        }
        .frame(height: GlanceLayout.headerHeight)
    }

    /// The glyph WeatherKit itself named, and a temperature — and the way into the weather.
    ///
    /// The symbol comes from the service rather than from a table here, because Apple's mapping
    /// already knows about day and night variants and a table of our own would drift every time they
    /// add a condition. The place name is the accessibility label and not the visible text: on a
    /// 368pt island "London" would cost the third event's title, and read aloud the temperature on
    /// its own says nothing about where.
    ///
    /// # Clicking it opens the weather page
    ///
    /// The chip is the affordance rather than a separate glyph beside it, for the reason the date is
    /// the way into today and tomorrow: the reading *is* what the page is about, and a second control next to
    /// it would be two controls for one idea. It carries no chevron where the date does — the date
    /// is a word and needs the mark to read as a control, and a chip is already a shape a Mac user
    /// clicks.
    ///
    /// A `Button` and not a tap gesture, which is also **why the click does not close the island**:
    /// `IslandHitTestView.mouseDown` toggles the island for any click that reaches it, and `hitTest`
    /// returns the deepest subview that wants the point — so a press here reaches SwiftUI and never
    /// reaches that handler. A gesture would swallow the press without reaching either, and the
    /// island would sit open under a click that appeared to be ignored.
    ///
    /// Not a button when there is nothing behind it: see `GlanceModel.canOpenWeather`. The chip
    /// still draws, because a temperature is worth reading on its own.
    @ViewBuilder
    private func weatherChip(_ weather: WeatherReading) -> some View {
        if glance.canOpenWeather {
            Button {
                glance.onOpenWeather?()
            } label: {
                weatherChipLabel(weather)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlanceButtonStyle())
            .accessibilityLabel(spokenWeather(weather))
            .accessibilityHint(islandText("glance.weather.open.a11y", "Show the weather"))
        } else {
            weatherChipLabel(weather)
                .accessibilityLabel(spokenWeather(weather))
        }
    }

    private func weatherChipLabel(_ weather: WeatherReading) -> some View {
        HStack(spacing: 5) {
            Image(systemName: weather.symbolName)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text(WeatherFormat.compact(weather.temperatureCelsius, unit: glance.temperatureUnit))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
        .accessibilityElement(children: .ignore)
    }

    private func spokenWeather(_ weather: WeatherReading) -> String {
        let temperature = WeatherFormat.full(weather.temperatureCelsius, unit: glance.temperatureUnit)
        guard let place = weather.placeName else {
            return islandText(
                "glance.weather.a11y",
                "\(weather.conditionDescription), \(temperature)"
            )
        }
        return islandText(
            "glance.weather.a11y.place",
            "\(weather.conditionDescription) in \(place), \(temperature)"
        )
    }

    /// One event: when, whose calendar, what — and a Join button on the one row that has a link and
    /// is close enough to use it.
    private func row(_ event: GlanceEvent) -> some View {
        HStack(spacing: 0) {
            // Fixed width, so every title starts at the same x. A time column sized to its contents
            // gives three rows a ragged left edge, which reads as a layout fault rather than as
            // typography.
            Text(GlanceFormat.rowTime(event))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.62))
                .frame(width: GlanceLayout.timeColumnWidth, alignment: .leading)
                .padding(.trailing, GlanceLayout.timeSpacing)

            Circle()
                .fill(
                    event.calendarTint?.color(increaseContrast: model.increaseContrast)
                        ?? .white.opacity(model.increaseContrast ? 1 : 0.5)
                )
                .frame(width: GlanceLayout.dotSide, height: GlanceLayout.dotSide)
                .padding(.trailing, GlanceLayout.dotSpacing)
                // The dot is an index into a week the user already knows, and it reads aloud as
                // nothing. The calendar's name is in the row's spoken label instead.
                .accessibilityHidden(true)

            Text(event.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if let meeting = event.meeting, event.id == glance.joinableMeeting?.id {
                joinButton(meeting, height: GlanceLayout.joinButtonHeight, wide: false)
            }
        }
        .frame(height: GlanceLayout.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(event))
    }

    private func spoken(_ event: GlanceEvent) -> String {
        [GlanceFormat.rowTime(event), event.title, event.calendarTitle]
            .filter { !$0.isEmpty }
            .joined(separator: islandText("list.separator", ", "))
    }

    /// Nothing to show — and **which** nothing decides the words.
    ///
    /// A refused calendar and a genuinely free afternoon return byte-identical results from every
    /// EventKit call there is; `CalendarAccess` is the only discriminator, so the sentence comes from
    /// it. Showing "Nothing else today" to somebody who has refused access is an app pretending to
    /// work, and showing "Grant access in Settings" to somebody with a clear day is an app nagging.
    ///
    /// The button appears only in the one state where a prompt would actually show. §10: a "Grant
    /// Access" button after a refusal is a control that visibly does nothing, because macOS will not
    /// raise the dialog twice.
    private var emptyState: some View {
        HStack(spacing: 10) {
            Text(glance.snapshot.access.emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if glance.snapshot.access == .notDetermined, let ask = glance.onRequestCalendarAccess {
                accessButton(islandText("glance.allow", "Allow…"), action: ask)
                    .accessibilityLabel(islandText("glance.allow.a11y", "Allow calendar access"))
            } else if glance.snapshot.access.canBeGrantedInSettings,
                      let open = glance.onOpenCalendarSettings {
                accessButton(islandText("home.openSettings", "Open Settings"), action: open)
                    .accessibilityLabel(
                        islandText("home.openSettings.a11y", "Open Calendar privacy settings")
                    )
            }
        }
        .frame(height: GlanceLayout.rowHeight, alignment: .center)
    }

    /// The empty state's one control, whichever of the two it is.
    private func accessButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: GlanceLayout.joinButtonHeight)
                .contentShape(Rectangle())
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - The meeting

    /// One joinable meeting: what it is, when, and the button that is the entire reason this island
    /// opened itself.
    private func meeting(_ event: GlanceEvent) -> some View {
        VStack(alignment: .leading, spacing: GlanceLayout.meetingSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(GlanceFormat.startsIn(event.start, from: glance.snapshot.asOf))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.6))
                    .lineLimit(1)
            }
            .frame(height: GlanceLayout.meetingTitleHeight, alignment: .center)

            if let link = event.meeting {
                joinButton(link, height: GlanceLayout.meetingButtonHeight, wide: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one control on this surface.
    ///
    /// A SwiftUI `Button`, which is also **why a click on it does not close the island**:
    /// `IslandHitTestView.mouseDown` toggles the island for any click that reaches it, and
    /// `hitTest` returns the deepest subview that wants the point — so a press here reaches SwiftUI
    /// and never reaches that handler. The transport controls and the switcher chips run on the same
    /// mechanism.
    private func joinButton(_ link: MeetingLink, height: CGFloat, wide: Bool) -> some View {
        Button { glance.onJoin?(link) } label: {
            HStack(spacing: 5) {
                Image(systemName: link.provider.symbol)
                    .font(.system(size: wide ? 12 : 10, weight: .semibold))
                Text(wide ? link.joinTitle : islandText("glance.join", "Join"))
                    .font(.system(size: wide ? 13 : 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, wide ? 14 : 10)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: GlanceLayout.joinButtonCornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: GlanceLayout.joinButtonCornerRadius, style: .continuous)
                    // Brighter than the island's other chrome, because this is the one control on
                    // the island that the user is being asked to press rather than offered.
                    .fill(.white.opacity(model.increaseContrast ? 0.34 : 0.18))
            )
        }
        .buttonStyle(GlanceButtonStyle())
        .accessibilityLabel(link.joinTitle)
    }
}

/// A button that dims while pressed and draws no chrome of its own.
///
/// `.plain` alone leaves no press feedback at all, on a control whose effect happens in another
/// application — the user clicks, the island closes, and a browser opens a second later. Without the
/// dip there is nothing on screen to say the click landed.
struct GlanceButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
