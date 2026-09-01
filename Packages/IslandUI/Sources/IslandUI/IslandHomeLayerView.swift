import IslandActivities
import IslandKit
import SwiftUI

/// The home page: what is playing on the left, the day on the right.
///
/// A sibling of `ActivityLayerView` rather than a slot inside it, for the reason `GlanceLayerView`
/// is one: the four slots belong to *an activity*, and a page belongs to the island. The flanks keep
/// drawing throughout, which is what lets the collapsed island go on saying what is playing while
/// this is the page behind it.
///
/// ## Coordinates
///
/// The panel is a fixed rectangle far larger than the island (§4.2), so everything is offset by
/// `IslandLayout.bodyOrigin` and then again by the cutout's height — the notch is a **hole**, not a
/// dark rectangle, and there are no pixels to draw on above that line. Read from `contentMetrics`
/// and never from `metrics`: the content lags the container by `Motion.contentFollowDelay` (§6.2),
/// so laying out against the container's target would put the columns where the island is *going*
/// to be.
///
/// ## Motion
///
/// There is none of its own, and that is deliberate rather than an omission. The island arriving,
/// resizing and turning a page are all transactions this view is drawn inside, and it inherits them.
/// §6.1 forbids an inline `.animation(...)` anywhere in this codebase, and a second curve here would
/// be the page animating separately from the island it is in.
struct IslandHomeLayerView: View {

    let model: IslandScreenModel

    let glance: GlanceModel

    /// The player, or nil on a build with no Now Playing source at all — which is §3's layering
    /// test: this package must draw with nothing injected.
    let nowPlaying: NowPlayingController?

    /// What the player has to say, or nil when nothing is playing. Separate from `nowPlaying`
    /// because the two are independently absent: a running source with a silent Mac has a controller
    /// and no content, and that is exactly the state the placeholder is for.
    let content: ActivityContent?

    let now: Date

    /// Which transport control the pointer is on, or nil.
    ///
    /// Held here rather than per button so the wash can crossfade *between* two controls as one
    /// animation, and so a crossing that arrives out of order cannot blank the neighbour that has
    /// already claimed it. `NowPlayingTransportView` holds its own for the same two reasons — this
    /// row is the same control and lights up on the same terms.
    @State private var hovered: NowPlayingControlCommand?

