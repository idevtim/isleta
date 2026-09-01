import Foundation

/// One activity's place on the stack.
///
/// `sequence` and `deadline` are the stack's business, not the activity's: an activity describes
/// *what* it is and *how long it stays relevant*, and only the stack knows when it arrived or what
/// that turned its relative expiry into.
public struct ActivityEntry: Sendable, Identifiable {

    public let activity: any IslandActivity

    /// Arrival order, monotonically increasing and never reused. This is the tie-breaker that makes
    /// the ordering a strict *total* order rather than a partial one — which matters because
    /// `Array.sort` is not stable, so a comparator that returns "neither precedes the other" for
    /// two same-priority entries would let the presented activity change identity on an unrelated
    /// insertion.
    public let sequence: UInt64

    public let insertedAt: Date

    /// Resolved from `activity.expiry` at insertion. `nil` for `.never`.
    ///
    /// Settable inside the package for exactly one reason: `ActivityStack.releasePointerHold`. A
    /// deadline that passed while the pointer was resting on the island is a deadline nobody was
    /// given a chance to act on, so the pointer leaving hands the entry its dwell back rather than
    /// sweeping it. Nothing else rewrites it — an activity presented under one `dwellScale` keeps
    /// the deadline it was given, which is a rule stated at length on that property.
    public internal(set) var deadline: Date?

    public var id: ActivityID { activity.id }

    public func hasExpired(at now: Date) -> Bool {
        guard let deadline else { return false }
        return deadline <= now
    }
}

/// A user's swipe, holding one activity at the head of the order for a while (§5).
///
/// The pin is an **input to the ordering**, in the same sense `isFlanked` and `isHovering` are
/// inputs elsewhere in this codebase — never a stored "currently presented" field. `presented` is
/// still defined as the head of the order; the pin only changes what sorts to the head.
///
/// **It carries its own deadline.** The two alternatives were both rejected in PROGRESS.md: a pin
/// that holds until its activity leaves makes a volume keypress do nothing visible, and a view-level
/// offset into the queue makes the presented activity and the displayed one differ, at which point
/// `ActivityChange` stops describing what is on screen.
public struct ActivityPin: Equatable, Sendable {

    public let id: ActivityID

    /// The instant the swipe placed it — and deliberately *not* moved by `refresh(at:)`.
    ///
    /// This is the line that decides which interrupting activities may still take the stage from a
    /// pinned one: those that arrived *after* the user pinned. Moving it on every interaction would
    /// let a HUD that is already on screen sink below the pin the next time the pointer twitched,
    /// which is an activity changing place for a reason the user cannot see.
    public let placedAt: Date

    /// When the pin lapses, measured from the **last interaction** rather than from the swipe —
    /// PROGRESS.md is explicit about that, and it is the difference between a pin that survives a
    /// user still working with the island and one that drops out from under them mid-gesture.
    public private(set) var deadline: Date

    /// How much quiet the pin needs before it lapses. Carried on the pin rather than read from a
    /// constant at refresh time, so a pin placed under one hold cannot silently adopt another.
    public let hold: Duration

    init(id: ActivityID, placedAt: Date, hold: Duration) {
        self.id = id
        self.placedAt = placedAt
        self.hold = hold
        self.deadline = placedAt.addingTimeInterval(hold.timeInterval)
    }

    func hasLapsed(at now: Date) -> Bool { deadline <= now }

    mutating func refresh(at now: Date) {
        deadline = now.addingTimeInterval(hold.timeInterval)
    }
}

/// What happened to the stage — the single slot the island actually draws.
///
/// Exists so the app shell can pick the right motion token without diffing activities itself
/// (§6.2): `swapped` is a morph on `Motion.expand`, `contentChanged` is a crossfade on
/// `Motion.contentSwap`, and getting that backwards is what makes a track change look like the
/// island reopening.
public enum ActivityChange: Equatable, Sendable {

    /// The stage did not change identity or content. Also what an update to a *queued* activity
    /// produces — the island has nothing to redraw for it.
    case none

    /// Something took an empty stage.
    case presented(ActivityID)

    /// The stage emptied.
    case dismissed(ActivityID)

    /// A different activity took the stage from the one on it.
    case swapped(from: ActivityID, to: ActivityID)

