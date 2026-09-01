# IslandSettings

What the user has asked Isleta to do, where that answer is kept, and the window they change it in.

## Owns

- **`IsletaConfiguration`** — the configuration model. A value type: whole copies are handed out, so
  no reader ever sees half an edit, and `Equatable` is what lets a no-op "change" be dropped instead
  of echoing round the callbacks. The global toggle shortcut (§5), the per-source switches, the glance's
  calendars and place, the lock-screen card, the hidden-application list, HUD suppression, and
  whether updates are checked automatically. **Every field in
  it has a live reader** — that is the rule the record is kept to, and schema 4 is where the two that
  did not were removed.
- **`SourceToggles`** — which of Isleta's sources may run (§8.1.4), keyed by `ActivityKind`. That
  key is why this module now depends on **IslandActivities**: `ActivityKind` is closed *for this
  reason* — its own documentation names "so IslandSettings can offer a toggle without string
  matching" — and a parallel enum here would be a second spelling of the same vocabulary, drifting
  from the first the day a kind is added. The stored shape is still four named `Bool`s rather than a
  `Set<ActivityKind>`, because a persisted record wants a key that survives a rename, reads as a
  diff a human can check, and can fall back per key when the blob is partial.

  **One source has finer switches under it**, and it is the only one that does. `systemHUDs` is a
  master over `volumeHUD` and `displayBrightnessHUD` — schema 14, when there were three; the
  keyboard backlight and its `keyboardBrightnessHUD` flag are withdrawn — for a reason the row shape
  forced: volume, mute and display brightness are cases of `SystemHUD`, not `ActivityKind`s, and
  `SourceSettingsRow` is keyed on the latter so that two rows for one kind is not expressible. Minting kinds to buy rows would put a second spelling of
  `SystemHUD` in the vocabulary, which is the mistake the paragraph above opens by refusing. So they
  are `SourceSettingsRow.Option`s instead: switches drawn under the row, writing flags of their own.
  `enabledHUDs` is the one place the mapping lives, and `.volume` and `.mute` deliberately share a
  flag — mute is not a separate thing the user changed, it is what the volume did.
- **`SourceSettingsRow`** — the Sources section, as data the *app shell* hands in. This module reads no `ActivitySource` and links no IslandSources: the pane has to build
  and preview with nothing granted, and reaching for a live source would drag an AX observer and a
  child process into a SwiftUI preview. The shell is the one layer that legitimately sees both a
  source's `authorization` and `IsletaConfiguration`, so it is the layer that phrases the row.
- **`HotKeyBinding`** — a shortcut as Carbon's `(keyCode, modifiers)` pair, which is what
  `IslandKit.HotKeyMonitor` is handed verbatim. Also how it is printed, which means asking the
  *current* keyboard layout rather than assuming QWERTY.
- **Persistence and migration (§11)** — `SettingsStorage` (one JSON blob in `UserDefaults`),
  `SettingsMigration` (the version chain), `SettingsStore` (the one loaded copy, and the callbacks
  that announce changes).
- **The settings window** (§8.1.8) — `SettingsWindowController` and `SettingsView`, including what
  it takes to present a real window from an `LSUIElement` agent app that has no menu bar.
- **The first-run flow** — `OnboardingStep`, `OnboardingLedger`, `OnboardingView` and
  `OnboardingWindowController`. See "The first run" below.
- **Launch at login** via `SMAppService.mainApp`.
- **The seam Sparkle plugs into** — `SoftwareUpdater`, the `UnavailableUpdater` null object, and
  `UpdatesSectionState`, the pure value that decides whether the Updates controls are live and what
  they say when they are not.
- **`GlanceSettings` and the Glance pane** — which calendars to include, Celsius or Fahrenheit, and
  location-or-a-city. Three cards, which is what earns it a sidebar row: `SettingsSection`'s own
  note is explicit that a pane with one card in it belongs inside an existing pane instead.

  It lived in its own `UserDefaults` blob for one release, because appending a stored property to a
  shared struct is the cross-package memory-layout trap CLAUDE.md documents and Stage 1 was built
  beside three other agents. `migrateV7ToV8` brought it home, and the cost while it was parked —
  **"Reset to Defaults" did not reach the glance** — is recorded there rather than forgotten.

