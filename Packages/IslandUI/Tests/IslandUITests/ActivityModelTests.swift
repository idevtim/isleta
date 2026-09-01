import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import SwiftUI
import Testing

@testable import IslandUI

// The tokens became main-actor when they gained a user-settable speed (`Motion.speed`, which is
// `@MainActor` for `Haptics.isEnabled`'s reason). The suite follows them rather than the value being
// made `nonisolated(unsafe)` to keep a test convenient.
@MainActor
@Suite("Activity motion tokens")
struct ActivityMotionTests {

    /// The mapping §6.2 turns on, and the one that is obviously wrong on screen in both directions:
    /// a morph where a crossfade belongs makes every track change look like the island reopening.
    @Test("each kind of change gets the curve it means")
    func tokens() {
        #expect(Motion.animation(for: .presented("a"), reduceMotion: false) == Motion.expand)
        #expect(Motion.animation(for: .swapped(from: "a", to: "b"), reduceMotion: false) == Motion.expand)
        #expect(Motion.animation(for: .dismissed("a"), reduceMotion: false) == Motion.collapse)
        #expect(Motion.animation(for: .contentChanged("a"), reduceMotion: false) == Motion.contentSwap)
    }

    /// Not "an instant animation": a change the island has nothing to redraw for must not open a
    /// transaction at all, or an update to a *queued* activity puts the presented one through a
    /// no-op transition.
    @Test("a change the island cannot see opens no animation")
    func noneIsNil() {
        #expect(Motion.animation(for: .none, reduceMotion: false) == nil)
        #expect(Motion.animation(for: .none, reduceMotion: true) == nil)
    }

    @Test("reduce motion substitutes a crossfade for every morph")
    func reduceMotion() {
        #expect(Motion.animation(for: .presented("a"), reduceMotion: true) == Motion.contentSwap)
        #expect(Motion.animation(for: .swapped(from: "a", to: "b"), reduceMotion: true) == Motion.contentSwap)
        #expect(Motion.animation(for: .dismissed("a"), reduceMotion: true) == Motion.contentSwap)
        #expect(Motion.animation(for: .contentChanged("a"), reduceMotion: true) == Motion.contentSwap)
    }
}

@Suite("Activities on the screen model")
@MainActor
struct ActivityScreenModelTests {

    private static let cutout = CGSize(width: 185, height: 32)

