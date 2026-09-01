import Foundation
import Observation

/// The pages the open island turns between, and the order a swipe walks them in.
///
/// Three surfaces the user *browses*, as distinct from the activities that *arrive*. An activity
/// takes the stage because something happened — a volume key, a timer finishing, a call — and says
/// its piece in the flanks or in the body it brought with it. A page is what the island shows when
/// nothing has happened and somebody opened it to look: the day, what is playing, what it is doing
/// outside.
///
/// ## Why this is an enum and not the activity roster
///
/// It was the roster, through the switcher row: every activity on the stack got a chip, and the row
/// was how you moved between them. That made "what can I look at" a function of what had recently
/// happened, so the calendar and the weather were reachable only while something was holding them
/// on the stack — and the row grew a bell, a gear and a weather shortcut that were not activities at
/// all, because the three things a person actually wants are not the three things that happen to
/// have arrived.
///
/// The pages are fixed, so they are always all there, and the gesture that moves between them is the
/// one every other paged surface on the platform uses.
///
/// ## The order wraps
///
/// `home → music → weather → home`. Three is few enough that wrapping is quicker than backtracking
/// from either end, and a carousel that stopped dead at the weather would need a rubber-band the
/// user has to learn to read. `SwipeBounds` is therefore open in both directions — see
/// `SwipeController`.
public enum IslandPage: String, CaseIterable, Sendable {

    /// The day on the right, what is playing on the left. Where the island opens until it is told
    /// otherwise — see `IslandPageModel.rememberedPage`, which lets somebody who lives on the
    /// player keep it.
    ///
    /// It is first because it is the answer to the question people open the island with, and because
    /// it is the only page that says two things at once — a glance at it is a glance at both.
    case home

    /// The full player: artwork, the scrubber, the transport.
    case music

    /// The forecast.
    case weather

    /// The next page along, wrapping. Two fingers left.
    public var next: IslandPage {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The previous page, wrapping. Two fingers right.
    public var previous: IslandPage {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + all.count - 1) % all.count]
    }

    /// The page `steps` along, wrapping in either direction.
    ///
    /// Takes any integer rather than ±1, because that is what `SwipeTracker.Outcome.commit(steps:)`
    /// carries — a flick fast enough to cross two pages says so in one sample, and clamping it here
    /// would make the gesture's own arithmetic a lie. Negative steps go backwards; zero is a no-op.
    public func stepped(by steps: Int) -> IslandPage {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let count = all.count
        // `%` in Swift keeps the sign of the dividend, so a negative step needs the extra `+ count`
        // before the second modulo — without it, stepping back from `.home` traps on a negative
        // index rather than wrapping to `.weather`.
        let wrapped = ((index + steps) % count + count) % count
        return all[wrapped]
    }

    /// The fewest steps from here to `page`, signed, wrapping.
    ///
    /// Used to give a **jump** a direction. A swipe already has one — it is the way the finger went
    /// — but a dot in the indicator does not, and a page that slid in from the right when the
    /// shorter way round was to the left would contradict the row of dots the user just clicked.
    /// Home to weather is one step back, not two forward.
    ///
    /// Ties go forward. With an even number of pages the opposite page is equidistant either way,
    /// and forward is the direction the carousel is described in.
    public func steps(to page: IslandPage) -> Int {
        let all = Self.allCases
        guard let from = all.firstIndex(of: self), let to = all.firstIndex(of: page) else { return 0 }
        let count = all.count
        let forward = (to - from + count) % count
        let backward = forward - count
        return forward <= -backward ? forward : backward
    }

    /// What VoiceOver calls this page, and what the indicator's dots are labelled with.
    public var spokenName: String {
        switch self {
        case .home: islandText("page.home", "Today")
        case .music: islandText("page.music", "Music")
        case .weather: islandText("page.weather", "Weather")
        }
    }
}

/// Which page the open island is on.
///
/// **One instance for the whole app, pushed into every `IslandScreenModel` by the shell**, for the
/// reason `NowPlayingController` and `GlanceModel` are: there is one user looking at one page, and a
/// page per display would let the laptop and an external monitor disagree about where the user is —
/// with no answer to which one is right.
///
/// Deliberately **not** a stored property on `IslandScreenModel`. Everything there is an input to
/// *that screen's* shape; this is an app-wide answer that every screen reads.
@MainActor
@Observable
public final class IslandPageModel {

    /// The page on screen. Written by the swipe and by the indicator's dots, and by nothing else.
    public private(set) var current: IslandPage = .home