- **`GlanceSettingsState`** — the calendar's authorization, the user's calendar list, the location
  status and whether this build holds the WeatherKit entitlement, handed in by the app shell as a
  snapshot. The same arrangement `SourceSettingsRow` has, for both of its reasons: this module links
  no IslandSources, and every field behind it is a live system query too expensive to make from
  `body` — which runs once per keystroke while a city is being typed.

- **`SourcesPaneState`** — the same arrangement again, for the one thing in the Sources pane that
  is **not a source**. `SourceSettingsRow` is keyed on `ActivityKind` and Focus is not a kind that
  publishes: it is a gate consulted at the hub's funnel. It was a shipped feature with no control
  anywhere until this record existed — the Focus gate sat permanently at `.notDetermined` because
  nothing could ask. It carried a notification roster too until notifications were withdrawn on
  2026-08-28.

- **The About pane's Diagnostics card** — the button, its wording, and the rule that it is absent
  when nothing supplies an export. Writing the file is the app shell's (see below).

## A pane opens at its top

The detail column is one `ScrollView` that survives the selection changing, so its offset does too —
switching from halfway down a long pane to a short one lands the reader partway in, or past the end.
`SettingsView.detail` holds a `ScrollPosition` and calls `scrollTo(edge: .top)` on `onChange(of:
section)`, unanimated.

**An edge, not a `ScrollViewReader` anchor.** The anchor version shipped for one build and was wrong
in a way that reads as a padding bug: `scrollTo(id:anchor: .top)` puts *that view* at the top of the
viewport, and the only view to aim at is inside the pane's own `padding`, so the pane arrived with
its top margin scrolled off and could still be scrolled up into. An edge also accounts for the
safe-area inset `paneHeader` adds, which the anchor could not see.

**`.id(section)` on the content would reset the offset too**, and is the wrong tool for it: it
re-creates every control in the pane on every switch — a cost paid for a side effect.

## The window's appearance

Opaque cards over a gradient taken from the app icon's own two stops, in a `NavigationSplitView`,
with a header bar at the top of the detail column and a hairline between every pair of rows.

**These were Liquid Glass until 2026-08-28, and the change is worth the paragraph.** A lens is at
its best over something worth bending — a photo, a map, a video. What sat behind these cards was a
low-contrast gradient that exists to be ignored, so the glass had nothing much to refract and spent
its budget making the *text on top of it* harder to place: each label landed on a slightly different
tone depending on which of `SettingsBackdrop`'s ripples was under it. Eight cards down a pane, that
reads as unevenness rather than as depth. The worst of it was the two `.ultraThinMaterial` bands at
the tops of the two columns, which resolved toward the system's neutral gray and put a gray bar
across a teal window.

What holds now:

- **Every surface is an opaque mix of the icon's two colors.** `SettingsPalette.card`, `.chrome` and
  `.hairline` are mixes off `deep` and `bright`, so a card is the same tone wherever it lands and
  nothing can drift toward gray — there is nothing behind an opaque fill to sample. The window still
  carries its identity in the *backdrop*, where there is no text competing with it.
- **The cards are flat; the controls are still stock.** macOS 26's `Toggle`, `Slider` and `Button`
  carry the system's own treatment, drawn by the code every other app on the machine uses.
  Re-skinning them would produce switches that are *nearly* the system's, which is the "close
  enough" the project brief rules out. This module's job is to give them a surface worth sitting on.
- **The hairline is the only thing allowed out of a card's margin.** `SettingsDivider` undoes
  `cardPadding` with a negative inset so the line spans the card while the text it separates stays
  inset. It is one point tall and sits *between* two rows, which is why it does not repeat the
  swallowed-click bug an overhanging decorative rectangle caused in the sidebar. If it ever grows a
  height, that stops being true.