    private func makeModel() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(bodySize: Self.cutout, topCornerRadius: 0, bottomCornerRadius: 8),
                .peek: IslandShapeMetrics(bodySize: CGSize(width: 197, height: 40), topCornerRadius: 0, bottomCornerRadius: 8),
                .flankedRest: IslandShapeMetrics(bodySize: CGSize(width: 265, height: 32), topCornerRadius: 0, bottomCornerRadius: 8),
                .flankedPeek: IslandShapeMetrics(bodySize: CGSize(width: 277, height: 40), topCornerRadius: 0, bottomCornerRadius: 8),
                .expanded: IslandShapeMetrics(bodySize: CGSize(width: 380, height: 140), topCornerRadius: 0, bottomCornerRadius: 22),
            ],
            notchKind: .hardware,
            cutoutSize: Self.cutout
        )
    }

    private func settle(_ body: (@escaping @MainActor () -> Void) -> Void) async {
        await withCheckedContinuation { continuation in
            body { continuation.resume() }
        }
    }

    /// Longer than `Motion.contentFollowDelay`, so the hop has certainly landed. The test is about
    /// the ordering, not about the exact 40ms.
    private func waitForContentToFollow() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Music starting on an empty, closed island springs sideways out of the cutout on the
    /// unlock's own token; everything else keeps `Motion.animation(for:)`.
    @Test("Now Playing taking an empty stage arrives like the unlock")
    func nowPlayingArrivesLikeTheUnlock() async {
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        let stage = ActivityStage(primary: playing, primaryFlank: .leading)
        #expect(IslandScreenModel.arrivesLikeTheUnlock(.presented(playing.id), stage: stage))
        #expect(!IslandScreenModel.arrivesLikeTheUnlock(.swapped(from: "hud", to: playing.id), stage: stage))
        #expect(!IslandScreenModel.arrivesLikeTheUnlock(.contentChanged(playing.id), stage: stage))
        #expect(!IslandScreenModel.arrivesLikeTheUnlock(.presented(playing.id), stage: nil))

        // And it lands settled: the spring's target is full width, whatever it traveled from.
        let model = makeModel()
        await settle { model.setActivity(playing.presentations, change: .presented(playing.id), reduceMotion: false, completion: $0) }
        #expect(model.reentry == 1)
    }

    /// **A device connecting arrives the same way, and did not until 2026-08-29.** It had `expand`,
    /// which morphs the cutout to the *standard* flanked width — a much shorter move than either
    /// neighbour, so beside a HUD's `Motion.widen` and music's spring it read as arriving already
    /// finished. Reported as "it just appeared".
    @Test("a device connecting takes an empty stage the same way music does")
    func deviceConnectedArrivesLikeTheUnlock() async {
        let device = BuiltInActivity.deviceConnected(BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 100, single: 0)))
        let stage = ActivityStage(primary: device, primaryFlank: .leading)
        #expect(IslandScreenModel.arrivesLikeTheUnlock(.presented(device.id), stage: stage))
        // A reconnect of the device already on stage is the same activity saying something new —
        // it crossfades, and springing the island sideways for it would be the island arriving
        // twice for one connect.
        #expect(!IslandScreenModel.arrivesLikeTheUnlock(.contentChanged(device.id), stage: stage))

        let model = makeModel()
        await settle { model.setActivity(device.presentations, change: .presented(device.id), reduceMotion: false, completion: $0) }
        #expect(model.reentry == 1)
    }

    /// The other side of the line, and the reason it is not "every arrival springs". A welcome back
    /// is a *word* in the sliver, and text springing sideways out of a cutout smears.
    @Test("a kind whose slivers carry words keeps the plain morph")
    func wordsDoNotSpringSideways() {
        let greeting = BuiltInActivity.welcomeBack(greeting: "Welcome back")
        let stage = ActivityStage(primary: greeting, primaryFlank: .leading)
        #expect(!IslandScreenModel.arrivesLikeTheUnlock(.presented(greeting.id), stage: stage))
    }

    @Test("an activity arriving, changing and leaving")
    func lifecycle() async {
        let model = makeModel()
        #expect(model.presentations == nil)

        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        await settle { model.setActivity(playing.presentations, change: .presented(playing.id), reduceMotion: true, completion: $0) }
        #expect(model.presentations == playing.presentations)

        let next = BuiltInActivity.nowPlaying(title: "Windowlicker", artist: "Aphex Twin")
        await settle { model.setActivity(next.presentations, change: .contentChanged(next.id), reduceMotion: true, completion: $0) }
        #expect(model.presentations?.expanded.title == "Windowlicker")

        await settle { model.setActivity(nil, change: .dismissed(next.id), reduceMotion: true, completion: $0) }
        #expect(model.presentations == nil)
    }

    /// The completion tightens the hit region back to the exact shape. `.none` is the case most
    /// likely to be skipped, and skipping it would leave the region permanently widened.
    @Test("the completion fires even for a change the island cannot see")
    func completionAlwaysFires() async {
        let model = makeModel()
        await settle { model.setActivity(nil, change: .none, reduceMotion: true, completion: $0) }
        #expect(model.presentations == nil)
    }

    /// §6.2: the container leads and the content follows by 40ms. The failure this pins down is the
    /// content arriving *first* — laying the expanded body out before the island has grown to hold
    /// it, which reads as two animations rather than one object changing shape.
    @Test("the content follows the container rather than leading it")
    func contentFollowsContainer() async throws {
        let model = makeModel()
        #expect(model.contentPresentation == .rest)

        model.setExpanded(true, reduceMotion: false)
        // The container is already there; the content is deliberately not.
        #expect(model.presentation == .expanded)
        #expect(model.contentPresentation == .rest)
        #expect(model.contentMetrics.bodySize == Self.cutout)

        try await waitForContentToFollow()
        #expect(model.contentPresentation == .expanded)
        #expect(model.contentMetrics.bodySize == CGSize(width: 380, height: 140))
    }

    /// A crossfade that begins 40ms after the thing it is crossfading from has already changed size
    /// is a two-step animation — which is what the substitution exists to get rid of.
    @Test("reduce motion drops the follow delay entirely")
    func reduceMotionSkipsTheDelay() {
        let model = makeModel()
        model.setExpanded(true, reduceMotion: true)
        #expect(model.contentPresentation == .expanded)
    }

    /// A pointer that crosses the island and leaves inside 40ms must not land the outgoing hop
    /// after the incoming one, which would leave the content laid out for a state the island is no
    /// longer in.
    @Test("a transition that reverses inside the delay cancels the pending follow")
    func reversalCancelsTheFollow() async throws {
        let model = makeModel()
        model.setHovering(true, reduceMotion: false)
        model.setHovering(false, reduceMotion: false)

        try await waitForContentToFollow()
        #expect(model.presentation == .rest)
        #expect(model.contentPresentation == .rest)
    }

    /// The layout the views actually resolve against, end to end: the flanks arrive with the
    /// activity, and the body region only when the island opens.
    @Test("the model's slot layout follows the content's metrics, not the container's")
    func slotLayoutFollowsContent() async throws {
        let model = makeModel()
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        model.setActivity(playing.presentations, change: .presented(playing.id), reduceMotion: true)
        // Flanked rest: two 40pt slivers, and still nothing below the cutout.
        #expect(model.slotLayout.affordsFlanks)
        #expect(!model.slotLayout.affordsBody)
        #expect(!model.needsClock)

        model.setExpanded(true, reduceMotion: false)
        // 40ms in which the container has grown and the content has not.
        #expect(!model.slotLayout.affordsBody)

        try await waitForContentToFollow()
        #expect(model.slotLayout.affordsFlanks)
        #expect(model.slotLayout.affordsBody)
    }

    /// The point of the whole flanked variant: an activity with something to say in the slivers is
    /// visible with no click and no pointer anywhere near the island.
    @Test("an activity with flank content widens the resting island")
    func flankContentWidensRest() async {
        let model = makeModel()
        #expect(model.form == .rest)
        #expect(model.slotLayout.isBlind)

        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        await settle {
            model.setActivity(
                playing.presentations, change: .presented(playing.id), reduceMotion: true, completion: $0
            )
        }
        #expect(model.hasFlankContent)
        #expect(model.form == .flankedRest)
        #expect(model.metrics.bodySize == CGSize(width: 265, height: 32))
        #expect(model.slotLayout.affordsFlanks)
        #expect(model.slotLayout.leading?.width == 40)
        #expect(!model.slotLayout.isBlind)

        // ...and back to the bare cutout when it leaves, with nothing left widened.
        await settle {
            model.setActivity(nil, change: .dismissed(playing.id), reduceMotion: true, completion: $0)
        }
        #expect(!model.hasFlankContent)
        #expect(model.form == .rest)
        #expect(model.slotLayout.isBlind)
    }

    /// Flanked-ness is an input, so hovering a flanked island reaches the flanked peek rather than
    /// the bare one — the two inputs compose instead of one overriding the other.
    @Test("hovering a flanked island peeks to the flanked size")
    func flankedPeek() async {
        let model = makeModel()
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        await settle {
            model.setActivity(
                playing.presentations, change: .presented(playing.id), reduceMotion: true, completion: $0
            )
        }
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.presentation == .peek)
        #expect(model.form == .flankedPeek)
        #expect(model.metrics.bodySize == CGSize(width: 277, height: 40))

        // Opening collapses the flank input: the open island is one shape however it got there.
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(model.form == .expandedWithPageIndicator)
    }

    /// An activity that says nothing in either flank must not widen the island — 80pt of black for
    /// no content is the worst of both answers.
    @Test("an activity with empty flanks leaves the island at the cutout")
    func emptyFlanksDoNotWiden() async {
        let model = makeModel()
        let bodyOnly = ActivityPresentations(
            compact: ActivityContent(symbol: "bolt.fill"),
            expanded: ActivityContent(symbol: "bolt.fill", title: "Nothing in the flanks")
        )
        await settle { model.setActivity(bodyOnly, change: .presented("a"), reduceMotion: true, completion: $0) }
        #expect(!model.hasFlankContent)
        #expect(model.form == .rest)
        #expect(model.slotLayout.isBlind)
    }

    /// One flank is enough — `welcomeBack` fills only the leading one, and an island that stayed
    /// at the cutout for it would show nothing at all.
    @Test("one flank is enough to widen the island")
    func oneFlankIsEnough() async {
        let model = makeModel()
        let welcome = BuiltInActivity.welcomeBack(greeting: "Welcome back")
        #expect(welcome.presentations.trailing.isEmpty)
        await settle {
            model.setActivity(
                welcome.presentations, change: .presented(welcome.id), reduceMotion: true, completion: $0
            )
        }
        #expect(model.form == .flankedRest)
    }

    /// §6.2 applies to this morph too: an activity arriving grows the container, so the content has
    /// to follow it by 40ms rather than appear in slivers the island has not grown yet.
    @Test("the flanks follow the container by the content delay")
    func flanksFollowTheContainer() async throws {
        let model = makeModel()
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        model.setActivity(playing.presentations, change: .presented(playing.id), reduceMotion: false)

        // The container is already flanked; the content is deliberately still laid out for the cutout.
        #expect(model.form == .flankedRest)
        #expect(model.contentForm == .rest)
        #expect(model.slotLayout.isBlind)

        try await waitForContentToFollow()
        #expect(model.contentForm == .flankedRest)
        #expect(model.slotLayout.affordsFlanks)
    }

    /// A track title moving on does not move the outline, so nothing has to follow anything — and
    /// the app shell reads the same fact to decide whether the hit region needs widening at all.
    @Test("a content change with the flanks unchanged does not move the container")
    func contentChangeLeavesTheOutlineAlone() async throws {
        let model = makeModel()
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin")
        model.setActivity(playing.presentations, change: .presented(playing.id), reduceMotion: true)

        let next = BuiltInActivity.nowPlaying(title: "Windowlicker", artist: "Aphex Twin")
        #expect(IslandScreenModel.hasFlankContent(in: ActivityStage.lone(next.presentations)) == model.hasFlankContent)

        model.setActivity(next.presentations, change: .contentChanged(next.id), reduceMotion: false)
        #expect(model.form == .flankedRest)
        #expect(model.contentForm == .flankedRest)
        #expect(model.metrics == model.metricsByForm[.flankedRest])
    }
}

