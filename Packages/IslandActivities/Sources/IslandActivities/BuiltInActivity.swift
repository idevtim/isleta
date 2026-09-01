import Foundation
import IslandKit

/// The closed vocabulary of things Isleta presents.
///
/// Closed on purpose. An open `String` kind, or a `case custom(String)`, would let Milestones 5–8
/// each invent their own priority and expiry and there would be no single place to read what the
/// island does — and no way for IslandSettings to offer "show Now Playing" as a toggle without
/// string-matching. Adding a kind is meant to be a deliberate edit here, next to the defaults it
/// has to justify itself against.
public enum ActivityKind: String, CaseIterable, Sendable {

    /// §2.4. Whatever is playing, for as long as it plays.
    case nowPlaying

    /// §2.6 / §8.1.5. Volume, mute, brightness — the result of a key the user just pressed.
    case systemHUD

    /// §2.5. The wake/unlock moment. Not a lock screen feature and must not be described as one:
    /// `loginwindow` is a separate secure context and is closed to third parties.
    case welcomeBack

    /// §5, Milestone 3. The drag-and-drop shelf.
    case shelf

    /// §2.7. A timer from Apple's Clock — running, paused, or just finished.
    case timer

    /// A Bluetooth audio device that has just connected. Momentary by design — see
    /// `defaultExpiry`. The one kind whose whole content is a picture and a number.
    case deviceConnected

    // MARK: - 2.0, the parity vocabulary
    //
    // Ten kinds added together on 2026-08-23 rather than one per milestone, and the reason is a
    // trap this repository has already paid for once: inserting a stored property into a shared
    // struct leaves dependent packages reading every field at the wrong offset, with no compile
    // error (CLAUDE.md). Enum cases are cheaper than that, but the same argument applies to the
    // rebuild storm — every package downstream recompiles for each addition, and the five
    // exhaustive tables below have to be re-argued each time. One edit, one argument, one rebuild.
    //
    // Each is justified against the defaults directly beneath it. A kind with no table entry it
    // has to think about is a kind that did not need to exist.

    /// Calendar and weather in one surface — the day, what is next, and what it is doing outside.
    ///
    /// **The one kind that is never presented, and it has to stay in this enum anyway.** The glance
    /// is a *page* (`IslandPage.home` and `.weather`), reached by opening the island and turning to
    /// it, and `GlanceModel` carries the day and the sky to it as a snapshot with no stack
    /// involved. It stood on the stack as an ambient activity through 2.0 and was withdrawn: a
    /// condition that is permanently true takes the leading sliver from Now Playing forever, so a
    /// resting island showed a calendar glyph where the album cover belongs and the track lip —
    /// which is gated on Now Playing owning that sliver — could not fire at all. See "Will not own"
    /// in the IslandSources README.
    ///
    /// What is left here is the **module's** identity: `SourceToggles[.glance]` is the switch that
    /// runs `CalendarSource` at all, `SettingsSection.glance` is its pane, and `ShortcutAction`
    /// and the status menu both name it. Giving that a vocabulary of its own beside this one is the
    /// second spelling `SourceToggles` argues at length against, so the case stays and the tables
    /// below say plainly that nothing reads them.
    case glance

    /// One calendar event about to start. The announcing half of `glance`, and separate from it
    /// because the two have opposite manners: this one arrives unasked with a deadline attached.
    case calendarAlert

    /// A meeting the user can join — a Zoom, Meet, Teams or FaceTime link found on an event that
    /// is starting. Separate from `calendarAlert` because it carries an *action*: the whole point
    /// is the button, and an alert with nothing to press is a different thing.
    case meeting

    /// Power: charger connected or pulled, a battery getting low, Low Power Mode turning itself on.
    case power

    /// An incoming, outgoing or connected call.
    case call

    /// Work Isleta is doing to a file the user dropped: converting, compressing, transcribing,
    /// making a link. The one kind that reports on Isleta's own labor rather than the system's.
    case fileAction

    /// A Focus turning on or off. Worth saying because it changes what the island itself will do
    /// next — a user who cannot see that Do Not Disturb came on reads the resulting silence as
    /// Isleta being broken.
    case focusChanged

    /// The screen is being recorded or shared. Not a permission Isleta holds — a state the system
    /// is in, which the user is owed a persistent reminder of.
    case screenSharing

