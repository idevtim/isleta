import Foundation

/// What kind of thing just connected, insofar as the glyph has to be chosen.
///
/// Named by *what the user calls it*, not by the Bluetooth class of device, because the only
/// consumer is a symbol and the classes do not divide the way the symbols do: AirPods, AirPods Pro
/// and AirPods Max are all `0x240418` and all "Headphones", and they are three different pictures.
///
/// The vendor's product id is what tells them apart, so the resolution lives here and not in a
/// view — the arithmetic that maps `0x2014` to a picture is testable with no Bluetooth radio, in
/// the same spirit as the geometry being AppKit-free.
public enum BluetoothDeviceKind: Equatable, Sendable, CaseIterable {

    case airPods
    case airPodsPro
    case airPodsMax
    case beats

    /// Some other set of headphones. The generic answer, and the honest one — a third-party pair is
    /// not going to have its own glyph and drawing it as AirPods would be a lie about the hardware.
    case headphones

    /// Connected, audio, but not something worn. A HomePod, a speaker, a car.
    case speaker

    /// SF Symbols only (§6.5). Never a bundled asset: the island's own rule, and the reason there
    /// is no rendered 3D AirPods model here the way iOS has one — Apple ships that art inside their
    /// own frameworks and there is no public route to it.
    public var symbol: String {
        switch self {
        case .airPods: "airpods.gen3"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .beats: "beats.powerbeatspro"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        }
    }

    /// Whether this kind reports two ear pieces rather than one battery.
    ///
    /// Asked of the *kind* rather than of the device, because the device's own answer is wrong:
    /// `isMultiBatteryDevice` reads `0` on an AirPods Pro that is reporting left and right at the
    /// same moment. See `BluetoothDeviceBattery`.
    public var hasEarPieces: Bool {
        switch self {
        case .airPods, .airPodsPro, .beats: true
        case .airPodsMax, .headphones, .speaker: false
        }
    }

    /// The kind a device's vendor and product ids describe.
    ///
    /// Apple's vendor id is `0x004C`; the product ids are the ones `system_profiler` reports and
    /// the high byte is what separates the families. Anything unrecognized falls to `.headphones`
    /// or `.speaker` by its Bluetooth major/minor class, which is always present.
    ///
    /// - Parameters:
    ///   - vendorID: the PnP vendor id, or nil when the device does not publish one.
    ///   - productID: the PnP product id, or nil.
    ///   - isWorn: whether the Bluetooth class of device says headset/headphones rather than
    ///     loudspeaker. The fallback when the ids say nothing.
    public static func resolve(vendorID: Int?, productID: Int?, isWorn: Bool) -> Self {
        guard vendorID == appleVendorID, let productID else {
            return isWorn ? .headphones : .speaker
        }
        switch productID {
        // AirPods Max, alone in the 0x200A/0x201F family and the only Apple pair that is not buds.
        case 0x200A, 0x201F: return .airPodsMax
        // Every Beats product Apple ships under its own vendor id. Listed rather than ranged:
        // the product ids are not contiguous and a range would swallow the AirPods sitting inside it.
        case 0x200B, 0x200C, 0x200D, 0x200E, 0x2010, 0x2011, 0x2012, 0x2013, 0x201D, 0x2020, 0x2021:
            return .beats
        // AirPods Pro, first and second generation.
        case 0x200F, 0x2014, 0x2024: return .airPodsPro
        // Plain AirPods, first through fourth generation.
        case 0x2002, 0x200000, 0x2003, 0x2019, 0x201B, 0x2022, 0x2023: return .airPods
        default: return isWorn ? .headphones : .speaker
        }
    }

    private static let appleVendorID = 0x004C
}

