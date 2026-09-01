import Foundation

/// The pages of the first-run flow, in order.
///
/// An enum with an ordering rather than an index into an array of views, for the same reason
/// `SettingsSection` is one: three separate things have to agree about what exists — the page, the
/// dots under it, and the two buttons that move between them — and a raw `Int` lets them disagree
/// the day a page is inserted in the middle.
///
/// ## Why there is a first run at all
///
/// Isleta is invisible until the pointer crosses the notch, has no Dock icon, and its one genuinely
/// gated feature needs a permission the user has to grant in another application. Before this flow,
/// every one of those facts was discoverable only by opening Settings and reading the Sources pane —
/// which a person has no reason to do, because nothing on screen has told them Isleta is running.
/// The result was an app that appeared not to show notifications and gave the user no way to find
/// out why.
///
/// ## What it deliberately is not
///
/// It is not a permission wall. Every page can be left with Continue, and closing the window at any
/// point counts as finished — see `OnboardingLedger`. §10's rule is that a prompt comes from a moment
/// the user chose, and a flow that will not let go until they choose it is the same nagging in a
/// nicer typeface.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {

    /// What Isleta is, before it asks for anything.
    case welcome

    /// Accessibility, for the media keys and the volume and brightness HUDs.
    ///
    /// **First of the five, and it was last.** The original order put it at the end on the argument
    /// that it is the only one whose dialog sends the user out of Isleta into System Settings to
    /// finish, so it is the likeliest place to abandon the flow — and abandoning it there costs
    /// nothing, where abandoning it first costs the four pages behind it.
    ///
    /// That reasoning is sound and it was outweighed. The HUDs are the most *visible* thing Isleta
    /// does — they happen every time the user touches a volume or brightness key, on a surface they
    /// are already looking at — so this is the permission whose payoff a first-time user recognises
    /// fastest, and asking for it while attention is highest is worth more than protecting the four
    /// behind it. `Skip` is what makes the cost survivable: the page is leaveable in one click and
    /// the flow continues.
    ///
    /// Anyone moving it back: the argument above is the one to answer, not the ordering.
    case accessibility

    /// Automation, so the island can name the track that is *already* playing rather than waiting
    /// for the next play, pause or skip.
    case music

    /// Calendar, for the glance page's day.
    case calendar

    /// Location, for the weather beside it.
    case weather

    /// Bluetooth. **The one page that does not ask**, because there is nothing here that can:
    /// CoreBluetooth raises its dialog when `IOBluetoothDeviceMonitor.start()` registers, which is
    /// at launch — so on a first run the answer has already been given by the time this page is
    /// reached. It explains what that dialog was for, and offers System Settings if it was refused.
    /// See `OnboardingState.Permission.request` being nil for this step.
    case devices

    /// Launch at login — asked here because an app with no Dock icon is one the user cannot
    /// re-launch by habit, so "it stopped working after I restarted" is the default experience
    /// otherwise.
    case startup

    /// Where the island is and how to reach it. The page the whole flow exists to deliver.
    case ready

    /// The page a name refers to, for `--onboarding <page>`.
    ///
    /// Spelled here rather than as a `String` raw value, because the ordering is the raw value and a
    /// type cannot have two. Names rather than indices for the same reason `--settings` takes a pane
    /// name: `--onboarding 2` is a number that means something different the day a page is inserted,
    /// and the person typing it is the one who inserted it.
    public init?(name: String) {
        switch name {
        case "welcome": self = .welcome
        case "accessibility": self = .accessibility
        case "music": self = .music
        case "calendar": self = .calendar
        case "weather": self = .weather
        case "devices": self = .devices
        case "startup": self = .startup
        case "ready": self = .ready
        default: return nil
        }
    }

    public var id: Int { rawValue }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }

    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    public var isLast: Bool { next == nil }

    /// The five pages that are about a permission, in order.
    ///
    /// Derived from the cases rather than written out a second time, so a page added to the enum
    /// cannot be forgotten here — which is exactly what happened to the Accessibility page when
    /// notifications were withdrawn: it left the flow and three doc comments went on saying it was
    /// still there.
    public static let permissions: [OnboardingStep] = allCases.filter { $0.permission != nil }

    /// Which permission this page is about, or nil for the three that are not about one.
    ///
    /// The enum is the identity for both the page *and* what it asks for, rather than a parallel
    /// table keyed by step — the arrangement `SourceSettingsRow` uses in keying itself on
    /// `ActivityKind`, and for the same reason: two rows for one permission should not be
    /// expressible.
    public var permission: OnboardingPermission? {
        switch self {
        case .accessibility: .accessibility
        case .music: .automation
        case .calendar: .calendar
        case .weather: .location
        case .devices: .bluetooth
        case .welcome, .startup, .ready: nil
        }
    }

    /// What the primary button says. "Get Started" on the last page rather than "Done", because the
    /// user has not done anything — they are about to.
    ///
    /// A permission page's button is **not** decided here, because it depends on an answer this
    /// type cannot see — see `OnboardingState.Permission.advanceTitle`, which is the same question
    /// asked where the authorization is known.
    public var advanceTitle: String {
        isLast
            ? settingsText("onboarding.getStarted", "Get Started")
            : settingsText("onboarding.continue", "Continue")
    }
}