    /// Where this kind sits by default. A provider may override it, but starting from the kind is
    /// what stops a volume HUD shipping at `.ambient` and never being seen.
    public var defaultPriority: ActivityPriority {
        switch self {
        case .nowPlaying, .timer: .ambient
        // `screenSharing` is ambient for the same reason Now Playing is: it is a *condition*, true
        // for as long as it is true, and a condition that fights something that just happened for
        // the stage would take the top of the screen away from the thing that actually happened.
        case .screenSharing: .ambient
        case .shelf: .standard
        // `.fileAction` is work the user asked for, and `.standard` is the honest level for it: it
        // outranks the ambient conditions it was summoned over, and it yields to anything that
        // genuinely just happened. `.glance` is never presented and this answer is never read — it
        // is here because the switch is exhaustive. See the case's own note.
        case .glance, .fileAction: .standard
        case .welcomeBack, .deviceConnected: .prominent
        // A calendar alert and a joinable meeting are `.prominent` on the same argument the
        // greeting is: something happened, it has the user's name on it, and it expires.
        case .calendarAlert, .meeting, .power, .focusChanged: .prominent
        // A ringing phone is the one thing in this vocabulary that outranks a volume key, and it is
        // the only new kind that earns `.interrupting`. Every other candidate was talked out of it:
        // a meeting starting is prominent, a battery at 5% is prominent, a conversion finishing is
        // standard. `.interrupting` means "this cannot wait four seconds", and almost nothing is.
        case .call: .interrupting
        case .systemHUD: .interrupting
        }
    }

    /// How long this kind stays relevant by default.
    ///
    /// The HUD figure matches the system's own dwell closely enough that Isleta's HUD and Apple's
    /// do not read as two different lengths when both are on screen (§2.6 allows shipping alongside
    /// the system HUD rather than suppressing it). Now Playing and the shelf never expire because
    /// nothing about the passage of time makes them false — their sources remove them.
    public var defaultExpiry: ActivityExpiry {
        switch self {
        case .nowPlaying, .shelf, .timer: .never
        case .systemHUD: .after(.milliseconds(1500))
        case .welcomeBack: .after(.seconds(4))
        // Four seconds, and the number is doing more work than it looks. The battery percentages
        // are read **once**, on the connect callback, and are never refreshed — so the activity
        // must not outlive the moment its numbers were true. It also means this source keeps no
        // timer and nothing on the idle path: the expiry is the whole lifecycle. See
        // `BluetoothDeviceBattery` for why re-reading would not help anyway.
        case .deviceConnected: .after(.seconds(4))
        // Four kinds that end when the thing they describe ends, not when a clock says so. A call
        // hangs up, a conversion finishes, a screen stops being shared — in
        // every one of them the source knows, and an expiry would be Isleta guessing over the top
        // of a source that has the answer.
        case .call, .fileAction, .screenSharing: .never
        // Never presented, so never expired. `.never` rather than a duration because a page does
        // not time out — the user turns away from it. See the case's own note.
        case .glance: .never
        // An alert about a thing that is starting has its deadline in the content, and the content
        // is the argument for the number: ten seconds is long enough to read "Standup, 2 minutes"
        // and decide, and short enough that it is gone before the meeting it is about.
        case .calendarAlert: .after(.seconds(10))
        // A meeting carries a button, so it must live long enough to be *hit* — which is a
        // different bar from long enough to be read. Thirty seconds is the smallest number that
        // survives a user looking up, reaching for the trackpad and traveling to the notch.
        case .meeting: .after(.seconds(30))
        case .power: .after(.seconds(5))
        // A Focus change is a fact about the machine, said once and briefly. Longer than a HUD
        // because it was not the result of a key the user just pressed and may need finding.
        case .focusChanged: .after(.seconds(3))
        }
    }

    /// The one id this kind's activities share, or nil if several can be outstanding at once.
    ///
    /// Most kinds are a singleton, and that is what makes the coordinator do the right thing for
    /// free. Volume and brightness are one HUD — Apple's is — so pressing brightness while the
    /// volume HUD is up replaces its content and restarts its dwell instead of queueing a second
    /// HUD behind the first. Timers are genuinely plural: the user is owed every one they started.
    public var singletonID: ActivityID? {
        switch self {
        // Two kinds where several can be outstanding at once, so each needs its own identity:
        // macOS Clock runs as many timers as the user starts, and two devices can connect within a
        // second of each other. A singleton id here would make the second timer an *update* to the
        // first. A device's is its address (`BluetoothDeviceConnection.activityID`) rather than a
        // fresh UUID, which is what makes the three or four callbacks one physical AirPods connect
        // fires collapse into one island instead of four.
        case .timer, .deviceConnected: nil
        // Three more genuinely plural kinds. Two files can convert at once, so `fileAction`
        // carries its own identity or the second would be an *update* to the first and the user
        // would watch one progress bar do the work of two. A calendar can alert on two events
        // starting in the same minute, and a Mac can be in a call while another comes in.
        case .fileAction, .calendarAlert, .call: nil
        default: ActivityID("builtin.\(rawValue)")
        }
    }

