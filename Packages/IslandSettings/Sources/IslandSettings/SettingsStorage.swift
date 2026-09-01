import Foundation

/// Where the configuration blob lives.
///
/// One key, one blob, read once. A protocol rather than a direct `UserDefaults` call so the store's
/// tests can exercise migration, corruption and write-suppression against bytes they control —
/// hitting `UserDefaults.standard` from a test suite writes into the *test runner's* preference
/// domain, where it survives the process and quietly leaks into the next run.
///
/// `@MainActor` rather than `Sendable`: the configuration is read at launch and written from the
/// settings window, both on the main actor, and every consumer of a change is a main-actor callback.
/// Making the storage concurrency-safe instead would buy the ability to write settings from a
/// background thread, which nothing wants and which would let a write race the UI that caused it.
@MainActor
public protocol SettingsStorage: AnyObject {
    /// The stored bytes, or nil if nothing has ever been written.
    func readConfiguration() -> Data?
    func writeConfiguration(_ data: Data)
}

/// The shipping storage: one JSON blob in the app's own preference domain.
///
/// A single blob rather than one `UserDefaults` key per setting. Per-key storage looks tidier and
/// makes migration impossible to do atomically — a rename becomes read-old, write-new, delete-old
/// across three keys with no transaction, and a crash in the middle leaves a user half-migrated.
/// A blob migrates as one value or not at all.
@MainActor
public final class UserDefaultsSettingsStorage: SettingsStorage {

    /// Namespaced with the bundle id so `defaults read com.tryisleta.isleta` shows it under an
    /// obvious name and nothing else can collide with it.
    public static let configurationKey = "com.tryisleta.isleta.configuration"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func readConfiguration() -> Data? {
        defaults.data(forKey: Self.configurationKey)
    }

    public func writeConfiguration(_ data: Data) {
        defaults.set(data, forKey: Self.configurationKey)
    }
}

/// Storage that never touches the disk, for tests and previews.
@MainActor
public final class InMemorySettingsStorage: SettingsStorage {

    public var stored: Data?

    /// How many times the store has actually written. The store suppresses no-op updates, and the
    /// only way to prove it is to count.
    public private(set) var writeCount = 0

    public init(stored: Data? = nil) {
        self.stored = stored
    }

    public func readConfiguration() -> Data? { stored }

    public func writeConfiguration(_ data: Data) {
        stored = data
        writeCount += 1
    }
}
