import IslandActivities
import Observation
import SwiftUI

/// The day and the weather, as the island holds them.
///
/// # Why this exists at all, and why it is not `ActivityContent`
///
/// Every other activity describes itself as data in four slots and `ActivityContentView` draws it,
/// which is what keeps IslandActivities free of SwiftUI. The glance cannot: it draws a *list* of
/// events, each with a time, a color and possibly a button that opens a URL, and the four-slot
/// vocabulary has no word for any of that. PROGRESS.md already sanctions the escape hatch — "a
/// bespoke view belongs in IslandUI keyed on `ActivityKind`, never as an `AnyView` smuggled through
/// IslandActivities" — and this is the state that view reads.
///
/// So the glance activity publishes its two flanks and its compact badge as ordinary
/// `ActivityContent` (the glyph and the next time, which is what the collapsed island shows), and
/// publishes an **empty** `expanded` slot. `ActivitySlotLayout.bodySlot` returns nil for an empty
/// slot, so `ActivityLayerView` draws nothing in the open island's body and `GlanceLayerView` has it
/// to itself. `ShelfModel` is the same arrangement for the same reason.
///
/// # One instance for the whole app
///
/// Pushed into every `IslandScreenModel` by the shell, exactly as `NowPlayingController` is: there
/// is one day and one sky, and a model per panel would let the laptop and an external display
/// disagree about what is next.
///
/// # Nothing here is ever logged
///
/// Titles, notes, locations and join URLs are the user's own content, and `IslandLog` writes into
/// the file "Export Logs…" hands to strangers. This type deliberately has no `description` of its
/// own and is not `Encodable` — Swift's synthesised `description` spells every stored property, and
/// one careless interpolation would put somebody's calendar into a bug report. `DropHistoryModel`
/// found that the expensive way; this file inherits the lesson rather than repeating it.
@MainActor
@Observable
public final class GlanceModel {

    /// What is on today, what the sky is doing, and — crucially — what the calendar is *allowed* to
    /// say. See `CalendarAccess`: a refusal and an empty life produce identical events, and the
    /// empty-state copy is chosen from `access` and never from `events.isEmpty`.
    public var snapshot: GlanceSnapshot

    /// The units the user reads temperatures in. Held here rather than read from Settings by the
    /// view, so one change redraws one card instead of every consumer having to find the setting.
    public var temperatureUnit: TemperatureUnit

    /// The event a `.meeting` activity is currently about, or nil.
    ///
    /// Separate from `snapshot.events` on purpose: the meeting is a *moment* with a button, and the
    /// glance is a standing surface. Folding it into the snapshot would make the day list republish
    /// — and the island resize — every time a meeting became joinable.
    public var joinableMeeting: GlanceEvent?

    /// Open a join link. Set by the app shell, which is the only layer allowed to reach
    /// `NSWorkspace`. IslandUI must build and preview with no permission and no wiring (§3), so this
    /// is a closure rather than a call.
    public var onJoin: ((MeetingLink) -> Void)?

    /// Ask for the calendar, from a moment the user began. Nil where there is nothing to ask —
    /// which is every state except `.notDetermined`, and is why the empty glance sometimes draws a
    /// button and sometimes only a sentence.
    public var onRequestCalendarAccess: (() -> Void)?

    /// Open the Calendar row of System Settings' Privacy list.
    ///
    /// The other half of `onRequestCalendarAccess`, and the two are never both offered: the prompt
    /// can be raised exactly once, so after a refusal the trip to the pane is the only thing left
    /// that does anything. A closure for the same reason the one above is — IslandUI must draw with
    /// nothing injected (§3), and `NSWorkspace` belongs to the app shell.
    ///
    /// Nil where there is nothing to open, which `CalendarAccess.canBeGrantedInSettings` decides:
    /// a managed Mac's pane has no switch the user owns.
    public var onOpenCalendarSettings: (() -> Void)?

