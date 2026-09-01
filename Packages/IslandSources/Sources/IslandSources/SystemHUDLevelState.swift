import Foundation
import IslandActivities

/// One observation of the system's audio levels, as read in a single pass.
///
/// Both fields are optional because "this device has no volume control" and "the volume is zero"
/// are different facts and a `Double` cannot hold both. Aggregate devices, most HDMI outputs and
/// some USB interfaces genuinely expose neither a volume nor a mute property, and a source that
/// defaulted them to `0`/`false` would announce a mute the user never performed the first time
/// somebody plugged in a monitor.
public struct SystemHUDAudioSnapshot: Equatable, Sendable {

    /// 0...1 as CoreAudio reports it, unrounded. Stored raw for the same reason
    /// `BuiltInActivity.systemHUD` stores its level raw: the clamping belongs to
    /// `ActivityValue.normalized`, at the point of use, not scattered across producers.
    public var volume: Double?

    public var isMuted: Bool?

    public init(volume: Double?, isMuted: Bool?) {
        self.volume = volume
        self.isMuted = isMuted
    }

    /// A device that reports neither level. Not the same as silence.
    public static let unavailable = SystemHUDAudioSnapshot(volume: nil, isMuted: nil)
}

/// What the island should say about a system level, if anything.
public struct SystemHUDReading: Equatable, Sendable {

    public var hud: SystemHUD

    /// 0...1.
    public var level: Double

    /// The end of the range this reading **landed on**, or nil — see `ActivityLimit`. The island
    /// bounces in that direction when it is set.
    ///
    /// Decided here rather than by the island reading the number back, because "level zero" and
    /// "the bottom of the range" are different facts and only this file can tell them apart: a mute
    /// publishes level zero, and it is not somebody running the volume down.
    public var limit: ActivityLimit?

    public init(hud: SystemHUD, level: Double, limit: ActivityLimit? = nil) {
        self.hud = hud
        self.level = level
        self.limit = limit
    }

    /// The end of the range a level sits on, or nil.
    ///
    /// `>=` and `<=` rather than `==`, because neither producer hands back a clean bound: CoreAudio
    /// reports 1.0000000149 at full volume (the number `ActivityValue.normalized` already clamps),
    /// and a display's ramp can overshoot in the last bits.
    static func limit(atLevel level: Double) -> ActivityLimit? {
        if level >= 1 { return .maximum }
        if level <= 0 { return .minimum }
        return nil
    }

    /// The activity this reading becomes. Everything about priority, expiry and identity comes from
    /// `ActivityKind.systemHUD` — §8.3 put those defaults in one place precisely so a source could
    /// not quietly ship a HUD that outlives Apple's or sits below Now Playing.
    public var activity: BuiltInActivity {
        BuiltInActivity.systemHUD(hud, level: level, limit: limit)
    }
}

/// Turns a stream of audio snapshots into the HUDs worth showing.
///
/// A pure value type with no CoreAudio in it, for the same reason `IslandLayout` has no AppKit in
/// it: this is where the bugs are, and they are all about *when not to speak*. Two of them are
/// verified misbehaviors of the real API rather than hypotheticals — see `apply(_:)`.
public struct SystemHUDLevelState: Equatable, Sendable {

    public private(set) var volume: Double?
    public private(set) var isMuted: Bool?

    /// Whether a snapshot has been taken as the reference point. Until one has, nothing is a
    /// *change* and nothing is published.
    public private(set) var hasBaseline: Bool

    public init() {
        volume = nil
        isMuted = nil
        hasBaseline = false
    }

    /// Adopt a snapshot as the new reference without saying anything about it.
    ///
    /// Two callers, and both would be user-visible bugs if they went through `apply(_:)` instead.
    /// At launch we read the current volume to know what a later change is relative to; publishing
    /// that would throw a volume HUD at the user every time Isleta starts, for something they did
    /// not do. The same on a default-output-device change: plugging in headphones swaps to a device
    /// at a completely different level, and macOS shows no HUD for it either, because the number
    /// changed without the user touching it.
    public mutating func rebase(to snapshot: SystemHUDAudioSnapshot) {
        volume = snapshot.volume
        isMuted = snapshot.isMuted
        hasBaseline = true
    }

    /// Fold in a snapshot, returning the HUD to present or nil if nothing user-visible happened.
    ///
    /// The two nil cases are not defensive programming; both were observed against CoreAudio on
    /// macOS 26 while writing this:
    ///
    /// - **A single volume keypress delivers eight listener callbacks**, all carrying the same new
    ///   value. Published unfiltered they would restart the HUD's 1.5s dwell eight times and, worse,
    ///   re-enter `.interrupting` eight times against a coordinator that is entitled to treat each
    ///   as a fresh interruption.
    /// - **The mute listener fires when only the volume changed**, with mute unchanged. A source
    ///   that trusted "my mute listener fired" as "mute changed" would show a mute HUD on every
    ///   volume keypress.
    ///
    /// Equality is exact rather than epsilon-based on purpose. A duplicate callback hands back the
    /// identical `Float32`, so exact comparison drops exactly the duplicates; the finest real step
    /// the system offers is a quarter-notch of 1/64, which no tolerance small enough to be safe
    /// would ever swallow, and one large enough to be interesting would swallow it.
    public mutating func apply(_ snapshot: SystemHUDAudioSnapshot) -> SystemHUDReading? {
        guard hasBaseline else {
            rebase(to: snapshot)
            return nil
        }

        let changed = snapshot.volume != volume || snapshot.isMuted != isMuted
        rebase(to: snapshot)
        guard changed else { return nil }

        // Mute wins over level whenever it is on, which also covers unmuting: the mute flag goes
        // false, the branch falls through, and the user gets the volume bar showing what they have
        // come back to. That is what macOS does, and it is the only reading that answers the
        // question the keypress asked.
        if snapshot.isMuted == true {
            // Level zero, not the volume being held behind the mute. A full bar drawn next to a
            // crossed-out speaker says two opposite things at once.
            //
            // **And no limit, which is the whole reason `SystemHUDReading.limit` is decided here.**
            // This is the one place in the app that publishes a zero nobody ran a level down to, and
            // an island deriving "at the bottom" from the number alone would bounce on every mute.
            return SystemHUDReading(hud: .mute, level: 0)
        }

        // A device with no volume property (aggregate devices, most HDMI outputs) can still have
        // changed its mute flag; with neither there is nothing to draw a bar from.
        guard let volume = snapshot.volume else { return nil }
        return SystemHUDReading(
            hud: .volume, level: volume, limit: SystemHUDReading.limit(atLevel: volume)
        )
    }
}