    var body: some View {
        GeometryReader { proxy in
            // The width and nothing else, so a page turn's live interpolation of the island's
            // *height* does not re-lay-out the whole day on every sample of the drag. See
            // `IslandScreenModel.contentBodyWidth`.
            let bodyWidth = model.contentBodyWidth
            let origin = IslandLayout.bodyOrigin(bodyWidth: bodyWidth, in: proxy.size)

            HStack(alignment: .top, spacing: IslandHomeLayout.dividerSpacing) {
                musicColumn
                    .frame(width: IslandHomeLayout.musicColumnWidth(bodyWidth: bodyWidth), alignment: .leading)

                // A rule rather than a gap: the two halves are different subjects, and at this width
                // a gap wide enough to read as a separation is width taken off the event titles.
                // Full height of the content box, so it does not stop short of the taller column.
                //
                // **0.07, down from 0.16 on hardware, 2026-08-28.** A rule on `#000000` has no
                // material under it to knock it back, so the alpha that reads as a hairline in a
                // window reads as a white line here — and a line the eye stops on is doing more
                // than separating two columns. What it has to do is be *felt* rather than read: at
                // 0.07 the columns still resolve as two things and nothing in the page competes
                // with the date or the cover. Increase Contrast keeps its own value, which is the
                // whole point of that setting — the rule is structure, and somebody who has asked
                // for structure to be visible gets it.
                Rectangle()
                    .fill(.white.opacity(model.increaseContrast ? 0.45 : 0.07))
                    .frame(width: IslandHomeLayout.dividerWidth)
                    .frame(maxHeight: .infinity)

                calendarColumn
                    .frame(width: IslandHomeLayout.calendarColumnWidth(bodyWidth: bodyWidth), alignment: .leading)
            }
            .padding(.horizontal, IslandHomeLayout.horizontalPadding)
            .padding(.top, IslandHomeLayout.topPadding)
            .frame(
                width: bodyWidth,
                // **This page's own height, not the box the island currently is.** See
                // `IslandPageHeight`: the shape table is swapped in one frame when a turn commits,
                // so a page reading the box reflows to its replacement's height as it slides away.
                // It is the same function that sized the island, so the two agree at rest.
                height: IslandPageHeight.layoutHeight(
                    for: .home, glance: glance, cutoutHeight: model.cutoutSize.height,
                    hasAudioFormat: audioBadge != nil
                ),
                alignment: .topLeading
            )
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    // MARK: - What is playing

    /// The cover, two lines about the track, and three transport buttons.
    ///
    /// Deliberately **not** `NowPlayingSlotView`'s expanded body at a smaller size. That view is the
    /// music page — artwork, a scrubber with both times, shuffle, repeat, favorite and Up Next — and
    /// squeezing it into 40% of the body would be nine controls at a size nobody can hit. This is
    /// the reminder and the three buttons somebody actually reaches for without leaving their day.
    private var musicColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **The cover and the words are one button, and the transport below is not.**
            //
            // Clicking the song here does what clicking it in the player does: brings Music forward
            // *at that track* rather than at whatever it was last showing — see
            // `NowPlayingBridge.onOpenPlayer`. It did nothing at all until 2026-08-28, which made
            // this the one place in the island where the artwork was inert while the identical
            // artwork one swipe away was not.
            //
            // A `Button`, which is also why it does not close the island: `IslandHitTestView`
            // toggles the island for any click that reaches it, and `hitTest` returns the deepest
            // subview that wants the point — so a press here reaches SwiftUI and never reaches that
            // handler. The transport row runs on the same mechanism and says so at more length.
            Button {
                nowPlaying?.openPlayer()
            } label: {
                songLabel
            }
            .buttonStyle(.plain)
            // The label is two layer-backed marquees and a cover; VoiceOver reaches none of them as
            // text, so the button says what it is and what it does.
            .accessibilityLabel(openSongAccessibilityLabel)

            transportRow

            Spacer(minLength: 0)
        }
    }

    /// The cover, the two lines, and the badge — everything the song click covers.
    private var songLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingArtworkView(
                image: nowPlaying?.artwork,
                fallbackSymbol: "music.note",
                side: IslandHomeLayout.artworkSide,
                tint: accent,
                increaseContrast: model.increaseContrast,
                // Only ever *known* paused, never `!isPlaying` — the scripting route cannot report
                // transport state, and a cover permanently dimmed on it would be the island claiming
                // something it does not know. `NowPlayingArtworkView.isPaused` says the same.
                isPaused: NowPlayingSlotView.coverIsPaused(
                    isTransportAvailable: nowPlaying?.isTransportAvailable ?? false,
                    isPlaying: nowPlaying?.isPlaying ?? false
                ),
                reduceMotion: model.reduceMotion
            )
            .padding(.bottom, IslandHomeLayout.artworkSpacing)

