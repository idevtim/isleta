import IslandKit
import SwiftUI

/// Positions the page indicator at the bottom of the open island.
///
/// A sibling of `ActivityLayerView` rather than a slot inside it, and the reason is the same one
/// that keeps `ShelfLayerView` separate: the four slots belong to *an activity*, and this strip
/// belongs to the island. Putting it in `ActivitySlotLayout` would mean the layout that answers
/// "where can this activity draw" also answered "where do the island's own controls go".
struct IslandPageIndicatorLayerView: View {

    let model: IslandScreenModel

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)

            IslandPageIndicatorView(
                current: model.currentPage,
                incoming: model.pageBeingDraggedTo,
                progress: model.pageDragProgress,
                increaseContrast: model.increaseContrast,
                // The strip sits at the island's bottom edge, which is where Semi-Liquid Glass has
                // cleared to glass and where Liquid Glass is glass throughout. `.opaque` is the only
                // material that gives a dot black to be seen against.
                isOnGlass: model.material != .opaque,
                // Lit at a page change and for two seconds after it, and for as long as a finger or
                // a pointer is on the carousel. See `IslandScreenModel.showsPageDots`.
                isVisible: model.showsPageDots,
                onSelect: { model.onSelectPage?($0) },
                onPointer: { isOver in
                    // Held while the pointer is on the strip; the dwell restarts when it leaves.
                    // `holdIndicator` is idempotent, which matters — `PointerPresence` re-reads the
                    // pointer on every layout, and the island changes shape under a stationary one
                    // constantly.
                    if isOver {
                        model.page?.holdIndicator()
                    } else {
                        model.page?.releaseIndicator()
                    }
                }
            )
            .frame(width: metrics.bodySize.width)
            .offset(
                x: origin.x,
                // Anchored to the **bottom** of the body, not offset from the top: the island's
                // height follows its content, so a strip placed from the top would sit at a
                // different distance from the bottom edge for every page.
                y: origin.y + metrics.bodySize.height
                    - IslandPageIndicatorLayout.bottomPadding
                    - IslandPageIndicatorLayout.dotSide
                    - IslandPageIndicatorLayout.topPadding
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