/// How much charge a connected device reports, as far as it can be believed.
///
/// ## Every field here is a measurement of a field that lies
///
/// Measured on macOS 27.0 against a connected AirPods Pro, all in the same read:
///
/// - `batteryPercentLeft` and `batteryPercentRight` answered **100 and 100**, correctly, and were
///   already populated at the instant the connect notification fired.
/// - `batteryPercentCombined` answered **0** — the field whose name says it is the summary is not
///   one, and a UI that reaches for it draws an empty ring on a full battery.
/// - `isMultiBatteryDevice` answered **0** on that same device, so the field that reads like the
///   discriminator does not discriminate. `BluetoothDeviceKind.hasEarPieces` is used instead.
/// - `batteryPercentCase` answered 93 — but it arrived **12.5 seconds** after the connect
///   notification on one connect and read 0 on the next. The island is on screen for four seconds,
///   so the case percentage is never knowable in time and is deliberately not carried here.
///
/// Zero therefore means "not reported", not "flat", which is why the fields are optional and why
/// `init` drops zeros on the floor. A device genuinely at 0% has disconnected.
public struct BluetoothDeviceBattery: Equatable, Sendable {

    public let left: Int?
    public let right: Int?

    /// A device with one battery — AirPods Max, a speaker, most third-party headphones.
    public let single: Int?

    /// - Parameters are the raw percentages as read, zeros included; this is where they are
    ///   interpreted, so there is one place that knows zero is absence.
    public init(left: Int?, right: Int?, single: Int?) {
        self.left = Self.reported(left)
        self.right = Self.reported(right)
        self.single = Self.reported(single)
    }

    private static func reported(_ raw: Int?) -> Int? {
        guard let raw, raw > 0, raw <= 100 else { return nil }
        return raw
    }

    public static let none = BluetoothDeviceBattery(left: nil, right: nil, single: nil)

    /// The one number worth drawing in a 40pt sliver, or nil when the device reported nothing.
    ///
    /// **The lower of the two ear pieces, not their mean.** A mean says 75% when the right bud is
    /// at 50 and about to die, and the number a user acts on is the one that runs out first —
    /// which is also what Apple's own menu bar shows.
    public var displayedPercent: Int? {
        let earPieces = [left, right].compactMap { $0 }
        if let lowest = earPieces.min() { return lowest }
        return single
    }

    public var isReported: Bool { displayedPercent != nil }

    /// 0...1 for the ring. Nil rather than zero when nothing was reported, so the ring can be
    /// absent instead of drawn empty — an empty ring is a claim about the battery, and a wrong one.
    public var fraction: Double? {
        displayedPercent.map { Double($0) / 100 }
    }
}

/// A device that has just connected, in the terms the island needs to draw it.
///
/// Pure, and deliberately without an `IOBluetoothDevice` in it: this is the value the source hands
/// over, so everything downstream — the activity factory, the layout, the tests — works with no
/// Bluetooth radio and no paired hardware.
public struct BluetoothDeviceConnection: Equatable, Sendable {

    /// What the user named it. Shown only in the expanded slot and in the accessibility label.
    public let name: String

    /// The MAC address, used for identity and **never displayed** — it is a stable identifier for a
    /// piece of the user's hardware, and `IslandLog`'s rule is that nothing the user did not write
    /// goes in a log that gets emailed to strangers. The same reasoning applies to drawing it.
    public let address: String

    public let kind: BluetoothDeviceKind
    public let battery: BluetoothDeviceBattery

    public init(name: String, address: String, kind: BluetoothDeviceKind, battery: BluetoothDeviceBattery) {
        self.name = name
        self.address = address
        self.kind = kind
        self.battery = battery
    }

    /// The activity id for this device.
    ///
    /// Keyed on the address so that reconnecting the same AirPods **updates** the activity that is
    /// already on stage rather than queueing a second one behind it. That is load-bearing rather
    /// than tidy: one physical AirPods connection fires the IOBluetooth notification three or four
    /// times — measured on macOS 27.0, three at the classic address and once more at a BLE random
    /// address — so a per-connection id would put four islands on screen for one pair of AirPods.
    public var activityID: ActivityID { ActivityID("builtin.deviceConnected.\(address)") }
}