@MainActor
@Suite("Stowing the content away")
struct StowRevealTests {

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    @Test("the scale keeps the spring's overshoot at both ends")
    func scaleDoesNotClampTheBounce() {
        // The bounce *is* the overshoot. Clamping at 1 threw away the swell on the way out and
        // clamping at 0 threw away the squash on the way in, which is why the stow settled flat
        // while the unstow sprang.
        #expect(IslandScreenModel.stowScale(1.1) > 1)
        #expect(IslandScreenModel.stowScale(-0.1) < IslandScreenModel.stowScale(0))
    }

    @Test("a spring that has gone wrong cannot invert or fling the content")
    func scaleIsBounded() {
        // The remaining bounds shape nothing; they exist so a runaway value cannot mirror the
        // content or throw it off the island.
        for value in stride(from: -8.0, through: 8.0, by: 0.25) {
            let scale = IslandScreenModel.stowScale(value)
            #expect(scale > 0)
            #expect(scale <= 1.2)
        }
    }

    @Test("opacity is clamped, because an opacity overshoot is not a bounce")
    func opacityIsClamped() {
        #expect(IslandScreenModel.stowOpacity(1.4, isStowed: false) == 1)
        #expect(IslandScreenModel.stowOpacity(-0.4, isStowed: false) == 0)
        #expect(IslandScreenModel.stowOpacity(0.5, isStowed: false) == 0.5)
        #expect(IslandScreenModel.stowOpacity(1.4, isStowed: true) == 1)
        #expect(IslandScreenModel.stowOpacity(-0.4, isStowed: true) == 0)
    }

