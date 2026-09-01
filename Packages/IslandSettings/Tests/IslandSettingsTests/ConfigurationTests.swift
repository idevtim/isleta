import Carbon.HIToolbox
import Foundation
import Testing

@testable import IslandSettings

@Suite("Configuration")
struct ConfigurationTests {

    @Test("the shipped defaults are the behavior that was hardcoded before settings existed")
    func defaultsMatchPreviousHardcodedBehavior() {
        let defaults = IsletaConfiguration.defaults
        #expect(defaults.toggleHotKey == .toggleIsland)               // ⌃⌥⌘I
        #expect(defaults.toggleHotKey.keyCode == kVK_ANSI_I)
        #expect(defaults.toggleHotKey.carbonModifiers == controlKey | optionKey | cmdKey)
        #expect(defaults.automaticUpdateChecks)
        #expect(defaults.showMenuBarIcon)                          // installStatusItem(), unconditionally
    }

    @Test("a configuration survives a round trip")
    func roundTrip() throws {
        var configuration = IsletaConfiguration.defaults
        configuration.showMenuBarIcon = false
        configuration.automaticUpdateChecks = false
        configuration.hiddenApplications = ["com.apple.Keynote"]
        configuration.toggleHotKey = HotKeyBinding(keyCode: kVK_ANSI_J, carbonModifiers: cmdKey | shiftKey)

        let decoded = try SettingsMigration.decode(SettingsMigration.encode(configuration))
        #expect(decoded == configuration)
    }

    /// The reason the decoder is hand-written. A file from a build that had not yet grown a field
    /// must lose only that field, not every setting the user chose.
    @Test("a missing key costs only that key")
    func missingKeysFallBackIndividually() throws {
        let json = """
        {"schemaVersion":1,"showMenuBarIcon":false,"minimalOnSynthesizedDisplays":true}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.minimalOnSynthesizedDisplays)
        #expect(decoded.automaticUpdateChecks == IsletaConfiguration.defaults.automaticUpdateChecks)
        #expect(decoded.toggleHotKey == IsletaConfiguration.defaults.toggleHotKey)
    }

    /// A hand-edited file with the wrong type in one field is the same problem as a missing one:
    /// it must not take the rest of the file down with it.
    @Test("a malformed value costs only that value")
    func malformedValuesFallBackIndividually() throws {
        let json = """
        {"schemaVersion":1,"showMenuBarIcon":"yes please","automaticUpdateChecks":false,
         "toggleHotKey":{"keyCode":"J"}}
        """
        let decoded = try SettingsMigration.decode(Data(json.utf8))

        #expect(decoded.showMenuBarIcon == IsletaConfiguration.defaults.showMenuBarIcon)
        #expect(decoded.toggleHotKey == IsletaConfiguration.defaults.toggleHotKey)
        #expect(decoded.automaticUpdateChecks == false)
    }
}

@Suite("Which keys changed, for the log")
struct ConfigurationChangedKeysTests {

    @Test("an unchanged configuration reports no keys")
    func nothingChanged() {
        #expect(IsletaConfiguration.changedKeys(from: .defaults, to: .defaults).isEmpty)
    }

    @Test("each edited field is named, in declaration order, and the schema stamp is not")
    func namesEditedFields() {
        var edited = IsletaConfiguration.defaults
        edited.automaticUpdateChecks.toggle()
        edited.showMenuBarIcon.toggle()
        edited.schemaVersion += 1
        #expect(
            IsletaConfiguration.changedKeys(from: .defaults, to: edited)
                == ["automaticUpdateChecks", "showMenuBarIcon"]
        )
    }
}
