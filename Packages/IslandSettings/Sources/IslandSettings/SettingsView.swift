import AppKit
import Combine
import IslandActivities
import IslandKit
import IslandUI
import SwiftUI

/// The settings window's content (§8.1.8).
///
/// Every control here writes through `SettingsStore.update` and reads back from
/// `store.configuration`. There is no local `@State` mirror of a setting, which is the bug this
/// shape exists to prevent: a mirrored toggle drifts the moment anything else changes the value —
/// a reset, a future menu item, a second window — and then shows the user the opposite of what is
/// actually in effect.
///
/// `launchState` is the one piece of local state, and it mirrors the *system's* answer rather than
/// ours. `SMAppService` has no change notification, so the only way to notice that the user turned
/// the login item off in System Settings is to look again when they come back to Isleta. That is
/// driven by the activation notification, not by a timer: nothing here runs while the window is
/// closed, which is what §9 asks for.
///
/// ## Why a split view rather than one `Form`
///
/// This was a single grouped `Form` through Milestone 9, and it worked — but it put seven sections
/// on one scroll, so the thing a user opened the window to change was usually below the fold, and
/// "Reset to Defaults" shared a scroll with the switch for haptics. A sidebar makes each pane short
/// enough to be read at a glance and puts the destructive control somewhere a person has to go
/// deliberately.
///
/// The visual half is `SettingsBackdrop` and `SettingsSurface`, and the layering is the point: the
/// window supplies something worth refracting, the cards are glass, and the **controls are stock**.
/// A hand-drawn switch that is nearly the system's is exactly the "close enough" this project's
/// brief rules out.
public struct SettingsView: View {

    private let store: SettingsStore
    private let updater: any SoftwareUpdater
    private let sourceRows: @MainActor () -> [SourceSettingsRow]

    /// Writes the "Export Logs…" bundle, or nil where there is nothing to export from.
    ///
    /// A closure rather than something this module does itself, and the reason is the file's
    /// contents rather than the save panel: the bundle carries the diagnostics report, which is
    /// assembled from the island controller and the running sources — both of which live in the app
    /// shell. `LogExport` in IslandKit already owns everything about the file that needs no app.
    ///
    /// Optional so a preview and a test get the pane without a Diagnostics card, rather than a
    /// button that opens a save panel onto an empty file. A control that is there and does nothing
    /// is the thing this window is careful about everywhere else.
    private let exportLogs: (@MainActor () -> Void)?

    /// Whether any display Isleta is drawing on has no notch of its own. Supplied by the app shell,
    /// which is the only layer that knows — `IslandKit` owns the screens and this module owns the
    /// slider that is meaningless without one.
    private let hasSynthesizedIsland: @MainActor () -> Bool

    /// What the calendar and the weather are currently able to do. Supplied by the app shell for the
    /// reason `sourceRows` is: IslandSettings must build and preview with no permission granted
    /// (§3), so it cannot import the package that links EventKit and CoreLocation.
    private let glanceState: @MainActor () -> GlanceSettingsState

    /// What the Sources pane needs that a `SourceSettingsRow` cannot carry — the notification
    /// roster, the Focus permission, and whether window previews are possible. Supplied by the app
    /// shell for the reason `glanceState` is: this module cannot import the package that links
    /// ScreenCaptureKit and Intents. See `SourcesPaneState`.
    private let sourcesState: @MainActor () -> SourcesPaneState

    /// Reopens the first-run flow, and quits Isleta.
    ///
    /// **Both exist because the status-item menu can be switched off**, and until now each of them
    /// was reachable from that menu and nowhere else. `showMenuBarIcon` shipped in 1.2.0 and 1.3.1
    /// already records the rule it created — nothing may be reachable *only* from the menu — and
    /// these two were the rows still breaking it. Quit is the serious one: a user who hid the icon
    /// had no way to stop Isleta short of Activity Monitor.
    ///
    /// Closures rather than something this module does itself, for `exportLogs`' reason: the
    /// onboarding window is the app shell's, and `NSApp.terminate` on a package that must build and
    /// preview standalone would put a live application object in a SwiftUI canvas. Optional so a
    /// preview and a test get the pane without them, rather than with buttons that do nothing.
    private let openSetupGuide: (@MainActor () -> Void)?
    private let quit: (@MainActor () -> Void)?

    @State private var section: SettingsSection

    /// The detail column's scroll offset, held only so a pane change can put it back at the top.
    /// See `detail`.
    @State private var scrollPosition = ScrollPosition()
    @State private var launchState: LaunchAtLogin.State = .disabled
    @State private var launchError: String?
    @State private var recorder: HotKeyRecorder?

    /// Read from the environment rather than from `AccessibilityPreferences` so the fallback is
    /// live in previews and in the SwiftUI canvas, where no `NSWorkspace` observer is running.
    /// IslandKit's copy is the app shell's; this window only needs to know what to draw.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Which side of `SettingsPalette` the pane header takes its fill from. Same reason as above:
    /// the environment's answer is live in a preview, where there is no window to ask.
    @Environment(\.colorScheme) private var colorScheme

    /// Snapshotted, not read in `body`.
    ///
    /// Every `SourceAuthorization` behind these rows is read live from the system —
    /// `AXIsProcessTrusted`, `AEDeterminePermissionToAutomateTarget`, a CoreAudio device query — and
    /// `body` runs on every redraw, including once per keystroke while a shortcut is being recorded
    /// and once per frame while a slider is dragged. Calling the provider from `body` would put a
    /// handful of IPC round trips on each of those. Refreshed on the same two events `launchState`
    /// is, and for the same reason: a permission can only change while the user is away in System
    /// Settings, so coming back to Isleta is exactly when the answer is stale. No timer, per §9.
    @State private var rows: [SourceSettingsRow] = []

    /// Snapshotted for the same reason `rows` is, and refreshed on the same two events. A display
    /// is plugged in while Isleta is not frontmost far more often than while it is.
    @State private var showsSynthesizedSettings = false

    /// Snapshotted for the reason `rows` is, and refreshed on the same two events. Every field
    /// behind it is a live system query — `EKEventStore.authorizationStatus`, the calendar list,
    /// `CLLocationManager.authorizationStatus`, a code-signing query for the WeatherKit entitlement
    /// — and `body` runs once per keystroke while a city is being typed.
    @State private var glance = GlanceSettingsState()

    /// Whether the user has just tried to switch location on and been refused.
    ///
    /// View state and not a setting, and deliberately not derived from `locationAccess`: see
    /// `locationPermissionControl`, which is the only thing that reads it. It resets with the window
    /// because the sentence it reveals is about a thing that just happened.
    @State private var locationRefusalIsShown = false

    /// The places the typed city could mean, as MapKit last answered.
    ///
    /// View state and not settings: it is a *list of offers*, alive only while the field has focus,
    /// and nothing about it survives the window closing. Held here rather than in a model for
    /// `glance`'s reason — this pane already owns its transient answers, and a second `@Observable`
    /// for five strings would be a class that exists to be a `@State`.
    @State private var citySuggestions: [CitySuggestion] = []

    /// The suggestion the user actually picked, so it is not immediately searched for again.
    ///
    /// Without it the pane loops visibly: choosing "London, England" writes that into the field,
    /// the field's change starts a search for "London, England", MapKit answers with London, and the
    /// list the user just dismissed by choosing from it reappears under their pointer.
    @State private var chosenCity: String?

    /// Whether the city field has the keyboard.
    ///
    /// The list is drawn only while it does. A completion list under an unfocused field is a
    /// permanent block of half-relevant place names in the middle of a settings pane, and it would
    /// push the cards below it down for as long as the window is open.
    @FocusState private var cityFieldIsFocused: Bool

    /// Snapshotted for the reason `rows` and `glance` are, and refreshed on the same two events.
    /// Every field is a live read — `INFocusStatusCenter.authorizationStatus` at 21 ms, the roster
    /// off a running source — and `body` runs once per keystroke while a shortcut is being
    /// recorded.
    @State private var sources = SourcesPaneState()

    /// Which shortcut the recorder is currently capturing for, or nil.
    ///
    /// Held beside `recorder` rather than inside it because the recorder does not know, and does not
    /// need to: it captures the next binding and hands it back. What the *field* needs is which of
    /// the seven rows should draw itself as recording, and a second row lighting up because they
    /// share one optional is the bug this exists to prevent.
    @State private var recordingAction: ShortcutAction?

