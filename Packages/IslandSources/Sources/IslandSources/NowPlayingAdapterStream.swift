import Foundation
import IslandActivities

/// Turns the `mediaremote-adapter` line protocol into `NowPlayingUpdate`s.
///
/// Split out from the process that produces those lines so the fiddly half is testable without
/// spawning anything. The adapter's `stream` command emits one JSON object per line of the form
/// `{"type":"data","diff":true,"payload":{…}}`, and the `diff` flag is the part worth isolating:
/// when it is true the payload holds **only the fields that changed**, so a decoder that treats
/// every line as a complete state loses the artist the moment the player reports a pause. That bug
/// is invisible in a five-second manual test — the first line is always a full state — and shows up
/// as titles that keep their subtitle until you touch the play button.
///
/// Stateful and deliberately not `Sendable`. It lives on the reader's queue and the merged state
/// crosses to the main actor only as a finished `NowPlayingUpdate`, which is a value type. Making it
/// `Sendable` and sharing it would require a lock around every field of a forty-key dictionary to
/// protect an ordering the pipe already guarantees.
public struct NowPlayingAdapterDecoder {

    /// The accumulated state that `diff` payloads are merged into.
    ///
    /// `[String: Any]` rather than a `Codable` struct, and that is the right way round here. A
    /// `Decodable` model cannot express "this key was absent, keep what you had" versus "this key
    /// arrived as null, forget what you had" — both land as `nil` in a decoded optional, and they
    /// mean opposite things in a diff stream. Decoding to a dictionary keeps `NSNull` distinguishable
    /// from absence, which is the entire semantics of the protocol, and the four fields we actually
    /// read are pulled out at the end where a wrong type is one `as?` away from being ignored rather
    /// than one thrown error away from dropping the whole line.
    private var merged: [String: Any] = [:]

    /// The next track, and what the queue that named it said was playing at the time.
    ///
    /// Held beside `merged` rather than inside it, because the two arrive on different lines with
    /// different semantics: a `diff: false` payload *replaces* `merged` wholesale, and the up-next
    /// has not stopped being true just because the player re-reported the same track in full.
    ///
    /// The second field is the staleness check. The queue notification and the info change fire in
    /// the same millisecond and nothing orders the two lines, so for a few milliseconds after a skip
    /// one of them describes the old track — and the field that is wrong is the one nobody would
    /// look at, which is how a wrong "Up Next" survives a demo. When both sides name an id and the
    /// ids disagree, the peek is withheld rather than guessed; when either side names none, there
    /// is nothing to check against and the queue is believed, because most players report no
    /// `contentItemIdentifier` at all and withholding by default would mean never showing it.
    private var upNext: NowPlayingUpNext?
    private var upNextCurrentIdentifier: String?

    /// The whole window, for the list the open island scrolls.
    ///
    /// Read by the reader after every decoded line and forwarded only when it changes — it is a
    /// second output of this type rather than a field of `NowPlayingUpdate`, because it arrives on
    /// its own line and on its own cadence. Folding it into the update would mean every pause and
    /// every scrub republished forty rows, and `NowPlayingSnapshot` would have to compare them to
    /// decide whether the island changed.
    ///
    /// **Not** withheld the way `upNext` is when the ids disagree. The peek is one row that claims
    /// to be *the next song* and is wrong for a few milliseconds after a skip; the list is the
    /// player's own window with its own current track at index 0, so a stale one is a list that is
    /// briefly one track behind rather than a sentence that is briefly untrue.
    public private(set) var queueItems: [NowPlayingQueueItem] = []

    /// Read once per decoded line, and only as a *fallback* anchor.
    ///
    /// The payload's own `timestampEpochMicros` is the anchor whenever the player supplies one, and
    /// it is strictly better: it is the instant the *player* observed the position, so it survives
    /// the pipe, the reader queue and the main-actor hop without accumulating any of their latency.
    /// This stands in for players that report an elapsed time with no timestamp, where the least
    /// wrong assumption is that the number was true when the line was written — which is a few
    /// hundred microseconds ago, not a few hundred milliseconds. Injectable so the tests are pure.
    private let now: @Sendable () -> Date

    /// The timeline this decoder last published.
    ///
    /// Held for one job — re-anchoring across a rate change that arrives without a fresh position.
    /// See `timeline(from:isPlaying:carriedFreshTiming:)`, which is where the rule is argued.
    private var lastTimeline: ActivityTimeline?