- **The pane header is a `safeAreaInset`, and its own height is the inset.** The first card starts
  below it rather than under it, so there is nothing interactive beneath the fill. Its background
  `ignoresSafeArea(edges: .top)` because the window is `.fullSizeContentView` and the bar has to
  reach the window's top edge. `SettingsWindowController` sets `titleVisibility = .hidden`: the pane
  name is drawn here, in the content view, and the window's own title in the same band would be a
  second name in it.
- **The sidebar's identity block has no surface, and that is a claim about the minimum size.** Four
  rows under a 560pt minimum height cannot scroll, so nothing slides under the app icon and version.
  A fifth pane, or a smaller minimum, needs a surface again — `SettingsPalette.chrome`, never a
  material.

Reduce transparency still turns `SettingsBackdrop` opaque rather than dimming it. It no longer
touches the cards, because they are opaque already; §6.3 treats the setting as correctness, and its
plain meaning — do not make me read things through other things — is satisfied with nothing left to
branch on.

**Sidebar rows and the pane header share one `SectionIcon`**, a filled rounded square in
`SettingsSection.tint`. The four tints are system colors, never literals: those are what macOS
adapts for dark appearance, increase contrast and the colorblind accommodations, and a hand-picked
hex would be the one thing in this window that ignored the user asking the system to change it.

## Localization

German, French and Spanish, plus English. English is the source language and lives in the Swift
files, as the second argument to `settingsText(_:_:)` — there is no `en.lproj`, because a second copy
of the English would be free to drift from the sentence its doc comment is arguing for. The tables
are `Sources/IslandSettings/Resources/{de,fr,es}.lproj/Localizable.strings`, grouped by surface in
the order the panes appear so the three files diff against each other line for line.
`LocalizationCoverageTests` fails on a key with no entry in a shipped language, on an entry nothing
asks for, and on two languages taking different printf arguments for one key.

**151 keys.** No `.stringsdict`: this package has no plural anywhere — the one place that branches
on a count (`hiddenApplicationsCaption`) chooses between two whole sentences and never prints the
number.

**This is where the argued copy lives, so the rule is fidelity over length.** The settings window is
760pt wide and its cards wrap, so a translation is free to be longer than the English and every
concession, cost and still-works clause has to survive. Two groups were genuinely hard:

- **The four `focusSummary` sentences.** Each is a different state arguing a different thing, and
  `unavailable` is a build problem rather than a refusal — a translation that flattened it into "not
  granted" would send somebody to System Settings to look for a row that is not in the list.
- **`glance.where.caption`.** The second sentence is the whole caption. Losing it turns a switch
  that is safe to turn off into one that looks as though it disables the weather.

Three notes worth keeping:

- **`SettingsFormat` was not locale-aware and is now.** `multiple(_:)` built its decimal with
  `String(format: "%.1f×")`, which takes no locale and printed "1.5×" to a reader whose whole system
  says "1,5"; it and `percentage(_:)` now go through `formatted(.number)` / `formatted(.percent)`.
  The words at zero — "None", "Measured", "Any return" — are looked up. `ms`, `pt`, `s` and `min`
  are **not**: they are unit symbols rather than English words, and de, fr and es write them
  identically. `appearance.size.measured` is the one to watch in review — it has to read as *the
  size Isleta measured on this Mac*, never as an adjustment of nought.
- **No string in the window is Markdown.** `Text(_:)` given a resolved `String` does not parse it,
  so a bold clause would have to be `Text(.init(settingsText(…)))` and every table would have to
  keep the asterisks through translation. The one string that did this was the per-app notification
  sound note, and it went with notifications on 2026-08-28.
- **License text is never localized.** `Acknowledgement.licenseText`, `copyrightNotice` and
  `licenseName` are reproduced verbatim, which is what BSD-3 clause 2 and MIT ask for and what
  `AcknowledgementTests` pins byte-for-byte. Only `purpose` — the sentence Isleta wrote about why a
  component is in the bundle — is translated.

## Deliberately does not own