    /// The page a closing island will come back to.
    ///
    /// **The island remembers where you were, with one exception, and the exception is the point.**
    /// It used to reopen on `.home` always, on the argument that reopening onto the weather because
    /// that is where somebody stood three hours ago is the island deciding what they came back for.
    /// That argument is right about the *weather* and wrong about the other two: home and music are
    /// where a person lives — one is the day, the other is what is playing — and somebody who keeps
    /// the island on the player is answering the question every time they reopen it.
    ///
    /// The weather is different in kind. It is a thing you go and look at and are then finished
    /// with; there is no state of the world in which "check the forecast" is a standing preference,
    /// and a forecast fetched a quarter of an hour ago is the one page that can be stale on arrival.
    ///
    /// So it is never *written* here — a turn to the weather leaves whatever was remembered
    /// standing, rather than resetting it to home. Closing on the weather therefore comes back to
    /// wherever you were before you went to look at it, which is the answer somebody who swiped
    /// home → weather and somebody who swiped music → weather would each give.
    ///
    /// **Session-scoped, deliberately.** It is not in `IsletaConfiguration` and is not persisted:
    /// appending a stored property to that struct is the cross-package memory-layout trap CLAUDE.md
    /// documents, and it belongs in a change that is only that. This is a menu-bar agent that runs
    /// for weeks, so in practice the memory outlives every session it needs to.
    public private(set) var rememberedPage: IslandPage = .home

    /// Which way the page is travelling: `+1` forward, `-1` back.
    ///
    /// **The page transition needs a direction, and the page value alone does not carry one.** A
    /// carousel that always slid in from the right would contradict the gesture half the time — a
    /// swipe right has to bring the previous page in from the left, or the island reads as ignoring
    /// which way the finger went. `IslandRootView` turns this into the pair of edges the insertion
    /// and removal travel between.
    ///
    /// ## It is published *before* the page changes, and that is the whole of `setTurnDirection`
    ///
    /// SwiftUI builds an **insertion** transition from the arriving view's first render and a
    /// **removal** transition from the departing view's *last* one — which happened before the page
    /// changed. So a direction written at the same moment as the page reaches the arriving half only:
    /// the departing page leaves on whatever direction was current a moment ago.
    ///
    /// While you keep swiping the same way that is invisible, because the two agree. Reverse, and
    /// the outgoing page slides toward the edge the incoming one is arriving from and they cross
    /// over each other — reported as the two views colliding going one way and never the other,
    /// which is exactly the asymmetry a stale direction produces.
    ///
    /// Starts at `+1` so a first turn with no history slides the way the carousel is described.
    public private(set) var lastTurn = 1

    /// Whether a page turn's animation is in flight.
    ///
    /// **The page layer slides only while this is true, and appears the rest of the time.** The
    /// block that draws a page is inserted when the island *opens*, and a directional slide on that
    /// insertion is the island opening onto a page that flies in from the side — reported from use,
    /// and wrong: nothing was turned, so nothing should travel. It is a page *turn* that has a
    /// direction, not the page's existence.
    ///
    /// Set by the shell around the turn and cleared when the island has finished resizing for it,
    /// which is strictly after the content transition it gates has run.
    public var isTurning = false

    /// Whether the island is allowed to turn pages at all right now.
    ///
    /// False while a full-body surface the user opened is up — the month grid, the drop history, Up
    /// Next, the shelf. Those own the body and carry their own way out, so a horizontal swipe over
    /// one of them is not a request for the next page; it is a gesture with nowhere to go. Pushed by
    /// the shell, which is the only thing that knows what is drawn.
    public var canTurn = true

    // MARK: - How long the dots stay

    /// How long the row of dots stays on screen after the page has settled, before it fades.
    ///
    /// **The dots are a signpost, not a control bar.** They were drawn for as long as the island was
    /// open, which put three permanent marks under every page — and a page indicator that is always
    /// there is saying "there are three pages" to somebody who has not moved for a minute and is
    /// reading a forecast. The information is only ever news at the moment the page *changes*: which
    /// of the three you have arrived on, and that there are others either side.
    ///
    /// **1.2s, and it was 2.** Two seconds is what a row of three dots is *read* in, and on hardware
    /// that turned out to be the wrong measurement: nobody reads the dots, they glance at them, and
    /// the interval that matters is how long the island goes on wearing a mark after the user has
    /// finished with it. At 2s the fade began after the eye had already moved to the page. Reported
    /// from use, 2026-08-29.
    ///
    /// It is not a motion token and deliberately does not scale with `Motion.speed`: the *fade* is
    /// motion and travels on `Motion.contentSwap` like every other content change, but this is a
    /// person glancing, and glancing does not get faster because the animations do.
    public static let indicatorDwell: Duration = .milliseconds(1_200)

