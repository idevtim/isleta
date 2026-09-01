import Darwin
import Foundation
import Testing

@testable import IslandSources

/// The launch-time sweep for helpers a crashed run left behind.
///
/// Every test here is about something the sweep must **not** kill. That balance is deliberate: the
/// feature's whole risk is in over-matching, and `NowPlayingAdapterReader` carries a standing
/// warning against "fixing" the orphan problem by killing every `perl` at launch. The one positive
/// case is easy and the six negative ones are the specification.
@Suite("Now Playing — stranded helper sweep")
struct NowPlayingAdapterOrphanTests {

    private static let perl = "/usr/bin/perl"
    private static let script = "/Applications/Isleta.app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
    private static let framework = "/Applications/Isleta.app/Contents/Frameworks/MediaRemoteAdapter.framework"
    private static let us: uid_t = 501
    private static let ourPID: Int32 = 4242

    private static func entry(
        pid: Int32,
        parent: Int32 = 1,
        uid: uid_t = us,
        arguments: [String]? = nil
    ) -> NowPlayingAdapterOrphans.Entry {
        NowPlayingAdapterOrphans.Entry(
            pid: pid,
            parentPID: parent,
            uid: uid,
            arguments: arguments ?? [perl, script, framework, "stream", "--no-artwork", "--micros"]
        )
    }

    private static func reapable(
        _ table: [NowPlayingAdapterOrphans.Entry]
    ) -> [Int32] {
        NowPlayingAdapterOrphans.reapable(
            from: table,
            scriptPath: script,
            perlPath: perl,
            currentUID: us,
            currentPID: ourPID
        )
    }

    // MARK: - What it collects

    @Test("a helper running our script whose parent is launchd is ours to clear")
    func collectsOurOrphan() {
        #expect(Self.reapable([Self.entry(pid: 900)]) == [900])
    }

    /// The artwork loader's one-shot `get` is equally ours and equally dead. Requiring the `stream`
    /// subcommand would read as tighter and would simply leave a class of orphan uncollected.
    @Test("a stranded one-shot get counts too, not only the stream")
    func collectsOneShots() {
        let get = Self.entry(pid: 901, arguments: [Self.perl, Self.script, Self.framework, "get"])
        #expect(Self.reapable([get]) == [901])
    }

    // MARK: - What it must never touch

    /// The load-bearing condition. A helper belonging to a *running* Isleta has that instance's pid
    /// as its parent, never 1 — so no arrangement of live instances can put a live helper in range.
    /// Without this the sweep kills the music of whichever copy is already running.
    @Test("a helper whose parent is a live process is not touched, whatever else matches")
    func ignoresLiveChildren() {
        let live = Self.entry(pid: 902, parent: 4242)
        let liveOfAnother = Self.entry(pid: 903, parent: 777)
        #expect(Self.reapable([live, liveOfAnother]).isEmpty)
    }

    /// `ungive/mediaremote-adapter` is vendored by other notch apps. Matching the file name, or the
    /// subpath, would reach into a competitor's stranded helpers; matching the absolute path inside
    /// our own bundle cannot.
    @Test("another app's copy of the same adapter is not ours, despite the identical file name")
    func ignoresAnotherAppsAdapter() {
        let theirs = Self.entry(pid: 904, arguments: [
            Self.perl,
            "/Applications/SomeOtherNotchApp.app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl",
            "/Applications/SomeOtherNotchApp.app/Contents/Frameworks/MediaRemoteAdapter.framework",
            "stream",
        ])
        #expect(Self.reapable([theirs]).isEmpty)
    }

    /// A different install of *Isleta* — a development build beside the installed one — is also not
    /// ours. Each bundle sweeps only what it could itself have spawned.
    @Test("a different Isleta bundle's helper is left to that bundle")
    func ignoresAnotherBundleOfOurs() {
        let debugBuild = Self.entry(pid: 905, arguments: [
            Self.perl,
            "/Users/someone/Sites/isleta-app/.build/xcode/Build/Products/Debug/Isleta.app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl",
            Self.framework,
            "stream",
        ])
        #expect(Self.reapable([debugBuild]).isEmpty)
    }

