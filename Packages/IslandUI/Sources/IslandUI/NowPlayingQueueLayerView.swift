import CoreGraphics
import Foundation
import IslandKit
import SwiftUI

/// One entry of the queue, as the island draws it.
///
/// A UI-side value type rather than IslandSources' `NowPlayingQueueItem`, which is the same split
/// `NowPlayingControlCommand` makes against `NowPlayingCommand`: importing the source's type would
/// put IslandSources — and with it a spawned Perl process — inside the package that has to build
/// and preview with nothing granted (§3). It carries the two things a row draws and the two things
/// a double-click needs, and nothing else.
public struct NowPlayingQueueRow: Equatable, Sendable, Identifiable {

    /// The window position, from zero. **Index 0 is the track that is playing** — played entries
    /// are dropped from the queue the player vends, so the discrimination is positional and the
    /// item's own `isCurrentlyPlaying` reads zero on every row including that one.
    public let index: Int

    public let title: String

    public let artist: String?

    public let duration: TimeInterval?

    /// The player's own id, sent beside the offset when the row is played.
    public let contentItemIdentifier: String?

    public var isCurrent: Bool { index == 0 }

    /// Stable across a window that grows, and deliberately **not** the index alone: a `ForEach`
    /// keyed on position re-uses row 3's view for whatever ends up at position 3 after a skip, so
    /// the list appears to keep its rows and change their words.
    public var id: String { contentItemIdentifier ?? "index-\(index)" }

    public init(
        index: Int,
        title: String,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        contentItemIdentifier: String? = nil
    ) {
        self.index = index
        self.title = title
        self.artist = artist
        self.duration = duration
        self.contentItemIdentifier = contentItemIdentifier
    }
}

/// One system audio output device, as the island draws it. The UI-side half of
/// `NowPlayingOutputDevice`, for the reason `NowPlayingQueueRow` is.
public struct NowPlayingOutputDeviceRow: Equatable, Sendable, Identifiable {

    public let id: UInt32
    public let name: String
    public let isSelected: Bool

    /// Chosen in IslandSources from the device's CoreAudio transport type, because that is where
    /// the transport type is known. IslandUI is handed a symbol name and asks no questions — the
    /// alternative is this package learning a CoreAudio vocabulary to draw a glyph.
    public let symbolName: String

    public init(id: UInt32, name: String, isSelected: Bool, symbolName: String) {
        self.id = id
        self.name = name
        self.isSelected = isSelected
        self.symbolName = symbolName
    }
}

/// Which half of the Up Next surface is showing.
///
/// Two tabs rather than two surfaces, because they are the same question asked twice — *what plays
/// next, and where does it come out* — and because two surfaces would be two heights, which is two
/// reasons for the island's outline to move. See `NowPlayingQueueLayout`.
public enum NowPlayingQueueTab: Equatable, Sendable, CaseIterable {
    case upNext
    case output

    var title: String {
        switch self {
        case .upNext: islandText("nowPlaying.upNext", "Up Next")
        case .output: islandText("nowPlaying.queue.output", "Output")
        }
    }
}

/// Where the Up Next list should be sitting, and whether it should travel there.
///
/// A value rather than a bare `CGFloat` for the reason `RecentsScrollTarget` is one: a **drag** has
/// to land un-animated on every sample, because a spring between the fingers and the rows is a list
/// that lags the hand; an **arrival** — a track change re-vending the window from a new current
/// track — has to travel, because the rows the reader was looking at now mean something else.
///
/// `sequence` is what makes a repeat reach the view: two track changes in a row both target zero,
/// and an `onChange` watching the offset alone would play nothing for the second.
public struct NowPlayingQueueScrollTarget: Equatable, Sendable {

    public var offset: CGFloat
    public var isAnimated: Bool
    public var sequence: Int

    public init(offset: CGFloat = 0, isAnimated: Bool = false, sequence: Int = 0) {
        self.offset = offset
        self.isAnimated = isAnimated
        self.sequence = sequence
    }

