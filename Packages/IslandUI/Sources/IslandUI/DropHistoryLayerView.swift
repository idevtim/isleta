import IslandActivities
import IslandKit
import SwiftUI

/// The drop history, drawn in the open island's body in place of the activity's own content.
///
/// What the user dropped on the island and what Isleta did with it — converted, compressed,
/// transcribed, AirDropped, filed away, linked — newest first.
///
/// ## It carries its own way out
///
/// An island the user opened is normally dismissed by clicking anywhere else, which is right for a
/// transient surface and wrong for one that is being *read*: the click that puts the caret back in
/// the user's editor is part of reading a list, not an answer about it. So the header holds the two
/// deliberate exits — **Clear All**, which forgets everything and closes, and the **✕**, which
/// closes and keeps it. Escape is the third and needs no pixels.
///
/// ## There is no search field, and that is a decision rather than a gap
///
/// A search field would cost `IslandPanel.acceptsKeyboardInput` — the single scoped
/// exception to "the panel never becomes key", which CLAUDE.md marks explicitly as a thing not to
/// widen to a second feature without measuring it again. Two callers already share it (the reply
/// composer and the shelf's field). A third, for a list capped at forty rows that is ten flicks from
/// end to end, would be spending the app's most carefully argued exception on a convenience.
struct DropHistoryLayerView: View {

    let model: IslandScreenModel
    let history: DropHistoryModel
    let now: Date

