import IslandActivities

/// Everything the status-item menu contains, in order, with each row's enablement and the reason
/// for it — as a value, so the whole of it can be asked questions with no running app.
///
/// **Why this is not assembled in `AppDelegate` where the `NSMenu` is built.** The two questions
/// this stage actually has to answer are "is Start a Timer enabled when nothing can start a timer"
/// and "does the menu show a Now Playing row when nothing is playing", and both were unanswerable
/// while the answer lived inside a function that needs an `NSStatusBar`, a running
/// `NSApplication` and — for the second one — music. Everything above the AppKit line is here;
/// `AppDelegate` keeps the twenty lines that turn a `StatusMenuEntry` into an `NSMenuItem`.
///
/// **The rule this model exists to enforce is `showMenuBarIcon`.** The icon can be switched off
/// (1.2.0), which takes this whole menu off the machine — so a row here may never be the *only*
/// door to anything. Every quick action below names its other door in its own doc comment, and the
/// two rows that are still the only door to something are named as such rather than quietly left.
public enum StatusMenuModel {

    // MARK: - The world the menu is drawn from

    /// What the app shell knows at the moment the menu opens.
    ///
    /// A **value handed in**, the way `SourceSettingsRow` is handed in, and for the same layering
    /// reason: this module must build and preview with nothing granted and no source constructed,
    /// so it cannot reach for an `ActivityCoordinator` or ask whether Music is running. The shell
    /// is the one layer that legitimately knows both halves, and it phrases them here.
    ///
    /// Assembled at `menuWillOpen`, never held. Opening the menu is already a user-initiated
    /// moment, which is what makes reading the world there free of the §9 idle budget — a cached
    /// copy would need something to invalidate it, and that something would be a timer.
    public struct State: Equatable, Sendable {

        /// The user's module switches, read straight off `IsletaConfiguration.sources`.
        ///
        /// `SourceToggles` and not a second `Set<ActivityKind>` of our own: the mapping from a kind
        /// to the flag behind it exists once, in `SourceToggles.subscript(kind:)`, and a menu that
        /// carried its own copy would be the second spelling of one vocabulary that that file
        /// argues at length against.
        public var sources: SourceToggles

        /// Every kind the island is currently holding — the switcher row's own roster,
        /// `ActivityCoordinator.chips` mapped to `\.kind`.
        ///
        /// Holding, not showing. A quick action that brings something to the front needs the thing
        /// to exist somewhere on the stack; whether it happens to be the activity on stage at this
        /// instant is exactly what the action is for changing.
        public var kindsOnIsland: Set<ActivityKind>

        /// The actions the shell has a handler for right now.
        ///
        /// The same honesty `AppDelegate.handler(for:)` already applies to hot keys: an action with
        /// nothing listening is not registered, because claiming a system-wide key in exchange for
        /// nothing happening is the worst trade in that file. A menu row is a cheaper version of
        /// the same trade and gets the same answer — it is left out of the menu entirely rather
        /// than drawn dead. See `Availability.unavailable`.
        ///
        /// Only the quick actions consult this. The fixed rows — Settings, the Setup Guide, Export
        /// Logs, Quit — are implemented in the shell unconditionally and are always drawn.
        public var performableActions: Set<StatusMenuAction>

        /// Whether this build carries the debug affordances.
        ///
        /// `#if DEBUG` cannot be asked at runtime from a package that is compiled once for both, so
        /// the shell passes what it knows. The three rows it gates are the same three
        /// `installStatusItem` gates today.
        public var includesDebugItems: Bool

        public init(
            sources: SourceToggles = SourceToggles(),
            kindsOnIsland: Set<ActivityKind> = [],
            performableActions: Set<StatusMenuAction> = [],
            includesDebugItems: Bool = false
        ) {
            self.sources = sources
            self.kindsOnIsland = kindsOnIsland
            self.performableActions = performableActions
            self.includesDebugItems = includesDebugItems
        }
    }

    // MARK: - The menu

