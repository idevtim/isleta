import AppKit

/// What the first-run flow needs from the running app, per permission.
///
/// The same arrangement `GlanceSettingsState` and `SourcesPaneState` use, for the same two reasons —
/// IslandSettings must build and preview with nothing granted (§3), so it cannot import the package
/// that links EventKit, CoreLocation and CoreBluetooth; and every field here is a live system read,
/// so it is snapshotted when Isleta comes back to the front rather than called from `body`.
///
/// It carries one thing those two do not: **the icons of the apps this permission is about.**
/// `NSWorkspace.urlForApplication(withBundleIdentifier:)` is a live read of what is installed, and a
/// page that shows Spotify to somebody who has never installed it is telling them about an app
/// rather than about their Mac. The app shell resolves them for the same reason it resolves
/// everything else here — it is the only layer allowed to ask.
public struct OnboardingState {

    /// One app or device the permission is *for*, drawn in the row under the headline.
    ///
    /// The concrete icons are the whole argument of that row. "Isleta needs Calendar access" is a
    /// sentence about Isleta; the same sentence over the user's own Calendar and Fantastical icons
    /// is a sentence about their Mac, and it is the second one that gets a permission granted.
    public struct Payoff: Identifiable, Sendable {

        /// The bundle identifier where there is one, or a stable spelling of the device otherwise.
        /// Never shown.
        public let id: String

        /// What the icon is called. The app's own name as macOS reports it wherever there is one —
        /// **never Isleta's guess at it**, because a user who renamed the app or runs it in another
        /// language is looking at the name on their own screen.
        public let name: String

        /// The real icon, resolved by the app shell. Nil where the app is not installed or the row
        /// is about hardware rather than software, in which case `symbol` is drawn instead.
        ///
        /// `NSImage` is not `Sendable`, which is why this struct is not either. Every use is already
        /// on the main actor.
        public let icon: NSImage?

        /// The SF Symbol drawn when there is no icon. Never a bundled asset (§6.5) and never a PNG
        /// scraped out of a system framework: the private paths that hold Apple's own permission
        /// artwork have moved between releases, and a missing image is a blank square nobody
        /// notices until a user reports it.
        public let symbol: String

        public init(id: String, name: String, icon: NSImage? = nil, symbol: String) {
            self.id = id
            self.name = name
            self.icon = icon
            self.symbol = symbol
        }
    }

    /// Where the user stands on one permission, and what can still be offered.
    public struct Permission {

        /// The four states the flow acts on differently — the same four `SourceAuthorization` has,
        /// and the reason it has four.
        ///
        /// **`notNeeded` was folded into `granted` at first, and that was wrong on the page it
        /// mattered on.** The argument was that both mean "Continue advances", which is true of the
        /// *button* and false of the *sentence*: the music page on a Mac where the mediaremote
        /// adapter is live had "Choose OK when macOS asks whether Isleta can control your music
        /// app" under it, for a dialog that was never going to appear, because Automation is only
        /// the fallback route's permission. A state that produces correct behaviour and incorrect
        /// copy is still a missing state.
        public enum Access: Equatable, Sendable {

            /// Nothing left to do. Continue advances.
            case granted

            /// Nothing to ask on *this* Mac — a permission whose feature is reached another way, or
            /// whose hardware is absent. Continue advances, and the page says so rather than
            /// claiming a grant nobody gave.
            case notNeeded

            /// Never asked, or asked and left unanswered. Continue offers.
            case notDetermined

            /// Refused. **The system will not ask again** — for Calendar, Location and Automation
            /// it returns the stored answer with no dialog — so the only honest offer left is the
            /// deep link, and there has to be a way past the page without taking it.
            case denied
        }

        public var access: Access

        /// Raise the system dialog, and report where the user landed.
        ///
        /// Nil where a prompt would not show, and that is the §10 rule made structural rather than
        /// enforced by a disabled button: `.denied` never has one, and **Bluetooth never has one in
        /// any state**, because CoreBluetooth raises its dialog when the monitor registers at launch
        /// and offers no call that asks a second time. A button that visibly does nothing is worse
        /// than no button, which is the rule `SourceHub.action(for:)` already follows.
        ///
        /// Asynchronous because two of the five are: `AEDeterminePermissionToAutomateTarget` blocks
        /// for as long as the dialog is up, and EventKit answers on a background queue.
        public var request: Request?

