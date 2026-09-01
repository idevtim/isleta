import AppKit
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The device-connected slot, and the one thing about it that fails silently.
@Suite("Device connected")
struct DeviceConnectTests {

    /// **The failure this exists to catch.** `Image(systemName:)` given a name that is not an SF
    /// Symbol renders as *nothing* — no warning, no error, no placeholder — in a 40pt sliver at the
    /// top of the screen that nobody is looking at while the tests run. So the names are checked
    /// against the installed SDK here, where AppKit is available, rather than only for emptiness in
    /// IslandActivities, which has no way to ask.
    @Test("every device kind names a symbol this SDK actually has",
          arguments: BluetoothDeviceKind.allCases)
    @MainActor
    func symbolsExist(kind: BluetoothDeviceKind) {
        #expect(
            NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil,
            "\(kind) names \(kind.symbol), which this SDK does not have — it would draw nothing"
        )
    }

    /// The chip glyph too, which is a different name and reached by a different path.
    @Test("the switcher chip's glyph exists")
    @MainActor
    func chipSymbolExists() {
        let name = ActivityKind.deviceConnected.chipSymbol
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    /// A connected device puts content in both slivers, which is what widens the resting island to
    /// its flanked form — the picture and the ring have nowhere to go otherwise. Pinned because
    /// `ActivitySlotLayout.minimumFlankWidth` is what makes a 40pt sliver drawable at all, and a
    /// kind whose flanks were empty would collapse to the unflanked width and show nothing.
    @Test("a device with a battery fills both slivers, and one without fills only the leading")
    func flanksDecideTheIslandWidth() {
        let charged = BuiltInActivity.deviceConnected(BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 100, single: 0)))
        #expect(!charged.presentations.leading.isEmpty)
        #expect(!charged.presentations.trailing.isEmpty)

        let silent = BuiltInActivity.deviceConnected(BluetoothDeviceConnection(
            name: "Studio Buds", address: "aa-bb-cc-dd-ee-ff", kind: .headphones, battery: .none))
        #expect(!silent.presentations.leading.isEmpty)
        #expect(silent.presentations.trailing.isEmpty)
    }

    /// The battery is a `.fraction`, which is deliberately *not* time-dependent — so a connected
    /// device runs no display link. That is the difference between this kind and the timer, and it
    /// is what keeps a four-second island off §9's animating budget for the whole of its life.
    @Test("a connected device needs no clock")
    func needsNoClock() {
        let activity = BuiltInActivity.deviceConnected(BluetoothDeviceConnection(
            name: "AirPods Pro", address: "04-9d-05-6b-19-80", kind: .airPodsPro,
            battery: BluetoothDeviceBattery(left: 100, right: 100, single: 0)))
        let stage = ActivityStage(primary: activity, primaryFlank: ActivityKind.deviceConnected.flankAffinity)
        let layout = ActivitySlotLayout.resolve(
            bodySize: CGSize(width: 265, height: 32), cutoutSize: CGSize(width: 185, height: 32))

        #expect(layout.affordsFlanks)
        #expect(!layout.needsClock(for: .rest, in: stage))
        #expect(!layout.needsClock(for: .expanded, in: stage))
    }
}