- **The five continuous settings.** `hoverDelay`, `peekScale`, `activityDwellScale`,
  `welcomeBackMinimumAbsence` and `synthesizedIslandOpacity` were sliders and are **withdrawn**,
  along with `hapticsEnabled`. Each had one right answer, and shipping the slider was shipping the
  question instead of the answer. The migration drops the keys.

  **Three findings outlive them, and two are about the window layer rather than about settings.**

  - **`peekScale` reached two places that had to agree.** The shape the island is *drawn* at and the
    region that *accepts clicks in it* are the same arithmetic run twice; a scale applied to one and
    not the other is the subset bug `IslandHitTestView` documents, where clicks land on lit island
    pixels, reach us, and get dropped. Anything that scales the island still has to do both.
  - **`synthesizedIslandOpacity`'s floor was 0.35, not 0**, because the window server derives our
    event shape from the alpha of the backing store: an island faded far enough stops being
    *clickable* before it stops being *visible*. Increase contrast overrode it to fully opaque. That
    is a fact about alpha and hit testing and it did not go away with the slider.
  - **Bounds belong on the model, not on the `Slider`.** A range written into a view constrains a
    drag and nothing else — it says nothing about a blob hand-edited with `defaults write`, a file
    from a build whose bounds were wider, or a future menu item. Clamping belonged in the
    initializer, in a `didSet`, *and* in the decoder, because those are three different ways in and a
    property observer does not run during initialization. Any numeric setting added later inherits
    this.

- **The Appearance pane, and every control that was in it.** `AppearanceSettings` shipped the
  island's material (Normal / Semi-Liquid Glass / Liquid Glass), its size, its animation speed, a
  shadow, and whether Now Playing borrowed the album's color. **The pane went in schema 18** and the
  settings went with it. The island is now black in a real notch and Liquid Glass where it floats —
  `IslandStyle.automatic`, which is exactly the pair of rules that shipped before the pane existed —
  and the album color is simply always on, because it was the feature rather than an option.

  **The reasoning that outlives it.** Every default in that pane reproduced exactly what Isleta drew
  before the pane existed, so an upgrade changed nothing on screen until the user asked it to. That
  property is why removing the pane was safe: `.automatic` was already the stored meaning of "what
  this screen was", so no install changed appearance when the pane went. Any future pane offering a
  look has to be built the same way or it cannot be withdrawn again.

  `IslandStyle` and `IslandMaterial` remain in IslandKit and still resolve material from the
  display's kind and Reduce Transparency, which is where that rule belongs; `--style-demo` still
  drives all four cases. Nothing sets `style` away from `.automatic`.

- **The Sides card, and the live island in it.** Which side of the notch each kind took, and which
  way round an activity read — `IsletaConfiguration.sides`, schema 15, backed by `IslandSides` in
  IslandActivities. **Withdrawn**; nothing stores a side now, and `ActivityStage`'s raw values stay
  only so an old blob still decodes.

  **`SidesPreview` was why this module briefly depended on IslandUI**, and the reason it did is
  worth keeping: the card asked a question no caption can answer — *which side do you want this on* —
  so it drew a real island out of `ActivityStack`, `ActivitySlotLayout` and `ActivityContentView`
  rather than a hand-drawn mock that would have been wrong the first time any of the three changed.
  The layering held throughout (IslandUI does not depend on this package, so the edge stayed
  acyclic). Its one honest compromise was recorded too: three kinds drew their slivers with a view
  internal to IslandUI needing live state a settings window has none of, so the *side* was exact and
  the artwork schematic. The dependency is gone with the card.

- **Sparkle.** The framework is a dependency of the *app target only*; the real conformance is
  `SparkleUpdater` in `Isleta/`, and it is the only file in the project that imports Sparkle. That
  is the whole reason `SoftwareUpdater` exists: this module has to build, test and preview with no
  third-party framework in its graph, exactly as IslandUI has to with no permission granted. Adding
  `import Sparkle` anywhere under `Sources/IslandSettings` undoes it.

- **Writing the "Export Logs…" bundle.** The About pane draws the button and takes a closure
  (`SettingsView.exportLogs`); the file itself is `LogExport` in IslandKit plus `LogExporter` in the
  app shell, because the diagnostics report inside it is assembled from the island controller and
  the running sources. Nil hides the card rather than drawing a button that saves an empty file.