        /// Spelled as a name rather than left inline, because the app shell builds five of these
        /// and an optional main-actor closure taking an escaping main-actor closure is the shape
        /// that has already defeated the type checker outright in `SourceHub.glanceSettingsState` —
        /// `failed to produce diagnostic for expression`. A named type is also the clearer read.
        public typealias Request = @MainActor (@escaping @MainActor (Access) -> Void) -> Void

        /// Open System Settings at this permission's privacy pane.
        ///
        /// Present whenever there is a pane to open, not only when refused — the Accessibility page
        /// offers it beside a prompt that has been answered but not acted on, which is the one case
        /// where a user has said yes to a dialog and still has a switch to throw.
        public var openSettings: (@MainActor () -> Void)?

        /// The apps or devices drawn under the headline. Empty is allowed and draws nothing rather
        /// than an empty card — a Mac with no supported music player installed should not be shown
        /// a row of blanks.
        public var payoff: [Payoff]

        public init(
            access: Access = .notDetermined,
            request: Request? = nil,
            openSettings: (@MainActor () -> Void)? = nil,
            payoff: [Payoff] = []
        ) {
            self.access = access
            self.request = request
            self.openSettings = openSettings
            self.payoff = payoff
        }
    }

    /// Keyed by what the permission *is*, not by which page it is on. The app shell builds this and
    /// has no reason to know the page order; `OnboardingStep.permission` is the one place the two
    /// meet.
    public var permissions: [OnboardingPermission: Permission]

    public init(permissions: [OnboardingPermission: Permission] = [:]) {
        self.permissions = permissions
    }

    /// What this page should draw, or nil for a page that is not about a permission — and also for
    /// a permission the app shell could not describe, which is the state a SwiftUI preview and a
    /// unit test are both in. A page with no `Permission` renders its explanation and a plain
    /// Continue, which is the correct thing to show when nothing can be asked.
    public subscript(step: OnboardingStep) -> Permission? {
        guard let permission = step.permission else { return nil }
        return permissions[permission]
    }
}

// MARK: - What each page says

extension OnboardingPermission {

    /// The headline for a page that is about to ask, or has asked.
    ///
    /// One sentence, and it names the **payoff rather than the API**. "Isleta needs Calendar access"
    /// describes a checkbox; "…to show what's next in your day" describes what the user gets, and
    /// §10 asks for the second. Nothing here names the framework, the entitlement or the pane.
    ///
    /// Not used for `.notNeeded` — see `headline(for:)`, which is the one caller.
    var headline: String {
        switch self {
        case .automation:
            settingsText("onboarding.permission.automation.headline",
                         "Isleta needs your permission to show the music you’re already playing.")
        case .calendar:
            settingsText("onboarding.permission.calendar.headline",
                         "Isleta needs your permission to show what’s next in your day.")
        case .location:
            settingsText("onboarding.permission.location.headline",
                         "Isleta needs your permission to show the weather where you are.")
        case .bluetooth:
            settingsText("onboarding.permission.bluetooth.headline",
                         "Isleta needs your permission to show the devices you connect.")
        case .accessibility:
            settingsText("onboarding.permission.accessibility.headline",
                         "Isleta needs your permission to replace the system volume and brightness HUDs.")
        }
    }

    /// The headline as this page should say it, which is a different sentence when there is nothing
    /// to ask for.
    ///
    /// "Isleta needs your permission to…" over a page that will never raise a dialog is the same
    /// mistake as the instruction line under it, and it is worth spelling both rather than only the
    /// one that was noticed.
    func headline(for access: OnboardingState.Permission.Access) -> String {
        guard access == .notNeeded else { return headline }
        switch self {
        case .automation:
            return settingsText("onboarding.permission.automation.notNeeded.headline",
                                "Isleta shows the music you’re already playing.")
        case .bluetooth:
            return settingsText("onboarding.permission.bluetooth.notNeeded.headline",
                                "Isleta shows the devices you connect.")
        // **Unreachable, and deliberately not given copy of their own.** EventKit, CoreLocation and
        // the Accessibility API each require a grant on every Mac that has the feature at all —
        // there is no route to any of the three that asks nobody — so `.notNeeded` cannot arrive
        // here. Inventing three sentences nobody will read is how a strings file fills with copy
        // that cannot be checked against a screen.
        case .calendar, .location, .accessibility:
            return headline
        }
    }

