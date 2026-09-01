import Foundation
import Testing

@testable import IslandUI

/// The pieces a list drawn inside the island shares, whichever list it is.
///
/// They were `RecentsFormat` and `RecentsScroll`, written for the notification list and borrowed by
/// the drop history. The notification list is gone; the borrower is the only caller now, and these
/// pin the behaviour that outlived the subject.
@Suite("Island lists")
struct IslandListTests {

    @Test("age reads as a glance, and never as zero")
    func ageFormatting() {
        #expect(IslandListFormat.age(seconds: 0) == "now")
        #expect(IslandListFormat.age(seconds: 59) == "now")
        #expect(IslandListFormat.age(seconds: 60) == "1m")
        #expect(IslandListFormat.age(seconds: 4 * 60) == "4m")
        #expect(IslandListFormat.age(seconds: 3600) == "1h")
        #expect(IslandListFormat.age(seconds: 86_400 * 3) == "3d")
        // A clock that has gone backwards must not print "-2m".
        #expect(IslandListFormat.age(seconds: -30) == "now")
    }
}