    /// The same activity, new content.
    case contentChanged(ActivityID)

    /// The body is untouched; only the **companion flank** changed — one arrived, left, or its
    /// content moved on. Carries the new companion's id, or nil when the flank emptied.
    ///
    /// Its own case rather than folding into `contentChanged`, because the two want different
    /// motion. A companion occupies one 40pt sliver, and reporting its arrival as a body change
    /// fires `Motion.expand` — the whole island morphs for something confined to a flank, which is
    /// the "track change that looks like the island reopening" failure §6.2 warns about, in a new
    /// place. This one crossfades the flank and leaves the outline alone.
    ///
    /// **Only ever reported when the body did not change.** A body change already redraws the whole
    /// island, companion included, so there is nothing left for this to say — which is what lets
    /// `ActivityChange` stay one value rather than becoming a pair of them.
    case companionChanged(ActivityID?)
}

/// The activity stack: everything outstanding, in the order it would be presented.
///
/// A pure value type with no clock, no concurrency and no isolation, because this is where the
/// subtle bugs live and none of them need a running app to reproduce. `ActivityCoordinator` is the
/// thin shell that owns one of these, supplies `now`, and schedules the sleep — it holds no policy
/// of its own, so a policy question can always be answered by a synchronous test here.
///
/// **Ordering is derived, never stored.** The presented activity is defined as the head of the
/// order, not as a separate "currently presented" field mutated on insert and remove. Storing it
/// would be the same mistake `IslandPresentation` documents at the other end of the app: two
/// sources of truth that agree until an activity expires while queued, or a source re-presents an
/// activity whose priority changed, and then quietly do not.
public struct ActivityStack: Sendable {

    /// Every outstanding activity, kept sorted so `presented` is O(1) — it is read from a SwiftUI
    /// body on every frame of an animation, and sorting there would put allocation on the §9
    /// animating budget for no reason.
    public private(set) var entries: [ActivityEntry] = []

    /// The user's swipe, if one is still holding. Nil is the normal state, and nil is what makes
    /// the §9 claim true: with no pin there is no second deadline, so the coordinator's single
    /// sleep is exactly what it was before Milestone 2.
    public private(set) var pin: ActivityPin?

    /// How long a pin holds without interaction (§5, PROGRESS.md's "~8s").
    public static let defaultPinHold: Duration = .seconds(8)

    /// The user's dwell multiplier (`IsletaConfiguration.activityDwellScale`), applied to every
    /// `.after` expiry as it is resolved into a deadline.
    ///
    /// Applied **here, at insertion**, rather than by the sources that build the activities. A
    /// source runs off the main actor, knows nothing about IslandSettings, and must keep knowing
    /// nothing — IslandSources deliberately does not depend on it. Applying it at the one point
    /// where a relative expiry becomes an absolute instant means every source gets it for free,
    /// including any that has not been written yet, and there is a single place to read what the
    /// setting does.
    ///
    /// Changing it does **not** restretch deadlines already on the stack. An activity presented
    /// under the old scale keeps the deadline it was given, because moving it would mean either
    /// expiring something the user is mid-read of or extending a HUD that was already leaving. The
    /// next thing presented uses the new value, which is one HUD's worth of latency on a setting
    /// nobody drags while reading a notification.
    public var dwellScale: Double = 1

    /// Whether the pointer is resting on an island, anywhere.
    ///
    /// An input to **expiry**, in the same sense the pin is an input to ordering — never a stored
    /// "do not remove this one" flag on an entry. While it is true, whatever is on stage keeps its
    /// place no matter how far past its deadline it is: a notification that ran out of dwell under
    /// the pointer that is reading it has not stopped being what the user is looking at, and taking
    /// it away mid-sentence is the one dismissal they did not ask for.
    ///
    /// **Only what is on stage, and only while the pointer is there.** Everything queued behind it
    /// expires on the ordinary clock, so a burst held under the pointer cannot pile up: the moment
    /// something else takes the stage, the entry the pointer *was* holding is expired, unpresented
    /// and removed by the next `removeExpired` like anything else. And the hold ends with the
    /// pointer — `ActivityCoordinator.setPointerOverIsland(false)` refreshes on the way out, so
    /// what was being held leaves on the frame the pointer does.
    ///
    /// Set through `ActivityCoordinator`, which reschedules its sleep either side of the change.
    /// See `nextExpiry` for why a held entry must not stay in the schedule.
    public var isPointerOverIsland: Bool = false

