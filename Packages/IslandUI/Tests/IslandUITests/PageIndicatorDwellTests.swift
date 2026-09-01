import CoreGraphics
import IslandKit
import Testing

@testable import IslandUI

/// The dots are a signpost, not a control bar: they say which of the three pages you have arrived
/// on, and then they go.
///
/// **Every test here runs on a model built with a dwell of a few milliseconds.**
/// `IslandPageModel.indicatorDwell` is two seconds — the number a person reads a row of three dots
/// in — and a suite that waited it out would spend a minute of its own to observe an interval it
/// cannot check the value of anyway. What is worth pinning is the *shape*: what lights the dots,
/// what holds them, and what takes them away.
@MainActor
@Suite("The page indicator's dwell")
struct PageIndicatorDwellTests {

    /// Comfortably longer than the dwell below, so a fade that is going to happen has happened.
    private static let dwell = Duration.milliseconds(20)

    private static let past = Duration.milliseconds(150)

    private func pages() -> IslandPageModel {
        IslandPageModel(indicatorDwell: Self.dwell)
    }

    private func waitPastTheDwell() async {
        try? await Task.sleep(for: Self.past)
    }

    /// The strip is drawn empty until something happens. An island that has just come up and a
    /// page that changed a minute ago are the same state, and neither is news.
    @Test("nothing is lit until something changes")
    func darkAtRest() {
        #expect(!pages().isIndicatorVisible)
    }

    @Test("a page turn lights the dots, and two seconds later they are gone")
    func aTurnLightsThemAndTheyFade() async {
        let model = pages()
        #expect(model.step(by: 1))
        #expect(model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }

    /// The dot in the row does what the swipe does. It is the same arrival.
    @Test("a jump to a page lights them too")
    func aJumpLightsThem() async {
        let model = pages()
        #expect(model.go(to: .weather))
        #expect(model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }

    /// A dot tapped on the page already showing turns nothing, so there is nothing to announce —
    /// the same guard that stops the shell running a whole transition for no visible difference.
    @Test("a turn that goes nowhere lights nothing")
    func aTurnToNowhereLightsNothing() {
        let model = pages()
        #expect(!model.go(to: .home))
        #expect(!model.step(by: 0))
        #expect(!model.isIndicatorVisible)
    }

    /// **The second turn's two seconds start at the second turn.** Each change restarts the clock,
    /// rather than the first one's fade landing in the middle of the third page.
    @Test("each change restarts the dwell")
    func eachChangeRestartsTheDwell() async {
        let model = pages()
        #expect(model.step(by: 1))
        try? await Task.sleep(for: .milliseconds(12))
        #expect(model.step(by: 1))
        // Past the *first* turn's fade, and the dots are still up because the second one moved it.
        try? await Task.sleep(for: .milliseconds(12))
        #expect(model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }

    /// A finger on the carousel is the one moment the dots are certainly being read, and a clock
    /// running underneath would take them away mid-gesture.
    @Test("a hold keeps them up with no clock running")
    func aHoldKeepsThem() async {
        let model = pages()
        model.holdIndicator()
        await waitPastTheDwell()
        #expect(model.isIndicatorVisible)

        model.releaseIndicator()
        #expect(model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }

    /// A hold taken *during* a dwell has to cancel it, or the gesture inherits whatever was left of
    /// the last turn's two seconds.
    @Test("a hold cancels a dwell already running")
    func aHoldCancelsTheDwell() async {
        let model = pages()
        #expect(model.step(by: 1))
        model.holdIndicator()
        await waitPastTheDwell()
        #expect(model.isIndicatorVisible)
    }

    /// A pointer leaving the strip long after the dots faded must not bring them back on its way
    /// out — the release says "the reason to hold them is over", not "show them".
    @Test("releasing when they are already gone brings nothing back")
    func aReleaseWithNothingToReleaseIsSilent() async {
        let model = pages()
        model.releaseIndicator()
        #expect(!model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }

    /// The island closing takes them at once. There is nothing drawn to fade, and a dwell left
    /// armed would leave the next open's dots already spent.
    @Test("closing the island takes them immediately")
    func closingTakesThem() {
        let model = pages()
        #expect(model.step(by: 1))
        model.reset()
        #expect(!model.isIndicatorVisible)
        // Back on the page it remembers, which after a step forward is the music page — see
        // `IslandPageModel.rememberedPage`. What this test is about is the dots, which go either way.
        #expect(model.current == .music)
    }

    @Test("hiding cancels the dwell rather than racing it")
    func hidingCancelsTheDwell() async {
        let model = pages()
        model.holdIndicator()
        model.hideIndicator()
        #expect(!model.isIndicatorVisible)
        await waitPastTheDwell()
        #expect(!model.isIndicatorVisible)
    }
}

/// What the island draws, as against what the page model believes.
@MainActor
@Suite("Whether the dots are drawn")
struct PageDotsVisibilityTests {

    private func model() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    /// §3's layering test: this package must draw with nothing wired.
    @Test("with no page model injected nothing is drawn")
    func nothingWithoutAPageModel() {
        #expect(!model().showsPageDots)
    }

    /// **Opening is the one appearance that is not a turn**, and it is the only one a person who
    /// has never swiped will see. Without it the row exists solely as the answer to a gesture
    /// nobody has been told about.
    @Test("opening the island lights the dots")
    func openingLightsThem() {
        let m = model()
        let pages = IslandPageModel()
        m.page = pages
        #expect(!m.showsPageDots)

        m.setExpanded(true, reduceMotion: true)
        #expect(m.showsPageDots)
    }

    /// Every screen is set expanded on every transition, and a re-arm on each would keep the dots
    /// alive on an island standing still.
    @Test("setting an open island open again does not re-light them")
    func reopeningAnOpenIslandLightsNothing() {
        let m = model()
        let pages = IslandPageModel()
        m.page = pages
        m.setExpanded(true, reduceMotion: true)
        pages.hideIndicator()

        m.setExpanded(true, reduceMotion: true)
        #expect(!m.showsPageDots)
    }

    /// A live swipe keeps them lit whatever the clock says: the carousel is being dragged, so the
    /// dots are being read.
    @Test("a live swipe draws them even after the dwell has passed")
    func aLiveSwipeDrawsThem() {
        let m = model()
        let pages = IslandPageModel()
        m.page = pages
        pages.hideIndicator()
        #expect(!m.showsPageDots)

        m.swipe.beginPaging(toward: nil, span: 368)
        #expect(m.showsPageDots)

        m.swipe.endPaging()
        #expect(!m.showsPageDots)
    }

    /// The dots come and go inside room that is already reserved, so nothing about the island's
    /// shape follows them. This is the whole reason the fade is an opacity and not a branch: the
    /// island's bottom edge — and the hit region pinned to it — must not move two seconds after the
    /// user stopped touching anything.
    @Test("the strip's height does not follow whether the dots are drawn")
    func theHeightDoesNotFollowTheDots() {
        let open = IslandShapeMetrics(
            bodySize: CGSize(width: 368, height: 200),
            topCornerRadius: 0,
            bottomCornerRadius: 22
        )
        let m = IslandScreenModel(
            metricsByForm: [.expanded: open, .expandedWithPageIndicator: open],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        let pages = IslandPageModel()
        m.page = pages
        m.setExpanded(true, reduceMotion: true)
        let body = m.contentBodySize.height
        let form = m.form
        #expect(m.showsPageDots)

        pages.hideIndicator()
        #expect(!m.showsPageDots)
        #expect(m.form == form)
        #expect(m.hasPageIndicator)
        #expect(m.contentBodySize.height == body)
    }
}
