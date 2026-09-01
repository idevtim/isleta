import Foundation

/// Decides how long to keep the island hidden after each signal that might be a space transition.
///
/// **This is the fallback.** When `SkyLightOverlaySpace` hosts the panels they are never in a
/// transition at all and none of this runs; it exists for a macOS where that private API has gone
/// away, and for that case it is what shipped before the private space existed.
///
/// Pure, and separate from `IslandController`, because every mistake made getting this right was a
/// mistake about the *order* of signals rather than about windows — and order is exactly what can be
/// tested with no display attached, no spaces, and no window server.
///
/// There is no notification that marks the end of a space transition, and the signals that exist
/// disagree about the start. Measured on macOS 27.0, one switch at a time with silence either side:
///
/// - desktop↔desktop: occlusion drop, then `activeSpaceDidChange` 779–782ms later, at the end.
/// - into fullscreen: `activeSpaceDidChange` first, then the drop ~400ms later, then a second change
///   ~1s after that.
/// - out of fullscreen: drop, `visible=true` 678ms later, then the change 779ms after that.
///
/// The one invariant across all three is that **a space change arriving after an occlusion drop was
/// the last signal of the transition**.
///
/// Until then the wait has to clear the gap to the *next* signal, and the two gaps are not the same
/// size, which is why one constant could not serve both. Measured live over many switches:
///
/// - **change → drop varies wildly: 531ms, 606ms, 1792ms.** A single isolated trial suggested
///   ~400ms and that sample simply did not contain the tail.
/// - **drop → closing change is steady at ~990ms** (971, 988, 989, 997).
///
/// A hold sized for the steady gap expires inside the wild one, which is the interrupted bounce
/// this type exists to prevent: the island restores mid-slide, is painted into the picture, and is
/// then hidden again by the drop that finally arrives.
public struct TransitionSettle: Equatable, Sendable {

    public enum Signal: Equatable, Sendable {
        /// The panel stopped being shown. A transition is certainly under way.
        case occlusionDrop
        /// The active space changed. Closes a transition when a drop came first, opens one otherwise.
        case spaceChange
        /// The panel is being shown again. Ends nothing — evidence the transition is still live.
        case stillRunning
    }

    /// How long to wait once the closing pair has been seen and there is nothing left to expect.
    public static let afterClosingChange: TimeInterval = 0.35

    /// How long to wait after an occlusion drop for the space change that closes the transition.
    /// That gap is the steady one — never more than ~1.0s measured.
    public static let afterOcclusionDrop: TimeInterval = 1.2

    /// How long to wait when a space change has arrived but no drop has confirmed a transition yet.
    /// This is the wild gap: 1792ms measured on a switch between fullscreen apps, so a hold sized
    /// like the one above expires in the middle of the slide.
    public static let whileUnconfirmed: TimeInterval = 2.5


    private var sawDrop = false
    private var sawClosingChange = false

    public init() {}

    /// Starts a fresh transition. Called when the island goes from shown to hidden.
    public mutating func begin() {
        sawDrop = false
        sawClosingChange = false
    }

    /// Records a signal and answers how long to wait for the next one before restoring.
    public mutating func delay(after signal: Signal) -> TimeInterval {
        switch signal {
        case .occlusionDrop:
            // A drop means the transition is still going, so whatever change preceded it did not
            // end it — entering fullscreen posts its change first and then runs on.
            sawDrop = true
            sawClosingChange = false
        case .spaceChange:
            sawClosingChange = sawDrop
        case .stillRunning:
            break
        }
        if sawClosingChange { return Self.afterClosingChange }
        return sawDrop ? Self.afterOcclusionDrop : Self.whileUnconfirmed
    }
}