    /// Whether this kind is worth *opening* the island for, rather than waiting to be looked at.
    ///
    /// The bar is deliberately high: opening unasked takes the top of the user's screen and puts
    /// an Escape hot key and a global click monitor on the machine for as long as it is up.
    /// Everything else in the vocabulary either arrives while the user is mid-sentence in another
    /// app — a volume key, a track change — or is already the result of something they did, and the
    /// island's whole manner is to say those in the flanks and be glanced at.
    ///
    /// The greeting is one of them because of what it is and when it lands. The user has just come
    /// back to a Mac they were away from and has nothing in progress to interrupt, and the sentence
    /// *is* the activity: drawn compactly it is a wave glyph in the notch, which is a message the
    /// island promises and then asks the user to click to collect. Nobody clicks a glyph they have
    /// no reason to believe is holding something.
    ///
    ///
    /// Expiry is what makes both safe to do without a dismiss control — `defaultExpiry` retires the
    /// activity on its own, and the app shell closes the island it opened when it goes.
    /// The glyph that identifies this kind in the switcher row.
    ///
    /// **Stable across the activity's own state**, unlike the compact badge's symbol. A chip is a
    /// way *back* to something, not a readout of it — the music chip drew `pause.fill` while the
    /// track was paused, so the control for "take me to my music" changed shape depending on
    /// whether the music was playing. `music.note` is Apple Music's own mark and always means the
    /// same thing.
    public var chipSymbol: String {
        switch self {
        case .nowPlaying: "music.note"
        case .timer: "timer"
        case .welcomeBack: "hand.wave.fill"
        case .systemHUD: "speaker.wave.2.fill"
        case .shelf: "tray.full.fill"
        // Generic on purpose, where the *activity* draws the specific device. A chip is a way back
        // to something and has to mean the same thing every time; the compact badge is a readout
        // and is free to show the actual pair of AirPods.
        case .deviceConnected: "headphones"
        // Each of these is the *stable* mark for the kind, never a readout of its state — the rule
        // the music chip was fixed for. `power` is `bolt.fill` whether the battery is charging or
        // dying, because a chip is a way back to a thing and has to mean the same thing every time.
        case .glance: "calendar"
        case .calendarAlert: "calendar.badge.clock"
        case .meeting: "video.fill"
        case .power: "bolt.fill"
        case .call: "phone.fill"
        case .fileAction: "wand.and.rays"
        case .focusChanged: "moon.fill"
        case .screenSharing: "record.circle"
        }
    }

    /// Which sliver this kind takes when it is the primary of a pair.
    ///
    /// The table `ActivityStack.stage` asks, and the only answer — it was briefly overridable per
    /// kind (`IslandSides`, through 2.0), which froze whatever the table said on the day the user
    /// opened the pane into their settings file forever.
    ///
    /// **Every built-in currently answers `.leading`, and that is not an oversight.** Each of them
    /// puts its glyph in the leading sliver and its value — a timeline, a level, a count — in the
    /// trailing one, because a glyph on the left reading into a number on the right is how all five
    /// were drawn. The first kind to want `.trailing` is the timer, whose content *is* the number.
    ///
    /// The table earns its place before that kind exists, because it is what makes the pair
    /// symmetric: the primary takes the side it asked for and the companion takes the only side
    /// left, so music sits left of the notch and a timer right of it whichever of the two happens
    /// to own the body. A rule written as "the companion goes trailing" instead would put the music
    /// on the right the moment a user brought the timer to the stage.
    public var flankAffinity: ActivityFlank {
        switch self {
        case .nowPlaying, .systemHUD, .welcomeBack, .shelf, .deviceConnected: .leading
        // Glyph on the left reading into a value on the right, which is what the first five did and
        // what makes a pair symmetric.
        //
        // `.glance` is in this list and is never asked, because it never reaches a stage. It
        // answering `.leading` here is precisely what took the album cover's sliver while it did —
        // both it and `.nowPlaying` wanted the same side, and the primary won.
        case .glance, .calendarAlert, .meeting, .call, .focusChanged, .screenSharing: .leading
        // The first kind to want the other sliver, and the reason the table exists. A timer's
        // content *is* a number, so it belongs where the other kinds put their numbers — which
        // also puts music on the left of the notch and a countdown on the right whichever of the
        // two happens to own the body.
        case .timer: .trailing
        // A conversion's progress is the timer's case exactly: the content *is* the fraction.
        case .fileAction: .trailing
        // **Power was `.trailing` on that same argument until 2026-09-01, and the argument stopped
        // being true when the sliver learned to say "Charging".** Its content used to be a
        // percentage and nothing else, so it belonged where the timer's countdown goes. Now its
        // leading content is a battery glyph *and the word for what just happened* and its trailing
        // content is the level — and this table only ever decides which **one** of the two a paired
        // power activity gets, since unpaired it owns both slivers regardless.
        //
        // Asked that way the answer inverts. Power outranks Now Playing, so the pair it makes is
        // the common one — a charger going in while music plays — and `.trailing` spent that pair's
        // one sliver on a bar, which draws a fraction with nothing to say whose fraction it is.
        // `ActivityStage.flanks` then correctly declines to widen the island for a wordless sliver,
        // so the whole of what the charger did was a bar changing length beside an album cover. The
        // word is the thing that could not be inferred; the percentage is on the open island and in
        // the menu bar already.
        //
        // It costs the symmetry the timer's note describes — music and power now both want the
        // leading sliver, and the primary wins — and that is the right way round: the album cover
        // is a picture the user has been looking at for three minutes, and the charger is the thing
        // that just happened.
        case .power: .leading
        }
    }

