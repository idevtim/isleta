import Foundation
import IslandActivities
import IslandKit

/// Reads the playing track's audio format with a one-shot `queue` call, for the case the stream
/// cannot answer.
///
/// ## Why a second route to something the stream already carries
///
/// The format — "Lossless", "Dolby Atmos" — rides on the stream's `{"type":"queue"}` line, on the
/// entry at index 0, and for a player that has been running since the stream opened it is there.
/// **After the player quits and comes back it is not**, and no amount of asking the stream fixes it:
/// measured 2026-09-08 on macOS 27.0, driving Music through quit → reopen → play while logging every
/// queue push, the stream re-emitted a full five-entry window on demand with `audioFormat` **absent**
/// from the current entry, twice, while a one-shot `queue --length=1` against the same player at the
/// same moment returned it in full. The reported symptom was a badge that never came back "until I
/// hit next and then previous" — the two gestures that change a queue enough for the stream to
/// carry the field again.
///
/// So this is not a fallback for a broken route. It is the only route that answers in that state,
/// and the stream stays the one that answers in every other.
///
/// ## What it costs, and what bounds it
///
/// One `perl` process per ask, which is the same trade `NowPlayingArtworkLoader` already makes for
/// covers — and for the same reason: the payload is a few hundred bytes and the alternative is
/// nothing at all. §9 forbids polling on the idle path and this is not polling: it is asked for by
/// `NowPlayingFormatRefresh`, **at most once per track**, and only when the playing track has no
/// format in hand. A library where nothing reports a format costs one spawn per track change and
/// then silence.
///
/// `--length=1` is deliberate: the window is the *current* entry, which is the only one that ever
/// carries `audioFormat`, and it was measured returning the field at that length rather than only at
/// the resting five.
@MainActor
public final class NowPlayingFormatReader {

    /// How long the helper gets before it is terminated. Generous next to the ~70 ms this measures
    /// at, because the cost of being wrong is a badge that does not appear, and the cost of waiting
    /// is nothing at all: this runs off the main actor and answers into a callback.
    private nonisolated static let timeout: TimeInterval = 4

    /// The output is a single JSON object of one queue entry — a few hundred bytes measured. The cap
    /// is three orders of magnitude above that and exists for `NowPlayingArtwork`'s reason: a read
    /// with no ceiling is a pipe that can fill memory if the thing on the other end misbehaves.
    private nonisolated static let byteLimit = 256 * 1024

    private let executable: URL
    private let arguments: [String]

    /// Nil where this build carries no adapter — a developer build, or the scripting fallback —
    /// in which case every ask answers nil and nothing is spawned.
    public convenience init(bundle: Bundle = .main) {
        let location = NowPlayingAdapterLocation.inBundle(bundle)
        self.init(
            executable: NowPlayingAdapterLocation.perlExecutable,
            arguments: location?.audioFormatArguments ?? []
        )
    }

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Asks for the playing track's format, answering on the main actor.
    ///
    /// **Answers only what it found.** A nil result is not delivered: the caller is asking because it
    /// has nothing, and a nil here would be indistinguishable from "this track has no format" — a
    /// distinction the stream's own push is the right one to make, because it knows which track it is
    /// talking about. Silence keeps this route from ever *removing* a badge.
    public func read(_ completion: @escaping @MainActor (AudioFormat) -> Void) {
        guard !arguments.isEmpty else { return }
        let executable = executable
        let arguments = arguments
        Task.detached(priority: .utility) {
            guard let format = Self.fetch(
                executable: executable,
                arguments: arguments,
                timeout: Self.timeout,
                byteLimit: Self.byteLimit
            ) else { return }
            await MainActor.run { completion(format) }
        }
    }

    /// `nonisolated` and static so it cannot touch anything the main actor owns —
    /// `NowPlayingArtwork.fetch`'s shape, and every trap it documents applies here identically.
    private nonisolated static func fetch(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        byteLimit: Int
    ) -> AudioFormat? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        // stderr to /dev/null rather than to a pipe nobody drains — an undrained stderr pipe fills
        // and blocks the writer, which hangs the helper rather than letting it exit.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // The deadline is armed before the read, because `availableData` blocks on a writer that
        // may never close.
        let boxed = UncheckedBox(process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard boxed.value.isRunning else { return }
            boxed.value.terminate()
        }

        var data = Data()
        let handle = pipe.fileHandleForReading
        while data.count < byteLimit {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if data.count >= byteLimit {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return decodeFormat(fromQueuePayload: data)
    }

    /// Pulls the current entry's `audioFormat` out of a one-shot `queue` payload.
    ///
    /// Internal rather than private so the half with decisions in it is tested without spawning
    /// anything — `NowPlayingArtwork.decodeArtwork`'s arrangement, for its reason.
    ///
    /// The payload is `{"queueItems":[{…,"audioFormat":{…}}]}`, and **entry 0 is the playing track**
    /// (`NowPlayingQueueWindow`). `null` is what the adapter prints when no player is running, and it
    /// decodes to nothing here rather than to an error.
    nonisolated static func decodeFormat(fromQueuePayload data: Data) -> AudioFormat? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["queueItems"] as? [Any],
              let first = items.first as? [String: Any],
              let fields = first["audioFormat"] as? [String: Any]
        else { return nil }
        return AudioFormat(mediaRemoteFields: fields)
    }
}
