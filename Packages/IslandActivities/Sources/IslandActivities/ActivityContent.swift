import Foundation
import IslandKit

/// The color role of a piece of content, named by meaning rather than by color.
///
/// Not a `Color`: that would need SwiftUI here, and worse, it would let a provider hardcode a hex
/// value that survives the user turning on Increase Contrast or switching appearance. Every one of
/// these resolves in IslandUI, once, where the accessibility settings are already observed
/// (`AccessibilityPreferences`) and where the "pure `#000000` on a real notch" rule lives.
public enum ActivityTint: Equatable, Sendable, CaseIterable {
    case neutral
    case accent
    case positive
    case warning
    case critical
}

/// Where a player is in a track, expressed so that it stays true without being re-asked.
///
/// The four fields are exactly what `mediaremote-adapter` reports and exactly what is needed to
/// answer "where is it now": the position at a known instant, how fast it is moving, and how long
/// the track is. Everything else about playback is somebody else's field.
///
/// **`anchor` and `rate` are the whole point.** Storing `elapsed` alone would be storing a
/// measurement, and a measurement of a moving thing is wrong the moment after it is taken; the only
/// way to keep it right is to re-take it, which is the poll §9 exists to prevent. Storing the pair
/// makes position a pure function of the current time, so the value that arrives once per track
/// change is still exact ten minutes later. It is also what lets a *paused* track be expressed with
/// no special case at all — `rate` is zero, so `position(at:)` returns the same number forever and
/// nothing on screen has any reason to redraw.
///
/// `Date` rather than a monotonic instant, matching `ActivityExpiry` — see PROGRESS.md. The player
/// reports a wall-clock timestamp and there is no conversion to a monotonic clock that does not
/// reintroduce the same skew. A clock correction mis-places the playhead by the size of the
/// correction until the next update, which is a cosmetic error in a bar 200pt wide.
public struct ActivityTimeline: Equatable, Sendable {

    /// The position, in seconds, at `anchor`.
    public let elapsed: TimeInterval

    /// Track length in seconds. Zero for a live stream, which is why `fraction(at:)` returns nil
    /// rather than dividing — a scrub bar on something with no end is a bar that is always full.
    public let duration: TimeInterval

    /// The instant `elapsed` was true.
    public let anchor: Date

    /// Seconds of playback per second of wall clock. `0` while paused, `1` at normal speed, and
    /// genuinely other values for podcast apps at 1.5x — which is why it is a multiplier and not a
    /// `Bool`. A bar advancing at 1x under audio playing at 1.5x drifts a minute every two.
    public let rate: Double

    public init(elapsed: TimeInterval, duration: TimeInterval, anchor: Date, rate: Double) {
        self.elapsed = elapsed
        self.duration = duration
        self.anchor = anchor
        self.rate = rate
    }

    /// Whether the playhead moves on its own. The single input to whether anything redraws.
    public var isAdvancing: Bool { rate != 0 }

    /// Where the playhead is at `now`, clamped to the track.
    ///
    /// Clamped at both ends, and the far end matters: a player that stops reporting at the end of a
    /// track leaves the last anchor in place, and an unclamped extrapolation would run the numerals
    /// past the duration and paint the bar out of its own track.
    ///
    /// **Time never runs backwards, so the interval is clamped rather than the position.** A `now`
    /// earlier than `anchor` is ordinary — after a seek, because the player timestamps from its own
    /// clock a shade ahead of ours; and on the frame a paused track resumes, because
    /// `IslandScreenModel.clockRate` stops the display link dead while nothing is advancing, so the
    /// `now` the island holds is as old as the pause. The anchor is the last thing the player
    /// actually told us — "at `anchor`, the position was `elapsed`" — and nothing is knowable before
    /// it, so that is what a stale `now` reports.
    ///
    /// It used to extrapolate backwards and clamp the *result* to zero, and that shipped a visible
    /// bug: pressing play after a pause drew one frame with the playhead at **the far left** before
    /// the restarted clock put it back. Reported as "it blips to the far left and immediately goes
    /// back to the place it's playing from". Clamping the position rather than the interval also
    /// hid it from the arithmetic — the number was a real extrapolation to a time that had not
    /// happened, not a missing value.
    ///
    /// The interval clamp is the right shape for a **negative** rate too: a running timer counts
    /// down at `-1`, and a stale `now` there would otherwise report *more* time remaining than the
    /// player last said.
    public func position(at now: Date) -> TimeInterval {
        // Never before the anchor. See above: this is a clamp on elapsed *time*, not on position.
        let sinceAnchor = max(0, now.timeIntervalSince(anchor))
        let advanced = elapsed + sinceAnchor * rate
        guard duration > 0 else { return max(0, advanced) }
        return min(max(0, advanced), duration)
    }