    @Test("another user's process is not signalled, rather than signalled and refused")
    func ignoresOtherUsers() {
        #expect(Self.reapable([Self.entry(pid: 906, uid: 502)]).isEmpty)
    }

    /// A process that merely *mentions* the path — a grep, a tail, an editor — is not a helper.
    /// `argv[0]` is what says this is the interpreter we spawn rather than something reading about
    /// it.
    @Test("a process that mentions the script without being it is not a helper")
    func ignoresMentions() {
        let grep = Self.entry(pid: 907, arguments: ["/usr/bin/grep", Self.script])
        #expect(Self.reapable([grep]).isEmpty)
    }

    /// Paranoia that costs nothing: the sweep runs inside the process it is sweeping for.
    @Test("the sweeping process and launchd itself are never candidates")
    func ignoresSelfAndLaunchd() {
        let ourselves = Self.entry(pid: Self.ourPID)
        let launchd = Self.entry(pid: 1)
        #expect(Self.reapable([ourselves, launchd]).isEmpty)
    }

    @Test("a mixed table yields exactly the orphans and nothing else")
    func picksOnlyOrphansFromAMixedTable() {
        let table = [
            Self.entry(pid: 900),
            Self.entry(pid: 902, parent: 4242),
            Self.entry(pid: 906, uid: 502),
            Self.entry(pid: 908),
        ]
        #expect(Self.reapable(table) == [900, 908])
    }

    // MARK: - Decoding KERN_PROCARGS2

    /// The blob's layout is `argc`, the executable path, **an unspecified run of NUL padding**, then
    /// `argc` NUL-terminated arguments. The padding is what catches people: splitting on NUL and
    /// taking the first `argc` fields yields empty strings or real ones depending purely on how the
    /// kernel aligned that executable's path, so it works on some processes and not others.
    private static func blob(executable: String, arguments: [String], padding: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var argc = Int32(arguments.count)
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(executable.utf8))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: max(1, padding)))
        for argument in arguments {
            bytes.append(contentsOf: Array(argument.utf8))
            bytes.append(0)
        }
        return bytes
    }

    @Test("the argument vector survives however much padding follows the executable path")
    func parsesAcrossPadding() {
        for padding in [1, 2, 5, 8, 16] {
            let bytes = Self.blob(
                executable: Self.perl,
                arguments: [Self.perl, Self.script, "stream"],
                padding: padding
            )
            #expect(
                NowPlayingAdapterOrphans.parseProcArgs(bytes) == [Self.perl, Self.script, "stream"],
                "padding of \(padding) bytes"
            )
        }
    }

    @Test("a truncated blob decodes to nothing rather than to a short vector")
    func refusesTruncatedBlobs() {
        let full = Self.blob(executable: Self.perl, arguments: [Self.perl, Self.script], padding: 4)
        #expect(NowPlayingAdapterOrphans.parseProcArgs(Array(full.dropLast(4))) == nil)
        #expect(NowPlayingAdapterOrphans.parseProcArgs([]) == nil)
        #expect(NowPlayingAdapterOrphans.parseProcArgs([1, 2]) == nil)
    }

    // MARK: - Against the live kernel

    /// The pure rule above is only worth as much as the table it is handed, so this checks the
    /// reading half against a process that certainly exists: this one.
    @Test("the process table reader finds real processes and decodes their arguments")
    func readsTheLiveProcessTable() throws {
        let arguments = try #require(NowPlayingAdapterOrphans.arguments(ofPID: getpid()))
        #expect(!arguments.isEmpty)
        // argv[0] of the test runner is a path to an executable, whatever the runner is called.
        #expect(arguments[0].hasPrefix("/"))
    }

    /// The sweep on a machine with no stranded helpers must do nothing at all — including on the
    /// developer machine this runs on, where a real Isleta may well be running with a real helper
    /// whose parent is that Isleta.
    @Test("a sweep for a bundle that never ran signals nothing")
    func sweepingForAnAbsentBundleIsANoOp() {
        let reaped = NowPlayingAdapterOrphans.sweep(
            scriptPath: "/nonexistent/Isleta.app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
        )
        #expect(reaped.isEmpty)
    }
}
