import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A monitor with no IOKit behind it, so the source is testable on a machine that is plugged in and
/// full — which is every machine a test runs on.
@MainActor
private final class StubPowerMonitor: PowerMonitoring {
    var isAvailable = true
    var current = PowerState(isPresent: true, isPluggedIn: true, percent: 100, estimate: .notApplicable)
    private(set) var isStarted = false
    private var handler: (@MainActor (PowerState) -> Void)?

    func read() -> PowerState { current }

    func start(_ onChange: @escaping @MainActor (PowerState) -> Void) {
        isStarted = true
        handler = onChange
    }

    func stop() {
        isStarted = false
        handler = nil
    }

    func fire(_ state: PowerState) {
        current = state
        handler?(state)
    }
}

@Suite("Power source")
@MainActor
struct PowerSourceTests {

    private func onBattery(_ percent: Int) -> PowerState {
        PowerState(isPresent: true, isPluggedIn: false, percent: percent, estimate: .remaining(3600))
    }

    @Test("the state at launch is a baseline, not an announcement")
    func launchIsSilent() {
        let monitor = StubPowerMonitor()
        let source = PowerSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        #expect(published.isEmpty)
        #expect(monitor.isStarted)
    }

    @Test("pulling the charger publishes one power activity")
    func unplugPublishes() {
        let monitor = StubPowerMonitor()
        let source = PowerSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        monitor.fire(onBattery(96))
        #expect(published.count == 1)
        #expect(published.first?.kind == .power)
        #expect(source.announcementCount == 1)
    }

    /// A Mac with no battery: nothing starts, nothing publishes, and the source is still
    /// `.notRequired` rather than denied — nobody is refusing a Studio anything.
    @Test("a machine with no battery starts nothing")
    func noBatteryStartsNothing() {
        let monitor = StubPowerMonitor()
        monitor.isAvailable = false
        let source = PowerSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        #expect(monitor.isStarted == false)
        #expect(published.isEmpty)
        #expect(source.authorization == .notRequired)
        #expect(source.hasBattery == false)
    }

    /// §9's idle budget is measured with sources running, so "stopped" has to mean the monitor was
    /// told — and switching the source off and on again must not announce a change nobody watched
    /// happen.
    @Test("stop releases the monitor and rearms the baseline")
    func stopReleasesAndRearms() {
        let monitor = StubPowerMonitor()
        let source = PowerSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        source.stop()
        #expect(monitor.isStarted == false)

        monitor.current = onBattery(9)
        source.start()
        #expect(published.isEmpty)
        #expect(monitor.isStarted)
    }

    @Test("start is idempotent")
    func startIsIdempotent() {
        let monitor = StubPowerMonitor()
        let source = PowerSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        source.start()
        monitor.fire(onBattery(96))
        #expect(published.count == 1)
    }

    /// The monitor for a Mac with no battery is a conformance rather than a branch, the same shape
    /// as `UnavailableBluetoothMonitor` — so this is the shipped denied-equivalent path.
    @Test("the unavailable monitor observes nothing and says so")
    func unavailableMonitor() {
        let monitor = UnavailablePowerMonitor()
        #expect(monitor.isAvailable == false)
        #expect(monitor.read().isPresent == false)
        let source = PowerSource(monitor: monitor)
        source.start()
        source.stopAndWait()
        #expect(source.announcementCount == 0)
    }
}
