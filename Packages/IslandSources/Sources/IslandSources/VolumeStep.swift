import Foundation

/// What macOS does to the output level when a volume key is pressed, reproduced exactly.
///
/// **Pure arithmetic on purpose, and separated from everything that touches CoreAudio**, because
/// this is the half that has to be *right* rather than merely working. Once Isleta swallows a volume
/// key it owns the entire behaviour of that key, and every part of that behaviour is undocumented,
/// is compared against by muscle memory, and is instantly visible when wrong. A value type with no
/// I/O is testable against the numbers a real Mac produces; a function that reads and writes
/// CoreAudio in the same breath is testable only by pressing keys.
///
/// # The numbers, and where they come from
///
/// macOS divides the output level into **sixteen notches**, so one press is `1/16` = 0.0625. That is
/// not a guess: the measurement in `HUDConsumeSelfTest`'s control phase moved five presses from
/// 0.2000 to 0.5000 — five notches of 0.0625 from a level that was itself set to 0.2 rather than
/// snapped, which is also why the first press lands on a *boundary* rather than adding a notch to an
/// off-grid value. See `stepping(from:)`.
///
/// Holding **⇧⌥** gives quarter-notches, `1/64` = 0.015625. Every level app on the platform
/// reproduces it and Apple documents it nowhere.
///
/// # The three behaviours that are not arithmetic
///
/// - **Volume-up unmutes.** Pressing volume-up while muted does not raise a silent level; it unmutes
///   at the level that was already there. Only the *second* press raises it. Getting this wrong
///   means a user hits volume-up once, sees the number move, and hears nothing.
/// - **Volume-down does not mute.** It walks to zero and stops. Muted and zero are different states
///   — the mute switch is a separate CoreAudio property — and collapsing them loses the level the
///   user is muted *at*.
/// - **Mute toggles, and unmuting at zero raises nothing.** A device muted at 0.0 that is unmuted is
///   still silent, which is correct and looks broken; the HUD showing the level is what makes it
///   legible.
public enum VolumeStep {

    /// One notch. Sixteen of them span the range.
    public static let notch = 1.0 / 16.0

    /// One notch with ⇧⌥ held. A quarter of a notch, so sixty-four across the range.
    public static let fineNotch = 1.0 / 64.0

    /// Which direction a key press moves the level.
    public enum Direction: Sendable, Equatable {
        case up
        case down
    }

    /// The level and mute state a press produces, given what they were.
    public struct Outcome: Equatable, Sendable {

        /// Where the level lands. Unchanged from the input when the press only unmuted.
        public let volume: Double

        /// Whether the device is muted afterwards.
        public let isMuted: Bool

        /// Whether anything actually changed. False when a press asks for something already true —
        /// volume-up at 1.0, volume-down at 0.0 — which is what the island's limit rebound is *for*
        /// (`IslandScreenModel.limitBounce`) and therefore has to be distinguishable rather than
        /// silently collapsed into "no change".
        public let didChange: Bool

        /// Whether the press ran into the end of the range. Distinct from `didChange`: unmuting is a
        /// change that is not a limit, and volume-up at 1.0 is a limit that is not a change.
        public let didReachLimit: Bool

        public init(volume: Double, isMuted: Bool, didChange: Bool, didReachLimit: Bool) {
            self.volume = volume
            self.isMuted = isMuted
            self.didChange = didChange
            self.didReachLimit = didReachLimit
        }
    }

    /// Apply one volume key press.
    ///
    /// - Parameters:
    ///   - direction: which key.
    ///   - volume: the current level, 0…1.
    ///   - isMuted: the current mute state, read from CoreAudio's own property rather than inferred
    ///     from a zero level — they are genuinely different states.
    ///   - fine: whether ⇧⌥ was held.
    public static func apply(
        _ direction: Direction,
        volume: Double,
        isMuted: Bool,
        fine: Bool = false
    ) -> Outcome {
        let current = clamp(volume)

        // **Volume-up unmutes before it raises**, and this branch has to come first. A muted device
        // whose level is already 0.5 goes to *audible at 0.5*, not to 0.5625 — the press spends
        // itself on the unmute. Apple's own behaviour, and the one people notice immediately.
        if direction == .up, isMuted {
            return Outcome(volume: current, isMuted: false, didChange: true, didReachLimit: false)
        }

        let step = fine ? fineNotch : notch
        let target: Double
        switch direction {
        case .up: target = stepping(from: current, by: step, up: true)
        case .down: target = stepping(from: current, by: step, up: false)
        }

        let landed = clamp(target)
        let changed = abs(landed - current) > tolerance
        // The limit is about where the press *wanted* to go, not where it landed: a press at 1.0 has
        // reached the limit even though nothing moved, and that is exactly the case the rebound
        // animates.
        let limit = (direction == .up && current >= 1.0 - tolerance)
            || (direction == .down && current <= tolerance)

        return Outcome(
            volume: landed,
            // **Volume-down never mutes.** It walks to zero and stops there; muted-at-a-level and
            // silent-at-zero are different states and the mute key is what moves between them.
            isMuted: isMuted,
            didChange: changed,
            didReachLimit: limit
        )
    }

    /// Toggle mute, as the mute key does.
    ///
    /// The level is untouched, which is the whole point of mute being a separate property: unmuting
    /// returns you to where you were rather than to some remembered guess.
    public static func toggleMute(volume: Double, isMuted: Bool) -> Outcome {
        Outcome(
            volume: clamp(volume),
            isMuted: !isMuted,
            didChange: true,
            // Unmuting a device sitting at zero is still silent. Not a limit — nothing was refused —
            // but the HUD showing 0 is what stops it reading as broken.
            didReachLimit: false
        )
    }

    /// Move one step, snapping to the grid rather than adding to an off-grid value.
    ///
    /// **The snap is the part that is easy to miss.** A level set by a script, by a slider drag, or
    /// by another app is rarely a multiple of 1/16 — `osascript -e 'set volume output volume 20'`
    /// leaves 0.2, and 0.2 + 0.0625 is 0.2625, which is on no notch at all. Apple's keys land on the
    /// grid: from 0.2, volume-up goes to 0.25, and five presses reach 0.5. That is precisely what the
    /// control phase of `HUDConsumeSelfTest` measured (0.2000 → 0.5000 in five presses), so the
    /// arithmetic here is pinned to a reading rather than to an assumption.
    ///
    /// A value already on the grid simply moves one step, because flooring it and adding one is the
    /// same answer.
    static func stepping(from value: Double, by step: Double, up: Bool) -> Double {
        let index = value / step
        if up {
            // `floor(index) + 1` rather than `ceil`, so a value already on a notch advances instead
            // of standing still — `ceil(4.0)` is 4.0, and the press would do nothing.
            let next = (floor(index + tolerance) + 1) * step
            return next
        }
        let previous = (ceil(index - tolerance) - 1) * step
        return previous
    }

    /// Levels are compared with a tolerance because they are `Float32` in CoreAudio and `Double`
    /// here: a round trip through the audio device turns 0.75 into 0.7499999, and an equality test
    /// against the value just written reports a change that did not happen.
    static let tolerance = 1e-6

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
