import IslandActivities
import IslandKit
import SwiftUI

/// The ten motion tokens (§6.1). Nothing in Isleta may write an inline `.animation(...)`.
///
/// Defined in Milestone 0 and deliberately unused: the island is static until §6 lands. They live
/// here now so that the first animation ever written reaches for a token rather than inventing a
/// duration, which is how divergent curves creep in.
public enum Motion {

    /// The user's animation speed. 1 is what all seven tokens below were tuned at.
    ///
    /// ## What "speed" means for a spring
    ///
    /// A spring has no duration to halve. What it has is a **response** — the period of the
    /// undamped oscillation, which is the time the animation takes to cover most of its distance —
    /// and a **damping fraction**, which is its *character*: how much it overshoots, whether it
    /// settles crisply or lolls in. So speed divides the response and leaves the damping alone.
    /// That is the only version that keeps the island recognizably the same object moving faster,
    /// rather than a different, twitchier one: raising damping to "tighten" a fast animation
    /// removes the overshoot that makes `expand` read as a spring at all, and the island at 2×
    /// would look like a resize rather than a morph.
    ///
    /// `contentSwap` and `nudge` are declared with durations because `.smooth` and `.bouncy` take
    /// one — a crossfade genuinely is a duration, and `.bouncy`'s duration is its response under a
    /// different name. Those divide too, which is what keeps all four tokens in proportion: §6.1's
    /// whole rule is that the island's dimensions travel on one spring, and a speed that reached
    /// three tokens and not the fourth would put the content on a different clock from the
    /// container it is following by 40ms.
    ///
    /// **`contentFollowDelay` is deliberately not scaled.** It is not part of the motion — it is the
    /// gap that makes the container read as leading, and at 2× a 20ms lead is below the frame
    /// interval on a 60Hz panel, which is no lead at all. It stays 40ms at every speed.
    ///
    /// `@MainActor` for `Haptics.isEnabled`'s reason: it is written once from the settings store on
    /// the main actor and read from views and models that are all already there.
    @MainActor public static var speed: Double = 1 {
        didSet { speed = MotionSpeed.clamp(speed) }
    }

    /// Compact to expanded. The container leads; content follows by `contentFollowDelay`.
    @MainActor public static var expand: Animation {
        .spring(response: MotionSpeed.scale(0.38, speed: speed), dampingFraction: 0.78)
    }

    /// Expanded to compact. Snappier and better damped than `expand` — collapsing should feel
    /// decisive, not like the island is falling back.
    @MainActor public static var collapse: Animation {
        .spring(response: MotionSpeed.scale(0.32, speed: speed), dampingFraction: 0.85)
    }

    /// Swapping the content of an activity without changing the container.
    @MainActor public static var contentSwap: Animation {
        .smooth(duration: MotionSpeed.scale(contentSwapSeconds, speed: speed))
    }

    /// `contentSwap`'s duration, in seconds, for the one caller that cannot take an `Animation`.
    ///
    /// **This is not a license to write durations.** It exists because the Now Playing equaliser is
    /// six `CALayer`s animated by the render server — the only thing in the app that is, and it is
    /// that for a measured 2 400× — and CoreAnimation takes a `CFTimeInterval` where SwiftUI takes a
    /// spring. Exposing the number the token is already built from is what keeps the bars sinking on
    /// the *same* curve length as every other content change, including under the user's animation
    /// speed. Inventing a second 0.22 beside it is exactly the divergence §6.1 exists to prevent, so
    /// `contentSwap` above reads this constant rather than repeating it.
    @MainActor public static var contentSwapDuration: TimeInterval {
        MotionSpeed.scale(contentSwapSeconds, speed: speed)
    }

    /// The tuned value behind both of the two above.
    private static let contentSwapSeconds: TimeInterval = 0.22

    /// An attention nudge that does not change state.
    ///
    /// **Two users, and the second stretched what this token is for.** It was written for a surface
    /// *inside* an island that is standing still — the recents drawer, a refusal — and it now also
    /// carries the island's own **lean at the end of a range**
    /// (`IslandScreenModel.limitBounce`): a level reaching its top or bottom springs the whole
    /// island a few points that way and back. That is the island moving, which everywhere else in
    /// this file means `expand` sideways or `reveal` downward — but neither of those is a *there and
    /// back*, and both are curves for a shape arriving somewhere it will stay. This is a refusal, in
    /// the sense the sentence above already claims, and 8pt over 0.30s reads as one whatever it is
    /// attached to. The harder bounce is what makes a travel that small legible at all.
    @MainActor public static var nudge: Animation {
        .bouncy(duration: MotionSpeed.scale(nudgeSeconds, speed: speed), extraBounce: 0.15)
    }

