import Foundation
import IslandActivities
import IslandKit
import SwiftUI

/// Places an activity's slots on the island.
///
/// Everything here is positioning; `ActivityContentView` decides what a slot looks like and
/// `ActivitySlotLayout` decides where it can go. The one thing this view knows that neither of
/// those does is where the island body sits inside the panel — the panel is a fixed rectangle far
/// larger than the island (§4.2), so a slot's rect has to be offset by `IslandLayout.bodyOrigin`
/// before it means anything on screen.
///
/// ## The morph (§6.2)
///
/// Three mechanisms, separate because they animate different things:
///
/// - **`matchedGeometryEffect` on the symbol**, between the compact badge and the expanded well.
///   The glyph is the one object demonstrably the same before and after, so it travels rather than
///   crossfading. Everything else in those two layouts is genuinely different content.
/// - **`.transition(.opacity)` on a flank**, which is what a flank becoming afforded looks like —
///   the slivers arriving as the island grows past the cutout.
/// - **`.contentTransition(.opacity)` inside a slot** for `ActivityChange.contentChanged`, where
///   the slot stays and only its text moves on.
///
/// None of the three names a curve. The curve is whatever animation opened the transaction —
/// `Motion.expand` for the container, `Motion.contentSwap` for a content swap — which is how one
/// token drives a size change, a slot appearing and a string changing as one event instead of three.
///
/// ## Why the body slot is an `if`/`else` and the flanks are not
///
/// The two body slots are written as the two branches of one condition, with no explicit
/// transition, and that shape is load-bearing rather than stylistic. `matchedGeometryEffect`
/// requires exactly one live view to be the source of a geometry group at any moment. A conditional
/// removes one branch and inserts the other in a single transaction, so the id never has two
/// claimants. Driving the same switch from a collection — a `ForEach` over the visible slots, which
/// is the obvious way to write this — gives the outgoing view a removal transition, leaves both
/// alive for its duration, and SwiftUI then has two inserted views claiming one id: it picks one,
/// logs, and the glyph animates from the wrong place. The flanks carry no matched geometry, so they
/// are free to have explicit transitions.
struct ActivityLayerView: View {

    let model: IslandScreenModel
    let namespace: Namespace.ID

    /// The instant every time-dependent value on screen is formatted at. One value for the whole
    /// island so two counters cannot straddle a second boundary and disagree.
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let layout = model.slotLayout
            // The width and nothing else. The origin is a function of the width alone, and the slot
            // frames come from `slotLayout` — so reading the whole shape here would tie this layer
            // to the frame clock for the length of every page drag, which is the only thing in this
            // app that moves `contentMetrics` per frame. See `IslandScreenModel.contentBodyWidth`.
            let origin = IslandLayout.bodyOrigin(bodyWidth: model.contentBodyWidth, in: proxy.size)

