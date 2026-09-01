import CoreGraphics
import Testing

@testable import IslandUI

/// When the island casts a shadow, and when it must not.
///
/// "Cast a shadow" is a setting about the *open* island. At rest the island is the cutout, and a
/// shadow there falls on the bezel around a hole — reported from hardware as a halo on a closed
/// island. So the setting arms the shadow and the island's own height decides whether any of it is
/// drawn.
@Suite("The island's shadow")
struct IslandShadowTests {

    /// A 14" MacBook Pro's cutout, which is what the island is at rest.
    static let resting: CGFloat = 32
    static let peek: CGFloat = 40
    static let open: CGFloat = 200

    private func presence(_ height: CGFloat, showsShadow: Bool = true) -> Double {
        IslandMaterialView.shadowPresence(
            showsShadow: showsShadow, height: height, restingHeight: Self.resting
        )
    }

    @Test("a closed island casts nothing, even with the setting on")
    func restCastsNothing() {
        #expect(presence(Self.resting) == 0)
    }

    @Test("a peek casts nothing either — it is the closed island wearing a larger shape")
    func peekCastsNothing() {
        // A peek is an invitation to click, never the click's result. The same rule the glass tip
        // follows, for the same reason: the invitation must not look like a different island.
        #expect(presence(Self.peek) == 0)
    }

    @Test("an open island casts the full shadow")
    func openCastsFully() {
        #expect(presence(Self.open) == 1)
    }

    @Test("the shadow arrives over the opening rather than switching on part-way through it")
    func theShadowRampsIn() {
        // The height handed in is the *animated* one, so this plays on the island's own spring — a
        // step would be a second animation on a different clock, which §6.1 exists to stop.
        var previous = 0.0
        for height in stride(from: Double(Self.resting), through: Double(Self.open), by: 2) {
            let value = presence(CGFloat(height))
            #expect(value >= previous, "the shadow shrank while the island grew, at \(height)pt")
            #expect(value <= 1)
            previous = value
        }
    }

    @Test("the setting off means no shadow at any height")
    func theSettingStillWins() {
        for height in [Self.resting, Self.peek, 140, Self.open] {
            #expect(presence(height, showsShadow: false) == 0)
        }
    }

    @Test("the glass and the shadow arrive together")
    func oneRampForBoth() {
        // By value rather than by coincidence: both are asking whether the island has grown enough
        // that what it draws outside the closed shape belongs on screen. Two ramps would show up as
        // the shadow appearing before the material it belongs to.
        for height in stride(from: CGFloat(0), through: 400, by: 4) {
            #expect(
                IslandMaterialView.openPresence(inHeight: height, restingHeight: Self.resting)
                    == SemiGlassUnderlay.fadePresence(inHeight: height, restingHeight: Self.resting)
            )
        }
    }

    @Test("a synthesized island's own resting height is what counts, not a constant")
    func theRestingHeightIsTheScreens() {
        // A cutout is a property of the display; a synthesized island is whatever `NotchResolver`
        // made up for that screen. A hardcoded 32 would cast a shadow around a closed island the
        // moment somebody plugged in a display with a smaller one.
        #expect(
            IslandMaterialView.shadowPresence(showsShadow: true, height: 48, restingHeight: 48) == 0
        )
        #expect(
            IslandMaterialView.shadowPresence(showsShadow: true, height: 48, restingHeight: 20) > 0
        )
    }
}