    /// Open one event in Calendar. What a click on a pill does.
    ///
    /// Takes the whole event rather than a URL, because the URL is the app shell's to resolve and
    /// the *decision* about which occurrence to name belongs to `GlanceEventLink` — see it for what
    /// is undocumented about that link and what happens if it stops working. Nil where nothing is
    /// wired, which is §3's layering test: a pill in a preview is inert rather than broken.
    public var onOpenEvent: ((GlanceEvent) -> Void)?

    // MARK: - The schedule surface

    /// Whether today and tomorrow are up in place of the day.
    ///
    /// Set inside the island's animated transaction by
    /// `IslandScreenModel.setShowingGlanceSchedule`, for the reason Up Next and the drop history
    /// both are: it puts the surface and the island's outline on one spring instead of swapping the
    /// body a frame ahead of the shape.
    ///
    /// **It was `isShowingMonth` until 2026-08-28**, when the six-week grid it named was replaced
    /// by the two days people actually ask a notch about. The surface is one flag either way, which
    /// is what `IslandRootView` and `AppDelegate.expandedContentHeightForStage` depend on.
    public var isShowingSchedule = false

    /// Everything on today, timed and all-day, in any order — `GlanceSchedulePlan` sorts and splits
    /// it. Filled by the shell when the surface opens, and emptied when it closes.
    ///
    /// **Held rather than derived from `snapshot.events`**, which is the *look-ahead*: it starts at
    /// "now" and is capped at `GlancePolicy.maximumEvents`, so a 9am meeting is gone from it by ten
    /// past and the fourth event of the day was never in it. A surface headed with today's date has
    /// to be able to say what today held, not what is left of the next few hours.
    public var todayEvents: [GlanceEvent] = []

    /// The same for tomorrow. Fetched with its own predicate at the same moment, so the two lists
    /// cannot disagree about where the boundary is.
    public var tomorrowEvents: [GlanceEvent] = []

    /// Show today and tomorrow. Routed through the shell rather than flipping the flag here, because
    /// opening changes the island's height *and* its width, and that has to go through the same
    /// widen-then-tighten path everything else does.
    public var onOpenSchedule: (() -> Void)?

    /// Put the day back. The same, in the other direction.
    public var onCloseSchedule: (() -> Void)?

    // MARK: - The weather surface

    /// Open the weather page.
    ///
    /// **The weather is an `IslandPage` now, not a flag on this model.** It was `isShowingWeather`
    /// here, and the pair it formed with the month grid's flag could be true together — which is why
    /// `IslandRootView` and `AppDelegate.expandedContentHeightForStage` both had to test them in the
    /// same order or the island was sized for one surface and drawing another. A page is a single
    /// value, so there is no pair and no order.
    ///
    /// Still routed through the shell rather than turning the page here, because a page change moves
    /// the island's height and that has to take the same widen-then-tighten path everything else
    /// does.
    ///
    /// **There is no `onCloseWeather`.** There was, and it went with the ✕ on 2026-08-28: the
    /// weather is a page, and a page is left by turning to another one or by closing the island —
    /// see `GlanceWeatherLayerView.header`.
    public var onOpenWeather: (() -> Void)?

    /// Whether the weather chip is a button at all right now.
    ///
    /// **Not simply "is there a reading".** A page opened onto a lone temperature is a large empty
    /// rectangle, which reads as a surface that failed to load rather than as a weather page — so a
    /// reading with no forecast and no detail behind it keeps its chip and loses its click, exactly
    /// as the empty glance keeps its sentence and loses its Allow button. See
    /// `WeatherReading.hasDetail`.
    public var canOpenWeather: Bool {
        onOpenWeather != nil && (snapshot.weather?.hasDetail ?? false)
    }

    /// Whether the weather is empty because nobody has told Isleta where to ask.
    ///
    /// **The weather page is one of three fixed pages, so it is there whether or not the weather
    /// is.** A user who has never opened Settings — which is everybody on a new install, since
    /// `GlanceSettings.usesCurrentLocation` is false and the city is empty by default — can swipe
    /// to a page that says the weather is not available and gives them nothing to do about it.
    /// That is the app reporting a fault where what it actually has is a setting nobody has set.
    ///
    /// **Only when Settings is where the fix is.** A build with no WeatherKit entitlement has no
    /// weather at all and no switch can turn one on (see `WeatherKitProvider`), and a place that is
    /// set but did not answer is a refresh that failed — both keep the plain sentence. This is
    /// exactly the discrimination the empty day makes between "Allow…" and "Open Settings": which
    /// control appears is decided by which one would do something, and where none would there is no
    /// control rather than a disabled one.
    ///
    /// Published by the app shell, which is the only layer that sees both the user's record and a
    /// running source — §3's layering test, the same reason the closures on this type are closures.
    public var weatherNeedsPlace = false

