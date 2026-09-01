import Testing
import IslandActivities
@testable import IslandSettings

/// The two questions this stage had to make answerable without a running app — "is Start a Timer
/// enabled when nothing can start a timer" and "does the menu show a Now Playing row when nothing
/// is playing" — are `startTimerIsNotDrawnWithNoHandler` and `nowPlayingIsDrawnDisabledWithNothingPlaying`.
@Suite("Status menu model")
struct StatusMenuModelTests {

    /// A machine where everything works: every quick action wired, every module on, everything on
    /// the island.
    private static func everything() -> StatusMenuModel.State {
        StatusMenuModel.State(
            sources: SourceToggles(),
            kindsOnIsland: [.nowPlaying, .glance, .timer],
            performableActions: [.showNowPlaying, .showWeather, .shortcut(.openGlance)],
            includesDebugItems: false
        )
    }

    /// What the app shell can actually do today: the two "bring it forward" actions, and no timer.
    private static func shipping() -> StatusMenuModel.State {
        StatusMenuModel.State(
            kindsOnIsland: [.nowPlaying, .glance],
            performableActions: [.showNowPlaying, .showWeather, .shortcut(.openGlance)]
        )
    }

    private static func items(_ state: StatusMenuModel.State) -> [StatusMenuItem] {
        StatusMenuModel.entries(for: state).compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        }
    }

    private static func availability(
        of action: StatusMenuAction,
        in state: StatusMenuModel.State
    ) -> StatusMenuItem.Availability? {
        StatusMenuModel.quickActions(for: state).first { $0.action == action }?.availability
    }

    // MARK: - The two questions

    @Test("the Now Playing row is drawn, disabled and explained when nothing is playing")
    func nowPlayingIsDrawnDisabledWithNothingPlaying() throws {
        var state = Self.shipping()
        state.kindsOnIsland = [.glance]

        let row = try #require(Self.items(state).first { $0.action == .showNowPlaying })
        #expect(row.isEnabled == false)
        // Asserts against the source language: under `swift test` every lookup falls back to the
        // English `defaultValue`. `LocalizationCoverageTests` is what guards the other languages.
        #expect(row.subtitle == "Nothing is playing")
    }

    @Test("the Now Playing row is live when something is playing")
    func nowPlayingIsReadyWhilePlaying() {
        let row = Self.items(Self.shipping()).first { $0.action == .showNowPlaying }
        #expect(row?.isEnabled == true)
        #expect(row?.subtitle == nil)
    }

    // MARK: - Enablement

    @Test("a module the user switched off takes its row out of the menu entirely")
    func switchedOffModuleIsNotDrawn() {
        var state = Self.everything()
        state.sources.nowPlaying = false

        #expect(Self.items(state).contains { $0.action == .showNowPlaying } == false)
        // Not merely absent — absent for the stated reason, so that a future change cannot make it
        // absent for the wrong one.
        #expect(Self.availability(of: .showNowPlaying, in: state)?.reason?.contains("switched off") == true)
    }

    @Test("no handler outranks everything else about a row")
    func missingHandlerOutranksTheModuleSwitch() {
        var state = Self.everything()
        state.performableActions = []
        for item in StatusMenuModel.quickActions(for: state) {
            #expect(item.isDrawn == false)
            #expect(item.availability.reason?.contains("listening") == true)
        }
    }

    @Test("a drawn row is either live or explains itself")
    func everyDisabledRowCarriesAReason() {
        for state in [Self.everything(), Self.shipping(), StatusMenuModel.State()] {
            for item in Self.items(state) where !item.isEnabled {
                #expect(item.subtitle?.isEmpty == false)
            }
        }
    }

    // MARK: - Order and separators

    @Test("the fixed rows are present, in order, with Quit last")
    func fixedRowsAreInOrder() {
        let actions = Self.items(Self.everything()).map(\.action)
        #expect(actions.last == .quit)
        let expected: [StatusMenuAction] = [.openSettings, .openSetupGuide, .exportLogs, .quit]
        #expect(actions.filter(expected.contains) == expected)
    }

    /// **The rows are the pages, in the pages' order.** Home, music, weather — the order a swipe
    /// walks them in, and the order the dots are drawn in. It was Now Playing above Glance, from
    /// when the two were activities being brought forward rather than pages being turned to; a menu
    /// listing them any other way teaches a carousel that does not exist.
    @Test("the quick actions are the three pages, in the pages' own order")
    func quickActionsFollowThePageOrder() {
        let actions = StatusMenuModel.quickActions(for: Self.everything()).map(\.action)
        #expect(actions == [.shortcut(.openGlance), .showNowPlaying, .showWeather])
    }

    /// The weather page is a fixed page and its empty state now offers Open Settings
    /// (`GlanceModel.weatherNeedsPlace`), so there is no state in which this row has nothing to act
    /// on — graying it out for somebody who has not picked a city would hide the one surface that
    /// tells them to.
    @Test("the weather row is live whenever its module is on")
    func weatherIsAlwaysLive() {
        var state = Self.shipping()
        state.kindsOnIsland = []
        let row = Self.items(state).first { $0.action == .showWeather }
        #expect(row?.isEnabled == true)
        #expect(row?.subtitle == nil)
    }

    /// The weather rides `sources.glance` in `SourceHub.apply` — it is the same module as the day,
    /// not a second switch — so switching Calendar and Weather off takes both rows.
    @Test("switching the calendar and weather module off takes the day and the forecast together")
    func theGlanceSwitchReachesBothPages() {
        var state = Self.everything()
        state.sources.glance = false
        let actions = Self.items(state).map(\.action)
        #expect(!actions.contains(.shortcut(.openGlance)))
        #expect(!actions.contains(.showWeather))
        // And leaves the music page alone, which is the point of asking per module.
        #expect(actions.contains(.showNowPlaying))
    }

    @Test("quick actions come before the windows")
    func quickActionsComeFirst() throws {
        // The reason the order changed from what shipped: a quick action is the thing somebody
        // clicks the icon for repeatedly, and Settings is the thing they open twice a year.
        let actions = Self.items(Self.everything()).map(\.action)
        let firstQuickAction = try #require(actions.firstIndex(of: .shortcut(.openGlance)))
        let settings = try #require(actions.firstIndex(of: .openSettings))
        #expect(firstQuickAction < settings)
    }

    @Test("a menu with no quick actions at all is exactly the menu that shipped before this stage")
    func noQuickActionsLeavesNoSeam() {
        let entries = StatusMenuModel.entries(for: StatusMenuModel.State())
        // No leading separator, and the first thing in the menu is Settings — which is what the
        // 1.3.x menu opened with. Asserts against the source language: under `swift test` every
        // lookup falls back to the English `defaultValue`, and `LocalizationCoverageTests` is what
        // guards the other languages.
        #expect(entries.first == .item(StatusMenuItem(
            action: .openSettings, title: "Open Isleta Settings", availability: .ready)))
    }

    @Test("no two separators are ever adjacent, and none is first or last")
    func separatorsAreOnlyBetweenGroups() {
        let states = [Self.everything(), Self.shipping(), StatusMenuModel.State()]
        for state in states {
            let entries = StatusMenuModel.entries(for: state)
            #expect(entries.first != .separator)
            #expect(entries.last != .separator)
            for pair in zip(entries, entries.dropFirst()) {
                #expect(!(pair.0 == .separator && pair.1 == .separator))
            }
        }
    }

    // MARK: - Debug rows

    @Test("the three development rows appear only when the shell says this build has them")
    func debugRowsAreGated() {
        var state = Self.everything()
        let debugActions: Set<StatusMenuAction> = [.debugOverlay, .probeAtPointer, .copyDiagnostics]

        #expect(Self.items(state).contains { debugActions.contains($0.action) } == false)

        state.includesDebugItems = true
        #expect(Set(Self.items(state).map(\.action)).isSuperset(of: debugActions))
    }

    // MARK: - Key equivalents

    @Test("no row that ships in a release build draws a key equivalent")
    func releaseRowsCarryNoKeyEquivalent() {
        // The CLAUDE.md rule made mechanical: an `.accessory` app installs no menu bar, so a glyph
        // here promises a system-wide shortcut that nothing dispatches. Quit's ⌘Q is included in
        // this — it shipped, and nothing dispatched it either.
        for item in Self.items(Self.everything()) {
            #expect(item.keyEquivalent == nil)
        }
    }

    @Test("only the two debug rows draw one, and only what installHotKeys really registered")
    func debugRowsMirrorRealRegistrations() {
        var state = Self.everything()
        state.includesDebugItems = true
        let byAction = Dictionary(uniqueKeysWithValues: Self.items(state).map { ($0.action, $0) })

        #expect(byAction[.debugOverlay]?.keyEquivalent
            == .init(character: "d", modifiers: [.option, .command]))
        #expect(byAction[.probeAtPointer]?.keyEquivalent
            == .init(character: "p", modifiers: [.option, .command]))
        // Copy Diagnostics holds no hot key in `installHotKeys`, so it draws none here.
        #expect(byAction[.copyDiagnostics]?.keyEquivalent == nil)
        #expect(byAction[.quit]?.keyEquivalent == nil)
    }

    // MARK: - One vocabulary

    @Test("a quick action's title says the same words as the shortcut behind it")
    func titlesDoNotForkTheVocabulary() {
        for item in StatusMenuModel.quickActions(for: Self.everything()) {
            guard let shortcut = item.action.shortcut else { continue }
            // Case differs on purpose — a menu is title case and a settings row is sentence case —
            // and nothing else may. "Today" or "Agenda" in place of "Show Calendar and Weather"
            // fails here, which is the point. Both sides are localized and both fall back to the
            // English `defaultValue` under `swift test`, so this asserts against the source
            // language; `LocalizationCoverageTests` is what guards the other languages, and each
            // table keeps the pair saying the same words for the same reason.
            #expect(item.title.lowercased() == shortcut.title.lowercased())
        }
    }

    @Test("every quick action that maps to a shortcut maps to one the user can bind")
    func quickActionShortcutsAreRealCases() {
        let bindable = Set(ShortcutAction.allCases)
        for item in StatusMenuModel.quickActions(for: Self.everything()) {
            guard let shortcut = item.action.shortcut else { continue }
            #expect(bindable.contains(shortcut))
        }
    }

    @Test("no two rows share an action")
    func rowIdentityIsUnique() {
        let actions = Self.items(Self.everything()).map(\.action)
        #expect(Set(actions).count == actions.count)
    }
}