    /// `nudge`'s duration in seconds, for the one caller that has to schedule the *return* of a
    /// there-and-back.
    ///
    /// **The second exception to "no durations", and it is narrower than `contentSwapDuration`'s.**
    /// The lean at the end of a range goes out and comes home (`IslandScreenModel.limitBounce`), and
    /// the obvious way to write the second half is `withAnimation(_:completion:)` on the first. That
    /// is wrong in a way that only shows up off-screen: the completion fires **immediately** when
    /// there is no host animating the transaction, which is every test process — so the lean would
    /// be assigned and unassigned inside one synchronous call, correct on hardware and impossible to
    /// pin anywhere else. Scheduling the return against the token's own length keeps the two halves
    /// on one curve, under the user's animation speed, and observable.
    ///
    /// Reading the constant the token is already built from, never a second copy of it — the
    /// divergence §6.1 exists to prevent.
    @MainActor public static var nudgeDuration: Duration {
        .milliseconds(Int((MotionSpeed.scale(nudgeSeconds, speed: speed) * 1000).rounded()))
    }

    /// The tuned value behind both of the two above.
    private static let nudgeSeconds: TimeInterval = 0.30

    /// The island going into the notch at the lock, and coming out of it at the unlock — and the
    /// lock-screen padlock doing both between them.
    ///
    /// The fifth token, and the only one added after Milestone 0. It is `nudge`'s shape at more
    /// than twice the length: the lock is the one moment the island moves with nobody's hand on
    /// it, across a system animation that is itself unhurried, and at `nudge`'s 0.30s the owner's
    /// verdict was "definitely slower than that". A little less bounce than `nudge`, because a long
    /// spring that overshoots as much as a short one reads as wobbling rather than settling. Used
    /// for all four moves so the lock and the unlock are one curve played both ways.
    @MainActor public static var lockHandover: Animation {
        .bouncy(duration: MotionSpeed.scale(0.70, speed: speed), extraBounce: 0.10)
    }

    /// **The island's own outline growing downward.** The peek, the open, and the track lip.
    ///
    /// The sixth token, and the second one added after Milestone 0. The track lip asked for it and
    /// then the rest of the island claimed it, which is the right order for a token to arrive in:
    /// `expand` at `dampingFraction` 0.78 grows the shape and *arrives*, and the owner's verdict on
    /// hardware, 2026-08-27, was that anything coming down out of the bezel should go a little
    /// further than it means to and come back up. That is one movement — the notch dropping — and
    /// it now has one curve wherever it happens.
    ///
    /// **Downward specifically, and that is the whole selector.** `IslandScreenModel.apply` picks
    /// this whenever the island's *height* grows and leaves `expand` to the changes that only widen
    /// it, because the two do not read alike: a shape hanging off the bezel bouncing as it drops is
    /// the notch behaving like a physical thing, and the same bounce applied sideways is a wobble.
    ///
    /// **A step below `nudge`, deliberately, and they are not interchangeable.** `nudge` is a
    /// surface *inside* an island that is already there — the recents drawer, a refusal — and it
    /// bounces harder because it is small and lands against a container that is standing still.
    /// This one carries the island and everything drawn in it, and `lockHandover` already records
    /// what happens when a large slow shape overshoots as hard as a small quick one: it reads as
    /// wobbling rather than settling. It started at `extraBounce` 0.24, which was that, and came
    /// back to 0.12 on sight of it.
    ///
    /// Used in **both** directions, like `expand` was for any outline change that leaves the
    /// presentation alone: the island going back up is the same gesture answered a second time, and
    /// a tighter curve on the way out reads as a different, brisker event than the thing it is
    /// undoing.
    /// **Unhurried, and that is the second thing tuned about it.** It started at 0.34s, which was
    /// the same length as a hover peek, and on hardware the open read as the island snapping to its
    /// size rather than descending to it. At 0.42s the drop is long enough for the eye to follow the
    /// bottom edge down, which is what makes the overshoot read as weight rather than as a twitch.
    /// Still the shortest of the three bouncy tokens, and deliberately: `nudge`'s 0.30s is a smaller
    /// surface and `lockHandover`'s 0.70s is a move nobody's hand is on.
    @MainActor public static var reveal: Animation {
        .bouncy(duration: MotionSpeed.scale(0.42, speed: speed), extraBounce: 0.12)
    }