    /// The track `lastTimeline` belongs to. Re-anchoring across a track change would carry one
    /// record's playhead onto the next, which is a worse bug than the one it fixes.
    private var lastTimelineIdentity: String?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Decodes one line.
    ///
    /// Returns `nil` — not `.cleared` — for anything that carries no verdict: blank lines, lines
    /// that are not JSON, and envelopes of a `type` this version does not understand. The
    /// distinction is load-bearing. `.cleared` takes the island away from the user, so a future
    /// adapter release that adds a `{"type":"heartbeat"}` line must not be able to blank a playing
    /// track just by saying something we have not heard of. Unknown input is silence, and silence
    /// changes nothing.
    public mutating func decode(line: String) -> NowPlayingUpdate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        // `.fragmentsAllowed` because the documented output for "nothing is playing" is a bare
        // `null`, which is a valid JSON fragment but not a valid JSON *document*; without the option
        // it throws and the "stopped" signal is silently swallowed as unparseable.
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        if object is NSNull {
            merged.removeAll()
            forgetUpNext()
            return .cleared
        }
        guard let envelope = object as? [String: Any] else { return nil }

        let payload: Any?
        let isDiff: Bool
        if let type = envelope["type"] as? String {
            // The queue window, on its own line beside the state ones. A separate type rather than
            // a key in the payload because the payload is a *diff*, where an absent array means
            // "unchanged", and a full state, where an absent array means "there is no queue" — one
            // dictionary cannot carry both instructions.
            if type == "queue" {
                guard let items = NowPlayingQueueWindow.items(fromQueueEnvelope: envelope)
                else { return nil }
                upNext = NowPlayingQueueWindow.next(fromQueueItems: items)
                upNextCurrentIdentifier = NowPlayingQueueWindow.currentIdentifier(
                    fromQueueItems: items
                )
                queueItems = NowPlayingQueueWindow.rows(fromQueueItems: items)
                // Silence, not a verdict, when no track has been reported yet. `update(from:)` on
                // an empty state resolves to `.cleared`, which takes the island away from the user —
                // and a queue line can perfectly well arrive first, because the initial read is
                // issued alongside the first state request rather than after it.
                guard merged["title"] != nil else { return nil }
                // A queue line carries no position, so it may not re-anchor one.
                return update(from: merged, carriedFreshTiming: false)
            }
            // A `stream` envelope. Only "data" carries state; anything else is for a human reading
            // stderr, not for us.
            guard type == "data" else { return nil }
            payload = envelope["payload"]
            isDiff = envelope["diff"] as? Bool ?? false
        } else {
            // A bare `get` payload. Accepted so the same decoder serves the one-shot command, which
            // is what a diagnostics dump and the adapter's own smoke test use.
            payload = envelope
            isDiff = false
        }

        guard let fields = payload as? [String: Any] else {
            // Present but null: playback stopped. Reset rather than merely reporting, or the next
            // diff would be applied on top of a track that is no longer playing and resurrect its
            // title.
            merged.removeAll()
            forgetUpNext()
            return .cleared
        }

        if isDiff {
            for (key, value) in fields {
                // An explicit null in a diff means "this field is gone" — a track that lost its
                // album. Assigning `NSNull` instead of removing would leave `as? String` returning
                // nil anyway here, but it would also make `merged` grow monotonically over a long
                // listening session, and it would defeat any future field that has to distinguish
                // the two.
                if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
            }
        } else {
            // A `diff: false` line replaces the accumulated state, which is right for a new track
            // and wrong for the same one.
            //
            // Pressing play produces a full payload that reports what changed and omits the timing
            // keys. Replacing wholesale drops `durationMicros`, the duration resolves to zero, the
            // fraction becomes zero, and the progress bar snaps to the start of the track before the
            // next payload puts it back — which is exactly the "jumps to 0% and then returns"
            // reported from a running build, and why it happened only on the first press.
            //
            // Carried forward **only** when the payload names the same track. A different
            // `contentItemIdentifier`, or none at all, replaces as before: inheriting one track's
            // duration into another is a worse bug than the one being fixed.
            var replacement = fields
            if let previous = merged["contentItemIdentifier"] as? String,
               let incoming = fields["contentItemIdentifier"] as? String,
               previous == incoming {
                for key in Self.carriedTimingKeys where replacement[key] == nil {
                    if let carried = merged[key] { replacement[key] = carried }
                }
            }
            merged = replacement
        }

