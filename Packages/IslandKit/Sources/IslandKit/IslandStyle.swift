import CoreGraphics

/// What the island is made of.
///
/// §6.4 fixed this by hardware: pure `#000000` in a real cutout, Liquid Glass where the island
/// floats below the menu bar. Both halves were right for the reason they were written down — a
/// notch island has to be optically continuous with the bezel, and a floating one has nothing to be
/// continuous with — and neither was ever a *taste*. This is where that becomes the user's.
///
/// ## Why there are four cases and not three
///
/// The three the user is offered are Normal, Semi-Liquid Glass and Liquid Glass. `.automatic` is a
/// fourth because the alternative is changing what every existing install looks like on upgrade:
/// stored as `.normal`, a notchless Mac's floating pill would stop being glass the moment somebody
/// installed this version, and stored as `.liquidGlass` a notched one would gain a material §6.4
/// spends a paragraph refusing. `.automatic` is exactly the pair of rules that shipped, so an
/// upgrade changes nothing until the user asks it to, and the other three then mean one thing each
/// on both kinds of display rather than meaning "whatever this screen already was".
///
/// ## Reduce transparency
///
/// §6.3 makes it a correctness requirement rather than polish, and its plain meaning — do not make
/// me read things through other things — reaches this directly: the island is a surface the user
/// reads text off. So both glass styles resolve to `.opaque` under it. That is a *substitution*,
/// like `Motion.respectingReduceMotion`'s crossfade, and not a refusal: the setting keeps its value
/// and comes back the moment the system setting does.
public enum IslandStyle: String, Codable, CaseIterable, Sendable {

    /// What shipped before this setting existed: black in a cutout, Liquid Glass where it floats.
    case automatic

    /// Solid, on both kinds of display. In a cutout this is §6.4's pure `#000000`; floating, it is
    /// the same black, which is what "normal" means everywhere else this kind of app is drawn.
    case normal

    /// Solid black down most of the island, clearing to glass through the bottom tip. The
    /// compromise style: enough material to read text against, and the refraction where the eye
    /// actually is — the bottom edge is the one part of a notch island that has lit pixels under it.
    case semiGlass

    /// Liquid Glass, on both kinds of display.
    case liquidGlass

    /// A label for the picker and for `--style-demo`.
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .normal: "Normal"
        case .semiGlass: "Semi-Liquid Glass"
        case .liquidGlass: "Liquid Glass"
        }
    }

    /// The material this style actually paints on one display, once the display's own kind and the
    /// user's accessibility settings have had their say.
    ///
    /// Pure, and separated from the drawing for the reason every rule in this package is: the
    /// question "what does Semi-Glass do on a notched Mac with Reduce Transparency on" has one
    /// answer, and it should be answerable without a window server.
    public static func material(
        for style: IslandStyle,
        notch: NotchGeometry.Kind,
        reduceTransparency: Bool
    ) -> IslandMaterial {
        let resolved: IslandMaterial = switch style {
        case .automatic: notch == .hardware ? .opaque : .glass
        case .normal: .opaque
        case .semiGlass: .semiGlass
        case .liquidGlass: .glass
        }
        // The substitution, not a refusal. See the type's note.
        return reduceTransparency ? .opaque : resolved
    }
}

/// What one island actually paints, after `IslandStyle.material(for:notch:reduceTransparency:)` has
/// resolved the display and the accessibility settings.
///
/// Three cases rather than four, because `.automatic` is a *question* and this is the answer.
public enum IslandMaterial: String, Equatable, Sendable, CaseIterable {

    /// Pure `#000000`, spelled in sRGB by the renderer so it cannot pick up an appearance-sensitive
    /// variant and lift off the bezel by a shade.
    case opaque

    /// Glass with black painted over it, solid at the top and clearing through the bottom tip. See
    /// `SemiGlassUnderlay` for where the fade sits and why it is a distance rather than a fraction,
    /// and `IslandMaterialView` for why the black is on top rather than underneath.
    case semiGlass

    /// Liquid Glass alone.
    case glass

    /// Whether this material asks SwiftUI for `glassEffect` at all.
    ///
    /// Read by the renderer and by the tests: the whole of the "renders nothing against a custom
    /// `Shape`" trap is confined to the two cases that answer true, and `.opaque` never goes near it.
    public var usesGlass: Bool { self != .opaque }
}
