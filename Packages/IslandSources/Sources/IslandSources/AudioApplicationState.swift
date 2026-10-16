import IslandActivities

/// Keeps paused sessions when another app takes Now Playing. Only explicit player state is
/// called paused; a stopped audio stream alone is inactive, and a microphone never adds a row.
public struct AudioApplicationState: Sendable {
    private var sessions: [String: NowPlayingSnapshot] = [:]
    private var observedOutput: Set<String> = []
    private var activeOutput: Set<String> = []
    private var currentPlayer: String?

    public init() {}

    public mutating func update(_ snapshot: NowPlayingSnapshot?) {
        // A global clear can be the gap between two owners. It says nothing about an explicit
        // pause in another app; only that app's stop notification or its exit clears that session.
        if snapshot == nil, let previous = currentPlayer, sessions[previous]?.isPlaying != false {
            sessions[previous] = nil
            observedOutput.remove(previous)
        }
        currentPlayer = snapshot?.bundleIdentifier
        guard let snapshot, let id = snapshot.bundleIdentifier else { return }
        sessions[id] = snapshot
    }

    public mutating func updatePlayer(_ update: NowPlayingUpdate, bundleIdentifier: String) {
        switch update {
        case .snapshot(let snapshot): sessions[bundleIdentifier] = snapshot
        case .cleared:
            sessions[bundleIdentifier] = nil
            observedOutput.remove(bundleIdentifier)
        }
    }

    public mutating func setActiveOutput(_ identifiers: Set<String>) {
        activeOutput = identifiers
        observedOutput.formUnion(identifiers)
    }

    public mutating func applications(running: [String: String]) -> [AudioApplication] {
        sessions = sessions.filter { running[$0.key] != nil }
        observedOutput = observedOutput.intersection(running.keys)
        return observedOutput.union(sessions.keys).compactMap { id in
            guard let name = running[id] else { return nil }
            let session = sessions[id]
            let state: AudioApplication.State
            if session?.isPlaying == false { state = .paused }
            else if activeOutput.contains(id) { state = .active }
            else if currentPlayer == id, session?.isPlaying == true { state = .active }
            else { state = .inactive }
            return AudioApplication(bundleIdentifier: id, name: name, title: session?.title, state: state)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
