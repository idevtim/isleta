import Foundation
import Testing

@testable import IslandActivities

/// Reaching the end of a range, and the glyph that fills on the way there.
///
/// Both are about the same keypress and they fail in opposite directions: a limit that is reported
/// too eagerly bounces the island for something the user did not do, and one reported too rarely
/// means the bounce never fires at all.
@Suite("Activity limits")
struct ActivityLimitTests {

    /// The signal has to survive the trip from the source to the island, which is the only reason it
    /// is on the protocol rather than inferred from the number.
    @Test("a HUD carries the limit it was built with")
    func hudCarriesTheLimit() {
        #expect(BuiltInActivity.systemHUD(.volume, level: 1, limit: .maximum).reachedLimit == .maximum)
        #expect(BuiltInActivity.systemHUD(.volume, level: 0, limit: .minimum).reachedLimit == .minimum)
        #expect(BuiltInActivity.systemHUD(.volume, level: 0.5).reachedLimit == nil)
    }

    /// **The whole reason the limit is decided by the source and not derived from `level`.** A mute
    /// publishes level zero and is not somebody running the volume down; an island that read the
    /// number would bounce every time anybody muted.
    @Test("a level of zero is not by itself the bottom of a range")
    func zeroIsNotAlwaysTheBottom() {
        #expect(BuiltInActivity.systemHUD(.mute, level: 0).reachedLimit == nil)
    }

    /// Nothing else in the vocabulary reports one, and the default is what keeps it that way — a
    /// conformer that has never heard of limits does not have to say so.
    @Test("everything else is never at a limit")
    func everythingElseIsNil() {
        #expect(BuiltInActivity.nowPlaying(title: "Flamenco Sketches").reachedLimit == nil)
        #expect(BuiltInActivity.welcomeBack(greeting: "Good morning").reachedLimit == nil)
        #expect(TestActivity("plain").reachedLimit == nil)
    }

    // MARK: - The glyph that fills

    /// The volume glyph carries the level as SF Symbols' variable value, so its two waves light in
    /// turn. Measured support is recorded on `ActivityContent.symbolVariableValue`; this pins that
    /// the number actually reaches the content, in every slot that draws the glyph.
    @Test("the level is drawn into the volume glyph as well as beside it")
    func levelReachesTheGlyph() {
        let hud = BuiltInActivity.systemHUD(.volume, level: 0.75)
        #expect(hud.presentations.leading.symbolVariableValue == 0.75)
        #expect(hud.presentations.compact.symbolVariableValue == 0.75)
        #expect(hud.presentations.expanded.symbolVariableValue == 0.75)
        // The trailing sliver is the bar alone and has no glyph to fill.
        #expect(hud.presentations.trailing.symbol == nil)
    }

    /// Clamped where it is read, not where it is stored — `ActivityValue.normalized`'s rule, for the
    /// same reason: CoreAudio hands back 1.0000000149 at full volume often enough to matter, and a
    /// variable value above 1 is undefined.
    @Test("the drawn fill is clamped even though the stored value is raw")
    func fillIsClamped() {
        let loud = ActivityContent(symbol: "speaker.wave.2.fill", symbolVariableValue: 1.0000000149)
        #expect(loud.symbolVariableValue == 1.0000000149)
        #expect(loud.symbolFill == 1)

        let below = ActivityContent(symbol: "speaker.wave.2.fill", symbolVariableValue: -0.2)
        #expect(below.symbolFill == 0)

        #expect(ActivityContent(symbol: "bell.fill").symbolFill == nil)
    }
}
