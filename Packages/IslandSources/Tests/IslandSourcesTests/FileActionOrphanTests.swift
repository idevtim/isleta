import Darwin
import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// Which processes the conversion sweep is allowed to end.
///
/// Every one of these runs against a table of values nobody had to create by crashing an app, which
/// is the whole reason `reapable` is a pure function over `Entry`. The bug this code could have is
/// in *which* pids it picks, and that question needs no running processes to answer.
///
/// The first test is the one that matters. `NowPlayingAdapterOrphans` could rely on `p_comm ==
/// "perl"` doing most of the work; here the stranded worker and the user's own running copy of
/// Isleta are **the same executable, the same name, the same uid, and both children of launchd**.
/// The only thing that separates them is one flag on the argument vector.
@Suite("File worker orphans")
struct FileActionOrphanTests {

    private let executable = "/Applications/Isleta.app/Contents/MacOS/Isleta"
    private let uid: uid_t = 501
    private let us: Int32 = 4242

    private func entry(
        pid: Int32,
        parent: Int32 = 1,
        uid: uid_t = 501,
        arguments: [String]
    ) -> FileActionOrphans.Entry {
        FileActionOrphans.Entry(pid: pid, parentPID: parent, uid: uid, arguments: arguments)
    }

    private func reapable(_ table: [FileActionOrphans.Entry]) -> [Int32] {
        FileActionOrphans.reapable(
            from: table, executablePath: executable, currentUID: uid, currentPID: us
        )
    }

    /// **The one that must never regress.** A second copy of Isleta — the installed app running
    /// beside a development build, or simply the app itself on a machine where this sweep runs from
    /// a helper — is the same binary with the same name owned by the same user, and launchd is its
    /// parent because LaunchServices started it. Without the flag check this sweep would quit the
    /// user's app at every launch.
    @Test("an ordinary Isleta is never reaped")
    func liveApplication() {
        let table = [
            entry(pid: 900, arguments: [executable]),
            entry(pid: 901, arguments: [executable, "--verbose-logging"]),
            entry(pid: 902, arguments: [executable, "--perf-report", "60"]),
        ]
        #expect(reapable(table).isEmpty)
    }

    /// A worker belonging to a *live* Isleta has that instance's pid as its parent, never 1. So no
    /// arrangement of running copies can put a live worker in range — only one whose owner is
    /// already gone.
    @Test("a worker whose parent is still alive is never reaped")
    func liveWorker() {
        let table = [entry(pid: 910, parent: 900, arguments: [executable, FileActionWorker.flag])]
        #expect(reapable(table).isEmpty)
    }

    @Test("another user's process is never reaped")
    func otherUser() {
        let table = [entry(pid: 920, uid: 502, arguments: [executable, FileActionWorker.flag])]
        #expect(reapable(table).isEmpty)
    }

    /// A different bundle's copy of Isleta — a build in someone's Downloads, a competitor that
    /// happens to name its binary the same — is matched on the **absolute path**, so it cannot be
    /// reached. `p_comm` truncates at sixteen bytes and is only ever the cheap pre-filter.
    @Test("a worker from another copy of the app is never reaped")
    func otherBundle() {
        let table = [
            entry(
                pid: 930,
                arguments: ["/Users/someone/Downloads/Isleta.app/Contents/MacOS/Isleta", FileActionWorker.flag]
            )
        ]
        #expect(reapable(table).isEmpty)
    }

    @Test("we never reap ourselves")
    func ourselves() {
        let table = [entry(pid: us, arguments: [executable, FileActionWorker.flag])]
        #expect(reapable(table).isEmpty)
    }

    @Test("launchd itself is never reaped")
    func launchd() {
        let table = [entry(pid: 1, parent: 0, uid: 0, arguments: ["/sbin/launchd"])]
        #expect(reapable(table).isEmpty)
    }

    @Test("a genuinely stranded worker is reaped")
    func strandedWorker() {
        let table = [
            entry(pid: 940, arguments: [executable, FileActionWorker.flag]),
            entry(pid: 941, arguments: [executable]),
            entry(pid: 942, parent: 900, arguments: [executable, FileActionWorker.flag]),
        ]
        #expect(reapable(table) == [940])
    }
}

/// The wire between the parent and the worker.
///
/// Both sides are in this package and both sides are `Codable`, so the thing worth pinning is that a
/// request survives the round trip intact — a route that decoded as something else would run the
/// wrong conversion silently, which is the failure mode this whole file is written against.
@Suite("File worker protocol")
struct FileConversionProtocolTests {

    @Test("a request survives the round trip", arguments: ConversionRoute.allCases)
    func requestRoundTrip(route: ConversionRoute) throws {
        let request = FileConversionRequest(
            route: route,
            targetIdentifier: "public.jpeg",
            targetExtension: "jpg",
            inputs: ["/a/b.png", "/a/c.png"],
            outputDirectory: "/a",
            localeIdentifier: "en-GB"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(FileConversionRequest.self, from: data)
        #expect(decoded.route == route)
        #expect(decoded.inputs == request.inputs)
        #expect(decoded.outputDirectory == request.outputDirectory)
        #expect(decoded.localeIdentifier == "en-GB")
    }

    @Test("every event survives the round trip")
    func eventRoundTrip() throws {
        let events: [FileConversionEvent] = [
            .progress(0.42), .produced("/a/b.jpg"), .failed("That image could not be read"),
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(FileConversionEvent.self, from: data)
            switch (event, decoded) {
            case (.progress(let a), .progress(let b)): #expect(a == b)
            case (.produced(let a), .produced(let b)): #expect(a == b)
            case (.failed(let a), .failed(let b)): #expect(a == b)
            default: Issue.record("an event changed shape across the wire")
            }
        }
    }

    /// The flag is the identity of a worker — it is what `FileActionOrphans` matches on and what
    /// `IsletaMain` branches on before it builds anything. A rename would be silent in both places.
    @Test("the worker is recognized by its flag and by nothing else")
    func flag() {
        #expect(FileActionWorker.flag == "--file-worker")
        #expect(FileActionWorker.isWorker(["/x/Isleta", "--file-worker"]))
        #expect(!FileActionWorker.isWorker(["/x/Isleta"]))
        #expect(!FileActionWorker.isWorker(["/x/Isleta", "--perf-report", "60"]))
    }
}