- **Any behavior a setting controls.** This module stores intent; other modules read it. Nothing
  here suppresses a HUD, performs a haptic, or registers a hot key — the app shell reads the
  configuration and does those, which is why `IslandSettings` has no idea whether they worked.
- **State the system owns.** Launch-at-login is read live from `SMAppService`, never mirrored into
  `IsletaConfiguration`: the user can change it in System Settings while Isleta is not running, and
  a stored copy would be wrong from that moment on. The same goes for reduce-motion and friends,
  which belong to `AccessibilityPreferences` in IslandKit.
- **Any polling.** A setting can only change because this process changed it, so the store *is* the
  notification. Nothing here holds a timer, open or closed (§9).

## Persistence: why this is `UserDefaults` and not SwiftData

§3 says persistence is SwiftData and that GRDB gets proposed before anything else is added. This is
neither, and the reason is that neither is a database problem:

- One record. No query patterns, no relationships, no history, no sorting, no partial loads. Read
  once at launch, written when a human moves a switch.
- §9's launch budget is build-failing. Measured on this machine, creating a `ModelContainer` for a
  single `@Model` and fetching the one record costs **15–21 ms and ~6.0 MB resident**. Reading a
  `UserDefaults` blob and decoding it costs **~2.8 ms cold (~0.012 ms warm) and ~1.5 MB**, and most
  of that 2.8 ms is `cfprefsd` and `JSONDecoder` warm-up that an AppKit app has already paid.
- Against a 300 ms launch budget that Isleta currently meets at ~96 ms, ~20 ms is 20% of the
  remaining headroom spent on a struct of five values.

What SwiftData would buy — a schema, migration plans, a query language, observation of a large
object graph — is all machinery for a problem this module does not have. If a later milestone gives
it one (an activity history worth querying, say), that is the moment to stand a store up, and it
should be a *separate* store rather than dragging the config record into it.

The trade being accepted: `UserDefaults` gives no schema and no automatic migration, so both are
written by hand in `SettingsMigration` — and `MigrationTests` is what makes that honest.

## Storage shape

One key, one JSON blob:

```
defaults read com.tryisleta.isleta com.tryisleta.isleta.configuration
```

A blob rather than a key per setting, because a rename across three keys with no transaction leaves
a user half-migrated if anything interrupts it. A blob migrates as one value or not at all.

Two mechanisms keep old files readable, and they cover different things:

- **Lenient decoding.** `IsletaConfiguration.init(from:)` falls back per key, so a missing or
  malformed field costs only that field. The synthesized all-or-nothing decode would throw on one
  bad key and reset every setting the user ever chose.
- **The version chain.** `SettingsMigration` runs on the raw JSON *before* `Codable` sees it, which
  is the only point at which a renamed key is still distinguishable from an absent one. That handles
  what leniency cannot: data whose meaning changed while its name and type did not.

### Three records are nested inside it, and the nesting is the pattern

`glance` is **one appended field** holding a record, rather than five loose properties — and so
were `notifications` and `appearance` before schema 18 took the appearance pane and 2026-08-28 took
notifications. That is not tidiness: every field added to
`IsletaConfiguration` has to go on the **end** — CLAUDE.md's cross-package layout trap has no compile
error and segfaults in a package nobody touched — so nine appended at once is nine chances for
somebody to put the tenth in the middle.

The first two arrived by a different route and it is worth remembering which. `GlanceSettings` and
`NotificationPreferences` were each parked on a `UserDefaults` key of their own while their stage was
built beside other agents, and lifted in by `migrateV7ToV8` and `migrateV8ToV9`. **The cost while a
record is parked, stated rather than hidden: "Reset to Defaults" does not reach it** — a user who
muted six apps and reset every setting in the window still had six muted apps. `AppearanceSettings`
skipped that step because Stage 7 was built alone, so `migrateV9ToV10` is a type sweep and nothing
more.

## Reading it from elsewhere

```swift
Haptics.isEnabled = SettingsStore.shared.configuration.hapticsEnabled

SettingsStore.shared.addChangeHandler { configuration in
    // Fired after any change that changed something. Never on registration: a caller that also
    // wants the current value already has `configuration`, and calling back immediately would make
    // "apply at launch" and "apply on change" two paths that have to stay in sync.
}
```

