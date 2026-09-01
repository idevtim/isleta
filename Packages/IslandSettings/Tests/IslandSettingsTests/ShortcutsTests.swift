import Carbon.HIToolbox
import Foundation
import Testing

@testable import IslandSettings

/// The vocabulary of global shortcuts, and the one property that makes it safe to have one at all:
/// `RegisterEventHotKey` is exclusive, so every binding in this record is a key no other app on the
/// user's Mac can use. Everything here is about not claiming one by accident.
@Suite("Shortcuts")
struct ShortcutsTests {

    /// The bar for shipping an action bound is that the feature is unreachable without it, and
    /// exactly one action clears it: Isleta has no Dock icon and its menu bar item can be hidden.
    @Test("only the island toggle ships bound")
    func onlyTheToggleShipsBound() {
        let bound = ShortcutAction.allCases.filter { $0.defaultBinding != nil }
        #expect(bound == [.toggleIsland])
        #expect(ShortcutAction.toggleIsland.defaultBinding == .toggleIsland)
    }

    /// Every shipped default has to survive its own validity rule, or Isleta would register a bare
    /// key at launch and the user would have to type that key to undo it.
    @Test("every shipped default is valid", arguments: ShortcutAction.allCases)
    func defaultsAreValid(action: ShortcutAction) {
        guard let binding = action.defaultBinding else { return }
        #expect(binding.isValid)
    }

    /// The distinction the whole record is built on: an absent key falls back to the default, and a
    /// key stored empty does not. Without it, clearing a shortcut would read as a bug — the default
    /// would come back on the next launch.
    @Test("clearing is remembered, and is not the same as never having chosen")
    func clearingIsNotAbsence() {
        var shortcuts = Shortcuts()
        #expect(shortcuts[.toggleIsland] == .toggleIsland)
        #expect(shortcuts.isCustomised(.toggleIsland) == false)

        shortcuts[.toggleIsland] = nil
        #expect(shortcuts[.toggleIsland] == nil, "a cleared shortcut must not resurrect its default")
        #expect(shortcuts.isCustomised(.toggleIsland))

        shortcuts.reset(.toggleIsland)
        #expect(shortcuts[.toggleIsland] == .toggleIsland)
        #expect(shortcuts.isCustomised(.toggleIsland) == false)
    }

    /// Two actions on one combination is not something to resolve at registration time:
    /// `RegisterEventHotKey` takes the same pair twice and then delivers to whichever handler it
    /// feels like — a bug that presents as "the shortcut works, but does the wrong thing about half
    /// the time". The recorder asks before it stores.
    @Test("a collision is found before it is registered")
    func collisionsAreFound() {
        var shortcuts = Shortcuts()
        let combination = HotKeyBinding(keyCode: kVK_ANSI_G, carbonModifiers: optionKey | cmdKey)
        shortcuts[.openGlance] = combination

        #expect(shortcuts.conflict(with: combination, excluding: .toggleIsland) == .openGlance)
        // An action never conflicts with itself, or rebinding a shortcut to what it already is
        // would report a collision with the row the user is editing.
        #expect(shortcuts.conflict(with: combination, excluding: .openGlance) == nil)
        #expect(shortcuts.conflict(with: .toggleIsland, excluding: .openGlance) == .toggleIsland)
    }

    /// An invalid binding is dropped where the list is built rather than where it is registered, so
    /// there is one place that decides what Isleta takes from the machine.
    @Test("active carries only what is bound and valid")
    func activeIsTheRegistrationList() {
        var shortcuts = Shortcuts()
        #expect(shortcuts.active.map(\.action) == [.toggleIsland])

        shortcuts[.openGlance] = HotKeyBinding(keyCode: kVK_ANSI_S, carbonModifiers: 0)
        #expect(shortcuts.active.map(\.action) == [.toggleIsland],
                "a shortcut with no ⌘/⌃/⌥ must never reach RegisterEventHotKey")

        shortcuts[.toggleIsland] = nil
        #expect(shortcuts.active.isEmpty)
    }

    /// The forwarder, and the one piece of policy in it: the island toggle is the only action that
    /// cannot be cleared, because clearing it locks a user out of an app with no Dock icon.
    @Test("the configuration's toggleHotKey is the shortcut record, not a second copy of it")
    func toggleHotKeyForwards() {
        var configuration = IsletaConfiguration.defaults
        #expect(configuration.toggleHotKey == .toggleIsland)

        let rebound = HotKeyBinding(keyCode: kVK_ANSI_J, carbonModifiers: cmdKey | controlKey)
        configuration.toggleHotKey = rebound
        #expect(configuration.shortcuts[.toggleIsland] == rebound)

        configuration.shortcuts[.openGlance] = rebound
        #expect(configuration.shortcuts.conflict(with: rebound, excluding: .openGlance) == .toggleIsland)

        // Cleared in the record, the forwarder still answers — the island toggle is rebindable and
        // not clearable, and this is where that is pinned.
        configuration.shortcuts[.toggleIsland] = nil
        #expect(configuration.toggleHotKey == .toggleIsland)
    }

    /// A v6 file holds the shortcut under the flat `toggleHotKey` key. It has to survive, or every
    /// existing user's rebound shortcut silently returns to ⌃⌥⌘I on upgrade.
    @Test("a schema 6 file keeps the shortcut the user chose")
    func legacyKeyMigrates() throws {
        let json = #"{"schemaVersion":6,"toggleHotKey":{"keyCode":38,"carbonModifiers":256}}"#
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.toggleHotKey.keyCode == 38)
        #expect(decoded.toggleHotKey.carbonModifiers == 256)
        #expect(decoded.shortcuts[.toggleIsland]?.keyCode == 38)

        // And it survives the round trip into the new shape, which is the half that matters: the
        // decoder's leniency keeps the file working, and the encoder is what stops the next reader
        // finding the shortcut in two places.
        let round = try JSONDecoder().decode(IsletaConfiguration.self, from: JSONEncoder().encode(decoded))
        #expect(round.toggleHotKey.keyCode == 38)
    }

    /// A file that has both keys was written by a build that had already migrated, so the record is
    /// the live one and the flat key is a leftover.
    @Test("the shortcut record wins over the legacy key it was migrated from")
    func recordWinsOverLegacy() throws {
        let json = """
        {"schemaVersion":7,
         "toggleHotKey":{"keyCode":38,"carbonModifiers":256},
         "shortcuts":{"assignments":{"toggleIsland":{"keyCode":40,"carbonModifiers":4096}}}}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))
        #expect(decoded.toggleHotKey.keyCode == 40)
    }
}