    public func dragged(to offset: CGFloat) -> Self {
        Self(offset: offset, isAnimated: false, sequence: sequence + 1)
    }

    /// The next target for the window being re-vended around a new current track: the top,
    /// traveling.
    public func revealingCurrent() -> Self {
        Self(offset: 0, isAnimated: true, sequence: sequence + 1)
    }
}

/// The Up Next surface, drawn in the open island's body in place of the player's own.
///
/// ## What it is for, and what it deliberately is not
///
/// It is the queue the *player* vends, which is not the playlist: after a skip a 36-item read comes
/// back with 35 and the new track at index 0, and with shuffle on the order changes completely at
/// the same offsets while `current playlist` does not move. That is exactly the case an Up Next
/// exists for, and it is why the sneak peek two rows above the transport controls and this list are
/// the same data at two scales.
///
/// It is **not** a queue editor. There is no reorder, no remove, no "play next" — MediaRemote vends
/// a window to read and exactly one command to act on it (`PlayItemInPlaybackQueue`), and drawing a
/// drag handle for a rearrangement nothing can perform is the shape of control this codebase
/// refuses everywhere else.
///
/// ## The scroll
///
/// A `ScrollView` with scrolling switched off, driven from our own offset. Not a preference: inside
/// this hosting view a SwiftUI clip does not contain scrolled text, images or buttons —
/// `.clipped()`, `.clipShape(_:)`, `.mask(_:)`, `.compositingGroup()` and `.drawingGroup()` were
/// each measured letting rows draw straight over the header, in nine combinations, while a plain
/// `Rectangle` overflowing the *same* container by the same amount was clipped exactly. A scroll
/// view's clipping is its whole job and is not a request. `scrollDisabled(true)` is load-bearing
/// too: `IslandHitTestView.scrollWheel` never calls `super`, so this view is offered no event
/// anyway, and an enabled one would take the vertical axis inside its own rectangle only — leaving
/// the stow and close gestures reading different samples depending on where the pointer happened to
/// be.
struct NowPlayingQueueLayerView: View {

    let model: IslandScreenModel
    let controller: NowPlayingController