    private var nextSequence: UInt64 = 0

    public init() {}

    // MARK: - Reading

    /// The one activity the island is showing. `nil` is a first-class state: an empty stack is the
    /// normal condition of this app, not an error, and it is what the island rests at.
    public var presented: (any IslandActivity)? { entries.first?.activity }

    /// Everything waiting, in the order it would be presented.
    public var queued: [any IslandActivity] { entries.dropFirst().map(\.activity) }

    public var isEmpty: Bool { entries.isEmpty }

    /// What the island is showing: the primary, and a companion in the other flank when one is
    /// willing to share. Nil on an empty stack, which is the island's resting state.
    ///
    /// See `ActivityStage` for why the stage is a pair at all. This is the only place the pair is
    /// assembled, and it is computed rather than stored for the reason at the top of this type.
    public var stage: ActivityStage? {
        guard let primary = entries.first?.activity else { return nil }
        // Resolved here and not inside `ActivityStage`, so the stage has one settled flank rather
        // than a rule it could re-evaluate and disagree with about which side the primary is on.
        let primaryFlank = primary.kind.flankAffinity
        return ActivityStage(
            primary: primary,
            companion: companion(for: primary, on: primaryFlank.opposite),
            primaryFlank: primaryFlank
        )
    }

    /// The highest-ranked activity that may share the island with `primary`, or nil.
    ///
    /// Walks `entries` in presented order, so the pin is already accounted for: whatever the user
    /// swiped past is where the ordering put it, and the companion is simply the next thing down
    /// that qualifies.
    private func companion(for primary: any IslandActivity, on flank: ActivityFlank) -> (any IslandActivity)? {
        guard Self.maySharePair(primary) else { return nil }
        // A candidate is admitted on the strength of the content the sliver it is being offered is
        // actually going to read — the same presentation `ActivityStage.content(on:)` will ask for.
        // Testing the other one would let a pair form around a sliver that draws nothing.
        return entries.dropFirst().first { entry in
            let candidate = entry.activity
            return candidate.kind != primary.kind
                && Self.maySharePair(candidate)
                && !candidate.presentations.content(for: flank).isEmpty
        }?.activity
    }

    /// Whether an activity belongs on a shared island at all — asked of **both** halves, which is
    /// what keeps the rule symmetric and short.
    ///
    /// Two conditions, and each rules out a specific way of sharing wrongly:
    ///
    /// - **Not interrupting.** A volume HUD must take the whole stage for its moment. Letting one
    ///   sit quietly in a sliver turns a momentary interruption into ambient furniture, and it also
    ///   destroys the HUD: its glyph and its level are the two flanks, so handing one away leaves a
    ///   speaker icon next to nothing.
    /// - **Never expires.** Something with a deadline is asking to be *read*, and a 40pt sliver is
    ///   not where anything gets read. A notification demoted to a flank is a bell glyph the user
    ///   cannot open, expiring on a clock they cannot see.
    ///
    /// Read off the **instance** rather than the kind, so an activity built with a non-default
    /// priority or expiry is judged as what it actually is. That is what will let a *fired* timer —
    /// interrupting, with a dwell — take the whole island while a *running* one shares it, with no
    /// second table to keep in step.
    static func maySharePair(_ activity: any IslandActivity) -> Bool {
        activity.priority != .interrupting && activity.expiry == .never
    }


    public var count: Int { entries.count }

    /// The earliest instant at which *anything* on the stack goes stale, or nil if nothing ever
    /// does. One value for the whole stack: this is what lets the coordinator hold a single
    /// scheduled sleep instead of a timer per activity.
    ///
    /// **The held entry is not in it.** A deadline that cannot remove anything must not be
    /// scheduled against: the coordinator would wake at it, find `removeExpired` holding the entry,
    /// clear its record of the sleep and schedule the same past deadline again — a tight loop on
    /// the main actor for as long as the pointer rested on the island, which is §9's idle budget
    /// spent on a timer that can never do anything. See `heldEntry`.
    public var nextExpiry: Date? {
        let held = heldEntry?.id
        return entries.lazy.filter { $0.id != held }.compactMap(\.deadline).min()
    }

