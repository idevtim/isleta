import IslandKit
import SwiftUI

/// What one panel draws.
///
/// At rest with nothing on stage this is, correctly, invisible on a notched display: pure black
/// filling exactly the notch cutout, its bottom corners following the cutout's own.
///
/// Being invisible is the point, and it is also the discovery problem: nothing on screen says the
/// island is there. Two things answer that. Arriving with the pointer swells the island past the
/// notch and taps the trackpad once, so the first thing the user learns about Isleta is that it
/// responds to them. And an activity with something to say in the flanks puts the island in a
/// *flanked* form — 80pt wider, still exactly the cutout's height — so what it is saying is visible
/// without a click. Both are one animated `model.metrics` driving one `IslandShape`; the mask below
/// is what reveals the content as the container grows to hold it. Press ⌥⌘D to see which form is
/// live and what geometry it is drawing.
public struct IslandRootView: View {

    private let model: IslandScreenModel

    /// The namespace the compact-to-expanded symbol morph is matched in (§6.2). One per panel: a
    /// namespace shared across screens would try to fly the glyph from one display to another.
    @Namespace private var morph

    /// The instant time-dependent values are formatted at, advanced by `ActivityClock` and by
    /// nothing else. One value for the whole island, so two counters cannot sample `Date()` either
    /// side of a second boundary and render "1:00" next to "0:59".
    @State private var now = Date()

    /// The app-wide shelf, or nil where nothing injected one — a preview, a test, or any build that
    /// has no app shell. Optional rather than required so this view keeps satisfying §3's layering
    /// test: everything in IslandUI must build and preview with no permission and no wiring.
    @Environment(ShelfModel.self) private var shelf: ShelfModel?

