import IslandActivities
import IslandKit
import SwiftUI

/// The open shelf: a header, a scrolling grid of tiles, and a placeholder where the next drop will
/// land.
///
/// ## Why this is a bespoke view rather than `ActivityContent`
///
/// Every other activity describes itself as data and `ActivityContentView` draws it, which is what
/// keeps IslandActivities free of SwiftUI. The shelf cannot: it draws *n* independent things, each
/// with its own hit region, its own drag source and its own remove control, and the four-slot
/// vocabulary has no word for that. PROGRESS.md already sanctions the escape hatch — "a bespoke
/// view belongs in IslandUI keyed on `ActivityKind`, never as an `AnyView` smuggled through
/// IslandActivities" — and this is it.
///
/// So the shelf activity publishes its flanks and its compact badge as ordinary `ActivityContent`
/// (the tray glyph and the count, which is what the collapsed island shows), and publishes an
/// **empty** `expanded` slot. `ActivitySlotLayout.bodySlot` returns nil for an empty slot, so
/// `ActivityLayerView` draws nothing in the open island's body and this view has it to itself.
/// There is no overlap to arbitrate and no z-order to get right.
///
/// ## Coordinates
///
/// `ShelfLayout` works in the island *body's* y-down space, the same space `ActivitySlotLayout`
/// uses. The panel is a fixed rectangle much larger than the island (§4.2), so everything here is
/// offset by `IslandLayout.bodyOrigin` — and the point the app shell hit-tests is converted the
/// same way, in the opposite direction. Both conversions read `contentMetrics`, never `metrics`:
/// the content lags the container by `Motion.contentFollowDelay` (§6.2), so laying tiles out
/// against the container's target would put them where the island is *going* to be.
struct ShelfLayerView: View {

    let model: IslandScreenModel
    let shelf: ShelfModel

    /// Where the `ScrollView` is parked. Driven from `shelf.scrollTarget` — see `grid`.
    @State private var scrollPosition = ScrollPosition(y: 0)

    /// Focus for the search field. The panel takes key from the app shell before this view draws
    /// the field; the first responder inside it is this.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = model.contentMetrics
            let origin = IslandLayout.bodyOrigin(for: metrics, in: proxy.size)