        return update(from: merged, carriedFreshTiming: Self.carriesFreshTiming(fields))
    }

    /// Forgets accumulated state. Called when the helper dies, so a relaunch cannot merge new
    /// diffs onto the state of a process that is no longer running.
    public mutating func reset() {
        merged.removeAll()
        lastTimeline = nil
        lastTimelineIdentity = nil
        forgetUpNext()
    }

    /// Drops the peek. Separate from `reset()` because it also runs on a stop, where the merged
    /// state is being cleared for a reason the queue knows nothing about.
    private mutating func forgetUpNext() {
        upNext = nil
        upNextCurrentIdentifier = nil
        queueItems = []
    }

    /// The keys a full payload may omit for a track it has already described, and which must
    /// survive rather than being read as "this track has no duration".
    ///
    /// Both spellings of each, because the adapter reports seconds without `--micros` and
    /// microseconds with it, and this decoder serves both.
    static let carriedTimingKeys = [
        "durationMicros", "duration",
        "elapsedTimeMicros", "elapsedTime",
        "timestampEpochMicros", "timestamp",
    ]

    /// Whether a payload carries a position measured *now* rather than one inherited from the
    /// merged state.
    ///
    /// Asked of the **line's own fields**, never of `merged`, which is the whole point: a diff that
    /// says only `{"playing": false}` leaves a position in `merged` that was measured seconds ago,
    /// and the question this answers is exactly "may that number be republished as current".
    ///
    /// **The elapsed time alone is enough, and the timestamp alone is not**, which is not symmetric
    /// and should not be. A player that reports a position with no timestamp gets `now()` as its
    /// anchor — see the `now` property — so the pair is current and honest. A line carrying a
    /// timestamp but no position would pin a *stale* elapsed to a *fresh* anchor, which is precisely
    /// the mismatch this whole mechanism exists to prevent.
    private static func carriesFreshTiming(_ fields: [String: Any]) -> Bool {
        fields["elapsedTimeMicros"] != nil || fields["elapsedTime"] != nil
    }

    private mutating func update(
        from fields: [String: Any],
        carriedFreshTiming: Bool
    ) -> NowPlayingUpdate {
        // `playing` is documented as mandatory whenever the payload is valid, but it is read
        // defensively anyway: the failure mode of a missing flag is an island that says a track is
        // playing when it is paused, which is worse than the failure mode of assuming paused.
        //
        // Read through `NSNumber` rather than `as? Bool` alone because `JSONSerialization` bridges
        // JSON booleans to `__NSCFBoolean`, which *does* cast to `Bool` — but an adapter that ever
        // emits `1` instead of `true` would otherwise silently read as paused forever.
        let isPlaying = (fields["playing"] as? NSNumber)?.boolValue ?? false

        return NowPlayingSnapshot.update(
            title: fields["title"] as? String,
            artist: fields["artist"] as? String,
            album: fields["album"] as? String,
            isPlaying: isPlaying,
            bundleIdentifier: fields["bundleIdentifier"] as? String,
            timeline: resolvedTimeline(
                from: fields, isPlaying: isPlaying, carriedFreshTiming: carriedFreshTiming
            ),
            // Absent means "the player did not say", and a player that does not say is not
            // forbidding anything. Defaulting the other way would gray the Next button out on every
            // app that never sets the key, which is most of them.
            canSkip: !((fields["prohibitsSkip"] as? NSNumber)?.boolValue ?? false),
            artworkIdentity: fields["contentItemIdentifier"] as? String,
            // Either spelling counts. Apple Music radio reports `radioStationHash` and no
            // `radioStationIdentifier`, measured on macOS 27.0 — the header names both, so a player
            // that sets the other one must not read as an ordinary queue.
            //
            // Presence alone, because the *value* is a station token and means nothing here. A
            // payload that omits both is an ordinary queue, which is the right default: it is also
            // what every player that has never heard of radio sends.
            isRadioStation: fields["radioStationHash"] != nil || fields["radioStationIdentifier"] != nil,
            upNext: resolvedUpNext(against: fields),
            // `supportsIsLiked`, not `isFavorite`. The second one is the state of a control the first
            // one decides the existence of, and a track nobody has favorite yet reports `0` for it —
            // so reading the state as the capability draws a dead heart on every likeable track.
            // Absent means the player has no like to offer, which is why this defaults false where
            // `canSkip` defaults true.
            canFavorite: (fields["supportsIsLiked"] as? NSNumber)?.boolValue ?? false,
            isFavorite: (fields["isLiked"] as? NSNumber)?.boolValue ?? false,
            canSkipBackFifteen: (fields["supportsRewind15Seconds"] as? NSNumber)?.boolValue ?? false,
            canSkipForwardFifteen: (fields["supportsFastForward15Seconds"] as? NSNumber)?.boolValue ?? false
        )
    }

    /// The peek, withheld when the queue is describing a different track from the payload.
    ///
    /// See `upNextCurrentIdentifier`. Both ids present and different is the only case that
    /// withholds: it means one of the two lines is a few milliseconds out of date, and there is no
    /// way to tell which — so the honest answer for those few milliseconds is nothing rather than
    /// the previous track's successor.
    private func resolvedUpNext(against fields: [String: Any]) -> NowPlayingUpNext? {
        guard let upNext else { return nil }
        guard let claimed = upNextCurrentIdentifier,
              let playing = fields["contentItemIdentifier"] as? String
        else { return upNext }
        return claimed == playing ? upNext : nil
    }

    /// The timeline actually published, which is not always the one the fields spell out.
    ///
    /// **`elapsed`, `anchor` and `rate` are one measurement, and this is what stops them being
    /// mixed.** The adapter reports a play or a pause as *two* lines — measured on macOS 27.0 with
    /// Apple Music: `{"playing": true}` first, then the fresh position 87 ms later; `{"playing":
    /// false}` first, then the fresh position **217 ms** later. In that window the merged state
    /// holds a position measured before the press and a rate from before it too, and combining them
    /// with the new flag is what makes the bar move when the user asked it to stop.
    ///
    /// Two rules, and each fixes a failure that was reproduced rather than imagined:
    ///
    /// - **A paused player does not advance, whatever `playbackRate` still says.** On the pause edge
    ///   the merged rate is the *playing* rate, so the bar kept running for the whole 217 ms after
    ///   the glyph had already flipped to play. `playing: false` with a non-zero rate is a
    ///   contradiction, and the flag is the half the user just caused.
    /// - **A line without a fresh position re-anchors to where the playhead is now.**
    ///   This is the one that matters. Apple Music happens to leave a stale `playbackRate` in the
    ///   merged state, which accidentally holds the bar still on the play edge — a player that omits
    ///   the key entirely gets `rate` 1 from the `playing` flag alone, applied to an anchor that can
    ///   be *minutes* old, and `elapsed + (now - anchor)` then clamps to the end of the track. The
    ///   bar slams to 100% and comes back a frame later. Re-anchoring means the timeline says what
    ///   was already on screen, so the only visible change is that it starts or stops moving.
    ///
    /// The correction that follows is sub-pixel: on the measured pause edge the re-anchored position
    /// and the player's own differ by 0.13 s of a 228 s track, which is 0.11 pt of a 200 pt bar.
    private mutating func resolvedTimeline(
        from fields: [String: Any],
        isPlaying: Bool,
        carriedFreshTiming: Bool
    ) -> ActivityTimeline? {
        let built = Self.timeline(from: fields, isPlaying: isPlaying, fallbackAnchor: now())
        guard var timeline = built else {
            lastTimeline = nil
            lastTimelineIdentity = nil
            return nil
        }

        if !isPlaying, timeline.rate != 0 {
            timeline = ActivityTimeline(
                elapsed: timeline.elapsed,
                duration: timeline.duration,
                anchor: timeline.anchor,
                rate: 0
            )
        }

        // **Every** line without a fresh position re-anchors, not only the ones that change the
        // rate. Gating on a rate change was the first attempt and it is subtly wrong: the *second*
        // stale line of a pause — the flag repeated, or any metadata diff arriving before the real
        // position — finds the rate already zero, skips the re-anchor, and republishes the raw
        // `elapsed` from before the press. On the captured edge that threw the bar 3.82 s backwards.
        //
        // Re-anchoring unconditionally is also free where nothing changed: `previous.position(at:)`
        // under an unchanged rate is exactly what the old pair already described, so a steady line
        // re-states the same playhead rather than moving it. `steadyLinesDoNotReAnchor` pins that.
        //
        // Only for the *same track*. A new record's payload carries its own position, so this does
        // not fire for it — and if one ever arrived without, inheriting the previous track's
        // playhead would be a worse bug than the one this fixes.
        let identity = fields["contentItemIdentifier"] as? String
        if !carriedFreshTiming, let previous = lastTimeline, identity == lastTimelineIdentity {
            let instant = now()
            timeline = ActivityTimeline(
                elapsed: previous.position(at: instant),
                duration: timeline.duration,
                anchor: instant,
                rate: timeline.rate
            )
        }

        lastTimeline = timeline
        lastTimelineIdentity = identity
        return timeline
    }

    /// Builds the playhead anchor from whichever spelling of the time keys this payload uses.
    ///
    /// Two spellings exist because `--micros` *replaces* the three time keys rather than adding to
    /// them, and both are read here rather than in two decoders. The microsecond form is what
    /// `streamArguments` asks for and is strictly better — the plain form serializes `timestamp` as
    /// an ISO-8601 string rounded to the **whole second**, so a playhead anchored to it can be up to
    /// a second out and a scrub bar built on it visibly steps. The plain form is still parsed,
    /// because `get` may be invoked without the flag and because an adapter release could change
    /// which it defaults to.
    ///
    /// Returns `nil` when there is nothing to anchor. That is not a failure: a player reporting no
    /// position at all is normal (a live stream, an app that never sets the keys), and the island
    /// answers by drawing a glyph in the trailing flank and no scrub bar, rather than a bar stuck at
    /// zero that invites a drag it cannot honor.
    static func timeline(
        from fields: [String: Any],
        isPlaying: Bool,
        fallbackAnchor: Date
    ) -> ActivityTimeline? {
        let micros = 1_000_000.0
        let elapsed: TimeInterval?
        if let value = (fields["elapsedTimeMicros"] as? NSNumber)?.doubleValue {
            elapsed = value / micros
        } else if let value = (fields["elapsedTime"] as? NSNumber)?.doubleValue {
            elapsed = value
        } else {
            elapsed = nil
        }

        let duration: TimeInterval
        if let value = (fields["durationMicros"] as? NSNumber)?.doubleValue {
            duration = value / micros
        } else if let value = (fields["duration"] as? NSNumber)?.doubleValue {
            duration = value
        } else {
            duration = 0
        }

        // The rate, not the flag, is what makes the playhead move — and it is not redundant with
        // `playing`. A podcast at 1.5x reports `playbackRate` 1.5, and a bar advancing at 1x under
        // it drifts a minute every two. Where the player reports no rate at all, `playing` is the
        // only thing left to infer it from.
        let reportedRate = (fields["playbackRate"] as? NSNumber)?.doubleValue
        let rate = reportedRate ?? (isPlaying ? 1 : 0)

        let anchor: Date
        if let epochMicros = (fields["timestampEpochMicros"] as? NSNumber)?.doubleValue {
            anchor = Date(timeIntervalSince1970: epochMicros / micros)
        } else if let text = fields["timestamp"] as? String, let parsed = Self.date(from: text) {
            anchor = parsed
        } else {
            anchor = fallbackAnchor
        }

        // No elapsed time and no duration is a player with nothing to say about position — but a
        // *playing* one still wants a timeline, because that is what the equaliser reads to know it
        // should be moving. Zero duration is exactly how `ActivityTimeline.fraction(at:)` reports
        // "there is no end to be a fraction of", so the bars run and no scrub bar is drawn.
        guard elapsed != nil || duration > 0 || rate != 0 else { return nil }

        return ActivityTimeline(
            elapsed: elapsed ?? 0,
            duration: max(0, duration),
            anchor: anchor,
            rate: rate
        )
    }

    /// Parses the adapter's non-`--micros` timestamp: `yyyy-MM-dd'T'HH:mm:ss'Z'`, always UTC.
    ///
    /// Hand-rolled against that exact format rather than handed to `ISO8601DateFormatter`, for a
    /// reason that is measurable rather than aesthetic: this runs on the reader queue for every line
    /// of a diff stream, and a formatter allocated per call is the kind of thing that turns a pipe
    /// read into a visible cost on a long listening session. A single `static let` formatter would
    /// also do, and is what this was before — `DateFormatter` is documented thread-safe for
    /// formatting, but only once fully configured, and a lazily-initialized global reached from two
    /// queues has a window where it is not.
    static func date(from text: String) -> Date? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard digits.count >= 6 else { return nil }
        var components = DateComponents()
        components.year = Int(digits[0])
        components.month = Int(digits[1])
        components.day = Int(digits[2])
        components.hour = Int(digits[3])
        components.minute = Int(digits[4])
        components.second = Int(digits[5])
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        return calendar.date(from: components)
    }
}