## Permission belongs to a button, never to launch (§10)

Nothing in this module asks for anything, and nothing it renders can ask on its own. A row that
needs a permission carries a `SourceSettingsRow.Action`, which is a closure the app shell supplied
and a `Button` renders — so the only way a prompt can appear is a person clicking it in a window
they opened. The three-case `Status` is what makes that possible to get right: *working*, *not asked
/ refused* and *this machine cannot* want different sentences and different offers, and collapsing
the last two is how an app ends up with a "Grant Access" button for a permission the hardware does
not have.

`SourcesPaneState` follows the same rule. One addition it used to carry is worth keeping even though
its feature is gone: **Screen Recording needed a ledger, because macOS will not keep the bit.**
`CGPreflightScreenCaptureAccess` answers a `Bool`, and the errors cannot help either —
`SCShareableContent.current` throws `-3801` with the message *"The user declined TCCs…"* before the
user has been asked, identically in both states. So "never asked" and "refused" are the same
`false`, and they deserve opposite offers. Isleta asks for Screen Recording nowhere now — it went
with the app switcher's window thumbnails — but any permission whose API cannot distinguish the two
states needs a ledger beside it, which is what the Accessibility grant still does.

The rows are a closure rather than an array, and are re-read on `didBecomeActive` rather than in
`body`. Every authorization behind them is a live system call — `AXIsProcessTrusted`,
`AEDeterminePermissionToAutomateTarget`, a CoreAudio device query — and `body` runs on every
redraw, including once per keystroke while a shortcut is being recorded. `didBecomeActive` is also
exactly when the answer is stale, because the only way to change it is to leave for System Settings
and come back. No timer, per §9.

## Every shortcut is bindable, and six of them were not

`ShortcutAction` shipped as a closed vocabulary of seven with `HotKeyRecorder` behind it, and the
window drew **one** field — for `toggleIsland`. The glance, the timer, the shelf, the switcher, the
last link and dismiss-all were assignable only by editing `UserDefaults` by hand.

**Two actions remain — `toggleIsland` and `openGlance`.** The other five went with the surfaces they
reached: the switcher, the last link and dismiss-all with their withdrawn features, and the timer and
the shelf because a shortcut for something that already arrives on its own is a key taken for nothing.
The lesson is the one below, not the count: an action in the vocabulary with no field in the window is
a setting only its author can use.

The Shortcuts card in General lists every action there is. Two rules go with it. **One recorder at a time** — the
monitor is local and swallows the events it takes, so two live recorders would both consume the same
keystroke. And **`toggleIsland` has no clear button**, where every other action does: Isleta has no
Dock icon and its menu bar item can be hidden, so a user who cleared that one would have locked
themselves out with no way back that does not involve `defaults delete`. That is the same asymmetry
`IsletaConfiguration.toggleHotKey` expresses by being non-optional where `Shortcuts`' subscript is
optional.

## A switch that could never move, and what it became

`SourceToggles.focusChanges` meant "announce a Focus turning on or off". macOS cannot tell us: there
is no change notification for Focus anywhere, so `ActivityKind.focusChanged` has no publisher and
cannot get one without a poll, which §9 forbids. That was the `suppressSystemHUDs` position below, and
the rule it left behind is that a switch which can never move is not made honest by graying it.
(`suppressSystemHUDs` has since found its mechanism and come back at schema 23 — see below. The rule
survives its example: what changed was the mechanism, not the reasoning.)

It was **not** deleted, because the slot turned out to hold a live question nobody had asked. Isleta
does let a Focus silence notifications and calendar alerts — `FocusGate` has done that since Stage 2
— and the user had no say in it. So schema 11 renames the flag to `respectsFocus`, defaulting to on,
and `FocusGate.isEnabled` is where it lands.

`migrateV10ToV11` is the one step in the chain that **deliberately discards what it replaces**.
Carrying a stored `focusChanges: false` into `respectsFocus` would turn Focus suppression off for
every existing user, silently, in an upgrade — from a value that meant nothing. The key is removed
and the new one left absent, which the lenient decoder resolves to `true`: exactly what every build
up to now did.