    /// The entry the pointer is holding on stage past its deadline, or nil.
    ///
    /// The presented entry only — never the companion, which cannot have a deadline at all
    /// (`maySharePair` requires `.never`), and never anything queued. Computed from the head of the
    /// order rather than stored, for the reason at the top of this type: a stored "held" id and the
    /// order would agree until something preempted the thing being held.
    private var heldEntry: ActivityEntry? {
        guard isPointerOverIsland, let first = entries.first, first.deadline != nil else { return nil }
        return first
    }

    /// The earliest instant at which *anything at all* wants the stack looked at again — an
    /// activity going stale or a pin lapsing, whichever comes first.
    ///
    /// This, not `nextExpiry`, is what the coordinator schedules against. Merging the two deadlines
    /// into one value here rather than giving the pin its own timer is the whole of how Milestone 2
    /// adds a second deadline without adding a second `Task`: the pin is one more candidate for a
    /// `min`, and a stack with no pin produces exactly the value it produced before, so the idle
    /// path is unchanged and still holds nothing.
    public var nextDeadline: Date? {
        switch (nextExpiry, pin?.deadline) {
        case (let expiry?, let lapse?): min(expiry, lapse)
        case (let expiry?, nil): expiry
        case (nil, let lapse?): lapse
        case (nil, nil): nil
        }
    }

    public func contains(_ id: ActivityID) -> Bool { entries.contains { $0.id == id } }

    public func entry(for id: ActivityID) -> ActivityEntry? { entries.first { $0.id == id } }

    // MARK: - Cycling

    /// Every outstanding activity in the order it would be presented **if nobody had swiped**.
    ///
    /// Cycling walks this rather than the live order, and that is the difference between a swipe
    /// that advances through the queue and one that flips between two entries forever: the pin
    /// lifts one activity to the head, so in the live order the successor of the pinned entry is
    /// whatever the pin displaced — swipe, swipe would land back where it started.
    ///
    /// Computed rather than stored. It is read once per swipe, on a stack holding single digits of
    /// entries; storing a second sorted array would mean two orders to keep in step, which is the
    /// mistake this type's own doc comment opens with.
    public var cycleOrder: [ActivityID] {
        entries.sorted { Self.precedes($0, $1, pin: nil) }.map(\.id)
    }

    /// Everything outstanding as switcher chips, in `cycleOrder`.
    ///
    /// **`cycleOrder`, not the live order**, and for the same reason cycling walks it: the pin lifts
    /// one activity to the head, so a row drawn from the live order would reshuffle itself every
    /// time the user picked something — the chip they just clicked would jump to the front and
    /// every other chip would move under the pointer. The row holds still and marks the current one
    /// instead.
    public var chips: [ActivityChip] {
        let onStage = presented?.id
        return cycleOrder.compactMap { id in
            entry(for: id)?.activity.chip(isOnStage: id == onStage)
        }
    }

    /// The activity `steps` along the queue from the one on stage, or nil if there is nothing there.
    ///
    /// **Deliberately does not wrap.** §5 asks for a swipe past the end of the queue to resist and
    /// spring back, and a wrapping cycle has no end to resist at; it also leaves a user with two
    /// activities unable to tell which one they started on.
    public func cycleTarget(steps: Int) -> ActivityID? {
        guard steps != 0, let presented = presented?.id else { return nil }
        let order = cycleOrder
        guard let index = order.firstIndex(of: presented) else { return nil }
        let target = index + steps
        guard order.indices.contains(target) else { return nil }
        return order[target]
    }

    /// Whether a swipe in this direction has anywhere to go. What the rubber-banding asks.
    public func canCycle(by steps: Int) -> Bool { cycleTarget(steps: steps) != nil }

    // MARK: - Mutating