    /// Where the `ScrollView` is parked. Driven from `controller.queueScrollTarget`.
    @State private var scrollPosition = ScrollPosition(y: 0)

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)
            let width = max(0, metrics.bodySize.width - NowPlayingQueueLayout.horizontalPadding * 2)

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, NowPlayingQueueLayout.headerSpacing)

                viewport(
                    width: width,
                    // The room actually left under the header, not the room the layout intends
                    // there to be. Asking the box how big it is cannot be off by one, and the way
                    // this fails is the last row being sliced in half by the
                    // island's own bottom edge while every test still passed.
                    available: NowPlayingQueueLayout.rowsHeight(
                        inContentHeight: max(
                            0, model.contentBodySize.height - model.cutoutSize.height
                        )
                    )
                )
            }
            .padding(.horizontal, NowPlayingQueueLayout.horizontalPadding)
            .frame(
                width: metrics.bodySize.width,
                height: max(0, model.contentBodySize.height - model.cutoutSize.height),
                alignment: .topLeading
            )
            .padding(.top, NowPlayingQueueLayout.topPadding)
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    /// The two tabs, the rate readout, and the way out.
    private var header: some View {
        HStack(spacing: 6) {
            ForEach(NowPlayingQueueTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }

            Spacer(minLength: 4)

            // The rate the player reports, and only when it is not 1×.
            //
            // A readout and not a control. `MRMediaRemoteSetPlaybackSpeed` takes an `int`, so it
            // cannot express 1.5× and what its integers mean is not established — a chip that
            // cycled through them would be changing a setting nobody can predict. What is worth
            // saying is the rate itself: a podcast left at 1.5× has no other indication in the
            // island, and a bar advancing at 1× under it would drift a minute every two.
            if let rate = NowPlayingRateFormat.chip(for: controller.playbackRate) {
                Text(NowPlayingRateFormat.text(rate))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.7))
                    .padding(.horizontal, 7)
                    .frame(height: NowPlayingQueueLayout.headerHeight)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .accessibilityLabel(islandText("nowPlaying.queue.rate.a11y", "Playback speed"))
                    .accessibilityValue(NowPlayingRateFormat.text(rate))
            }

            Button { controller.send(.toggleQueue) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
                    .frame(
                        width: NowPlayingQueueLayout.headerHeight,
                        height: NowPlayingQueueLayout.headerHeight
                    )
                    .contentShape(Rectangle())
                    .background(Circle().fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(islandText("nowPlaying.queue.close", "Close Up Next"))
        }
        .frame(height: NowPlayingQueueLayout.headerHeight)
    }

    /// One tab.
    ///
    /// Output is drawn dimmed and inert where CoreAudio reported no devices — the same discipline
    /// the transport row uses for a capability that is missing from an otherwise working set,
    /// rather than a tab that vanishes and shifts the other one sideways.
    private func tabButton(_ tab: NowPlayingQueueTab) -> some View {
        let enabled = tab == .upNext || controller.hasOutputRouting
        let selected = controller.queueTab == tab
        return Button {
            guard enabled else { return }
            withAnimation(
                Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: model.reduceMotion)
            ) {
                controller.queueTab = tab
            }
        } label: {
            Text(tab.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    .white.opacity({
                        guard enabled else {
                            return ActivityPalette.secondaryOpacity(
                                increaseContrast: model.increaseContrast
                            ) * 0.6
                        }
                        if selected { return 1 }
                        return model.increaseContrast ? 0.9 : 0.55
                    }())
                )
                .padding(.horizontal, 10)
                .frame(height: NowPlayingQueueLayout.headerHeight)
                .contentShape(Rectangle())
                .background(
                    Capsule().fill(.white.opacity(selected ? (model.increaseContrast ? 0.24 : 0.12) : 0))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - The rows

    private var rowCount: Int {
        switch controller.queueTab {
        case .upNext: controller.queue.count
        case .output: controller.outputDevices.count
        }
    }

    private func viewport(width: CGFloat, available: CGFloat) -> some View {
        let extent = NowPlayingQueueLayout.contentExtent(rowCount: rowCount)
        let height = min(available, min(NowPlayingQueueLayout.viewportHeight, extent))
        return ScrollView(.vertical) {
            // `LazyVStack` for the reason the drop history is one: `--hitch-test` measured a plain
            // stack building every row inside the opening spring's first frames, and the cost
            // tracked the row count. Here the window can reach a hundred entries, so the lazy stack
            // is not an optimisation but the difference between a surface that opens and one that
            // stalls for a fifth of a second.
            LazyVStack(alignment: .leading, spacing: NowPlayingQueueLayout.rowSpacing) {
                switch controller.queueTab {
                case .upNext:
                    ForEach(controller.queue) { row in
                        queueRow(row)
                            .frame(width: width, height: NowPlayingQueueLayout.rowHeight)
                    }
                case .output:
                    ForEach(controller.outputDevices) { device in
                        outputRow(device)
                            .frame(width: width, height: NowPlayingQueueLayout.rowHeight)
                    }
                }
            }
            // Stated rather than inferred, which is what a lazy stack cannot do for itself: it can
            // only report the rows it has actually built, so the extent a scroll view jumps against
            // would be an estimate made from a few of them. Every row here is one height, so the
            // extent is known exactly without building any.
            .frame(width: width, height: extent, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .frame(width: width, height: height, alignment: .topLeading)
        .scrollPosition($scrollPosition)
        .onChange(of: controller.queueScrollTarget, initial: true) { _, target in
            guard target.isAnimated,
                  let animation = Motion.respectingReduceMotion(
                    Motion.nudge, reduceMotion: model.reduceMotion
                  ) as Animation?
            else {
                scrollPosition.scrollTo(y: target.offset)
                return
            }
            withAnimation(animation) { scrollPosition.scrollTo(y: target.offset) }
        }
        // Switching tabs puts the reader back at the top of the *other* list. Keeping the offset
        // would open Output scrolled to a position that was about a queue, and on a two-device Mac
        // that is a viewport of nothing.
        .onChange(of: controller.queueTab) { _, _ in
            scrollPosition.scrollTo(y: 0)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let indicator = NowPlayingQueueLayout.indicator(
                offset: controller.queueScrollOffset,
                rowCount: rowCount
            ) {
                Capsule()
                    .fill(.white.opacity(model.increaseContrast ? 0.6 : 0.25))
                    .frame(width: NowPlayingQueueLayout.indicatorWidth, height: indicator.length)
                    .offset(y: indicator.top)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if rowCount == 0 {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.55))
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    /// What an empty list says, and it says which of the two empties it is.
    ///
    /// A radio station and the last track of a playlist both vend nothing, and so does a player
    /// that has just stopped — "Nothing queued" covers all three honestly without claiming a
    /// failure. The Output case cannot be reached today (`hasOutputRouting` disables the tab) and
    /// is written anyway, because a Mac that lost its last output device between the tab being
    /// enabled and the list being drawn is a real frame.
    private var emptyText: String {
        switch controller.queueTab {
        case .upNext: islandText("nowPlaying.queue.empty", "Nothing queued")
        case .output: islandText("nowPlaying.queue.empty.output", "No output devices")
        }
    }

    /// One queue entry.
    ///
    /// **Double-click plays it**, single-click does not — which is the Finder convention and, more
    /// to the point, the only safe one here. A single click on a list of songs is how a person
    /// scrolls their eye down it; making that jump the player would mean every stray click on the
    /// surface changed what the user was listening to.
    ///
    /// The single click still has to be *consumed*. An unconsumed press travels back up the
    /// responder chain to `IslandHitTestView.mouseDown` and collapses the island — so a row that
    /// only listened for double-clicks would close the surface on the first of the two. A `Button`
    /// with an inert action consumes it; the double-click is a high-priority tap on top, which wins
    /// the press before the button's own gesture claims it.
    private func queueRow(_ row: NowPlayingQueueRow) -> some View {
        Button {
            // Deliberately nothing. See above: the press has to be swallowed so it does not close
            // the island, and a single click on a queue row means nothing else.
        } label: {
            queueRowBody(row)
        }
        .buttonStyle(NowPlayingQueueRowButtonStyle(increaseContrast: model.increaseContrast))
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                controller.playQueueItem(at: row.index)
            }
        )
        .accessibilityLabel(NowPlayingQueueFormat.accessibilityLabel(for: row))
        .accessibilityHint(row.isCurrent
                           ? islandText("nowPlaying.queue.row.current", "Now playing")
                           : islandText("nowPlaying.queue.row.hint", "Double-click to play"))
        .padding(.trailing, NowPlayingQueueLayout.indicatorLane)
    }

    private func queueRowBody(_ row: NowPlayingQueueRow) -> some View {
        HStack(spacing: NowPlayingQueueLayout.symbolSpacing) {
            // The playing row gets the equaliser's glyph; every other row gets its position.
            //
            // The number is 1-based and index 0 is skipped, because the reader's "1" is the next
            // song and not the one they are hearing. Drawn from the index and never from the item's
            // own `isCurrentlyPlaying`, which reads zero on every entry including the one that is
            // playing — the discrimination here is positional and nothing else.
            Group {
                if row.isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(row.index)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.45))
                }
            }
            .frame(
                width: NowPlayingQueueLayout.symbolSide,
                height: NowPlayingQueueLayout.symbolSide
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: row.isCurrent ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(row.isCurrent ? 1 : (model.increaseContrast ? 1 : 0.9)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = row.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            if let duration = row.duration, duration > 0 {
                Text(ActivityValueFormatter.clock(seconds: duration))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.45))
            }
        }
        .frame(height: NowPlayingQueueLayout.rowHeight)
    }

    /// One output device. A single click selects it — unlike a queue row, because selecting an
    /// output is reversible in one further click and playing the wrong song is not.
    private func outputRow(_ device: NowPlayingOutputDeviceRow) -> some View {
        Button {
            controller.selectOutputDevice(device.id)
        } label: {
            HStack(spacing: NowPlayingQueueLayout.symbolSpacing) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(device.isSelected ? 1 : 0.75))
                    .frame(
                        width: NowPlayingQueueLayout.symbolSide,
                        height: NowPlayingQueueLayout.symbolSide
                    )

                Text(device.name)
                    .font(.system(size: 12, weight: device.isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if device.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: NowPlayingQueueLayout.rowHeight)
        }
        .buttonStyle(NowPlayingQueueRowButtonStyle(increaseContrast: model.increaseContrast))
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(device.isSelected ? [.isSelected] : [])
        .padding(.trailing, NowPlayingQueueLayout.indicatorLane)
    }
}

