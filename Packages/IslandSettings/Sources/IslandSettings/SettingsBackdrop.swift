import IslandKit
import SwiftUI

/// The colors the settings window is built from, taken from Isleta's own app icon.
///
/// The two stops are the literal values in `Isleta.icon/icon.json` — the icon's fill is a linear
/// gradient between them — so the window and the icon in the Dock are the same object rather than
/// two things that were each described as "teal". They are spelled in extended sRGB for the same
/// reason §6.4 spells the island's black in sRGB: a color left to `Color(red:green:blue:)`'s
/// default space is free to resolve differently under a display profile, and "close to the icon" is
/// the failure this avoids.
enum SettingsPalette {

    /// `extended-srgb:0.023529,0.184314,0.298039` — the icon gradient's dark stop.
    static let deep = Color(.sRGB, red: 0.023529, green: 0.184314, blue: 0.298039)

    /// `extended-srgb:0.070588,0.627451,0.737255` — the icon gradient's light stop.
    static let bright = Color(.sRGB, red: 0.070588, green: 0.627451, blue: 0.737255)

    // MARK: - Backdrop stops
    //
    // The icon's two colors are the *source*, not the backdrop. An icon is 128pt of saturated
    // artwork the eye lands on deliberately; a window is 760pt the eye reads across for a minute at
    // a time, and the same two stops at window size are a wall of teal that every label has to
    // compete with. What carries over is the hue.

    /// Dark appearance: near-black with a teal cast, which is what "dark mode" means everywhere else
    /// on the system. The previous values were the icon's own stops, and they lifted the window to
    /// roughly `#0d6b92` at the brightest corner once the ripples were composited — a mid teal that
    /// read as a *light* window with a blue tint sitting among the user's actually-dark ones.
    static let darkTop = deep.mix(with: .black, by: 0.6)
    static let darkBottom = deep.mix(with: bright, by: 0.22).mix(with: .black, by: 0.25)

    /// Light appearance: the same hue with almost all the saturation removed. It cannot be the
    /// icon's own gradient — the deep stop is darker than any text color AppKit puts on a light
    /// window, so it would need white labels, which is not what the rest of a light window uses.
    ///
    /// **Both stops came down on 2026-08-28, and the reason is the flat cards.** They were 0.86 and
    /// 0.9, which put the brightest corner of the backdrop at `#F3FFFF` once the ripples were
    /// composited — *brighter* than the near-white card at `#F6FAFC`. Glass hid that, because a lens
    /// samples what is under it and therefore sits above the backdrop wherever it lands; an opaque
    /// card cannot, so a card was darker than its background on the left of the window and lighter
    /// on the right, and the same card read as sunk at one end of a pane and raised at the other.
    /// A surface that is *always* below the card is the requirement, and it is the backdrop's job to
    /// meet it rather than the card's to chase it.
    static let lightTop = bright.mix(with: .white, by: 0.78)
    static let lightBottom = deep.mix(with: .white, by: 0.85)

    // MARK: - Flat surfaces
    //
    // Added 2026-08-28, when the window's cards stopped being glass. Everything here is **opaque**,
    // and that is the whole difference: a material samples what is behind it and resolves toward
    // the system's gray no matter what the backdrop is doing, which is why the old header band read
    // as a gray bar across a teal window. A mix of the icon's own two colors cannot drift, because
    // there is nothing behind it to sample.
    //
    // Each is a mix off `deep` or `bright` rather than a fourth and fifth literal, so the window
    // still has exactly two colors in it and the day the icon changes they all move together.

    /// The surface a card is drawn on — one step *toward* the reader from the backdrop behind it.
    ///
    /// Light is near-white with a teal cast rather than white, because a pure white card on a pale
    /// teal window is the one combination that reads as a hole rather than as a panel.
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? deep.mix(with: .black, by: 0.45) : bright.mix(with: .white, by: 0.95)
    }

    /// The bar at the top of the detail column, and anything else that has to sit *over* content
    /// scrolling under it. One step the other way — away from the reader, toward the backdrop — so
    /// it reads as chrome rather than as another card.
    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? deep.mix(with: .black, by: 0.5) : bright.mix(with: .white, by: 0.82)
    }

    /// The hairline: between two rows in a card, and under the pane header.
    ///
    /// A tint of the window's own colors rather than `Color(nsColor: .separatorColor)`, which is a
    /// neutral gray and is visible as gray against every surface above. One line is not worth a
    /// note on its own; twelve of them down a pane is the window's grain, and grain in the wrong
    /// hue is what makes a tinted window look like a gray one with a filter on it.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.1) : deep.opacity(0.12)
    }
}