    @Test("the widgets clear out early on the way in, and track the reveal on the way out")
    func fadeIsAsymmetric() {
        // Content riding the bounce all the way down reads as debris being pulled into the notch
        // rather than as the island putting it away, so going in the fade finishes first.
        #expect(IslandScreenModel.stowOpacity(0.5, isStowed: true) == 0)
        #expect(IslandScreenModel.stowOpacity(0.75, isStowed: true) == 0.5)
        // Coming back it simply follows, which is the arrival that already looked right.
        #expect(IslandScreenModel.stowOpacity(0.5, isStowed: false) == 0.5)
        // At every point, going away is at least as faded as coming back.
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(IslandScreenModel.stowOpacity(value, isStowed: true)
                    <= IslandScreenModel.stowOpacity(value, isStowed: false) + 1e-9)
        }
    }

    @Test("the outline never scales above one, whatever the spring does")
    func outlineNeverOvershoots() {
        // `islandPath` does not follow this scale. An outline drawn larger than the path paints
        // island the app then refuses — a click there reaches us, is dropped, and never falls
        // through to whatever is underneath. Smaller is harmless.
        for value in stride(from: -3.0, through: 3.0, by: 0.05) {
            #expect(IslandScreenModel.stowOutlineScale(value) <= 1)
            #expect(IslandScreenModel.stowOutlineScale(value) > 0)
        }
        // And it still springs: it is the same curve with the top taken off, not a flat line.
        #expect(IslandScreenModel.stowOutlineScale(0) < IslandScreenModel.stowOutlineScale(0.5))
        #expect(IslandScreenModel.stowOutlineScale(1) == 1)
    }

    @Test("stowing hides the content and narrows the island, without touching what is on stage")
    func stowingIsNotDismissing() {
        // The activity stays on the coordinator's stack — a swipe that silently ended a
        // notification is not a gesture anyone could afford to make by accident.
        let m = model()
        m.setStowed(true, reduceMotion: true)
        #expect(m.isStowed)
        #expect(!m.hasFlankContent)
        #expect(m.stowReveal == 0)
    }

    @Test("unstowing starts the content visible rather than at nothing")
    func unstowStartsVisible() {
        // At zero the widgets are invisible until the spring has carried them far enough to see,
        // while an outline still growing back from the cutout is clipping them as well — which read
        // as the content arriving late.
        let m = model()
        m.setStowed(true, reduceMotion: true)
        m.setStowed(false, reduceMotion: true)
        #expect(!m.isStowed)
        #expect(m.stowReveal == 1)
    }

    @Test("reduce motion arrives at the same place without animating")
    func reduceMotionSettlesImmediately() {
        let m = model()
        m.setStowed(true, reduceMotion: true)
        #expect(m.stowReveal == 0)
        m.setStowed(false, reduceMotion: true)
        #expect(m.stowReveal == 1)
    }
}

