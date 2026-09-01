import Foundation

/// What macOS does to the display brightness when a brightness key is pressed, reproduced exactly.
///
/// The counterpart to `VolumeStep`, and it is a **separate type rather than a parameter on that one**
/// because the two are not the same ladder wearing different numbers. Volume has sixteen even
/// notches from zero to one. Brightness has thirteen lit levels on a grid that does not start at
/// zero, plus a fourteenth stop at *off* below the bottom of it. A shared implementation would have
/// to be told about a floor, an offset and an extra stop, at which point it is two implementations in
/// one function.
///
/// # The ladder, measured
///
/// On macOS 27.0, Mac15,9, built-in panel, 2026-08-30, by parking the panel off-grid with
/// `DisplayServicesSetBrightness` and reading `DisplayServicesGetBrightness` back after each key
/// press had **settled**:
///
/// ```
/// 1.000000  0.917500  0.835000  0.752500  0.670000  0.587500   delta -0.0825 each
/// 0.100000 -> 0.010000 -> 0.000000                             the floor, and off below it
/// 0.010000 -> 0.092500                                         delta +0.0825
/// ```
///
/// So the grid is `0.01 + n × 0.0825` for `n` in `0...12` — which lands exactly on 1.0, because
/// `0.01 + 12 × 0.0825 = 1.0` — with **0.0 as a separate bottom stop below it**. Thirteen lit levels
/// and an off.
///
/// **The settling is what made this readable.** A first attempt sampled every 30 ms and reported
/// deltas of 0.0137, 0.0184, 0.0107, 0.0062 — six different numbers that were not steps at all, but
/// points on the ramp the *system* animates when it handles a key itself. Any future measurement
/// driven by real key presses has to wait for quiet.
///
/// That ramp is a fact about the backlight, **not** about the API: `DisplayServicesGetBrightness`
/// reports a written value in 0 ms while the panel is still visually travelling, so
/// `SystemBrightnessControl` neither waits for it nor tries to reproduce it. It writes the rung and
/// reads it straight back. The one thing it must not do is reach for
/// `DisplayServicesSetBrightnessSmooth` to get the animation — that setter takes a *delta*, and
/// choosing it for its name is what pinned a panel at full brightness for one build.
///
/// # What is not settled
///
/// **⇧⌥ quarter-steps.** Volume has them and the same gesture is conventional for brightness, but the
/// measurement came back at a full ±0.0825 for presses that were meant to be modified, which is
/// either "brightness has no fine step" or "the modifiers were not held". `fineNotch` therefore
/// exists and `apply` honours it, so the behaviour is *there* if the flag is ever set — and nothing
/// sets it for brightness yet. That is a deliberate open end rather than an oversight: shipping a
/// quarter-step that Apple does not have would be a fidelity bug in the same family as not having
/// one it does.
public enum BrightnessStep {

    /// One press. Measured, not derived — see the ladder above.
    public static let notch = 0.0825

    /// The dimmest level a key will stop at with the backlight still lit.
    ///
    /// Not zero, and that is the whole reason this type is not `VolumeStep`. The grid is built up
    /// from here, so a level of 0.01 is *on the ladder* and a level of 0.0 is below it.
    public static let floor = 0.01

    /// A quarter of a notch, by analogy with `VolumeStep.fineNotch`. **Unverified** — see the note on
    /// the type.
    public static let fineNotch = notch / 4

    /// Every stop a brightness key can land on, dimmest first.
    ///
    /// Spelled as a ladder rather than as arithmetic because that is what it is: the bottom two rungs
    /// are 0.0 and 0.01, which are 0.01 apart, and every rung above is 0.0825 from the last. No
    /// single expression describes that without a special case, and a special case inside a loop is
    /// harder to check against a measurement than a list is.
    public static let ladder: [Double] = {
        var stops: [Double] = [0]
        for n in 0...12 { stops.append(floor + Double(n) * notch) }
        return stops
    }()

    public typealias Direction = VolumeStep.Direction

    /// The level a press produces, and whether it moved at all.
    public struct Outcome: Equatable, Sendable {

        public let level: Double

        /// False when the press asked for something already true — up at 1.0, down at 0.0. The
        /// island's limit rebound runs on this being false while `didReachLimit` is true.
        public let didChange: Bool

        /// Whether the press ran into an end of the ladder.
        public let didReachLimit: Bool

        public init(level: Double, didChange: Bool, didReachLimit: Bool) {
            self.level = level
            self.didChange = didChange
            self.didReachLimit = didReachLimit
        }
    }

    /// Apply one brightness key press.
    ///
    /// - Parameters:
    ///   - level: the current brightness, 0…1, as `DisplayServicesGetBrightness` reports it.
    ///   - fine: whether ⇧⌥ was held. Nothing passes true today — see the type's note.
    public static func apply(_ direction: Direction, level: Double, fine: Bool = false) -> Outcome {
        let current = clamp(level)

        let limit = (direction == .up && current >= 1.0 - tolerance)
            || (direction == .down && current <= tolerance)

        // A fine step is arithmetic off the current value rather than a move along the ladder,
        // because a quarter-notch is by definition *between* rungs.
        if fine {
            let target = clamp(current + (direction == .up ? fineNotch : -fineNotch))
            return Outcome(
                level: target,
                didChange: abs(target - current) > tolerance,
                didReachLimit: limit
            )
        }

        let target = neighbour(of: current, going: direction)
        return Outcome(
            level: target,
            didChange: abs(target - current) > tolerance,
            didReachLimit: limit
        )
    }

    /// The next rung up or down from wherever the level currently is.
    ///
    /// **Off-grid values snap**, exactly as volume's do and for the same reason: a level set by a
    /// script, by Control Center's slider, or by ambient-light adjustment is rarely on a rung, and
    /// Apple's keys move to the grid rather than adding a notch to whatever they found: a panel
    /// parked at 0.1 answers a down press with 0.0925, the rung below, and not with `0.1 - 0.0825`.
    ///
    /// The raw log for that reads `0.1 -> 0.01, delta -0.090000`, which is **two presses merged into
    /// one plateau** rather than one press of 0.09 — the probe only reported a value once it had held
    /// still for 500 ms, and two quick presses ramp through 0.0925 without ever settling there.
    /// `BrightnessStepTests.floorAndOff` pins the reading of it.
    ///
    /// Ambient light makes this matter more here than it does for volume: the panel drifts off-grid
    /// on its own, so "snap to the nearest rung in the direction pressed" is the *normal* case rather
    /// than an edge one.
    static func neighbour(of level: Double, going direction: Direction) -> Double {
        switch direction {
        case .up:
            return ladder.first { $0 > level + tolerance } ?? 1.0
        case .down:
            return ladder.last { $0 < level - tolerance } ?? 0.0
        }
    }

    /// Levels round-trip through a `Float` in DisplayServices — 0.75 comes back as 0.7499999 — so
    /// nothing here may compare them for equality. Same reasoning as `VolumeStep.tolerance`, and the
    /// value is looser because the ambient-light system nudges the panel by small amounts on its own.
    static let tolerance = 1e-4

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
