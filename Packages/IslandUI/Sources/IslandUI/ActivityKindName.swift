import IslandActivities

/// What a kind of activity is called out loud, when nothing better is available.
///
/// **This exists because a persisted raw value was being spoken.** `ActivitySwitcherView` fell back
/// to `chip.kind.rawValue` for a chip whose provider supplied no accessibility label, so VoiceOver
/// read `deviceConnected`, `welcomeBack` and `nowPlaying` as they are spelled in the enum — one
/// word, no space, and in English on a German machine. §3(b) of the localization brief says a raw
/// value is a record and not a sentence, and this is the other half of that rule: if it is not a
/// sentence then something else has to be.
///
/// The names are deliberately the surface a user would name rather than the Swift case: `power` is
/// the battery, `fileAction` is the work the shelf is doing, `systemHUD` is the system. A supplied
/// label always wins — every kind that has something specific to say (a track, a device, a
/// notification) says it through `ActivityContent.accessibilityLabel`, and this is only reached when
/// none was given.
///
/// It lives in IslandUI rather than beside the enum because it is a *rendering* decision: the same
/// argument that keeps `ActivityChip`'s symbols out of IslandActivities' vocabulary. IslandUI is
/// also the only package with a translation table to look it up in.
enum ActivityKindName {

    static func spoken(_ kind: ActivityKind) -> String {
        switch kind {
        case .nowPlaying: islandText("activityKind.nowPlaying", "Now Playing")
        case .systemHUD: islandText("activityKind.systemHUD", "System")
        case .welcomeBack: islandText("activityKind.welcomeBack", "Welcome Back")
        case .shelf: islandText("activityKind.shelf", "Shelf")
        case .timer: islandText("activityKind.timer", "Timer")
        case .deviceConnected: islandText("activityKind.deviceConnected", "Device")
        case .glance: islandText("activityKind.glance", "Glance")
        case .calendarAlert: islandText("activityKind.calendarAlert", "Event")
        case .meeting: islandText("activityKind.meeting", "Meeting")
        case .power: islandText("activityKind.power", "Battery")
        case .call: islandText("activityKind.call", "Call")
        case .fileAction: islandText("activityKind.fileAction", "File Action")
        case .focusChanged: islandText("activityKind.focusChanged", "Focus")
        case .screenSharing: islandText("activityKind.screenSharing", "Screen Sharing")
        }
    }
}
