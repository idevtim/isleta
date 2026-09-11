import Foundation

/// A `UserDefaults` that never reaches the disk.
///
/// ## Why not a suite
///
/// Every test here already knew not to write to `UserDefaults.standard`: from a test bundle that
/// lands in the *test runner's* preference domain, where it survives the process and leaks into the
/// next run. So both helpers that predated this file reached for `UserDefaults(suiteName:)` with a
/// unique name instead, which is correct about isolation and wrong about cost — **a suite is a
/// file.** `cfprefsd` writes `~/Library/Preferences/<name>.plist`, and a name that is unique per
/// test is exactly what stops the next run reusing it.
///
/// **Measured on 2026-09-10: 10,297 leftover plists against 725 real ones** — the suite had quietly
/// become 93% of that user's `~/Library/Preferences`. Two of the four leaking domains came from
/// tests deleted along with their features in 2.0 (the downloads island, the player bar, the
/// screen-recording prompt), so there was nothing left in the code to notice.
///
/// ## Why cleaning up after the suite was not enough
///
/// The obvious fix — remove the domain when the test ends — was tried first and does not hold.
/// `removePersistentDomain(forName:)` empties the domain in the API's view of it and leaves the
/// file; adding `synchronize()` and an explicit unlink gets it off disk; and then it comes back,
/// because `cfprefsd` is a **separate process** with its own cache of the domain and it writes the
/// file when it gets round to it. Measured across four full runs of this target with that fix in
/// place: 0, 7, 7 and 21 files left behind. The race is not winnable from inside the process that
/// is exiting.
///
/// So the file is not cleaned up. It is never created.
///
/// ## What it has to override, and why only these
///
/// `object(forKey:)`, `set(_:forKey:)` and `removeObject(forKey:)` are `UserDefaults`'
/// primitives — `integer(forKey:)`, `data(forKey:)`, `string(forKey:)` and the typed setters are
/// all documented to go through them. `OnboardingLedger` uses `integer`/`set`/`removeObject` and
/// `UserDefaultsSettingsStorage` uses `data`/`set`, so all five land here without either of them
/// knowing this exists. Nothing calls `super`, which is the whole point: there is no backing store
/// under this, so there is nothing to synchronise and nothing to remove.
final class InMemoryDefaults: UserDefaults {

    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        // `set(nil, forKey:)` is documented to be a removal, and `SettingsStore` relies on it.
        guard let value else {
            storage.removeValue(forKey: defaultName)
            return
        }
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