    /// Presents an activity, or updates one already on the stack.
    ///
    /// Re-presenting an existing id keeps its `sequence` but resets its deadline, and the split is
    /// deliberate. Keeping the sequence means a Now Playing update does not jump the queue past a
    /// notification that arrived while the track was already on the stage. Resetting the deadline
    /// means pressing the volume key a second time buys another 1.5 seconds — the alternative,
    /// holding the original deadline, makes the HUD vanish mid-adjustment while the user is still
    /// pressing the key.
    @discardableResult
    public mutating func insert(_ activity: any IslandActivity, at now: Date) -> ActivityChange {
        let before = stageSignature
        let sequence: UInt64
        if let index = entries.firstIndex(where: { $0.id == activity.id }) {
            sequence = entries[index].sequence
            entries.remove(at: index)
        } else {
            sequence = nextSequence
            nextSequence += 1
        }
        entries.append(
            ActivityEntry(
                activity: activity,
                sequence: sequence,
                insertedAt: now,
                deadline: activity.expiry.deadline(from: now, dwellScale: dwellScale)
            )
        )
        sort()
        return ActivityChange.between(before, stageSignature)
    }

    @discardableResult
    public mutating func remove(_ id: ActivityID) -> ActivityChange {
        let before = stageSignature
        entries.removeAll { $0.id == id }
        retirePinIfUnbacked()
        // The pin is a sort input, so losing it can reorder what is left. Ordering before reading
        // `stageSignature`, not after, or the reported change would describe the order the pin imposed.
        sort()
        return ActivityChange.between(before, stageSignature)
    }

    @discardableResult
    public mutating func removeAll() -> ActivityChange {
        let before = stageSignature
        entries.removeAll()
        pin = nil
        return ActivityChange.between(before, stageSignature)
    }

    // MARK: - Pinning

    /// Holds `id` at the head of the order until the pin lapses. What a swipe does.
    ///
    /// Pinning an id that is not on the stack records **nothing**. That is the "a pin must not
    /// resurrect an activity that has expired out of the stack" rule from PROGRESS.md, enforced at
    /// the only two points where it can be violated: here, and in `removeExpired`. A pin kept for
    /// an absent id would sit waiting, and the next time that source re-presented — the next track,
    /// the next volume keypress — the activity would jump the queue for a swipe the user made
    /// minutes ago and has long forgotten.
    @discardableResult
    public mutating func pin(
        _ id: ActivityID,
        at now: Date,
        holding hold: Duration = ActivityStack.defaultPinHold
    ) -> ActivityChange {
        guard contains(id) else { return .none }
        let before = stageSignature
        pin = ActivityPin(id: id, placedAt: now, hold: hold)
        sort()
        return ActivityChange.between(before, stageSignature)
    }

    /// Drops the pin and lets ordinary ordering resume immediately.
    @discardableResult
    public mutating func unpin() -> ActivityChange {
        guard pin != nil else { return .none }
        let before = stageSignature
        pin = nil
        sort()
        return ActivityChange.between(before, stageSignature)
    }

    /// Moves the pinned activity `steps` along the queue. A swipe, in one call.
    ///
    /// Returns `.none` and pins nothing when there is nowhere to go — one activity on the stack, or
    /// a swipe off the end of the queue. The caller reads that as "resist and spring back"; pinning
    /// the activity already on stage instead would look identical on screen while quietly arming an
    /// 8s deadline, which is a timer bought for a gesture that did nothing.
    @discardableResult
    public mutating func cycle(
        by steps: Int,
        at now: Date,
        holding hold: Duration = ActivityStack.defaultPinHold
    ) -> ActivityChange {
        guard let target = cycleTarget(steps: steps) else { return .none }
        return pin(target, at: now, holding: hold)
    }

    /// Restarts the pin's hold. Called for anything the user does to the island.
    ///
    /// The 8s is measured from the last interaction, not from the swipe, so hovering, clicking or
    /// swiping again all come through here. A no-op when nothing is pinned — which is what keeps
    /// the idle path free of a deadline: an interaction with no pin behind it must not invent one.
    public mutating func refreshPin(at now: Date) {
        pin?.refresh(at: now)
    }

    /// Drops a pin whose activity has left the stack. See `pin(_:at:)` for why it cannot be kept.
    private mutating func retirePinIfUnbacked() {
        guard let pin, !contains(pin.id) else { return }
        self.pin = nil
    }