## What was removed, and the rule it left behind

Two settings shipped through 1.1.0 that nothing could act on, and schema 4 deletes both:

- **`suppressSystemHUDs`** was rendered as a permanently disabled switch, on the argument that a
  grayed control carrying its own reason is more honest than no control. It is not, once the reason
  looks permanent: the switch could not move, and what it produced was a whole sidebar pane — System
  — holding one dead control and a screenful of nothing.

  **It came back at schema 23, on 2026-08-30, and that is the interesting half.** The removal note in
  `docs/PLATFORM-CONSTRAINTS.md` said *do not reintroduce the setting without a mechanism*, and a
  mechanism arrived: `MediaKeyMonitor` in `.replace` consumes the volume keys, `SystemVolumeControl`
  becomes their implementation, and a `SIGSTOP` on `OSDUIHelper` covers the HUD that Isleta's own
  CoreAudio write would otherwise wake. False by default, volume and mute only. **The rule below is
  therefore about readers, not about permanence** — the flag was deleted because nothing read it, and
  it came back the moment something could.
- **`delightEnabled`** was stored ahead of §8.4's `Delight` registry, so the first build to ship a
  delight would already know what the user wanted. The registry never arrived, the row was hidden
  behind a `delightsExist = false` constant, and the flag was written, migrated and read by nobody
  for three releases. Storing intent before the mechanism is still the right instinct; it wants a
  deadline, not a permanent home.

**The rule now: a setting goes in `IsletaConfiguration` when something reads it.** A field with no
reader cannot be told apart from one whose reader was deleted — and the switch offering it cannot be
told apart, by the user, from a feature that is broken.

The same reasoning removed two *panes*. `system` held the dead switch; `shortcut` held one row, now
in General under Startup. A sidebar entry is a promise that something is behind it, and a pane with a
single card costs a click to discover there was not. `SettingsSection` says so where a new case would
be added. The count reached four — General, Sources, Glance and About — when Appearance went at
schema 18.

**One control was hidden rather than removed, and it went with the sliders.** Island opacity
appeared only when a display in use had no notch — the one setting whose relevance was a fact about
the hardware rather than about the build, so the app shell answered `hasSynthesizedIsland` and the
card came and went with the display. The pattern is worth keeping even though the setting is not: a
caption saying "this may do nothing on your Mac" was the previous answer and is worse, because the
user drags it, sees nothing change, and now has a sentence to disbelieve.

## The first run

Isleta is invisible at rest, has no Dock icon, and its most-wanted feature is behind a permission the
user grants in another application. Before `OnboardingStep` existed, all three facts were discoverable
only by opening Settings and reading the Sources pane — which nothing gave anyone a reason to do. The
symptom was an app that showed nothing and offered no way to find out why.

Eight pages: what Isleta is; the five permissions, one to a page — Accessibility, music, calendar,
weather and devices; launch at login; and where the island is. Three things about it are
load-bearing:

- **It is not a permission wall.** Continue is enabled on every page, the Accessibility page included,
  and *closing the window counts as finished*. A flow that keeps returning until it is completed on
  its own terms is the nagging §10 rules out. "Open Setup Guide" in the status menu is what makes
  letting go affordable.
- **Nothing on the path prompts.** The Accessibility page renders `SourceStatusLabel`, whose button is
  the only path in Isleta that can raise a system dialog. `SourceHub.didPromptDuringLaunch` is the
  runtime check on that claim, and this window opens during launch.
- **`OnboardingLedger` stores a version, not a `Bool`, and lives outside `IsletaConfiguration`.** A
  release that adds a permission has to reach people onboarded before it existed, which "onboarded"
  alone cannot express. And a first-run flag in the config record would mean "Reset to Defaults"
  re-runs onboarding at the next launch — a consequence with no relationship to what the user asked
  for.

`--onboarding [page]` opens it on a named page and `--onboarding-reset` puts the ledger back, because
the flow is otherwise something you get one look at per machine.