            ZStack(alignment: .topLeading) {
                // Drawn whether or not it is stowed: `stowReveal` fades and scales it away, and a
                // view removed outright has nothing to animate — the content would vanish on the
                // frame the swipe committed instead of retracting into the notch. The activity is
                // untouched on the coordinator's stack throughout; only its visibility moves.
                if let stage = model.stage {
                    // Asked once, from the one place that decides it. These conditions used to be
                    // spelled out again here, which is how an open island kept drawing its flanks
                    // after `visibleSlots` had already been taught not to: the cover and the
                    // equaliser appeared twice, 40pt apart. A second copy of a rule is a second
                    // place for it to be wrong.
                    let visible = layout.visibleSlots(
                        for: model.contentPresentation,
                        in: stage,
                        showsTrackLip: model.contentShowsTrackLip
                    )

                    // `.transition(.opacity)` is what makes the flanks fade rather than vanish when
                    // the island opens, and fade back in as it closes. It works because the change
                    // arrives inside the same animated transaction as the morph — see
                    // `IslandScreenModel.setExpanded`.
                    if visible.contains(.leading), let frame = layout.leading {
                        slot(.leading, of: stage, in: frame, offsetBy: origin, matched: false)
                            .transition(.opacity)
                    }
                    if visible.contains(.trailing), let frame = layout.trailing {
                        slot(.trailing, of: stage, in: frame, offsetBy: origin, matched: false)
                            .transition(.opacity)
                    }
                    // The Up Next surface takes the body while it is up — the flanks keep the
                    // cover and the equaliser, and the body is the queue's. Two views in the same
                    // rectangle is not a layered effect, it is text on text.
                    //
                    // **And a page takes it on exactly the same terms.** Most surfaces that draw
                    // their own body publish an *empty* `expanded` slot, so `bodySlot` answers nil
                    // and this stands down without being told — the glance and the shelf both work
                    // that way. Now Playing does not: its expanded slot is the whole player. So
                    // without `pagesOwnBody` the home page and the player were composited on top of
                    // one another, a scrubber drawn through the middle of the calendar.
                    if let bodySlot = layout.bodySlot(
                        for: model.contentPresentation,
                        in: stage.primary.presentations,
                        showsTrackLip: model.contentShowsTrackLip
                       ),
                       let frame = layout.body,
                       !model.isShowingNowPlayingQueue,
                       !model.pagesOwnBody {
                        if bodySlot == .expanded {
                            slot(.expanded, of: stage, in: frame, offsetBy: origin, matched: true)
                        } else {
                            slot(.compact, of: stage, in: frame, offsetBy: origin, matched: true)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    /// - Parameter matched: whether this slot participates in the compact-to-expanded morph. Only
    ///   the body slots do. A flank and the expanded body are on screen at the same time, and two
    ///   live views claiming one geometry id is a SwiftUI error rather than a design choice.
    private func slot(
        _ slot: ActivitySlot,
        of stage: ActivityStage,
        in frame: CGRect,
        offsetBy origin: CGPoint,
        matched: Bool
    ) -> some View {
        content(slot, of: stage, matched: matched)
            .frame(width: frame.width, height: frame.height)
            // **Plus the rebound**, which moves the sliver on the stretching side and nothing else —
            // see `IslandScreenModel.bounceOffset(for:)`. The edge alone is black on black and
            // invisible; what a person actually sees move is the bar, or the glyph and its word.
            .offset(
                x: origin.x + frame.minX + model.bounceOffset(for: slot),
                y: origin.y + frame.minY
            )
    }

    /// Which renderer draws a slot.
    ///
    /// The "bespoke view keyed on `ActivityKind`" escape hatch that IslandActivities' README
    /// sanctions in place of letting an activity smuggle an `AnyView` through the model layer. Two
    /// kinds take it, and both for the same reason — what they draw is not sayable in a vocabulary
    /// of symbols and strings: Now Playing's album art and moving equaliser, the timer's radial
    /// ring, which the generic renderer would draw as a scrub bar, and a connected device's picture
    /// and battery arc. Everything else still renders through `ActivityContentView`.
    ///
    /// Three kinds take it now. A `NowPlayingController` is required rather than optional here: without one there is no cover
    /// image, no transport and no scrub state, so the bespoke view would have nothing bespoke to
    /// draw and the generic one is the correct answer rather than a degraded one.
    ///
    /// **The kind is resolved per slot, not once per island.** It used to read
    /// `model.presentedKind`, which was correct while one activity owned all four slots and is
    /// wrong the moment a companion holds a flank: a timer beside music would be handed to
    /// `NowPlayingSlotView` and drawn as a cover and an equaliser. That failure renders *plausibly*
    /// — a view appears, in the right sliver, at the right size — so nothing about it looks broken
    /// until you read what is in it.
    @ViewBuilder
    private func content(
        _ slot: ActivitySlot,
        of stage: ActivityStage,
        matched: Bool
    ) -> some View {
        if stage.kind(for: slot) == .deviceConnected {
            DeviceConnectSlotView(
                content: stage.content(for: slot),
                slot: slot,
                increaseContrast: model.increaseContrast,
                reduceMotion: model.reduceMotion
            )
        } else if stage.kind(for: slot) == .timer {
            TimerSlotView(
                content: stage.content(for: slot),
                slot: slot,
                increaseContrast: model.increaseContrast,
                reduceMotion: model.reduceMotion,
                now: now
            )
        } else if stage.kind(for: slot) == .nowPlaying, let controller = model.nowPlaying {
            NowPlayingSlotView(
                content: stage.content(for: slot),
                slot: slot,
                controller: controller,
                increaseContrast: model.increaseContrast,
                reduceMotion: model.reduceMotion,
                now: now,
                namespace: matched ? namespace : nil,
                icons: model.applicationIcons
            )
        } else {
            ActivityContentView(
                content: stage.content(for: slot),
                slot: slot,
                increaseContrast: model.increaseContrast,
                reduceMotion: model.reduceMotion,
                now: now,
                namespace: matched ? namespace : nil,
                icons: model.applicationIcons,
                // A bar stretches where everything else moves — see
                // `IslandScreenModel.bounceStretch(for:)`. The two are exclusive: a slot that
                // stretches gets no offset, and vice versa. The travel springs and the anchor does
                // not, which is what keeps the far end of the bar out of it.
                levelStretch: model.bounceStretch(for: slot),
                levelStretchAnchor: model.bounceStretchAnchor
            )
        }
    }
}
