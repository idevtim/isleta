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
        let roster = IslandPageRoster.all
        #expect(roster.next(after: .home) == .music)
        #expect(roster.next(after: .music) == .weather)
        #expect(roster.next(after: .weather) == .home)
    }

    @Test("two fingers right walks back the other way")
    func previousWraps() {
        let roster = IslandPageRoster.all
        #expect(roster.previous(before: .home) == .weather)
        #expect(roster.previous(before: .weather) == .music)
        #expect(roster.previous(before: .music) == .home)
    }

    /// `SwipeTracker.Outcome.commit(steps:)` carries an integer rather than a direction, so a flick
    /// fast enough to cross two pages says so in one sample.
    @Test("a multi-page step wraps in both directions", arguments: [-7, -4, -3, -2, -1, 0, 1, 2, 3, 4, 7])
    func steppingWraps(steps: Int) {
        let roster = IslandPageRoster.all
        for page in roster.pages {
            let landed = roster.stepped(from: page, by: steps)
            // Stepping by the count is the identity, so any step is congruent to one inside it.
            #expect(landed == roster.stepped(from: page, by: steps + roster.count))
            #expect(roster.contains(landed))
        }
    }

    /// The one that traps rather than wrapping if `%` is used without correcting its sign: Swift's
    /// remainder keeps the sign of the dividend, so `(0 - 1) % 3` is `-1` and indexes off the front.
    @Test("stepping back from the first page wraps rather than trapping")
    func steppingBackFromHome() {
        let roster = IslandPageRoster.all
        #expect(roster.stepped(from: .home, by: -1) == .weather)
        #expect(roster.stepped(from: .home, by: -3) == .home)
        #expect(roster.stepped(from: .home, by: -4) == .weather)
    }

    @Test("a step of nothing stays put")
    func zeroIsIdentity() {
        for page in IslandPageRoster.all.pages {
            #expect(IslandPageRoster.all.stepped(from: page, by: 0) == page)
        }
    }

    /// A jump has to slide the shorter way round, or it contradicts the row of dots that was
    /// clicked: home to weather is one step back, not two forward.
    @Test("the shortest signed path wraps rather than always going forward")
    func shortestStepsWrap() {
        let roster = IslandPageRoster.all
        #expect(roster.steps(from: .home, to: .home) == 0)
        #expect(roster.steps(from: .home, to: .music) == 1)
        #expect(roster.steps(from: .home, to: .weather) == -1)
        #expect(roster.steps(from: .weather, to: .home) == 1)
        #expect(roster.steps(from: .weather, to: .music) == -1)
        #expect(roster.steps(from: .music, to: .home) == -1)
    }

    /// Whatever it answers, walking that many steps has to land there — otherwise the slide goes one
    /// way and the page goes another.
    @Test("the shortest path actually reaches the page it is asked about")
    func shortestStepsLand() {
        let roster = IslandPageRoster.all
        for from in roster.pages {
            for to in roster.pages {
                #expect(roster.stepped(from: from, by: roster.steps(from: from, to: to)) == to)
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
        #expect(!model.step(by: model.roster.count))
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
        #expect(!model.step(by: model.roster.count))
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

/// The music page comes and goes with the music. `IslandPageRoster` argues why; this pins what.
@MainActor
@Suite("What is on the carousel")
struct IslandPageRosterTests {

    /// Nothing injected is every page — a preview and a test with no shell are not a Mac with
    /// nothing playing, and §3 says IslandUI has to be complete with nothing wired to it.
    @Test("a model nobody has told about the music has every page")
    func startsWithEveryPage() {
        #expect(IslandPageModel().roster.pages == IslandPage.allCases)
    }

    @Test("nothing playing takes the music page off the carousel")
    func silenceHidesMusic() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        #expect(model.roster.pages == [.home, .weather])
    }

    @Test("a track starting puts it back")
    func musicComesBack() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        model.setMusicAvailable(true)
        #expect(model.roster.pages == IslandPage.allCases)
    }

    /// **The two-page carousel still wraps**, in both directions, and both neighbours of home are
    /// the weather. That is what a two-page carousel is; the alternative is an end-stop the user
    /// has to learn.
    @Test("two pages wrap the way three do")
    func twoPagesWrap() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        #expect(model.page(steppedBy: 1) == .weather)
        #expect(model.page(steppedBy: -1) == .weather)
        #expect(model.page(steppedBy: 2) == .home)
        #expect(model.step(by: 1))
        #expect(model.current == .weather)
        #expect(model.step(by: 1))
        #expect(model.current == .home)
    }

    /// A swipe cannot land on a page that is not there. This is the one that would show up as the
    /// island turning to an empty player.
    @Test("a swipe never lands on the music page while nothing is playing")
    func swipeSkipsTheMusicPage() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        for steps in -6...6 {
            #expect(model.page(steppedBy: steps) != .music)
        }
    }

    /// Nor can a dot, or a menu row that raced the track ending. `go(to:)` is where every jump
    /// arrives, so refusing here is refusing everywhere.
    @Test("a jump to a page that is not on the carousel is refused")
    func goRefusesAPageThatIsNotThere() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        #expect(!model.go(to: .music))
        #expect(model.current == .home)
    }

    /// **The page under the user is never taken away.** A track ending while the player is open
    /// leaves the page where it is, saying "Not playing", rather than the island turning a page by
    /// itself because a song finished.
    @Test("the page you are standing on stays on the carousel")
    func standingOnMusicKeepsIt() {
        let model = IslandPageModel()
        #expect(model.go(to: .music))
        model.setMusicAvailable(false)
        #expect(model.current == .music)
        #expect(model.roster.contains(.music))
        #expect(model.roster.pages == IslandPage.allCases)
    }

    /// And it goes the moment they leave it — which is the other half of the same rule, and the
    /// reason it lives inside the model rather than in the shell that pushes the track.
    @Test("it goes when the user turns away from it")
    func leavingMusicDropsIt() {
        let model = IslandPageModel()
        #expect(model.go(to: .music))
        model.setMusicAvailable(false)
        #expect(model.go(to: .home))
        #expect(model.roster.pages == [.home, .weather])
    }

    /// The memory is kept and *resolved*: somebody who lives on the player still lives there, and
    /// comes back to it the next time there is something to play.
    @Test("closing on the music page with nothing playing comes back to home")
    func resetResolvesTheRememberedPage() {
        let model = IslandPageModel()
        #expect(model.go(to: .music))
        model.setMusicAvailable(false)
        #expect(model.pageAfterReset == .home)
        model.reset()
        #expect(model.current == .home)
        #expect(model.rememberedPage == .music, "the memory is kept, not corrected")
        #expect(model.roster.pages == [.home, .weather])

        // And the next track brings both back.
        model.setMusicAvailable(true)
        #expect(model.pageAfterReset == .music)
        model.reset()
        #expect(model.current == .music)
    }

    /// The shell asks `pageAfterReset` rather than comparing against `rememberedPage`, because the
    /// two differ in exactly the case that matters — see `AppDelegate.resetPageAfterClose`.
    @Test("a close from the music page has somewhere to go even though the memory agrees with it")
    func closeFromMusicMovesEvenWhenRemembered() {
        let model = IslandPageModel()
        #expect(model.go(to: .music))
        model.setMusicAvailable(false)
        #expect(model.current == model.rememberedPage)
        #expect(model.current != model.pageAfterReset)
    }

    /// Home is on every roster there is, so there is always a page to be on and always a page to
    /// come back to.
    @Test("home is never taken off the carousel")
    func homeIsAlwaysThere() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        #expect(model.roster.contains(.home))
        #expect(model.roster.contains(.weather))
    }

    /// A page that is not on the roster has nowhere to step from, and lands on home rather than
    /// trapping. Unreachable through the model — it keeps the current page on the roster — and
    /// pinned because the arithmetic is public and the alternative is an index off the front.
    @Test("stepping from a page that is not on the roster lands on home")
    func steppingFromAMissingPage() {
        let model = IslandPageModel()
        model.setMusicAvailable(false)
        let roster = model.roster
        #expect(roster.stepped(from: .music, by: 1) == .home)
        #expect(roster.steps(from: .music, to: .weather) == 0)
        #expect(roster.resolved(.music) == .home)
        #expect(roster.resolved(.weather) == .weather)
    }
}