    /// The menu as it should be drawn for `state`: rows and separators, in order.
    ///
    /// Separators are produced by joining the non-empty groups rather than by appending one after
    /// each, so a menu whose whole quick-action group is unavailable is **exactly** the menu that
    /// shipped before this stage — no leading separator, no doubled rule, nothing to say that
    /// something was left out. A menu that shows the seams of its own construction reads as broken.
    public static func entries(for state: State) -> [StatusMenuEntry] {
        let groups: [[StatusMenuItem]] = [
            quickActions(for: state).filter(\.isDrawn),
            windowItems(),
            diagnosticItems(for: state),
            [quitItem()]
        ]

        var entries: [StatusMenuEntry] = []
        for group in groups where !group.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(contentsOf: group.map(StatusMenuEntry.item))
        }
        return entries
    }

    /// Every quick action that was *considered*, drawn or not, with the availability that decided
    /// it.
    ///
    /// Exposed beside `entries` because the interesting half of this model is the rows that are
    /// missing, and a list that has already filtered them cannot be asked why. Tests read this;
    /// the menu reads `entries`.
    public static func quickActions(for state: State) -> [StatusMenuItem] {
        QuickAction.all.map { $0.item(for: state) }
    }

    // MARK: - The quick actions

    /// One of the things the status item offers besides windows and Quit.
    ///
    /// **One row per page, in the pages' own order**, and that is the whole roster: the three
    /// surfaces a person browses are the three things worth a row. Deliberately not every
    /// `ShortcutAction`, and the omission is the argument for the shape: `toggleIsland` was in this
    /// menu once and was removed, because
    /// reaching a thing whose whole point is being one keystroke away by first clicking a menu is
    /// the slowest possible route — and clicking the status item dismisses the menu over the notch
    /// the island is about to appear in.
    ///
    /// One more row, Start a Timer, stood here and was **never drawn**: `TimerSource` reads Apple's
    /// Clock and cannot write to it, and macOS offers no API that starts a timer, so it was gated on
    /// an `Availability.unavailable` that was permanent. It went with `ShortcutAction.startTimer` in
    /// schema 18. If Isleta ever owns a timer of its own, the row and the shortcut come back
    /// together — one edit, next to the handler that makes them mean something.
    private struct QuickAction {

        /// What the shell is asked to do.
        let action: StatusMenuAction

        /// The module switch this row lives or dies by.
        let kind: ActivityKind

        /// The row's title.
        ///
        /// Held here rather than read from `ShortcutAction.title` for one reason, and it is
        /// capitalisation: a menu is title case and a settings row is sentence case, so
        /// `ShortcutAction.openGlance.title` — "Show glance" — would sit under "Open Isleta
        /// Settings" in the wrong case. That is a presentation difference and it is **not** license
        /// to invent a second name: `StatusMenuModelTests` pins every one of these to the same
        /// words as the `ShortcutAction` behind it, so "Today" or "Agenda" fails the build while
        /// "Show Glance" passes.
        let title: String

        /// What the row says about itself when it is drawn and cannot act, or **nil** for a row
        /// that can always act once its module is on.
        ///
        /// One optional rather than the `bringsSomethingForward` flag plus a mandatory string it
        /// used to be, and the change is what the pages made of this menu. A row that brings
        /// something the island *holds* to the front can be blocked by there being nothing to hold;
        /// a row that turns to a **page** cannot, because the pages are a fixed enum and are
        /// therefore always all there (`IslandPage`). Two fields let those disagree — a nil reason
        /// beside a true flag, or a reason nothing could ever read.
        ///
        /// Written as a fact rather than a cause. The model cannot know *why* nothing is playing —
        /// paused, no player running, the adapter refused — and a row that guesses is a row that is
        /// wrong on somebody's machine.
        let nothingToActOnReason: String?

        /// The three rows, **in the order the pages are in**: home, music, weather.
        ///
        /// `IslandPage.allCases`' order, and not a coincidence — every one of these opens the island
        /// on a page, so a menu that listed them in some other order would be teaching a carousel
        /// that does not exist. It was Now Playing above Glance, from when the two were activities
        /// being brought forward rather than pages being turned to, and the pages are what made the
        /// order mean something.
        static let all: [QuickAction] = [
            // Opens the island on `IslandPage.home` — the day beside what is playing.
            //
            // **Never `nothingToActOn`, and that is what the pages changed here.** This row asked
            // whether the stack was holding a `.glance` activity, because through 2.0 the calendar
            // stood on it as an ambient one. It does not any more — the day and the sky are a
            // snapshot the pages read — so the same question would now answer "no" forever and
            // gray the row out on every Mac. A page is always there; the module switch above is
            // the only thing that can take this row away.
            //
            // The other way in: `ShortcutAction.openGlance`, bindable in Settings ▸ Shortcuts, and
            // a two-finger swipe on an open island.
            QuickAction(
                action: .shortcut(.openGlance),
                kind: .glance,
                title: settingsText("menu.showGlance", "Show Glance"),
                nothingToActOnReason: nil
            ),
            // Opens the island on `IslandPage.music` — the full player, not merely the sliver.
            //
            // **The other way in: the island itself.** `ShortcutAction.toggleIsland` is the one
            // shortcut that ships bound, precisely so that a user who has hidden the menu bar icon
            // still has a door, and the music page is one two-finger swipe from wherever it opens.
            //
            // It carries no `ShortcutAction` of its own, and that is a gap rather than a decision:
            // the vocabulary has `openGlance` and no "show Now Playing". Adding a case belongs in
            // the same edit as the Settings row that binds it, so it is parked and
            // `StatusMenuAction.showNowPlaying` stands in until then.
            //
            // **Still gated on something playing**, unlike the two pages either side of it, and the
            // asymmetry is the honest one: the page is always there, but a music page with no track
            // is a heading over an empty box, and a menu row that opens one has promised something
            // it did not deliver.
            QuickAction(
                action: .showNowPlaying,
                kind: .nowPlaying,
                title: settingsText("menu.showNowPlaying", "Show Now Playing"),
                nothingToActOnReason: settingsText("menu.showNowPlaying.nothing", "Nothing is playing")
            ),
            // Opens the island on `IslandPage.weather` — the forecast.
            //
            // **`.glance`, the same module switch as the day**, because it is the same module: the
            // weather source rides `sources.glance` in `SourceHub.apply`, and a Mac with the
            // Calendar and Weather module off has no forecast to show. A row with a switch of its
            // own would be a second spelling of one setting.
            //
            // **Never `nothingToActOn`, for the day's reason and one of its own.** The page is
            // always there, and a weather page with nothing on it is no longer a dead end: where
            // the record has no place it says so and offers Open Settings
            // (`GlanceModel.weatherNeedsPlace`). Graying this row out for a user who has not picked
            // a city would hide the one surface that tells them to.
            //
            // The other ways in: a two-finger swipe, and the weather chip on the day. It carries no
            // `ShortcutAction`, parked for `showNowPlaying`'s reason and in the same future edit.
            QuickAction(
                action: .showWeather,
                kind: .glance,
                title: settingsText("menu.showWeather", "Show Weather"),
                nothingToActOnReason: nil
            )
        ]

        func item(for state: State) -> StatusMenuItem {
            StatusMenuItem(
                action: action,
                title: title,
                availability: availability(for: state),
                keyEquivalent: nil
            )
        }

        /// The three-state answer, in the order the states rule each other out.
        ///
        /// Three cases and not a `Bool`, for `SourceSettingsRow.Status`' reason: "works", "would
        /// work if there were something to work on" and "cannot happen on this build at all" need
        /// three different treatments, and collapsing the last two is how an app ends up drawing a
        /// dead row for a feature that does not exist.
        private func availability(for state: State) -> StatusMenuItem.Availability {
            // First, because it outranks everything: an action nothing is listening for cannot be
            // rescued by the module being on or by something being on the island.
            guard state.performableActions.contains(action) else {
                return .unavailable("nothing in the app is listening for this action yet")
            }
            // The user's own switch. A row for a module they have turned off is clutter at best
            // and, if it worked, would be Isleta overruling them.
            guard state.sources[kind] else {
                return .unavailable("the \(kind.rawValue) module is switched off in Settings")
            }
            // A row that turns to a page has nothing left to check — see `nothingToActOnReason`.
            guard let nothingToActOnReason else { return .ready }
            guard state.kindsOnIsland.contains(kind) else {
                return .nothingToActOn(nothingToActOnReason)
            }
            return .ready
        }
    }

    // MARK: - The fixed rows

    /// The two rows that open a window.
    ///
    /// Unchanged from what shipped, titles included — "Open Isleta Settings" rather than
    /// "Settings…" because this menu is reachable while any other app is frontmost, where a bare
    /// "Settings" reads as *that* app's.
    private static func windowItems() -> [StatusMenuItem] {
        [
            // Other way in: `--settings`, and the `[⚙]` on the island's own switcher row, which
            // 1.3.1 made reachable for any island with something on stage precisely so that this
            // row would stop being the only door.
            StatusMenuItem(
                action: .openSettings,
                title: settingsText("menu.openSettings", "Open Isleta Settings"),
                availability: .ready
            ),
            // **Still the only door, and named as one.** `--onboarding` reopens the flow and no
            // user will type it. The flow runs itself once per machine and closing it counts as
            // finishing, which is affordable only because it can be reopened — from here. A button
            // in Settings ▸ About would fix it; that file is not this stage's to edit.
            StatusMenuItem(
                action: .openSetupGuide,
                title: settingsText("menu.openSetupGuide", "Open Setup Guide"),
                availability: .ready
            )
        ]
    }

    /// Export Logs, and in a debug build the three development tools above it.
    private static func diagnosticItems(for state: State) -> [StatusMenuItem] {
        var items: [StatusMenuItem] = []
        if state.includesDebugItems {
            // The only two rows in this menu that may draw a key equivalent, and only because
            // `AppDelegate.installHotKeys` really does hand ⌥⌘D and ⌥⌘P to `RegisterEventHotKey`
            // in the same build configuration. The glyph is a report of a registration that
            // happened, not a promise made by a menu — see `StatusMenuItem.keyEquivalent`.
            items.append(StatusMenuItem(
                action: .debugOverlay,
                title: "Debug Overlay",
                availability: .ready,
                keyEquivalent: .init(character: "d", modifiers: [.option, .command])
            ))
            items.append(StatusMenuItem(
                action: .probeAtPointer,
                title: "Probe at Pointer",
                availability: .ready,
                keyEquivalent: .init(character: "p", modifiers: [.option, .command])
            ))
            items.append(StatusMenuItem(action: .copyDiagnostics, title: "Copy Diagnostics", availability: .ready))
        }
        // Other way in: Settings ▸ About, added in 1.3.1 for this exact reason, plus
        // `--export-logs <path>`. With an ellipsis, because it asks where to save before it acts.
        items.append(StatusMenuItem(
            action: .exportLogs,
            title: settingsText("menu.exportLogs", "Export Logs…"),
            availability: .ready
        ))
        return items
    }

    /// Quit.
    ///
    /// **The other door does not exist, and this is the one row where that is a real problem.** A
    /// user who switches the menu bar icon off has no way to quit Isleta short of Activity Monitor.
    /// The fix is a button in Settings ▸ About beside Export Logs, which is a one-line addition to
    /// a file this stage does not own; it is reported rather than left implicit.
    ///
    /// It carries **no ⌘Q**, which is a change from what shipped. See
    /// `StatusMenuItem.keyEquivalent`.
    private static func quitItem() -> StatusMenuItem {
        StatusMenuItem(action: .quit, title: settingsText("menu.quit", "Quit Isleta"), availability: .ready)
    }
}

