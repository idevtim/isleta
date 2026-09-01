import Carbon.HIToolbox
import Foundation
import Testing

@testable import IslandSettings

@Suite("Settings store")
@MainActor
struct SettingsStoreTests {

    /// First launch. Deliberately no write: stamping defaults onto a machine that has never
    /// expressed an intent gives every future migration a file to migrate for no reason.
    @Test("an empty store starts at the defaults and writes nothing")
    func emptyStoreDoesNotWrite() {
        let storage = InMemorySettingsStorage()
        let store = SettingsStore(storage: storage)

        #expect(store.configuration == .defaults)
        #expect(store.loadFailure == nil)
        #expect(storage.writeCount == 0)
    }

    @Test("an edit is persisted and read back by the next launch")
    func editsSurviveRelaunch() {
        let storage = InMemorySettingsStorage()
        SettingsStore(storage: storage).update { $0.showMenuBarIcon = false }

        #expect(storage.writeCount == 1)
        #expect(SettingsStore(storage: storage).configuration.showMenuBarIcon == false)
    }

    /// The check that stops a change handler which writes back from recursing forever.
    @Test("an update that changes nothing neither writes nor notifies")
    func noOpUpdatesAreSuppressed() {
        let storage = InMemorySettingsStorage()
        let store = SettingsStore(storage: storage)
        var notifications = 0
        store.addChangeHandler { _ in notifications += 1 }

        store.update { $0.showMenuBarIcon = store.configuration.showMenuBarIcon }
        store.update { _ in }

        #expect(storage.writeCount == 0)
        #expect(notifications == 0)
    }

    @Test("change handlers are called with the new configuration, and only while registered")
    func changeHandlersFireAndStop() {
        let store = SettingsStore(storage: InMemorySettingsStorage())
        var seen: [Bool] = []
        let token = store.addChangeHandler { seen.append($0.showMenuBarIcon) }

        store.update { $0.showMenuBarIcon = false }
        #expect(seen == [false])

        store.removeChangeHandler(token)
        store.update { $0.showMenuBarIcon = true }
        #expect(seen == [false])
    }

    @Test("resetting puts every setting back")
    func resetRestoresDefaults() {
        let store = SettingsStore(storage: InMemorySettingsStorage())
        store.update {
            $0.showMenuBarIcon = false
            $0.hiddenApplications = ["com.apple.Keynote"]
            $0.toggleHotKey = HotKeyBinding(keyCode: kVK_ANSI_K, carbonModifiers: cmdKey)
        }
        store.resetToDefaults()

        #expect(store.configuration == .defaults)
    }

    /// Falling back to defaults is the only sane recovery, and it is also indistinguishable — to
    /// the user — from Isleta having forgotten everything for no reason. So the reason is kept.
    @Test("an unreadable stored configuration falls back to defaults and says why")
    func corruptStorageFallsBackVisibly() {
        let storage = InMemorySettingsStorage(stored: Data("{ this is not json".utf8))
        let store = SettingsStore(storage: storage)

        #expect(store.configuration == .defaults)
        #expect(store.loadFailure != nil)
    }

    @Test("an edit always saves at the current schema version")
    func updatesStampTheCurrentVersion() {
        let stale = Data(#"{"schemaVersion":0,"showMenuBarIcon":true}"#.utf8)
        let store = SettingsStore(storage: InMemorySettingsStorage(stored: stale))

        store.update { $0.automaticUpdateChecks = false }
        #expect(store.configuration.schemaVersion == IsletaConfiguration.currentSchemaVersion)
    }
}
