import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A monitor with no radio behind it, so the source's own behavior is testable without hardware,
/// without pairing anything, and without the private selectors being present.
@MainActor
private final class StubBluetoothMonitor: BluetoothDeviceMonitoring {
    /// Backed by a stored property with a counting getter, because *whether the source reads this
    /// before starting* is itself a thing to assert — see `noRadio`. Reading it on the main thread
    /// is what deadlocked the app at launch.
    var isAvailable: Bool {
        get { availabilityReads += 1; return storedIsAvailable }
        set { storedIsAvailable = newValue }
    }
    var storedIsAvailable = true
    private(set) var availabilityReads = 0

    var authorization: SourceAuthorization = .granted
    var reportsBattery = true
    var isStarted = false
    private var handler: ((BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void)?

    func start(onConnect: @escaping (BluetoothDeviceConnection, BluetoothConnectionOrigin) -> Void) {
        isStarted = true
        handler = onConnect
    }

    /// The paired devices this stub can resolve, keyed by address — standing in for
    /// `IOBluetoothDevice.pairedDevices()`. Synchronous here where the real one hops a queue, which
    /// is the one thing about this path a test cannot check and hardware has to.
    var pairedByAddress: [String: BluetoothDeviceConnection] = [:]
    private(set) var resolveRequests: [String] = []

    func publishConnection(at address: String, origin: BluetoothConnectionOrigin) {
        resolveRequests.append(address)
        guard let connection = pairedByAddress[address.lowercased()] else { return }
        handler?(connection, origin)
    }

    func stop() {
        isStarted = false
        handler = nil
    }

    /// What IOBluetooth does when a device connects — including doing it three or four times.
    func fire(
        _ connection: BluetoothDeviceConnection,
        origin: BluetoothConnectionOrigin = .connected,
        times: Int = 1
    ) {
        for _ in 0..<times { handler?(connection, origin) }
    }
}

/// A route monitor with no CoreAudio behind it, so the second half of the feature is testable
/// without a Mac, a radio, or a pair of AirPods to take in and out of somebody's ears.
@MainActor
private final class StubAudioRouteMonitor: AudioRouteMonitoring {
    var isAvailable = true
    var isStarted = false
    private var handler: ((String, BluetoothConnectionOrigin) -> Void)?

    func start(onBluetoothOutput: @escaping (String, BluetoothConnectionOrigin) -> Void) {
        isStarted = true
        handler = onBluetoothOutput
    }

    func stop() {
        isStarted = false
        handler = nil
    }