/// The five permissions the first-run flow is about, as an identity separate from the page.
///
/// Separate because the app shell has to name one without importing the flow's page order — it is
/// the layer that reads `EKEventStore.authorizationStatus` and `AXIsProcessTrusted`, and it should
/// not have to know that Calendar is page three. `OnboardingStep.permission` is the one place the
/// two are tied together.
public enum OnboardingPermission: String, CaseIterable, Sendable {
    case automation
    case calendar
    case location
    case bluetooth
    case accessibility
}

/// Whether this Mac has been shown the first-run flow, and for which version of it.
///
/// A stored **version**, not a `Bool`. The flow's job is to introduce whatever a user has to act on
/// before Isleta works, and that set changes: a release that adds a second permission needs to reach
/// people who were onboarded before it existed, and a `Bool` cannot express "onboarded, but for an
/// older set of questions". Bumping `currentVersion` is the whole mechanism.
///
/// **Deliberately not in `IsletaConfiguration`.** Two reasons, and the first is the load-bearing
/// one: "Reset to Defaults" puts every setting in that record back to its shipped value, and a
/// first-run flag living there would mean resetting settings re-runs onboarding on the next launch —
/// a surprise with no relationship to what the user asked for. The second is that this has to be
/// readable at a point in launch where the answer decides whether a window is built at all, which is
/// the same argument `NotificationPromptLedger` makes for staying out of the settings store.
///
/// Not `Sendable`, because `UserDefaults` is not, and every caller is already on the main actor.
public struct OnboardingLedger {

    /// The version of the flow this build ships.
    ///
    /// Bump it when the flow gains a page a previously-onboarded user genuinely has to see — a new
    /// permission, a new thing they must do before Isleta works. Not for rewording, not for a new
    /// illustration: every bump puts a window in front of somebody who has already answered these
    /// questions once, and an app that does that for cosmetic reasons is one people stop updating.
    /// **2 as of the five permission pages.** Version 1 asked about nothing a user had to grant —
    /// the Accessibility page had gone out with notifications, and Automation, Calendar, Location
    /// and Bluetooth had never had one, so every permission Isleta needs was discoverable only by
    /// opening Settings and reading the Sources pane. That is precisely the bump this mechanism
    /// exists for, and the first one it has been used for.
    public static let currentVersion = 2

    /// Suite-scoped in tests so they never write into the developer's own copy of Isleta — a test
    /// that marks onboarding complete in `.standard` passes on a clean machine and then permanently
    /// suppresses the flow on the machine it ran on, which is exactly the bug you cannot reproduce.
    private let defaults: UserDefaults
    private let key = "com.tryisleta.onboarding.completedVersion"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The flow version this Mac has already been through. Zero when it never has — which is both a
    /// fresh install and every copy that predates this flow, and they want the same answer.
    public var completedVersion: Int {
        get { defaults.integer(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }

    /// Whether to put the window up at this launch.
    ///
    /// `<` rather than `!=`, so a Mac that briefly ran a newer Isleta and went back is not made to
    /// sit through an older flow it has already answered a superset of.
    public var shouldPresent: Bool { completedVersion < Self.currentVersion }

    /// Records that the user has been through it — reached the end, or closed the window.
    ///
    /// **Closing counts.** The alternative is a flow that reappears at every launch until it is
    /// completed on its own terms, which is the shape of nagging §10 rules out; and a user who
    /// dismissed it has answered the question it was asking. It stays reachable from the status
    /// menu, which is the honest way to offer it a second time.
    public func markComplete() {
        completedVersion = Self.currentVersion
    }

    /// Puts this Mac back to never-onboarded. For `--onboarding-reset`, and for a test that needs to
    /// observe the first-run path more than once.
    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
