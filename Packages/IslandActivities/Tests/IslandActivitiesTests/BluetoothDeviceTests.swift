import Foundation
import Testing

@testable import IslandActivities

/// The arithmetic that turns a Bluetooth device into a picture and a number.
///
/// Pure, so it runs with no radio and no paired hardware — which is the point: every value here
/// was read off a real AirPods Pro on macOS 27.0, and pinning them in a test is what stops the
/// next person "fixing" the fields that lie.
@Suite("Bluetooth devices")
struct BluetoothDeviceTests {

    /// The product ids are the ones `system_profiler SPBluetoothDataType` reports on this machine.
    /// They matter because the *class* of device does not separate these: AirPods, AirPods Pro and
    /// AirPods Max are all `0x240418`, all "Headphones", and three different pictures.
    @Test("Apple's product ids pick the right picture", arguments: [
        (0x2014, BluetoothDeviceKind.airPodsPro),   // the pair this was measured against
        (0x2002, BluetoothDeviceKind.airPods),
        (0x200A, BluetoothDeviceKind.airPodsMax),
        (0x200B, BluetoothDeviceKind.beats),        // Powerbeats Pro
        (0x201D, BluetoothDeviceKind.beats),        // Powerbeats Pro 2
    ])
    func appleProductIDs(productID: Int, expected: BluetoothDeviceKind) {
        #expect(BluetoothDeviceKind.resolve(vendorID: 0x004C, productID: productID, isWorn: true) == expected)
    }

    /// A third-party pair gets the generic glyph rather than someone else's product. Drawing an
    /// unknown vendor's headphones as AirPods would be a lie about the hardware, and the user can
    /// see the hardware.
    @Test("an unknown vendor falls back to what the Bluetooth class knows")
    func unknownVendor() {
        #expect(BluetoothDeviceKind.resolve(vendorID: 0x1234, productID: 0x2014, isWorn: true) == .headphones)
        #expect(BluetoothDeviceKind.resolve(vendorID: nil, productID: nil, isWorn: true) == .headphones)
        #expect(BluetoothDeviceKind.resolve(vendorID: nil, productID: nil, isWorn: false) == .speaker)
        // Apple's vendor id with a product id from no family we know: still Apple, still unknown.
        #expect(BluetoothDeviceKind.resolve(vendorID: 0x004C, productID: 0x9999, isWorn: false) == .speaker)
    }

    /// **Measured on macOS 27.0, all in one read from a connected AirPods Pro:** left 100, right
    /// 100, combined 0, isMultiBatteryDevice 0. The two fields whose names promise a summary and a
    /// discriminator are both zero on a device that is plainly reporting two full ear pieces, so
    /// neither is read — this pins the interpretation that replaced them.
    @Test("zero means not reported, because the fields that summarise are zero on a full battery")
    func zeroIsAbsence() {
        let airPods = BluetoothDeviceBattery(left: 100, right: 100, single: 0)
        #expect(airPods.displayedPercent == 100)
        #expect(airPods.fraction == 1)

        // Nothing reported at all — the case a third-party pair lands in, and the one that must
        // draw no ring rather than an empty one.
        #expect(BluetoothDeviceBattery(left: 0, right: 0, single: 0).displayedPercent == nil)
        #expect(BluetoothDeviceBattery(left: 0, right: 0, single: 0).fraction == nil)
        #expect(BluetoothDeviceBattery.none.isReported == false)

        // A single-battery device — AirPods Max, a speaker — reports through `single` alone.
        #expect(BluetoothDeviceBattery(left: 0, right: 0, single: 42).displayedPercent == 42)

        // Out of range is absence too, not a clamp: a percentage above 100 is a field that is not
        // holding a percentage, and drawing it as full would hide that.
        #expect(BluetoothDeviceBattery(left: 0, right: 0, single: 255).displayedPercent == nil)
    }

    /// The lower ear piece, never the mean. A mean says 75% when the right bud is at 50 and about
    /// to cut out mid-sentence, and the number the user acts on is the one that runs out first.
    @Test("the ring shows the ear piece that dies first")
    func lowerEarPieceWins() {
        #expect(BluetoothDeviceBattery(left: 100, right: 50, single: 0).displayedPercent == 50)
        #expect(BluetoothDeviceBattery(left: 50, right: 100, single: 0).displayedPercent == 50)
        // One bud out of the case and reporting, the other still in it and not: the one answer
        // there is, rather than nothing.
        #expect(BluetoothDeviceBattery(left: 0, right: 88, single: 0).displayedPercent == 88)
    }

    /// `isMultiBatteryDevice` reads 0 on an AirPods Pro, so the question is asked of the kind.
    @Test("ear pieces are a property of the kind, because the device's own answer is wrong")
    func earPiecesComeFromTheKind() {
        #expect(BluetoothDeviceKind.airPodsPro.hasEarPieces)
        #expect(BluetoothDeviceKind.beats.hasEarPieces)
        #expect(!BluetoothDeviceKind.airPodsMax.hasEarPieces)
        #expect(!BluetoothDeviceKind.speaker.hasEarPieces)
    }

    /// Every kind names a symbol, and none of them names a bundled asset — §6.5 allows SF Pro and
    /// SF Symbols only. A name that is not an SF Symbol renders as nothing at all, in a 40pt sliver
    /// nobody is looking at during a test.
    @Test("every device kind names a non-empty SF Symbol", arguments: BluetoothDeviceKind.allCases)
    func everyKindHasASymbol(kind: BluetoothDeviceKind) {
        #expect(!kind.symbol.isEmpty)
    }
}