    /// Drops everything whose deadline has passed.
    ///
    /// Queued activities expire on the same clock as the presented one, and that is a decision
    /// rather than an oversight: an expiry says when the *information* goes stale, not how long the
    /// island owes it screen time. A notification that was preempted by a volume HUD is five
    /// seconds old by the time the HUD clears whether or not anybody saw it, and surfacing it then
    /// would show the user a stale banner with no way to tell it apart from a fresh one. The cost
    /// is that a burst of interrupting activity can swallow a notification entirely; the fix for
    /// that is a longer expiry on the notification, not a per-activity display budget.
    /// Also retires a pin that has lapsed, or whose activity has just expired out from under it.
    ///
    /// One entry point for both deadlines, because they are the same question asked of one instant:
    /// what on this stack has stopped being true as of `now`? Splitting them into `removeExpired`
    /// and a separate `expirePin` would need two calls at every site and two chances to forget one,
    /// and the coordinator would have to decide which of its own deadlines had fired — a decision
    /// that is exactly the state it is trying not to hold.
    /// The pointer has left the island: give back what it was holding, rather than sweeping it.
    ///
    /// **Reported from use, 2026-08-25.** The hold worked exactly as designed — an entry the pointer
    /// is on cannot be removed, however far past its deadline it is — and the design was wrong at
    /// one edge. A notification whose five seconds ran out under the pointer was removed on the
    /// frame the pointer left, so reading it carefully was the one way to make it vanish the instant
    /// you looked away, and there was nothing on screen to explain why.
    ///
    /// **Its own dwell again, not a fixed grace.** The span is `deadline - insertedAt`, which is
    /// what the activity asked for and what `dwellScale` has already been applied to — so a user who
    /// has set a long dwell gets a long one here, and a HUD that was only ever meant to last a
    /// second does not get a notification's five. That is the whole of "reset the timer": the
    /// activity starts its life over at the moment the user stopped looking at it.
    ///
    /// Called by `ActivityCoordinator.setPointerOverIsland(false)` **before** the flag is cleared,
    /// because `heldEntry` is defined in terms of the flag.
    @discardableResult
    public mutating func releasePointerHold(at now: Date) -> Bool {
        guard let held = heldEntry,
              let deadline = held.deadline,
              deadline <= now,
              let index = entries.firstIndex(where: { $0.id == held.id })
        else { return false }
        let dwell = deadline.timeIntervalSince(held.insertedAt)
        // A non-positive span would put the new deadline in the past and change nothing, which is
        // the state this exists to avoid rather than a case to pass through.
        guard dwell > 0 else { return false }
        entries[index].deadline = now.addingTimeInterval(dwell)
        return true
    }

    @discardableResult
    public mutating func removeExpired(at now: Date) -> ActivityChange {
        let before = stageSignature
        // Read before anything is removed, so it names the entry that is on stage *now* rather
        // than whatever the removal promotes to the head.
        let held = heldEntry?.id
        entries.removeAll { $0.hasExpired(at: now) && $0.id != held }
        if pin?.hasLapsed(at: now) == true { pin = nil }
        retirePinIfUnbacked()
        // Only the pin's departure can reorder what survived, so this is a no-op in the common case
        // — but it has to happen before `stage` is read, or the change would describe the order the
        // pin was still imposing.
        sort()
        return ActivityChange.between(before, stageSignature)
    }

    // MARK: - Ordering

    private mutating func sort() {
        let pin = pin
        entries.sort { Self.precedes($0, $1, pin: pin) }
    }

    /// The total order the stack is kept in. Head of the order is the presented activity.
    ///
    /// Read in three tiers, most significant first:
    ///
    /// 1. **Rank**, which is where the pin enters — see `rank(_:pin:)`.
    /// 2. **Priority**, higher first.
    /// 3. **Arrival**, with `displacesPeers` deciding which way the tie breaks: newest first for
    ///    `.interrupting`, oldest first for everything else. See `ActivityPriority.displacesPeers`
    ///    for why those two want opposite answers.
    ///
    /// Still a strict *total* order with the pin in it, and that matters as much as it did before:
    /// `rank` is a function of one entry against a fixed pin, so this stays a lexicographic
    /// comparison of key tuples, and `Array.sort` — which is not stable — cannot reorder equals.
    static func precedes(_ a: ActivityEntry, _ b: ActivityEntry, pin: ActivityPin?) -> Bool {
        let (rankA, rankB) = (rank(a, pin: pin), rank(b, pin: pin))
        if rankA != rankB { return rankA > rankB }
        let (left, right) = (a.activity.priority, b.activity.priority)
        if left != right { return left > right }
        return left.displacesPeers ? a.sequence > b.sequence : a.sequence < b.sequence
    }