/// What the glass in this window refracts.
///
/// Liquid Glass is a *lens*, not a color. Given a flat window background it has nothing to bend
/// and resolves to a faintly lit gray rectangle — which is why a first pass at a glass settings
/// window so often reads as plastic. Everything here exists to put something worth refracting
/// behind the cards: a gradient with a direction, and two soft ripples the edge treatment can catch.
///
/// There was a third thing — a blurred island silhouette hanging from the top of the window, echoing
/// how the real one hangs from the top of a screen. It is gone deliberately. Drawn crisply it read as
/// a stray dark rectangle sitting on the title bar, and blurred enough not to, it read as a smudge:
/// either way it was a picture of the product inside the product, which is decoration rather than
/// design. The gradient already carries the identity.
///
/// It is deliberately low-contrast. The cards sit on top of it carrying every word in the window,
/// and a backdrop that competes with them is a backdrop that has to be turned off.
struct SettingsBackdrop: View {

    /// Light and dark are not the same design with the colors swapped.
    ///
    /// In dark the icon's own gradient is the backdrop, near enough as-is. In light it cannot be:
    /// the deep stop is darker than any text color AppKit will put on top of it, so the same
    /// gradient would need white text, which is not what the rest of a light-appearance window uses.
    /// The light variant keeps the *hue* and drops almost all of the saturation, so the window is
    /// recognizably Isleta's without asking the labels to be legible against a navy field.
    @Environment(\.colorScheme) private var colorScheme

    /// Reduce transparency turns this off entirely rather than dimming it.
    ///
    /// §6.3 treats these as correctness. The setting's plain meaning is "do not make me read things
    /// through other things", and the honest response is an opaque window — a *subtler* gradient
    /// would still be a gradient under the text.
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                gradient
                ripples
                    .blendMode(.plusLighter)
                    // Much fainter in dark than it used to be. `plusLighter` *adds*, so the ripples
                    // were contributing more brightness than the gradient underneath them — the
                    // backdrop was dark and the window was not. At this weight they read as a glow
                    // on a dark surface, which is what they were for.
                    // Light came down from 0.28 with the two stops above, and for the same reason:
                    // `plusLighter` *adds*, so the ripples were most of what pushed the top-left
                    // corner past the cards. They are a glow on a surface, not a second gradient.
                    .opacity(colorScheme == .dark ? 0.14 : 0.16)
            }
        }
        .ignoresSafeArea()
    }

    private var gradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [SettingsPalette.darkTop, SettingsPalette.darkBottom]
                : [SettingsPalette.lightTop, SettingsPalette.lightBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The icon's two ripples, as light rather than as artwork.
    ///
    /// Radial rather than the icon's literal arcs, because at window size an arc traced at icon
    /// proportions reads as a stray line. What carries over is where the light is, which is what the
    /// glass above actually samples.
    private var ripples: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RadialGradient(
                    colors: [SettingsPalette.bright.opacity(0.75), .clear],
                    center: .init(x: 0.18, y: 0.08),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.75
                )
                RadialGradient(
                    colors: [SettingsPalette.bright.opacity(0.4), .clear],
                    center: .init(x: 0.95, y: 0.92),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.6
                )
            }
        }
    }

}

extension View {

    /// Applies the window's backdrop, reading reduce-transparency from the environment.
    ///
    /// A modifier rather than something the root view composes by hand, because the fallback has to
    /// be impossible to forget: every surface in this window is transparent by default, and one that
    /// missed the check would be the one a user with reduce transparency on could not read.
    func settingsBackdrop(reduceTransparency: Bool) -> some View {
        background(SettingsBackdrop(reduceTransparency: reduceTransparency))
    }
}
