import IslandKit
import Foundation
import Observation

/// The one copy of the configuration the running app agrees on.
///
/// Loaded once, at launch, from `SettingsStorage`. Nothing re-reads it and nothing polls it: a
/// setting can only change because this process changed it, so the store *is* the notification.
/// §9's "no polling when idle" is not a preference here — a settings module that watched its own
/// file would be the one component in Isleta holding a timer while the app sat still.
///
/// Changes reach consumers two ways, and both are push:
///
/// - **SwiftUI** observes `configuration` through `@Observable`, so the settings window redraws with
///   no wiring at all.
/// - **Everything else** registers a callback. The app shell needs to hear about a new hot key in
///   order to unregister the old one, and `withObservationTracking` is the wrong tool for that: it
///   is one-shot and has to be re-armed from inside its own handler, which is a re-entrancy bug
///   waiting for the first handler that also writes.
@MainActor
@Observable
public final class SettingsStore {

    /// The app-wide store. Anything that is not a test uses this one.
    public static let shared = SettingsStore()

    /// The current configuration. Whole-value: readers cannot see a partial edit.
    public private(set) var configuration: IsletaConfiguration

    /// Why the stored configuration could not be used, if it could not be.
    ///
    /// Surfaced rather than swallowed. Falling back to defaults after a failed read is the only
    /// sensible recovery, but it is also indistinguishable — to the user — from Isleta having
    /// forgotten everything for no reason, so the reason is kept and shown.
    public private(set) var loadFailure: String?

    @ObservationIgnored private let storage: any SettingsStorage
    @ObservationIgnored private var handlers: [UUID: @MainActor (IsletaConfiguration) -> Void] = [:]

    public init(storage: any SettingsStorage = UserDefaultsSettingsStorage()) {
        self.storage = storage

        guard let data = storage.readConfiguration() else {
            // Nothing stored is the normal first launch, not a failure. Deliberately *not* written
            // back here: writing defaults on first read would turn every launch of every build into
            // a preference write, and would stamp a schema version onto a machine that has never
            // expressed an intent — which then has to be migrated forever.
            configuration = .defaults
            IslandLog.settings.info("no stored configuration — using defaults")
            return
        }

        do {
            configuration = try SettingsMigration.decode(data)
            let stored = SettingsMigration.schemaVersion(of: data)
            IslandLog.settings.info(
                stored == IsletaConfiguration.currentSchemaVersion
                    ? "configuration loaded (schema \(stored))"
                    : "configuration loaded and migrated from schema \(stored) to \(IsletaConfiguration.currentSchemaVersion)"
            )
        } catch {
            configuration = .defaults
            loadFailure = "\(error)"
            IslandLog.settings.error("stored configuration could not be read, using defaults: \(error)")
        }
    }

    // MARK: - Changing it

    /// Applies an edit, persists it, and tells everyone — but only if it changed anything.
    ///
    /// The equality check is load-bearing, not an optimisation. A change handler that writes back
    /// (the app shell re-registering a hot key, say, and normalizing it as it does) would otherwise
    /// re-enter here and recurse. Comparing first makes the second pass a no-op and terminates it.
    public func update(_ mutate: (inout IsletaConfiguration) -> Void) {
        var edited = configuration
        mutate(&edited)
        edited.schemaVersion = IsletaConfiguration.currentSchemaVersion
        guard edited != configuration else { return }

        let previous = configuration
        configuration = edited
        persist(edited)
        // Which keys, not which values: a shortcut or a threshold is the user's own, and "the hot
        // key changed at 10:18" is what a report needs — the value is in the export's diagnostics.
        IslandLog.settings.info("configuration changed: \(IsletaConfiguration.changedKeys(from: previous, to: edited).joined(separator: ", "))")
        for handler in handlers.values { handler(edited) }
    }

    /// Puts every setting back to the shipped default.
    public func resetToDefaults() {
        update { $0 = .defaults }
    }

    private func persist(_ configuration: IsletaConfiguration) {
        do {
            storage.writeConfiguration(try SettingsMigration.encode(configuration))
        } catch {
            // Encoding a struct of Bools and Ints cannot fail in practice, but a silently dropped
            // write would present as settings that forget themselves across launches with nothing
            // anywhere to explain it.
            IslandLog.settings.error("configuration could not be written: \(error)")
        }
    }

    // MARK: - Observing it

    /// Identifies a registered change handler. Holding one is what lets an observer stop observing;
    /// dropping it on the floor is a leak, so the token is `@discardableResult` only for callers
    /// that genuinely live for the lifetime of the app.
    public struct ChangeToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Registers a callback fired after every change that changed something. Not called on
    /// registration — a caller that also wants the current value already has `configuration`, and
    /// calling back immediately would make "apply on launch" and "apply on change" two paths that
    /// have to stay in sync.
    @discardableResult
    public func addChangeHandler(
        _ handler: @escaping @MainActor (IsletaConfiguration) -> Void
    ) -> ChangeToken {
        let token = ChangeToken(id: UUID())
        handlers[token.id] = handler
        return token
    }

    public func removeChangeHandler(_ token: ChangeToken) {
        handlers[token.id] = nil
    }
}