    /// How wide this kind's slivers have to be: whether they say **what it is**, in a word, rather
    /// than only showing a glyph — and if so, how long the word is.
    ///
    /// The island widens past `IslandLayout.flankedWidthGrowth` for the kinds that ask, so there is
    /// room for the word beside the glyph in the leading sliver. `.standard` is the answer for
    /// almost everything and means "a glyph, and no more room than one needs".
    ///
    /// **Two kinds, and the bar for a third is high.** Two things have to be true together:
    ///
    /// - **The glyph alone is genuinely ambiguous.** A volume key and a brightness key produce the
    ///   same picture at a glance — a small symbol and a bar — and the user has just pressed one of
    ///   them and wants to know it was the one they meant. A battery glyph is worse than ambiguous:
    ///   `battery.100percent.bolt` on a charger and `battery.100percent` on a full battery differ by
    ///   a bolt 4pt wide, in a notch, from a meter away, and the two mean opposite things about
    ///   whether the user has to go and find a cable. Nothing else in the vocabulary has a sibling
    ///   it can be confused with: a track is artwork, a timer is a countdown, a device is its own
    ///   picture.
    /// - **It is over in a moment.** `defaultExpiry` retires a HUD after 1.5s and a power moment
    ///   after 5, so the widest shapes the island has are on screen for the length of a keypress or
    ///   a charger going in. That is what pays for a body `wideFlankedWidthGrowth` argues is past
    ///   the width at which the island still reads as the notch growing: nothing *ambient* may
    ///   answer anything but `.standard` here, because a condition that is permanently true would
    ///   leave the island permanently that wide, which is a black bar with a notch in it rather
    ///   than a notch.
    ///
    /// **Two spans and not one shared widest**, because the two kinds are sized to different words:
    /// the longest HUD label across the shipped languages is 61pt and the longest power label is 90,
    /// and one constant for both would put "Volume" in a hole sized for "Batteriebetrieb". See
    /// `IslandLayout.widerFlankedWidthGrowth`, where the arithmetic is.
    ///
    /// Keyed on the kind and read per *flank*, so a pair widens the island when either sliver's
    /// owner asks — and only when that sliver is actually carrying the word. See
    /// `ActivityStage.flanks`.
    public var flankSpan: IslandFlanks {
        switch self {
        case .systemHUD: .wide
        // A phrase rather than a noun: "On Battery", "Low Power Off", "Sparmodus aus". Every
        // shortening that fits the HUD's sliver reads as a different fact — "Battery" is not
        // "On Battery", and "Low" is not "Low Battery" — so the shape follows the sentence.
        case .power: .wider
        // Everything else shows rather than spells. Four of them draw a picture in the sliver that
        // is already the answer (artwork, a device, a ring, a level), and the rest have no sibling
        // to be told apart from.
        case .nowPlaying, .welcomeBack, .shelf, .timer, .deviceConnected, .glance,
             .calendarAlert, .meeting, .call, .fileAction, .focusChanged, .screenSharing:
            .standard
        }
    }

