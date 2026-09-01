import Foundation

/// The arithmetic behind `Motion.speed`, in IslandKit rather than beside the tokens it scales.
///
/// Two reasons, and the second is the load-bearing one. It can be tested with no app, no window
/// server and no `Animation` to inspect — SwiftUI's `Animation` is opaque, so a test in IslandUI
/// could only compare two of them for inequality, which says nothing about direction or amount. And
/// `IslandSettings` needs `range` for the slider's bounds and its clamp, and IslandSettings does not
/// depend on IslandUI: a second copy of the range in the settings package is exactly the "two
/// spellings of one vocabulary" this codebase refuses everywhere else, and the failure would be a
/// slider that lets a user ask for a speed the tokens then clamp away without saying so.
///
/// Splitting the two numbers out means the thing that can actually be wrong is the thing that is
/// checked.
public enum MotionSpeed {

    /// Half speed to two and a half times.
    ///
    /// The floor is where the island stops reading as responsive and starts reading as syrup; the
    /// ceiling is DynamicLake's "Superman", and at 2.5 `expand`'s response is 152ms — about nine
    /// frames at 60Hz, which is still enough for a spring to be a spring rather than a jump cut.
    /// `AppearanceSettings` clamps to this on every write for the reason every range on that type
    /// exists: a range written into a `Slider` constrains a drag and says nothing about a blob
    /// hand-edited with `defaults write`.
    public static let range: ClosedRange<Double> = 0.5...2.5

    public static func clamp(_ speed: Double) -> Double {
        Swift.min(Swift.max(speed, range.lowerBound), range.upperBound)
    }

    /// A token's tuned response, at the user's speed.
    ///
    /// Division, not multiplication: speed is how fast the island moves, and response is how long it
    /// takes — so 2× speed is half the response. Getting that backwards is a slider that is
    /// labeled "faster" and is not, which nothing in a build would catch.
    ///
    /// The clamp is applied here as well as in `Motion.speed`'s observer, because this is the entry
    /// point a test uses and a function that trusted its caller would be a function whose tests
    /// prove less than they look like they do.
    public static func scale(_ response: Double, speed: Double) -> Double {
        response / clamp(speed)
    }
}