    /// 0...1 through the track, or nil when there is no end to be a fraction of.
    public func fraction(at now: Date) -> Double? {
        guard duration > 0 else { return nil }
        return position(at: now) / duration
    }

    /// The same timeline re-anchored to a position, as if the player had just reported it.
    ///
    /// What a scrub produces. The command travels to the player, the player moves the playhead and
    /// eventually reports the move back — a round trip measured in hundreds of milliseconds — and
    /// without this the bar would spring back to where it was for the whole of it, which reads as
    /// the drag having failed. The optimistic value is *shaped like* a real one rather than being a
    /// held fraction, so exactly one thing on screen is ever the source of the playhead.
    public func seeked(to position: TimeInterval, at instant: Date) -> Self {
        Self(
            elapsed: duration > 0 ? min(max(0, position), duration) : max(0, position),
            duration: duration,
            anchor: instant,
            rate: rate
        )
    }
}

/// A quantity an activity wants drawn rather than spelled out.
///
/// Split out from `title` because these are the shapes that must not be pre-formatted into a
/// string by the provider. A countdown baked into `"4:59"` needs the provider to re-emit an
/// activity every second — polling, forbidden by §9 — where a `.countdown(until:)` lets IslandUI
/// drive the numerals off the display link it is already running for the animation.
public enum ActivityValue: Equatable, Sendable {

    /// 0...1. Volume, brightness, a conversion. See `normalized`.
    case fraction(Double)

    case countdown(until: Date)

    case elapsed(since: Date)

    /// Something is happening and nobody knows how far along it is.
    case indeterminate

    /// A playback position that is a *function of the clock* rather than a sample of it.
    ///
    /// The third shape a quantity can take, and the reason it is not just `.fraction`: a scrub bar
    /// fed a fraction is only true for the instant it was measured, so keeping it current means
    /// re-asking the player several times a second — polling, on a path §9 forbids one on. An
    /// `ActivityTimeline` carries the anchor instead, and IslandUI evaluates it against the display
    /// link it is already running. A track playing for an hour publishes one activity, not 3,600.
    case timeline(ActivityTimeline)

    /// The fraction clamped to 0...1, or nil for the other cases.
    ///
    /// System levels do not arrive clean: a volume read back through CoreAudio lands on
    /// 1.0000000149011612 often enough to matter, and a track that paints 1pt past its own end
    /// reads as a rendering bug rather than as full volume. Clamped here rather than at the call
    /// site so there is one place it can be got right.
    public var normalized: Double? {
        guard case .fraction(let value) = self else { return nil }
        return min(max(value, 0), 1)
    }
}

/// What an activity has to say in one slot of the island.
///
/// Every field optional and every field inert: this is a description, not a view. A slot that has
/// nothing to say is `.empty`, which IslandUI draws as nothing at all rather than as a gap.
public struct ActivityContent: Equatable, Sendable {

    /// An SF Symbol name. Never a bundled asset — §6.5 allows SF Pro and SF Symbols only, and a
    /// vended image would put a resource bundle in the one package that has no rendering in it.
    public var symbol: String?

    /// How full the symbol is drawn, 0...1 — SF Symbols' own *variable value*, which lights a
    /// glyph's layers in turn as the number rises. Nil for a glyph that is simply itself, which is
    /// almost all of them.
    ///
    /// **The volume glyph is what this is for.** `speaker.wave.2.fill` has two wave layers, so a
    /// level drawn into it gives three states — no waves, one, both — and the sliver beside the
    /// cutout then says roughly *where in its range* the volume is without the user reading the bar
    /// on the other side of the notch. It is the same number the bar draws, said a second way, on
    /// the half of the island the eye lands on first.
    ///
    /// **Not every symbol answers, and the ones that do not fail silently** — they draw exactly as
    /// they always did. Measured on macOS 27.0, 2026-08-29, by rendering each at 0, 0.34, 0.67 and 1
    /// and comparing the bitmaps: `speaker.wave.2.fill` and `speaker.wave.3.fill` give three
    /// distinct renders, `speaker.slash.fill`, `sun.max.fill` and `sun.min.fill` give one. So the
    /// volume HUD gets this and the brightness HUD does not, and there is no brightness glyph in SF
    /// Symbols that would. Setting it on a symbol that ignores it costs nothing, which is why this
    /// carries the level for all three HUDs rather than for the one that shows it.
    ///
    /// Clamped by `symbolFill`, not here, for `ActivityValue.normalized`'s reason: a provider
    /// handing back CoreAudio's 1.0000000149 should not be silently rewritten by the thing that
    /// stores it.
    public var symbolVariableValue: Double?

