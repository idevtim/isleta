import Foundation

/// What CoreLocation is allowing.
///
/// Its own enum rather than `CLAuthorizationStatus`, and one case of that enum is missing on purpose.
///
/// **`.authorizedWhenInUse` does not exist on macOS.** `CLLocationManager.h:73` marks
/// `kCLAuthorizationStatusAuthorizedWhenInUse` as `API_AVAILABLE(ios(8.0))
/// API_UNAVAILABLE(macos)`, and Swift refuses to compile a comparison against it here. After
/// granting a *when-in-use* request the status a Mac reports is **`.authorizedAlways` (raw 3)**. So
/// any code gating on when-in-use is dead on this platform, and it is exactly the case a person
/// writing this from memory adds first.
public enum LocationAccess: Equatable, Sendable {

    case granted
    case notDetermined
    case denied
    case restricted

    public var isUsable: Bool { self == .granted }
}