/// Where the vendored adapter lives, and whether it is actually there.
///
/// The adapter is three files that must agree with each other: a Perl script, a compiled
/// `MediaRemoteAdapter.framework` the script loads, and `/usr/bin/perl` itself. This resolves them
/// from an app bundle and refuses to half-resolve — a location that exists but points at a missing
/// framework would spawn a process that exits immediately, once per launch, forever.
///
/// **`perlExecutable` is `/usr/bin/perl` and must not be made configurable.** This is the one place
/// in the whole design where the exact binary is the mechanism rather than an implementation detail.
/// Since macOS 15.4 `mediaremoted` refuses `MRMediaRemoteGetNowPlayingInfo` to callers it does not
/// recognize, and what it recognizes is a code signature whose identifier begins `com.apple.` —
/// `/usr/bin/perl` reports `com.apple.perl` and is signed by "macOS Software Signing" with a
/// platform identifier. The capability belongs to Apple's copy of Perl at Apple's path. Copying that
/// binary into the app bundle, re-signing it with Isleta's Developer ID, or pointing this at a
/// Homebrew or `perlbrew` Perl all produce a perfectly good Perl interpreter that gets "Operation
/// not permitted" from `mediaremoted`, and the symptom is an adapter that starts, prints nothing,
/// and never fails loudly enough to look broken.
public struct NowPlayingAdapterLocation: Equatable, Sendable {