    /// - Parameters:
    ///   - sourceRows: each source's state, re-read whenever Isleta comes back to the front.
    ///   - hasSynthesizedIsland: whether any display in use lacks a notch. The Displays-without-a-
    ///     notch card is hidden when it does not, because that slider provably does nothing on a
    ///     Mac whose every island is drawn in a real cutout — and a control that silently has no
    ///     effect on the hardware reading it is the thing §10 objects to about permissions.
    ///   - exportLogs: writes the diagnostics-and-history bundle the status menu's "Export Logs…"
    ///     writes. Supplied by the app shell; nil hides the card entirely.
    ///   - initialSection: which pane opens first. Named `initial` rather than `section` because it
    ///     seeds `@State` and is then the user's to change — a caller passing a new value to an
    ///     already-built view would be ignored, and a name that implied otherwise would eventually
    ///     be used that way.
    public init(
        store: SettingsStore,
        updater: any SoftwareUpdater,
        sourceRows: @escaping @MainActor () -> [SourceSettingsRow] = { [] },
        hasSynthesizedIsland: @escaping @MainActor () -> Bool = { true },
        exportLogs: (@MainActor () -> Void)? = nil,
        glanceState: @escaping @MainActor () -> GlanceSettingsState = { GlanceSettingsState() },
        sourcesState: @escaping @MainActor () -> SourcesPaneState = { SourcesPaneState() },
        openSetupGuide: (@MainActor () -> Void)? = nil,
        quit: (@MainActor () -> Void)? = nil,
        initialSection: SettingsSection = .general
    ) {
        self.store = store
        self.updater = updater
        self.sourceRows = sourceRows
        self.hasSynthesizedIsland = hasSynthesizedIsland
        self.exportLogs = exportLogs
        self.glanceState = glanceState
        self.sourcesState = sourcesState
        self.openSetupGuide = openSetupGuide
        self.quit = quit
        _section = State(initialValue: initialSection)
    }

