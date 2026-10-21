import Foundation
import Testing
@testable import IslandSettings

@Suite("Audio page settings")
struct AudioPageSettingsTests {
    @Test("existing installations keep the audio page and unrelated choices")
    func upgrade() throws {
        let old = Data(#"{"schemaVersion":27,"showMenuBarIcon":false,"suppressSystemHUDs":true,"showsAudioSourcesPage":false}"#.utf8)
        let decoded = try SettingsMigration.decode(old)
        #expect(!decoded.showsAudioSourcesPage)
        #expect(!decoded.showMenuBarIcon)
        #expect(decoded.suppressSystemHUDs)
        #expect(decoded.schemaVersion == 28)
        let missing = try SettingsMigration.decode(Data(#"{"schemaVersion":27}"#.utf8))
        #expect(missing.showsAudioSourcesPage)
    }

    @Test("hidden page survives encoding and malformed values use the visible default")
    func persists() throws {
        var config = IsletaConfiguration.defaults
        config.showsAudioSourcesPage = false
        let decoded = try SettingsMigration.decode(SettingsMigration.encode(config))
        #expect(!decoded.showsAudioSourcesPage)
        #expect(IsletaConfiguration.changedKeys(from: .defaults, to: config) == ["showsAudioSourcesPage"])
        for value in ["1", "\"false\"", "null", "[]"] {
            let malformed = try SettingsMigration.decode(Data("{\"schemaVersion\":27,\"showsAudioSourcesPage\":\(value)}".utf8))
            #expect(malformed.showsAudioSourcesPage)
        }
    }

    @Test("the shared status and context menu always offer the visibility toggle with its checkmark")
    func menu() throws {
        for visible in [true, false] {
            let rows = StatusMenuModel.entries(for: .init(showsAudioSourcesPage: visible)).compactMap { entry -> StatusMenuItem? in
                if case .item(let item) = entry { return item }
                return nil
            }
            let row = try #require(rows.first { $0.action == .toggleAudioSourcesPage })
            #expect(row.isEnabled)
            #expect(row.isChecked == visible)
            #expect(row.keyEquivalent == nil)
        }
    }
}