    /// The display name of an installed application whose icon should be drawn in place of
    /// `symbol` — "Mail", "Slack", the string the system itself puts in the banner.
    ///
    /// A **name**, not an image, for the same reason `symbol` is: an image here would need a
    /// resource bundle, a pixel format and a size in the one package with no rendering in it, and
    /// it would have to be resolved by whoever built the activity rather than by whoever knows how
    /// large the slot is. IslandUI resolves it (`ApplicationIconStore`) or does not, and `symbol`
    /// is what draws until it does.
    ///
    /// **`symbol` must still be set.** Resolution is asynchronous and is allowed to fail — the app
    /// may not be on this disk at all, having posted through a helper that has since been deleted —
    /// so a content that names an icon and no glyph draws nothing at all on the frame the island
    /// arrives, which is the only frame anyone is looking at. The two together mean the island
    /// shows a bell immediately and the app's own icon a beat later, the way Now Playing shows a
    /// note and then the cover.
    public var applicationIconName: String?

    public var title: String?

    public var subtitle: String?

    public var value: ActivityValue?

    public var tint: ActivityTint

    /// What VoiceOver says. Separate from `title` because the island's compact slots are glyphs and
    /// abbreviations by design — "1:04" is right on screen and useless read aloud.
    public var accessibilityLabel: String?

    /// `symbolVariableValue` clamped into 0...1, or nil. What the renderer reads.
    public var symbolFill: Double? {
        symbolVariableValue.map { min(max($0, 0), 1) }
    }

    public init(
        symbol: String? = nil,
        symbolVariableValue: Double? = nil,
        applicationIconName: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        value: ActivityValue? = nil,
        tint: ActivityTint = .neutral,
        accessibilityLabel: String? = nil
    ) {
        self.symbol = symbol
        self.symbolVariableValue = symbolVariableValue
        self.applicationIconName = applicationIconName
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
    }

    /// Nothing to draw. Distinct from "not supplied": an activity that deliberately shows nothing
    /// in its trailing slot says so with this.
    public static let empty = ActivityContent()

    public var isEmpty: Bool {
        symbol == nil && applicationIconName == nil && title == nil && subtitle == nil && value == nil
    }
}

/// The four slots an activity fills (§8.3).
///
/// The naming follows the physical island rather than ActivityKit — which does not exist here and
/// must never be imported (§2.2) — so it is worth writing down what each one is:
///
/// - `leading` and `trailing` are the two slivers of lit pixels either side of the cutout while the
///   island is collapsed. They are the *only* places anything can be drawn at rest, because the
///   cutout itself is not a screen.
/// - `compact` is the single small badge shown when the island cannot afford both flanks — a
///   second activity is queued behind this one, or the synthesized island on a notchless display
///   has no cutout to flank.
/// - `expanded` is the open island: the click's result.
public struct ActivityPresentations: Equatable, Sendable {

    public var leading: ActivityContent
    public var trailing: ActivityContent
    public var compact: ActivityContent
    public var expanded: ActivityContent

    public init(
        leading: ActivityContent = .empty,
        trailing: ActivityContent = .empty,
        compact: ActivityContent = .empty,
        expanded: ActivityContent = .empty
    ) {
        self.leading = leading
        self.trailing = trailing
        self.compact = compact
        self.expanded = expanded
    }

    public static let empty = ActivityPresentations()

    /// The slot that carries this activity's body in a given island presentation.
    ///
    /// `.rest` and `.peek` both map to `compact` on purpose. Peek is a few points of growth on an
    /// otherwise resting island (`IslandLayout.peekWidthGrowth`) — an invitation to click, never
    /// the click's result — so swapping the content on hover would answer the invitation before the
    /// user accepted it, and would put a content transition on the same frames as the size spring.
    ///
    /// The flanks are not returned here because they are not an alternative to `compact`; they are
    /// drawn beside the cutout in the same states. IslandUI reads `leading`/`trailing` directly.
    /// The content for one of the two slivers.
    ///
    /// Separate from `content(for: IslandPresentation)` because the two questions genuinely differ:
    /// a presentation picks between the *body* renderings, and the flanks are drawn alongside
    /// whichever of those is up. `ActivityStage` asks this one.
    public func content(for flank: ActivityFlank) -> ActivityContent {
        switch flank {
        case .leading: leading
        case .trailing: trailing
        }
    }

    public func content(for presentation: IslandPresentation) -> ActivityContent {
        switch presentation {
        case .rest, .peek: compact
        case .expanded: expanded
        }
    }
}