    public var body: some View {
        // Pinned open, and the toggle removed — the sidebar does not collapse.
        //
        // Not a workaround for the janky animation, though it does remove one. On macOS SwiftUI
        // hosts the sidebar toggle *in the sidebar's* title bar, so collapsing the sidebar takes the
        // button with it — and SwiftUI answers by re-hosting a second one, the double chevron, in
        // the detail pane. For the length of the transition both exist, in different places, and the
        // collapse visibly stops between them while the title bar is relaid out. Two controls for
        // one state is the bug; the stall is what it looks like.
        //
        // Removing the toggle is the honest fix rather than the cheap one, because collapsing was
        // never worth offering here. The sidebar is 190pt of a 760pt window and hiding it buys
        // nothing but a window that no longer says which pane you are on. System Settings does not
        // let you hide its sidebar either, for the same reason.
        //
        // `.constant(.all)` rather than a `@State` that is only ever `.all`: this is not a value the
        // window owns and might change, and a binding that could be written to is an invitation to
        // write to it.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .settingsBackdrop(reduceTransparency: reduceTransparency)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// Re-reads the two things the *system* owns: the login-item state and every source's
    /// authorization. Neither has a change notification, and neither is allowed a timer.
    private func refresh() {
        launchState = LaunchAtLogin.state
        rows = sourceRows()
        showsSynthesizedSettings = hasSynthesizedIsland()
        glance = glanceState()
        sources = sourcesState()
    }

    // MARK: - Sidebar

    /// The pane list, with Isleta's own icon at the top.
    ///
    /// `scrollContentBackground(.hidden)` is what lets the backdrop reach behind the list. Without
    /// it AppKit paints the sidebar's own material over it, and the window becomes a tinted detail
    /// pane bolted to an ordinary gray sidebar — two surfaces, one window.
    private var sidebar: some View {
        List(SettingsSection.allCases, selection: $section) { item in
            Label { Text(item.title) } icon: { SectionIcon(section: item) }
                .tag(item)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // On the column's content, not on the `NavigationSplitView`. The toggle is contributed by
        // the column's own toolbar, so the modifier has to be inside it — applied to the split view
        // it compiles, runs, and removes nothing, which is a full build-and-look to notice.
        .toolbar(removing: .sidebarToggle)
        // A minimum, not just an ideal. Without one the divider can still be dragged all the way
        // left, which collapses the sidebar by hand and puts the window back in the state the
        // toggle was removed to prevent — with no control anywhere to undo it.
        .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 220)
        .safeAreaInset(edge: .top, spacing: 0) { identity }
        // The edge between the two columns, which `NavigationSplitView` does not draw once both
        // sides have `scrollContentBackground(.hidden)`: the sidebar and the detail column are then
        // two stops of one gradient meeting with nothing between them. Measured at the boundary
        // three quarters of the way down the window, the two sides were `#DDEAEF` and `#DBEBF2` —
        // a two-level step, which is no edge at all.
        //
        // **It is inside the column, and the divider is not.** `NSSplitView` owns the drag handle
        // and draws it *between* the columns, as a sibling of both rather than a descendant of
        // either — so a hairline at the trailing edge of the sidebar's own content cannot cover the
        // handle's tracking area, and the divider still drags between its 176 and 220. That is what
        // makes this safe without `.allowsHitTesting(false)`, which this codebase has a trap about.
        //
        // `ignoresSafeArea` so it reaches the window's top edge rather than starting below the
        // title bar — the detail column's header already runs up there, and a border that stopped
        // 28pt short would leave the corner it is supposed to define open.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SettingsPalette.hairline(colorScheme))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    /// Icon, name, version. At the top of the sidebar rather than buried in About, because in an app
    /// with no Dock icon and no menu bar this window is the *only* place Isleta ever shows the user
    /// what it is — there is nothing else on screen carrying the name.
    ///
    /// **It has no background of its own, and that is a claim about the window's minimum size.**
    /// There was a masked `.ultraThinMaterial` here, for the same reason the detail column had one:
    /// a `safeAreaInset` header is outside the scroll region, so rows slide *under* it and drew
    /// straight through the version number. Four rows under a 560pt minimum height cannot scroll —
    /// the identity block and the list together come to under 300pt — so there is nothing to slide
    /// under it and nothing for a material to hide. If a fifth pane is ever added, or the minimum
    /// height comes down, this needs a surface again: `SettingsPalette.chrome` is the one to use,
    /// not a material, which is what made it gray.
    private var identity: some View {
        VStack(spacing: 6) {
            AppIconView(size: 64)
            Text(AppVersion.name)
                .font(.system(.headline, weight: .semibold))
            Text(AppVersion.settingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    // MARK: - Detail

    /// The selected pane, under its header, scrolled.
    ///
    /// The `GlassEffectContainer` that used to wrap this is gone with the glass. It existed so that
    /// adjacent glass shapes sampled each other's edges rather than each computing its own in
    /// isolation; opaque cards have no edges to sample, so it was doing nothing but costing a
    /// layout pass.
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsSurface.cardSpacing) {
                switch section {
                case .general: generalPane
                case .sources: sourcesPane
                case .glance: glancePane
                case .about: aboutPane
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One margin on all four edges. The header is a `safeAreaInset`, so the pane's own top
            // margin starts below it rather than under it, and a pane that is tighter at the top
            // than at the sides reads as a layout mistake rather than as a decision.
            .padding(SettingsSurface.paneInset)
        }
        // A pane always arrives at its top.
        //
        // The scroll offset belongs to the `ScrollView`, and the `ScrollView` is the one view that
        // survives the selection changing — so without this, switching from halfway down a long pane
        // to a short one lands the reader partway into it, or past its end entirely, with no way to
        // tell that is what happened. Reported as panes "opening in the middle".
        //
        // **`scrollTo(edge: .top)` on a `ScrollPosition`, not a `ScrollViewReader` anchor.** The
        // anchor version was written first and was subtly wrong in a way that is worth keeping
        // written down: `scrollTo(id:anchor: .top)` puts *that view* at the top of the viewport, and
        // the only view available to aim at sits inside the pane's own `padding` — so the pane
        // arrived with its top inset scrolled off, and a reader could still scroll up by exactly the
        // padding they should already have been looking at. Reported as "too much padding at the
        // top". An edge is the thing actually wanted, and it accounts for the title bar's safe-area
        // inset without this having to know about it.
        //
        // **`.id(section)` on the content would also reset the offset**, by giving the whole subtree
        // a new identity, and it is the wrong tool for it: it re-creates every control in the pane
        // on every switch, which is a cost paid for a side effect.
        //
        // Unanimated, because a scroll the user did not perform should not look like one they did:
        // the pane is simply already at its top when it appears.
        .scrollPosition($scrollPosition)
        .onChange(of: section) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(edge: .top) }
        }
        .scrollContentBackground(.hidden)
        // **The detail column reclaims the title bar's band, and the sidebar deliberately does
        // not.** The window is `.fullSizeContentView`, so SwiftUI hands its content a top safe area
        // the height of the title bar — and `safeAreaInset` puts the header *below* that. The
        // header therefore measured 73pt from the window's top edge to its hairline, of which 28
        // were an empty strip and only 20 were the header's own padding: the pane's name sat in the
        // bottom third of a band that was mostly nothing. Reported from use as too much padding at
        // the top.
        //
        // Nothing lives in that strip on this side. `NavigationSplitView` puts the traffic lights
        // over the **sidebar**, which is at least 176pt wide, so the detail column starts well clear
        // of them — which is exactly why this is not also done to `identity`, where the app icon
        // would end up behind the close button.
        //
        // **The order of these two is the whole trick, and the other order compiles.**
        // `.ignoresSafeArea` *then* `.safeAreaInset` reads correctly and is wrong: the inset is
        // handed to a view that has already been told to ignore top insets, so the header is
        // placed and its inset is discarded — the bar draws at the top and the first card starts
        // underneath it, half a row down. Reported as the pane being "underneath the header".
        //
        // This way round, `safeAreaInset` applies to a `ScrollView` that still respects insets, so
        // the content is pushed below the bar; `ignoresSafeArea` then moves the *composite* up into
        // the title bar's band. Both things are wanted and only this order gets them.
        .safeAreaInset(edge: .top, spacing: 0) { paneHeader }
        .ignoresSafeArea(edges: .top)
        // Set once for the whole pane rather than on each `Toggle`.
        //
        // Outside a `Form`, AppKit's default toggle style is a **checkbox**, and the previous
        // version of this window got switches only because `Form` was quietly substituting them.
        // Dropping `Form` for cards therefore silently changed every switch in Isleta into a tick
        // box — which still works, still reads as "on", and is the wrong control: a checkbox says
        // "include this in something", a switch says "this is running now", and every setting here
        // is the second kind.
        .toggleStyle(.switch)
    }

    /// The bar at the top of the detail column: the pane's icon, its name, a hairline under it.
    ///
    /// ## Why there is a header here again
    ///
    /// There was one until earlier today and it was removed, because `navigationTitle` drew the
    /// pane's name in the title bar and the band of `.ultraThinMaterial` behind it — there so the
    /// cards had something to scroll under — resolved to gray over a teal window. Both halves of
    /// that are fixed rather than avoided: the name is drawn here, in the content view, where its
    /// surface is `SettingsPalette.chrome` and cannot drift toward the system's neutral; and the
    /// pane's own first card no longer repeats it.
    ///
    /// ## The parts that are load-bearing
    ///
    /// - **The fill is opaque and reaches over the title bar** via `ignoresSafeArea`. The window is
    ///   `.fullSizeContentView`, so the scroll view runs to the window's top edge; without a fill
    ///   the cards would scroll through the name, which is the collision this whole arrangement
    ///   exists to prevent. The *content* now sits in that band too rather than below it — see
    ///   `detail`, which is where that is done and why the sidebar does not do it.
    /// - **The bar's own height is the inset.** `safeAreaInset` takes it from the laid-out height,
    ///   so the first card starts below the bar rather than under it, and there is nothing
    ///   interactive beneath the fill. That is what keeps this from repeating the swallowed-click
    ///   bug the sidebar's old overhanging background caused — without `.allowsHitTesting(false)`,
    ///   a modifier this codebase has a trap about.
    /// - **The content is inset by `paneInset`, matching the cards below it**, so the icon lines up
    ///   with the left edge of every card in the pane rather than sitting on a margin of its own.
    /// - **The text is not in the title bar**, so it does not move when a toolbar appears and it is
    ///   not subject to `titleVisibility`. `SettingsWindowController` hides the window's own title
    ///   for exactly this reason — two names in one band is the thing being fixed.
    private var paneHeader: some View {
        HStack(spacing: 8) {
            SectionIcon(section: section)
            Text(section.title)
                .font(.system(.headline, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsSurface.paneInset)
        .padding(.vertical, SettingsSurface.headerPadding)
        .background {
            SettingsPalette.chrome(colorScheme)
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(SettingsPalette.hairline(colorScheme))
                        .frame(height: 1)
                }
        }
    }

    // MARK: - Panes

    /// How Isleta sits on the Mac: whether it starts, where it can be reached from, the shortcuts
    /// it has taken, the two extra surfaces, and updates.
    ///
    /// Three panes' worth of sidebar rows have collapsed into this one. The shortcut had a pane of
    /// its own through 1.1.0, and Updates had one through 2.0; neither earned it, for the reason
    /// `SettingsSection` gives — a sidebar row leading to a single card is a click spent to discover
    /// there was nothing else there.
    ///
    /// **Haptic feedback is not here any more**, and it is the one removal in this pane worth a
    /// sentence. It was a switch for a single tap as the pointer arrives, which macOS already
    /// suppresses entirely unless a finger is on the trackpad — so the honest description of the
    /// setting was "turn off a thing you only feel when you asked to feel it". Apple ships the tap
    /// and no switch for it, in System Settings ▸ Trackpad, and so does Isleta now.
    private var generalPane: some View {
        Group {
            SettingsCard(settingsText("general.startup", "Startup")) {
                launchAtLoginRow
            }

            shortcutsCard

            lockScreenCard

            // The caption carries the way back, and it names the *user's own* shortcut rather than
            // a compiled-in one — somebody who rebound it would otherwise be told to press keys
            // that do nothing. Beside the switch and not in a help article: this is the moment the
            // user is deciding, and it is the only moment the answer is worth anything.
            SettingsCard(settingsText("general.menuBar", "Menu bar")) {
                SettingsRow(caption: menuBarIconCaption) {
                    Toggle(
                        settingsText("general.menuBar.show", "Show Isleta in the menu bar"),
                        isOn: binding(\.showMenuBarIcon)
                    )
                }
            }

            softwareUpdateCard
        }
    }

    /// Every global shortcut, not just the island's.
    ///
    /// **Three rows, where 2.0 drew eight.** The five that went were each a key bound to something
    /// already one click away on an island the user had just opened — and two of them, the timer and
    /// dismiss-all, had no handler in the app shell at all, so the row recorded a keystroke that
    /// nothing listened for. See `ShortcutAction`, which is where the bar for a fourth is written
    /// down: the pointer cannot do it as well.
    ///
    /// The caption is above the list rather than under each row, because it is the same sentence
    /// three times and the rows are what a person is reading.
    ///
    /// **Clearing is a separate control, and `toggleIsland` does not get one.** Isleta has no Dock
    /// icon and its menu bar item can be hidden, so a user who has hidden the icon and cleared this
    /// shortcut has locked themselves out of the app — which is why `IsletaConfiguration.toggleHotKey`
    /// is non-optional where `Shortcuts`' subscript is optional. Everything else is reachable by
    /// opening the island and clicking, so everything else may be cleared.
    private var shortcutsCard: some View {
        SettingsCard(settingsText("general.shortcuts", "Shortcuts")) {
            SettingsRow(caption: recordingAction != nil
                        ? settingsText("general.shortcuts.recording", "Press a shortcut. Escape cancels.")
                        : settingsText("general.shortcuts.caption", """
                            Click a shortcut, then press the keys you want. They work from any app, \
                            including full screen — and each one is a key no other app on this Mac can \
                            use while Isleta is running.
                            """)) {
                EmptyView()
            }

            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsDivider() }
                LabeledContent(action.title) {
                    HStack(spacing: 6) {
                        hotKeyField(for: action)
                        clearButton(for: action)
                    }
                }
            }
        }
    }

    /// The clear button, or nothing where clearing is not allowed.
    ///
    /// Nothing rather than a disabled button for `toggleIsland`: a grayed control invites the user
    /// to work out why, and the answer — that they would lock themselves out — is not something a
    /// tooltip can carry. Nothing, too, for an action that is already unassigned, because there is
    /// nothing to clear and the button would be the "visibly does nothing" control this window
    /// avoids everywhere else.
    @ViewBuilder
    private func clearButton(for action: ShortcutAction) -> some View {
        if action != .toggleIsland, store.configuration.shortcuts[action] != nil {
            Button {
                store.update { $0.shortcuts[action] = nil }
            } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(.borderless)
            .help(settingsText("general.shortcuts.clear.help", "Clear this shortcut"))
        }
    }

    /// The lock-screen card.
    ///
    /// Off by default, and it is the one surface Isleta draws that a person is not looking at when
    /// it appears. Two things are said in the caption rather than left for the user to discover,
    /// and both are unusual enough to be worth the words:
    ///
    /// - **It cannot be operated.** loginwindow captures every event on the locked screen, so there
    ///   are no buttons on this card and there never can be. Saying so is better than a user tapping
    ///   a card that ignores them and concluding Isleta is broken.
    /// - **It shows to whoever is in the room.** That is the actual trade, and it is the reason this
    ///   is a switch rather than something Isleta just does.
    ///
    /// **One switch, where 2.0 had two.** The second governed the lock and unlock sounds, on the
    /// argument that "show me what is playing" and "make a noise" are different questions. They are,
    /// and they are not different *decisions* — see `IsletaConfiguration.showsNowPlayingOnLockScreen`.
    /// The caption names the sound so a user knows what they are agreeing to before they hear it in
    /// a meeting.
    ///
    /// What is deliberately *not* said is anything about SkyLight or space levels. The user is
    /// choosing a feature, not auditing an implementation, and `docs/NAMING.md` is explicit that a
    /// setting is named for what it does.
    @ViewBuilder
    private var lockScreenCard: some View {
        SettingsCard(settingsText("general.lockScreen", "Lock Screen")) {
            SettingsRow(caption: settingsText("general.lockScreen.caption", """
                What is playing, on the Lock Screen, while you are away from the Mac. It shows the \
                artwork, the track and how far through it is — it has no buttons, because macOS does \
                not let anything but the password field be tapped there. Anyone who walks past the \
                Mac can see what you are listening to, and coming back plays a short sound of \
                macOS's own.
                """)) {
                Toggle(
                    settingsText("general.lockScreen.show", "Show what is playing on the Lock Screen"),
                    isOn: Binding(
                        get: { store.configuration.showsNowPlayingOnLockScreen },
                        set: { newValue in
                            store.update { $0.showsNowPlayingOnLockScreen = newValue }
                        }
                    )
                )
            }
        }
    }

    /// Says what the switch costs and what still works, and changes when it is off.
    ///
    /// Two captions rather than one that covers both states. A single sentence hedged to be true
    /// either way ("you can also use the shortcut") reads as filler while the icon is there and as
    /// an afterthought once it is gone, which is precisely when it is load-bearing.
    private var menuBarIconCaption: String {
        let shortcut = store.configuration.toggleHotKey.displayString
        return store.configuration.showMenuBarIcon
            ? settingsText("general.menuBar.caption.shown", """
                Isleta has no Dock icon, so this is how you reach Settings, the Setup Guide and Quit. \
                Turn it off and \(shortcut) opens the island instead, where the same things are one \
                click away.
                """)
            : settingsText("general.menuBar.caption.hidden", """
                The icon is hidden. \(shortcut) opens the island from any app, and Settings is one \
                click away inside it.
                """)
    }

    // MARK: - Staying out of the way

    /// The apps Isleta does not speak over, and the display it does not draw on unasked.
    ///
    /// **In Sources, where it reads as a rule about when Isleta speaks.** It was the last card of an
    /// Appearance pane through 2.0, which was the wrong shelf for it twice over: hiding the island
    /// while Keynote is in front is not a *look*, and the pane it was in has gone. Every other card
    /// in this pane answers "what may the island say", and so does this one — it is the same question
    /// asked about a moment rather than about a source.
    private var hiddenApplicationsCard: some View {
        SettingsCard(settingsText("sources.quiet", "Staying out of the way")) {
            SettingsRow(caption: hiddenApplicationsCaption) {
                Button(settingsText("sources.quiet.add", "Add App…")) { addHiddenApplication() }
                    .buttonStyle(.glass)
            }

            if !store.configuration.hiddenApplications.isEmpty {
                SettingsDivider()
                hiddenApplicationList
            }

            // Only where there is a synthesized island for it to apply to. A switch that provably
            // does nothing on the hardware reading it is the thing §10 objects to about permissions.
            if showsSynthesizedSettings {
                SettingsDivider()
                SettingsRow(caption: settingsText("sources.quiet.minimal.caption", """
                    On a Mac with no notch, the island is a pill floating below the menu bar all \
                    day. This hides it until something is happening or the pointer arrives — which \
                    is how a real cutout already behaves, because at rest it *is* the cutout.
                    """)) {
                    Toggle(
                        settingsText("sources.quiet.minimal", "Hide the island on displays without a notch"),
                        isOn: binding(\.minimalOnSynthesizedDisplays)
                    )
                }
            }
        }
    }

    private var hiddenApplicationsCaption: String {
        store.configuration.hiddenApplications.isEmpty
            ? settingsText("sources.quiet.caption.empty", """
                Apps you would rather Isleta stayed out of. While one of them is in front, the island \
                is not drawn and does not take clicks; it comes back the moment you switch away.
                """)
            : settingsText("sources.quiet.caption", """
                While one of these is in front, the island is not drawn and does not take clicks. It \
                comes back the moment you switch away.
                """)
    }

    /// The list, one row per app, with the app's own icon and name resolved from disk.
    ///
    /// Bundle identifiers are what is stored — see `IsletaConfiguration.hiddenApplications` — and a
    /// row for an app that has since been deleted still has to be removable, so the identifier is
    /// the fallback label rather than the row being dropped. A list that quietly forgets entries
    /// when a disk is unplugged is a list nobody can trust.
    private var hiddenApplicationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.configuration.hiddenApplications, id: \.self) { identifier in
                HStack(spacing: 8) {
                    HiddenApplicationLabel(bundleIdentifier: identifier)
                    Spacer(minLength: 0)
                    Button {
                        removeHiddenApplication(identifier)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(settingsText(
                        "sources.quiet.remove.a11y",
                        "Stop hiding the island in this app"
                    ))
                }
            }
        }
    }

    /// Picks an app with the system's own open panel.
    ///
    /// An `NSOpenPanel` rather than a list of running applications, and the difference matters: the
    /// apps somebody wants Isleta to stay out of are the ones they use full screen, which is exactly
    /// when they are *not* running beside a settings window. A picker that only offered what happens
    /// to be open would be missing the entries the feature exists for.
    private func addHiddenApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = settingsText("sources.quiet.panel.prompt", "Add")
        panel.message = settingsText(
            "sources.quiet.panel.message",
            "Choose apps Isleta should stay out of the way of."
        )
        guard panel.runModal() == .OK else { return }

        let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !identifiers.isEmpty else { return }
        store.update { configuration in
            var list = configuration.hiddenApplications
            // Appended rather than inserted, and de-duplicated: adding an app twice is a list with a
            // row the user cannot tell from its twin and a remove button that appears to do nothing.
            for identifier in identifiers where !list.contains(identifier) {
                list.append(identifier)
            }
            configuration.hiddenApplications = list
        }
    }

    private func removeHiddenApplication(_ identifier: String) {
        store.update { configuration in
            configuration.hiddenApplications.removeAll { $0 == identifier }
        }
    }

    /// Every source in one card, rather than one card each.
    ///
    /// The previous shape gave each source a titled card *and* a toggle labeled with the same
    /// words, so "Now Playing" was on screen twice, four rows running. The card title was the
    /// redundant half — a switch has to be labeled, a group of one does not have to be named — and
    /// four groups of one were never groups. What is left is the shape the rest of this window
    /// already uses: one card, a divider between rows.
    /// The sources, and the four things about them that are not sources.
    ///
    /// The first card is one row per running `ActivitySource`. Three of the others exist because
    /// `SourceSettingsRow` is keyed on `ActivityKind` and none of them is a kind that publishes —
    /// see `SourcesPaneState`, which is where each is argued. The fourth, `hiddenApplicationsCard`,
    /// arrived from the Appearance pane when schema 18 removed it. They are here rather than in
    /// panes of their own because `SettingsSection` sets the bar for a sidebar row at more than one
    /// card, and because all four answer "what may the island say", which is what this pane is.
    private var sourcesPane: some View {
        Group {
            // No title on this card. The pane header two points above it already says "Sources",
            // and a heading that repeats the header is the duplication the header was reinstated
            // without. The three cards below it keep theirs, because they name a subject the header
            // does not.
            SettingsCard {
                if rows.isEmpty {
                    Text(settingsText("sources.empty", "No sources are running in this build."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        sourceRow(row)
                    }
                }
            }

            focusCard
            hiddenApplicationsCard
        }
    }

    // MARK: - Focus

    /// The switch that decides whether a Focus quiets the island, and the permission that makes it
    /// mean anything.
    ///
    /// **The switch is live in every permission state and that is deliberate.** It is a statement
    /// about what this user wants, which is true of them whether or not `INFocusStatusCenter` will
    /// answer — and graying it would make a permanent-looking claim about a grant they can give in
    /// the next thirty seconds. The caption is what changes; see `SourcesPaneState.focusSummary`,
    /// which has a sentence for all four states including the one where the build itself cannot ask.
    private var focusCard: some View {
        SettingsCard(settingsText("sources.focus", "Focus")) {
            SettingsRow(caption: sources.focusSummary) {
                Toggle(
                    settingsText("sources.focus.respect", "Stay quiet while a Focus is on"),
                    isOn: binding(\.sources.respectsFocus)
                )
            }

            focusPermissionControl
        }
    }

    /// §10, the same three-way as the calendar's: the prompt where one would show, the deep link
    /// where macOS will not ask again, and nothing at all otherwise — including `unavailable`, where
    /// there is no row in System Settings to send anybody to.
    @ViewBuilder
    private var focusPermissionControl: some View {
        switch sources.focusAccess {
        case .notDetermined:
            if let ask = sources.requestFocusAccess {
                Button(settingsText("sources.focus.allow", "Allow Focus Access…")) {
                    ask()
                    refresh()
                }
                .buttonStyle(.glass)
            }
        case .denied:
            if let open = sources.openPrivacySettings {
                Button(settingsText("permission.openSystemSettings", "Open System Settings…")) { open(.focus) }
                    .buttonStyle(.glass)
            }
        case .granted, .unavailable:
            EmptyView()
        }
    }

    // MARK: - Glance

    /// Which calendars, and where.
    ///
    /// Two cards, which is what earns this a sidebar row of its own — `SettingsSection`'s note is
    /// explicit that a pane with one card in it belongs inside an existing pane instead. They are
    /// grouped by what the user is deciding rather than by which framework answers: what the island
    /// may read, and where it asks about.
    ///
    /// **Celsius or Fahrenheit was the third card**, and it is System Settings ▸ General ▸ Language
    /// & Region ▸ Temperature now — read through `TemperatureUnit.fromLocale()`. It is a question
    /// macOS asks once for the whole machine, and answering it a second time here meant a user could
    /// have Isleta disagreeing with every other app they own about what a degree is.
    ///
    /// Every control here writes through `SettingsStore` like every other pane, which is what makes
    /// "Reset to Defaults" reach the glance. It did not, for one release: the record was parked on
    /// its own `UserDefaults` key while Stage 1 was built beside three other agents, and
    /// `SettingsMigration.migrateV7ToV8` is what brought it home.
    private var glancePane: some View {
        Group {
            SettingsCard(settingsText("glance.calendars", "Calendars")) {
                SettingsRow(caption: glance.calendarSummary) {
                    calendarPermissionControl
                }

                if glance.calendarAccess == .granted, !glance.calendars.isEmpty {
                    SettingsDivider()
                    calendarList
                }
            }

            SettingsCard(settingsText("glance.weather", "Weather")) {
                // Whether weather can be expected on this build at all — the entitlement, the
                // provider, the refusal. It leads the card because it is the sentence that explains
                // an empty weather island, and no control below it can.
                SettingsRow(caption: glance.weatherSummary) {
                    EmptyView()
                }

                SettingsDivider()

                // The second sentence is the whole caption. Without it the switch reads as though
                // turning location off turns the weather off, and it does not — see SettingsText.
                SettingsRow(caption: settingsText("glance.where.caption", """
                    The weather works either way. With location off, Isleta asks about the city you \
                    type instead of the one you are in — nothing else changes.
                    """)) {
                    Toggle(
                        settingsText("glance.where.useLocation", "Use my location"),
                        isOn: useCurrentLocationBinding
                    )
                }

                locationPermissionControl

                if !usesCurrentLocation {
                    SettingsDivider()
                    cityRow
                }
            }
        }
    }

    // MARK: - The city, and the places it could mean

    /// The field, and the list of real places under it.
    ///
    /// # Why a search and not a text field
    ///
    /// The field shipped as a plain one, and every way of getting it wrong looked identical: a typo,
    /// a place that does not exist, and the right city spelled the way another country spells it all
    /// produce a glance with no weather on it and nothing anywhere saying why — fifteen minutes
    /// later, in a window the user has long since closed. Offering real places while they type
    /// replaces a silent failure with a choice, and it is the *only* correction available here,
    /// because the geocode that fails happens on a timer somewhere else entirely.
    ///
    /// # The field still writes on every keystroke
    ///
    /// Deliberately unchanged. The stored value is what the weather is asked about, and a field that
    /// only committed on Return or on a chosen suggestion would silently discard a city somebody
    /// typed correctly and then clicked away from. The suggestions are an *offer* laid over a field
    /// that already worked, not a gate in front of it — which is also what keeps this pane honest in
    /// a build where `searchCities` is nil.
    ///
    /// # Nothing is asked for on the first letter
    ///
    /// `.task(id:)` restarts on every change to the query and cancels the task it replaces, so the
    /// sleep below is a debounce with no timer, no bookkeeping and no way to leak one: the letters a
    /// person types inside a quarter of a second cost one search between them, not one each.
    private var cityRow: some View {
        SettingsRow(caption: settingsText("glance.where.city.caption", """
            Start typing and pick your city from the list. Looked up once and remembered — a city \
            does not move, so Isleta only asks again if you change it.
            """)) {
            VStack(alignment: .leading, spacing: 6) {
                // The placeholder is an *example* of a city rather than a city the user has, so it
                // is localized — a French reader shown "London" reads a value, not an example. What
                // the user types is theirs and is never translated.
                TextField(
                    settingsText("glance.where.city", "City"),
                    text: glanceBinding(\.city),
                    prompt: Text(settingsText("glance.where.city.example", "London"))
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .focused($cityFieldIsFocused)
                    .onSubmit { dismissCitySuggestions() }
                    .onChange(of: cityFieldIsFocused) { _, focused in
                        // Leaving the field takes the list with it, and stops whatever round is
                        // outstanding — a completer left holding a query nobody is reading the
                        // answer to is the one thing this file must not leave behind (§9).
                        if !focused { dismissCitySuggestions() }
                    }

                if cityFieldIsFocused, !citySuggestions.isEmpty {
                    citySuggestionList
                }
            }
            .task(id: cityQuery) {
                await refreshCitySuggestions()
            }
        }
    }

    /// What the search is currently about. A computed value rather than a second `@State`, so it
    /// cannot disagree with the field: `.task(id:)` restarts precisely when this changes.
    private var cityQuery: String {
        store.configuration.glance.city
    }

    private var citySuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(citySuggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 { Divider().opacity(0.3) }
                Button {
                    choose(suggestion)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(suggestion.name)
                            .font(.callout)
                        if !suggestion.region.isEmpty {
                            // The region is what tells eleven Springfields apart, and it is
                            // secondary because the name is what the user is looking for. Truncated
                            // rather than wrapped: a two-line row in a five-row list would make the
                            // card's height depend on how far away somebody lives.
                            Text(suggestion.region)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(suggestion.searchText)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        // A hierarchical fill and not a color. `.quaternary` resolves against the window's own
        // appearance and against the glass behind it; a literal gray would be the mistake this
        // window has already made once — an explicit color blocks the vibrancy that makes a card
        // legible in both appearances.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
        )
        .accessibilityLabel(settingsText("glance.where.city.suggestions", "Matching cities"))
    }

    /// Chosen from the list: the full "London, England" goes into the setting, not the bare name.
    ///
    /// The pair is what makes the answer unambiguous — see `CitySuggestion.searchText` — and storing
    /// only the half the user reads would hand the geocoder back exactly the ambiguity the list
    /// existed to resolve.
    private func choose(_ suggestion: CitySuggestion) {
        chosenCity = suggestion.searchText
        store.update { $0.glance.city = suggestion.searchText }
        dismissCitySuggestions()
    }

    private func dismissCitySuggestions() {
        citySuggestions = []
        glance.cancelCitySearch?()
    }

    /// One round of suggestions, after a pause and only if anybody is still asking.
    ///
    /// Every guard here answers a state that is normal rather than exceptional: a build with no
    /// source hub (`searchCities` nil, and every preview), a field nobody is typing in, a query too
    /// short to mean anything, and the string the user has just chosen from this very list.
    private func refreshCitySuggestions() async {
        let query = cityQuery
        guard let search = glance.searchCities,
              cityFieldIsFocused,
              query != chosenCity,
              CityQuery.isSearchable(query)
        else {
            citySuggestions = []
            return
        }
        // The debounce. Canceled — and therefore skipped — the moment another letter arrives,
        // because `.task(id:)` tears this task down when the query changes.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let results = await search(query)
        guard !Task.isCancelled else { return }
        citySuggestions = results
    }

    /// The one offer, and only in the one state where a prompt would show.
    ///
    /// §10, twice over: `.notDetermined` gets the button that raises the real dialog, `.denied` gets
    /// the deep link because macOS will not show the dialog a second time, and everything else gets
    /// nothing at all rather than a control that visibly does nothing.
    @ViewBuilder
    private var calendarPermissionControl: some View {
        switch glance.calendarAccess {
        case .notDetermined:
            if let ask = glance.requestCalendarAccess {
                Button(settingsText("glance.calendars.allow", "Allow Calendar Access…")) {
                    ask()
                    refresh()
                }
                .buttonStyle(.glass)
            }
        case .denied, .restricted, .writeOnly:
            if let open = glance.openPrivacySettings {
                Button(settingsText("permission.openSystemSettings", "Open System Settings…")) { open(.calendars) }
                    .buttonStyle(.glass)
            }
        case .granted:
            Label(settingsText("sources.status.granted", "Granted"), systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What the user has actually got, which is not the same as what they have asked for.
    ///
    /// The stored flag is an *intention* and this is the *fact*: CoreLocation can be refused, and it
    /// can be revoked in System Settings long after somebody set this. Everything on this card reads
    /// the fact, so a switch is never on for a permission that is not there.
    private var usesCurrentLocation: Bool {
        store.configuration.glance.usesCurrentLocation && glance.locationAccess == .granted
    }

    /// "Use my location", which asks rather than assumes.
    ///
    /// **The switch does not move until the grant is real.** It used to be a plain binding onto the
    /// stored flag, with an "Allow Location…" button underneath it — so the default state of a new
    /// install was a switch reading *on* over a permission nobody had been asked for, and a weather
    /// island that silently resolved no place at all. A switch that is on for something that is not
    /// happening is the one thing a settings window must never draw.
    ///
    /// So switching it on is what raises the dialog, and the answer decides where the switch lands:
    ///
    /// - **Granted** — stored on, which is also the only state where `get` can answer true.
    /// - **Not determined** — one request, and the switch moves when CoreLocation says it may. The
    ///   answer comes back through `GlanceSettingsState.requestLocationAccess`, because the dialog
    ///   is answered outside this window and this pane's snapshot is refreshed when Isleta comes
    ///   back to the front.
    /// - **Refused or restricted** — the switch stays where it was, and `locationRefusalIsShown`
    ///   puts the way to System Settings under it. Nothing is stored: a flag set true against a
    ///   refusal would be a preference nothing could honor.
    ///
    /// Switching it off stores false and nothing else. The typed city is left alone — clearing
    /// somebody's city because they turned location off is a second decision they did not make.
    private var useCurrentLocationBinding: Binding<Bool> {
        Binding(
            get: { usesCurrentLocation },
            set: { wantsLocation in
                guard wantsLocation else {
                    locationRefusalIsShown = false
                    store.update { $0.glance.usesCurrentLocation = false }
                    return
                }
                switch glance.locationAccess {
                case .granted:
                    locationRefusalIsShown = false
                    store.update { $0.glance.usesCurrentLocation = true }
                case .notDetermined:
                    guard let ask = glance.requestLocationAccess else { return }
                    ask { answer in
                        if answer == .granted {
                            store.update { $0.glance.usesCurrentLocation = true }
                        } else {
                            locationRefusalIsShown = answer == .denied || answer == .restricted
                        }
                        // The whole snapshot, not just the one field: the summary sentence above the
                        // switch is chosen from `locationAccess` too.
                        refresh()
                    }
                case .denied, .restricted:
                    locationRefusalIsShown = true
                }
            }
        )
    }

    /// The way out of a refusal, shown only to somebody who has just run into one.
    ///
    /// Not drawn from `locationAccess` alone, which would put a warning under the switch of every
    /// user who refused location once and has been happily typing a city ever since — §10's "no
    /// nagging". It appears when the user reaches for the switch and the system will not let it
    /// move, which is the one moment the sentence explains something they are looking at.
    @ViewBuilder
    private var locationPermissionControl: some View {
        if locationRefusalIsShown, glance.locationAccess == .denied || glance.locationAccess == .restricted {
            SettingsRow(caption: settingsText("glance.where.refused", """
                macOS is not letting Isleta have your location, so the switch cannot move. Turning \
                Isleta on in Location Services is what changes that — or type a city below, which \
                works just as well.
                """)) {
                if let open = glance.openPrivacySettings {
                    Button(settingsText("permission.openSystemSettings", "Open System Settings…")) { open(.location) }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    /// The include-list.
    ///
    /// Checkboxes rather than switches, and this is the one place in the window that is right —
    /// CLAUDE.md's rule is that a checkbox says "include this in something" and a switch says "this
    /// is running now", and these are literally the first. `.toggleStyle(.checkbox)` overrides the
    /// pane-wide `.switch` for exactly this card.
    ///
    /// **Nothing selected means everything shown**, which is what the caption above has to say and
    /// what the empty-list state is: it is what every user has before they first come here, and a
    /// glance that showed nothing until somebody had visited Settings would look broken to everyone
    /// who never does.
    private var calendarList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(glance.calendars) { calendar in
                Toggle(isOn: calendarBinding(calendar.id)) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(calendar.tint.map {
                                Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1)
                            } ?? Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(calendar.title)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    /// A calendar's checkbox.
    ///
    /// Unticking the last one clears the set rather than storing an empty include-list, so "none
    /// picked" and "all picked" collapse to the same stored value — which is the same thing they
    /// mean. Without that, unticking everything would produce a glance that shows nothing at all,
    /// with no sentence anywhere to explain it.
    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                let selected = store.configuration.glance.includedCalendarIDs
                return selected.isEmpty || selected.contains(id)
            },
            set: { included in
                store.update { configuration in
                    var settings = configuration.glance
                    defer { configuration.glance = settings }
                    var selected = settings.includedCalendarIDs
                    if selected.isEmpty {
                        // The first tick is really an *un*tick: every calendar was shown, so what
                        // the user just did was take one away.
                        selected = Set(glance.calendars.map(\.id))
                    }
                    if included { selected.insert(id) } else { selected.remove(id) }
                    settings.includedCalendarIDs =
                        selected.count == glance.calendars.count ? [] : selected
                }
            }
        )
    }

    /// Reads and writes the glance through `SettingsStore`, which is what makes "Reset to Defaults"
    /// reach it. It was parked on its own `UserDefaults` key for one release — see
    /// `SettingsMigration.migrateV7ToV8` — and this is the whole of what that parking cost.
    private func glanceBinding<Value>(_ keyPath: WritableKeyPath<GlanceSettings, Value>) -> Binding<Value> {
        // Composed explicitly rather than with `appending(path:)`, which erases a
        // `WritableKeyPath` to a read-only `KeyPath` when the roots differ.
        Binding(
            get: { store.configuration.glance[keyPath: keyPath] },
            set: { newValue in store.update { $0.glance[keyPath: keyPath] = newValue } }
        )
    }

    /// Software update — one switch and one button, in General.
    ///
    /// It had a sidebar row of its own through 2.0 and did not clear the bar `SettingsSection` sets:
    /// two controls behind a click, on a pane a user visits when they already suspect there is a
    /// newer version. It sits last in General, after the surfaces, because it is the card people
    /// look for deliberately rather than land on.
    private var softwareUpdateCard: some View {
        // Asked once per redraw, and every control below reads that one answer. Asking the updater
        // separately per control is how a disabled toggle ends up beside a live button.
        let updates = UpdatesSectionState(canCheckForUpdates: updater.canCheckForUpdates)
        return SettingsCard(settingsText("updates.card", "Software update")) {
            SettingsRow(caption: updates.unavailableReason
                        ?? settingsText("updates.caption", """
                            Isleta checks quietly in the background and never interrupts you to do it.
                            """)) {
                Toggle(
                    settingsText("updates.automatic", "Check for updates automatically"),
                    isOn: binding(\.automaticUpdateChecks)
                )
                .disabled(!updates.isEnabled)
            }

            Button(settingsText("updates.checkNow", "Check Now")) { updater.checkForUpdates() }
                .buttonStyle(.glass)
                .disabled(!updates.isEnabled)
        }
    }

    private var aboutPane: some View {
        Group {
            SettingsCard {
                HStack(spacing: 16) {
                    AppIconView(size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppVersion.name).font(.system(.title2, weight: .semibold))
                        Text(AppVersion.settingsSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                        Text(settingsText("about.tagline", "The notch, made useful."))
                            .font(.callout)

                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            AcknowledgementsCard()

            reopenAndQuitCard

            diagnosticsCard

            SettingsCard(settingsText("about.reset", "Start over")) {
                if let failure = store.loadFailure {
                    // Only the sentence is ours. `failure` is whatever Foundation's decoder said,
                    // which macOS has already localized as far as it is going to — translating it
                    // here would mean re-translating an error string we did not write.
                    Label(
                        settingsText("about.reset.loadFailure", """
                            Your saved settings could not be read, so these are the defaults. (\(failure))
                            """),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                SettingsRow(caption: settingsText("about.reset.caption", """
                    Puts every setting on every pane back to the shipped default. It does not touch \
                    permissions you have granted in System Settings.
                    """)) {
                    // Tinted explicitly rather than left to `role: .destructive`. On a glass button
                    // the role alone changes almost nothing visible — the red it would normally
                    // apply to the label is competing with a translucent surface over a teal
                    // backdrop — so the only thing marking the one irreversible control in this
                    // window would be its wording.
                    Button(settingsText("about.reset.button", "Reset to Defaults"), role: .destructive) {
                        store.resetToDefaults()
                    }
                        .buttonStyle(.glass(.regular.tint(.red).interactive()))
                }
            }
        }
    }

    /// "Export Logs…", in the window as well as in the menu.
    ///
    /// It lived only on the status item until the menu bar icon became something a user can turn
    /// off — at which point the one thing a person is asked for in a bug report was reachable only
    /// from an icon they had hidden. It sits in About rather than in a pane of its own because a
    /// sidebar row leading to one button is a click spent to discover there was nothing else there
    /// (see `SettingsSection`), and in About specifically because the version number a bug report
    /// also wants is already on this pane.
    ///
    /// Not marked destructive and not warned about: it writes one file where the user chooses.
    /// What the caption has to say instead is what is *in* it, because the answer to "will this
    /// send Apple my notifications" is no and nobody can tell that from a button.
    @ViewBuilder
    private var diagnosticsCard: some View {
        if let exportLogs {
            SettingsCard(settingsText("about.diagnostics", "Diagnostics")) {
                SettingsRow(caption: settingsText("about.diagnostics.caption", """
                    Saves one text file — what Isleta can see on this Mac, and its recent log. It holds \
                    no notification text, track titles or file names, so it is safe to attach to a bug \
                    report.
                    """)) {
                    Button(settingsText("menu.exportLogs", "Export Logs…")) { exportLogs() }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    /// Reopening the first run, and quitting.
    ///
    /// **The two things that were reachable only from the status-item menu.** That menu can be
    /// switched off — `showMenuBarIcon`, 1.2.0 — and the rule 1.3.1 wrote down is that nothing may
    /// be reachable only from there. These were the two rows still breaking it, and Quit is the
    /// serious one: a user who hid the icon had no way to stop Isleta short of Activity Monitor.
    ///
    /// Last in the pane, because About is where the destructive things live and quitting is the
    /// most destructive thing in the window. Not a confirmation dialog: quitting Isleta loses
    /// nothing a user would miss — the shelf persists, the settings are written on every change,
    /// and nothing here outlives the session by design. A sheet here would be ceremony over a
    /// reversible act.
    @ViewBuilder
    private var reopenAndQuitCard: some View {
        if openSetupGuide != nil || quit != nil {
            // Not looked up: "Isleta" is the product's name, and §3(c) keeps proper nouns verbatim.
            SettingsCard("Isleta") {
                if let openSetupGuide {
                    SettingsRow(caption: settingsText("about.setupGuide.caption", """
                        The four pages you saw the first time. It explains where the island is, what it \
                        can show you, and which permissions unlock what — worth a second look after you \
                        have used it for a while.
                        """)) {
                        Button(settingsText("menu.openSetupGuide", "Open Setup Guide")) { openSetupGuide() }
                            .buttonStyle(.glass)
                    }
                }

                if let quit {
                    if openSetupGuide != nil { SettingsDivider() }
                    SettingsRow(caption: settingsText("about.quit.caption", """
                        Isleta stops until you open it again. It has no Dock icon, so this and the menu \
                        bar item are the two ways out — and the menu bar item is one you can switch off.
                        """)) {
                        Button(settingsText("menu.quit", "Quit Isleta")) { quit() }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
    }


    // MARK: - Rows

    /// One source: a switch, what it does, and what it is currently able to do.
    ///
    /// The switch is **not** disabled when the permission is missing. A source the user has turned
    /// on and not yet granted is a source that does nothing and says so — turning it off has to stay
    /// available so somebody who has decided against a feature can stop being shown a row about it,
    /// which is the "no nagging" half of §10.
    ///
    /// One `VStack`, not two siblings. Now that the four sources share a card, the card's own 14pt
    /// spacing runs between every view it is handed — so a switch, its caption and its status line
    /// as three siblings read as three separate settings rather than as one source with something
    /// to say about itself. The status belongs to the row above it and is spaced like it.
    private func sourceRow(_ row: SourceSettingsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(caption: row.summary) {
                if let toggle = row.toggle {
                    Toggle(row.title, isOn: binding(toggle))
                } else {
                    Text(row.title)
                }
            }

            statusLine(row)

            if !row.options.isEmpty {
                sourceOptions(row)
            }
        }
    }

    /// The finer switches inside one source, under its status line.
    ///
    /// **Below the status rather than between it and the caption**, because the order is the order a
    /// user asks the questions in: what is this, does it work here, which parts do I want. Indented,
    /// because a switch at the card's own left margin is a sibling of the source above it — which is
    /// exactly what these are not, and there is no divider to say otherwise.
    ///
    /// Disabled while the master switch is off. They are not *hidden* there: a user who has just
    /// turned the source off and is looking for the keyboard backlight needs to see that the switch
    /// exists and where it went, and a control that vanishes reads as one that was never there.
    @ViewBuilder
    private func sourceOptions(_ row: SourceSettingsRow) -> some View {
        let isSourceOn = row.toggle.map { store.configuration[keyPath: $0] } ?? true
        VStack(alignment: .leading, spacing: 6) {
            ForEach(row.options) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(option.title, isOn: binding(option.toggle))
                        .controlSize(.small)
                        // Two reasons, one control: the source is off, so this governs nothing; or
                        // this Mac cannot produce the level at all, and the sentence below says so.
                        .disabled(!isSourceOn || option.unavailable != nil)

                    if let unavailable = option.unavailable {
                        Text(unavailable)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Nested under the level it governs, one switch each. **Not one switch for
                    // both**: volume is recoverable if Isleta gets it wrong — the slider is in
                    // Control Center — and brightness is the one that leaves somebody unable to dim
                    // their screen. A single control would make accepting the cheaper risk mean
                    // accepting the dearer one. See `IsletaConfiguration.suppressBrightnessHUD`.
                    if option.id == SystemHUD.volume.rawValue {
                        replaceHUDToggle(
                            isSourceOn: isSourceOn,
                            binding: binding(\IsletaConfiguration.suppressSystemHUDs),
                            title: settingsText("sources.systemHUD.replace", "Replace the system volume HUD"),
                            caption: settingsText(
                                "sources.systemHUD.replace.caption",
                                """
                                Isleta answers the volume and mute keys itself, so macOS never shows its own HUD. \
                                Needs Accessibility. Quitting Isleta gives the keys straight back.
                                """
                            )
                        )
                    }
                    if option.id == SystemHUD.brightness.rawValue {
                        replaceHUDToggle(
                            isSourceOn: isSourceOn,
                            binding: binding(\IsletaConfiguration.suppressBrightnessHUD),
                            title: settingsText("sources.systemHUD.replaceBrightness", "Replace the system brightness HUD"),
                            caption: settingsText(
                                "sources.systemHUD.replaceBrightness.caption",
                                """
                                Isleta answers the brightness keys itself for the built-in display. \
                                Needs Accessibility. Quitting Isleta gives the keys straight back.
                                """
                            )
                        )
                    }
                }
            }
        }
        .padding(.leading, 18)
    }

    /// A switch that hands Isleta one family of level keys.
    ///
    /// **The only controls in Isleta that take something away from the rest of the Mac**, so they say
    /// so rather than being phrased as features: turning one on means those keys stop reaching macOS
    /// and Isleta answers them instead. Off by default (CLAUDE.md), and every caption names the
    /// permission — without Accessibility the switch would move and nothing would happen, because the
    /// tap receives nothing at all, which is a silence the user would otherwise have to diagnose.
    ///
    /// One function taking its title and binding rather than two hand-built stacks, for
    /// `OnboardingPermissionPage`'s reason: two copies drift, and a switch that takes a key away is
    /// the last place a caption should quietly stop matching its control.
    @ViewBuilder
    private func replaceHUDToggle(
        isSourceOn: Bool,
        binding: Binding<Bool>,
        title: String,
        caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: binding)
                .controlSize(.small)
                .disabled(!isSourceOn)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func statusLine(_ row: SourceSettingsRow) -> some View {
        // Shared with the first-run flow rather than drawn twice — see `SourceStatusLabel`, which
        // is also where the one prompt-raising button in Isleta lives.
        SourceStatusLabel(row: row) { refresh() }
    }

    @ViewBuilder
    private var launchAtLoginRow: some View {
        SettingsRow(caption: launchCaption) {
            Toggle(settingsText("startup.launchAtLogin", "Launch Isleta at login"), isOn: Binding(
                // Read from the cached system answer rather than asking `SMAppService` here: `body`
                // runs on every redraw, and `status` is a round trip to launchd.
                get: { launchState == .enabled || launchState == .requiresApproval },
                set: { setLaunchAtLogin($0) }
            ))
        }

        if launchState == .requiresApproval {
            Button(settingsText("startup.openLoginItems", "Open Login Items")) { LaunchAtLogin.openSystemSettings() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }

        if let launchError {
            Text(launchError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var launchCaption: String {
        switch launchState {
        case .requiresApproval:
            settingsText("startup.awaitingApproval", "Waiting for your approval in System Settings.")
        case .enabled, .disabled:
            settingsText("startup.caption", """
                Isleta has no Dock icon, so it starts out of sight and stays there until you need it.
                """)
        }
    }

    @ViewBuilder
    private func hotKeyField(for action: ShortcutAction) -> some View {
        let isRecording = recordingAction == action && recorder?.isRecording == true
        Button {
            if isRecording {
                cancelRecording()
            } else {
                startRecording(for: action)
            }
        } label: {
            Text(shortcutLabel(for: action, isRecording: isRecording))
                .monospaced()
                .frame(minWidth: 108)
        }
        // Tinted while listening, so a field that is waiting for keys does not look like a field
        // that is merely showing them. `.interactive()` is what gives the glass its press response;
        // on a control the user is about to type into, that response is the confirmation the click
        // landed.
        .buttonStyle(.glass(isRecording ? .regular.tint(.accentColor).interactive() : .regular.interactive()))
    }

    /// While recording, the field shows the modifiers as they are held down. Showing the old
    /// shortcut instead would leave the user with no sign that anything is listening until the
    /// moment it stops.
    ///
    /// An unassigned action reads "Not set" rather than an empty field, which would look like a
    /// control that had failed to draw.
    private func shortcutLabel(for action: ShortcutAction, isRecording: Bool) -> String {
        guard isRecording, let recorder else {
            return store.configuration.shortcuts[action]?.displayString
                ?? settingsText("general.shortcuts.notSet", "Not set")
        }
        let held = HotKeyBinding.modifierGlyphs(HotKeyBinding.carbonModifiers(from: recorder.pendingModifiers))
        // The `held + "…"` branch is glyphs and an ellipsis, in every language.
        return held.isEmpty ? settingsText("general.shortcuts.pressKeys", "Press keys…") : held + "…"
    }

    // MARK: - Actions

    /// One recorder at a time, and starting a second cancels the first.
    ///
    /// The monitor is local and swallows the events it takes, so two live recorders would both
    /// consume the same keystroke and the second field would record a shortcut the first had already
    /// claimed. Canceling first is what makes clicking straight from one row to another do the
    /// obvious thing.
    private func startRecording(for action: ShortcutAction) {
        cancelRecording()
        let recorder = HotKeyRecorder { binding in
            store.update { $0.shortcuts[action] = binding }
            recordingAction = nil
        }
        self.recorder = recorder
        recordingAction = action
        recorder.begin()
    }

    private func cancelRecording() {
        recorder?.cancel()
        recorder = nil
        recordingAction = nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            // Not every throw is worth a red line: "already registered" and "job not found" are the
            // system and Isleta agreeing about where the switch ended up, and re-reading `state`
            // below is the whole correction they need.
            launchError = LaunchAtLogin.explanation(for: error, enabling: enabled)
        }
        launchState = LaunchAtLogin.state
    }

    // MARK: - Bindings

    /// Reads from the store and writes through it — never through a `@State` copy. See the type's
    /// note on why a mirrored toggle drifts.
    ///
    /// This is also what makes the sliders safe. A drag writes on every frame, and `update` compares
    /// before it persists and before it notifies, so the frames that land on the value already
    /// stored cost nothing — and the clamping in `IsletaConfiguration` runs on every write rather
    /// than on the ones a `Slider` happens to produce.
    private func binding<Value>(_ keyPath: WritableKeyPath<IsletaConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration[keyPath: keyPath] },
            set: { newValue in store.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// One row of the hide-in-app list: an app's own icon and name, resolved from its bundle identifier.
///
/// Its own view rather than a function on `SettingsView`, so the two disk reads happen once when the
/// row appears rather than on every redraw of the pane — `body` there runs once per frame while a
/// slider is being dragged, and `urlForApplication(withBundleIdentifier:)` is a Launch Services
/// round trip.
///
/// The identifier is the fallback label rather than a reason to drop the row. An app that has been
/// deleted, or lives on a disk that is not mounted, still has an entry the user has to be able to
/// remove — and a list that quietly forgets what it was told is worse than one that shows a name
/// nobody recognizes.
struct HiddenApplicationLabel: View {

    let bundleIdentifier: String

    /// Resolved once, when the row appears. Not `@State` derived in `body`.
    @State private var resolved: (icon: NSImage, name: String)?

    var body: some View {
        HStack(spacing: 8) {
            if let resolved {
                Image(nsImage: resolved.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text(resolved.name)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                Text(bundleIdentifier)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .onAppear(perform: resolve)
    }

    private func resolve() {
        guard resolved == nil,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        resolved = (
            NSWorkspace.shared.icon(forFile: url.path),
            FileManager.default.displayName(atPath: url.path)
        )
    }
}