    /// **A page landing on its page.** The remaining inches of a swipe, and the island resizing
    /// for the page it turned to.
    ///
    /// The seventh token, and the first one that is deliberately **not a bounce**. Every other
    /// spring here overshoots on purpose, because everything else they move is arriving somewhere
    /// it was not — an island dropping out of the bezel, a surface being nudged, a lock handed
    /// over. A page is different in kind: it is a rail with detents, and the detent is where the
    /// content *already is* by the time the finger lets go. Overshooting one is the carousel
    /// sliding a few points past centre and coming back, which on hardware reads as the page
    /// missing its mark and correcting itself rather than as weight.
    ///
    /// `dampingFraction: 1` is critical damping — the fastest approach that never crosses the
    /// target — and it is the number, not a taste: anything below it has an overshoot, and the
    /// whole complaint this token answers is that the overshoot exists at all. What is tuned is the
    /// response: 0.30s, a little brisker than `expand`'s 0.38, because a critically damped spring
    /// spends its last stretch creeping and a page that is visibly still moving after a third of a
    /// second reads as slow.
    ///
    /// Used at **both** ends of a page turn — the offset finishing its crossing
    /// (`IslandSwipeModel.landTurn`), the offset going home when the swipe did not carry
    /// (`IslandSwipeModel.settle`), and the island's outline resizing for a page a dot in the
    /// indicator jumped to (`IslandScreenModel.setPageMetrics`). §6.1's rule is that one movement
    /// travels on one spring, and a page turn where the content settles flat while the outline
    /// bounces is two.
    @MainActor public static var pageTurn: Animation {
        .spring(response: MotionSpeed.scale(0.30, speed: speed), dampingFraction: 1)
    }

    /// **The edge of the island rebounding at the end of a range.** The eighth token, and the first
    /// one tuned for a movement that has to happen *several times a second*.
    ///
    /// Every other spring here moves something once and lets it settle, and their responses are
    /// chosen for that: `nudge`'s 0.30s is a drawer being nudged, `reveal`'s 0.42s is long enough
    /// for the eye to follow an edge down. This one answers a key the user is **holding**, and
    /// macOS repeats a volume key about ten times a second. Re-struck at that rate, a 0.30s spring
    /// never leaves its outward swing — the edge simply parks and the island reads as having stopped
    /// responding, which is the opposite of what a rebound is for. At 0.16s a strike is over before
    /// the next one lands, so a held key is a flutter and a single press is one clean beat.
    ///
    /// `dampingFraction: 0.55` is a real overshoot — more than `expand`'s 0.78 — because the travel
    /// is 8pt and a bounce that small is invisible without it. That is the same argument `nudge`
    /// makes for bouncing harder than `reveal`: the smaller the movement, the more character it
    /// needs to read as one.
    ///
    /// Not a variant of `nudge`, and the difference is not the number. `nudge` is an *attention*
    /// nudge — something the island does to be noticed. This is an *answer*: the user pushed, and
    /// there is nothing left to give. It fires only from `IslandScreenModel.limitBounce`.
    @MainActor public static var rebound: Animation {
        .spring(response: MotionSpeed.scale(reboundSeconds, speed: speed), dampingFraction: 0.55)
    }

    /// `rebound`'s response in seconds, for scheduling the return of a there-and-back.
    ///
    /// The same narrow exception `nudgeDuration` documents, for the same caller and the same reason:
    /// `withAnimation(_:completion:)` fires immediately where nothing is hosting the transaction.
    @MainActor public static var reboundDuration: Duration {
        .milliseconds(Int((MotionSpeed.scale(reboundSeconds, speed: speed) * 1000).rounded()))
    }

    /// **The rebound coming home**, and the half of it that must not overshoot.
    ///
    /// `rebound` is `dampingFraction` 0.55 because an 8pt strike is invisible without a real
    /// overshoot. Played backwards that same overshoot is a bug rather than a flourish: coming home
    /// means arriving at *zero*, and crossing zero puts the travel on the **other side** — the right
    /// edge stretches out, comes back, and then briefly stretches the left. Reported from hardware,
    /// 2026-08-29, as "the other side seems to still have a small bounce at the end of the
    /// animation". It was, and it was this.
    ///
    /// `dampingFraction: 1` is critical damping — the fastest approach that never crosses the
    /// target — and it is the same argument `pageTurn` makes, in the same words: the resting shape
    /// is a detent, and the detent is where the island already belongs. Same response as `rebound`,
    /// so the two halves are one movement at one speed rather than a fast strike and a slow crawl.
    @MainActor public static var reboundReturn: Animation {
        .spring(response: MotionSpeed.scale(reboundSeconds, speed: speed), dampingFraction: 1)
    }