// MARK: - What a row is

/// One row of the status menu, or the rule between two groups of them.
public enum StatusMenuEntry: Equatable, Sendable {
    case item(StatusMenuItem)
    case separator
}

/// One row of the status menu.
public struct StatusMenuItem: Equatable, Sendable, Identifiable {

    /// What the row does, and its identity — two rows for one action is not expressible.
    public let action: StatusMenuAction

    public var id: StatusMenuAction { action }

    public let title: String

    public let availability: Availability

    /// The combination drawn down the right-hand side of the row, and **nil for every row that
    /// ships in a release build**.
    ///
    /// A key equivalent on a status-item menu is not a shortcut. An `.accessory` app installs no
    /// menu bar, so nothing dispatches one unless this menu is already open — by which point the
    /// pointer is on the row and it is not needed. What it does instead is print a promise: the
    /// user reads ⌘Q or ⌘, as system-wide, tries it with their editor frontmost, and quits or
    /// configures *that*.
    ///
    /// So the rule here is narrow and factual: **a row may draw a combination only when something
    /// outside this menu has genuinely registered it.** Today that is exactly the two debug rows,
    /// whose ⌥⌘D and ⌥⌘P are real `RegisterEventHotKey` registrations made by
    /// `AppDelegate.installHotKeys` in the same `#if DEBUG`. Quit's ⌘Q, which shipped, fails the
    /// rule and is gone — nothing dispatches it, and the app it appears to promise to quit is
    /// whichever one the user is actually looking at.
    public let keyEquivalent: KeyEquivalent?