            // **`MarqueeText`, the same view the player's own title block uses**, and not a `Text`
            // with `.truncationMode(.tail)`.
            //
            // This column is 127pt wide, which is a third of the player's row — so a title that
            // merely fits there is cut here, and the ellipsis was landing inside the first word of
            // most tracks. Truncation is the right answer when a line is *slightly* too long and the
            // wrong one when it is half the line; and it is exactly the case scrolling exists for.
            //
            // It is CoreAnimation rather than a SwiftUI `TimelineView`, which is §9's rule about
            // continuous animation: the render server is handed the whole loop once and the main
            // thread never hears about it again. Reduce Motion clips and fades instead of
            // travelling, inside the view — see `MarqueeText`.
            VStack(alignment: .leading, spacing: IslandHomeLayout.titleBlockSpacing) {
                if let title = content?.title {
                    MarqueeText(
                        text: title,
                        // Heavier than the artist by a clear margin, as the player's block is — the
                        // title is what the glance is for. See `IslandHomeLayout.titleFontSize` for
                        // why these are no longer a point under the player's: the width problem this
                        // column has is answered by the scrolling, not by the type size.
                        font: .systemFont(
                            ofSize: IslandHomeLayout.titleFontSize, weight: .semibold
                        ),
                        color: NowPlayingSlotView.lineColor(opacity: 1),
                        reduceMotion: model.reduceMotion,
                        // Left, against the cover above it. The track lip centres for its own
                        // reason; a centred title here would be the one thing in the column not
                        // lining up with the rest.
                        alignment: .leading
                    )
                    .frame(height: IslandHomeLayout.titleLineHeight)
                } else {
                    // The placeholder does not scroll: it is two words that fit, and a line that
                    // travelled would say the island was doing something when the Mac is quiet.
                    Text(islandText("home.notPlaying", "Not playing"))
                        .font(.system(size: IslandHomeLayout.titleFontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(height: IslandHomeLayout.titleLineHeight, alignment: .leading)
                }

                // The artist line keeps its height whether or not it has words in it, so the
                // transport row sits at the same y on every track. A row that moved up when a track
                // had no artist would be a button that shifts under the pointer aiming at it.
                if let subtitle = content?.subtitle {
                    MarqueeText(
                        text: subtitle,
                        font: .systemFont(
                            ofSize: IslandHomeLayout.artistFontSize, weight: .regular
                        ),
                        color: NowPlayingSlotView.lineColor(
                            opacity: model.increaseContrast ? 0.85 : 0.6
                        ),
                        reduceMotion: model.reduceMotion,
                        alignment: .leading
                    )
                    .frame(height: IslandHomeLayout.artistLineHeight)
                } else {
                    Color.clear
                        .frame(height: IslandHomeLayout.artistLineHeight)
                }

                // **Apple's badge, on a row of its own under the artist.** It shared the artist's
                // row for one revision, which kept the column's height constant but cost the artist
                // 60 of its 127 points — a name with almost nowhere to scroll.
                //
                // The row is *counted* rather than reserved: no badge, no row, no gap. That is what
                // makes `musicColumnHeight` take a parameter, and it is the same rule the open
                // player follows — a gap held open for an absent thing is worse than the movement
                // it prevents.
                if let badge = audioBadge {
                    Image(nsImage: badge)
                        .renderingMode(.template)
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.6))
                        .frame(height: IslandHomeLayout.formatLineHeight, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, IslandHomeLayout.formatLineSpacing)
                }
            }
            .padding(.bottom, IslandHomeLayout.transportSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What a click on the song does, for somebody who cannot see that it is a cover.
    ///
    /// The player's own header says the same thing in the same words — `NowPlayingSlotView`'s
    /// `openPlayerAccessibilityLabel` — because it is the same action on the same track, and two
    /// surfaces describing one gesture differently is the inconsistency a screen-reader user
    /// notices first.
    private var openSongAccessibilityLabel: String {
        guard let title = content?.title else {
            return islandText("nowPlaying.a11y.openPlayer", "Open the player")
        }
        guard let artist = content?.subtitle else {
            return islandText("nowPlaying.a11y.openTrack", "Open \(title) in the player")
        }
        return islandText(
            "nowPlaying.a11y.openTrackByArtist",
            "Open \(title) by \(artist) in the player"
        )
    }

    /// Previous, play/pause, next.
    ///
    /// ## Why these are `Button`s
    ///
    /// `IslandHitTestView.mouseDown` opens the island for any click that reaches it — but `hitTest`
    /// returns the deepest subview that wants the point, so a press landing on a SwiftUI `Button`
    /// reaches SwiftUI and never reaches that handler. That is the same mechanism the player's own
    /// transport runs on, and `NowPlayingTransportView` documents why it works on a panel that is
    /// never key: a button is driven by a press gesture over its own hit region, which needs neither
    /// key status nor first responder. `.buttonStyle(.plain)` is required rather than cosmetic — the
    /// default macOS style draws a bezel, and a bezel on pure `#000000` is a gray rectangle.
    private var transportRow: some View {
        HStack(spacing: IslandHomeLayout.transportButtonSpacing) {
            transportButton(
                "backward.fill",
                command: .previousTrack,
                size: IslandHomeLayout.transportGlyphSize,
                enabled: canSkip
            )
            transportButton(
                (nowPlaying?.isPlaying ?? false) ? "pause.fill" : "play.fill",
                command: .togglePlayPause,
                size: IslandHomeLayout.playGlyphSize,
                enabled: isTransportAvailable
            )
            transportButton(
                "forward.fill",
                command: .nextTrack,
                size: IslandHomeLayout.transportGlyphSize,
                enabled: canSkip
            )
        }
        .frame(height: IslandHomeLayout.transportRowHeight)
        // **Centred in the column**, where the cover and the words above it are ranged left. The
        // three buttons are a control *set* rather than another line of the block, and a set hard
        // against the leading edge reads as having been left there rather than placed — most
        // obviously against the cover, which is square and 8pt narrower than the row.
        .frame(maxWidth: .infinity, alignment: .center)
        // The wash fades rather than snapping, on the token every content change in the island
        // travels on (§6.1) — keyed on `hovered` so the pointer moving between two controls is one
        // crossfade, and so nothing else in the column is animated by it. The player's own row
        // does exactly this.
        .animation(Motion.contentSwap, value: hovered)
    }

    private func transportButton(
        _ symbol: String,
        command: NowPlayingControlCommand,
        size: CGFloat,
        enabled: Bool
    ) -> some View {
        Button {
            nowPlaying?.onCommand?(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
                // A 15pt glyph is a ~17pt target. The frame is what makes it 36, and
                // `.contentShape` is what makes the whole frame grabbable rather than only the
                // glyph's own coverage — without it the gaps inside a "backward.fill" chevron are
                // holes the press falls through.
                .frame(
                    width: IslandHomeLayout.transportButtonSize.width,
                    height: IslandHomeLayout.transportButtonSize.height
                )
                // Behind the glyph and inside the frame, so the wash is exactly the press target.
                .background(hoverWash(isOn: enabled && hovered == command))
                .contentShape(Rectangle())
                // A sibling that answers no hit test, so the press it reports about still reaches
                // the button. Reported whether or not the control is enabled: a disabled one draws
                // no wash, but the pointer resting on `next` while a track loads must find it
                // already lit at the instant the player says it can skip.
                .background(PointerPresence { isOver in
                    if isOver {
                        hovered = command
                    } else if hovered == command {
                        // Only ever clears *this* control. A blind `nil` would blank the wash the
                        // neighbour has already claimed when two crossings arrive out of order.
                        hovered = nil
                    }
                })
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label(for: command))
    }

    /// What the control under the pointer is drawn on.
    ///
    /// **One view whose opacity animates, not a view that comes and goes.** A wash inserted and
    /// removed is a transition, and a transition at pointer speed is SwiftUI tearing down and
    /// rebuilding a view on every crossing; this is one rounded rectangle per button that is
    /// transparent when it is not wanted. `NowPlayingTransportView.hoverWash` is the same view for
    /// the same reasons, at the same weight — this is the same control, so it lights the same way.
    private func hoverWash(isOn: Bool) -> some View {
        RoundedRectangle(
            cornerRadius: IslandHomeLayout.transportHoverCornerRadius,
            style: .continuous
        )
        .fill(.white.opacity(isOn ? (model.increaseContrast ? 0.26 : 0.13) : 0))
    }

    private func label(for command: NowPlayingControlCommand) -> String {
        switch command {
        case .previousTrack: islandText("home.previous.a11y", "Previous track")
        case .nextTrack: islandText("home.next.a11y", "Next track")
        default:
            (nowPlaying?.isPlaying ?? false)
                ? islandText("home.pause.a11y", "Pause")
                : islandText("home.play.a11y", "Play")
        }
    }

    private var isTransportAvailable: Bool { nowPlaying?.isTransportAvailable ?? false }

    private var canSkip: Bool { isTransportAvailable && (nowPlaying?.canSkip ?? false) }

    /// Apple's badge for the playing track, or nil — which is also the answer to "does the column
    /// have a badge row", so the drawing and the height are one question asked once.
    private var audioBadge: NSImage? {
        nowPlaying?.audioFormat.flatMap { AudioFormatBadge.image(for: $0.kind) }
    }

    /// The cover's own accent, or the palette's where there is no cover to take one from.
    ///
    /// Computed once per track change in `NowPlayingController.setArtwork`, never on a frame — see
    /// `AlbumColor`, which is where the rule and the measurement are.
    private var accent: Color {
        ActivityPalette.color(for: content?.tint ?? .neutral, increaseContrast: model.increaseContrast)
    }

    // MARK: - The day

    /// The date, then the day's events as pills.
    ///
    /// The date is a **button**, and it is the way into the month grid — the same affordance the
    /// glance's own header carries, in the same place, so the gesture survives the swipe between
    /// them. The date *is* what the month is about: a person looking for "what does this month look
    /// like" reaches for the day they are reading, and a second glyph beside it would be a second
    /// control for one idea.
    private var calendarColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Button {
                glance.onOpenSchedule?()
            } label: {
                VStack(alignment: .trailing, spacing: IslandHomeLayout.dateBlockSpacing) {
                    Text(GlanceFormat.weekday(now).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(weekdayTint)
                        .frame(height: IslandHomeLayout.weekdayHeight, alignment: .bottomTrailing)

                    Text(GlanceFormat.dayOfMonth(now))
                        .font(.system(size: 34, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(height: IslandHomeLayout.dateHeight, alignment: .topTrailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(islandText("home.date.a11y", "Show today and tomorrow"))

            if !glance.rows.isEmpty {
                VStack(alignment: .trailing, spacing: IslandHomeLayout.eventSpacing) {
                    ForEach(glance.rows) { event in
                        eventPill(event)
                    }
                }
                .padding(.top, IslandHomeLayout.dateSpacing)
            }

            if !glance.snapshot.access.isReadable {
                accessNotice
            }

            if overflowCount > 0 {
                Text(islandText("home.moreEvents", "\(overflowCount) more"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 0.85 : 0.55))
                    .lineLimit(1)
                    .frame(height: IslandHomeLayout.overflowHeight, alignment: .trailing)
                    .padding(.top, IslandHomeLayout.overflowSpacing)
            }

            Spacer(minLength: 0)
        }
    }

    /// Why the column under the date is empty, when the reason is not "nothing on today".
    ///
    /// **A day with no events and a calendar Isleta was refused are byte-identical from EventKit**,
    /// and the column has to say which one this is — an empty column under a date reads as a clear
    /// afternoon, and shipping that to somebody who refused the prompt is the app pretending to
    /// work. `CalendarAccess` is the only discriminator; the sentence comes from it and never from
    /// `rows.isEmpty`. `GlanceLayerView.emptyState` makes the same argument for the glance, and the
    /// two share the copy so the swipe between them does not change the story.
    ///
    /// **Which control appears is the whole reason there are two closures**, and §10 is why: macOS
    /// raises the permission dialog exactly once, so an "Allow…" button after a refusal is a control
    /// that visibly does nothing. Before the prompt, the prompt; after it, the trip to System
    /// Settings, which is the only thing left that changes anything. A managed Mac gets neither and
    /// is told so, because there is no switch in that pane the user owns.
    private var accessNotice: some View {
        VStack(alignment: .trailing, spacing: IslandHomeLayout.accessButtonSpacing) {
            Text(glance.snapshot.access.emptyStateMessage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.6))
                .multilineTextAlignment(.trailing)
                .lineLimit(IslandHomeLayout.accessMessageLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    height: IslandHomeLayout.accessMessageHeight,
                    alignment: .topTrailing
                )

            if glance.snapshot.access == .notDetermined, let ask = glance.onRequestCalendarAccess {
                accessButton(islandText("home.allow", "Allow…"), action: ask)
                    .accessibilityLabel(islandText("glance.allow.a11y", "Allow calendar access"))
            } else if glance.snapshot.access.canBeGrantedInSettings,
                      let open = glance.onOpenCalendarSettings {
                accessButton(islandText("home.openSettings", "Open Settings"), action: open)
                    .accessibilityLabel(
                        islandText(
                            "home.openSettings.a11y",
                            "Open Calendar privacy settings"
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, IslandHomeLayout.dateSpacing)
    }

    /// The notice's one control.
    ///
    /// A SwiftUI `Button`, which is also why clicking it does not close the island —
    /// `IslandHitTestView.mouseDown` toggles the island for any click that reaches it, and `hitTest`
    /// returns the deepest subview that wants the point. The transport row above runs on the same
    /// mechanism and says so at more length.
    private func accessButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: IslandHomeLayout.accessButtonHeight)
                .contentShape(Rectangle())
                .background(
                    Capsule().fill(.white.opacity(model.increaseContrast ? 0.28 : 0.14))
                )
        }
        .buttonStyle(.plain)
    }

    /// One event, as the pill `GlanceEventPill` draws — shared with the schedule surface this
    /// column's date opens, because a row that changed shape across one swipe would read as a
    /// different list.
    private func eventPill(_ event: GlanceEvent) -> some View {
        Button {
            glance.onOpenEvent?(event)
        } label: {
            GlanceEventPill(event: event, increaseContrast: model.increaseContrast)
        }
        .buttonStyle(.plain)
        // The pill already reads its own time and title; what a click *does* is the part the label
        // does not say, and VoiceOver announces a button's action nowhere else.
        .accessibilityHint(islandText("home.openEvent.a11y", "Opens the event in Calendar"))
    }

    /// How many events the day has that the column has no room for.
    ///
    /// Asked of the *snapshot* rather than of `rows`, which is already capped — the whole point of
    /// the line is to say what the cap hid.
    private var overflowCount: Int {
        max(0, glance.snapshot.events.count - glance.rows.count)
    }

    /// The weekday, in the accent the date block reads against.
    ///
    /// **System red, which is the Mac's own mark for today.** It was white at 55% on the argument
    /// that a label beside a 34pt numeral must not read as a second value — true, and answered
    /// better by hue than by dimness. Calendar, the menu bar's date, and every calendar icon on the
    /// machine put today in red, so a person reads it before they have read the word; a grey label
    /// spent the same three characters saying nothing they did not already know.
    ///
    /// **Spelled in sRGB rather than taken from `NSColor.systemRed`.** §6.3's rule for this island:
    /// a dynamic system colour resolves against the *view's* appearance, and the panel's is not
    /// guaranteed to be the dark one — a light resolution would hand back the darker red, which on
    /// pure black is the one variant that cannot be read. These are the components macOS itself
    /// uses for `systemRed` in dark appearance.
    ///
    /// White under Increase Contrast, like every other tint on this surface: the hue is a
    /// convention rather than information the words do not already carry.
    private var weekdayTint: Color {
        model.increaseContrast
            ? .white
            : Color(.sRGB, red: 1.0, green: 0.271, blue: 0.227, opacity: 1)
    }
}