    /// Whether this kind's values are **levels the user drives**, so reaching an end of one is worth
    /// answering with a rebound of the island's edge (`IslandScreenModel.limitBounce`).
    ///
    /// The same shape as `namesItselfInFlanks` and true of the same one kind, for a related reason
    /// rather than the same one: a HUD is the only thing in this vocabulary whose number the user is
    /// *pushing*. A battery percentage, a conversion's progress and a track's position all reach 1.0
    /// on their own, and an island that sprang sideways when a file finished converting would be
    /// answering a question nobody asked.
    ///
    /// Read by `IslandScreenModel.hitRegionMetrics` to reserve the travel, so it has to be true for
    /// as long as such an activity is on stage — not only on the update that reaches an end. That is
    /// what covers the rebounds the user pushes out of a level that is *already* at its end, which
    /// carry no reading and no `ActivityLimit` with them at all.
    public var reboundsAtItsLimits: Bool {
        switch self {
        case .systemHUD: true
        case .nowPlaying, .welcomeBack, .shelf, .timer, .deviceConnected, .glance,
             .calendarAlert, .meeting, .power, .call, .fileAction, .focusChanged, .screenSharing:
            false
        }
    }

    public var opensIsland: Bool {
        switch self {
        case .welcomeBack: true
        // A connected device does not open the island, for the reason the bar is set high: the
        // user just did this deliberately, knows it happened, and is owed a confirmation rather
        // than an interruption. Everything it has to say — which device, how much charge — fits in
        // the two slivers, so there is nothing behind a click to collect.
        case .nowPlaying, .systemHUD, .shelf, .deviceConnected: false
        // Two more that open, and both clear the bar the same way `welcomeBack` does: what they
        // arrived to say is not on screen at all until the island is open. A meeting collapsed is a
        // video glyph in the notch — the button that is the entire point of the kind is behind a
        // click nobody has a reason to make. A ringing call is the same and more urgent.
        case .meeting, .call: true
        // Everything else says its piece in the slivers. `glance` is false for the opposite reason
        // to the rest: the user is *already* opening the island to get it, so a kind that opened the
        // island too would be opening something that is opening.
        case .glance, .calendarAlert, .power, .fileAction,
             .focusChanged, .screenSharing: false
        // A finished timer does **not** open the island by itself. It arrives `.interrupting`, so
        // it takes the stage and is visible in the flanks with no click — the same way a volume HUD
        // is.
        //
        // **The reason for this used to be different, and it is worth recording that it changed.**
        // It was false because Clock posts its own notification when a timer ends and *that* opened
        // the island, so making this true would have opened the island twice for one event. With
        // notifications gone that second route is gone with them, and a finished timer now says its
        // piece in the flanks only. Turning this true is not the fix: this table is keyed on the
        // *kind*, and a timer merely starting would then open the island too.
        case .timer: false
        }
    }
}

/// Which system level a `systemHUD` activity is reporting.
///
/// **The keyboard backlight is deliberately not one of them.** It was, through 2.0 — read from
/// CoreBrightness, which answers an unentitled process and pushes changes — and the route working is
/// exactly what made it a bad HUD: the ambient-light sensor moves the backlight on its own, all day,
/// with nobody having pressed anything. So the island interrupted itself to report a change the user
/// had not made and could not have predicted, which is the opposite of what a HUD is for. Volume and
/// display brightness both move only because a key was pressed. If a way to tell a sensor-driven
/// change from a keyed one ever appears, this is where the case goes back.
public enum SystemHUD: String, CaseIterable, Sendable {
    case volume
    case mute
    case brightness

    /// SF Symbols only (§6.5). Named here rather than in IslandUI because the *choice* of glyph is
    /// part of what the activity means, while its size, weight and color are not.
    public var symbol: String {
        switch self {
        case .volume: "speaker.wave.2.fill"
        case .mute: "speaker.slash.fill"
        case .brightness: "sun.max.fill"
        }
    }

    /// What VoiceOver announces. The HUD is a glyph and a bar; read aloud it is nothing at all.
    public var accessibilityLabel: String {
        switch self {
        case .volume: activityText("hud.volume", "Volume")
        case .mute: activityText("hud.muted", "Muted")
        case .brightness: activityText("hud.brightness", "Display brightness")
        }
    }

    /// The word drawn beside the glyph, on an island widened to hold it — see
    /// `ActivityKind.namesItselfInFlanks`.
    ///
    /// **A second string rather than `accessibilityLabel` reused, and only brightness differs.**
    /// The spoken label is a phrase read aloud with nothing else around it, so "Display brightness"
    /// is right there and wrong in a sliver — the glyph is already saying "brightness", and the word
    /// beside it is answering *which* of the two keys was pressed. One noun, in the words a user
    /// would use for the thing they just changed.
    ///
    /// Kept short deliberately. `IslandLayout.wideFlankedWidthGrowth` is sized to the longest of
    /// these across the shipped languages, so a translation that reaches for a phrase where a noun
    /// will do widens the island for everybody who reads that language.
    public var label: String {
        switch self {
        case .volume: activityText("hud.volume.label", "Volume")
        case .mute: activityText("hud.muted.label", "Muted")
        case .brightness: activityText("hud.brightness.label", "Display")
        }
    }
}

