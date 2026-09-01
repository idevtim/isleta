import Testing

@testable import IslandKit

/// What each style paints, on each kind of display, with and without Reduce Transparency.
///
/// Twelve of these sixteen answers can be read straight off the `switch`. The four that cannot are
/// the ones worth a suite: whether `.automatic` genuinely reproduces what shipped before there were
/// styles, and whether Reduce Transparency reaches *both* glass styles rather than only the one
/// somebody remembered to handle. The second is §6.3, which this project treats as a correctness
/// requirement rather than polish, and its failure mode is silent — a user with the setting on sees
/// a translucent island and has no way to know it is Isleta ignoring them rather than macOS.
@Suite("Island style")
struct IslandStyleTests {

    @Test("automatic is exactly the pair of rules that shipped before the setting existed")
    func automaticIsTodaysBehavior() {
        #expect(
            IslandStyle.material(for: .automatic, notch: .hardware, reduceTransparency: false)
                == .opaque
        )
        #expect(
            IslandStyle.material(for: .automatic, notch: .synthesized, reduceTransparency: false)
                == .glass
        )
    }

    @Test("the three named styles mean one thing each, on both kinds of display")
    func namedStylesDoNotDependOnTheDisplay() {
        for notch in [NotchGeometry.Kind.hardware, .synthesized] {
            #expect(IslandStyle.material(for: .normal, notch: notch, reduceTransparency: false) == .opaque)
            #expect(IslandStyle.material(for: .semiGlass, notch: notch, reduceTransparency: false) == .semiGlass)
            #expect(IslandStyle.material(for: .liquidGlass, notch: notch, reduceTransparency: false) == .glass)
        }
    }

    /// §6.3. Every style, both displays, no exceptions — written as a sweep rather than as three
    /// assertions precisely because the failure this catches is a case somebody forgot.
    @Test("reduce transparency makes every style solid, on every display")
    func reduceTransparencyWins() {
        for style in IslandStyle.allCases {
            for notch in [NotchGeometry.Kind.hardware, .synthesized] {
                #expect(IslandStyle.material(for: style, notch: notch, reduceTransparency: true) == .opaque)
            }
        }
    }

    /// The substitution is a *substitution*: nothing about the stored choice changes, so turning the
    /// system setting off puts the user's style straight back. A test rather than a comment, because
    /// the tempting implementation — clearing the setting when the material resolves to opaque —
    /// looks identical from inside the app and quietly destroys the user's choice.
    @Test("it substitutes rather than clearing: the style is unchanged either side")
    func substitutionIsReversible() {
        let chosen = IslandStyle.liquidGlass
        #expect(IslandStyle.material(for: chosen, notch: .hardware, reduceTransparency: true) == .opaque)
        #expect(IslandStyle.material(for: chosen, notch: .hardware, reduceTransparency: false) == .glass)
    }

    @Test("only the opaque material avoids the custom-Shape glass trap entirely")
    func onlyTwoMaterialsTouchGlass() {
        #expect(IslandMaterial.opaque.usesGlass == false)
        #expect(IslandMaterial.semiGlass.usesGlass)
        #expect(IslandMaterial.glass.usesGlass)
    }
}
