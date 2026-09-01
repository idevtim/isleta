import Foundation
import IslandActivities
import Testing

@testable import IslandUI

@Suite("Activity value formatting")
struct ActivityValueFormatterTests {

    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    @Test("a countdown reads m:ss and grows an hours field only when there are hours")
    func countdown() {
        #expect(ActivityValueFormatter.text(for: .countdown(until: epoch.addingTimeInterval(64)), at: epoch) == "1:04")
        #expect(ActivityValueFormatter.text(for: .countdown(until: epoch.addingTimeInterval(9)), at: epoch) == "0:09")
        #expect(ActivityValueFormatter.text(for: .countdown(until: epoch.addingTimeInterval(3661)), at: epoch) == "1:01:01")
    }

    @Test("elapsed time counts up from the instant it was given")
    func elapsed() {
        let now = epoch.addingTimeInterval(125)
        #expect(ActivityValueFormatter.text(for: .elapsed(since: epoch), at: now) == "2:05")
    }

    /// The display link and the coordinator's scheduled sleep are two clocks with no ordering
    /// between them, so a frame drawn after a deadline and before the withdrawal is normal. `-0:01`
    /// in that frame is not.
    @Test("a countdown that has run out reads zero, never negative")
    func expiredCountdownDoesNotGoNegative() {
        #expect(ActivityValueFormatter.text(for: .countdown(until: epoch), at: epoch.addingTimeInterval(30)) == "0:00")
        #expect(ActivityValueFormatter.text(for: .elapsed(since: epoch.addingTimeInterval(30)), at: epoch) == "0:00")
    }

    /// A fraction and an indeterminate value are drawn, not spelled. Returning `""` instead of nil
    /// would reserve a line's worth of height for a string with nothing in it.
    @Test("values that are drawn rather than spelled produce no text")
    func drawnValuesHaveNoText() {
        #expect(ActivityValueFormatter.text(for: .fraction(0.5), at: epoch) == nil)
        #expect(ActivityValueFormatter.text(for: .indeterminate, at: epoch) == nil)
    }

    /// The compact slots are glyphs and abbreviations by design; "1:04" read aloud is "one oh four".
    @Test("VoiceOver gets words where the screen gets numerals")
    func spokenForm() {
        #expect(ActivityValueFormatter.accessibilityText(for: .fraction(0.615), at: epoch) == "62 percent")
        #expect(ActivityValueFormatter.accessibilityText(for: .indeterminate, at: epoch) == "in progress")
        #expect(
            ActivityValueFormatter.accessibilityText(
                for: .countdown(until: epoch.addingTimeInterval(61)), at: epoch
            ) == "1 minute 1 second remaining"
        )
    }

    /// `normalized` clamps upstream, and the bar depends on that: CoreAudio hands back
    /// 1.0000000149 often enough to matter, and a bar 1pt past its own end is a rendering bug.
    @Test("a fraction is clamped before it reaches the bar")
    func fractionIsClamped() {
        #expect(ActivityValue.fraction(1.0000000149011612).normalized == 1)
        #expect(ActivityValue.fraction(-0.2).normalized == 0)
    }
}

@Suite("Activity palette")
struct ActivityPaletteTests {

    /// Five tints that resolve to the same color would make `ActivityTint` decoration.
    @Test("every tint resolves to a distinct color")
    func tintsAreDistinct() {
        let colors = ActivityTint.allCases.map { ActivityPalette.color(for: $0, increaseContrast: false) }
        for (index, color) in colors.enumerated() {
            for other in colors[(index + 1)...] {
                #expect(color != other)
            }
        }
    }

    /// §6.3 is a correctness requirement, not polish. Increase Contrast has to change something
    /// about every tint, or it is being observed and ignored.
    @Test("increase contrast changes every tint")
    func increaseContrastIsHonored() {
        for tint in ActivityTint.allCases {
            #expect(
                ActivityPalette.color(for: tint, increaseContrast: false)
                    != ActivityPalette.color(for: tint, increaseContrast: true)
            )
        }
    }

    /// Hierarchy by opacity is the right default on a black island, and it is exactly what a user
    /// asking for more contrast is asking us to stop doing.
    @Test("increase contrast removes the opacity that separates subtitle from title")
    func secondaryTextGoesToFullStrength() {
        #expect(ActivityPalette.secondaryOpacity(increaseContrast: false) < 1)
        #expect(ActivityPalette.secondaryOpacity(increaseContrast: true) == 1)
        #expect(
            ActivityPalette.trackOpacity(increaseContrast: true)
                > ActivityPalette.trackOpacity(increaseContrast: false)
        )
    }

    /// The track is what gives the filled part of a bar a length to be a fraction of. At zero it
    /// would be the only thing on screen, and a bar that vanishes at low volume is a dot.
    @Test("the unfilled part of a bar is never invisible")
    func trackIsAlwaysVisible() {
        #expect(ActivityPalette.trackOpacity(increaseContrast: false) > 0)
    }
}
