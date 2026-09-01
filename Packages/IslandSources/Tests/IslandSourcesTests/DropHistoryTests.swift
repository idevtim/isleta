import Foundation
import Testing
@testable import IslandSources

/// The four answers to "where is that file now".
///
/// Every one of them is exercised as arithmetic over four facts, which is the whole reason
/// `DropHistoryResolver.state(bookmarkResolved:...)` is a `static` function taking them rather than
/// a method that goes and gets them. Two of the four branches cannot be reached any other way: the
/// unmounted-volume answer needs an external disk to be unplugged mid-test, and the renamed-in-place
/// answer needs a bookmark that reports `isStale` — which is a property of the filesystem's own
/// bookkeeping and not something a test can arrange.
@Suite("Drop history file states")
struct DropHistoryFileStateTests {

    private let mounted = ["/", "/System/Volumes/Data", "/Volumes/Backup"]

    @Test("A bookmark resolving to the recorded path is `here`")
    func resolvesInPlace() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: URL(fileURLWithPath: "/Users/someone/Pictures/holiday.jpg"),
            renewedBookmark: nil,
            recordedPath: "/Users/someone/Pictures/holiday.jpg",
            existsAtRecordedPath: true,
            mountedVolumePaths: mounted
        )
        #expect(state == .here(URL(fileURLWithPath: "/Users/someone/Pictures/holiday.jpg")))
    }

    /// **The trap CLAUDE.md names.** A rename in place resolves *correctly, to the new name*, and
    /// reports `isStale` — so the only honest reading of that flag is "remake this bookmark", and
    /// the entry follows the file. A version that read it as death would mark every file the user
    /// has since tidied up as missing while holding a URL that works.
    @Test("A rename in place is a move, not a death, and carries the renewed bookmark")
    func renameInPlaceFollows() {
        let renewed = Data([0xCA, 0xFE])
        let state = DropHistoryResolver.state(
            bookmarkResolved: URL(fileURLWithPath: "/Users/someone/Pictures/receipt.jpg"),
            renewedBookmark: renewed,
            recordedPath: "/Users/someone/Pictures/holiday.jpg",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(state == .moved(URL(fileURLWithPath: "/Users/someone/Pictures/receipt.jpg"), renewedBookmark: renewed))
        #expect(state.url?.lastPathComponent == "receipt.jpg")
        #expect(state.explanation == nil)
        #expect(state.mayReturn)
    }

    @Test("A move to another folder is the same answer")
    func moveFollows() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: URL(fileURLWithPath: "/Users/someone/Archive/holiday.jpg"),
            renewedBookmark: nil,
            recordedPath: "/Users/someone/Pictures/holiday.jpg",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(state == .moved(URL(fileURLWithPath: "/Users/someone/Archive/holiday.jpg"), renewedBookmark: nil))
    }

    @Test("A deleted file on a mounted volume is missing, and says so")
    func deletedIsMissing() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: nil,
            renewedBookmark: nil,
            recordedPath: "/Users/someone/Pictures/holiday.jpg",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(state == .missing)
        #expect(state.explanation == "That file has been deleted")
        #expect(!state.mayReturn)
        #expect(state.url == nil)
    }

    /// The one the two-answer version gets actively wrong: identical at the filesystem to a
    /// deletion, and a completely different thing to tell somebody about their own disk.
    @Test("A file on an unmounted volume is not deleted, and names the disk")
    func unmountedVolumeIsNotDeath() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: nil,
            renewedBookmark: nil,
            recordedPath: "/Volumes/Field Recordings/interview.wav",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(state == .volumeUnavailable(volumeName: "Field Recordings"))
        #expect(state.explanation == "Field Recordings isn't connected")
        // The fact is about a cable rather than about the file, so the row keeps offering to act.
        #expect(state.mayReturn)
    }

    @Test("The same file with its disk plugged back in is missing only if it really is")
    func mountedVolumeIsJudgedNormally() {
        let onBackup = DropHistoryResolver.state(
            bookmarkResolved: nil,
            renewedBookmark: nil,
            recordedPath: "/Volumes/Backup/old.mov",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(onBackup == .missing)
    }

    /// The `/Volumes/Backup` vs `/Volumes/Backup2` case. A string-prefix test answers "mounted" for
    /// the second when only the first is attached, which turns a disk that is away into a file that
    /// has been deleted.
    @Test("A volume whose name is a prefix of another does not match it")
    func volumePrefixesAreComponentWise() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: nil,
            renewedBookmark: nil,
            recordedPath: "/Volumes/Backup2/old.mov",
            existsAtRecordedPath: false,
            mountedVolumePaths: mounted
        )
        #expect(state == .volumeUnavailable(volumeName: "Backup2"))
    }

    /// A record written before bookmarks worked for it, whose path is still a file. Worth `here`:
    /// the caller renews the bookmark from the URL it is handed, which is what stops the entry dying
    /// at the next rename.
    @Test("No bookmark and a live path is `here`")
    func pathOnlyStillResolves() {
        let state = DropHistoryResolver.state(
            bookmarkResolved: nil,
            renewedBookmark: nil,
            recordedPath: "/Users/someone/Pictures/holiday.jpg",
            existsAtRecordedPath: true,
            mountedVolumePaths: mounted
        )
        #expect(state == .here(URL(fileURLWithPath: "/Users/someone/Pictures/holiday.jpg")))
    }

    /// The boot volume is in the mounted list, so nothing in the user's home ever reaches the
    /// unmounted branch — the rule is structural rather than a `/Volumes` special case.
    @Test("Nothing under a mounted volume is ever reported as an absent disk")
    func homeIsNeverAnAbsentDisk() {
        #expect(
            DropHistoryResolver.unmountedVolumeName(
                forPath: "/Users/someone/Documents/x.txt", mountedVolumePaths: mounted
            ) == nil
        )
        #expect(
            DropHistoryResolver.unmountedVolumeName(
                forPath: "/Volumes/Backup/x.txt", mountedVolumePaths: mounted
            ) == nil
        )
    }

    /// The live resolver against the real filesystem, on the one path every Mac has. It exercises
    /// the two disk reads rather than the rule, which is what the rest of this suite is for.
    @Test("The live resolver finds a file that is there and does not find one that is not")
    func liveResolverAgreesWithTheDisk() throws {
        let resolver = DropHistoryResolver()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("drop-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)

        let bookmark = DropHistoryResolver.bookmark(for: file)
        #expect(bookmark != nil, "an unsandboxed process can make a security-scoped bookmark")

        // Compared standardized rather than by case, because the temporary directory reaches this
        // process as `/var/…` and comes back out of a bookmark as `/private/var/…` — the same file
        // by two names, which is exactly what `standardizedFileURL` is for and exactly the kind of
        // difference `.here` versus `.moved` must not be decided by.
        let found = resolver.state(path: file.path, bookmark: bookmark)
        #expect(found.url?.standardizedFileURL == file.standardizedFileURL)
        #expect(found.mayReturn)
        #expect(found.explanation == nil)

        try FileManager.default.removeItem(at: file)
        #expect(resolver.state(path: file.path, bookmark: bookmark) == .missing)
    }
}
