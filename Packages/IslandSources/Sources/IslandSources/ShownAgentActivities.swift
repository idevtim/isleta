import IslandActivities

/// Which activity each coding agent session has on the island, by the id it was *shown* with.
///
/// # Why this exists
///
/// The source used to work out the id to take down from the session it was tracking at the time of
/// taking it down. That id is the agent's session id, and the session behind one key can change
/// under it: Claude Code keeps one `<pid>.json` per process and rewrites its `sessionId` in place
/// when the conversation is replaced, and a resumed conversation brings an existing session id to a
/// second file. Either way the id the source would compute is not the id on the island, the
/// dismissal misses, and the activity stays on stage with nothing left that will ever take it down
/// — reported in 2.9.0 as a "needs your input" that a click no longer did anything to.
///
/// So the id is remembered when it goes up and that same id comes down. Pure, so the bookkeeping is
/// testable without a session file or a process.
struct ShownAgentActivities {

    private var shown: [String: ActivityID] = [:]

    /// `key` put `id` on the island. A key shows one activity at a time, so this replaces whatever
    /// it showed before — and returns that earlier id if it is now on the island for nobody.
    @discardableResult
    mutating func show(_ id: ActivityID, for key: String) -> ActivityID? {
        let previous = shown.updateValue(id, forKey: key)
        guard let previous, previous != id else { return nil }
        return isShown(previous) ? nil : previous
    }

    /// `key`'s activity is to come down. Returns the id to dismiss, or nil when `key` showed nothing
    /// — or when another session is showing the same id, which two files resuming one conversation
    /// do, and taking it down would take down the other's.
    mutating func takeDown(_ key: String) -> ActivityID? {
        guard let id = shown.removeValue(forKey: key) else { return nil }
        return isShown(id) ? nil : id
    }

    /// The island retired `id` itself — a click through to the terminal, or an answer given on it.
    /// Nothing is dismissed: it is already gone. What changes is that no session may re-say it until
    /// it shows something new.
    mutating func retired(_ id: ActivityID) {
        shown = shown.filter { $0.value != id }
    }

    /// Whether `key` has something on the island. Re-saying an activity in place — a prompt arrived,
    /// the reason for the wait changed — is only right while it is still there.
    func isShowing(_ key: String) -> Bool { shown[key] != nil }

    /// Whether any session is showing `id`.
    func isShown(_ id: ActivityID) -> Bool { shown.values.contains(id) }

    /// Every id on the island, each once, for `stop()`.
    var all: Set<ActivityID> { Set(shown.values) }

    /// The keys showing `id`, for finding the session a click landed on.
    func keys(showing id: ActivityID) -> [String] {
        shown.filter { $0.value == id }.map(\.key)
    }

    mutating func removeAll() { shown = [:] }
}
