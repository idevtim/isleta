import IslandActivities
import SwiftUI

/// Turns an `ActivityTint` into an actual color, in the one place that knows what it is painted on.
///
/// `ActivityTint` is named by meaning rather than by color precisely so this resolution can happen
/// once, here, where the accessibility settings are already known. A provider that hardcoded a hex
/// value would keep drawing it after the user turned on Increase Contrast.
///
/// ## Why every color is spelled in sRGB and none of them are semantic
///
/// The island is pure `#000000` on a real notch and dark glass on a synthesized one, in both
/// appearances — it is optically part of the bezel, and the bezel does not have a light mode. So
/// `Color.primary`, `.accentColor` and friends are all wrong here: they resolve against the
/// *environment's* appearance, and on a Mac in Light mode they resolve to near-black on black. The
/// same argument that puts `Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)` in `IslandRootView`
/// rather than `Color.black` applies to everything drawn on top of it.
///
/// ## Increase Contrast is a correctness requirement (§6.3)
///
/// It does two things here, and the second matters more than the first. It saturates the tints, and
/// it removes the opacity that separates a title from a subtitle. Hierarchy by opacity is the right
/// default on a black island and is exactly what a user who has asked for more contrast is asking
/// us to stop doing — so with it on, secondary text goes to full strength and the hierarchy is
/// carried by weight and size alone.
///
/// ## Album color is not here, and the boundary is the interesting part
///
/// Stage 7.5 lets the Now Playing chrome take its accent from the cover, and none of that lives in
/// this file. The resolution is `NowPlayingController.accent(_:increaseContrast:)` and the
/// extraction is `AlbumColor`, because what a cover gives is a fact about *one track* while
/// everything below is a fact about the island — and the moment those two share a home, somebody
/// will tint the second from the first.
///
/// What it reaches: the transport glyphs, the cover's fallback well, and the played portion of the
/// scrub bar. What it must not, and why:
///
/// - **The equaliser stays white.** Six abstract bars carrying the record's color read as
///   decoration; white reads as a level meter. This is the same judgement `NowPlayingEqualiserView`
///   already records.
/// - **The numerals stay gray.** A colored number reads as a value that means something by its
///   color, and a clock does not.
/// - **`timerRing`, `batteryRing` and `batteryRingLow` below are untouchable.** Those three
///   *are* the information — Clock's orange means "counting down", green and amber mean "charged"
///   and "getting low" — and an album is not allowed to restate them.
/// - **Increase Contrast wins.** A color derived from an arbitrary image can be promised no
///   particular contrast, so the accent falls back to the palette's own.
public enum ActivityPalette {

    /// The color a tint resolves to for a symbol or a title.
    public static func color(for tint: ActivityTint, increaseContrast: Bool) -> Color {
        switch tint {
        case .neutral:
            increaseContrast ? rgb(1.00, 1.00, 1.00) : rgb(0.94, 0.94, 0.96)
        case .accent:
            increaseContrast ? rgb(0.62, 0.82, 1.00) : rgb(0.42, 0.69, 1.00)
        case .positive:
            increaseContrast ? rgb(0.44, 0.94, 0.60) : rgb(0.25, 0.83, 0.45)
        case .warning:
            increaseContrast ? rgb(1.00, 0.85, 0.40) : rgb(1.00, 0.78, 0.24)
        case .critical:
            increaseContrast ? rgb(1.00, 0.55, 0.50) : rgb(1.00, 0.36, 0.31)
        }
    }

    /// Strength of text that is not the headline — subtitles, units, the unfilled part of a bar.
    ///
    /// Full strength under Increase Contrast, for the reason in the type's doc comment.
    public static func secondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 1.0 : 0.62
    }

    /// The unfilled part of a level bar. Never invisible: the length of the track is what makes the
    /// filled part mean anything, and a track that vanishes at low volume turns a bar into a dot.
    public static func trackOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.45 : 0.22
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// Clock's own timer orange, spelled in sRGB.
    ///
    /// Explicit components rather than `.orange` or `NSColor.systemOrange`, for the same reason the
    /// island's black is spelled out: a named system color resolves differently by appearance and
    /// by accent, and a ring that shifts by a shade against pure `#000000` in a notch reads as a
    /// different color rather than as the same one lit differently.
    ///
    /// Matched by eye from Clock's radial timer rather than sampled — the arc was not in any capture
    /// that could be sampled. If it looks off beside the real thing, this constant is the only place
    /// to change.
    public static let timerRing = Color(.sRGB, red: 1.0, green: 0.541, blue: 0.118, opacity: 1)

    /// A held timer's arc. Clock grays it, and so does this: a lit orange arc on a paused timer
    /// reads as one that is still running.
    public static let timerRingPaused = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.55)

    /// The unfilled part of the ring. Dark enough to read as a track rather than as a second arc.
    public static let timerRingTrack = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.16)

    /// The battery ring on a device that has just connected.
    ///
    /// Apple's own green, the one the system uses for a charged battery, spelled in sRGB for the
    /// reason every color here is: a semantic `Color.green` resolves differently by appearance and
    /// would shift shade against a notch that is always `#000000`.
    public static let batteryRing = Color(.sRGB, red: 0.204, green: 0.780, blue: 0.349, opacity: 1)

    /// Below `DeviceConnectSlotView.lowBatteryThreshold`. Amber rather than red: the device just
    /// connected and still works, so this is information, not a fault.
    public static let batteryRingLow = Color(.sRGB, red: 1.0, green: 0.584, blue: 0.0, opacity: 1)
}