            if shelf.isPresented, model.contentPresentation == .expanded {
                // One layer or the other, in one rectangle. `ShelfLayout.contentHeight` is a
                // constant, so swapping them changes nothing about the island's outline — no
                // widen-then-tighten, no new form to prove, and no way for the two to overlap.
                if let menu = shelf.actionMenu,
                   let layout = ShelfActionLayout.resolve(
                    body: model.slotLayout.body,
                    rowCount: menu.actions.count,
                    offset: shelf.actionScrollTarget.offset
                   ) {
                    ShelfActionsLayerView(
                        model: model, shelf: shelf, menu: menu, layout: layout, origin: origin
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                } else if let layout = ShelfLayout.resolve(
                    body: model.slotLayout.body,
                    slotCount: shelf.slotCount,
                    offset: shelf.scrollTarget.offset
                ) {
                    ZStack(alignment: .topLeading) {
                        header(layout, offsetBy: origin)
                        grid(layout, offsetBy: origin)
                        indicator(layout, offsetBy: origin)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: - Header

    /// What the shelf is holding, the magnifier, and Clear All.
    ///
    /// ## The field takes the keyboard, and that is bought rather than free
    ///
    /// A window that is not key receives no keys, and `IslandPanel` refuses key so that clicking the
    /// island never deactivates the user's frontmost app (§4.1). The notification reply bought the
    /// exception this reuses: `IslandPanel.acceptsKeyboardInput`, true for the length of one
    /// deliberate typing act and false at every other instant, measured on macOS 27.0 to leave
    /// `NSWorkspace.frontmostApplication` where it was and the frontmost window `AXMain = true` —
    /// no Dock switch, no title-bar flicker. The full table is on that property.
    ///
    /// Reusing it rather than standing up a second key-capable panel of the shelf's own is the whole
    /// point: two mechanisms for taking the keyboard is two things that can each forget to give it
    /// back, and the failure mode of forgetting is an island that eats every keystroke on the
    /// machine.
    ///
    /// Clear All is styled as the drop history styles its own — a capsule of the same height, in the
    /// same corner — because the two headers are the same piece of chrome as far as anyone looking
    /// at the island is concerned. It is drawn only when there is something to clear: a button whose
    /// only possible effect is nothing is worse than an empty corner.
    @ViewBuilder
    private func header(_ layout: ShelfLayout, offsetBy origin: CGPoint) -> some View {
        HStack(spacing: ShelfLayout.headerControlGap) {
            if shelf.isSearchOpen {
                searchField
            } else {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ActivityPalette.color(for: tint, increaseContrast: model.increaseContrast))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if !shelf.isEmpty, shelf.areDropActionsEnabled {
                // The wand: what the island can do with what it is holding. Leading of the
                // magnifier, at the same size, because the two are the same kind of control — a
                // mode the header enters — and a wider one would read as the more important of the
                // two. `wand.and.rays` is `ActivityKind.fileAction.chipSymbol`, so the control that
                // starts the work and the chip that leads back to it are one mark.
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                            .opacity(model.increaseContrast ? 1 : 0.7)
                    )
                    .frame(width: ShelfLayout.searchSide, height: ShelfLayout.headerHeight)
                    .background(Circle().fill(.white.opacity(model.increaseContrast ? 0.2 : 0.10)))
                    // Announced as a button even though the press is handled by `IslandHitTestView`
                    // rather than by a SwiftUI control — the reason it is not a `Button` is a
                    // window-server one (§4.1), not a semantic one.
                    .accessibilityLabel(islandText("shelf.actions.a11y", "Actions for these files"))
                    .accessibilityAddTraits(.isButton)
            }

            if !shelf.isEmpty {
                // The magnifier is a toggle in a fixed place rather than a control that moves aside
                // for a field: one rect for `ShelfLayout.region` to test, in the same position
                // whether or not a search is running, so the gesture that ends a search is the same
                // one that started it.
                Image(systemName: isSearchEngaged ? "xmark" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        ActivityPalette.color(
                            for: isSearchEngaged ? .accent : .neutral,
                            increaseContrast: model.increaseContrast
                        )
                        .opacity(searchOpacity)
                    )
                    .frame(width: ShelfLayout.searchSide, height: ShelfLayout.headerHeight)
                    .background(Circle().fill(.white.opacity(model.increaseContrast ? 0.2 : 0.10)))
                    // Announced as a button even though the press is handled by `IslandHitTestView`
                    // rather than by a SwiftUI control — VoiceOver describes what the thing *is*,
                    // and the reason this is not a `Button` is a window-server one (§4.1), not a
                    // semantic one.
                    .accessibilityLabel(isSearchEngaged
                                        ? islandText("shelf.search.end", "End search")
                                        : islandText("shelf.search.a11y", "Search the shelf"))
                    .accessibilityAddTraits(.isButton)

                Text(islandText("shelf.clearAll", "Clear All"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                            .opacity(ActivityPalette.secondaryOpacity(increaseContrast: model.increaseContrast))
                    )
                    .frame(width: ShelfLayout.clearWidth, height: ShelfLayout.headerHeight)
                    .background(Capsule().fill(.white.opacity(model.increaseContrast ? 0.2 : 0.10)))
                    .accessibilityLabel(islandText("shelf.clearAll.a11y", "Clear the shelf"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(width: layout.header.width, height: layout.header.height)
        .offset(x: origin.x + layout.header.minX, y: origin.y + layout.header.minY)
        .contentTransition(.opacity)
        // Focus follows the shell's decision rather than leading it: the panel is told to accept
        // keyboard input *before* this flag flips, so by the time the field exists there is a key
        // window for it to be the first responder of. `initial: true` covers the case where the
        // island is rebuilt — a display reconnecting — with a search already up.
        .onChange(of: shelf.isSearchOpen, initial: true) { _, open in
            isSearchFocused = open
        }
    }

    /// The query, typed into the island.
    ///
    /// Written through `ShelfModel.setQuery` rather than bound straight to `shelf.query`, so the
    /// animation lives with the state that changed instead of being a modifier on the field — see
    /// that method. The binding's getter is the model's own value, so an ended search (which clears
    /// it from underneath) empties the field without the view being told twice.
    private var searchField: some View {
        TextField(
            islandText("shelf.search.prompt", "Search"),
            text: Binding(
                get: { shelf.query },
                set: { shelf.setQuery($0, reduceMotion: model.reduceMotion) }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .focused($isSearchFocused)
        // Return keeps the matches and hands the keyboard back — the shell's `onSubmitSearch` is
        // what actually releases key, because a view cannot know whether some other surface wants
        // it next.
        .onSubmit { shelf.onSubmitSearch?() }
        .accessibilityLabel(islandText("shelf.search.a11y", "Search the shelf"))
    }

    /// What the header says on the left.
    ///
    /// While a filter is live it counts **both** numbers. A search that matches nothing would
    /// otherwise leave the user looking at an empty grid wondering whether the shelf emptied itself,
    /// which is the one state where the count alone is a lie by omission.
    private var title: String {
        if shelf.isDropTargeted { return islandText("shelf.dropTarget", "Drop to add") }
        // A running job wins the line, and it has to: while the island is open the flanks are not on
        // screen at all, so the `fileAction` activity's progress — which lives in the trailing
        // sliver of the *collapsed* island — is invisible to exactly the person who asked for the
        // work. The count comes back when the job ends. See `ShelfJobStatus`.
        if let job = shelf.job { return job.label }
        if shelf.isSearching {
            return islandText(
                "shelf.searchCount",
                "\(shelf.visibleItems.count) of \(shelf.count)"
            )
        }
        return islandText("shelf.itemCount", "\(shelf.count) items")
    }

    private var tint: ActivityTint {
        shelf.isDropTargeted ? .accent : .neutral
    }

    /// Whether the magnifier is offering to *end* a search rather than start one.
    ///
    /// Either half counts: the field being up with nothing typed, or a filter still narrowing the
    /// grid after the field has been dismissed with Return. A glyph that only knew about one of them
    /// would leave the user with a live filter and a control that promises to start the search they
    /// are already in.
    private var isSearchEngaged: Bool {
        shelf.isSearchOpen || shelf.isSearching
    }

    private var searchOpacity: Double {
        model.increaseContrast ? 1 : (isSearchEngaged ? 0.95 : 0.7)
    }

    // MARK: - The grid

    /// The tiles, scrolled behind a window that clips.
    ///
    /// **A `ScrollView` with scrolling switched off, driven from our own offset** — the same
    /// mechanism `DropHistoryLayerView.viewport` uses, and for the same measured reason. Inside this
    /// hosting view a SwiftUI clip does not contain scrolled content: `.clipped()`,
    /// `.clipShape(_:)`, `.mask(_:)`, `.compositingGroup()` and `.drawingGroup()` were each measured
    /// letting rows draw straight over the header above them, with the offset applied inside the
    /// stack and outside it, and with the island's own ancestor mask present and removed. A plain
    /// `Rectangle` overflowing the same container by the same amount at the same moment was clipped
    /// exactly, so the container was never the problem — whatever promotes this content (text,
    /// images) puts it beyond the reach of a SwiftUI clip here. A scroll view's clipping is its
    /// whole job and is not a request. Nine mechanisms were tried there; this is not a tenth.
    ///
    /// `scrollDisabled(true)` is load-bearing rather than tidiness: the event never arrives anyway
    /// (`IslandHitTestView.scrollWheel` does not call `super`), and an enabled scroll view would
    /// take the vertical axis inside the grid's rectangle only, leaving `IslandStowGesture` and
    /// `IslandCloseGesture` reading a different set of samples depending on where the pointer
    /// happened to be. `ShelfScroll` stays the one place a scroll is interpreted.
    ///
    /// **The tiles are placed absolutely rather than by a grid container**, which is what keeps the
    /// drawn shelf and the clickable shelf the same object: `ShelfLayout` computes both, and a
    /// `LazyVGrid` would compute the drawn one itself and be free to disagree by a point. Only the
    /// slots in `visibleSlots` are built — that is `ShelfLayout`'s own window, not a second copy of
    /// the arithmetic — because building every tile up front is what dropped frames on the island's
    /// one other scrolling surface, at a row count this one passes with six files on it.
    private func grid(_ layout: ShelfLayout, offsetBy origin: CGPoint) -> some View {
        let visible = layout.visibleSlots
        let items = shelf.visibleItems

        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Keyed by the item's identity and **not** by its slot, which is the whole of why a
                // reorder travels instead of blinking: the array is rearranged under the pointer, so
                // a view keyed by index would keep its position and swap its contents — thirty tiles
                // changing what they are, rather than one tile moving.
                ForEach(Array(items.enumerated()).filter { visible.contains($0.offset) }, id: \.element.id) { slot, item in
                    filled(item, at: slot, in: layout)
                }
                if items.count < layout.tiles.count, visible.contains(items.count) {
                    placeholder(at: items.count, in: layout)
                }
            }
            // Stated rather than inferred, for the reason `DropHistoryLayerView` states its own: the
            // scroll view is being asked to sit at an offset our arithmetic produced, so its idea
            // of how much content there is has to be that same arithmetic and not an estimate made
            // from whichever tiles happen to have been built.
            .frame(width: layout.viewport.width, height: layout.contentExtent, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
        .scrollPosition($scrollPosition)
        // A drag lands instantly; a file arriving travels, on the one motion token with bounce in
        // it. Keyed on the whole target rather than on the offset, because two drops in a row both
        // target the end and an `onChange` watching the number alone would play nothing for the
        // second — see `ShelfScrollTarget.sequence`.
        .onChange(of: shelf.scrollTarget, initial: true) { _, target in
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

    /// The scroll indicator, drawn in the gutter beside the grid rather than over it.
    ///
    /// It gets a lane for free: the grid is centerd in a body 50pt wider than five tiles, so there
    /// is 25pt of margin either side and nothing has to be moved aside for it. `DropHistoryLayout`
    /// reserves a lane on every row because its rows are full width; this one does not need to, and
    /// a reserved lane there would shift the whole grid off center to make room for chrome that is
    /// absent on most shelves.
    @ViewBuilder
    private func indicator(_ layout: ShelfLayout, offsetBy origin: CGPoint) -> some View {
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

    // MARK: - Tiles

    private func filled(_ item: ShelfItem, at slot: Int, in layout: ShelfLayout) -> some View {
        let frame = contentFrame(at: slot, in: layout)
        let isHeld = shelf.reorderingID == item.id

        return VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                            .opacity(chipOpacity(isHeld: isHeld))
                    )
                    .overlay {
                        Image(systemName: item.isStale ? "questionmark.folder" : item.symbolName)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(
                                ActivityPalette.color(
                                    for: item.isStale ? .warning : .neutral,
                                    increaseContrast: model.increaseContrast
                                )
                            )
                    }
                    .frame(height: ShelfLayout.chipHeight)

                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: ShelfLayout.removeBadgeSize - 3, weight: .semibold))
                    .foregroundStyle(
                        ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                            .opacity(model.increaseContrast ? 0.95 : 0.65)
                    )
                    .frame(width: ShelfLayout.removeBadgeSize, height: ShelfLayout.removeBadgeSize)
                    .accessibilityLabel(islandText("shelf.tile.remove", "Remove \(item.name)"))
                    .accessibilityAddTraits(.isButton)
            }

            Text(item.name)
                .font(.system(size: 9, weight: .regular))
                // Middle rather than tail: at 50pt a filename is going to be cut somewhere, and the
                // extension is the half that says what the thing is.
                .truncationMode(.middle)
                .lineLimit(1)
                .foregroundStyle(
                    ActivityPalette.color(for: .neutral, increaseContrast: model.increaseContrast)
                        .opacity(ActivityPalette.secondaryOpacity(increaseContrast: model.increaseContrast))
                )
        }
        .frame(width: frame.width, height: frame.height)
        // Lifted while held, so a reorder reads as picking one tile up out of the grid. A scale and
        // nothing else: a shadow would need somewhere to fall, and on a pure black island (§6.4)
        // there is nothing for it to fall on.
        .scaleEffect(isHeld ? 1.12 : 1)
        .offset(x: frame.minX, y: frame.minY)
        // No curve named here: the transition rides whichever token opened the transaction —
        // `Motion.contentSwap` for a drop, a search or a reorder, `Motion.expand` when the island
        // opens around it.
        .transition(.scale(scale: 0.86).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            item.isStale ? islandText("shelf.tile.missing", "\(item.name), missing") : item.name
        )
    }

    private func placeholder(at slot: Int, in layout: ShelfLayout) -> some View {
        let frame = contentFrame(at: slot, in: layout)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                ActivityPalette.color(for: .accent, increaseContrast: model.increaseContrast)
                    .opacity(model.increaseContrast ? 0.9 : 0.55),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        ActivityPalette.color(for: .accent, increaseContrast: model.increaseContrast)
                            .opacity(model.increaseContrast ? 0.9 : 0.55)
                    )
            }
            .frame(width: frame.width, height: ShelfLayout.chipHeight)
            .offset(x: frame.minX, y: frame.minY)
            .transition(.scale(scale: 0.86).combined(with: .opacity))
            .accessibilityHidden(true)
    }

    private func chipOpacity(isHeld: Bool) -> Double {
        if isHeld { return model.increaseContrast ? 0.38 : 0.26 }
        return model.increaseContrast ? 0.22 : 0.12
    }

    /// A slot's rect inside the scroll view — which is the layout's unscrolled rect, moved into the
    /// viewport's own space. The scroll view applies the offset; applying it here as well would
    /// scroll the grid twice as fast as the fingers.
    private func contentFrame(at slot: Int, in layout: ShelfLayout) -> CGRect {
        guard layout.contentTiles.indices.contains(slot) else { return .zero }
        return layout.contentTiles[slot]
            .offsetBy(dx: -layout.viewport.minX, dy: -layout.viewport.minY)
    }
}