@MainActor
@Suite("The stowed border springs with its content")
struct StowOutlineTests {

    private func model() -> IslandScreenModel {
        let m = IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        m.setActivity(
            BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations,
            kind: .nowPlaying,
            change: .none,
            reduceMotion: true
        )
        return m
    }

    @Test("stowing empties the flanks, which is what narrows the border")
    func stowingNarrowsTheIsland() {
        // The outline is drawn from `metrics`, which derives from `form`, which derives from
        // `hasFlankContent`. That chain is why setting `isStowed` outside an animation made the
        // border snap while the content sprang — the width change had no animation attached to it.
        let m = model()
        #expect(m.hasFlankContent)
        m.setStowed(true, reduceMotion: true)
        #expect(!m.hasFlankContent)
        m.setStowed(false, reduceMotion: true)
        #expect(m.hasFlankContent)
    }

    @Test("the flag and the reveal always agree once the gesture has settled")
    func flagAndRevealAgree() {
        // They are set in the same transaction now. If they ever disagreed at rest, the island would
        // be sitting narrow with its content shown, or wide with nothing in it.
        let m = model()
        m.setStowed(true, reduceMotion: true)
        #expect(m.isStowed && m.stowReveal == 0)
        m.setStowed(false, reduceMotion: true)
        #expect(!m.isStowed && m.stowReveal == 1)
    }

    @Test("stowing twice does nothing the second time")
    func stowingIsIdempotent() {
        let m = model()
        m.setStowed(true, reduceMotion: true)
        let reveal = m.stowReveal
        m.setStowed(true, reduceMotion: true)
        #expect(m.stowReveal == reveal)
        #expect(m.isStowed)
    }
}

@MainActor
@Suite("Unstowing brings the layout back with it")
struct StowContentFormTests {

    private func model(hovering: Bool) -> IslandScreenModel {
        let m = IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        m.setActivity(
            BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations,
            kind: .nowPlaying,
            change: .none,
            reduceMotion: true
        )
        if hovering { m.setHovering(true, reduceMotion: true) }
        return m
    }

    @Test("the content layout follows a stow, not just a hover")
    func contentFormFollowsStowing() {
        // The bug this pins: `slotLayout` derives from `contentForm`, which only moved on a hover,
        // an expansion or a new activity. Stowing changes the island's form without any of those, so
        // after unstowing the border grew back while the layout was still the unflanked one — which
        // affords no room to draw — and the widgets stayed invisible until an unrelated hover change
        // refreshed it.
        let m = model(hovering: true)
        let flankedWhileShowing = m.contentForm.isFlanked
        #expect(flankedWhileShowing)

        m.setStowed(true, reduceMotion: true)
        #expect(!m.contentForm.isFlanked)

        m.setStowed(false, reduceMotion: true)
        #expect(m.contentForm.isFlanked, "the layout stayed stowed, so there is nowhere to draw")
    }

