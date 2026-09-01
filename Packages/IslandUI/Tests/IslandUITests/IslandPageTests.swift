import Testing

@testable import IslandUI

@Suite("Island pages")
struct IslandPageTests {

    @Test("the pages run home → music → weather")
    func orderIsTheDeclaredOne() {
        #expect(IslandPage.allCases == [.home, .music, .weather])
    }

    @Test("two fingers left walks forward and comes back to home")
    func nextWraps() {
        #expect(IslandPage.home.next == .music)
        #expect(IslandPage.music.next == .weather)
        #expect(IslandPage.weather.next == .home)
    }

    @Test("two fingers right walks back the other way")
    func previousWraps() {
        #expect(IslandPage.home.previous == .weather)
        #expect(IslandPage.weather.previous == .music)
        #expect(IslandPage.music.previous == .home)
    }

    /// `SwipeTracker.Outcome.commit(steps:)` carries an integer rather than a direction, so a flick
    /// fast enough to cross two pages says so in one sample.
    @Test("a multi-page step wraps in both directions", arguments: [-7, -4, -3, -2, -1, 0, 1, 2, 3, 4, 7])
    func steppingWraps(steps: Int) {
        for page in IslandPage.allCases {
            let landed = page.stepped(by: steps)
            // Stepping by the count is the identity, so any step is congruent to one inside it.
            #expect(landed == page.stepped(by: steps + IslandPage.allCases.count))
            #expect(IslandPage.allCases.contains(landed))
        }
    }

    /// The one that traps rather than wrapping if `%` is used without correcting its sign: Swift's
    /// remainder keeps the sign of the dividend, so `(0 - 1) % 3` is `-1` and indexes off the front.
    @Test("stepping back from the first page wraps rather than trapping")
    func steppingBackFromHome() {
        #expect(IslandPage.home.stepped(by: -1) == .weather)
        #expect(IslandPage.home.stepped(by: -3) == .home)
        #expect(IslandPage.home.stepped(by: -4) == .weather)
    }

    @Test("a step of nothing stays put")
    func zeroIsIdentity() {
        for page in IslandPage.allCases {
            #expect(page.stepped(by: 0) == page)
        }
    }

    /// A jump has to slide the shorter way round, or it contradicts the row of dots that was
    /// clicked: home to weather is one step back, not two forward.
    @Test("the shortest signed path wraps rather than always going forward")
    func shortestStepsWrap() {
        #expect(IslandPage.home.steps(to: .home) == 0)
        #expect(IslandPage.home.steps(to: .music) == 1)
        #expect(IslandPage.home.steps(to: .weather) == -1)
        #expect(IslandPage.weather.steps(to: .home) == 1)
        #expect(IslandPage.weather.steps(to: .music) == -1)
        #expect(IslandPage.music.steps(to: .home) == -1)
    }

    /// Whatever it answers, walking that many steps has to land there — otherwise the slide goes one
    /// way and the page goes another.
    @Test("the shortest path actually reaches the page it is asked about")
    func shortestStepsLand() {
        for from in IslandPage.allCases {
            for to in IslandPage.allCases {
                #expect(from.stepped(by: from.steps(to: to)) == to)
            }
        }
    }

    @Test("every page has a name to speak")
    func everyPageIsSpoken() {
        for page in IslandPage.allCases {
            #expect(!page.spokenName.isEmpty)
        }
    }
}

@MainActor
@Suite("The page the island is on")
struct IslandPageModelTests {

    @Test("the island opens on home")
    func startsAtHome() {
        #expect(IslandPageModel().current == .home)
    }

    @Test("a committed swipe turns the page and says that it did")
    func steppingReportsTheChange() {
        let model = IslandPageModel()
        #expect(model.step(by: 1))
        #expect(model.current == .music)
        #expect(model.step(by: -1))
        #expect(model.current == .home)
    }

    /// The indicator's dots call `go(to:)`, and the one the user is already on has to be a no-op —
    /// otherwise tapping it runs the whole widen-then-tighten transition for no visible change.
    @Test("going to the page already showing changes nothing and reports so")
    func goingNowhereIsANoOp() {
        let model = IslandPageModel()
        #expect(!model.go(to: .home))
        #expect(model.go(to: .weather))
        #expect(!model.go(to: .weather))
    }

    @Test("a step of nothing is not a change")
    func zeroStepIsNotAChange() {
        let model = IslandPageModel()
        #expect(!model.step(by: 0))
        #expect(!model.step(by: IslandPage.allCases.count))
    }