    public init(model: IslandScreenModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .top) {
            island
                // The outline grows back with its content, anchored at the notch, so the island
                // arrives as one object rather than as a black shape that is already there with
                // something fading in inside it.
                //
                // **Sideways only.** The island lives in a cutout whose height never changes, so
                // the only direction it has to arrive *from* is the cutout's own width: the
                // flanks spring out to the left and right. A uniform scale also grew it
                // downwards, which read as the island dropping out of the bezel rather than
                // widening out of it — the owner's verdict on hardware, 2026-08-26. `y: 1`, and
                // the same on every other re-entry so they are one movement.
                //
                // Safe to scale the *drawn* shape while `islandPath` stays at the settled one,
                // because the scale only ever runs from smaller up to 1: every intermediate is a
                // **subset** of the region we accept, which is the harmless direction. A click on
                // those few points during the ~300ms return is one the window server has already
                // routed to us and that we accept — never the dangerous case, which is drawn pixels
                // we refuse. See `IslandShapeMetrics.union` for the same rule stated the other way.
                .scaleEffect(x: IslandScreenModel.reentryScale(model.reentry), y: 1, anchor: .top)
                .opacity(IslandScreenModel.reentryOpacity(model.reentry))
                // The shape is the island; it says nothing. Everything VoiceOver should reach is in
                // the activity layer below, which carries the content's own labels.
                .accessibilityHidden(true)

            // Masked to the island outline, and that is a hard requirement rather than tidiness.
            // The window server derives the panel's event shape from the alpha of our backing
            // store, so a single glyph drawn outside the island would make those pixels opaque and
            // start swallowing clicks meant for the app underneath — over the menu bar, of all
            // places. Masking also gives the morph its reveal for free: content laid out for the
            // expanded island is clipped to the container until the container has grown to fit it.
            //
            // `.mask` rather than `.clipShape` deliberately: `clipShape` also clips the view's
            // hit-testing region, and this codebase keeps hit testing in exactly one place
            // (`IslandHitTestView.islandPath`) so the visible shape and the clickable region cannot
            // drift. Two clippers is two definitions.
            ActivityLayerView(model: model, namespace: morph, now: now)
                // Inside the mask, never outside it: the swipe slides the content under a
                // stationary island outline, so nothing about the panel's alpha — and therefore
                // nothing about where a click lands — changes while a swipe is in flight.
                .modifier(SwipeOffsetEffect(swipe: model.swipe))
                // The re-entry after a space switch, for the same reason and in the same place as
                // the swipe offset: inside the mask, so the outline and `islandPath` never move.
                //
                // A scale from the center out, not a fade. A fade reads as a flicker — the content
                // is already fully drawn, so brightening it just looks like the island failed to
                // paint for a frame. Growing it back gives the return a direction, which is what
                // makes it read as the island arriving rather than as a glitch recovering.
                // Sideways only, matching the outline above.
                .scaleEffect(x: IslandScreenModel.reentryScale(model.reentry), y: 1, anchor: .top)
                .opacity(IslandScreenModel.reentryOpacity(model.reentry))
                // The stow, on the content only. The island itself stays put and keeps peeking —
                // see `IslandScreenModel.stowReveal` for why this is not `reentry`.
                .scaleEffect(IslandScreenModel.stowScale(model.stowReveal), anchor: .top)
                .opacity(IslandScreenModel.stowOpacity(model.stowReveal, isStowed: model.isStowed))
                .mask(islandMask)

            // The shelf (§5, Milestone 3), masked to the same outline for the same reason: content
            // drawn outside the island would make those pixels opaque and start swallowing clicks
            // meant for the app underneath. It draws only while the shelf is the activity on stage
            // and the island is open — see `ShelfLayerView`, which also says why the shelf is a
            // bespoke view rather than four slots of `ActivityContent`.
            //
            // The model is optional so IslandUI keeps building and previewing with nothing injected
            // (§3's layering test); the app shell puts the one app-wide instance in the environment.
            if let shelf {
                ShelfLayerView(model: model, shelf: shelf)
                    .mask(islandMask)
            }

            // **The pages the open island turns between**, and the surfaces a page drills into.
            //
            // Drawn in place of the activity's own body for the same reason the shelf is: the kinds
            // behind them publish an **empty** `expanded` slot, so `ActivitySlotLayout.bodySlot`
            // returns nil and `ActivityLayerView` leaves the body alone. The flanks keep drawing
            // throughout, which is what lets the collapsed island go on saying what is playing.
            //
            // Masked to the island outline like everything else — content drawn outside it makes
            // those pixels opaque to the window server and starts swallowing clicks meant for the
            // app underneath, over the menu bar of all places.
            //
            // **The order here is exhaustive and exclusive**, which is what pages bought. It used to
            // be a chain of `isShowing…` flags that could be true together — the weather had to be
            // tested before the drill-down precisely because both could be set at once, and
            // `AppDelegate.expandedContentHeightForStage` had to repeat the same order or the island
            // was sized for one surface and drawing another. A page is a single value, so the three
            // cannot overlap and there is no order to keep in step.
            //
            // The schedule is the exception and is deliberately *not* a page: it is a drill-down
            // from home — the same surface answering a longer question, today and tomorrow rather
            // than the next three hours — so it draws over whatever page is current and takes the
            // body while it is up.
            //
            // `pagesOwnBody` is the *same* question `ActivityLayerView` asks before it draws an
            // activity's own body slot, so the two cannot both decide they are drawing. It is one
            // property rather than this condition written out twice, which is how the player ended
            // up composited over the home page for a build.
            if model.pagesOwnBody, let glance = model.glance {
                // **The mask hangs on this container, not on the page**, and that is what keeps a
                // sliding page inside the island. `.mask` is positioned by layout, and a transition
                // applied to the same view carries the mask along with it — so the outline
                // travelled with the content and the page was visible out over the menu bar for the
                // length of the slide. A stable parent holds the mask still and the pages move
                // underneath it, which is the arrangement `ActivityLayerView` already relies on for
                // the swipe offset.
                ZStack(alignment: .topLeading) {
                    // **The two pages either side, drawn only while a swipe is live.**
                    //
                    // This is what makes the gesture a carousel rather than a trigger: the page you
                    // are dragging toward is really there, one island-width away, and it arrives
                    // because your fingers brought it rather than because a threshold fired. There
                    // is no transition on these — they are simply *at* ±one page, and the whole
                    // strip is moved by `SwipeOffsetEffect` below.
                    //
                    // Absent the rest of the time, and §9 is the whole reason: the music page owns
                    // a `CALayer` equaliser and the weather page a precipitation view, and keeping
                    // all three alive whenever the island is open would spend the idle budget on
                    // two surfaces nobody is looking at. See `IslandSwipeModel.isPaging`.
                    if model.swipe.isPaging, !glance.isShowingSchedule, model.presentedKind != .meeting {
                        page(model.currentPage.previous, glance: glance)
                            .offset(x: -model.swipe.pageSpan)
                        page(model.currentPage.next, glance: glance)
                            .offset(x: model.swipe.pageSpan)
                    }

                    Group {
                        if glance.isShowingSchedule {
                            GlanceScheduleLayerView(model: model, glance: glance, now: now)
                        } else if model.presentedKind == .meeting {
                            // A meeting keeps its own body wherever the user is: the whole point of the
                            // kind is the Join button, and a page turn is not a reason to take it away.
                            GlanceLayerView(model: model, glance: glance)
                        } else {
                            page(model.currentPage, glance: glance)
                        }
                    }
                // **The page slides in and the one it replaced slides out**, in the direction the
                // finger went. A crossfade here read as the new page simply appearing, which is
                // what a carousel is not: the whole point of the gesture is that the surfaces are
                // laid out side by side and you are moving along them.
                //
                // `.id` is load-bearing. The branches above are a `switch` inside a `ViewBuilder`,
                // and SwiftUI is entitled to treat two branches of the same shape as one view with
                // new contents — in which case there is no insertion or removal for a transition to
                // attach to and the content changes in place. Keying on what is drawn makes each
                // page its own identity.
                    .id(pageIdentity(glance: glance))
                    .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Inside the mask: the swipe slides the content under a stationary island outline,
                // so nothing about the panel's alpha — and therefore nothing about where a click
                // lands — changes while a swipe is in flight. Without this the pages did not follow
                // the finger at all; only `ActivityLayerView` did, and it draws nothing in the body
                // while a page owns it.
                .modifier(SwipeOffsetEffect(swipe: model.swipe))
                .mask(islandMask)
            }

            // What is playing, in the strip that springs out under the cutout while the pointer is
            // on the album cover (`IslandForm.showsTrackLip`).
            //
            // The one layer here drawn on a **collapsed** island. Everything above and below it
            // draws in the body region because the island is open; this one is the reason the body
            // region exists at all in that moment, so it is gated on the form rather than on the
            // presentation. `ActivityLayerView` gives the region up while it is on screen — see the
            // note on its body condition — and the flanks keep drawing, which matters: the cover
            // the pointer is on is one of them.
            //
            // `contentShowsTrackLip` and not `showsTrackLip`, like every other surface here: the
            // content follows the container by `Motion.contentFollowDelay` (§6.2), so the text
            // arrives into a strip that has already grown rather than 40ms ahead of it.
            //
            // Masked to the island outline like everything else — content drawn outside it makes
            // those pixels opaque to the window server and starts swallowing clicks meant for the
            // app underneath, over the menu bar of all places.
            // The content is the model's answer and not this view's, because the *shape* is gated on
            // the same question — the island must never grow a strip it would then draw empty. See
            // `IslandScreenModel.trackLipContent`.
            if model.contentShowsTrackLip, let content = model.trackLipContent {
                NowPlayingTrackLipView(
                    model: model,
                    content: content,
                    increaseContrast: model.increaseContrast
                )
                .mask(islandMask)
                .transition(.opacity)
            }

            // The drop history: what Isleta has done with the files it was given, drawn in place of
            // the activity's own body. Drawn *above* Up Next in the same chain, so the ordering
            // here matches the ordering in `AppDelegate.expandedContentHeightForStage` — the view
            // and the height have to agree about which surface wins, or the island is sized for one
            // and drawing the other.
            if model.contentPresentation == .expanded,
               model.isShowingDropHistory,
               !model.isStowed,
               let dropHistory = model.dropHistory {
                DropHistoryLayerView(model: model, history: dropHistory, now: now)
                    .mask(islandMask)
                    .transition(.opacity)
            }

            // The Up Next surface: the playback queue, and where the sound comes out.
            //
            // Drawn in place of the player's own body, so `NowPlayingSlotView` keeps the flanks —
            // the island goes on saying what is playing while the user reads what is next.
            //
            // Gated against the drop history because neither layer draws a background of its own —
            // the island's black *is* the background — so two on at once is two sets of rows
            // interleaved rather than one covering the other.
            if model.contentPresentation == .expanded,
               model.isShowingNowPlayingQueue,
               !model.isShowingDropHistory,
               !model.isStowed,
               let nowPlaying = model.nowPlaying {
                NowPlayingQueueLayerView(model: model, controller: nowPlaying)
                    .mask(islandMask)
                    .transition(.opacity)
            }

            // The page indicator, on the open island only.
            //
            // Masked to the same outline as everything else, for the reason stated above the
            // activity layer: content drawn outside the island makes those pixels opaque to the
            // window server and starts swallowing clicks meant for the app underneath.
            //
            // Gated on `contentPresentation` rather than on `presentation`, so the strip arrives
            // and leaves on the content's clock — 40ms behind the container (§6.2). Gated on the
            // container instead, the dots would appear in an island that has not finished growing
            // and be clipped by the mask for the length of the morph.
            if model.contentShowsPageIndicator, !model.isStowed {
                IslandPageIndicatorLayerView(model: model)
                    .mask(islandMask)
                    .transition(.opacity)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            // The clock and the debug overlay, held still while the island leans. Neither is part
            // of the island: the clock draws nothing at all, and an overlay that reports the
            // island's geometry sliding 8pt while you are reading geometry off it is a diagnostic
            // arguing with itself.
            ZStack(alignment: .top) {
                // Zero-sized, drawing nothing, contributing no alpha and no hit region — see
                // `ActivityClock`. Outside the mask because there is nothing to mask, and running
                // it through one would be a claim that it drew something.
                ActivityClock(rate: model.clockRate) { instant in
                    now = instant
                }
                .frame(width: 0, height: 0)

                if model.debugVisible, let info = model.debugInfo {
                    DebugOverlayView(info: info, diagnostics: model.diagnostics, form: model.form)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// One page, drawn where the layer puts it.
    ///
    /// Extracted so the current page and its two neighbours are built by the same code: a carousel
    /// whose middle slot was written out longhand and whose edges were a second spelling is a
    /// carousel that drifts the first time a page gains an argument.
    @ViewBuilder
    private func page(_ page: IslandPage, glance: GlanceModel) -> some View {
        switch page {
        case .home:
            IslandHomeLayerView(
                model: model,
                glance: glance,
                nowPlaying: model.nowPlaying,
                content: model.nowPlayingContent,
                now: now
            )
        case .music:
            IslandMusicPageView(model: model, content: model.nowPlayingContent, now: now)
        case .weather:
            GlanceWeatherLayerView(model: model, glance: glance, now: now)
        }
    }

    /// What the body is currently drawing, as an identity a transition can key on.
    ///
    /// The schedule and a meeting are not pages, but they occupy the same box and swap with the pages,
    /// so they need to be distinguishable from them and from each other. Strings rather than an enum
    /// because nothing outside this view asks the question.
    private func pageIdentity(glance: GlanceModel) -> String {
        if glance.isShowingSchedule { return "schedule" }
        if model.presentedKind == .meeting { return "meeting" }
        return model.currentPage.rawValue
    }

    /// How one page gives way to the next.
    ///
    /// Asymmetric on purpose: the two halves travel in the *same* direction across the island, which
    /// is what makes it read as one strip moving rather than as two independent slides. Swiping left
    /// — forward — pulls the outgoing page off toward the leading edge and brings the incoming one
    /// in from the trailing edge, the way the content moved under the finger.
    ///
    /// **An offset of the island's own width, not `.move(edge:)`.** These views fill the *panel*,
    /// which is far larger than the island (§4.2) — so `.move` slid them by ~600pt, a travel three
    /// times the distance the eye expects and one that spends most of its time off the island
    /// entirely. A carousel steps by exactly one page.
    ///
    /// **Only while a turn is in flight** (`IslandPageModel.isTurning`). This layer is also inserted
    /// when the island *opens*, and sliding then is the island opening onto a page that flies in
    /// from the side: nothing was turned, so nothing should travel. Opening gets the crossfade every
    /// other surface in the island arrives on.
    ///
    /// Reduce Motion gets that crossfade too — §6.3's substitution, and the reason this is a
    /// transition rather than a fixed slide: travel is what the setting exists to remove.
    private var pageTransition: AnyTransition {
        // **A swipe already moved the page; this must not move it again.** The carousel slides the
        // whole strip by the offset and then swaps identities at the instant the incoming page is
        // exactly under the mask — so the arriving view is already in position, and a slide on its
        // insertion would take it back out and bring it in a second time. A crossfade between two
        // renders of the same pixels is invisible, which is what makes this the right answer rather
        // than a compromise. The dots keep the slide: a tap has no gesture behind it, so the travel
        // is the only thing that says which way the carousel moved.
        guard !model.swipe.isPaging else { return .opacity }
        guard !model.reduceMotion, model.page?.isTurning == true else { return .opacity }
        let width = model.contentMetrics.bodySize.width
        let forward = (model.page?.lastTurn ?? 1) >= 0
        return .asymmetric(
            insertion: .offset(x: forward ? width : -width),
            removal: .offset(x: forward ? -width : width)
        )
    }

    /// The island's own surface — its material, and nothing else.
    ///
    /// §6.4 used to decide this outright: pure black in a real cutout, Liquid Glass where the island
    /// floats. Both rules are still here, as `IslandStyle.automatic`, and both are still the default
    /// — what changed in Stage 7 is that they are now the *default* rather than the only answer.
    /// Which material that resolves to, on this display, with this user's accessibility settings, is
    /// `IslandStyle.material(for:notch:reduceTransparency:)`; what it looks like is
    /// `IslandMaterialView`. Neither is decided here, so there is one place to read each.
    ///
    /// The user's opacity rides on the material rather than on the mask, so the shape's alpha —
    /// which is what the window server derives our event shape from — scales with what is drawn.
    /// That is the property `synthesizedIslandOpacity`'s floor of 0.35 protects: the island stops
    /// being clickable at the point it stops having alpha, so it must not be possible to make it
    /// fainter than it is reachable. Increase Contrast overrides it to fully opaque — §6.3 makes
    /// that a correctness requirement, and a user who has asked the system for more contrast has
    /// already answered the question that slider asks. On a hardware notch it is 1 regardless: the
    /// slider is about a floating island and there is nothing in a cutout to dim.
    /// The island's own outline, as a mask for everything drawn inside it.
    ///
    /// **The leaning outline, not `metrics`.** The two were the same until the rebound started
    /// stretching content: a bar growing out with a stretching edge is a bar clipped by the shape
    /// the island *used* to be, so it would slide out from under itself. One helper rather than the
    /// seven copies this replaced, so the mask and the outline cannot drift.
    ///
    /// Identical to the old spelling whenever nothing is rebounding: the lean is zero at rest, and
    /// a zero lean is `metrics` exactly.
    private var islandMask: some View {
        leaningShape
    }

    /// The island's outline, leaning if it is at the end of a range.
    ///
    /// **The rebound, and the shape is the only thing it touches.** One edge grows away from where
    /// the island rests and the other is nailed down — inside `IslandShape`, off a single
    /// interpolated number, so the two cannot drift apart at any frame between the ends. The
    /// content is laid out against `contentMetrics` and does not move at all; the bar in the
    /// stretching sliver grows with the edge, which is `IslandScreenModel.bounceStretch(for:)`.
    ///
    /// It used to be this shape grown symmetrically and the *view* shifted by half the growth. That
    /// arithmetic is right at both endpoints and wrong in between — see `IslandShape.lean`, which
    /// is where the three hardware reports of the other end moving are recorded.
    ///
    /// **This is the one thing here that paints outside `islandPath`**, and it is the dangerous
    /// direction rather than the safe one — the re-entry scale is safe precisely because it only
    /// ever runs *smaller*, so every intermediate is a subset of what we accept. So the hit region
    /// carries an allowance for the travel: see `IslandScreenModel.hitRegionMetrics`, which is what
    /// the app shell sets the region from, and `AppDelegate.transition`, which widens to the same
    /// number.
    private var leaningShape: IslandShape {
        IslandShape(
            metrics: model.metrics,
            lean: model.limitLean,
            leansTrailing: model.limitLeansTrailing
        )
    }

    @ViewBuilder
    private var island: some View {
        // Minimal mode, and only ever on a synthesized island with nothing to say — see
        // `IslandScreenModel.drawsMaterial`. Drawing nothing rather than drawing at zero opacity,
        // because they are the same picture and the first is the one that costs no composite.
        if model.drawsMaterial {
            IslandMaterialView(
                material: model.material,
                // The **leaning** shape, which is `metrics` everywhere except during a rebound —
                // see `leaningShape`, which the mask uses too so the two cannot drift.
                shape: leaningShape,
                opacity: opacity,
                showsShadow: model.showsShadow,
                // The *animated* height, not the target one — `model.metrics` is what
                // `IslandShapeMetrics.lerp` is publishing on the spring, so the semi-glass fade
                // travels with the shape rather than snapping to where it is going. It is the same
                // rule `islandPath` follows for the hit region, for the same reason.
                height: model.metrics.bodySize.height,
                // The closed island's height, so the semi-glass tip can be absent at rest. At rest
                // the island *is* the cutout and its bottom edge is the bottom of the notch, where a
                // glass rim draws a white line across a hole.
                restingHeight: model.cutoutSize.height
            )
        }
    }

    private var opacity: Double {
        guard model.notchKind == .synthesized else { return 1 }
        return model.increaseContrast ? 1 : model.synthesizedOpacity
    }
}
