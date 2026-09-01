import Foundation
import IslandKit
import Testing

@testable import IslandActivities

@Suite("Built-in activities")
struct BuiltInActivityTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// The vocabulary Milestones 5–8 conform to. If a kind's defaults drift, the milestone that
    /// depends on them fails here rather than on someone's Mac.
    @Test("every kind carries a priority and an expiry that match its job",
          arguments: ActivityKind.allCases)
    func kindDefaults(kind: ActivityKind) {
        let activity = BuiltInActivity(kind: kind)
        #expect(activity.priority == kind.defaultPriority)
        #expect(activity.expiry == kind.defaultExpiry)

        switch kind {
        case .nowPlaying, .shelf, .timer:
            // Nothing about the passage of time makes these false; their sources remove them. A
            // *running* timer is in this group because its source is watching the store — the
            // `.finished` moment is the one that expires, and it says so per instance rather than
            // through the kind's default.
            #expect(activity.expiry == .never)
        case .systemHUD, .welcomeBack, .deviceConnected:
            // Everything a source might forget to retract must retract itself. A connected device
            // is the strongest case in the group: its battery numbers are read once and never
            // refreshed, so an activity that outlived its expiry would be showing a percentage
            // nothing is keeping true.
            #expect(activity.expiry != .never)
        case .call, .fileAction, .screenSharing, .glance:
            // The 2.0 kinds that end when their subject ends. A call hangs up, a conversion
            // finishes, a screen stops being shared, and a glance is dismissed — in each the source
            // knows, so an expiry would be Isleta guessing over the top of something that has the
            // answer. The glance is here for the reason the recents list keeps its ground
            // (PROGRESS.md): it is read, not glanced at.
            #expect(activity.expiry == .never)
        case .calendarAlert, .meeting, .power, .focusChanged:
            // Four moments with nothing to retract them. The meeting is the one to watch: it is the
            // longest-lived of the group at 30s because it carries a *button*, and living long
            // enough to be read is a lower bar than living long enough to be hit.
            #expect(activity.expiry != .never)
        }
    }

    /// The three shapes a Clock timer takes, and the two that must not cost a display link.
    @Test("a running timer counts, and a paused or finished one is a still picture")
    func timerStates() {
        let fires = t0.addingTimeInterval(300)
        let running = BuiltInActivity.timer(
            id: "t", title: "Pasta", state: .running(fireDate: fires), totalDuration: 300, now: t0)
        #expect(running.priority == .ambient)
        #expect(running.expiry == .never)
        // A timeline that runs backwards: position is the remaining time, and fraction is the
        // shrinking arc the ring draws.
        if case .timeline(let timeline) = running.presentations.trailing.value {
            #expect(timeline.rate == -1)
            #expect(timeline.isAdvancing)
            #expect(timeline.position(at: t0) == 300)
            #expect(timeline.position(at: t0.addingTimeInterval(60)) == 240)
            #expect(timeline.fraction(at: t0.addingTimeInterval(150)) == 0.5)
            // Clamped, so an overdue timer reads zero rather than a negative countdown.
            #expect(timeline.position(at: t0.addingTimeInterval(600)) == 0)
        } else {
            Issue.record("a running timer should carry a backwards timeline")
        }
        #expect(running.presentations.expanded.title == "Pasta")

        let paused = BuiltInActivity.timer(
            id: "t", title: nil, state: .paused(remaining: 120), totalDuration: 300, now: t0)
        #expect(paused.priority == .ambient)
        // A paused timer is a still picture: `rate` zero means `position(at:)` never moves, so the
        // display link stops dead rather than redrawing an identical number once a second.
        if case .timeline(let timeline) = paused.presentations.trailing.value {
            #expect(timeline.rate == 0)
            #expect(timeline.isAdvancing == false)
            #expect(timeline.position(at: t0.addingTimeInterval(90)) == 120)
        } else {
            Issue.record("a paused timer should carry a frozen timeline")
        }
        #expect(paused.presentations.expanded.title == "Timer")

        let finished = BuiltInActivity.timer(
            id: "t", title: nil, state: .finished, totalDuration: 300, now: t0)
        #expect(finished.priority == .interrupting)
        #expect(finished.expiry != .never)
    }

    /// The timer was the first kind to want the trailing sliver, and the reason the affinity table
    /// exists: music sits left of the notch and a countdown right of it whichever owns the body.
    ///
    /// The 2.0 vocabulary added two more, and the *rule* is what this pins rather than the list —
    /// a kind goes trailing when its content **is** the number. A percentage, a progress fraction
    /// and a countdown are the same shape; a caller's name is not.
    ///
    /// **Power left this set on 2026-09-01**, and it left because its content stopped being only a
    /// number: it spells what the charger did in its leading sliver now, and a pair gives it one
    /// sliver to say that in. The rule is unchanged — a kind whose content *is* the number goes
    /// trailing — and power no longer answers to it. See `ActivityKind.flankAffinity`.
    @Test("the kinds whose content is a number take the trailing flank, and no others")
    func numericKindsTakeTheTrailingFlank() {
        let numeric: Set<ActivityKind> = [.timer, .fileAction]
        for kind in ActivityKind.allCases {
            #expect(kind.flankAffinity == (numeric.contains(kind) ? .trailing : .leading),
                    "\(kind) is on the wrong side of the notch")
        }
    }

    /// Several timers can run at once, so each needs its own identity — a singleton id would make
    /// the second timer an *update* to the first.
    @Test("timers and notifications each get their own identity")
    func timersAreNotSingletons() {
        #expect(ActivityKind.timer.singletonID == nil)
        #expect(ActivityKind.calendarAlert.singletonID == nil)
        #expect(ActivityKind.nowPlaying.singletonID != nil)
    }

    /// The two ends of the priority order, spelled out because the whole preemption model rests on
    /// them: a HUD must reach the user through anything, and Now Playing must never block anything.
    @Test("the HUD interrupts and Now Playing is ambient")
    func vocabularyPriorities() {
        #expect(ActivityKind.systemHUD.defaultPriority == .interrupting)
        #expect(ActivityKind.nowPlaying.defaultPriority == .ambient)
        #expect(ActivityKind.shelf.defaultPriority == .standard)
        #expect(ActivityKind.calendarAlert.defaultPriority == .prominent)
    }

    /// The two kinds allowed to open the island by themselves, and the one property that would be
    /// expensive to get wrong in either direction: a HUD that opened the island would take over the
    /// screen on every volume keypress, and a greeting that does not is a wave glyph nobody clicks.
    /// The 2.0 vocabulary added two, and both clear the same bar: what they arrived to say is not
    /// on screen at all until the island is open. A meeting collapsed is a video glyph — the button
    /// that is the whole point of the kind is behind a click nobody has a reason to make.
    @Test("only the three kinds with nothing to say collapsed open the island unasked",
          arguments: ActivityKind.allCases)
    func opensIsland(kind: ActivityKind) {
        let opening: Set<ActivityKind> = [.welcomeBack, .meeting, .call]
        #expect(kind.opensIsland == opening.contains(kind), "\(kind) opens the island unasked")
    }

    /// The greeting is opened by Isleta and closed by nothing the user does, so it has to retire
    /// itself. Pinned here next to `opensIsland` because the two together are what make an island
    /// that opens on its own acceptable — one without the other is an island stuck open.
    ///
    /// **`.call` is the one exception, and it is the timer's exception rather than a new one.** A
    /// ringing phone must not vanish after five seconds, so its default is `.never` and the
    /// *instance* carries the expiry — exactly as a running timer defaults to `.never` and the
    /// `.finished` moment expires per instance (`timerStates`, above). What that buys is also what
    /// it costs: if the source that raised a call ever fails to retract it, the island is stuck
    /// open, so a call source owes a retraction on every path including its own teardown. Written
    /// down here because the invariant it breaks is the one that keeps the other three honest.
    @Test("anything that opens the island also expires on its own", arguments: ActivityKind.allCases)
    func openingKindsExpire(kind: ActivityKind) {
        guard kind.opensIsland else { return }
        guard kind != .call else {
            #expect(kind.defaultExpiry == .never, "a ringing call is retracted, never timed out")
            return
        }
        #expect(kind.defaultExpiry != .never)
    }

    /// Singleton ids are what make the coordinator do the right thing without a special case:
    /// re-presenting the same stream updates it in place instead of stacking duplicates.
    @Test("only the plural kinds get their own id", arguments: ActivityKind.allCases)
    func singletonIdentity(kind: ActivityKind) {
        let first = BuiltInActivity(kind: kind)
        let second = BuiltInActivity(kind: kind)

        // The kinds where several can be outstanding at once: as many Clock timers as the user
        // cares to start, and two devices connecting at once. A shared id would make the second one
        // an *update* to the first.
        //
        // Note what this asserts about `.deviceConnected` and what it does not. The memberwise
        // init has no device to key on so it falls back to a UUID, which is what makes the two
        // differ here; the *factory* keys on the address instead, and `deviceIdentityCollapsesABurst`
        // below is where that is pinned — it is the half that matters, because one physical connect
        // fires the callback three or four times.
        let plural: Set<ActivityKind> = [
            .timer, .deviceConnected,
            // The 2.0 additions. Two files convert at once, a calendar alerts on two events
            // starting in the same minute, and a second call comes in during a call.
            .fileAction, .calendarAlert, .call,
        ]
        if plural.contains(kind) {
            #expect(kind.singletonID == nil)
            #expect(first.id != second.id, "these are plural — the user is owed all of them")
        } else {
            #expect(first.id == second.id)
            #expect(first.id == kind.singletonID)
        }
    }

    /// One physical AirPods connect fires IOBluetooth's notification three or four times — measured
    /// on macOS 27.0. The activity id is what collapses them, so it is keyed on the device address
    /// and not on the connection: four publishes of the same device are one activity, updated, and
    /// two different devices are still two.
    @Test("a burst of connects for one device is one activity, and two devices are two")
    func deviceIdentityCollapsesABurst() {
        let airPods = BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 100, single: 0))
        // The same device read again a moment later, one percent down — a different value, the
        // same identity.
        let again = BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 99, single: 0))
        let mouse = BluetoothDeviceConnection(
            name: "Magic Mouse", address: "bc-89-a7-e4-f7-c9", kind: .headphones,
            battery: BluetoothDeviceBattery(left: 0, right: 0, single: 55))

        #expect(BuiltInActivity.deviceConnected(airPods).id == BuiltInActivity.deviceConnected(again).id)
        #expect(BuiltInActivity.deviceConnected(airPods).id != BuiltInActivity.deviceConnected(mouse).id)
    }

    /// The trailing sliver is the ring, and it must be absent rather than empty when the device
    /// reported nothing. An unlit ring is a claim about the charge, and a false one.
    @Test("a device with no battery reported draws no ring")
    func deviceWithoutBattery() {
        let anonymous = BluetoothDeviceConnection(
            name: "Studio Buds", address: "aa-bb-cc-dd-ee-ff", kind: .headphones, battery: .none)
        let activity = BuiltInActivity.deviceConnected(anonymous)
        #expect(activity.presentations.trailing.isEmpty)
        #expect(activity.presentations.leading.symbol == "headphones")
        #expect(activity.presentations.expanded.subtitle == "Connected")

        let charged = BluetoothDeviceConnection(
            name: "AirPods", address: "aa-bb-cc-dd-ee-00", kind: .airPods,
            battery: BluetoothDeviceBattery(left: 80, right: 60, single: 0))
        let withRing = BuiltInActivity.deviceConnected(charged)
        // The lower of the two ear pieces, not their mean — 70% would be a comfortable lie about
        // the bud that is going to die first.
        #expect(withRing.presentations.trailing.value?.normalized == 0.6)
        #expect(withRing.presentations.expanded.subtitle == "60%")
    }

    /// Apple's HUD is one HUD. Pressing brightness while the volume HUD is up has to replace it,
    /// not queue a second one behind it — which falls out of the shared id plus preemption.
    @Test("volume and brightness are the same HUD, replaced in place")
    func hudsShareOneSlot() {
        var stack = ActivityStack()
        stack.insert(BuiltInActivity.systemHUD(.volume, level: 0.4), at: t0)
        let change = stack.insert(BuiltInActivity.systemHUD(.brightness, level: 0.9), at: t0.addingTimeInterval(0.2))

        #expect(stack.count == 1)
        #expect(change == .contentChanged(ActivityKind.systemHUD.singletonID!))
        #expect(stack.presented?.presentations.compact.symbol == SystemHUD.brightness.symbol)
        // And the dwell restarted: the user is still pressing a key.
        #expect(stack.nextExpiry == t0.addingTimeInterval(0.2 + 1.5))
    }

    /// System levels do not arrive clean — a volume read back through CoreAudio lands just past 1.0
    /// often enough to matter, and a bar that paints 1pt past its own track reads as a bug.
    @Test("a HUD level is clamped where it is read, not where it is stored")
    func hudLevelIsClamped() {
        let over = BuiltInActivity.systemHUD(.volume, level: 1.0000000149011612)
        let under = BuiltInActivity.systemHUD(.volume, level: -0.02)

        #expect(over.presentations.compact.value?.normalized == 1)
        #expect(under.presentations.compact.value?.normalized == 0)
        // Stored raw, so a provider comparing against its own reading still sees what it sent.
        #expect(over.presentations.compact.value == .fraction(1.0000000149011612))
    }

    @Test("a normalized value is nil for everything that is not a fraction")
    func nonFractionValues() {
        #expect(ActivityValue.indeterminate.normalized == nil)
        #expect(ActivityValue.countdown(until: t0).normalized == nil)
        #expect(ActivityValue.elapsed(since: t0).normalized == nil)
    }

    /// A Now Playing update must be a content change, never a new activity — otherwise §6.2 morphs
    /// the container on every track change instead of crossfading the content.
    @Test("a track change is a content change, not a new activity")
    func trackChangeIsAContentChange() {
        var stack = ActivityStack()
        stack.insert(BuiltInActivity.nowPlaying(title: "Teardrop", artist: "Massive Attack"), at: t0)
        let change = stack.insert(BuiltInActivity.nowPlaying(title: "Angel", artist: "Massive Attack"), at: t0)

        #expect(change == .contentChanged(ActivityKind.nowPlaying.singletonID!))
        #expect(stack.count == 1)
    }

    /// An empty string would reserve a subtitle's worth of height for text that is not there, and
    /// the island would sit a few points taller for an unnamed artist.
    @Test("a missing artist leaves no empty subtitle")
    func absentMetadataIsNilNotEmpty() {
        let bare = BuiltInActivity.nowPlaying(title: "Untitled")
        #expect(bare.presentations.expanded.subtitle == nil)

        let named = BuiltInActivity.nowPlaying(title: "Teardrop", artist: "Massive Attack", album: "Mezzanine")
        #expect(named.presentations.expanded.subtitle == "Massive Attack — Mezzanine")
    }

    /// The island cannot draw inside the cutout, so any activity that means to be visible at rest
    /// has to say something in a flank or in the compact slot.
    @Test("every built-in fills at least the compact slot")
    func everyBuiltInSaysSomething() {
        let activities: [BuiltInActivity] = [
            .nowPlaying(title: "Teardrop", artist: "Massive Attack"),
            .systemHUD(.volume, level: 0.5),
            .welcomeBack(greeting: "Welcome back"),
            .shelf(itemCount: 3),
        ]
        for activity in activities {
            #expect(!activity.presentations.compact.isEmpty, "\(activity.kind) has nothing to show")
            #expect(!activity.presentations.expanded.isEmpty, "\(activity.kind) opens to nothing")
        }
    }

    /// Peek is an invitation to click, not the click's result — so it shows the same content as
    /// rest. Swapping content on hover would answer the invitation before the user accepted it.
    @Test("rest and peek show the same content; only expanding changes it")
    func presentationMapping() {
        let presentations = BuiltInActivity.shelf(itemCount: 2).presentations
        #expect(presentations.content(for: .rest) == presentations.compact)
        #expect(presentations.content(for: .peek) == presentations.compact)
        #expect(presentations.content(for: .expanded) == presentations.expanded)
    }

    @Test("an explicit priority or expiry overrides the kind's default")
    func overridesWin() {
        let activity = BuiltInActivity(
            id: "custom",
            kind: .nowPlaying,
            priority: .interrupting,
            expiry: .after(.seconds(1))
        )
        #expect(activity.id == "custom")
        #expect(activity.priority == .interrupting)
        #expect(activity.expiry == .after(.seconds(1)))
    }

    /// The whole point of Milestone 4: the model composes without a window, a permission, or a
    /// running app. If this ever needs one, the layering has leaked.
    @Test("the built-in vocabulary runs end to end with no permission and no app")
    func endToEndWithNothingRunning() {
        var stack = ActivityStack()
        let alert = BuiltInActivity(
            kind: .calendarAlert,
            presentations: ActivityPresentations(
                compact: ActivityContent(title: "Standup"),
                expanded: ActivityContent(title: "Standup", subtitle: "in 2 minutes")
            )
        )
        stack.insert(BuiltInActivity.nowPlaying(title: "Teardrop", artist: "Massive Attack"), at: t0)
        stack.insert(alert, at: t0)
        stack.insert(BuiltInActivity.systemHUD(.volume, level: 0.6), at: t0)

        #expect(stack.presented?.kind == .systemHUD)
        #expect(stack.queued.map(\.kind) == [.calendarAlert, .nowPlaying])

        // 1.5s: the HUD goes, the alert takes over.
        #expect(stack.removeExpired(at: t0.addingTimeInterval(1.5)).isSwap)
        #expect(stack.presented?.kind == .calendarAlert)

        // 10s: the alert goes stale too, and Now Playing comes back.
        #expect(stack.removeExpired(at: t0.addingTimeInterval(10)).isSwap)
        #expect(stack.presented?.kind == .nowPlaying)
        #expect(stack.nextExpiry == nil)
    }
}

extension ActivityChange {
    fileprivate var isSwap: Bool {
        if case .swapped = self { return true }
        return false
    }
}
