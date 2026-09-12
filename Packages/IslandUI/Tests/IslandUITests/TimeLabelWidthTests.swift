import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import IslandUI

/// Whether the elapsed and remaining times actually fit the slots they are drawn in.
///
/// The slots are **constants** — fixed so the row does not shuffle sideways as a track crosses from
/// "9:59" to "10:00" — so nothing at runtime can notice a number that does not fit, and a number
/// that does not fit is drawn as `-1:0…` beside a bar with room to spare. That is what shipped
/// until 2.3.0, reported from a browser playing a 77-minute video.
///
/// **Measured in real SF, not asserted from memory**, for `WideFlankTests`' reason: these are font
/// metrics, and a system font update moves them. The strings are held here rather than produced
/// through `ActivityValueFormatter` because what is being measured is the *widest* a clock can get,
/// which is a fact about the format rather than about any particular track.
@Suite("Time label widths")
struct TimeLabelWidthTests {

    /// The widest a sub-hour clock gets. **Every remaining time on a track over ten minutes is this
    /// wide** — the labels are monospaced, so `-44:12` and `-59:59` are the same picture — which is
    /// why 38pt was thin for ordinary music and not only for films.
    private static let withinAnHour = "-59:59"

    /// The widest an hours clock gets before a tenth hour it will never reach.
    private static let withHours = "-9:59:59"

    /// The player's own label: SF **Rounded**, 11pt, medium, monospaced digits — §6.5's rule for
    /// numerals being read as a quantity.
    private static func playerWidth(of text: String) -> CGFloat {
        width(of: text, size: 11, weight: .medium, rounded: true)
    }

    /// The lock-screen card's: SF Pro at the card's own size, which it sets rather than shares —
    /// read from `timeLabelFontSize` and never written as a literal, so raising the font without
    /// raising `timeLabelWidth` fails here instead of truncating a film on a locked screen.
    private static func cardWidth(of text: String) -> CGFloat {
        width(
            of: text,
            size: LockScreenCardLayout.timeLabelFontSize,
            weight: .medium,
            rounded: false
        )
    }

    private static func width(
        of text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        rounded: Bool
    ) -> CGFloat {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = font.fontDescriptor
        if rounded, let design = descriptor.withDesign(.rounded) { descriptor = design }
        descriptor = descriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        font = NSFont(descriptor: descriptor, size: size) ?? font
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - The player

    @Test("a song's remaining time fits the slot it is drawn in")
    func songFits() {
        let slot = NowPlayingExpandedLayout.timeLabelWidth(forDuration: 180)
        let needed = Self.playerWidth(of: Self.withinAnHour)
        #expect(needed <= slot, "\(Self.withinAnHour) needs \(needed)pt of \(slot)")
    }

    /// **The failure this suite exists for.** 4637 seconds is the video that was reported.
    @Test("a film's remaining time fits the slot it is drawn in")
    func filmFits() {
        let slot = NowPlayingExpandedLayout.timeLabelWidth(forDuration: 4637)
        let needed = Self.playerWidth(of: Self.withHours)
        #expect(needed <= slot, "\(Self.withHours) needs \(needed)pt of \(slot)")
    }

    /// The old constant, kept as the record of what was wrong: 38pt could not hold the string every
    /// track over ten minutes draws. Not an assertion about the current value — an assertion that
    /// the current value is not that one by accident.
    @Test("the width that shipped was too narrow for the string it had to hold")
    func theOldWidthWasShort() {
        #expect(Self.playerWidth(of: Self.withinAnHour) > 38)
    }

    /// The whole reason the width is a function of the track rather than one number: an hours slot
    /// on every song would cost the scrub bar 24pt to hold a digit no song can produce.
    @Test("an hour of content is what widens the labels, and nothing shorter")
    func onlyHoursWiden() {
        let short = NowPlayingExpandedLayout.timeLabelWidth(forDuration: 3599)
        let long = NowPlayingExpandedLayout.timeLabelWidth(forDuration: 3600)
        #expect(short < long)
        #expect(NowPlayingExpandedLayout.timeLabelWidth(forDuration: 0) == short)
    }

    /// **The bar is laid out against the same answer the labels are**, so the two cannot disagree
    /// about where the row begins — and a film's bar is therefore shorter than a song's by exactly
    /// what its labels took.
    @Test("the scrub bar gives up exactly what the labels take")
    func theBarPaysForTheLabels() {
        let body = CGRect(x: 0, y: 0, width: 368, height: 176)
        let song = NowPlayingExpandedLayout.scrubberRect(in: body, duration: 180)
        let film = NowPlayingExpandedLayout.scrubberRect(in: body, duration: 4637)
        let taken = NowPlayingExpandedLayout.timeLabelWidthWithHours
            - NowPlayingExpandedLayout.timeLabelWidthWithinAnHour
        #expect(film.width == song.width - taken * 2)
        // And it is still a bar rather than a sliver between two numbers.
        #expect(film.width > body.width / 2)
    }

    // MARK: - The lock-screen card

    /// The card's slot holds every song at full size — see `LockScreenCardLayout.timeLabelWidth`,
    /// which reserves the minutes clock rather than the hours one.
    @Test("the card's slot holds a minutes clock at full size")
    func cardHoldsMinutes() {
        let slot = LockScreenCardLayout.timeLabelWidth
        let needed = Self.cardWidth(of: Self.withinAnHour)
        #expect(needed <= slot, "\(Self.withinAnHour) needs \(needed)pt of \(slot)")
    }

    /// And a film's fits once it shrinks, which is the whole reason the slot could come down.
    ///
    /// Asserted rather than eyeballed because the two numbers move independently: raising
    /// `timeLabelFontSize` or lowering `timeLabelWidth` without touching the scale factor is how a
    /// film's clock gets truncated on a surface nobody is at the Mac to see.
    @Test("the card's slot holds an hours clock once it shrinks")
    func cardHoldsHoursWhenScaled() {
        let slot = LockScreenCardLayout.timeLabelWidth
        let needed = Self.cardWidth(of: Self.withHours) * LockScreenCardLayout.timeLabelMinimumScale
        #expect(needed <= slot, "\(Self.withHours) needs \(needed)pt of \(slot) when scaled")
    }

    /// And the line between them is still the longest thing on the card.
    @Test("the card's progress line survives the wider labels")
    func cardLineSurvives() {
        #expect(LockScreenCardLayout.progressLineWidth > LockScreenCardLayout.progressRowWidth / 2)
    }
}