/// A row that lights under the pointer and dims while pressed, and draws no button chrome.
///
/// `.plain` alone leaves a row with no press feedback at all, which matters more here than in the
/// drop history: the press that does something is the *second* one, so the first has to acknowledge
/// itself or the user concludes the row is dead and stops.
struct NowPlayingQueueRowButtonStyle: ButtonStyle {

    let increaseContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? (increaseContrast ? 0.24 : 0.12) : 0))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// What VoiceOver reads for a queue row.
///
/// A plain `enum` rather than a `static func` on the view, and that is not tidiness: `View`
/// conformance is main-actor isolated, so a static function declared on one is too, and the first
/// nonisolated test to call it takes the **whole bundle down with a signal** after every other
/// suite has reported passing. CLAUDE.md records the trap.
public enum NowPlayingQueueFormat {

    public static func accessibilityLabel(for row: NowPlayingQueueRow) -> String {
        let position = row.isCurrent
            ? islandText("nowPlaying.queue.row.current", "Now playing")
            : "\(row.index)"
        return [position, row.title, row.artist]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: islandText("list.separator", ", "))
    }
}

/// The playback rate, as the chip draws it.
///
/// Its own `enum` for the reason above, and one rule worth stating: **nil at 1×**, so the chip is
/// absent on the overwhelmingly common path rather than saying "1.0×" over every song. A rate of
/// zero is a paused player and is not a speed at all.
public enum NowPlayingRateFormat {

    /// Nil for a rate that says nothing: unreported, paused, or ordinary.
    ///
    /// The tolerance is not decoration. Players report 1.0 as 0.9999998 often enough that an
    /// equality test leaves a "1.0×" chip on a normal track, which is the one case this is written
    /// to avoid.
    public static func chip(for rate: Double?) -> Double? {
        guard let rate, rate > 0, abs(rate - 1) > 0.01 else { return nil }
        return rate
    }

    /// `1.5×`, `2×`, `0.75×` — the trailing zero dropped, because "1.50×" reads as a measurement
    /// rather than as a setting.
    public static func text(_ rate: Double) -> String {
        let rounded = (rate * 100).rounded() / 100
        // `.formatted` rather than `String(format:)`, and that is a bug fix rather than a
        // translation: `String(format:)` takes no locale, so it drew `1.5×` on a machine that
        // writes `1,5`. `fractionLength(0...2)` is what keeps the old rule — two digits where there
        // are two, and no trailing `.0` on a whole number — in one expression instead of a branch.
        let number = rounded.formatted(
            .number.precision(.fractionLength(0...2)).grouping(.never)
        )
        return islandText("nowPlaying.queue.rate", "\(number)×")
    }
}