    /// Always `/usr/bin/perl`. See the type's documentation for why this is not a setting.
    public static let perlExecutable = URL(fileURLWithPath: "/usr/bin/perl")

    public let scriptURL: URL
    public let frameworkURL: URL

    public init(scriptURL: URL, frameworkURL: URL) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
    }

    /// Where `Tools/` is expected to vendor the adapter inside `Isleta.app`.
    ///
    /// `Contents/Resources` for the script and `Contents/Frameworks` for the framework, because that
    /// is where notarisation and the hardened runtime expect to find each: a `.framework` under
    /// `Resources` is not signed as a nested code bundle and fails notarisation, and a `.pl` under
    /// `Frameworks` is signed as if it were code and invalidates on the first edit.
    public static let scriptSubpath = "MediaRemoteAdapter/mediaremote-adapter.pl"
    public static let frameworkName = "MediaRemoteAdapter.framework"

    /// Resolves the adapter inside a bundle, or `nil` if this build does not carry it.
    ///
    /// `nil` is a completely normal answer, not an error: a developer build made by `check.sh` has
    /// no vendored adapter and must still run. The caller falls through to the scripting route.
    public static func inBundle(
        _ bundle: Bundle,
        fileManager: FileManager = .default
    ) -> NowPlayingAdapterLocation? {
        guard let resources = bundle.resourceURL else { return nil }
        let script = resources.appendingPathComponent(scriptSubpath)
        guard let frameworks = bundle.privateFrameworksURL else { return nil }
        let framework = frameworks.appendingPathComponent(frameworkName)

        let location = NowPlayingAdapterLocation(scriptURL: script, frameworkURL: framework)
        return location.isPresent(fileManager: fileManager) ? location : nil
    }

    /// Both halves present, and Apple's Perl still where it has always been.
    ///
    /// The Perl check is not paranoia about the file being deleted; it is the cheapest way to notice
    /// that a future macOS has removed the scripting language runtimes from the base install, which
    /// Apple has said it intends to do. On that day this returns false, `NowPlayingSource` selects
    /// the scripting fallback, and the user keeps a working island instead of an adapter that fails
    /// at spawn.
    public func isPresent(fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: Self.perlExecutable.path)
            && fileManager.fileExists(atPath: scriptURL.path)
            && fileManager.fileExists(atPath: frameworkURL.path)
    }

    /// The documented argument vector for a live stream.
    ///
    /// `--no-artwork` is not an optimisation, it is the memory budget. The adapter base64-encodes
    /// cover art into every payload it emits; a 600×600 JPEG is a few hundred kilobytes of text per
    /// update, allocated in the reader, merged into the decoder's state and held until the next
    /// track. §9 allows 60 MB resident for the entire app, and `BuiltInActivity.nowPlaying` has
    /// nowhere to put artwork — so this pays a per-track allocation for a field with no consumer.
    /// When the island grows an album-art slot, this flag comes off *and* the decoder learns to drop
    /// the previous image; taking it off alone is the leak.
    ///
    /// `--no-diff` is deliberately **not** passed. Full states on every line would make
    /// `NowPlayingAdapterDecoder` trivial, at the cost of pushing a complete forty-key payload
    /// through the pipe on every scrub of a track the user is not even looking at.
    ///
    /// `--micros` is what makes the scrub bar exact. Without it the adapter serializes `timestamp`
    /// as an ISO-8601 string **rounded to the whole second**, so the anchor the playhead is computed
    /// from can be up to a second out — on a three-minute track that is 1pt of a 200pt bar, which is
    /// invisible, but it also means the anchor *jumps* by up to a second every time the player
    /// re-reports, and a bar that steps backwards is not invisible at all.
    /// `--queue` is what makes the sneak peek free.
    ///
    /// A one-shot `perl … queue` costs 60-360 ms, of which the read itself is 15-30 — process spawn
    /// dominates — so asking on every track change would be a process per skip. The streaming
    /// helper is already alive and is already registered for the notification that carries this, so
    /// folding the read into it costs one extra MediaRemote request per track change and no timer
    /// anywhere. `--length` asks for five entries because a 5-item window measures 4-5 ms against
    /// 15-30 for 25, and the peek reads exactly one of them.
    public var streamArguments: [String] {
        [
            scriptURL.path, frameworkURL.path, "stream",
            "--no-artwork", "--micros", "--queue",
            "--length=\(NowPlayingQueuePaging.restingWindow)",
        ]
    }

    /// The one-shot queue read: `queue --length=N`.
    ///
    /// **Not on any path Isleta runs at runtime**, and that is the point of the doc comment. It
    /// exists for `--export-logs` and for a person checking by hand whether the queue is readable on
    /// a given machine; wiring it into the app would be the 60-360 ms spawn the stream exists to
    /// avoid.
    public func queueArguments(length: Int = 5) -> [String] {
        [scriptURL.path, frameworkURL.path, "queue", "--length=\(max(1, length))"]
    }

    /// The one-shot read that carries artwork. **The only invocation without `--no-artwork`.**
    ///
    /// Run on a track change and at no other time. The reason is measured rather than assumed:
    /// `artworkData` is base64 JPEG and came to 211,300 characters (~155 KB) for a single track, and
    /// `stream` re-emits the *whole* payload on every update it reports — so streaming with artwork
    /// on would push hundreds of kilobytes a second through the pipe during a scrub, against §9's
    /// 60 MB resident budget, to redeliver an image that has not changed.
    public var artworkArguments: [String] {
        [scriptURL.path, frameworkURL.path, "get"]
    }

    /// A transport command: `send <MRCommand id>`.
    public func sendArguments(_ command: NowPlayingCommand) -> [String] {
        [scriptURL.path, frameworkURL.path, "send", String(command.rawValue)]
    }

    /// Jumping to an entry of the playback queue: `send 131 --offset=N --content-item-id=…`.
    ///
    /// **Both options, and the command id is 131.** Measured on macOS 27.0 against a live Music
    /// queue: `kMRPlay (0)` and `SetPlaybackQueue (122)` with the offset both return `1` and change
    /// nothing, and only `PlayItemInPlaybackQueue (131)` moves the player — verified by reading the
    /// queue back, because every one of the three reports success. The plural spelling of the
    /// content-item key is inert in the same silent way.
    ///
    /// The identifier is optional because a player may not supply one. Re-measured 2026-08-23, the
    /// offset alone also moved a local Music queue — so the id may be belt and braces rather than
    /// required. It is sent whenever there is one anyway: the session that established this command
    /// measured it needing both, and a command that silently does nothing is not a thing to narrow
    /// on one contrary reading.
    public func playQueueItemArguments(
        atOffset offset: Int,
        contentItemIdentifier: String?
    ) -> [String] {
        var arguments = [
            scriptURL.path, frameworkURL.path, "send",
            String(NowPlayingCommand.playItemInPlaybackQueue.rawValue),
            "--offset=\(max(0, offset))",
        ]
        if let contentItemIdentifier, !contentItemIdentifier.isEmpty {
            arguments.append("--content-item-id=\(contentItemIdentifier)")
        }
        return arguments
    }

    /// Liking or un-liking the current track: `send 106` / `send 107`.
    ///
    /// No options. MediaRemote documents these as taking a track, station and station-hash triple,
    /// and the adapter can express all three now — but Isleta has none of them to pass: the
    /// now-playing payload carries `isFavorite` and `supportsIsLiked` and none of the three ids. So
    /// the command goes out bare and applies to whatever is playing, which is what the user pressed
    /// it about. If a player is ever found that needs the triple, the fork already carries the
    /// options and this is where they would be added.
    ///
    /// **Ban, not "unlike".** `kMRBanTrack` is the only inverse the vocabulary has, and whether a
    /// service treats it as "remove the like" or as "never play this again" is the service's
    /// business — upstream's own comment asks the same question and does not answer it. Isleta
    /// therefore sends it only to undo a like it can see, never as a first action.
    public func likeArguments(_ favorite: Bool) -> [String] {
        [
            scriptURL.path, frameworkURL.path, "send",
            String((favorite ? NowPlayingCommand.likeTrack : .banTrack).rawValue),
        ]
    }

    /// A seek: `seek <microseconds>`.
    ///
    /// Microseconds because that is the unit the adapter documents for this command specifically —
    /// unlike the payload's time keys, which are seconds unless `--micros` is passed. Rounded rather
    /// than truncated, and clamped at zero: Perl would take a negative happily and `MRMediaRemote`
    /// would seek to somewhere undefined.
    public func seekArguments(toSeconds seconds: TimeInterval) -> [String] {
        let micros = Int64((max(0, seconds) * 1_000_000).rounded())
        return [scriptURL.path, frameworkURL.path, "seek", String(micros)]
    }
}