/// The concrete activity the built-in providers hand to the coordinator.
///
/// One struct rather than five, because the five differ only in the data they carry and giving each
/// its own type would put five near-identical conformances in five different packages — and the
/// first one to forget `kind.defaultExpiry` would ship a volume HUD that never goes away. The
/// factories below are the sanctioned way in; the memberwise `init` exists for the cases they do
/// not cover yet and for tests.
public struct BuiltInActivity: IslandActivity, Equatable {

    public let id: ActivityID
    public let kind: ActivityKind
    public var priority: ActivityPriority
    public var expiry: ActivityExpiry
    public var presentations: ActivityPresentations

    /// See `IslandActivity.reachedLimit`. Set by `systemHUD(_:level:limit:)` and by nothing else.
    public var reachedLimit: ActivityLimit?

    /// `priority` and `expiry` default to the kind's, and `id` to the kind's singleton where it has
    /// one. Written as optionals rather than as default arguments because a default argument cannot
    /// refer to another parameter, and deriving them from `kind` is the entire point.
    public init(
        id: ActivityID? = nil,
        kind: ActivityKind,
        priority: ActivityPriority? = nil,
        expiry: ActivityExpiry? = nil,
        presentations: ActivityPresentations = .empty,
        reachedLimit: ActivityLimit? = nil
    ) {
        self.id = id ?? kind.singletonID ?? ActivityID("builtin.\(kind.rawValue).\(UUID().uuidString)")
        self.kind = kind
        self.priority = priority ?? kind.defaultPriority
        self.expiry = expiry ?? kind.defaultExpiry
        self.presentations = presentations
        self.reachedLimit = reachedLimit
    }

    // MARK: - The built-in vocabulary
    //
    // Defined ahead of any source (§8.3: the coordinator and its tests come before the providers),
    // so Milestones 5–8 conform to a shape that already exists rather than each inventing one and
    // the island having to accommodate all five.