    public init(
        snapshot: GlanceSnapshot = GlanceSnapshot(),
        temperatureUnit: TemperatureUnit = .fromLocale()
    ) {
        self.snapshot = snapshot
        self.temperatureUnit = temperatureUnit
    }

    /// The events the open island lists — already capped by `GlancePolicy`, and capped again here
    /// against the layout's own ceiling so the view and the height cannot disagree about how many
    /// rows exist.
    public var rows: [GlanceEvent] {
        Array(snapshot.events.prefix(GlanceLayout.maximumRows))
    }

    /// How tall the island should open for what is currently held.
    ///
    /// Read by the app shell **before** the transition. That ordering is the whole of the contract
    /// this model has with `GlanceLayout`: `widenHitRegionForTransition` asks the controller where
    /// the island is going, so a height decided afterwards would widen the click region against the
    /// island being *left*.
    public func contentHeight(for kind: ActivityKind?) -> CGFloat? {
        GlanceLayout.contentHeight(for: kind, rowCount: rows.count)
    }

    /// Whether the glance has a button on it right now — which is also whether a click on the
    /// island's body could do something other than close it.
    public var canJoin: Bool { joinableMeeting?.meeting != nil }
}

/// A `GlanceTint` as something SwiftUI can fill with.
///
/// The one place a calendar's color becomes a `Color`, for the reason `ActivityTint` resolves in
/// this package and not in IslandActivities: the model layer must stay free of SwiftUI, and a color
/// resolved upstream could not respond to Increase Contrast.
extension GlanceTint {

    /// - Parameter increaseContrast: §6.3 is a correctness requirement. A calendar color on a black
    ///   island is decoration, and under increased contrast decoration that carries no information
    ///   the text does not already carry gives way to plain white rather than being brightened.
    func color(increaseContrast: Bool) -> Color {
        increaseContrast
            ? .white
            : Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// The same colour, lifted until it can be *read* — for a calendar's colour used as text rather
    /// than as a dot or a ground.
    ///
    /// A calendar colour is chosen to be told apart from eleven other calendar colours in a white
    /// sidebar, which is not the same job as carrying a word on black. Half of macOS's own set is
    /// dark enough that a title drawn straight in it disappears into the pill it sits on — the
    /// stock Graphite, and any deep blue or purple the user picked themselves.
    ///
    /// So the colour keeps its *hue* and gives up as much of its darkness as it has to. The
    /// luminance floor is Rec. 709, mixed toward white by exactly the fraction that reaches it and
    /// no more, so a colour already bright enough is returned untouched and a dark one arrives at
    /// the floor rather than at white — which is what keeps two dark calendars still telling
    /// themselves apart.
    ///
    /// White under Increase Contrast, like `color(increaseContrast:)`: §6.3, and a hue carrying no
    /// information the words do not already carry gives way rather than being brightened.
    func labelColor(increaseContrast: Bool) -> Color {
        guard !increaseContrast else { return .white }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let floor = 0.62
        guard luminance < floor else {
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }
        // The mix that lands a colour of this luminance exactly on the floor. Luminance is linear
        // in the channels and mixing toward white moves every channel by the same fraction of its
        // distance to 1, so the whole colour's luminance moves by that fraction of its own distance
        // to 1 — which is what makes this one division rather than a search.
        let mix = (floor - luminance) / (1 - luminance)
        return Color(
            .sRGB,
            red: red + (1 - red) * mix,
            green: green + (1 - green) * mix,
            blue: blue + (1 - blue) * mix,
            opacity: 1
        )
    }
}