    /// What CoreAudio does when the system output becomes a Bluetooth device.
    func fire(_ address: String, origin: BluetoothConnectionOrigin = .connected) {
        handler?(address, origin)
    }
}

@Suite("Bluetooth device source")
@MainActor
struct BluetoothDeviceSourceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func airPods(name: String = "AirPods Pro", address: String = "04-9d-05-6b-19-80") -> BluetoothDeviceConnection {
        BluetoothDeviceConnection(
            name: name, address: address, kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 100, single: 0))
    }

    /// The measured behavior this exists to survive: **one physical AirPods connect fires the
    /// IOBluetooth notification three or four times** on macOS 27.0 — twice or three times at the
    /// classic address within 33ms, and once more at a BLE random address. Undeduplicated that is
    /// four islands for one thing the user did.
    @Test("a burst of connects for one device announces once")
    func burstAnnouncesOnce() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        // Four callbacks 10ms apart, which is tighter than the measured burst.
        for offset in 0..<4 {
            source.announce(airPods(), now: t0.addingTimeInterval(Double(offset) * 0.01))
        }

        #expect(published.count == 1)
        #expect(published.first?.kind == .deviceConnected)
    }

    /// Two devices connecting together are two things, and the user is owed both — the dedup is
    /// per address, never a global "recently announced anything" gate.
    @Test("two devices connecting at once are two announcements")
    func twoDevicesAreTwo() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(airPods(), now: t0)
        source.announce(airPods(name: "Powerbeats Pro", address: "28-f0-33-ce-35-73"), now: t0)

        #expect(published.count == 2)
        #expect(Set(published.map(\.id.rawValue)).count == 2)
    }

    /// The window is short on purpose. Taking AirPods out, putting them back and taking them out
    /// again is one thing at four seconds and two things at twenty.
    @Test("a genuine reconnect later is announced again")
    func laterReconnectIsAnnounced() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(airPods(), now: t0)
        source.announce(airPods(), now: t0.addingTimeInterval(3))    // inside the dwell
        source.announce(airPods(), now: t0.addingTimeInterval(20))   // long after it

        #expect(published.count == 2)
    }

    /// A Mac with the radio off is a normal Mac, not a denied one. Nothing is published and
    /// `authorization` reads `.notRequired` — §10's denied-state rule says "denied" means the user
    /// could have this and doesn't, which is not the case here. Checked with the monitor reporting a
    /// refusal underneath, because the radio being absent has to win: a Mac with no Bluetooth
    /// hardware must not be told to go and grant Bluetooth in System Settings.
    @Test("no radio means the source idles rather than reporting a refusal")
    func noRadio() {
        let monitor = StubBluetoothMonitor()
        monitor.isAvailable = false
        monitor.authorization = .denied(explanation: "refused")
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        // The monitor **is** started, and that is the point. Deciding first meant reading
        // `isAvailable`, which on the real monitor calls `IOBluetoothHostController.default()` —
        // a blocking semaphore wait whose reply arrives through the main queue, so on the main
        // thread inside `applicationDidFinishLaunching` it never returns. See
        // `IOBluetoothDeviceMonitor.coordinatorQueue`. The radio question now belongs to the
        // monitor, which asks it off the main thread.
        #expect(monitor.isStarted)
        #expect(source.isRunning)
        #expect(published.isEmpty)
        #expect(source.authorization == .notRequired)
    }

    /// **The event IOBluetooth does not have.** Measured 2026-08-30: taking AirPods out of the ears
    /// never drops the link — `isConnected()` stays true and no notification fires either way — so
    /// putting them back is not a connect and the island stayed empty. What moves is the system
    /// output device, and this is the route that carries it.
    @Test("a Bluetooth device becoming the system output announces it")
    func routeChangeAnnounces() {
        let monitor = StubBluetoothMonitor()
        let route = StubAudioRouteMonitor()
        monitor.pairedByAddress = ["04-9d-05-6b-19-80": airPods()]
        let source = BluetoothDeviceSource(monitor: monitor, routeMonitor: route)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()
        #expect(route.isStarted)

        route.fire("04-9D-05-6B-19-80")

        #expect(published.count == 1)
        #expect(published.first?.kind == .deviceConnected)
    }

    /// CoreAudio spells the MAC in upper case in its UID and IOBluetooth in lower. A match that is
    /// case-sensitive resolves nothing, announces nothing, and looks exactly like the bug this whole
    /// route exists to fix.
    @Test("the address matches whatever case it arrives in")
    func addressMatchIsCaseInsensitive() {
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "04-9D-05-6B-19-80:output")
                == "04-9d-05-6b-19-80")
        // No colon, already lower — still a valid address.
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "28-f0-33-ce-35-73")
                == "28-f0-33-ce-35-73")
        // Somebody else's idea of a UID. Better to resolve nothing than to hand IOBluetooth a
        // string it will fail on.
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "BuiltInSpeakerDevice") == nil)
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "AppleUSBAudioEngine:Foo") == nil)
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "04-9D-05-6B-19:output") == nil)
        #expect(CoreAudioRouteMonitor.bluetoothAddress(fromUID: "zz-9D-05-6B-19-80:output") == nil)
    }

    /// **The two routes are one island.** A genuine connect fires IOBluetooth at `.553` and the
    /// route change at `.797` — 244 ms apart, measured — and the address-keyed window is what makes
    /// the second a repeat of the first rather than a second announcement behind it.
    @Test("a genuine connect heard on both routes announces once")
    func bothRoutesCollapseToOneAnnouncement() {
        let monitor = StubBluetoothMonitor()
        let route = StubAudioRouteMonitor()
        monitor.pairedByAddress = ["04-9d-05-6b-19-80": airPods()]
        let source = BluetoothDeviceSource(monitor: monitor, routeMonitor: route)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(airPods(), now: t0)                                    // IOBluetooth
        source.announce(airPods(), now: t0.addingTimeInterval(0.244))          // CoreAudio, after

        #expect(published.count == 1)
    }

    /// The route in effect at launch is recorded and not announced, on the same rule the connect
    /// notification's replay follows: the island's sentence is "this just arrived", and at launch
    /// that is not true of whatever the user was already listening through.
    @Test("the output device already in effect at launch is not announced")
    func routeAtLaunchIsNotAnnounced() {
        let monitor = StubBluetoothMonitor()
        let route = StubAudioRouteMonitor()
        monitor.pairedByAddress = ["04-9d-05-6b-19-80": airPods()]
        let source = BluetoothDeviceSource(monitor: monitor, routeMonitor: route)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        route.fire("04-9d-05-6b-19-80", origin: .alreadyConnectedAtStart)
        #expect(published.isEmpty)

        // And it is still an arrival when the user genuinely does it later. Measured against a live
        // `Date` rather than `t0`, because the route path carries no clock: `publishConnection`
        // reaches `announce`'s default `now`, so the fixed reference date would sit twenty-five
        // years before the entry it is being compared with.
        source.announce(airPods(), now: Date().addingTimeInterval(30))
        #expect(published.count == 1)
    }

    /// A device that is not paired, or is paired and is not audio, resolves to nothing. The route
    /// path inherits `connection(from:)`'s rejections rather than repeating them.
    @Test("an output device that resolves to nothing announces nothing")
    func unresolvableRouteIsSilent() {
        let monitor = StubBluetoothMonitor()
        let route = StubAudioRouteMonitor()
        let source = BluetoothDeviceSource(monitor: monitor, routeMonitor: route)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        route.fire("bc-89-a7-e4-f7-c9")     // a mouse, which is not in `pairedByAddress`

        #expect(monitor.resolveRequests == ["bc-89-a7-e4-f7-c9"])
        #expect(published.isEmpty)
    }

    /// Stopping must leave no CoreAudio listener behind, exactly as it leaves no IOBluetooth
    /// notification registered.
    @Test("stopping stops both routes")
    func stopStopsBothRoutes() {
        let monitor = StubBluetoothMonitor()
        let route = StubAudioRouteMonitor()
        let source = BluetoothDeviceSource(monitor: monitor, routeMonitor: route)
        source.start()
        source.stop()
        #expect(!monitor.isStarted)
        #expect(!route.isStarted)
    }

    /// The regression guard for the deadlock above, stated as the rule rather than the symptom:
    /// **`start()` must not read `isAvailable`.** A test that only checked "nothing was published"
    /// would pass with the blocking read put back, because the read hangs rather than lying.
    @Test("starting the source never asks the monitor whether the radio is there")
    func startDoesNotProbeTheRadio() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        source.start()
        #expect(monitor.availabilityReads == 0)
        #expect(monitor.isStarted)
    }

    /// The battery half can be gone while the connection half still works — an OS that drops the
    /// selectors. The device still gets its picture; the ring is what goes.
    @Test("a monitor that cannot read the battery still announces the connection")
    func connectionWithoutBattery() {
        let monitor = StubBluetoothMonitor()
        monitor.reportsBattery = false
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro, battery: .none), now: t0)

        #expect(source.reportsBattery == false)
        #expect(published.count == 1)
        #expect(published.first?.presentations.trailing.isEmpty == true)
        #expect(published.first?.presentations.leading.symbol == "airpods.pro")
    }

    /// `stop()` is the whole of teardown here — no queue, no child, no timer — so `stopAndWait()`
    /// has nothing extra to promise. Pinned because the next person to add work to `stop()` needs
    /// this to fail rather than to quietly become untrue on the `applicationWillTerminate` path.
    @Test("stopping leaves nothing behind and forgets what it announced")
    func stopIsComplete() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()
        source.announce(airPods(), now: t0)

        source.stopAndWait()
        #expect(!monitor.isStarted)
        #expect(!source.isRunning)

        // Restarted, the same device is a new announcement rather than one suppressed by a stale
        // entry in a map that outlived the observation it belonged to.
        source.start()
        source.announce(airPods(), now: t0.addingTimeInterval(1))
        #expect(published.count == 2)
    }

    /// **The bug this was written for.** Registering for connect notifications replays every device
    /// that is already connected, so launching Isleta with AirPods in your ears announced them as if
    /// they had just connected — an island on every launch, saying something untrue. It also put an
    /// animation inside `--perf-report`'s idle window, which read 0.85% against a 0.3% budget for a
    /// source that keeps no timer at all, so it looked like a performance regression rather than a
    /// correctness one.
    @Test("a device already connected at launch is not announced")
    func alreadyConnectedIsNotNews() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(airPods(), origin: .alreadyConnectedAtStart, now: t0)
        #expect(published.isEmpty)
    }

    /// But taking them out and putting them back *is* news, even for a pair that was connected at
    /// launch. The replay must suppress one announcement, not the device forever.
    @Test("a device connected at launch still announces when it genuinely reconnects")
    func reconnectAfterLaunchIsNews() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        source.announce(airPods(), origin: .alreadyConnectedAtStart, now: t0)
        source.announce(airPods(), origin: .connected, now: t0.addingTimeInterval(30))

        #expect(published.count == 1)
    }

    /// The replay is what suppresses the burst that arrives with it. A replayed device is recorded
    /// as seen, so the two or three repeats IOBluetooth fires alongside it are dropped by the same
    /// window that dedups a real burst — rather than the second repeat sneaking through as news.
    @Test("a replayed burst does not leak an announcement")
    func replayedBurstIsSilent() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        monitor.fire(airPods(), origin: .alreadyConnectedAtStart, times: 4)
        #expect(published.isEmpty)
    }

    /// Starting twice must not register two observers — the controller rebuilds on display changes.
    @Test("start is idempotent")
    func startIsIdempotent() {
        let monitor = StubBluetoothMonitor()
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        source.start()
        monitor.fire(airPods())

        #expect(published.count == 1)
    }

    /// §10's denied-state rule, for the permission 1.3.0 did not know it needed. Refused Bluetooth
    /// is not a broken source: the source still starts, still keeps no timer, and simply never
    /// hears a connection — while `authorization` carries the sentence the Sources pane shows.
    @Test("a refusal is reported rather than swallowed, and nothing else breaks")
    func refusedBluetooth() {
        let monitor = StubBluetoothMonitor()
        monitor.authorization = .denied(explanation: "Isleta cannot see Bluetooth devices connecting.")
        let source = BluetoothDeviceSource(monitor: monitor)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }

        source.start()
        #expect(source.isRunning)
        #expect(!source.authorization.isUsable)
        #expect(source.authorization == .denied(explanation: "Isleta cannot see Bluetooth devices connecting."))
        #expect(published.isEmpty)
    }

    /// The state a user sits in between launching and answering the dialog. It is not a refusal —
    /// nothing has been said no to — so it must not read as one.
    @Test("an unanswered prompt is undetermined, not denied")
    func unansweredPrompt() {
        let monitor = StubBluetoothMonitor()
        monitor.authorization = .undetermined
        let source = BluetoothDeviceSource(monitor: monitor)

        #expect(source.authorization == .undetermined)
        #expect(!source.authorization.isUsable)
    }
}
