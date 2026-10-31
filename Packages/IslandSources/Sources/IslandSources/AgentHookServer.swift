import Darwin
import Foundation
import IslandKit

/// One event the hook script sent, already trimmed to what the island shows (`AgentHookScript`).
///
/// Every field but the two that make it an event is optional: the script sends `null` for anything
/// the agent did not supply, and a later agent release dropping a field should cost that field.
public struct AgentHookEvent: Equatable, Sendable, Decodable {
    /// `claudeCode` or `codex` — the argument the agent's settings run the script with.
    public let agent: String
    /// The agent's own event name: `PermissionRequest`, `Stop`, `Notification`, …
    public let event: String
    public let sessionID: String?
    public let toolName: String?
    /// One line: the tool's own description of the call, else the file, URL, pattern or command.
    /// Shown on screen and **never logged**.
    public let summary: String?
    public let command: String?
    public let notificationType: String?
    /// The script's parent, which is the agent's process — the start of the walk to its terminal.
    public let agentPID: Int32?
    /// The session's folder — what finds Codex's terminal, since its hooks run under a shared
    /// process rather than the session's. Shown as the session's name, and **never logged**.
    public let cwd: String?

    enum CodingKeys: String, CodingKey {
        case agent, event, summary, command, cwd
        case sessionID = "session_id"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case agentPID = "agent_pid"
    }

    public init(
        agent: String, event: String, sessionID: String? = nil, toolName: String? = nil,
        summary: String? = nil, command: String? = nil, notificationType: String? = nil,
        agentPID: Int32? = nil, cwd: String? = nil
    ) {
        self.agent = agent
        self.event = event
        self.sessionID = sessionID
        self.toolName = toolName
        self.summary = summary
        self.command = command
        self.notificationType = notificationType
        self.agentPID = agentPID
        self.cwd = cwd
    }

    public var isPermissionRequest: Bool { event == "PermissionRequest" }

    static func decode(_ line: Data) -> AgentHookEvent? {
        try? JSONDecoder().decode(Self.self, from: line)
    }
}

/// The answer a held permission request is waiting for.
public enum AgentHookDecision: String, Sendable {
    case allow
    case deny
}

/// A permission request whose hook is still connected and waiting for one line back.
///
/// The connection *is* the request: answering writes the decision down the socket the hook asked on
/// and nowhere else, and closing it without an answer is how Isleta says "the terminal has this" —
/// the script then prints nothing and the agent's own prompt stands. Either way it is done once.
@MainActor
public final class AgentHookRequest {

    public let event: AgentHookEvent

    /// Called once if the hook goes away first — the agent killed it at its timeout, or exited.
    public var onPeerClosed: (() -> Void)?

    public private(set) var isOpen = true

    private let descriptor: Int32
    private var watcher: (any DispatchSourceRead)?

    init(event: AgentHookEvent, descriptor: Int32) {
        self.event = event
        self.descriptor = descriptor
        // Readable on a held connection means only one thing: the peer closed. The hook writes its
        // one line and then only reads.
        let watcher = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.peerClosed() }
        }
        watcher.resume()
        self.watcher = watcher
    }

    /// Send the decision and close. A no-op once closed.
    public func answer(_ decision: AgentHookDecision) {
        guard isOpen else { return }
        let line = decision.rawValue + "\n"
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
        close()
    }

    /// Close without answering, leaving the decision to the agent's own prompt. A no-op once closed.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        watcher?.cancel()
        watcher = nil
        Darwin.close(descriptor)
    }

    private func peerClosed() {
        guard isOpen else { return }
        close()
        onPeerClosed?()
    }
}

/// The Unix socket the hook script connects to.
///
/// # Who can reach it
///
/// The socket is `0600` in a `0700` directory, and every connection's peer is checked with
/// `getpeereid` against this process's own uid before a byte is read — so only the user's own
/// processes can say anything to the island, which is the same boundary their own settings file
/// has. A permission answer is never *read* from the socket, only written to it, so a connection
/// can at most put a question on the island; it cannot answer one.
///
/// # Why this keeps no timer
///
/// The listening socket is a `DispatchSource`, woken by the kernel when the hook connects. Idle
/// cost is one file descriptor.
@MainActor
public final class AgentHookServer {

    /// Every event the hook sends. `request` is non-nil for a permission request, held open until
    /// the caller answers or closes it.
    public var onEvent: ((AgentHookEvent, AgentHookRequest?) -> Void)?

    public private(set) var isRunning = false

    /// Bigger than anything the script sends — it trims to a few hundred bytes — and small enough
    /// that a connection streaming garbage costs nothing before it is dropped.
    static let maximumLineLength = 16 * 1024

    private let socketURL: URL
    private var listener: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var pending: [Int32: (source: any DispatchSourceRead, buffer: Data)] = [:]

    public init(socketURL: URL = AgentHookScript.socketURL) {
        self.socketURL = socketURL
    }

    public enum Failure: Error, Equatable {
        case pathTooLong
        case socket(Int32)
    }

    public func start() throws {
        guard !isRunning else { return }
        let path = socketURL.path
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.pathTooLong }

        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A socket file outlives the process that bound it; a stale one makes `bind` fail with
        // EADDRINUSE and the hook would connect to nothing forever.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8)
            bytes[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw Failure.socket(error)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        listener = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptAll() }
        }
        source.resume()
        acceptSource = source
        isRunning = true
        IslandLog.sources.info("agent hooks: listening")
    }

    public func stop() {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        for (descriptor, entry) in pending {
            entry.source.cancel()
            Darwin.close(descriptor)
        }
        pending = [:]
        Darwin.close(listener)
        listener = -1
        unlink(socketURL.path)
        isRunning = false
        IslandLog.sources.info("agent hooks: stopped")
    }

    // MARK: -

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                IslandLog.sources.warning("agent hooks: refused a connection from another user")
                Darwin.close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            // An answer written to a hook the agent has just killed would otherwise raise SIGPIPE,
            // and SIGPIPE's default action ends the process — Isleta, not the hook.
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.readLine(from: client) }
            }
            pending[client] = (source, Data())
            source.resume()
        }
    }

    private func readLine(from client: Int32) {
        guard var entry = pending[client] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &chunk, chunk.count)
        if count > 0 {
            entry.buffer.append(contentsOf: chunk[0..<count])
        }
        let newline = entry.buffer.firstIndex(of: 0x0A)
        let closed = count == 0 || (count < 0 && errno != EAGAIN)
        guard newline != nil || closed || entry.buffer.count > Self.maximumLineLength else {
            pending[client] = entry
            return
        }

        // Done reading either way: the hook sends one line.
        entry.source.cancel()
        pending[client] = nil
        guard let newline,
              let event = AgentHookEvent.decode(entry.buffer[..<newline])
        else {
            Darwin.close(client)
            return
        }
        if event.isPermissionRequest && !closed {
            onEvent?(event, AgentHookRequest(event: event, descriptor: client))
        } else {
            Darwin.close(client)
            onEvent?(event, nil)
        }
    }
}