    /// Where the pin sits relative to priority. Three values, and the middle one is the pin.
    ///
    /// A pinned activity outranks **priority itself**, not merely its peers, and it has to: the
    /// case a swipe exists for is a user reaching past a notification to get back to their music,
    /// and a pin that only broke ties would leave the notification on stage and the swipe visibly
    /// doing nothing.
    ///
    /// The one thing that still outranks a pin is an interrupting activity that arrived **after**
    /// the user swiped. That is PROGRESS.md's "an interrupting activity can still preempt a pinned
    /// one", read at the resolution the failure actually happens at. Two coarser rules were
    /// considered:
    ///
    /// - *Interrupting always outranks a pin.* Simpler, and wrong in a way the user feels: swiping
    ///   while a 1.5s volume HUD is up would appear to do nothing, and the island would then change
    ///   by itself a second later — the swipe and its result separated by long enough to read as
    ///   two unrelated events.
    /// - *The pin always outranks everything.* Then pressing the volume key does nothing visible,
    ///   which is the alternative PROGRESS.md rejected the sticky pin for in the first place.
    ///
    /// Both dates being read here are already on the stack; nothing is stored to support this.
    /// Re-presenting an id refreshes its `insertedAt`, so a second press of the volume key is a new
    /// arrival and preempts, while the HUD the user swiped past stays where they put it.
    ///
    /// Everything below `.interrupting` — a notification included — queues behind a pin until it
    /// lapses. That is the point of a pin: for its eight seconds, the island is showing what the
    /// user asked for rather than what arrived last.
    private static func rank(_ entry: ActivityEntry, pin: ActivityPin?) -> Int {
        guard let pin else { return 0 }
        if entry.activity.priority == .interrupting, entry.insertedAt > pin.placedAt { return 2 }
        return entry.id == pin.id ? 1 : 0
    }

    // MARK: - Change detection

    /// Identity plus content of whatever owns the **body**, which is what `ActivityChange` describes.
    ///
    /// Deliberately does not include the companion. `ActivityChange` decides which motion token
    /// fires, and a companion appearing in a 40pt sliver must not report `.swapped` — that morphs
    /// the whole island on `Motion.expand` for a change confined to one flank, which is the "track
    /// change that looks like the island reopening" failure in a new place. The flank-only change is
    /// its own case, added with the code that draws it.
    fileprivate struct StageSignature: Equatable {
        let id: ActivityID
        let presentations: ActivityPresentations

        /// The companion, compared **after** the body and never mixed into it. See
        /// `ActivityChange.companionChanged`.
        let companion: Companion?

        struct Companion: Equatable {
            let id: ActivityID
            let presentations: ActivityPresentations
        }
    }

    fileprivate var stageSignature: StageSignature? {
        guard let stage else { return nil }
        return StageSignature(
            id: stage.primary.id,
            presentations: stage.primary.presentations,
            companion: stage.companion.map {
                StageSignature.Companion(id: $0.id, presentations: $0.presentations)
            }
        )
    }
}

extension ActivityChange {

    fileprivate static func between(_ before: ActivityStack.StageSignature?, _ after: ActivityStack.StageSignature?) -> Self {
        switch (before, after) {
        case (nil, nil):
            .none
        case (nil, .some(let after)):
            .presented(after.id)
        case (.some(let before), nil):
            .dismissed(before.id)
        case (.some(let before), .some(let after)) where before.id != after.id:
            .swapped(from: before.id, to: after.id)
        case (.some(let before), .some(let after)) where before.presentations != after.presentations:
            .contentChanged(after.id)
        case (.some(let before), .some(let after)) where before.companion != after.companion:
            // The body is identical and only the flank moved. Ordered last on purpose: a body
            // change already redraws the companion, so this is unreachable unless the body held
            // still.
            .companionChanged(after.companion?.id)
        case (.some, .some):
            .none
        }
    }
}
