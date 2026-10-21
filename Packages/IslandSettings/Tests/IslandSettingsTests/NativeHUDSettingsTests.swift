import Foundation
import Testing
@testable import IslandSettings

@Suite("Native system level HUDs")
struct NativeHUDSettingsTests {
    @Test("upgrading an enabled replacement restores native HUDs without changing other sources")
    func upgradeRestoresNativeHUDs() throws {
        let data = Data(#"{"schemaVersion":26,"suppressSystemHUDs":true,"suppressBrightnessHUD":true,"sources":{"systemHUDs":true,"nowPlaying":false,"timers":true}}"#.utf8)
        let configuration = try SettingsMigration.decode(data)
        #expect(!configuration.sources.systemHUDs)
        #expect(!configuration.suppressSystemHUDs)
        #expect(!configuration.suppressBrightnessHUD)
        #expect(!configuration.sources.nowPlaying)
        #expect(configuration.sources.timers)
    }

    @Test("a deliberate opt-in in the current version survives a save and reload")
    func optInSurvivesReload() throws {
        var configuration = IsletaConfiguration()
        configuration.sources.systemHUDs = true
        configuration.suppressSystemHUDs = true
        let reloaded = try SettingsMigration.decode(SettingsMigration.encode(configuration))
        #expect(reloaded.sources.systemHUDs)
        #expect(reloaded.suppressSystemHUDs)
        #expect(!reloaded.suppressBrightnessHUD)
    }
}