    /// **The direction is published separately from the page, and that separation is the fix.**
    /// SwiftUI builds a removal transition from the departing view's *last* render, so a direction
    /// written at the same moment as the page reaches the arriving half only — and on a reversal the
    /// two halves travel toward each other and collide.
    @Test("turning a page does not touch the direction")
    func turningDoesNotPublishDirection() {
        let model = IslandPageModel()
        #expect(model.lastTurn == 1)
        model.step(by: -1)
        #expect(model.current == .weather)
        // Still forward: nothing published a new direction, so the departing page's transition —
        // already built from the last render — and this one still agree.
        #expect(model.lastTurn == 1)
    }

    /// The return value is what lets the caller skip a wasted render: a direction already on screen
    /// needs no second one, which is why a swipe pays no frame and only a reversed dot does.
    @Test("publishing a direction reports only an actual change")
    func publishingReportsChange() {
        let model = IslandPageModel()
        #expect(!model.setTurnDirection(1))
        #expect(model.setTurnDirection(-1))
        #expect(model.lastTurn == -1)
        #expect(!model.setTurnDirection(-1))
        // Any negative is back, any non-negative is forward — callers pass a step count straight in.
        #expect(model.setTurnDirection(3))
        #expect(model.lastTurn == 1)
        #expect(model.setTurnDirection(-9))
        #expect(model.lastTurn == -1)
    }

    /// A turn that changes nothing must not move the page either.
    @Test("a turn of nothing changes nothing")
    func noOpChangesNothing() {
        let model = IslandPageModel()
        model.setTurnDirection(-1)
        #expect(!model.step(by: 0))
        #expect(!model.step(by: IslandPage.allCases.count))
        #expect(!model.go(to: model.current))
        #expect(model.current == .home)
        #expect(model.lastTurn == -1)
    }

    /// **A turn slides; the page layer arriving with the island does not.** The block that draws a
    /// page is inserted when the island opens, and a directional slide there is the island opening
    /// onto a page that flies in from the side.
    @Test("a fresh page model is not mid-turn")
    func startsNotTurning() {
        #expect(!IslandPageModel().isTurning)
    }

    /// **A closed island comes back to where you were, unless where you were was the weather.**
    /// Home and music are where a person lives; the weather is a thing you go and look at and are
    /// then finished with, and a forecast fetched a quarter of an hour ago is the one page that can
    /// be stale on arrival. See `IslandPageModel.rememberedPage`.
    @Test("closing on the weather comes back to where you were before it")
    func resetSkipsTheWeather() {
        let model = IslandPageModel()
        model.go(to: .weather)
        model.reset()
        #expect(model.current == .home)
    }

    @Test("a fresh model comes back to home")
    func remembersHomeToBeginWith() {
        let model = IslandPageModel()
        #expect(model.rememberedPage == .home)
        model.reset()
        #expect(model.current == .home)
    }

    /// Somebody who keeps the island on the player is answering the question every time they
    /// reopen it.
    @Test("closing on the music page comes back to the music page")
    func remembersMusic() {
        let model = IslandPageModel()
        model.go(to: .music)
        model.reset()
        #expect(model.rememberedPage == .music)
        #expect(model.current == .music)
    }

    /// The weather is never *written* to the memory — it leaves whatever was there standing. So
    /// music → weather → close comes back to music, which is the answer somebody who went to look
    /// at the forecast would give.
    @Test("a trip to the weather leaves the memory alone")
    func theWeatherDoesNotOverwriteTheMemory() {
        let model = IslandPageModel()
        model.go(to: .music)
        model.go(to: .weather)
        #expect(model.rememberedPage == .music)
        model.reset()
        #expect(model.current == .music)

        // And going back to home replaces it, because home is a page worth coming back to.
        model.go(to: .home)
        #expect(model.rememberedPage == .home)
    }

    /// A swipe remembers exactly as a dot does — one function does both, so a route added later
    /// cannot quietly skip it.
    @Test("a swipe remembers what a dot remembers")
    func stepRemembersToo() {
        let model = IslandPageModel()
        #expect(model.step(by: 1))
        #expect(model.current == .music)
        #expect(model.rememberedPage == .music)

        #expect(model.step(by: 1))
        #expect(model.current == .weather)
        #expect(model.rememberedPage == .music)
    }

    @Test("paging is allowed by default and can be taken away")
    func turningCanBeSuspended() {
        let model = IslandPageModel()
        #expect(model.canTurn)
        model.canTurn = false
        #expect(!model.canTurn)
    }
}
