import CoreGraphics
import Foundation

/// Whether the login session's screen is locked.
///
/// This exists because a locked screen makes every window-server probe lie, and the lie looks
/// exactly like the bug those probes were written to catch.
///
/// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` is alpha-aware and system-wide, which is
/// what makes `PassThroughSelfTest` a real test rather than an assertion. But while the screen is
/// locked the window server puts a full-display shield window over everything, so *every* pixel
/// resolves to it — and a probe asking "does the window server route the notch pixel to Isleta?"
/// correctly answers no.
///
/// The shield measures at **layer 2004** (macOS 27.0 26A5421a, 2026-08-25). This comment said
/// 2147483646 for a year, that number was never measured, and the probe notes quoted it from here
/// as though it had been. What makes the real number worth carrying is that it is
/// *low*: windows at 2147483647 are composited **below** it, so the shield does not win on level,
/// and no level beats it. `--click-test` then reports "the island paints a flank it will
/// not accept a click on" and `--shelf-test` reports the drop target is unreachable, neither of
/// which is true, and both of which are indistinguishable from the real defect.
///
/// It has cost three separate work sessions on this project. A self-test that cannot tell the
/// difference between "broken" and "cannot be measured right now" is worse than one that declines to
/// run, because a false failure trains people to ignore the true one.
enum ScreenLock {

    /// `CGSessionCopyCurrentDictionary` is public API; `CGSSessionScreenIsLocked` is an undocumented
    /// key within it. Absent rather than false when unlocked, so this reads it as optional and
    /// treats "no key" as unlocked — the safe direction, because a wrong `false` merely lets a probe
    /// run and report honestly, while a wrong `true` would silently skip a real test.
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Phrased as the reason a check did not run, for report output.
    static let explanation = """
        not run — the screen is locked, so the window server's shield owns every pixel and any \
        probe asking who owns one correctly answers "not Isleta"
        """
}