    /// Where the `ScrollView` is parked. Driven from `history.scrollTarget` — see `viewport`.
    @State private var scrollPosition = ScrollPosition(y: 0)

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)
            let entries = history.entries

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, DropHistoryLayout.headerSpacing)

                if entries.isEmpty {
                    Text(islandText("dropHistory.empty", "Nothing dropped yet"))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.6))
                        .frame(height: DropHistoryLayout.rowHeight)
                } else {
                    viewport(
                        entries,
                        width: max(0, metrics.bodySize.width - DropHistoryLayout.horizontalPadding * 2),
                        // The room actually left under the header, not the room the layout intends
                        // there to be. Letting those two disagree slices the last row in half with
                        // the island's own bottom edge while every test still passes.
                        available: DropHistoryLayout.rowsHeight(
                            inContentHeight: max(0, model.contentBodySize.height - model.cutoutSize.height)
                        )
                    )
                }
            }
            .padding(.horizontal, DropHistoryLayout.horizontalPadding)
            .frame(
                width: metrics.bodySize.width,
                height: max(0, model.contentBodySize.height - model.cutoutSize.height),
                alignment: .topLeading
            )
            .padding(.top, DropHistoryLayout.topPadding)
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The rows, scrolled behind a window that clips.
    ///
    /// **A `ScrollView` with scrolling switched off, driven from our own offset.** Not a preference:
    /// inside the island's hosting view a SwiftUI clip does not contain scrolled *content* —
    /// `.clipped()`, `.clipShape(_:)`, `.mask(_:)`, `.compositingGroup()` and `.drawingGroup()` were
    /// each measured letting rows draw straight over the header, while a plain `Rectangle`
    /// overflowing the same container by the same amount in the same frame was clipped exactly. A
    /// scroll view's clipping is its whole job rather than a request. `docs/TRAPS.md` carries the
    /// full account of the measurement.
    ///
    /// `scrollDisabled(true)` is load-bearing. The event never arrives anyway —
    /// `IslandHitTestView.scrollWheel` handles it and never calls `super` — and an enabled scroll
    /// view would take the vertical axis inside this rectangle only, so `IslandStowGesture` and
    /// `IslandCloseGesture` would read a different set of samples depending on where the pointer
    /// happened to be. `DropHistoryScroll` stays the one place a scroll is interpreted.
    ///
    /// `LazyVStack` with a **stated** height, and it was measured: a plain `VStack` building every
    /// row is the one animation in this app that dropped frames, and forty
    /// rows is well past the count where that showed. A lazy stack cannot report a content extent it
    /// has not built, so the extent is stated — every row here is exactly `rowHeight`, so it is known
    /// without building any.
    private func viewport(
        _ entries: [DropHistoryEntry],
        width: CGFloat,
        available: CGFloat
    ) -> some View {
        let height = min(
            available,
            min(
                DropHistoryLayout.viewportHeight,
                DropHistoryLayout.contentExtent(rowCount: entries.count)
            )
        )
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: DropHistoryLayout.rowSpacing) {
                ForEach(entries) { entry in
                    row(for: entry)
                        .frame(width: width, height: DropHistoryLayout.rowHeight)
                }
            }
            .frame(
                width: width,
                height: DropHistoryLayout.contentExtent(rowCount: entries.count),
                alignment: .topLeading
            )
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .frame(width: width, height: height, alignment: .topLeading)
        .scrollPosition($scrollPosition)
        // A drag lands instantly; a job finishing while the list is open travels back to the top on
        // the one motion token with bounce in it. Keyed on the whole target rather than the offset,
        // because two jobs finishing in a row both target the top and an `onChange` watching the
        // number alone would play nothing for the second — see `IslandListScrollTarget.sequence`.
        .onChange(of: history.scrollTarget, initial: true) { _, target in
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
        .contentShape(Rectangle())
        // An overlay, so the indicator is not part of the list it describes and cannot be scrolled
        // away by it.
        .overlay(alignment: .topTrailing) {
            if let indicator = DropHistoryLayout.indicator(
                offset: history.scrollOffset,
                rowCount: entries.count
            ) {
                Capsule()
                    .fill(.white.opacity(model.increaseContrast ? 0.6 : 0.25))
                    .frame(width: DropHistoryLayout.indicatorWidth, height: indicator.length)
                    .offset(y: indicator.top)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The list's name and the two controls that close it.
    ///
    /// Clear All is drawn only when there is something to clear — a button whose only possible
    /// effect is nothing is not a button. The ✕ is drawn always, because the case where it is the
    /// *only* way out is exactly the case where the list is empty.
    private var header: some View {
        HStack(spacing: 8) {
            Text(islandText("dropHistory.title", "Drop History"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.55))
                .lineLimit(1)

            Spacer(minLength: 4)

            if !history.isEmpty {
                Button { history.onClear?() } label: {
                    Text(islandText("dropHistory.clearAll", "Clear All"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
                        .padding(.horizontal, 10)
                        .frame(height: DropHistoryLayout.headerHeight)
                        .contentShape(Rectangle())
                        .background(Capsule().fill(.white.opacity(model.increaseContrast ? 0.24 : 0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(islandText("dropHistory.clearAll.a11y", "Clear the drop history"))
                .help(islandText("dropHistory.clearAll.help", """
                    Forgets what Isleta has done with the files you dropped. It does not delete \
                    any files.
                    """))
            }

            Button { history.onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.8))
                    .frame(
                        width: DropHistoryLayout.headerControlSide,
                        height: DropHistoryLayout.headerControlSide
                    )
                    .contentShape(Rectangle())
                    .background(Circle().fill(.white.opacity(model.increaseContrast ? 0.24 : 0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(islandText("dropHistory.close", "Close"))
        }
        .frame(height: DropHistoryLayout.headerHeight)
    }

    /// One row. Clicking it reveals what the work produced.
    ///
    /// **Reveal rather than open**, and the difference matters on a surface somebody is scanning:
    /// opening a converted PDF launches Preview and takes the screen, which is a large consequence
    /// for a mis-aimed click on a notch. Revealing puts the Finder on the file and leaves the user
    /// in front of it, which is also what answers the question the list exists for — "where did that
    /// go" — rather than answering a different one.
    private func row(for entry: DropHistoryEntry) -> some View {
        HStack(spacing: 6) {
            Button { history.onReveal?(entry.id) } label: {
                rowBody(entry)
            }
            .buttonStyle(IslandListRowButtonStyle(increaseContrast: model.increaseContrast))
            // Read from the model rather than from the entry, so a row that has just told the user
            // its disk is not connected says the same thing aloud as it does on screen.
            .accessibilityLabel(
                history.detail(for: entry).isEmpty
                    ? entry.title
                    : islandText(
                        "dropHistory.row.a11y",
                        "\(entry.title), \(history.detail(for: entry))"
                    )
            )
            .accessibilityHint(islandText("dropHistory.row.hint", "Shows it in the Finder"))

            if entry.link != nil {
                trailingButton(
                    symbol: "doc.on.doc",
                    label: islandText("dropHistory.copyLink", "Copy the link")
                ) { history.onCopyLink?(entry.id) }
            } else if entry.canRunAgain {
                trailingButton(
                    symbol: "arrow.clockwise",
                    label: islandText("dropHistory.runAgain", "Do this again")
                ) { history.onRunAgain?(entry.id) }
            }
        }
        // The indicator's lane, on the row rather than on `rowBody`, so the trailing button sits
        // inside the row's own width rather than in the gutter the indicator is drawn in.
        .padding(.trailing, DropHistoryLayout.indicatorLane)
    }

    private func trailingButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.85))
                .frame(
                    width: DropHistoryLayout.rowButtonSize.width,
                    height: DropHistoryLayout.rowButtonSize.height
                )
                .contentShape(Rectangle())
                .background(Capsule().fill(.white.opacity(model.increaseContrast ? 0.24 : 0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func rowBody(_ entry: DropHistoryEntry) -> some View {
        let troubled = history.isTroubled(entry)
        let detail = history.detail(for: entry)
        return HStack(spacing: DropHistoryLayout.symbolSpacing) {
            Image(systemName: troubled ? "exclamationmark.triangle.fill" : entry.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: DropHistoryLayout.symbolSide, height: DropHistoryLayout.symbolSide)
                .background(Circle().fill(.white.opacity(0.12)))
                // The one place this list uses a tint, and it is the one place there is something to
                // say with it: `.warning` is what a failed `fileAction` activity is drawn in and what
                // the shelf gives a file it can no longer find, so a problem here is the color the
                // user has already been shown for the same fact.
                .foregroundStyle(
                    troubled
                        ? ActivityPalette.color(for: .warning, increaseContrast: model.increaseContrast)
                        : Color.white.opacity(model.increaseContrast ? 1 : 0.85)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.62))
                        .lineLimit(1)
                        // Truncating the head, not the tail, and only here. A file name's
                        // distinguishing part is at the end — `invoice-2026-08-final.pdf` — and a
                        // list of rows all reading `invoice-2026-0…` is a list that cannot be used
                        // for the one thing it is for.
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)

            Text(IslandListFormat.age(seconds: now.timeIntervalSince(entry.finishedAt)))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.5))
        }
        .frame(height: DropHistoryLayout.rowHeight, alignment: .center)
        .foregroundStyle(.white)
    }
}