    @Test("the form and the content form agree once a stow has settled")
    func formsAgreeAtRest() {
        // They are allowed to disagree *during* a morph — that is §6.2's container-leads-content —
        // but not once it is over, or the island is one shape and its contents are laid out for
        // another.
        for hovering in [false, true] {
            let m = model(hovering: hovering)
            m.setStowed(true, reduceMotion: true)
            #expect(m.contentForm == m.form)
            m.setStowed(false, reduceMotion: true)
            #expect(m.contentForm == m.form)
        }
    }
}

@MainActor
@Suite("An empty island does not announce itself")
struct EmptyReentryTests {

    private func model(withActivity: Bool) -> IslandScreenModel {
        let m = IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        if withActivity {
            m.setActivity(
                BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations,
                kind: .nowPlaying,
                change: .none,
                reduceMotion: true
            )
        }
        return m
    }

    @Test("a space change does not bounce an island with nothing on it")
    func emptyIslandDoesNotBounce() {
        // An empty island is the bare cutout. Bouncing it on every space change is the app
        // announcing itself about a place where nothing has happened.
        let m = model(withActivity: false)
        m.hideForReentry(reduceMotion: false)
        #expect(m.reentry == 1, "the bare cutout was hidden, so it has a bounce to play")
        m.playReentry(reduceMotion: false)
        #expect(m.reentry == 1)
    }

    @Test("a stowed island does not bounce either")
    func stowedIslandDoesNotBounce() {
        // It has an activity, and is deliberately not drawing it. The bare cutout should behave the
        // same whichever way it got there.
        let m = model(withActivity: true)
        m.setStowed(true, reduceMotion: true)
        m.hideForReentry(reduceMotion: false)
        #expect(m.reentry == 1)
    }

    @Test("an island that is showing something still bounces")
    func contentfulIslandBounces() {
        // The re-entry covers the window server handing the panel back mid-transition. With content
        // on screen, that is a real interruption worth covering.
        let m = model(withActivity: true)
        m.hideForReentry(reduceMotion: false)
        #expect(m.reentry == 0)
        m.playReentry(reduceMotion: false)
        #expect(m.reentry == 1)
    }

    @Test("reduce motion never hides the island, whatever is on it")
    func reduceMotionSkipsTheHide() {
        for withActivity in [false, true] {
            let m = model(withActivity: withActivity)
            m.hideForReentry(reduceMotion: true)
            #expect(m.reentry == 1)
        }
    }
}

@MainActor
@Suite("An arriving activity is always visible")
struct ArrivalVisibilityTests {

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    private var playing: ActivityPresentations {
        BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations
    }

    @Test("an activity arriving into a hidden island makes it visible again")
    func arrivalRestoresVisibility() {
        // The reported bug: quit the music app and the widgets go, reopen it and press play and
        // nothing appears until the notch is clicked. `reentry` had been left at zero by whatever
        // took the island off screen — the lock, or a space change whose return was skipped because
        // there was nothing to bring back — and the new content was drawn at a third of its size
        // with no opacity.
        let m = model()
        m.hideForReentry(reduceMotion: false)
        // Empty, so hiding is a no-op and the island is already visible.
        #expect(m.reentry == 1)

        // Force the state the lock leaves behind, then let an activity arrive into it.
        m.collapseIntoNotch()
        #expect(m.reentry == 0)
        m.setActivity(playing, kind: .nowPlaying, change: .presented("probe"), reduceMotion: true)
        #expect(m.reentry == 1, "the arriving activity was drawn into a hidden island")
    }

    @Test("an activity going away does not force the island visible")
    func dismissalDoesNotRestore() {
        // Only an arrival restores. A dismissal into a hidden island has nothing to show, and
        // forcing visibility there would undo a hide that is still meant to be in effect.
        let m = model()
        m.setActivity(playing, kind: .nowPlaying, change: .presented("probe"), reduceMotion: true)
        m.collapseIntoNotch()
        m.setActivity(nil, kind: nil, change: .dismissed("probe"), reduceMotion: true)
        #expect(m.reentry == 0)
    }

    @Test("an arrival into a visible island leaves the bounce alone")
    func arrivalDoesNotInterruptAReturn() {
        // Mid-bounce, `reentry` is between 0 and 1 and belongs to the spring. Only a value pinned at
        // exactly zero is the stuck state this repairs.
        let m = model()
        m.setActivity(playing, kind: .nowPlaying, change: .presented("probe"), reduceMotion: true)
        #expect(m.reentry == 1)
    }
}