    public init(
        action: StatusMenuAction,
        title: String,
        availability: Availability,
        keyEquivalent: KeyEquivalent? = nil
    ) {
        self.action = action
        self.title = title
        self.availability = availability
        self.keyEquivalent = keyEquivalent
    }

    /// Whether this row appears in the menu at all.
    public var isDrawn: Bool {
        switch availability {
        case .ready, .nothingToActOn: true
        case .unavailable: false
        }
    }

    /// Whether the row can be clicked.
    public var isEnabled: Bool {
        if case .ready = availability { return true }
        return false
    }

    /// The sentence under the title, or nil for a row that needs no explaining.
    ///
    /// A disabled row with no explanation is the thing this is here to avoid: the user reads "Show
    /// Now Playing" grayed out and learns that Isleta is broken. `NSMenuItem.subtitle` is where
    /// this lands.
    public var subtitle: String? {
        if case .nothingToActOn(let reason) = availability { return reason }
        return nil
    }

    /// What a row can do right now, in the three states that call for different treatment.
    ///
    /// Modelled on `SourceSettingsRow.Status`, which has three cases for the same reason: "working",
    /// "you could act on this" and "this cannot happen here" are three different sentences and
    /// three different answers to whether there is anything to draw.
    public enum Availability: Equatable, Sendable {

