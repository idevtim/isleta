import AppKit
import SwiftUI

/// The first-run flow's content: eight pages, five of them about a permission, and one button.
///
/// ## Why this is not a pane of the settings window
///
/// Settings is a place you go to change something you already understand. This is the opposite
/// errand — it exists to tell a first-time user that Isleta is running at all, what the notch is
/// about to start doing, and which permissions stand between them and the features they installed it
/// for. A pane in a sidebar is something you have to already know to look for; the whole failure this
/// flow addresses is that nobody had a reason to look.
///
/// It shares the settings window's surfaces — `SettingsBackdrop`, `SettingsPalette`, the card fill
/// and hairline — so that arriving in Settings afterwards feels like the same application rather
/// than a second one.
///
/// ## What changed when the permission pages arrived, and why
///
/// Until then this flow asked for nothing. The Accessibility page had gone out with notifications
/// and the other four permissions had never had one, so every gate in Isleta was discoverable only
/// by opening the Sources pane — and three doc comments across the codebase went on asserting that
/// onboarding still asked. The symptom was an app whose most-wanted features quietly did not work,
/// with no on-screen way to find out why.
///
/// Two rules did *not* change, and they are what keep this from being a permission wall:
///
/// **Every page can be left.** There is always a control that advances. Where Continue stops being
/// that control — because it is asking rather than advancing — a Skip appears beside it. Closing the
/// window still counts as finished (`OnboardingLedger.markComplete`).
///
/// **Nothing prompts on its own.** A dialog appears only under a button the user pressed, on a page
/// that has just said what is about to be asked and which answer to give. That is what §10 means by
/// a moment the user initiated, and it is the reverse of the arrangement it replaced, where macOS
/// asked cold.
///
/// ## The one thing that regressed on purpose
///
/// `SourceHub.didPromptDuringLaunch` used to be false in every launch the user did not click
/// something in, and this window opens *during* launch. It still is — because Continue is a click —
/// but the check is now load-bearing rather than incidental, since there is finally something behind
/// this window that can prompt. See `OnboardingPromptTests`.
struct OnboardingView: View {

    private let store: SettingsStore

    /// Read as a closure rather than a value for `GlanceSettingsState`'s reason: every field behind
    /// it is a live system query — `EKEventStore.authorizationStatus`, `CLLocationManager`,
    /// `AXIsProcessTrusted`, an `NSWorkspace` lookup per installed app — and `body` must never make
    /// one. Called on appear, on every page change, and whenever Isleta comes back to the front.
    private let state: @MainActor () -> OnboardingState

    /// Called when the user reaches the end or closes the window. The controller marks the ledger
    /// and closes; this view does not know it is in a window.
    private let onFinish: () -> Void

    @State private var step: OnboardingStep
    @State private var snapshot = OnboardingState()
    @State private var launchState: LaunchAtLogin.State = .disabled
    @State private var launchError: String?

    /// Whether the current page has already put its dialog up.
    ///
    /// The one piece of state that makes "ask again" different from "ask": before the first press,
    /// Continue is an offer; after it, the same button on an unanswered permission is a second
    /// offer, and a Skip has to exist beside it. Reset on every page change — it is a fact about
    /// this visit to this page, not about the permission.
    @State private var didAsk = false

