import Testing

@testable import IslandSources

/// The ladder Isleta has to walk before it may swallow a brightness key.
///
/// Every number here came off the hardware on 2026-08-30 — see `BrightnessStep`'s doc comment for
/// the raw readings. They are asserted rather than derived because the grid is not a formula anyone
/// would guess: thirteen lit levels of 0.0825 starting at 0.01, plus a fourteenth stop at off.
@Suite("Brightness stepping")
struct BrightnessStepTests {

    /// The four consecutive identical deltas that established the notch, replayed forwards.
    @Test("the measured descent from 1.0 is reproduced exactly")
    func matchesTheHardwareDescent() {
        let expected = [0.9175, 0.835, 0.7525, 0.67, 0.5875]
        var level = 1.0
        for step in expected {
            level = BrightnessStep.apply(.down, level: level).level
            #expect(abs(level - step) < 1e-9, "expected \(step), got \(level)")
        }
    }

    /// `0.01 + 12 × 0.0825` lands on exactly 1.0, which is what makes this grid the right one rather
    /// than merely a close fit.
    @Test("twelve notches above the floor reach full brightness")
    func twelveNotchesReachFull() {
        #expect(abs((BrightnessStep.floor + 12 * BrightnessStep.notch) - 1.0) < 1e-9)
        #expect(BrightnessStep.ladder.count == 14, "thirteen lit levels and an off")
        #expect(BrightnessStep.ladder.first == 0)
        #expect(abs((BrightnessStep.ladder.last ?? 0) - 1.0) < 1e-9)
    }

    /// **The floor is not zero, and zero is still reachable.** A ladder that started at zero would
    /// skip the dimmest lit level, which is the one people actually use in the dark.
    ///
    /// The hardware log reads `0.1 → 0.01, delta -0.090000`, and that is **two presses merged into
    /// one plateau** rather than one press of 0.09: the probe reported a value once it had held still
    /// for 500 ms, and two quick presses ramp through 0.0925 without ever settling there.
    /// `0.0175 + 0.0825` is not a step, and `0.0075 + 0.0825` is — 0.1 down to 0.0925, then 0.0925
    /// down to 0.01, which sums to exactly the -0.09 that was logged. The independently measured
    /// `0.01 → 0.0925` ascent is what confirms 0.0925 is a real rung.
    @Test("the bottom of the ladder is off, one rung below the dimmest lit level")
    func floorAndOff() {
        let first = BrightnessStep.apply(.down, level: 0.1).level
        #expect(abs(first - 0.0925) < 1e-9, "0.1 snaps down to the rung below it")

        let dim = BrightnessStep.apply(.down, level: first).level
        #expect(abs(dim - 0.01) < 1e-9)
        // The two presses together are the -0.09 the probe logged as one.
        #expect(abs((0.1 - dim) - 0.09) < 1e-9)

        let off = BrightnessStep.apply(.down, level: dim).level
        #expect(off == 0)

        // And nothing below it.
        let stillOff = BrightnessStep.apply(.down, level: 0)
        #expect(stillOff.level == 0)
        #expect(stillOff.didChange == false)
        #expect(stillOff.didReachLimit)
    }

    @Test("the first rung up from off is the dimmest lit level")
    func upFromOff() {
        #expect(abs(BrightnessStep.apply(.up, level: 0).level - 0.01) < 1e-9)
    }

    /// Measured: 0.01 → 0.0925.
    @Test("the rung above the floor is one notch")
    func upFromFloor() {
        #expect(abs(BrightnessStep.apply(.up, level: 0.01).level - 0.0925) < 1e-9)
    }

    /// **Off-grid snapping matters more here than for volume**, because the ambient-light system
    /// moves the panel between rungs on its own. This is the normal case rather than an edge one.
    @Test("an off-grid level snaps to the next rung in the direction pressed")
    func snapsToTheLadder() {
        // 0.5 is between 0.4225 and 0.505.
        #expect(abs(BrightnessStep.apply(.up, level: 0.5).level - 0.505) < 1e-9)
        #expect(abs(BrightnessStep.apply(.down, level: 0.5).level - 0.4225) < 1e-9)
    }

    /// A level already on a rung advances by one rather than standing still — the `ceil`-versus-floor
    /// bug `VolumeStepTests` guards, in its brightness form.
    @Test("a level already on a rung still moves")
    func onGridStillMoves() {
        let up = BrightnessStep.apply(.up, level: 0.505)
        #expect(abs(up.level - 0.5875) < 1e-9)
        #expect(up.didChange)
    }

    @Test("the ends are limits without being changes")
    func limitsAreNotChanges() {
        let top = BrightnessStep.apply(.up, level: 1.0)
        #expect(top.level == 1.0)
        #expect(top.didChange == false)
        #expect(top.didReachLimit)
    }

    /// Thirteen presses from off reach full: one onto the floor, then twelve notches.
    @Test("thirteen presses walk the whole ladder")
    func thirteenPressesCrossTheRange() {
        var level = 0.0
        for _ in 0..<13 { level = BrightnessStep.apply(.up, level: level).level }
        #expect(abs(level - 1.0) < 1e-9)
    }

    @Test("stepping never leaves the range")
    func staysInRange() {
        for start in stride(from: 0.0, through: 1.0, by: 0.01) {
            for direction in [BrightnessStep.Direction.up, .down] {
                for fine in [true, false] {
                    let outcome = BrightnessStep.apply(direction, level: start, fine: fine)
                    #expect(outcome.level >= 0)
                    #expect(outcome.level <= 1)
                }
            }
        }
    }

    @Test("an impossible level is clamped rather than trusted")
    func clampsBadInput() {
        #expect(BrightnessStep.apply(.up, level: 9).level == 1.0)
        #expect(BrightnessStep.apply(.down, level: -9).level == 0.0)
    }

    /// A quarter-notch is arithmetic off the current value rather than a move along the ladder,
    /// because by definition it lands between rungs. **Nothing sets `fine` for brightness today** —
    /// the measurement came back at a full notch for presses that were meant to be modified, and
    /// shipping a fine step Apple does not have is the same class of fidelity bug as missing one it
    /// does. This pins the behaviour so it is correct whenever that is settled.
    @Test("a fine step is a quarter notch off the current value, not a rung")
    func fineStepLeavesTheLadder() {
        let outcome = BrightnessStep.apply(.up, level: 0.505, fine: true)
        #expect(abs(outcome.level - (0.505 + 0.0825 / 4)) < 1e-9)
        #expect(!BrightnessStep.ladder.contains { abs($0 - outcome.level) < 1e-9 })
    }
}