    /// §2.4. The same id on every update, so a track change crossfades rather than reopening.
    ///
    /// The two flanks are asymmetric on purpose, and this is the one activity IslandUI draws
    /// bespokely rather than generically (see `ActivityPresentations`): the leading flank carries the
    /// album artwork and the trailing one a playing/paused equaliser. Both are still *declared* here
    /// as ordinary content — a symbol for the leading flank, a `.timeline` value for the trailing one
    /// — so everything downstream keeps working off the data. That matters for one thing in
    /// particular: `ActivitySlotLayout.needsClock` decides whether a display link runs at all by
    /// asking the *values* in the visible slots, so putting the timeline in the trailing flank is
    /// exactly what makes the equaliser run while playing and stop dead while paused, with no case
    /// for music anywhere in the clock.
    ///
    /// - Parameter timeline: where the player is, as an anchor rather than a sample. `nil` for a
    ///   route that cannot report position — the scripting fallback knows only what is playing — in
    ///   which case the trailing flank falls back to a glyph and the expanded island shows no scrub
    ///   bar. An empty bar would be a promise the route cannot keep.
    public static func nowPlaying(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        isPlaying: Bool = true,
        timeline: ActivityTimeline? = nil
    ) -> Self {
        let glyph = isPlaying ? "waveform" : "pause.fill"
        // A timeline in the trailing flank when there is one, a glyph when there is not. Never both:
        // the sliver is 40pt wide and two claimants on it is a glyph sitting on the equaliser.
        let trailing = timeline.map { ActivityContent(value: .timeline($0), tint: .neutral) }
            ?? ActivityContent(symbol: glyph, tint: .neutral)
        return Self(
            kind: .nowPlaying,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: "music.note", tint: .neutral, accessibilityLabel: title),
                trailing: trailing,
                compact: ActivityContent(symbol: glyph, title: title, tint: .neutral, accessibilityLabel: title),
                expanded: ActivityContent(
                    symbol: "music.note",
                    title: title,
                    // Both separators are *joining* text and are localized as such. The spaced em
                    // dash is a European typographic convention and not a universal one — zh-Hans
                    // sets no spaces between characters and reserves the dash for 破折号 — so a
                    // hardcoded " — " would be Isleta punctuating Chinese in English.
                    subtitle: Self.joined(
                        [artist, album],
                        separator: activityText("nowPlaying.metadataSeparator", " — ")
                    ),
                    value: timeline.map { ActivityValue.timeline($0) },
                    tint: .neutral,
                    accessibilityLabel: Self.joined(
                        [title, artist],
                        separator: activityText("nowPlaying.a11ySeparator", " by ")
                    )
                )
            )
        )
    }

    /// §2.6. `level` is clamped by `ActivityValue.normalized` at the point of use; it is stored raw
    /// so a provider reading back 1.0000000149 from CoreAudio is not silently rewritten here.
    ///
    /// - Parameter limit: the end of the range this reading *landed on*, if it did — see
    ///   `ActivityLimit`. Supplied by the source rather than derived here from `level`, and the mute
    ///   HUD is why: it publishes level zero, which is not a level being run to the bottom. Deriving
    ///   it from the number would bounce the island every time somebody muted.
    public static func systemHUD(_ hud: SystemHUD, level: Double, limit: ActivityLimit? = nil) -> Self {
        let value = ActivityValue.fraction(level)
        let tint: ActivityTint = hud == .mute ? .warning : .neutral
        let content = ActivityContent(
            symbol: hud.symbol,
            // The level, drawn *into* the glyph as well as beside it — see
            // `ActivityContent.symbolVariableValue`. Only `speaker.wave.2.fill` answers, which is
            // the one the user watches while they are turning the volume; the mute and brightness
            // glyphs ignore it and draw as they always did.
            symbolVariableValue: level,
            title: hud.label,
            value: value,
            tint: tint,
            accessibilityLabel: hud.accessibilityLabel
        )
        return Self(
            kind: .systemHUD,
            presentations: ActivityPresentations(
                // The glyph **and the word**, which is what `ActivityKind.namesItselfInFlanks`
                // widens the island to hold: a volume key and a brightness key draw the same
                // picture, and the word is the only part of it that says which one was pressed. The
                // spoken label is supplied as well, because "Volume" on screen and "Volume" read
                // aloud are the same string only by coincidence — see `SystemHUD.label`.
                leading: ActivityContent(
                    symbol: hud.symbol,
                    symbolVariableValue: level,
                    title: hud.label,
                    tint: tint,
                    accessibilityLabel: hud.accessibilityLabel
                ),
                trailing: ActivityContent(value: value, tint: tint),
                compact: content,
                expanded: content
            ),
            reachedLimit: limit
        )
    }

    /// §2.5. A wake/unlock moment, never described as a lock screen feature.
    public static func welcomeBack(greeting: String, subtitle: String? = nil) -> Self {
        Self(
            kind: .welcomeBack,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: "hand.wave.fill", tint: .neutral),
                compact: ActivityContent(symbol: "hand.wave.fill", title: greeting, tint: .neutral),
                expanded: ActivityContent(
                    symbol: "hand.wave.fill",
                    title: greeting,
                    subtitle: subtitle,
                    tint: .neutral
                )
            )
        )
    }

    /// A Bluetooth audio device that has just connected.
    ///
    /// The one activity whose two slivers are a picture and a ring rather than a glyph and a
    /// string, so — like Now Playing and the timer before it — it is drawn by a bespoke view and
    /// declares its content here as ordinary data anyway. `DeviceConnectSlotView` reads the symbol
    /// out of the leading slot and the fraction out of the trailing one, so nothing downstream has
    /// to know about Bluetooth to lay it out or to speak it aloud.
    ///
    /// The trailing slot is `.empty` when the device reported no battery — a third-party pair, or
    /// an Apple one that has not answered yet. That is what collapses the island back to its
    /// unflanked width rather than drawing an empty ring, which would be a claim about the charge
    /// and a false one.
    public static func deviceConnected(_ device: BluetoothDeviceConnection) -> Self {
        let fraction = device.battery.fraction
        let spoken = device.battery.displayedPercent
            .map { activityText("device.connected.a11y.battery", "\(device.name) connected, \($0) percent battery") }
            ?? activityText("device.connected.a11y", "\(device.name) connected")
        return Self(
            id: device.activityID,
            kind: .deviceConnected,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: device.kind.symbol, tint: .neutral, accessibilityLabel: spoken),
                trailing: fraction.map { ActivityContent(value: .fraction($0), tint: .positive) } ?? .empty,
                compact: ActivityContent(
                    symbol: device.kind.symbol,
                    title: device.name,
                    value: fraction.map { ActivityValue.fraction($0) },
                    tint: .neutral,
                    accessibilityLabel: spoken
                ),
                expanded: ActivityContent(
                    symbol: device.kind.symbol,
                    title: device.name,
                    subtitle: device.battery.displayedPercent
                        .map { activityText("device.connected.battery", "\($0)%") }
                        ?? activityText("device.connected.subtitle", "Connected"),
                    value: fraction.map { ActivityValue.fraction($0) },
                    tint: .neutral,
                    accessibilityLabel: spoken
                )
            )
        )
    }

    /// Joins the non-nil parts, or nil if there are none.
    ///
    /// `nil` rather than `""`, because `ActivityContent.isEmpty` is what tells IslandUI to draw
    /// nothing at all; an empty string would reserve a line's worth of height for a subtitle that
    /// has no text in it, and the island would sit a few points taller for an unnamed artist.
    private static func joined(_ parts: [String?], separator: String) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: separator)
    }

    /// §2.7. One of Apple's Clock timers.
    ///
    /// Three shapes, and they come from what `mobiletimerd` actually stores — see
    /// `MobileTimerState` for the measurements:
    ///
    /// - **Running** carries the absolute instant it will fire, so the island counts down against
    ///   its own display link with nothing to poll and no drift to correct.
    /// - **Paused** carries the time *remaining*, frozen. Expressed as an `ActivityTimeline` with
    ///   the same backwards timeline with `rate` zero, so `position(at:)` returns the same number
    ///   forever and the display link stops dead rather than redrawing an identical string.
    /// - **Finished** is momentary and loud: `.interrupting`, with a dwell, so it takes the stage
    ///   the way a volume HUD does and then leaves.
    public static func timer(
        id: ActivityID,
        title: String?,
        state: TimerRunState,
        totalDuration: TimeInterval,
        now: Date = Date()
    ) -> Self {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? activityText("timer.untitled", "Timer")
        // A timeline that runs **backwards**: `elapsed` is what is left, `rate` is -1, and
        // `duration` is what the timer was set for. Every consumer then does the right thing from
        // one value — `position(at:)` is the remaining time and clamps at zero, `fraction(at:)` is
        // the shrinking arc Clock draws, and `isAdvancing` is false when paused so the display link
        // stops dead rather than redrawing an identical number once a second.
        //
        // A `.countdown(until:)` would give the numerals and no fraction, so the ring would have
        // nothing to draw; a forwards timeline would give an arc that fills up as time runs out.
        let value: ActivityValue? = switch state {
        case .running(let fireDate):
            .timeline(ActivityTimeline(
                elapsed: max(0, fireDate.timeIntervalSince(now)),
                duration: max(totalDuration, fireDate.timeIntervalSince(now)),
                anchor: now,
                rate: -1
            ))
        case .paused(let remaining):
            .timeline(ActivityTimeline(
                elapsed: remaining, duration: max(totalDuration, remaining), anchor: now, rate: 0
            ))
        case .finished:
            nil
        }
        let symbol = switch state {
        case .running: "timer"
        case .paused: "pause.circle.fill"
        case .finished: "timer"
        }
        let tint: ActivityTint = state.isFinished ? .warning : .neutral
        let subtitle = switch state {
        case .running: nil as String?
        case .paused: activityText("timer.paused", "Paused")
        case .finished: activityText("timer.finished", "Time's up")
        }
        return Self(
            id: id,
            kind: .timer,
            // A finished timer is an interruption with a dwell; a live one is ambient and stays.
            priority: state.isFinished ? .interrupting : nil,
            expiry: state.isFinished ? .after(.seconds(6)) : nil,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: symbol, tint: tint),
                // The trailing sliver is the timer's whole point, and its flank affinity puts it
                // there — see `ActivityKind.flankAffinity`.
                trailing: value.map { ActivityContent(value: $0, tint: tint) }
                    ?? ActivityContent(symbol: "bell.fill", tint: tint),
                compact: ActivityContent(symbol: symbol, title: name, value: value, tint: tint),
                expanded: ActivityContent(
                    symbol: symbol,
                    title: name,
                    subtitle: subtitle,
                    value: value,
                    tint: tint,
                    accessibilityLabel: state.isFinished
                        ? activityText("timer.finished.a11y", "\(name) finished")
                        : name
                )
            )
        )
    }

    /// §5, Milestone 3. Lives until the user empties it.
    public static func shelf(itemCount: Int) -> Self {
        // One key and one plural rule, in `Localizable.stringsdict`. The `== 1` branch this replaced
        // was a second plural rule in Swift, and two of them are free to disagree — French counts 0
        // as singular and zh-Hans has no singular at all, neither of which a ternary can say.
        let label = activityText("shelf.itemCount", "\(itemCount) items")
        return Self(
            kind: .shelf,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: "tray.full.fill"),
                trailing: ActivityContent(title: "\(itemCount)"),
                compact: ActivityContent(symbol: "tray.full.fill", title: label),
                expanded: ActivityContent(
                    symbol: "tray.full.fill",
                    title: activityText("shelf.title", "Shelf"),
                    subtitle: label
                )
            )
        )
    }
}