    /// The tuned value behind all three of the above.
    private static let reboundSeconds: TimeInterval = 0.16

    /// **The island arriving at its widest**, which is nearly three times the travel of any other
    /// sideways move it makes.
    ///
    /// A HUD puts the island in `IslandFlanks.wide`: 185pt of cutout to 401pt of body, 108pt out on
    /// each side. Power reaches one span further — `.wider`, 459pt, 137 out each side — and takes
    /// the same curve, because the objection below is about the distance and power's is longer. `expand`'s 0.38s response was tuned against `flankedWidthGrowth`'s 40pt sliver,
    /// and at nearly three times the distance the same curve does not read as growing — it reads as
    /// the island *appearing*, full width, in one frame. The owner's verdict on hardware,
    /// 2026-08-29: "let's have a slightly slower animation out from the notch so it's not so jarring
    /// to the users."
    ///
    /// This is `lockHandover`'s argument at a smaller scale, and it is the third time this file has
    /// made it: a bigger shape needs a longer response, or it arrives rather than travels. It is
    /// deliberately not `lockHandover` itself — 0.70s is half the life of a HUD that expires in 1.5.
    ///
    /// **Damped above `expand`, not below.** `reveal` records the rule this obeys: a shape hanging
    /// off the bezel *dropping* should overshoot, and the same bounce applied sideways is a wobble.
    /// The wider the shape the worse that reads, so 0.86 — nearer `collapse`'s decisiveness than
    /// `expand`'s spring — and the island widens without wagging.
    @MainActor public static var widen: Animation {
        .spring(response: MotionSpeed.scale(0.50, speed: speed), dampingFraction: 0.86)
    }

    /// How far content lags the container during a morph (§6.2). The container must arrive first,
    /// otherwise the two read as separate animations rather than one object changing shape.
    public static let contentFollowDelay: Duration = .milliseconds(40)

    /// Substitutes a crossfade for a morph when the user has asked for reduced motion (§6.3).
    ///
    /// A correctness requirement, not polish: motion sensitivity is a real accessibility need, and
    /// the island's whole vocabulary is motion.
    @MainActor
    public static func respectingReduceMotion(
        _ animation: Animation,
        reduceMotion: Bool
    ) -> Animation {
        reduceMotion ? contentSwap : animation
    }

    /// The curve a change to what the island is saying travels on (§6.2).
    ///
    /// This is the whole reason `ActivityChange` exists as a value rather than as "something
    /// changed". §6.2 asks for two different things depending on whether the island is showing a
    /// *new* thing or the *same* thing differently, and getting it backwards is immediately
    /// obvious on screen in both directions:
    ///
    /// - **`contentChanged` is a crossfade** on `contentSwap`. A track change, a scrub, a volume
    ///   key pressed twice. If it morphed on `expand` instead, every seek would look like the
    ///   island closing and reopening — the single most common way these things are got wrong.
    /// - **`presented` and `swapped` are morphs** on `expand`. Something arrived that was not there
    ///   before; it should enter with the same curve the island itself grows on, because to the eye
    ///   it *is* the island changing shape.
    /// - **`dismissed` uses `collapse`**, matching the island's own closing curve: snappier and
    ///   better damped, because a thing going away should feel decided rather than reluctant. This
    ///   is the one place the mapping is not simply "morph", and it follows the same rule
    ///   `IslandScreenModel` already uses — which spring applies is decided by where the island
    ///   ends up, not by which input changed.
    /// - **`none` returns `nil`.** Not "an instant animation": a change that the island has nothing
    ///   to redraw for must not open an animation transaction at all, or a queued activity updating
    ///   in the background would put the presented one through a no-op transition every time.
    @MainActor
    public static func animation(for change: ActivityChange, reduceMotion: Bool) -> Animation? {
        let token: Animation
        switch change {
        case .none: return nil
        case .presented, .swapped: token = expand
        case .dismissed: token = collapse
        // A flank crossfading on the same token a track title uses. Deliberately not `expand`:
        // the outline does not move for a companion arriving into a sliver the island already
        // affords, and morphing it would be the whole island animating for 40pt of content.
        case .contentChanged, .companionChanged: token = contentSwap
        }
        return respectingReduceMotion(token, reduceMotion: reduceMotion)
    }
}