    /// This model's dwell. An initializer parameter rather than a read of the constant above, so a
    /// test can watch the whole cycle without spending two seconds of a suite on each one.
    @ObservationIgnored private let dwell: Duration

    /// Whether the dots are drawn.
    ///
    /// **Not the same question as whether the island wears the strip.** The strip's *height* belongs
    /// to `IslandForm.showsPageIndicator` and is reserved for as long as the island is open — see
    /// `IslandPageIndicatorLayout.height` for why that number cannot follow its contents. This is
    /// only whether anything is drawn in the room already set aside, so the dots coming and going
    /// never move the island's bottom edge or the hit region pinned to it.
    ///
    /// Read through `IslandScreenModel.showsPageDots`, which ors it with a live swipe.
    public private(set) var isIndicatorVisible = false

    /// The pending fade. At most one, cancelled by whatever restarts the dwell.
    @ObservationIgnored private var indicatorFade: Task<Void, Never>?

    public init(indicatorDwell: Duration = IslandPageModel.indicatorDwell) {
        self.dwell = indicatorDwell
    }

    /// Show the dots, and start the clock that takes them away.
    ///
    /// Called wherever the page the user is looking at becomes news: a turn, a dot, and the island
    /// opening onto a page.
    public func showIndicator() {
        isIndicatorVisible = true
        startDwell()
    }

    /// Show the dots and keep them, until `releaseIndicator()` says the reason is over.
    ///
    /// For the two states with a hand in them — a finger mid-swipe, a pointer resting on the strip —
    /// where a clock running underneath would take the dots away while the user is using them.
    public func holdIndicator() {
        indicatorFade?.cancel()
        indicatorFade = nil
        isIndicatorVisible = true
    }

    /// Whatever was holding them has let go: the dwell starts from here.
    ///
    /// Silent when the dots are already gone, so a pointer leaving the strip long after they faded
    /// does not bring them back on its way out.
    public func releaseIndicator() {
        guard isIndicatorVisible else { return }
        startDwell()
    }

    /// Take them away now, with no dwell. For the island closing.
    public func hideIndicator() {
        indicatorFade?.cancel()
        indicatorFade = nil
        isIndicatorVisible = false
    }

    /// Arms the fade, cancelling any fade already armed.
    ///
    /// A `Task` rather than a `Timer`: §9 forbids a `Timer` for animation and this is not one — it
    /// is a single sleep that exists only between a page change and its fade, and it is cancelled
    /// rather than left to fire into a closed island. Nothing is armed at rest.
    private func startDwell() {
        indicatorFade?.cancel()
        let dwell = self.dwell
        indicatorFade = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            self?.isIndicatorVisible = false
        }
    }

    /// Publishes which way the next turn will travel, and says whether that was news.
    ///
    /// Called before the page itself changes — see `lastTurn`. The return value is what lets the
    /// caller skip a wasted render: `false` means the departing page's transition was already built
    /// with this direction, so the turn can happen immediately.
    @discardableResult
    public func setTurnDirection(_ direction: Int) -> Bool {
        let normalized = direction >= 0 ? 1 : -1
        guard normalized != lastTurn else { return false }
        lastTurn = normalized
        return true
    }

    /// Goes to a page directly — what a dot in the indicator does.
    ///
    /// Returns whether the page actually changed, so the caller can skip the animation and the
    /// height change for a tap on the dot the user is already on.
    @discardableResult
    public func go(to page: IslandPage) -> Bool {
        guard page != current else { return false }
        arrive(at: page)
        return true
    }

    /// Turns `steps` pages, wrapping. What a committed swipe does.
    @discardableResult
    public func step(by steps: Int) -> Bool {
        guard steps != 0 else { return false }
        let destination = current.stepped(by: steps)
        guard destination != current else { return false }
        arrive(at: destination)
        return true
    }

    /// The half both routes share: land on the page, say so with the dots, and remember it if it is
    /// a page worth coming back to.
    ///
    /// One function rather than three lines written twice, because the third line is the one that
    /// is easy to forget — a page change added later that skipped it would leave the island
    /// reopening somewhere the user has not been for hours, with nothing on screen to explain it.
    private func arrive(at page: IslandPage) {
        current = page
        if page != .weather { rememberedPage = page }
        showIndicator()
    }

    /// Puts the island back on the page it opens on.
    ///
    /// Called when the island closes. Reopening onto the weather because that is where somebody was
    /// three hours ago is the island deciding what they came back for — the same argument that
    /// closes the month grid and the drop history on the way out.
    public func reset() {
        current = rememberedPage
        // The dots go with the island rather than fading inside a shape that is no longer drawn —
        // and, more to the point, so that the next open is their next appearance.
        hideIndicator()
    }
}