/// The transport commands Isleta sends, and their `MRCommand` ids.
///
/// The raw values are Apple's, read out of the vendored `MediaRemote.h` — they are a wire format
/// rather than a choice, so they are written here as literals with the header's own names beside
/// them rather than being derived from anything. Only the three the island offers are listed;
/// `MRCommand` has fourteen, and an enum listing commands with no button is an invitation to send
/// one that has never been tried.
public enum NowPlayingCommand: Int, Sendable, CaseIterable {

    /// `kMRPreviousTrack`.
    case previousTrack = 5

    /// `kMRTogglePlayPause`. The toggle rather than separate play and pause commands: the island's
    /// idea of whether something is playing lags the player by the length of one pipe hop, so
    /// sending the *absolute* command computed from a stale flag is how a user who taps twice
    /// quickly ends up pausing something that was already paused.
    case togglePlayPause = 2

    /// Shuffle and repeat. Accepted by `adapter_send` and checked against the vendored
    /// `MediaRemoteAdapter.h` rather than guessed — a wrong id is *refused*, which fails the command
    /// without failing anything the user can see.
    ///
    /// Toggles with no readback: Music puts neither `shuffleMode` nor `repeatMode` in its payload,
    /// so the island can change them and cannot show them. That is why their buttons carry no on/off
    /// state — see `NowPlayingTransportView`.
    case toggleShuffle = 6
    case toggleRepeat = 7