    /// What the page says when there was never anything to ask.
    ///
    /// Both of these are facts about *this Mac* rather than about the user's choices, which is why
    /// neither is phrased as a permission outcome.
    func notNeeded() -> String {
        switch self {
        case .automation:
            // The adapter route. It reads Now Playing directly and asks nobody for anything —
            // Automation is the scripting fallback's permission, and the fallback is not running.
            return settingsText("onboarding.permission.automation.notNeeded",
                                "Nothing to allow. Isleta reads what’s playing on this Mac without asking for anything.")
        case .bluetooth:
            return settingsText("onboarding.permission.bluetooth.notNeeded",
                                "Nothing to allow. This Mac has no Bluetooth radio Isleta can watch.")
        case .calendar, .location, .accessibility:
            return granted
        }
    }

    /// The grey line under the payoff row, saying what is about to happen and which button to press.
    ///
    /// The most useful sentence on the page, and the reason the flow asks at all rather than letting
    /// macOS ask cold: a TCC dialog arrives with no context, names a framework, and is answered by
    /// somebody who has no idea what said it. This is the context, delivered one click before.
    ///
    /// Bluetooth's is past tense, alone among the five, because its dialog has already been and
    /// gone — see `OnboardingStep.devices`.
    var instruction: String {
        switch self {
        case .automation:
            settingsText("onboarding.permission.automation.instruction",
                         "Choose OK when macOS asks whether Isleta can control your music app.")
        case .calendar:
            settingsText("onboarding.permission.calendar.instruction",
                         "Choose Allow Full Access when macOS asks about your calendars.")
        case .location:
            settingsText("onboarding.permission.location.instruction",
                         "Choose Allow when macOS asks for your location.")
        case .bluetooth:
            settingsText("onboarding.permission.bluetooth.instruction",
                         "macOS asked about Bluetooth when Isleta started. Allowing it is what shows a device arriving, and how much charge it has left.")
        case .accessibility:
            settingsText("onboarding.permission.accessibility.instruction",
                         "Choose Open System Settings when macOS asks, then switch Isleta on in the list.")
        }
    }

    /// What the page says once the answer is yes. Replaces `instruction`, rather than sitting under
    /// it: a page that still explains which button to press after the user has pressed it is one
    /// they read twice and trust less the second time.
    var granted: String {
        switch self {
        case .automation:
            settingsText("onboarding.permission.automation.granted",
                         "Allowed. The island names the track as soon as you open it.")
        case .calendar:
            settingsText("onboarding.permission.calendar.granted",
                         "Allowed. Your day is on the island’s second page.")
        case .location:
            settingsText("onboarding.permission.location.granted",
                         "Allowed. The weather is on the island’s third page.")
        case .bluetooth:
            settingsText("onboarding.permission.bluetooth.granted",
                         "Allowed. Your devices appear at the notch as they connect.")
        case .accessibility:
            settingsText("onboarding.permission.accessibility.granted",
                         "Allowed. Volume and brightness now happen at the notch.")
        }
    }

    /// What the page says after a refusal.
    ///
    /// **Not a second ask, and not an apology.** It says what is switched off, and where the switch
    /// is if they change their mind. §10's rule is that a refusal is answered with an explanation
    /// and silence, and the deep link beside it is the honest version of "if you change your mind" —
    /// the system will not raise the dialog again, so the alternative is a button that does nothing.
    var denied: String {
        switch self {
        case .automation:
            settingsText("onboarding.permission.automation.denied",
                         "That’s fine. Isleta will show what’s playing from the next play, pause or track change instead.")
        case .calendar:
            settingsText("onboarding.permission.calendar.denied",
                         "That’s fine. The island’s second page stays empty, and everything else works.")
        case .location:
            settingsText("onboarding.permission.location.denied",
                         "That’s fine. You can pick a city in Isleta’s settings instead.")
        case .bluetooth:
            settingsText("onboarding.permission.bluetooth.denied",
                         "That’s fine. Devices still connect as usual — Isleta just won’t say so at the notch.")
        case .accessibility:
            settingsText("onboarding.permission.accessibility.denied",
                         "That’s fine. macOS keeps showing its own volume and brightness HUDs.")
        }
    }

    /// The badge on the mock dialog's icon — the permission, drawn on top of Isleta's own icon the
    /// way macOS badges its own.
    ///
    /// SF Symbols only (§6.5). Apple's real TCC artwork lives in private frameworks whose paths have
    /// moved between releases, and reaching for it would be a blank square in a future macOS with
    /// nothing logged.
    var symbol: String {
        switch self {
        case .automation: "music.note"
        case .calendar: "calendar"
        case .location: "location.fill"
        case .bluetooth: "wave.3.right"
        case .accessibility: "accessibility"
        }
    }
}