        /// Clicking it does the thing.
        case ready

        /// Drawn, disabled, with the reason underneath. The action exists and works; there is
        /// simply nothing for it to act on at this instant, and that can change while the user is
        /// looking at the menu bar.
        case nothingToActOn(String)

        /// Not drawn at all — the action does not exist in this build, or the user has switched
        /// its module off.
        ///
        /// **Left out rather than grayed, and that is the shipped precedent rather than a
        /// preference.** `suppressSystemHUDs` was a switch that could never move; graying it did
        /// not make it honest, and it was removed in schema 4 along with the pane that held it. A
        /// permanently dead row raises exactly one question — "why can't I click that?" — to which
        /// the menu has no way to answer.
        ///
        /// The string is for tests and for whoever reads this file, never for the user: there is no
        /// row to put it on.
        case unavailable(String)

        /// The reason, whatever the case. Nil for `.ready`, which needs none.
        public var reason: String? {
            switch self {
            case .ready: nil
            case .nothingToActOn(let text), .unavailable(let text): text
            }
        }
    }

    /// A combination drawn beside a row.
    ///
    /// Spelled out here rather than as an `NSEvent.ModifierFlags` so this model stays AppKit-free
    /// and testable with no running application; `AppDelegate` converts at the boundary, which is
    /// four lines.
    public struct KeyEquivalent: Equatable, Sendable {

        public struct Modifiers: OptionSet, Equatable, Sendable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
            public static let command = Modifiers(rawValue: 1 << 0)
            public static let option = Modifiers(rawValue: 1 << 1)
            public static let control = Modifiers(rawValue: 1 << 2)
            public static let shift = Modifiers(rawValue: 1 << 3)
        }

        /// The character AppKit matches on — lowercase, as `NSMenuItem` expects.
        public let character: String

        public let modifiers: Modifiers

        public init(character: String, modifiers: Modifiers) {
            self.character = character
            self.modifiers = modifiers
        }
    }
}

// MARK: - What a row does

/// Everything a status-menu row can ask the app shell to do.
///
/// Closed, for `ShortcutAction`'s reason: an open string would let each stage invent its own row
/// and there would be no one place to read what the status item offers.
///
/// **`.shortcut` is the whole point of the shape.** The things this menu can do that are not
/// windows are already named in `ShortcutAction`, and a menu that spelled them again —
/// `case openGlance`, `case startTimer` — would be the second spelling of one vocabulary that
/// `SourceToggles` argues against at length: two lists that must be kept in step, with nothing but
/// diligence keeping them there. Wrapping the existing case means the menu and the shortcut card
/// cannot drift, and that `AppDelegate` can hand both to one method.
public enum StatusMenuAction: Hashable, Sendable {

    /// One of the user's bindable actions, reached from the menu instead of from a key.
    case shortcut(ShortcutAction)

    /// Open the island on the music page.
    ///
    /// **Parked, not invented.** This belongs in `ShortcutAction` beside `openGlance` — it is the
    /// same kind of thing, a page to turn to, and a user who can bind "Show glance" to a key should
    /// be able to bind "Show Now Playing" too. Adding a case there means
    /// touching a shared record that Settings, the migration and the app shell all read, which is
    /// an edit that belongs with the Settings row that binds it rather than smuggled in here. Until
    /// then this case carries the action, and the day it moves this one is deleted rather than kept
    /// as an alias.
    case showNowPlaying

    /// Open the island on the weather page.
    ///
    /// **Parked beside `showNowPlaying`, and the two move together.** Both belong in
    /// `ShortcutAction` next to `openGlance` — all three are the same kind of thing, a page to turn
    /// to — and a user who can bind "Show glance" to a key should be able to bind these. That edit
    /// touches a shared record Settings, the migration and the app shell all read, so it belongs
    /// with the Settings rows that bind them rather than smuggled in here.
    case showWeather

    case openSettings
    case openSetupGuide
    case exportLogs

    /// Debug builds only, all three.
    case debugOverlay
    case probeAtPointer
    case copyDiagnostics

    case quit

    /// The bindable action behind this row, for the three rows that have one.
    ///
    /// What makes the vocabulary claim checkable rather than a comment: a test walks the quick
    /// actions and asserts each title says the same words as `ShortcutAction.title`.
    public var shortcut: ShortcutAction? {
        if case .shortcut(let action) = self { return action }
        return nil
    }
}