    /// `kMRNextTrack`.
    case nextTrack = 4

    /// `kMRGoBackFifteenSeconds` and `kMRSkipFifteenSeconds`.
    ///
    /// Offered only where the player says it offers them — `supportsRewind15Seconds` and
    /// `supportsFastForward15Seconds` — which in practice means spoken word. They are not a
    /// substitute for a seek: a podcast player implements them as its own jump, and asking it for
    /// one is the difference between the button the app draws and a scrub we computed.
    case goBackFifteenSeconds = 12
    case skipFifteenSeconds = 13

    /// `kMRLikeTrack` (0x6A) and `kMRBanTrack` (0x6B).
    ///
    /// Newly whitelisted in the fork's `send.m` — upstream accepts neither, and its own note there
    /// asks whether "ban" means "remove like". Isleta only ever sends the ban to undo a like it can
    /// see reported, which is the narrowest reading and the only one that cannot surprise anybody.
    case likeTrack = 106
    case banTrack = 107

    /// `kMRPlayItemInPlaybackQueue`. **Never sent through `send(_:)`** — it needs a userInfo
    /// dictionary, so it goes through `playQueueItem(atOffset:contentItemIdentifier:)`, which is
    /// the only call that can build one. Listed here because the raw value belongs with the others.
    case playItemInPlaybackQueue = 131
}