    /// True while a request is in flight. `AEDeterminePermissionToAutomateTarget` blocks for as long
    /// as its dialog is up and EventKit answers on a background queue, so there is a real interval
    /// here in which a second press would raise a second dialog.
    @State private var isAsking = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Substituted for the page transition when the user has asked for less motion (§6.3). The pages
    /// slide because a flow with a direction should look like one; a crossfade says the same thing
    /// without the travel.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter initialStep: which page opens first. Named `initial` rather than `step` because
    ///   it seeds `@State` and is then the user's to change — a caller handing a new value to an
    ///   already-built view would be ignored, and a name implying otherwise would eventually be used
    ///   that way. Same reasoning as `SettingsView.initialSection`.
    init(
        store: SettingsStore,
        initialStep: OnboardingStep = .welcome,
        state: @escaping @MainActor () -> OnboardingState = { OnboardingState() },
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.state = state
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                // Taller than it was, because the window has no title bar to sit under any more —
                // see `OnboardingWindowController`. The 34 replaces the old 44 plus the 28pt band
                // AppKit used to reserve, which is why the content did not move up when the chrome
                // went away.
                .padding(.top, 34)

            footer
                .padding(.horizontal, 40)
                .padding(.bottom, 26)
        }
        // Fixed, and sized to the tallest page rather than to the average of them.
        //
        // A flow whose window resizes between pages is one whose buttons move under the pointer, so
        // the height cannot follow the content — which leaves the eight pages differing by how much
        // space is left under the content, and the tallest one is the constraint. 540 is where a
        // permission page — dialog preview, headline, payoff row, caption — has room to breathe
        // without the three shorter ones reading as half-empty.
        .frame(width: 560, height: 540)
        .toggleStyle(.switch)
        .settingsBackdrop(reduceTransparency: reduceTransparency)
        .onAppear { refresh() }
        // The same hook the settings window uses, for the same reason and no timer (§9): a
        // permission and a login item can only change while the user is away in System Settings, so
        // coming back to Isleta is exactly when both answers are stale. It is the *only* thing that
        // notices an Accessibility grant, whose dialog sends the user out of the app to finish.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        launchState = LaunchAtLogin.state
        snapshot = state()
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        // Keyed on the step so SwiftUI treats each page as a different view rather than as the same
        // one with new text — without the id the transition has nothing to move between and the
        // words simply change in place.
        Group {
            switch step {
            case .welcome: welcomePage
            case .music, .calendar, .weather, .devices, .accessibility:
                // One view for all five, driven by `OnboardingStep.permission`. Five hand-built
                // pages is how a flow ends up with an icon eight points larger on one of them and a
                // heading a weight lighter on another.
                OnboardingPermissionPage(
                    permission: step.permission ?? .accessibility,
                    state: snapshot[step]
                )
            case .startup: startupPage
            case .ready: readyPage
            }
        }
        .id(step)
        .transition(
            reduceMotion
                ? AnyTransition.opacity
                : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                )
        )
    }

    private var welcomePage: some View {
        pageBody(
            icon: { AppIconView(size: 88) },
            title: settingsText("onboarding.welcome.title", "Welcome to Isleta"),
            body: settingsText("onboarding.welcome.body", """
                Isleta turns the notch into somewhere your Mac can speak from — what’s playing, \
                a device connecting, the volume you just changed.
                """)
        ) {
            SettingsCard {
                bullet(
                    "cursorarrow.rays",
                    settingsText(
                        "onboarding.welcome.hover",
                        "Move your pointer over the notch and the island answers."
                    )
                )
                bullet(
                    "menubar.arrow.up.rectangle",
                    settingsText(
                        "onboarding.welcome.menuBar",
                        "No Dock icon and no window. Isleta lives in the menu bar."
                    )
                )
                // New in the eight-page flow, and it is the sentence that makes the next five pages
                // reasonable rather than an interrogation. A user who knows the asking has a shape
                // and an end sits through it; one who does not starts counting.
                bullet(
                    "lock.open",
                    settingsText(
                        "onboarding.welcome.permissions",
                        "The next few pages ask for the permissions each feature needs. You can skip any of them."
                    )
                )
            }
        }
    }

    /// Launch at login.
    ///
    /// Asked here because an app with no Dock icon is one the user cannot re-launch by habit, so
    /// "it stopped working after I restarted" is the default experience otherwise.
    private var startupPage: some View {
        pageBody(
            icon: { pageSymbol("power") },
            title: settingsText("onboarding.startup.title", "Start with your Mac"),
            body: settingsText("onboarding.startup.body", """
                Isleta has no Dock icon, so it starts out of sight and stays there until you need it.
                """)
        ) {
            SettingsCard {
                SettingsRow(caption: launchState == .requiresApproval
                            ? settingsText(
                                "startup.awaitingApproval",
                                "Waiting for your approval in System Settings."
                            )
                            : settingsText("onboarding.startup.caption", """
                                Recommended. Without it the notch is empty again after every restart.
                                """)) {
                    Toggle(settingsText("startup.launchAtLogin", "Launch Isleta at login"), isOn: Binding(
                        get: { launchState == .enabled || launchState == .requiresApproval },
                        set: { setLaunchAtLogin($0) }
                    ))
                }

                if launchState == .requiresApproval {
                    Button(settingsText("startup.openLoginItems", "Open Login Items")) {
                        LaunchAtLogin.openSystemSettings()
                    }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }

                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var readyPage: some View {
        pageBody(
            icon: { pageSymbol("sparkles") },
            title: settingsText("onboarding.ready.title", "You’re all set"),
            body: settingsText("onboarding.ready.body", """
                The island is invisible until it has something to say, or until you go looking for it.
                """)
        ) {
            SettingsCard {
                bullet(
                    "cursorarrow.rays",
                    settingsText("onboarding.ready.hover", "Hover the notch to peek. Click to open.")
                )
                // The shortcut as the user actually has it, not as it shipped. This page is read
                // once, at the moment somebody is deciding what to remember, and printing a
                // shortcut they have already changed would be the one line here they cannot trust.
                bullet(
                    "command",
                    settingsText(
                        "onboarding.ready.shortcut",
                        "Press \(store.configuration.toggleHotKey.displayString) from any app to open it."
                    )
                )
                bullet(
                    "gearshape",
                    settingsText("onboarding.ready.menuBar", "The menu-bar icon opens Isleta’s settings.")
                )
            }
        }
    }

    // MARK: - Page furniture

    /// The three pages that are not about a permission are the same three things above whatever they
    /// are actually saying.
    ///
    /// A shared shape rather than three hand-built stacks, because the alternative drifts: an icon
    /// eight points larger on one page and a heading a weight lighter on another is exactly how a
    /// flow comes to look like eight screens from three applications.
    private func pageBody<Icon: View, Content: View>(
        @ViewBuilder icon: () -> Icon,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 16) {
            icon()

            Text(title)
                .font(.system(.title, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

    /// The one symbol treatment. Hierarchical rather than multicolor: this window already carries
    /// the app's own two-stop gradient behind it, and a palette symbol on top of it is a third
    /// color scheme in 560 points.
    private func pageSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 46, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(SettingsPalette.bright)
            .frame(height: 88)
            .accessibilityHidden(true)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    /// One centered button, and a second only when the first has stopped being the way forward.
    ///
    /// No Back and no dots, unlike the three-page flow this replaces. Both were answering "how much
    /// of this is left", which mattered when the pages were a tour; now every page is a question
    /// with its own answer, and a progress indicator over a permission request reads as a countdown
    /// to getting through it.
    private var footer: some View {
        VStack(spacing: 10) {
            // `.bordered` rather than `.borderedProminent`, which reverses the call the three-page
            // flow made — and **not for the reason it was first changed for.**
            //
            // The argument was that a prominent blue Continue competes with the mock dialog's tinted
            // button, which is the instruction this page carries. That argument is wrong about the
            // pixels: `.keyboardShortcut(.defaultAction)` makes AppKit paint this with the accent
            // colour anyway while the window is key, so the two styles are indistinguishable at the
            // moment anyone is looking at the page. Measured on macOS 27.0 — the grey button in the
            // first screenshot was an *unfocused* window, not the style taking effect.
            //
            // It stays `.bordered` because that is the more accurate default button: it drops back
            // to grey when the window is not key, exactly as every stock macOS default button does,
            // where `.borderedProminent` stays blue in a window the user has left. The accent fill
            // is right here — this is the default action, and a Mac's default action looks like one.
            Button(advanceTitle) { advance() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isAsking)

            // The way past a page whose primary button is no longer the way past it. Present only
            // then — a Skip beside a Continue that already advances is two controls doing one job,
            // and on the very first press it would read as *this is going to be difficult*.
            if needsSkip {
                Button(settingsText("onboarding.skip", "Skip")) { move(to: step.next) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: needsSkip)
    }

    // MARK: - What the button does

    /// The permission this page is asking about, or nil on the three that ask about nothing.
    private var permission: OnboardingState.Permission? { snapshot[step] }

    /// What the primary button says, which is a different question on a permission page.
    ///
    /// Four answers, and each names the act rather than the destination — "Ask Again" says what
    /// pressing it does, where "Continue" on the same page would be a button that does not continue.
    private var advanceTitle: String {
        guard let permission, permission.request != nil || permission.access == .denied else {
            return step.advanceTitle
        }
        switch permission.access {
        case .granted, .notNeeded:
            return step.advanceTitle
        case .notDetermined:
            return didAsk
                ? settingsText("onboarding.askAgain", "Ask Again")
                : step.advanceTitle
        case .denied:
            // Only where there is a pane to open. A refusal with no deep link has nothing left to
            // offer, and the button goes back to being the one that moves on.
            return permission.openSettings == nil
                ? step.advanceTitle
                : settingsText("onboarding.openSystemSettings", "Open System Settings…")
        }
    }

    /// Whether the page needs a second control to get past it.
    ///
    /// Exactly when the primary button is not the one that advances — asked and unanswered, or
    /// refused with somewhere to send them. Deriving it from the same two conditions the title uses,
    /// rather than storing it, is what keeps a page from ever having two buttons that both advance
    /// or none that do.
    private var needsSkip: Bool {
        guard let permission else { return false }
        switch permission.access {
        case .granted, .notNeeded: return false
        case .notDetermined: return didAsk && permission.request != nil
        case .denied: return permission.openSettings != nil
        }
    }

    /// Continue, Ask Again and Open System Settings are all this one function, because from the
    /// page's point of view they are one act with three outcomes: do whatever is left to do here,
    /// and move on if there is nothing.
    private func advance() {
        guard let permission else {
            move(to: step.next)
            return
        }

        switch permission.access {
        case .granted, .notNeeded:
            move(to: step.next)

        case .notDetermined:
            guard let request = permission.request else {
                // Bluetooth, and any permission the app shell could not offer. There is nothing to
                // ask, so the page is purely an explanation and Continue means Continue.
                move(to: step.next)
                return
            }
            isAsking = true
            didAsk = true
            request { answer in
                isAsking = false
                // Re-read everything rather than trusting the one answer: granting Calendar can
                // change what `EKEventStore` reports about the calendar list too, and the snapshot
                // is what the next page will draw from.
                refresh()
                // Advance only on yes. A dismissed dialog leaves TCC with no answer and the user on
                // this page with an offer to try again — which is the point, and is why the button
                // and the skip are derived from `access` rather than from having pressed once.
                if answer == .granted { move(to: step.next) }
            }

        case .denied:
            guard let openSettings = permission.openSettings else {
                move(to: step.next)
                return
            }
            openSettings()
            // Deliberately does **not** advance. The user is now in System Settings; coming back to
            // Isleta fires `didBecomeActive`, `refresh()` re-reads the grant, and the button becomes
            // Continue on its own if they granted it. Advancing here would leave them returning to
            // a page about something else.
        }
    }

    private func move(to destination: OnboardingStep?) {
        guard let destination else {
            onFinish()
            return
        }
        // Re-read on the way into every page rather than only on activation. Granting Accessibility
        // through the system prompt does not deactivate Isleta — the dialog belongs to us — so
        // `didBecomeActive` never fires for the one path that most needs the refresh.
        refresh()
        didAsk = false
        withAnimation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.28)) {
            step = destination
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            launchError = LaunchAtLogin.explanation(for: error, enabling: enabled)
        }
        launchState = LaunchAtLogin.state
    }
}
