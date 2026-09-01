import AppKit

/// The one sound the lock screen makes: when the Mac comes back.
///
/// It was two. The lock had **Tink** (0.56s, dry and clipped, "something shutting") and the owner
/// removed it on 2026-08-26: the lock already has a 0.7s animation of its own to say what happened,
/// and a sound on top of it — heard by whoever is in the room *after* the user has walked off — was
/// noise about nothing. The unlock keeps its pop, because it is the one the user is present for.
///
/// ## A bundled file, with a system sound behind it
///
/// **This is the one bundled audio asset in Isleta, and it overrides a rule.** Isleta's sound policy
/// plays `NSSound(named:)` against `/System/Library/Sounds`, and the first cut of this did too, for
/// the reasons that rule gives: a bundled asset is a file with a format, a color of license and a
/// size, and §6.5's argument about never shipping a font is the same argument. The owner chose a
/// specific padlock sound for the unlock on 2026-08-26 (`Unlocked.wav`, 0.5s, 131KB, from
/// tunetank.com — **its license is the owner's to confirm before a release ships it**), and it is
/// bundled in the app shell's `Resources`, not in this package: `Bundle.main`, so the package keeps
/// no asset and a test can run with none.
///
/// The system sound is still here as the fallback, and it is a real one: a build without the file
/// plays **Bottle** (0.77s, a light pop) rather than nothing, which is CLAUDE.md's rule for every
/// private path applied to a resource. A file that is missing *and* a sound name that has been
/// retired is the only way to reach silence, and that is counted.
///
/// The reference implementation ships `lock.mp3` and `unlock.mp3`. Nothing here is derived from it:
/// that project is GPL-3 and its audio is its own.
///
/// ## Why this one
///
/// Under a second, which is the whole brief — a sound that outlasts the animation it belongs to is a
/// sound the user hears *after* the thing it was describing. A named constant rather than a literal
/// at the call site so the `Moment` stays the unit a caller asks for, and a second moment can be
/// added back without the call sites changing shape.
///
/// ## Nothing is retained
///
/// `NSSound.play()` on a fresh instance is fire-and-forget. Holding the object would keep an audio
/// buffer alive on the idle path for a sound that lasts half a second —
/// the same note that governs every other sound this app makes, and it applies here for longer, because a locked Mac is idle by
/// definition.
@MainActor
public final class LockScreenSound {

    public enum Moment: Equatable, Sendable {
        case unlocked

        /// The bundled file this moment plays, looked up in `Bundle.main` — the app shell's
        /// `Resources`, where the file has to be for the app to carry it.
        public var resource: (name: String, extension: String) {
            switch self {
            case .unlocked: ("Unlocked", "wav")
            }
        }

        /// The system sound this moment falls back to when the file is not in the bundle.
        public var soundName: String {
            switch self {
            case .unlocked: "Bottle"
            }
        }
    }

    /// How many were asked for and not made because the name resolved to nothing. A count — safe to
    /// log, and the only tell that a sound has been removed from macOS.
    public private(set) var unresolvedCount = 0

    /// How many were played. A count.
    public private(set) var playedCount = 0

    /// Injectable so a test can prove the behavior without a speaker. The default is the real one:
    /// the bundled file if the app carries it, else the system sound. Handed the moment rather than
    /// a name so the two-step lookup lives in one place.
    private let play: @MainActor (Moment) -> Bool

    public init(play: (@MainActor (Moment) -> Bool)? = nil) {
        self.play = play ?? { moment in
            let file = moment.resource
            if let url = Bundle.main.url(forResource: file.name, withExtension: file.extension),
               // `byReference: false` — the half-second buffer is loaded now and dropped with the
               // instance, not memory-mapped and held for the life of a process that is idle by
               // the time it plays.
               let sound = NSSound(contentsOf: url, byReference: false)
            {
                return sound.play()
            }
            guard let sound = NSSound(named: moment.soundName) else { return false }
            return sound.play()
        }
    }

    /// Make the sound for a moment, if the user asked for sounds at all.
    ///
    /// The `isEnabled` gate is a parameter rather than stored state so there is exactly one copy of
    /// the answer — the settings record — and this cannot go stale against it.
    public func play(_ moment: Moment, isEnabled: Bool) {
        guard isEnabled else { return }
        guard play(moment) else {
            unresolvedCount += 1
            // Two constants from this file — never anything about the user.
            IslandLog.system.warning(
                "lock screen sound: neither \(moment.resource.name).\(moment.resource.extension) "
                    + "in the bundle nor \"\(moment.soundName)\" on this Mac"
            )
            return
        }
        playedCount += 1
    }
}
