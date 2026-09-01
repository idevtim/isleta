import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The `mobiletimerd` parser, against the payload shapes measured on macOS 27.0.
///
/// Every fixture here is the real structure read out of the live preferences domain while starting,
/// pausing and canceling a timer — including the four idle presets that were already on the
/// machine, which is what makes the idle-versus-paused case a real test rather than a hypothetical.
@Suite("Mobile timer parsing")
struct MobileTimerStateTests {

    private let now = Date(timeIntervalSince1970: 1_787_348_000)

    private func store(_ timers: [[String: Any]]) -> [String: Any] {
        ["MTTimers": timers.map { ["$MTTimer": $0] }]
    }

    private func idle(_ id: String, duration: Double, title: String = "") -> [String: Any] {
        [
            "MTTimerID": id,
            "MTTimerState": NSNumber(value: 1),
            "MTTimerDuration": NSNumber(value: duration),
            "MTTimerFireTimerClass": "MTTimerTimeInterval",
            "MTTimerFireTime": ["$MTTimerTimeInterval": ["MTTimerTimeInterval": NSNumber(value: duration)]],
            "MTTimerTitle": title,
        ]
    }

    private func running(_ id: String, fires: Date, duration: Double = 300) -> [String: Any] {
        [
            "MTTimerID": id,
            "MTTimerState": NSNumber(value: 3),
            "MTTimerDuration": NSNumber(value: duration),
            "MTTimerFireTimerClass": "MTTimerDate",
            "MTTimerFireTime": ["$MTTimerDate": ["MTTimerTimeDate": fires]],
            "MTTimerTitle": "",
        ]
    }

    private func paused(_ id: String, remaining: Double, duration: Double = 300) -> [String: Any] {
        [
            "MTTimerID": id,
            "MTTimerState": NSNumber(value: 2),
            "MTTimerDuration": NSNumber(value: duration),
            "MTTimerFireTimerClass": "MTTimerTimeInterval",
            "MTTimerFireTime": ["$MTTimerTimeInterval": ["MTTimerTimeInterval": NSNumber(value: remaining)]],
            "MTTimerTitle": "",
        ]
    }

    // MARK: - The trap

    /// The whole reason this parser keys on `MTTimerState`. A paused timer reverts to a *relative*
    /// interval — same class, same field, same type as an idle one — so a parser that keyed on
    /// `MTTimerFireTimerClass`, which is the field that reads like the discriminator, would show
    /// every saved preset in the user's Clock as a paused countdown.
    @Test("saved presets are idle, not paused, even though they are the same shape")
    func idlePresetsAreNotPaused() {
        let raw = store([
            idle("a", duration: 300),
            idle("b", duration: 300),
            idle("c", duration: 900, title: MobileTimerState.placeholderTitle),
        ])
        #expect(MobileTimerState.timers(from: raw, now: now).isEmpty)
    }

    @Test("a paused timer carries what is left, not what it was set for")
    func pausedCarriesRemaining() throws {
        let raw = store([idle("a", duration: 300), paused("b", remaining: 295.6486, duration: 300)])
        let timers = MobileTimerState.timers(from: raw, now: now)

        #expect(timers.count == 1)
        let timer = try #require(timers.first)
        #expect(timer.state == .paused(remaining: 295.6486))
        #expect(timer.totalDuration == 300)
        #expect(timer.state.isCounting == false)
    }

    // MARK: - Running

    @Test("a running timer carries the absolute instant it fires")
    func runningCarriesFireDate() throws {
        let fires = now.addingTimeInterval(263)
        let timers = MobileTimerState.timers(from: store([running("a", fires: fires)]), now: now)

        let timer = try #require(timers.first)
        #expect(timer.state == .running(fireDate: fires))
        #expect(timer.state.isCounting)
        #expect(timer.id == ActivityID("timer.a"))
    }

    /// The date passing is the earlier and more reliable signal than `MTTimerFiredDate`, which
    /// `mobiletimerd` sets when it gets round to it — and it is the one the island is already
    /// counting against.
    @Test("a running timer whose date has passed has finished")
    func pastFireDateIsFinished() throws {
        let timers = MobileTimerState.timers(
            from: store([running("a", fires: now.addingTimeInterval(-2))]), now: now
        )
        #expect(try #require(timers.first).state == .finished)
    }

    // MARK: - Titles

    @Test("Clock's own placeholder and an empty string are both 'no name'")
    func placeholderTitlesBecomeNil() throws {
        let named = store([running("a", fires: now.addingTimeInterval(60))])
        #expect(try #require(MobileTimerState.timers(from: named, now: now).first).title == nil)

        var withPlaceholder = running("b", fires: now.addingTimeInterval(60))
        withPlaceholder["MTTimerTitle"] = MobileTimerState.placeholderTitle
        #expect(try #require(MobileTimerState.timers(from: store([withPlaceholder]), now: now).first).title == nil)

        var withName = running("c", fires: now.addingTimeInterval(60))
        withName["MTTimerTitle"] = "Pasta"
        #expect(try #require(MobileTimerState.timers(from: store([withName]), now: now).first).title == "Pasta")
    }

    // MARK: - Robustness

    /// The wrapper key and the field inside it are spelled differently — `$MTTimerDate` outside,
    /// `MTTimerTimeDate` inside — so the parser looks for the field rather than trusting either
    /// spelling. A rename of the wrapper must not silently produce "no timers running".
    @Test("the fire time is found by its field, not by the wrapper's name")
    func fireTimeFoundByField() throws {
        var odd = running("a", fires: now.addingTimeInterval(60))
        odd["MTTimerFireTime"] = ["$SomethingElse": ["MTTimerTimeDate": now.addingTimeInterval(60)]]
        #expect(try #require(MobileTimerState.timers(from: store([odd]), now: now).first).state.isCounting)
    }

    @Test("nothing readable yields nothing, rather than a wrong answer")
    func garbageYieldsNothing() {
        #expect(MobileTimerState.timers(from: nil, now: now).isEmpty)
        #expect(MobileTimerState.timers(from: "not a dictionary", now: now).isEmpty)
        #expect(MobileTimerState.timers(from: ["MTTimers": "wrong type"], now: now).isEmpty)
        #expect(MobileTimerState.timers(from: store([["MTTimerState": NSNumber(value: 3)]]), now: now).isEmpty)
    }

    /// An unknown state is treated as idle rather than guessed at: showing nothing is recoverable,
    /// and showing a countdown that is not running is not.
    @Test("a state this build has never heard of is ignored")
    func unknownStateIsIgnored() {
        var future = running("a", fires: now.addingTimeInterval(60))
        future["MTTimerState"] = NSNumber(value: 9)
        #expect(MobileTimerState.timers(from: store([future]), now: now).isEmpty)
    }

    @Test("several live timers are all reported")
    func multipleLiveTimers() {
        let raw = store([
            idle("preset", duration: 900),
            running("a", fires: now.addingTimeInterval(60)),
            paused("b", remaining: 120),
            running("c", fires: now.addingTimeInterval(3600)),
        ])
        #expect(MobileTimerState.timers(from: raw, now: now).count == 3)
    }
}
