import IslandActivities
import IslandKit
import SwiftUI

/// The shelf's actions menu: what the island can do with what it is holding.
///
/// Drawn in the shelf's own body rectangle rather than in one of its own — see `ShelfActionLayout`
/// for why that is the design and not an economy. `ShelfLayerView` draws either this or the grid,
/// never both, so there is no z-order to arbitrate and no second height for
/// `IslandController.expandedContentHeight` to be told about.
///
/// Every press here goes through `IslandHitTestView` and `ShelfActionLayout.region(at:)`, like the
/// grid's — not through SwiftUI `Button`s. The reason is the one `ShelfLayout` gives at length: the
/// panel never becomes key, so SwiftUI's gesture system is the route by which "the first click
/// sometimes does nothing" gets into an app like this, and two mechanisms for two controls sitting
/// 8pt apart is how a header ends up with one control that works when the island is settled and one
/// that works when it is not.
struct ShelfActionsLayerView: View {

    let model: IslandScreenModel
    let shelf: ShelfModel
    let menu: ShelfActionMenu
    let layout: ShelfActionLayout
    let origin: CGPoint

    /// Where the list is parked. Driven from `shelf.actionScrollTarget`, the same arrangement the
    /// grid has with `shelf.scrollTarget`.
    @State private var scrollPosition = ScrollPosition(y: 0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            header
            rows
            indicator
        }
    }

    // MARK: - Header

    /// What the menu is about, and the way back.
    ///
    /// The back control is in the magnifier's rect, deliberately: the wand that opened this menu is
    /// one control-width leading of it, and putting the exit under the user's finger rather than
    /// under the control they last pressed is the pattern every sheet on macOS follows. It draws a
    /// chevron rather than an ✕ because the grid is still there behind it — nothing is being
    /// dismissed, a layer is being left.
    private var header: some View {
        HStack(spacing: ShelfLayout.headerControlGap) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                )
                .lineLimit(1)
            Spacer(minLength: 4)

            Image(systemName: "chevron.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                        .opacity(model.increaseContrast ? 1 : 0.85)
                )
                .frame(width: ShelfActionLayout.backSide, height: ShelfLayout.headerHeight)
                .background(Circle().fill(.white.opacity(model.increaseContrast ? 0.2 : 0.10)))
                .accessibilityLabel(islandText("shelf.actions.back", "Back to the shelf"))
                .accessibilityAddTraits(.isButton)
        }
        .frame(width: layout.header.width, height: layout.header.height)
        .offset(x: origin.x + layout.header.minX, y: origin.y + layout.header.minY)
        .contentTransition(.opacity)
    }

    /// A running job wins the header line, for the reason `ShelfJobStatus` exists: with the island
    /// open the flanks are not on screen, so this is the only place the person who asked for the
    /// work can see it happening.
    private var title: String {
        if let job = shelf.job { return job.label }
        return menu.title
    }

    // MARK: - Rows

    /// The actions, scrolled behind a window that clips.
    ///
    /// **A `ScrollView` with scrolling switched off, driven from our own offset** — the mechanism
    /// `DropHistoryLayerView` measured and `ShelfLayerView` reuses. Inside this hosting view a SwiftUI
    /// clip does not contain scrolled *content*: `.clipped()`, `.clipShape(_:)`, `.mask(_:)`,
    /// `.compositingGroup()` and `.drawingGroup()` were each measured letting rows draw straight
    /// over the header above them, while a plain `Rectangle` overflowing the same container by the
    /// same amount in the same frame was clipped exactly. A scroll view's clipping is structural
    /// rather than a request. Nine mechanisms were tried there; this is not a tenth.
    private var rows: some View {
        let window = layout.visibleRows
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                ForEach(
                    Array(menu.actions.enumerated()).filter { window.contains($0.offset) },
                    id: \.element.id
                ) { index, action in
                    row(action, at: index)
                }
            }
            // Stated rather than inferred: the scroll view is being asked to sit at an offset our
            // arithmetic produced, so its idea of how much content there is has to be that same
            // arithmetic and not an estimate made from whichever rows happen to have been built.
            .frame(width: layout.viewport.width, height: layout.contentExtent, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
        .scrollPosition($scrollPosition)
        .onChange(of: shelf.actionScrollTarget, initial: true) { _, target in
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
        .offset(x: origin.x + layout.viewport.minX, y: origin.y + layout.viewport.minY)
    }

    private func row(_ action: DropAction, at index: Int) -> some View {
        let frame = contentFrame(at: index)
        return HStack(spacing: ShelfActionLayout.symbolSpacing) {
            Image(systemName: action.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: ShelfActionLayout.symbolWidth)
            Text(action.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        // `.warning` for the one row that leaves the user's file somewhere else. Color rather than
        // a confirmation sheet: the island has no room for a sheet, and the destination panel that
        // follows is itself a confirmation — Cancel there is Cancel here.
        .foregroundStyle(
            ActivityPalette.color(
                for: action.movesTheOriginal ? .warning : .neutral,
                increaseContrast: model.increaseContrast
            )
        )
        .padding(.horizontal, 8)
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ShelfActionLayout.rowCornerRadius, style: .continuous)
                .fill(.white.opacity(model.increaseContrast ? 0.2 : 0.08))
        )
        .offset(x: frame.minX, y: frame.minY)
        // No curve named here: the transition rides whichever token opened the transaction —
        // `Motion.contentSwap` for the layer arriving, `Motion.nudge` for a scroll.
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var indicator: some View {
        if let indicator = layout.indicator() {
            Capsule()
                .fill(.white.opacity(model.increaseContrast ? 0.6 : 0.25))
                .frame(width: ShelfLayout.indicatorWidth, height: indicator.length)
                .offset(
                    x: origin.x + layout.body.maxX - ShelfLayout.horizontalPadding - ShelfLayout.indicatorWidth,
                    y: origin.y + layout.viewport.minY + indicator.top
                )
                .accessibilityHidden(true)
        }
    }

    /// A row's rect inside the scroll view — the layout's unscrolled rect, moved into the viewport's
    /// own space. The scroll view applies the offset; applying it here as well would scroll the list
    /// twice as fast as the fingers.
    private func contentFrame(at index: Int) -> CGRect {
        guard layout.contentRows.indices.contains(index) else { return .zero }
        return layout.contentRows[index]
            .offsetBy(dx: -layout.viewport.minX, dy: -layout.viewport.minY)
    }
}
