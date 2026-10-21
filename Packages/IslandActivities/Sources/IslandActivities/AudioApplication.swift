import Foundation

/// One application with an observed audio session. Playback state is separate from audio IO:
/// an open client or a silent stream does not prove a track is playing or paused.
public struct AudioApplication: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case active, paused, inactive }
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let title: String?
    public let state: State

    public init(bundleIdentifier: String, name: String, title: String? = nil, state: State) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.title = title
        self.state = state
    }
}
