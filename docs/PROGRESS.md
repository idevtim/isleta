# Progress

Status for Isleta: what the build is, the milestones behind it, the decisions that override
`CLAUDE.md`, what is still open, and what was measured on the way. Update it in the same commit as
the work it describes — a progress file that lags the code is worse than none.

**The build is 2.1.0, and 2.1.0 is HEAD rather than a tag.** `Config/Isleta-Info.plist` carries
`CFBundleShortVersionString` and `CFBundleVersion` 2.1.0, bumped 2026-09-01 for power's own flank
span. The plist is what the target reads and is the authority; the `.xcodeproj`'s `MARKETING_VERSION`
was corrected to match in 484d21f and is kept in step, but it is still not what ships.

**Isleta is open source under the MIT License as of 2026-09-01**, at `idevtim/isleta`. See the standing
decision below for what that constrains — chiefly that the repository must stay public, because Sparkle's
appcast is served from it by raw URL.

---

## Status — what exists

Five local SPM packages and a thin app shell. The layering test still holds: everything in `IslandUI`
builds and previews with no permission granted.

```
IslandKit        panel per display, screen geometry, island CGPath, hit testing, hover tracking,
                 haptics, accessibility prefs, process metrics, IslandLog (categories, rotating
                 file sink, export bundle), the overlay space and the lock-screen space
IslandUI         IslandShape, the motion tokens, presentation state, root view, debug overlay,
                 the three pages and the swipe between them, activity slot layout and content
                 views, the CALayer equalizer and marquee, the display-link clock
IslandActivities IslandActivity + ActivityContent, the pure ActivityStack, ActivityCoordinator,
                 fourteen built-in kinds, the glance vocabulary, MeetingLinkParser
IslandSources    every permission-gated source (list below), the mediaremote-adapter bridge, the
                 file-conversion worker, VolumeStep / SystemVolumeControl / SystemOSDSuppressor
IslandSettings   IsletaConfiguration, UserDefaults storage + hand-written migration, the settings
                 window, the first-run flow, launch at login, the Sparkle seam
Isleta/          app shell: wiring only — controller, one model per screen, hot keys, status item,
                 self-tests, SparkleUpdater, LogExporter
```

**Pages — exactly three** (`IslandUI/IslandPage.swift`): `home` ("Today"), `music` ("Music"),
`weather` ("Weather"). Wrapping, turned by a two-finger horizontal swipe on an open island, with a
row of three dots under the cutout that fades 1.2 s after the page settles. Settings is a right-click
anywhere on the island. The schedule (today and tomorrow) is a drill-down from home, not a fourth
page: it takes the body outright, widens the island to 440pt and wears no dots.

**Activity kinds — exactly fourteen** (`IslandActivities/BuiltInActivity.swift`): `nowPlaying`,
`systemHUD`, `welcomeBack`, `shelf`, `timer`, `deviceConnected`, `glance`, `calendarAlert`,
`meeting`, `power`, `call`, `fileAction`, `focusChanged`, `screenSharing`. `glance` is the one kind
that is never presented — it survives as the module's identity (its source switch, its settings pane,
its shortcut and its status-menu row), and its four table entries say so.

**Motion tokens — ten** (`IslandUI/Motion.swift`): `expand`, `collapse`, `contentSwap`, `nudge`,
`lockHandover`, `reveal`, `pageTurn`, `rebound`, `reboundReturn`, `widen`, plus `contentFollowDelay`
(40 ms) and `Motion.speed`. `CLAUDE.md` says seven and the `isleta-motion` skill says four; both are
stale. Count them in the file.

**Settings — four panes**: `general`, `sources`, `glance`, `about`. Config schema **23**, a
`UserDefaults` JSON blob with a hand-written migration chain. Two shortcuts ship: `toggleIsland` and
`openGlance`.

**Live, permission-gated sources**: Now Playing (vendored `mediaremote-adapter` Perl helper, with an
AppleScript push fallback and a null provider), Calendar (EventKit), WeatherKit plus MapKit city
search, Bluetooth device connections (`IOBluetoothDeviceMonitor` plus the CoreAudio
`AudioRouteMonitor` for the reconnects IOBluetooth cannot see), CoreAudio volume and mute, display
brightness through DisplayServices, media keys through a `CGEventTap`, power, the Focus gate, screen
sharing, calls (audio-route based, anonymous), speech transcription, file conversion / the shelf /
drop history, and the CloudSharingUI share link.

**System HUD replacement ships, off by default.** `SystemHUDSuppression.suppressible` is
`[.volume, .mute]` and `survivesProcessDeath` is **true** — the rule `CLAUDE.md` states was
deliberately overridden on 2026-08-30. See the decision below.

**Onboarding is eight pages**, five of them permission pages, with Accessibility first.

**Localization**: English, German, French, Spanish. US English spelling throughout the source and the
docs after the 2026-08-27 sweep.

**Last recorded suite**: 1,795 tests, `Tools/check.sh` exit 0 (2026-08-30). The measurement log is
`PERF.md`.

---

## Milestones

| # | Milestone | Status |
|---|---|---|
| 0 | Window layer, screen geometry, island shape, hit testing, debug overlay | **Done** |
| 0.5 | Hover → peek + trackpad haptics | **Done** |
| 1 | Click → expand/collapse, Escape, global toggle | **Done** |
| 1.5 | Content inside the expanded island: `matchedGeometryEffect`, container-leads-content | **Done** |
| 2 | Swipe to cycle activities, rubber-banding, momentum | **Done** — the axis later became page turning |
| 3 | Drag-and-drop shelf | **Done** |
| 4 | Activity model + `ActivityCoordinator`, tests before any provider | **Done** |
| 5 | Now Playing: adapter, push fallback, null provider | **Done** |
| 5.5/5.6 | Now Playing UI: artwork, equalizer, transport, draggable scrubber, expanded player | **Done** |
| 6 | Volume / mute HUDs | **Done** — display brightness followed 2026-08-22 |
| 7 | Notifications via AX observer | **Withdrawn** 2026-08-28 |
| 8 | Wake/unlock "Welcome Back" | **Done** |
| 9 | Settings window, launch at login | **Done** |
| 9.5 | Sparkle in-app updates | **Done** — key pair generated 2026-08-19 |
| 9.6 | First-run flow, and the settings window cut back to what works | **Done** 2026-08-21 |

Then, by date. Each line is one or two sentences; the reasoning that outlived the work is in
*Decisions* and the numbers are in `PERF.md`.

| Date | What landed |
|---|---|
| 2026-08-21 | **1.2.0 — the stack view.** `showMenuBarIcon` (schema 5), the flanked pair in `ActivityStack`, per-slot renderer resolution, `TimerSource` and the `timer` kind, `--perf-report` against the §9 budgets. |
| 2026-08-22 | **1.3.0 — the quiet island.** An empty island opens rather than refusing; `IslandClickOutcome` and the refusal pulse deleted. Display brightness HUD (the fourth private path). AirPods connecting. |
| 2026-08-23 | **1.3.0 shipped broken and was pulled before anyone saw it.** `IOBluetoothDevice.register(forConnectNotifications:)` builds a `CBCentralManager`, TCC kills a process that files an access request with no usage string, and the app aborted 270 ms into every launch from the Dock. Every hardware check missed it because TCC judges the request against the *responsible* process, so a shell launch is judged against Terminal. `open -a Isleta` is now the last step before a release. |
| 2026-08-23 | **2.0 — parity with DynamicLake**, ten stages in one night across eight agents. The glance, the shelf-as-workbench (seven conversion routes plus transcription), Up Next and the queue control channel, power, calls, the Finder-extension sources, drop history, the copy link, appearance settings, localization into de/fr/es, and the `CALayer` equalizer rewrite. |
| 2026-08-24 | The city field became a real search (`MKLocalSearchCompleter`, no permission). The weather surface. WeatherKit entitlement embedded and fed a real reading. `announcesApplication(at:)` after a macOS update announced itself 522 times. Volume/brightness HUD levels split into a master and three (schema 14). The pointer holds an activity's expiry open. |
| 2026-08-25 | **2.0.0 cut, signed, notarized and published.** `Tools/release.sh` ran end to end for the first time: notarization Accepted, stapled, the zip extracts to a Gatekeeper-accepted app offline. The lock screen was solved from Isleta's own process. |
| 2026-08-26 | The click only opens, the pointer leaving closes, and the blur band around the open island is the grace region — in its own window. The collapsed island's music sliver became a play/pause control. |
| 2026-08-27 | **Sixty-five settings became twenty-five, seven panes became four** (schema 18). The keyboard-backlight HUD removed. US English sweep across 249 files. A star for Favorite, and Music's own `favorited` reached by AppleScript. The app switcher and the app-installed island withdrawn. The marquee title. |
| 2026-08-28 | **Pages, and the end of notifications.** ~14,900 lines removed. The open island is paged; the chip row became three dots; Settings moved to a right-click. The disk island, the month grid, the player bar and downloads withdrawn. The standing glance withdrawn. The settings window stopped being glass. The lock-screen card got Liquid Glass and three working controls. |
| 2026-08-29 | Wide flanks: the HUD names the key that was pressed (216pt of growth, `IslandFlanks` as a span). The limit rebound — one fixed edge, repeats, `rebound`/`reboundReturn`, and finally a `lean` inside `IslandShape.animatableData`. The page dots fade. The lock-screen card drops in and leaves at the unlock. The AirPods entitlement deadlock. The first run asks for the five permissions. |
| 2026-08-30 | `AudioRouteMonitor` for the reconnects `IOBluetooth` never reports. System HUD suppression measured, and shipped: the event tap consumes the key and `SIGSTOP` freezes `OSDUIHelper`. |
| 2026-08-30 | **The withdrawn features swept out of the prose in all three repositories.** The 2.0.0 notes are now byte-identical across `release-notes/v2.0.0.md`, both `appcast.xml` seeds and the site's changelog; the 1.x notes stay as the record of what those builds actually shipped. **A release note says what shipped, not what did not** — a `## Removed` section listing the seven withdrawals was written and then taken back out, because a reader of 2.0.0's notes has no reason to be told about features they may never have seen. The withdrawals are recorded here and in each module README's "Will not own". Corrected against the build: two shortcuts, not none bound; eight onboarding screens, not four; four settings panes with no style, size, speed or shadow to pick; the localization key counts in three module READMEs. `RecentsScroll`/`RecentsFormat` renamed in prose to `IslandListScroll`/`IslandListFormat`, and four Swift doc comments naming deleted types (`NotificationSourceDiagnostics`, `applyNotificationPreferences`) fixed. |
| 2026-09-01 | **Power spells itself in the sliver.** A charger going in or coming out now draws the word beside the glyph — "Charging", "On Battery", "Charged", "Low Battery", "Low Power On/Off" — the way the volume and brightness HUDs draw theirs. It needed a **fourth** flank span (`IslandFlanks.wider`, `widerFlankedWidthGrowth` 274 against the HUD's 216) because power's labels are phrases and its battery glyph is 23pt to a HUD's 20: the owner chose two constants over one shared widest, so the HUD island stays at the 401pt it was measured for. `IslandForm.allCases` is thirteen shapes; `AppDelegate.transition` widens to `.widerFlankedPeekWithLip`, which contains the wide one. Two smaller rules moved with it: `ActivityStage.flanks` now asks the *sliver* whether it carries a word rather than asking the kind alone, and `ActivityKind.power.flankAffinity` moved to `.leading` so a charger going in while music plays keeps the word rather than the bar. |
| 2026-09-01 | **Isleta is open source, under the MIT License.** `idevtim/isleta` is the public repository and holds the source, the releases and the appcast; `idevtim/isleta-app` became the private archive, keeping the pre-open-source history and the handful of files that are session records rather than documentation. `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, the issue and PR templates and `FUNDING.yml` were written for it, and `Tools/private-sync.sh` was written to keep the archive fed. The cost was borne up front: **61 references from published files to unpublished ones were rewritten or dereferenced**, because a doc that points at `docs/PROBE-*.md` is a dead pointer for everyone but the author. `Tools/sign-debug.sh` became identity-overridable so a contributor can sign with their own team, and `NSHumanReadableCopyright` stopped saying "All rights reserved" beside an MIT license. |

---

## Decisions that override the brief

These are the standing decisions a later reader must not unknowingly reverse. Each one contradicts
`CLAUDE.md` or an earlier entry here, and each was taken for a reason that is
written down beside it. Newest first.

**2026-09-01 — The repository is public, and must stay public.** `CLAUDE.md` described a private
tree for the whole of 1.x and 2.0. It is now MIT, and the change is not reversible in the way a normal
decision is: **Sparkle's feed is served by raw URL from `idevtim/isleta`**, so making the repo private
again 404s the appcast for every installed copy, and "no feed" is indistinguishable from "no update
available" from the outside. Taking the repo private would silently strand every user on the version
they have.

Two rules follow and are load-bearing rather than tidiness. **Do not cite an unpublished file from a
published one** — `docs/PROBES-2.0.md`, `docs/PROBE-*.md`, `docs/PLAN-2.0.md`, `docs/BRIEF.md`,
`docs/NEXT-SESSION.md` and `.claude/` are gitignored, not deleted, and a citation of one is a dead
pointer for every reader but the author; cite `docs/PLATFORM-CONSTRAINTS.md` or `docs/TRAPS.md`, where
the finding actually lives, or state the measurement inline. And **the private half of the EdDSA key,
the Developer ID certificate and the notarization credentials stay out of the tree** — `.env` is
gitignored, `.env.example` carries empty placeholders, and `SUPublicEDKey` in `Config/Isleta-Info.plist`
is public by design.

`CONTRIBUTING.md` and `SECURITY.md` are now public-facing contracts rather than internal notes, and are
worth keeping true.

**2026-08-30 — Isleta replaces the volume HUD, and `survivesProcessDeath` is true.**
`SystemHUDSuppression` had said since Milestone 5 that Isleta ships *alongside* Apple's HUD, on five
measured mechanisms of which four fail the restore-after-crash rule and the fifth — consuming the key
in a `CGEventTap` — was rejected on two grounds. **Both grounds fell.**

"For brightness that is impossible" rested on `IODisplaySetFloatParameter` answering
`kIOReturnUnsupported` on Apple Silicon internal panels. That refusal is real and still reproduces; the
conclusion is false. Measured on macOS 27.0, built-in panel, unentitled process, no Accessibility:
`DisplayServicesSetBrightness` resolves, `set(0.75)` returns 0 and reads back `0.7499999` — **EFFECT:
MOVED**. Fourth time in this codebase a capability was declared absent on the evidence of one API
declining it, and the claim had reached a user-facing string (`hud.suppression.brightness`, four
languages), which is the one place nobody re-reads it. The second ground — an Accessibility grant
Isleta never asks for — went obsolete on 2026-08-29, when the first run started asking for it.

**Consumption works.** `HUDConsumeSelfTest` (`--hud-consume-test`, Debug), signed build, Accessibility
granted, macOS 27.0 (26A5421a), Mac15,9:

| phase | presses | volume | Apple's HUD |
|---|---|---|---|
| A — tap passes events through (**control**) | 5 | 0.2000 → 0.5000 | appeared |
| B — tap consumes | 5 | 0.5000 → **0.5000** | **did not appear** |

Consuming at `.cghidEventTap` stops the key reaching the system *and* stops the HUD.

**But the tap alone was not enough, and the reason is the write.** Once Isleta swallows the volume key
it must write the level itself, and the CoreAudio write is what wakes `OSDUIHelper` — the HUD follows
the level change, not the keypress. Measured: the default output publishes `VirtualMainVolume` and
**no per-channel `VolumeScalar` at all** (`ch1 present: false`, `ch2 present: false`), so there is
exactly one writable level property and it is the one that draws. So the shipped mechanism is
`SIGSTOP` on `OSDUIHelper`, and **that outlives the process that sent it** — a crash or force-quit
leaves the user with no volume HUD from anything and nothing on screen naming the app responsible.
Taken knowingly by the owner with the cost named. Three things narrow it, all verified on hardware:

| path | helper state | verified |
|---|---|---|
| running, suppression on | `T` (frozen) | ✓ volume keys replaced, no macOS HUD |
| quit (⌘Q, SIGTERM, ⌃C) | `S` | ✓ `resume()` runs first in `applicationWillTerminate`, synchronously |
| SIGKILL, then relaunch | `T` → `S` | ✓ `repairAtLaunch()` thaws unconditionally |
| SIGKILL, feature switched **off**, relaunch | `T` → `S` | ✓ the repair is not gated on the setting |

`resume()` is synchronous because a detached `Task` never completes during termination. **Nothing
polls**: `SystemOSDSuppressor.ensureSuspended()` runs from the volume-key handler, before the write —
the one moment a respawned helper would matter — rather than from a watchdog. `kill(2)` rather than a
`killall` subprocess and `proc_listpids` rather than `pgrep`, because this runs on the path of a
keypress (67 ms wall / ~5 ms CPU per `pgrep` call against 0.6 ms). `suppressSystemHUDs` is back at
schema 23, **off by default**, and `migrateV22ToV23` clears any stored `true`: that answer was given
when the switch could not move anything, so it is not consent for a mechanism that did not exist.
**A refused CoreAudio write hands the key back rather than swallowing it.** Brightness is deliberately
still Apple's — the write works, but a ramp has a feel of its own and the external-display case is
unmeasured.

**2026-08-30 — the Bluetooth reconnect needs a second signal, and it is CoreAudio.** Measured before
anything was written, one probe watching IOBluetooth connect notifications, per-device disconnect
notifications, a half-second `isConnected()` poll and both CoreAudio hardware properties, across one
full cycle of real hardware:

| what the user did | IOBluetooth | CoreAudio default output |
|---|---|---|
| case → ears | `CONNECT` ×4 | → AirPods |
| out of ears | *silent* | → speakers |
| back in ears | *silent* | → AirPods |
| → case | `DISCONNECT` ×4 | → speakers |

Taking AirPods out of your ears never drops the link, so no amount of work on the IOBluetooth path
would have found the event. `AudioRouteMonitor` watches
`kAudioHardwarePropertyDefaultOutputDevice`, gates on a Bluetooth transport type and reads the MAC out
of `kAudioDevicePropertyDeviceUID` (`04-9D-05-6B-19-80:output` against an `addressString` of
`04-9d-05-6b-19-80` — exact, needing only a lowercase). Public, unentitled, push. **IOBluetooth stays
in one place**: the route monitor knows a MAC and hands it to
`BluetoothDeviceMonitoring.publishConnection(at:origin:)`, so the source has one path to deduplicate
rather than two to reconcile. **The two routes are one island** — a genuine connect fires IOBluetooth
at `.553` and CoreAudio at `.797`, 244 ms apart, and the existing address-keyed four-second window
collapses them. A route moving *away* from Bluetooth clears the memory rather than announcing, so
speakers → AirPods → speakers → AirPods is two announcements. The route in effect at launch is
recorded and not announced.

**2026-08-29 — Accessibility is a permission Isleta asks for, and the first run asks for five.** The
flow was `welcome → startup → ready`, a tour, and three doc comments asserted otherwise — one of them
*resting an argument on it*, to justify the media-key tap not prompting. It is eight pages now with
`OnboardingLedger.currentVersion` 1 → 2, which is the first use of that mechanism for what it was
built for. Accessibility leads, reversing the original order: its dialog sends the user out to System
Settings and is the likeliest place to abandon the flow, and that is outweighed because the HUDs are
the most visible thing Isleta does. `Skip` is what makes the cost survivable. It is still not a wall —
Continue is live on every page, closing the window counts as finished, and a `Skip` appears the moment
Continue stops being the control that advances. **Bluetooth is the page that does not ask**, and that
is the platform: CoreBluetooth raises its dialog when the monitor registers for connect notifications,
which is at launch, and there is no call that asks a second time. **`AXIsProcessTrusted` has no
`notDetermined`** — a refused process is indistinguishable from an unlisted one — which is why "Ask
Again" is honest on that page and would be a lie on the other four. Every request's return value is
discarded and the state re-read: `AEDeterminePermissionToAutomateTarget` has answered `noErr` for a
dialog the user had not touched.

**2026-08-29 — the lean is a property of the shape, not two composed effects.** The rebound was
reported three times and fixed twice wrongly, so what the fix is *not* matters. It was not the
`rebound` spring's damping played backwards: ω₀ = 2π/0.16 ≈ 39.3 rad/s at ζ = 0.55 is at 16.03 pt with
−20.5 pt/s at the 160 ms handoff, and a critically damped return from there has `v₀ + ω₀x₀ ≈ +609`, so
it never crosses zero — it would need about −629 pt/s to. (`Motion.reboundReturn` is still the right
curve for a detent; it was simply not fixing anything.) The actual cause was composition:
`bouncedMetrics` grew the outline symmetrically and a `+limitBounce / 2` view offset shifted it back,
which is exact at t=0 and t=1 and **has no claim at all on the frames between** — two animatable
channels, and SwiftUI hands a retargeted spring the velocity the outgoing one had. `IslandShape.lean`
now sits in the same `animatableData` as width, height and the radii, so the fixed edge is fixed at
every frame. Two things are deliberately **not** animated: the lean is a *magnitude* with its side as
a separate fact (`limitLean` + `limitLeansTrailing`), because a signed value has to pass through zero
to change sides and a spring aimed at zero passes *through* it; and the bar's stretch anchor, for the
same reason. **The test that let this ship twice** watched `model.limitBounce` and asserted it never
went negative — it never could, because the model holds the two endpoints and SwiftUI owns everything
between them. The check that can see it walks the geometry.

**2026-08-28 — pages, not activities, are what the open island browses.** `IslandPage`
(`home`/`music`/`weather`, wrapping) and one `IslandPageModel` for the whole app. This is
`SwipeTracker`'s second life: the physics were written for swipe-to-cycle and disconnected when that
lost the axis to stowing, and the horizontal axis on an *open* island was free the whole time
(`IslandStowGesture` ignores an open island at its first `guard`). **Three flags became one value, and
that deleted a class of bug** — the weather and the month could be true together, so `IslandRootView`
and `expandedContentHeightForStage` each had to test them in the same order or the island was sized
for one surface and drawing another, which had already happened once with the player stretched to the
weather's height. `pageTurn` is the one token that deliberately does not bounce, because a page is a
detent. **A turn commits before it finishes**: `commitPageDrag` steps `current` synchronously and
`landTurn` re-expresses the offset against the new page, instead of travelling toward it and swapping
identities in the spring's completion, which left `current` naming the page being *left* for the
length of the spring. The offset is `landing + drag`, so a gesture starting on a tail adds to it
rather than seizing it. **The dots fade 1.2 s after the page settles**, and the fade is an opacity and
never a branch — the strip's 28pt is reserved for as long as the island is open, so dots that came and
went by existing would move the island's bottom edge and the hit region pinned to it, two seconds
after the user stopped touching anything. A pointer on the strip lights them, which is a correctness
requirement rather than polish: the dots are the only pointer route between pages. The dwell does not
scale with `Motion.speed` — the fade is motion, the dwell is a person glancing.

**Settings is a right-click on the island.** Right-click already had a meaning there (the shelf's tile
actions), so `IslandDragHandlers.contextMenu` returns whether it took the point and everything else
falls through to Isleta's own menu, whose rows are `StatusMenuModel`'s so the two cannot drift.
`isShowingIslandMenu` holds the exit grace open, because moving onto a menu *is* the pointer leaving.

**2026-08-28 — a withdrawn feature is a subtraction, not a deprecation.** The code, the vocabulary
case, the settings control, the shortcut, the strings and the tests all go, so nothing is left whose
status a later reader has to work out. The measurements outlive the code, in the module README's
"Will not own" / "Deliberately does not own" and in this file. Seven features have gone this way; they
and their numbers are the last section here.

**2026-08-27 — a private path that works is not a reason to ship the feature it enables.** The
keyboard-backlight HUD was, by this project's own measurement standard, good work: the claim it
replaced ("a privileged device only Apple's software may query") was a correct measurement of the
wrong subsystem, and `CoreBrightness` answers an unentitled process and pushes 2–6 ms after a change.
It was the fifth private path, and it was still the wrong feature. **A HUD's entire premise is that it
reports what you just did.** The backlight moves on its own constantly — idle dimming fires
unprompted, ambient light suppresses it entirely, and with the keyboard's own auto-brightness on (the
default) an ambient adjustment is indistinguishable from a keypress. A switch to turn it off is a
setting apologizing for a feature. Reaching a value and having something worth saying about it are
separate questions, and this codebase is good enough at the first to keep mistaking it for the second.

**2026-08-27 — a setting is only a setting if a reasonable person could want the other answer.**
Sixty-five controls across seven panes became twenty-five across four (schema 18). Everything else is
either a constant the app should simply be right about, or a question macOS already asks once for the
whole machine. What went: eight sliders (Apple ships no slider for how fast an animation runs); the
style picker, where `.automatic` was already the right answer on both kinds of display; the shadow,
because macOS derives a window's event shape from its alpha, so "cast a shadow" also means "eat clicks
in a band you cannot see"; `IslandSides`, five weeks old, because the arrangement it let people change
is the one that makes a shared island legible; five of eight shortcuts, on the bar that **a shortcut
exists only for an action the pointer cannot do as well**; the temperature unit, which System Settings
already answers; the haptics switch, since macOS suppresses the tap unless a finger is on the
trackpad. Two of the five retired shortcuts had **no handler in the app shell at all** — a bindable
action with no handler takes a system-wide combination away from every other app in exchange for
nothing, and `handler(for:)` is total now.

**And the general fault this named and then walked into: a setting removed leaves a knob whose default
is now load-bearing.** Six properties were orphaned. Five defaulted to exactly the neutral value their
control defaulted to and were correct by luck. `NowPlayingController.usesAlbumColor` defaulted to
`false` because it had been written as a preference that started disabled, its two writers were the
Appearance pane's, and **no island wore its cover's color on any launch** — while every test that set
it by hand kept passing. The fix was to delete the flag, not to default it: taking the accent from the
sleeve is what the Now Playing island *is*. The check that now runs: for every property whose writer a
removal deletes, read what it defaults to and confirm the default is the behavior being kept, not
merely that it compiles.

**Removing the settings left plumbing with no writer, and it was deliberately not removed in the same
change.** `IslandSizing`'s four fields, `Motion.speed` and `MotionSpeed`,
`IslandHitTestView.hoverDelay`, `ActivityStack.dwellScale` and `IslandScreenModel.synthesizedOpacity`
all sit at neutral with nothing writing them. `IslandSizing` alone is 73 call sites across 16 files,
and it is the type whose entire purpose is that the drawn shape and the hit region are built from one
value. Named here so it is not rediscovered as mystery dead code.

**2026-08-26 — the click only opens, the pointer leaving closes, and the blur is the grace region.**
It was `toggleExpanded`, and a toggle's two halves are not the same gesture: opening is aimed at the
island, while closing by clicking again means aiming at the *body* of an open panel, which is where
all of its content is. There are five ways out, all pointing somewhere that is not the island — the
pointer leaving it and its blur, a click in the blur, a click anywhere else, Escape, and the swipe up
— and all five land in `collapseIslands`, so the island is handed back in one state however it was
closed. Two exemptions, both rules that already existed: an island Isleta opened itself is not closed
by the pointer wandering off it, and the drop-history-style surfaces that hold what has already
expired have nothing to bring back. **It closes on the pointer *leaving*, never on the pointer being
outside** — an island opened by the hot key with the pointer on another display has no hover to lose.
**And it waits 220 ms and then asks where the pointer actually is**, because the tracking rect is
rebuilt whenever the island's size changes and a rect rebuilt under a stationary pointer reports an
exit and a fresh entry.

The band is 24pt on the two sides and the bottom (`IslandLayout.blurSpread`, bounded by `panelMargin`
so it always fits a panel that is never resized). Its *entry* region stays the island itself, so the
same hysteresis the closed island has is extended rather than reinvented. **A click in the band passes
through to the app underneath and does not close the island** — the global outside-click monitor asks
`IslandController.isPointInBlur` first.

**2026-08-26 — the blur needs its own window, and `ignoresMouseEvents` is forbidden on `IslandPanel`
and required on `IslandBlurPanel`.** An `NSVisualEffectView` is opaque to the window server wherever
its mask reaches, however faint it looks. `--click-test` swept the band at 2, 6, 12 and 20pt outside
the island's wall across blur strengths of 0.34, 0.20, 0.12 and 0.06 — **`CLAIMED` at every one of
the sixteen combinations**, with a probe at the panel's far corner reporting `NOT Isleta` throughout
as the control. So there is no strength at which a blur in the island's panel lets a click through.
`IslandBlurPanel` is one per screen, directly beneath `IslandPanel`, `ignoresMouseEvents = true`,
hosted in the same private overlay space and driven from the same `IslandScreenModel`. That is not a
loophole in the rule: the rule is about the window whose alpha-derived event shape is the entire
mechanism, where *assigning* the property — either value — replaces that shape with the whole frame.
This window draws no control, accepts no click and has no hit testing.

**And `mouseExited` stopped being evidence.** With the band in the other window, the island's own panel
stops receiving mouse events the moment the pointer crosses the island's edge. Both places that acted
on it ask for a *position* now.

Three ways to blur a desktop, tested on hardware 2026-08-26:

| Route | Tint | Result |
|---|---|---|
| `CALayer.backgroundFilters` + `CIGaussianBlur` (public) | none | **Draws nothing.** Background filters see only what is composited inside the same window. |
| `SLSSetWindowBackgroundBlurRadius` (private, SkyLight) | **none** | A genuinely colorless blur, and **window-wide**: it blurs the whole 608×400 panel with a hard rectangular edge and is not masked by alpha. `SLSSetWindowClipShape` bounds it but clips the window's **content** with it — the island vanished — and the region came back ~2× oversized, so it wants device pixels. A region is a list of rectangles, so the edge could never feather. |
| `NSVisualEffectView` (public) | yes, always | What ships. |

`glassEffect` is not in the table because Liquid Glass is mostly its *edge*, and this band ends in
nothing. What ships is `.fullScreenUI` with the appearance **pinned to `.darkAqua`**: left to follow
the system, the light variant renders a **white glow** around a pure black island. `.hudWindow` pinned
dark was indistinguishable and is the fallback. **Every material is a blur plus a gray, and the gray
has a floor** — over a black terminal the band came back lighter than the window it sat on — so the
band is the blur with black over it (`strength` 0.34, `darkening` 0.22), each masked to the same
feathered outline. Two separate masks rather than one `compositingGroup()`, because grouping takes a
behind-window `NSVisualEffectView` offscreen and a backdrop rendered offscreen has no backdrop to
sample. It rides `IslandMaterialView.openPresence`, and is **absent** at rest rather than transparent:
a behind-window blur is work the window server does on our behalf and does not stop because a layer
above is at zero opacity. Under Reduce Transparency it is not drawn at all.

**2026-08-25, revised 2026-08-26 — the lock is a stow, and this overrides the 2026-08-19 rule that the
island must be gone before the first faded frame.** An island with something on stage now collapses
into the notch on `collapseIntoNotch(animated: true)` — the two-finger stow's own spring, the exact
reverse of `playReentry` — and the padlock arrives on the same curve. The owner chose the animation
knowing loginwindow's fade does not wait for it; the `animated:` flag is passed only from
`com.apple.screenIsLocked`, never from sleep or dark displays, and is the whole of the fix if the tail
is caught. `isStowed` is still not touched, because a stow is the user's answer and not the lock's.
`Motion.lockHandover` (`.bouncy(duration: 0.70, extraBounce: 0.10)`) is the fifth token, added because
`nudge`'s 0.30 s was too quick for a move nobody's hand is on. `AppDelegate.returnDelay` moved from
650 ms to **1750 ms** to bring the island out after the padlock's collapse. **Every re-entry is
`scaleEffect(x:y:1, anchor: .top)`** — the flanks spring left and right out of a cutout whose height
never moves — and **it does not fade**: `reentryOpacity` reaches solid at `reentryFadeSpan` (0.15 of
the travel), so everything anybody watches is the scale alone. One function, so the island in, the
padlock out, the padlock in, the island out and a track starting all lost the fade together.

**The one bundled audio asset, which overrides "system sounds, never bundled audio".** The unlock plays
`Isleta/Resources/Unlocked.wav` (0.5 s, 131 KB, tunetank.com), at the owner's request; Bottle is the
fallback when the file is absent, so the package still carries nothing. **The license is still to be
confirmed by the owner before it ships.** The lock sound is gone — the lock has a 0.7 s animation to
say what happened, and the sound landed on whoever was left in the room.

**2026-08-25 — the lock screen is reachable from Isleta's own process, and this reverses the
2.0 plan.** That plan says the route is a separate login-item helper app, because that
is the route the competitor took. **Locking does not log you out** — the Aqua session stays on console
and Isleta stays running with its panels and its window-server connection — so a login-item helper is
the same kind of process in the same session. The mechanism is a SkyLight space at absolute level
**400** (`kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`); `SkyLightOverlaySpace` already makes
all four calls and passes `Int32.max`, which silently fails and reads back 0. **The window level is
irrelevant**, and the trap that would have cost the most is that `CGShieldingWindowLevel()` is not the
lock screen's level: it is 2147483628 and belongs to `CGDisplayCapture`, where loginwindow's shield is
at 2147483646 — so `CGShieldingWindowLevel() + 1`, the advice everyone gives, is sixteen levels below
the window it is trying to beat.

**The lock screen delivers no events — and that does not mean the surface is a readout.** The shield
captures every event, for everyone; fourteen runs say so. But `NSEvent.mouseLocation` and
`NSEvent.pressedMouseButtons` are **global queries answered by the window server**, not events
delivered to us, and both are readable behind the shield. So a press edge over a rectangle whose
screen coordinates we compute is a click, and the lock-screen card carries five working transport
controls and a seekable progress line. The costs are honest and written on the view: no cursor change,
and the press resolves on the down edge at 30 Hz rather than on a release inside the target.

**2026-08-23 — private frameworks and third-party dependencies are both allowed.** The working
agreements said "no private frameworks except two isolated paths" and "only Sparkle and
`mediaremote-adapter` are sanctioned"; the private count had already reached five by the time the rule
was lifted, which is the usual sign that a rule is being honored by counting rather than by reasoning.
What survives is everything that was never about permission: **resolve at runtime** so a removed symbol
degrades instead of failing to launch, **sit behind a protocol** whose fallback is a real feature
rather than an empty box, and **measure before believing**.

**The rule that replaced them is a distinction rather than a limit: a private *path* versus a locked
*door*.** `mediaremoted` answers `/usr/bin/perl` because there is an interpreter whose code-signing
identifier begins `com.apple.` — that is a path, and walking it is engineering. `callservicesd`
answers `com.apple.telephonyutilities.callservicesd` / `access-calls`, which FaceTime holds and no
third-party app does — that is a door, and it does not open for a policy change or a better idea.
**The cheap test that tells them apart: stand the client up from a real app bundle and read the
*daemon's* log, not your own.** Ours printed a tidy empty array while `callservicesd` logged the
refusal about us in the same millisecond. And **"the daemon refused us" and "the daemon refuses this
operation" are different findings** — only the second closes a door. We conflated them and wrote off a
working route (`com.apple.CloudSharingUI.CopyLink`) for a day. The §9 budgets are untouched by this
and are not the same kind of rule: they do not say what may be built, they are how the cost of what
was built is found out.

**2026-08-23 — weather is not an `ActivityKind`, and WeatherKit is behind an entitlement that kills the
app when it is unauthorized.** The island never announces the weather, it *contains* it. A second
source publishing a second activity drawn in the same island would give the open island two publishers
and two heights, and `expandedContentHeight` is read **before** the transition, so a reading landing on
its own clock would resize a surface somebody is reading. `WeatherSource` publishes a reading;
`CalendarSource` folds it into `GlanceSnapshot`; one publisher, one height. **Claiming
`com.apple.developer.weatherkit` with no embedded provisioning profile SIGKILLs the app at `exec`** —
exit 137, no crash report, `codesign` silent — which is the 1.3.0 Bluetooth abort's shape again. The
entitlement and `Config/Isleta.provisionprofile` landed 2026-08-23, and the sharper permanent
constraint is that a **Debug** build can never carry it: an ad-hoc signature cannot carry a developer
entitlement at all, so `Tools/check.sh` is structurally unable to see a weather bug and "build it and
look" for this feature means `./Tools/release.sh --build-only`, installed and launched with `open -a`.

**`CalendarSource` owns one timer, and only when there is something to wake for.**
`.EKEventStoreChanged` is genuine push at 8–10 ms and it says *the user edited a calendar*, never *a
meeting is now five minutes away*. Time passing announces itself to nobody, the obvious answer is a
minute poll, and §9 forbids one. `GlancePolicy.nextBoundary` names the next instant any answer could
change; one `DispatchSourceTimer` is armed at it and re-armed from its own handler. **An empty calendar
has no boundary and therefore no timer at all.** Weather's refresh is the §9 exception taken
literally — armed when the pages own the body and the current page is `.home` or `.weather`, through
`AppDelegate.refreshWeatherPolling` off the one funnel every open, close and page turn goes through.

**Three kinds from one source, because they come from one fetch.** `.glance`, `.calendarAlert` and
`.meeting` are three switches and one `EKEventStore`; splitting them would mean three objects
re-running the same predicate and three answers about what is next that can disagree. A joinable
meeting **suppresses the alert about the same event**.

**The empty state's words come from the authorization, never from the event count.** A refused calendar
and a genuinely free afternoon return byte-identical results from every EventKit call there is — zero
sources, zero calendars, a valid predicate, `[]` in 1–4 ms with no throw. `authorizationStatus(for:)`
is the only discriminator. Nothing on this path retries on `.notDetermined`: with no usage key the
request answers a plausible-looking `false` in 9 ms and never prompts.

**The join link is parsed from `notes` first.** 30 of 33 real events carried the link in `notes`, 7 in
`url`, and `location` held no http(s) host at all. The `dialin.teams.microsoft.com` exclusion is in
the pattern set rather than applied afterwards, because in a real Teams invitation that host sits
*above* the join link and first match wins. `MeetingLinkParser` lives in **IslandActivities** with no
EventKit near it, so the whole of it is checkable with no calendar and no permission.

**The glance vocabulary lives in IslandActivities.** `GlanceEvent`, `GlanceSnapshot`, `CalendarAccess`,
`LocationAccess`, `WeatherReading` and the two pure policies are drawn by IslandUI and produced by
IslandSources, and the only package both depend on is that one. Putting them beside the producer would
have meant IslandUI linking EventKit, WeatherKit, CoreLocation and MapKit — the layering test failing
in a single edit.

**2026-08-23 — a shared record is the integrator's to edit.** Appending a stored property to a shared
struct is the cross-package memory-layout trap: dependent packages read every field at the wrong
offset, with no compile error and a segfault three packages away. An agent that needs a persisted
field parks it behind a store of the same shape, says so in the type, its README and this file, and the
integrator lifts it in one schema step. It happened twice (`GlanceSettings`, schema 8; the notification
preferences, schema 9) and both cost the same thing while they waited: **"Reset to Defaults" did not
reach them**, which is why both have a test pinning the reset — *"the record does not contain it"* and
*"the reset is broken"* are the same symptom and only a test tells them apart. Migrations read the
parked key and never write it, so a downgrade keeps what the user set.

**2026-08-23 — Isleta names its features in plain descriptive English and coins nothing.** A parity
exercise names the thing it is comparing against, and the competitive analysis goes on doing it. Calling one
of our own features by their name is a different act. Exactly one borrowed name had got through, and it
had got all the way through: `miniLake` was an `AppearanceSettings` field, a `UserDefaults` key, a test
suite, a test *file* and the text on a switch. It is `compactIsland` as of schema 12. The rule is a
product rule before it is a legal one — Apple does not brand its sub-features with portmanteaus, and
that is why our names need no glossary and also why they cannot accidentally be somebody else's.

**2026-08-21 — Clock timers, read from `com.apple.mobiletimerd` with no permission.** A running timer
is `.ambient`, peer to Now Playing, and takes the trailing flank — the first kind whose `flankAffinity`
is not `.leading`, which is what the table was built for. **The value is a timeline running
backwards**: `elapsed` is what is left, `rate` is `-1`, `duration` is what the timer was set for, and
every consumer then does the right thing from one value. Two shapes were tried and discarded — a
`.countdown(until:)` gives numerals and no fraction so the ring has nothing to draw, and a *forwards*
timeline fills the arc up as time runs out. **A chip's glyph comes from the kind, not from the
activity's state**, so the music chip is always `music.note`; reading the compact badge instead made a
navigation control change shape under the pointer. **`lineLimit(1)` on the flank numerals is
load-bearing** — a flank is 40pt with 20pt of padding, and the first live timer wrapped to two lines
and drew "4:" above an ellipsis beside the notch; hour-plus countdowns are spelled `1h04` rather than
`1:04:20`.

**2026-08-21 — `IslandScreenModel` stores the stage, not presentations plus a kind.** Two parallel
spellings of what is on the island would have agreed right up until a companion arrived and one of them
had never heard of it. `presentations` and `presentedKind` are computed and still mean the *primary's*,
so every call site that predates the pair reads correctly. **The bespoke-renderer kind is resolved per
slot** — asking once and using the answer for all four slots is correct while one activity owns them
all and wrong the moment a companion holds a flank, and the failure *renders plausibly*: a view
appears, in the right sliver, at the right size. The pre-pair `setActivity(_:kind:…)` shape lives in
the test target only, because a production convenience taking loose presentations plus a kind is
precisely the call that silently drops the companion while looking entirely correct.

**2026-08-21 — the status item is hideable, and the switch may not outrun its replacement.**
`showMenuBarIcon` (schema 5) is safe only because `toggleIsland` reaches the island from any app: an
`.accessory` app installs no menu bar and ⌘, is dispatched by whoever is frontmost, so the status item
is otherwise the only route to Settings and Quit. An **absent** key decodes to `true`. And
`migrateV4ToV5` drops a `showMenuBarIcon` that is present but is not a JSON boolean, which **cannot**
be written as `stored is Bool`: after `JSONSerialization` both `1` and `true` are `NSNumber` and Swift
bridges the first to `Bool` happily. `CFBooleanGetTypeID()` is the only test that separates them.
`setStatusItemVisible(_:)` is idempotent in both directions and uses `removeStatusItem` rather than
`isVisible = false`, because macOS gives a newly created status item the leftmost slot rather than the
one the user dragged it to.

**2026-08-19 — bottom corners curve inward, not outward.** §4.4 specifies concave bottom outer corners
so the island reads as carved out of the display. Built and viewed on hardware, the outward flare put
two points on the bottom of the island and read as a shape pasted *over* the notch. `ContinuousCorner`
still supports concave corners if a later state wants one.

**2026-08-19, revised the same day — the open island's top corners flare outward.** §1's four-value
`IslandShapeMetrics` grew a fifth, `topFlareRadius`, and `IslandShape.animatableData` nests to keep all
five on one spring. The flare is the one dimension that paints **outside** `bodySize`: `boundingSize`
accounts for it and `union` takes its **max** where the radii take min, because a radius removes area
and the flare adds it — taking min there would carve the widened top out of the widened hit region and
reintroduce the subset bug. Zero at rest and at peek. **A widened resting island earns the same flare**,
because once the island is wider than the cutout it has two square corners against the top of the
screen, which is the condition the flare exists for reached from a different direction.

**2026-08-19 — external displays get no island.** §1 and §4.3 say notchless displays get a synthesized
island pinned to the top center. In practice that is a floating black rectangle stuck to the top of the
screen — a different product, with no cutout to be continuous with. `IslandPlacement.displays(from:)`
presents only on displays with a real notch. The one exception is a Mac with no notched display at all
(mini, Studio, iMac), where the primary display still gets a synthesized island, or the app would have
no UI whatsoever. That exception is one function to change.

**2026-08-19 — a widened hit region is a *union*, not the larger endpoint.** Flanked rest is 265×32 and
unflanked peek is 197×40 — wider *and* shorter, so neither contains the other and the taller endpoint
is a **subset across 68pt of lit island**. A click there lands on visible island pixels, reaches us,
and gets rejected, so it neither opens the island nor falls through. `IslandShapeMetrics.union` takes
componentwise **max** on width and height and **min** on both radii; because `lerp` is componentwise,
every intermediate lies inside the union by construction. `PeekTests` samples the drawn shape at seven
progress values across all ordered form pairs and separately asserts that the *old* rule still fails,
so the union cannot silently become redundant. There are now three maximal forms to widen to —
`.expanded`, `.flankedPeekWithLip` (taller, at the ceiling of the size settings) and
`.wideFlankedPeekWithLip` (wider, on every Mac) — plus twice the rebound's travel at both ends of the
protocol.

**2026-08-19 — the layering edges.** IslandActivities depends on IslandKit, for one symbol
(`ActivityPresentations.content(for:)`); the alternative was duplicating the presentation enum, which
is how two definitions of the island's state start drifting. IslandUI depends on IslandActivities,
because IslandUI renders `ActivityContent`. IslandSettings depends on IslandUI, because the Sides
preview drew a real island — acyclic, and it does not touch the layering test, which is a statement
about IslandUI. IslandActivities still contains no SwiftUI, no AppKit and no I/O.

**2026-08-19 — activity presentations are data, not views.** A view-producing requirement drags SwiftUI,
and through it AppKit, into the one module whose value is being fully exercisable with no window, no
permission and no running app. It also makes `ActivityChange` undecidable: telling "same activity, new
content" (crossfade on `contentSwap`) from "new activity" (morph on `expand`) is an `Equatable`
comparison, and views are not `Equatable` — every provider would have to classify its own change, and
the first one to get it wrong makes a track change look like the island reopening. The cost is that an
activity cannot draw something the vocabulary has no word for; a bespoke view belongs in IslandUI keyed
on `ActivityKind`, never as an `AnyView` smuggled through IslandActivities.

**2026-08-19 — `ActivityCoordinator` is `@MainActor @Observable`, not an `actor`.** Every consumer is
main-actor UI reading the presented activity from inside a SwiftUI `body`; from an `actor` that read is
an `await`, so the view can only ever mirror a copy — a second source of truth for what is on the
island. §6.2's 40 ms container-leads-content window is ~2.4 frames and has no room for an actor hop,
and `withAnimation` cannot span one. There is nothing to protect: the stack holds single digits of
entries.

**2026-08-19 — the config record is a `UserDefaults` JSON blob, not SwiftData.** §3 says persistence is
SwiftData. Measured on this machine: standing up a `ModelContainer` for a single `@Model` and fetching
the one record costs **15–21 ms and ~6.0 MB resident**; reading a `UserDefaults` blob and decoding it
costs **~2.8 ms cold, ~0.012 ms warm, ~1.5 MB**, and most of that 2.8 ms is `cfprefsd` and
`JSONDecoder` warm-up an AppKit process pays anyway. Against a 300 ms launch budget Isleta meets at
~96 ms, SwiftData would spend a fifth of the remaining headroom on a struct of five values and buy none
of what it is for. The trade is that `UserDefaults` gives no schema and no automatic migration, so both
are hand-written — and migration runs on the raw JSON **before** `Codable` sees it, the only point at
which a renamed key is still distinguishable from an absent one. A later milestone with a real query
pattern wants its own store rather than dragging the config record into one.

**2026-08-19 — Sparkle is wired, and has a key.** Sparkle 2.9.6 (pinned `from: "2.6.0"`) is a remote SPM
package on the **app target only**; `SparkleUpdater` is the sole file that imports it. `SUFeedURL`
points at the **public** repo's raw `appcast.xml`, not at this one — a feed on a private repo needs a
token and 404s for every user, and "no feed" is indistinguishable from "no update available" from the
outside. The EdDSA key pair was generated 2026-08-19; the private half is in the login keychain and a
password manager and never in this repo. **This value is not editable after the first release** — a new
pair strands existing installs exactly as losing the private half would.

**`SPUStandardUpdaterController` is not used, and must not be.** It is the documented entry point and it
is wrong here: when `startUpdater:` fails it schedules a modal `NSAlert` one second later, which for an
`LSUIElement` app carrying a bad key is a modal dialog at every launch on an app with no Dock icon.
Driving `SPUUpdater` + `SPUStandardUserDriver` directly turns the same failure into a log line and a
grayed button. **A Release build cannot launch without a real signing identity, and only Release shows
it**: with Sparkle embedded, hardened runtime's library validation refuses `Sparkle.framework` — *"mapping
process and mapped file (non-platform) have different Team IDs"* — because two independently ad-hoc-signed
binaries share no team. Debug survives only because it carries `get-task-allow`. Do **not** fix it with
`com.apple.security.cs.disable-library-validation`.

**2026-08-19 — deadlines are `Date`, not a monotonic clock.** An NTP step or a manual clock change shifts
every activity's expiry. `ContinuousClock.Instant` cannot express "this timer ends at 3:45pm" without a
conversion that reintroduces the problem, and a few seconds of correction mis-timing a 1.5 s HUD is a
non-event. Recorded because it is the kind of thing that looks like a bug once, in the field, and never
reproduces.

**2026-08-19 — warnings-as-errors for packages lives in `Tools/check.sh`.** Xcode compiles package
dependencies with `-suppress-warnings`, which conflicts with a manifest-level `-warnings-as-errors` and
fails the app build outright. The app target keeps `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` per §3.

---

## Open questions

Checked against the build. Anything settled since it was written is in *Closed, and how* below.

**Geometry and interaction**

- **`IslandLayout.notchBottomCornerRadius` is set by eye**, at 8pt. Apple does not publish the notch's
  corner radius and it cannot be read back — a screenshot captures what is *drawn* in the notch region,
  not the shape of the physical cutout. It is the only number in the geometry not derived from a
  measured value, and it wants a look at peek, where the island's bottom corners sit on lit pixels next
  to the cutout's.
- **The hover target is small and easy to overshoot.** The island at rest is the notch: 185×32pt. With
  another screen directly above the laptop, pushing the pointer up carries it straight through that band
  onto the screen above — the top edge is not a wall. Edge resistance, a taller catch area or a brief
  dwell would all help; none is designed.
- **Hover tightens ~300 ms early on dismissal.** When an activity goes away the hover region tightens to
  the unflanked peek before the island has finished shrinking, so a pointer resting on a flank loses
  hover early. The direction is safe — the island is shrinking *away* from the pointer, so it cannot
  oscillate — but it is a real asymmetry with the widen-first rule everywhere else.
- **Whether the hover watchdog is needed.** `IslandHitTestView` runs a 100 ms timer while — and only
  while — the island is hovered, to catch a `mouseExited` that never arrives. The failure mode is real
  in principle, but it could not be confirmed: every run showing it turned out to be a human moving the
  pointer mid-test.
- **Escape is registered globally while an island is open**, and is ambiguous once the settings window is
  open too — Escape collapses the island rather than closing the window, because the island's is a
  system-wide Carbon hot key and the window's is local. Pre-existing, low impact, newly reachable.
- **Whether `popUpContextMenu` displays from the private overlay space** is unverified on hardware.
  There was no precedent: the only other `NSMenu` in the app belongs to an `NSStatusItem` and is popped
  by `NSStatusBarButton`. The fallback is `menu.popUp(positioning:at:in:)`.
- **Mission Control on a notched display.** At `Int32.max` the island is above Mission Control's own
  chrome. On a real notch the closed island is inside the cutout and covers nothing; on a synthesized
  island it would cover the center of the space-label row. boring.notch's `dev` branch adds `.transient`
  on non-notched displays; not done here because it cannot be verified on this Mac, and
  `collectionBehavior` is where windows silently stop appearing.
- **Whether 401pt of a 1728pt display still reads as the notch growing** rather than as a bar. The wide
  HUD flanks were confirmed legible on hardware; the proportion could not be judged from the capture,
  because the screen was in a fullscreen dark app and the island's black outline was invisible against
  it. Wants a light desktop behind it.
- **At the bottom of a range the rebound's stretch is fainter than at the top.** The fill has zero width
  and scaling zero is zero, so what stretches at the minimum is the dim track. If that reads as nothing
  on hardware, the fix is to put the leading sliver's translate back **alongside** the stretch rather
  than instead of it; the two are exclusive today only because nothing needed both.

**Platform and sources**

- **Whether ambient auto-brightness fires the same `DisplayServices` callback.** If it does, the island
  would show a HUD because the sun went behind a cloud — worse than no HUD, since Apple's own does not
  appear for ambient adjustment, so macOS distinguishes them internally and we have no signal that does.
  Two windows totalling 165 s recorded zero callbacks and zero movement, but the value never moved in
  them, so that is absence of evidence rather than a negative.
- **The suppression gap, stated rather than hidden.** `ensureSuspended()` runs from the volume-key
  handler, so a level change from Control Center or a script can draw Apple's HUD if `OSDUIHelper`
  respawned since the last keypress. Suppression is complete for the case it was asked for, not
  absolute.
- **The `AudioRouteMonitor`'s net is wider than "reconnect".** The trigger is "a Bluetooth device became
  the system output", so it also fires when the user picks AirPods from Control Center or an app takes
  the route. That reads as correct — it is the same sentence, *you are listening through this now* — but
  narrowing it means remembering which devices were connected rather than which was routed. Deliberately
  not decided.
- **No real AirPods connect has been watched end to end since the entitlement fix.** The deadlock is
  gone, launch completes and the request reaches `tccd`; the prompt was queued behind a lock screen for
  the rest of that session.
- **Weather has never been looked at against a real forecast.** The demo's forecast is hand-picked, so a
  real `symbolName` on the forecast rows, a real `precipitationChance` (the "under a tenth draws
  nothing" rule has never met one) and Apple's own attribution mark are all unseen.
- **Localization has no native reviewer.** The audit proves coverage and argument-shape parity; it cannot
  judge whether a translation is *good*. Three captions are flagged for a speaker — `appearance.size.measured`
  in all three, `glance.where.caption` in French, and the Spanish welcome-back greetings, which were
  re-written to phrasings that avoid gender agreement rather than translated, because "Bienvenido" marks
  a gender Isleta does not know. **RTL is untested and uncosted**, and the named risk is concrete:
  `ActivitySlotLayout`'s `leading` and `trailing` are *physical* slivers either side of the cutout, and
  SwiftUI would mirror an `HStack` inside them under `.rightToLeft` while `IslandShapeGeometry` and the
  hit region would not follow.
- **The onboarding refusal path has never been exercised.** Calendar and Location are already granted on
  this Mac, so the `.denied` path — the deep link, `Skip`, and the copy under both — is reasoned about
  and unit-tested but not seen.
- **The settings window's appearance has not been checked on screen** since it stopped being glass on
  2026-08-28: the Mac was locked, and a locked session reports every window as 0×0. `SettingsPalette`'s
  numbers are a first pass.
- **`Unlocked.wav`'s license is unconfirmed** — see the decision above.

**Measurement**

- **No Instruments pass.** §9 asks for Time Profiler + Energy at the end of every milestone. `PERF.md`
  uses in-process Mach sampling, which is more precise for CPU but says nothing about *where* time goes.
- **`--perf-report` still cannot aim its window at a source doing work.** `--no-sources` and the demo
  flags give a delta for a source *running*; they cannot put a real connect, a real charger pull or a
  real download inside a measured window.

### Closed, and how

- **§9's idle budget was breached while music played — 0.42 % against 0.3 %.** Closed by the `CALayer`
  equalizer rewrite (2026-08-23). The trail that got there is worth keeping, all like-for-like with
  `--perf-report --nowplaying-demo`: a sine sampled off the shared clock at 10 fps cost **2.79 %**
  (sampling off `IslandScreenModel`'s clock invalidates the island's whole content tree at the
  equalizer's rate); designed frames with interpolation handed to SwiftUI `animatableData` cost
  **6.01 %**, *worse*, because it moves the redraw to display refresh, which on a ProMotion panel is
  120 Hz; a self-driving `TimelineView(.animation)` at 8–12 fps cost 0.48–0.50 %; an **explicit**
  `TimelineSchedule` cost **0.42 %**, and the difference matters because
  `TimelineView(.animation(minimumInterval:))` treats its interval as a **hint** — 8 and 12 updates a
  second measured the same.
- **The island stayed put between two fullscreen spaces.** Closed by hosting the panels in a private
  SkyLight space, where they belong to no desktop's picture. Before that: `didChangeOcclusionState`
  *does* fire on a fullscreen↔fullscreen switch, ~900 ms before `activeSpaceDidChange`; ordering the
  panel out hides it and **it never comes back**, because an ordered-out window stops posting occlusion
  changes at all; `alphaValue = 0` works because it is a window-server-side property needing no render
  pass, and the transition composites a **snapshot** captured at the instant occlusion drops, which no
  redraw can win. **No window property changes whether a desktop space composites the island into its
  picture** — five panels differing by one property each (`.stationary` removed, `level = .mainMenu`,
  `sharingType = .none`, `.fullScreenAuxiliary` removed) behaved identically. And the private SkyLight
  route's own events say nothing: `SLSManagedDisplayIsAnimating` never reports true, and 1401/1508/1329
  fire in the same millisecond as the public notification.
- **`PassThroughSelfTest` reported false failures when the screen was locked**, and separately on every
  launch. The lock case: the window server puts a full-display shield at layer 2147483646 over
  everything, so every pixel resolves to it. The launch case: the run fired before the panel had
  composited, so the five `inside-*` probes correctly found no window of ours — the fix waits for the
  precondition (`hasComposited`) rather than for an interval. **A self-test that cannot distinguish
  "broken" from "cannot be measured right now" is worse than one that declines to run**, because a red
  line that is always in the file trains the reader to scroll past the one that matters.
- **Brightness had no public route, and keyboard brightness was "genuinely unavailable".** Both wrong,
  corrected 2026-08-22, and the first shipped in four sets of release notes.
  `DisplayServicesGetBrightness` returns the real user brightness and
  `DisplayServicesRegisterForBrightnessChangeNotifications` pushes: nine real key-holds produced **419
  callbacks at a mean 1.94 ms** to a correct re-read, then **zero in the following 45 s**, unsigned and
  re-signed with `--options runtime` alike. **Why the original measurement was confidently wrong is the
  part worth keeping**: the 1.2.0-era probe drove the panel with *synthesized* brightness media keys and
  watched `AppleARMBacklight` for movement — and **synthesized brightness keys move the value by exactly
  zero on Apple Silicon**, verified again with `AXIsProcessTrusted() == true`, because the keys are
  consumed below the event-tap layer. The stimulus never fired. **A probe whose stimulus is not
  independently verified can only confirm what it already believes**, and that doubt applies to any other
  measurement here that synthesized its own input. The keyboard case was the opposite: the measurement
  was sound (the IORegistry node is marked `Privileged`, `IOHIDDeviceOpen` succeeds,
  `IOHIDDeviceGetReport` returns `kIOReturnUnsupported`) and the level is simply not in HID —
  **proving one door locked says nothing about how many doors there are.**
- **The display-brightness ramp needed coalescing, and then an exception.** One key-hold delivers 27–78
  callbacks over 0.5–1.4 s tracing the panel's easing, and — unlike CoreAudio's eight per keypress —
  **the values all differ**, so equality dedupe drops none: ~50 `.interrupting` activities per press
  unfiltered. `SystemHUDBrightnessState` publishes the first callback of a burst immediately and
  throttles the rest to 100 ms, chosen by replaying the recorded 419-callback session against candidates:
  **5.8× fewer publishes for a settled error of 0.34 %**, under a third of one notch of the sixteen
  macOS draws. That throttle then swallowed the settled value at the top of the range, so an end of the
  range now publishes inside the window — the recorded 27-callback ramp goes from 5 published readings
  to 6 and its settled error from 0.0034 to zero.
- **Launch at login never worked in 1.0.0**, and survived testing because it cannot fail on a machine
  that has already used it. `SMAppService.mainApp.status` answers `.notFound` for an app that has never
  been registered and `.notRegistered` only once a Background Task Management record exists, and 1.0.0
  read the first as "unsigned". Two probe apps on macOS 27.0 — one Developer ID signed and notarized in
  `/Applications`, one ad-hoc in a scratch directory — both reported `.notFound` before their first
  `register()` and `.notRegistered` after unregistering, so **an unsigned build is not distinguishable
  from a fresh one by `status`, and only `register()` can report a signature problem.**
- **The settings window did not take focus.** `NSApp.activate()` has been a *cooperative* request since
  macOS 14 and nothing yields to a status-menu click; measured one second after the click with Chrome
  frontmost: `isActive=false, frontmost=Chrome, keyWindow=none`. It is
  `NSApp.activate(ignoringOtherApps: true)` now, and `SparkleUpdater.activateForUpdateUI()` had the same
  line and the same fix.
- **An ordinary Quit orphaned the `mediaremote-adapter` helper, every time.** `stop()` scheduled its
  teardown on a private queue and `applicationWillTerminate` returns into `exit()`, so the block never
  ran. Teardown is synchronous through the signal now and does not return until the child is reaped,
  escalating to SIGKILL after 250 ms. **One orphan per *crash* remains and is not fixable from inside
  Isleta**, so it is collected on the way up: `NowPlayingAdapterOrphans.sweep` signals a pid only when
  `argv[0]` is `/usr/bin/perl`, `argv` carries *this bundle's* absolute script path, the uid is ours, and
  **the parent is launchd** — a live Isleta's helper is parented to that instance, never to 1. Thirteen
  tests, all but one about something the sweep must *not* kill. `FileActionOrphans` is the same shape
  with a sharper rule, because a stranded conversion worker and the user's own running copy of Isleta are
  the same executable, same name, same uid, both children of launchd — the `--file-worker` flag is the
  only thing separating them.
- **`applicationWillTerminate` does not run on SIGTERM.** `installTerminationSignals` turns SIGTERM and
  SIGINT into an ordinary quit through a `DispatchSource`. SIGKILL still cannot be covered.
- **A `Picker` writes its selection back during layout, not only on a click** — six segmented controls
  appearing wrote six assignments the moment a pane was first opened. Found by screenshot against 1,913
  passing tests.
- **`delightEnabled` and `suppressSystemHUDs` were both stored and read by nobody.** Both removed in
  schema 4; `suppressSystemHUDs` came back at schema 23 with a mechanism behind it (above), and
  `migrateV22ToV23` clears the old value rather than treating it as consent.


---

## Verification you cannot get from the test suite

`Tools/check.sh` covers the packages and the app build. These need a machine, and most need a human.
**`open -a Isleta` is the only launch that can see a permission bug**, and a Debug build must be run
through `Tools/sign-debug.sh` first or every TCC grant is keyed to a cdhash that changed on the last
build.

| Check | How |
|---|---|
| Clicks pass through to the app underneath | `--perf-report` runs `PassThroughSelfTest` against the window server |
| Hover fires and the island grows | `--hover-test` |
| Click expands, renders, and collapses | `--click-test` synthesizes a click into our own window |
| The pages turn, including two swipes with no pause | `--swipe-test` |
| Geometry on every attached display | `--perf-report` prints per-screen geometry |
| **The trackpad tap actually fires** | *Human.* macOS suppresses haptics unless a finger is on the trackpad. Confirmed 2026-08-19 |
| **Focus is not stolen** | *Human, two cases that must come out differently.* With a text editor focused, the caret must keep blinking while you click the island — and opening Settings *must* take focus. Not redone since clicks started doing something |
| **Drags over transparent panel pixels still fall through** | *Human.* Drag a file over the menu bar just left of the notch; the app underneath must still accept it. Tests AppKit's drag-destination lookup against `hitTest`, which no in-process test can reach |
| **Dragging a tile out of the shelf** | *Human.* `beginDraggingSession` from a non-key panel is compiled and reasoned about, not run |
| **The three meanings of a press on a tile** | *Human.* `--shelf-demo 30`, then on one tile: flick it out (a drag), hold half a second and move (a reorder), release (QuickLook). The nested `nextEvent` tracking loop cannot be driven by any in-process test |
| **Typing in the shelf's search field** | *Human.* `--shelf-demo 30`, click the magnifier, type. `beginSearch` measures the effect and refuses to open the field if the panel did not take key, so the failure is a magnifier that appears to do nothing. Check the caret comes back on Return and Escape |
| **QuickLook does not strand the user's focus** | *Human.* `yieldActivation(to:)` is cooperative and nothing in the process can see whether it was honored |
| **A right click on the island** | *Human.* On a tile it must open that file's actions; anywhere else it must open Isleta's own menu — and whether `popUpContextMenu` displays at all from the private overlay space is unverified |
| **AirDrop's picker, and the two folder panels** | *Human.* `--convert-demo`. Each raises a system panel, which for an `.accessory` app means taking activation |
| **A real conversion, end to end, from the island** | *Human.* `--convert-demo`, then a row on the menu. The six routes and transcription were each driven through `--file-worker`; what only a person can see is the menu, the header and the tile arriving |
| **The shelf is still there tomorrow** | *Human, and cheap.* Drop a file, quit, relaunch. Then move the file in the Finder — the tile must follow it and take the new name. Then delete it — the tile must stay and say it is missing. `shelf restored: N item(s), M missing` is the machine-readable half |
| **The equalizer pauses and resumes** | *Human.* Three captures a second apart are byte-identical while Music is paused, so the freeze is confirmed; nobody has watched the `CALayer` version *pause* and *resume* on hardware, or seen its Reduce Motion state in a real cutout |
| **Which island style is right in a real cutout** | *Human.* `--style-demo normal`, then `semiGlass`, then `liquidGlass`, on the notched built-in — the picker is gone but the flag is not, and this is what it is for. Hover and open it: does glass in the notch read as a material or as a smudge |
| **The album accent on a real cover** | *Human.* A black sleeve (it must not be invisible), a flat single-color one (it must not fringe), a busy photograph (it will be muted). The equalizer must stay white |
| **The hide list, and getting the island back** | *Human.* Settings ▸ Sources ▸ staying out of the way. The island must be gone including on hover — the half a tracking area would otherwise still fire — and come back on the next switch away |
| **Minimal mode on a display with no notch** | *Human, and it needs a Mac with no notched display at all* — a mini, a Studio, an iMac. The pill must be absent at rest, appear when something is on stage, and still peek when the pointer arrives where it would be |
| **The island is gone before the lock fade** | *Human.* Open the island, then ⌃⌘Q. Since 2026-08-25 this is expected to show most of a 0.70 s spring, by choice; what must not happen is the island being caught at full size |
| **The island bounces back *after* the unlock finishes** | *Human.* `AppDelegate.returnDelay` (1750 ms) is the dial; nothing in the process can see the end of loginwindow's dissolve |
| **The lock-screen card, on a real lock** | *Human.* `--lockscreen-demo` answers layout, content, motion and material; it cannot answer the two things the shield owns — whether the space still composites above it, and what glass samples with loginwindow behind it. Nor has the unlock been seen, because the demo has no unlock to play |
| **A pointer resting in the notch across a lock still peeks at the unlock** | *Human.* This is the case `refreshHover()` exists for and no in-process test has a real pointer |
| **The greeting appears on the way back in, and the island opens for it** | *Human.* It must arrive after the dissolve, and the island must open a beat after springing out of the notch — two events, not one |
| **The island is absent while two fullscreen spaces slide past each other** | *Human.* And it must still be there after the *second* switch. The transition composites a snapshot, so nothing in the process can observe this |
| **Desktop↔desktop** | Confirmed 2026-08-21 by probe: one panel in the private space stayed, an ordinary one beside it travelled. Re-check after any change to `OverlaySpace` or `IslandPanel` |
| **Mission Control on a notched display** | *Human.* Open it with the island closed, peeked and expanded |
| **Media keys under a real finger** | Done 2026-08-29 on a signed build launched with `open -a`: 173 tap events in eleven seconds and 26 answered pushes, one per repeat of a held key |
| **HUD suppression across a crash** | Done 2026-08-30, all four paths in the table above |
| **The rebound's fixed edge** | Confirmed 2026-08-29 by the owner's eye against a real notch. Not measured by bitmap that session — the screen was locked — but the earlier round was: with the level at 0.9 the bar's right end went 1051 → **1065.5** → 1055 → 1047 → 1048, then 1055.5 → **1065** → 1050.5 → 1048, with "Volume" stationary throughout, and its left end at **972.5 in every one of 40 frames** |


---

## Withdrawn features, and what was measured

A withdrawal is a subtraction: the code, the vocabulary case, the settings control, the shortcut, the
strings and the tests all go. **The measurements outlive the code**, because a fact about an API is not
a fact about the feature. They are repeated in the owning module's README under "Will not own" /
"Deliberately does not own"; they are kept here in full so a later reader does not have to find them.

### 1 · Notifications — withdrawn 2026-08-28

~14,900 lines removed against ~750 added: the AX observer and its thirteen siblings, the recents list,
the message view, quick reply, the link preview, per-app rules, the settings card, the onboarding page,
and about 500 lines of `AppDelegate`. Schema 19 → 20, which also deletes the parked
`com.tryisleta.notifications.preferences` key — a list of the apps a person chose to silence, with
nothing left that could read it. `migrateV8ToV9` became an empty step and stays in the chain, because
the version numbers are a ledger.

Withdrawn for the product reason, not a technical one, and the technical record is:

- **Only one dismissal exists and it deletes the notification.** A banner exposes `AXPress` plus the
  custom actions **"Show Details", "Show" and "Close"**. Close works — banners live 4997/5017 ms left
  alone and 1100/1068 ms when it is performed — and the daemon logs `removeDisplayed` **and
  `removeDelivered`**, where an expiring banner logs neither. **Close is the ✕ button.** No action hides
  the banner while leaving the notification delivered.
- **The banner window can be moved instead, and that is a third route.** Measured on macOS 27.0,
  cross-checked against `CGWindowListCopyWindowInfo`: the window is an `AXWindow`, subrole
  `AXSystemDialog`, the size of the display, and **`AXPosition` on it is settable** — where
  `SLSSetWindowAlpha` against another process's window returns success and changes nothing. The banner
  survives the move: alive off screen, expiring on its own clock (3,189 ms), the expand action still
  growing its `AXTextArea`, so quick reply works on a banner nobody can see. A banner pinned by that
  action and hidden was still alive at **+40 s**, against **4,705–4,924 ms** untouched. The move
  survives between banners. The banner element's *own* `AXPosition` is not settable and setting it
  succeeds and does nothing.
- **The costs of that route, measured in the shipping source.** Apple's banner is visible for
  **71–86 ms** on arrival, because the window is at its origin when the banner appears; Apple's banner
  animates in over roughly **300 ms**, so what is on screen is the first quarter of a slide-in. Killing
  the app while the window is displaced leaves the Mac with **no banners** until the next one arrives
  and heals it.
- **`AXExpanded` on the NotificationCenter *application* element** is the only reliable signal that the
  panel is open. The panel draws the delivered notifications in the same list, with the same subroles
  and identifiers a banner has, in the same window — and opening it **re-presents every delivered
  notification**, so a ledger that has not seen them reads them all as arrivals.
- **The tree identifies the posting app only by name.** `AXImageData` is an attribute on every element
  of a banner and nil on all of them, and there is no bundle identifier anywhere in it. (This narrowed
  an earlier claim about Accessibility in general to a claim about NotificationCenter's tree.)
- **macOS will not enumerate a user's senders.** `com.apple.ncprefs` lists everything *registered*,
  which is every app installed, and the delivered store is Full-Disk-Access walled.
- **The AX observer's idle cost, and the bug behind it.** It polled at 2 Hz on a completely idle Mac
  because *attaching* to an idle NotificationCenter succeeds — only *reading* it answers `-25204` — so
  a successful attach reset the retry counter and the backoff could never advance. Before:
  **0.38–0.42 %** against a build-failing 0.3 %. After, with all four sources running: **launch
  192.7 ms, idle 0.2194 %, memory 21.0 MB, pass-through 12/12, 8 scans per 60 s** (was 115). A test
  asserting the *delay curve* existed and passed throughout, because the curve was never wrong — only
  the counter's progression was. While a banner was up the rescan loop measured **~0.98 %**, sanctioned
  by §9's "polls only while its activity is presented" but 3× the idle budget. And a **busy**
  Notification Center cost **0.8–1.6 s of main thread across 31 scans in 300 ms** until the scan
  coalesced.
- **Resolving the posting app's icon.** The apps that notify you are **not running** — with a
  notification from each in the last hour, Mail, Messages, Calendar, Reminders and Script Editor were
  all absent from `runningApplications`, so a disk scan keyed on each bundle's **localized** display
  name is the primary route at **29 ms for 151 apps**, built once. **The first rasterization is 68 ms**:
  `NSWorkspace.icon(forFile:)` hands back a lazy `NSImage` in 1.7 ms and does nothing, and the draw that
  forces IconServices is four frames wide. And **`cgImage(forProposedRect:)` ignores the rect** — asked
  for 128 it returned Finder's icon at 256 and Calendar's at 128 in one run, so a cache's memory bound
  is only a fact if the bitmap is drawn into a `CGContext` of our own size.
- **Typing in the island cost the app's central promise for the length of one compose, and the price was
  measured before it was paid.** Three probes on macOS 27.0 with a real app frontmost:

  ```
  at rest         frontmost=Code  isActive=false  panelKey=false  Code's focused window main=true
  key, composing  frontmost=Code  isActive=true   panelKey=true   Code's focused window main=true
  after resignKey frontmost=Code  isActive=false  panelKey=false  Code's focused window main=true
  ```

  `NSWorkspace.frontmostApplication` never moves and the frontmost app's focused window stays
  `AXMain = true` — no Dock switch, no menu-bar swap, **no title-bar flicker**. `NSApp.isActive` flips
  for the duration, and on an `LSUIElement` app there is nothing on screen that draws it.
  **`IslandPanel.acceptsKeyboardInput` survived the withdrawal**: the shelf's search field is a live
  second caller, and the exception is attributed to it now. Do not widen it to a third without
  measuring again.
- **The list's hitch, and what it was not.** Opening the recents list dropped 15 frames over six opens
  and closing it 8, in a single stall of **20–45 ms landing 17–26 ms into the spring**, on a 120 Hz
  panel — against **zero frames dropped across forty repeat runs** for every other animation in the app.
  The cost tracked the row count (1 row clean, 3 rows 4 dropped over five opens, 10 rows 11, 20 rows 15)
  and was **identical with the app icons taken out**, which rules out the 68 ms rasterization, and
  **unchanged with the sources switched off entirely**, which rules out the AX observer.
  `LazyVStack` with the content extent *stated* rather than inferred: three alternating A/B pairs gave
  17/22/18 dropped before and 9/11/16 after, and 15 → 2 on the best pair on a quiet machine.
- **Two smaller findings.** `NotificationAppKey.normalize` folded against the **root** locale rather
  than `Locale.current`, because Turkish lowercases `I` to `ı` and a locale-sensitive fold files a rule
  under a key the same machine cannot reproduce after a region change. And `NSDataDetector` was rejected
  for three reasons that are not performance: it is not `Sendable`, it is expensive to construct per row
  on a lazy stack's build path, and it detects bare domains and dates — so "see you at 3 on Tuesday"
  would have acquired a link chip.
- **`SourceHub.didPromptDuringLaunch` went with it, and with it a §10 runtime check.** It worked because
  the Accessibility prompt wrote a ledger *before* asking. No remaining permission keeps such a ledger,
  so the flag could only ever have answered "no" — measuring the return value instead of the effect.
  §10 is structural on that path now; a replacement check needs a ledger of its own.

### 2 · The app switcher — withdrawn 2026-08-27

⌥Tab opened a grid of running applications, held open by the modifier, with ScreenCaptureKit
thumbnails. Ten files, `ActivityKind.appSwitcher`, `ShortcutAction.appSwitcher`, the Sources card and
the two ways in. Schema 19's `migrateV18ToV19` drops `shortcuts.assignments["appSwitcher"]` — without
it, a user who had bound a combination would have gone on losing it to Isleta from every other app on
the Mac at every launch, with no row left to clear it from. **Screen Recording is no longer a permission
Isleta has any use for**, so `ScreenRecordingAccess` and its prompt ledger went with the feature rather
than being left as a permission with no consumer.

- **Thumbnails are ~400 ms for twelve windows and nothing moves that.** Fan-out buys 1.4×; shrinking
  the tiles buys 12 ms, because the cost is per-call stream setup rather than pixels. The icon grid
  draws at **~25 ms warm**, which is why it is not the fallback but also the first frame of the granted
  switcher. **One capture per window at the size the large preview wants**: 300×200 costs 38 ms and
  3456×2168 costs 50 ms, so capturing a small tile and then a second large one on hover would very
  nearly double the cost.
- **`CGWindowListCopyWindowInfo`'s z-order looks like most-recently-used and is not**, measured with
  ten regular applications running:

  | option | time | what it saw |
  |---|---|---|
  | `.optionOnScreenOnly` | 34.6 ms | 6 entries, **2 layer-0 windows, 1 owner** |
  | `.optionAll` | 15.6 ms | 557 entries, **127 layer-0, 32 owners** |

  "On screen" means *the current Space*, so the option whose name reads as "the windows that exist"
  offers the app you are already in, and is the **slower** of the two because it has more titles to
  marshal. And `.optionAll` is **not in z-order** — the frontmost application came back sixth. Recency
  has to be remembered rather than derived.
- **The modifier can be read, not watched.** `RegisterEventHotKey` delivers a key *press* and there is
  no key-up for a modifier; the two ways to watch them need Accessibility and Input Monitoring.
  `NSEvent.modifierFlags` is a read of current state, needs no permission, and measured from a
  background process answers `0x00080000` with ⌥ down and `0x0` with it up, tracking both edges.
  `CGEventSource.flagsState(.combinedSessionState)` agreed on the same edges in the same run, carrying a
  stray `0x20000000` that is not a modifier.
- **`-3811` is two different things wearing one error code.** Per-window it was measured at **3 windows
  in 57**, consistent per app within a session with nothing in the window list predicting it — which
  reads as a property of the window. Then a run answered `-3811` for **all ten**, and a standalone
  four-window probe failed identically in the same minute having succeeded fifteen minutes earlier
  (likely the panel asleep). The same code is also a *machine-wide* state, indistinguishable from the
  per-window one except in how many windows it took — so a clean sweep must be remembered as nothing.
- **Every convenient way to detect a Screen Recording refusal lies.** `SCShareableContent.current`
  throws `-3801` claiming *"the user declined TCCs…"* **before the user has been asked**, identically in
  both states. `SCScreenshotManager.captureImage(in:)` — the overload whose signature looks most
  convenient — **succeeds while denied** and returns a flat `#2D2D31` rectangle with one unique color, so
  a switcher built on it shows twelve identical gray tiles and reports success. `CGPreflightScreenCaptureAccess`
  answers a `Bool`, so never-asked and refused are the same `false` and deserve opposite offers.
- **Screen Recording buys exactly one field**, `kCGWindowName`, and nothing in the feature read a title —
  so the roster a refused Mac built was identical, entry for entry, to a granted one's.

### 3 · The app-installed island — withdrawn 2026-08-27

An island when an app was installed or updated itself. Withdrawn for what it announced: the install had
already finished in front of the user, in an installer or the App Store, and the island was repeating
it.

- **A macOS update announced itself 522 times.** `applicationRegistered` fired **522 times in 54.6
  seconds** across 26A5416b → 26A5421a, and a four-second sliding window over their timestamps peaks at
  **245 alive at once**. Every one of those bundles lives in `/System/Library/CoreServices`, which holds
  **369** `.app`s and which no icon lookup was ever going to reach.
- **The inference was wrong, not the measurement.** The probe recorded exactly one callback
  per install and per version bump, with zero on launch or quit. That is true and correctly measured,
  and it is a statement about *one app being installed*; the population it was measured over was one.
- **An allow-list, never a deny-list**, and the probe that settled it: Safari answers
  `NSWorkspace.urlForApplication(withBundleIdentifier:)` with
  `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app`, so a rule spelled "skip
  `/System/Applications`" would let it through. Third-party apps answer plainly —
  `/Applications/Ghostty.app` — even on a sealed volume where `/Applications` is a firmlink, which the
  API does not resolve away.

### 4 · The disk island — withdrawn 2026-08-28

Same reason: every app installed outside the App Store mounts a `.dmg`, so the "Connected" moment
arrived on top of the Finder window that had just opened for it. **`WillUnmount` precedes `DidUnmount`
by 72 ms** for one eject.

### 5 · The month grid — withdrawn 2026-08-28

A six-week grid with the chosen day's events beside it, reached by clicking the date. Replaced by the
two days a person actually asks a notch about. `isShowingMonth` became `isShowingSchedule` everywhere
it was spelled, so the next reader's question ("where is the month?") is impossible to ask.

- **The cost was never the fetch.** The EventKit predicate is warm and one day of it is **2 ms**. It is
  the *shape* of the answer: an event spanning days marks every day it touches, and an all-day event
  arrives as an ordinary range in its own calendar's time zone rather than midnight-to-midnight in the
  reader's. That is why the surface that replaced it calls `events(on:)` once per day rather than
  fetching two days and splitting them by hand, which is where a merged fetch goes quietly wrong for
  anybody travelling.
- **Two of its decisions carried over to the live schedule surface.** The island is **440pt** wide while
  a drill-down is up — at 368 the grid took 194 of the 336 drawable points and the chosen day's events
  got **126**, four points above `minimumEventColumnWidth`, below which the column is not drawn at all;
  440 gives that column **198**. And it wears no page indicator, because a drill-down is not one of the
  three pages. **Measured while pinning the width clamp**, on the 1728pt built-in: the open island's top
  flare curves **24.46pt** past its own body on each side against a `panelMargin` of 24 — so a body at
  the full `maxExpandedBodySize.width` of 560 puts half a point of that curve outside the panel, where
  it is clipped. 440 leaves 59pt each side; the ceiling is a guard rail rather than a size to design to.

### 6 · The player bar — withdrawn 2026-08-28

A slim always-visible Now Playing bar for notchless and external displays. Seven files, the General
pane's card, ten localized strings, `--playerbar-demo`, and schema 21, which also drops the parked
`com.tryisleta.isleta.playerbar` key that `migrateV12ToV13` had left for a downgrade — there is no build
left to downgrade *to* that would draw a bar from it.

- **A permanently visible window *can* hold §9.** No clock anywhere, the equalizer in `CALayer`s rather
  than a `Canvas`, and the playhead a single `CABasicAnimation` per *event*.
- **It was not in the private overlay space, so a desktop slide carried it.**
- **At zero opacity the window server said "not ours" while its own `hitTest` said otherwise** — the
  `islandPath`-is-nil bug pointing the other way.
- **Its localization finding is the one most likely to be needed again.** A 154pt text column had no
  slack in any language: "Now Playing is unavailable" is **149pt in English against 159 (de), 167 (fr)
  and 165 (es)**, after each had already been cut to the shortest wording that still said the *feature*
  was unavailable rather than that playback had failed.

### 7 · Downloads — withdrawn 2026-08-28

Download-progress islands. Five files, `ActivityKind.transfer` with its glyph, priority, expiry,
plurality, flank affinity and name in three languages, and schema 22. **`NSDownloadsFolderUsageDescription`
left `Info.plist`**, so Isleta no longer asks for a folder at all and its row under Privacy & Security ▸
Files and Folders is gone.

- **Only Safari could ever be drawn.** Safari's `.download` package publishes a live
  `com.apple.progress.fractionCompleted` and is named for the user's real file. Chromium — Chrome,
  Brave, Arc, Edge — publishes **no progress xattr at all** (grep count over a full 21-second download:
  **zero**) and calls its part file `Unconfirmed NNNNNN.crdownload` until the instant it finishes. So
  one browser got a filling bar with a file name and every other an indeterminate bar with no name,
  with nothing on screen explaining why. **There is no reported total to compute a percentage against.**
- **The Downloads folder's TCC gate *blocks* rather than refuses.** Re-measured from a freshly built,
  ad-hoc signed binary running as its own responsible process with launchd as parent:
  `open("~/Downloads", O_EVTONLY)` **had not returned 25 seconds later**, while `~/Library/Mail` and the
  `usernoted` group container answered `EPERM` in **under a millisecond in the same run**. That is a
  dialog, and the call is synchronous through it — so every such open belongs on a private queue, and
  nothing may make one on the launch path. The original "push, free, no permission" measurement had been
  taken from a shell, where TCC judges the request against Terminal.
- **`~/Library/Safari/Downloads.plist` is dead** while `ls` and `stat` say it is alive.
- **A Safari download raises an `.attrib` event about every 2.3 s** for the length of the download.

### Other subtractions, outside the canonical seven

- **The keyboard-backlight HUD** — removed 2026-08-27, level and switch together, with
  `SystemHUDKeyboardBrightnessState` and `SourceToggles.keyboardBrightnessHUD` (swept by
  `migrateV17ToV18`). The reasoning is the standing decision above. What was measured, and it was a
  working private path: **`CoreBrightness`'s `KeyboardBrightnessClient` answers an unentitled process
  and pushes 2–6 ms after a change.** Its notification keys are **prefixed `KeyboardBacklight`, not
  `KB`** — despite handlers named `KBBrightnessPropertyHandler:` — and `KBBrightness`, the bare
  `Brightness` and twenty-one other spellings produced **zero callbacks**, with registration returning
  `void` so a wrong key is indistinguishable from a quiet machine. The real names were found by walking
  the `__cfstring` section of the loaded image, which is the general move when a private API's string
  constants are the thing you need. There is **no ramp** — two or three callbacks per change — but a lot
  of self-motion: idle dimming fired unprompted 650 ms after a manual change, four callbacks, level to
  zero, and ambient light suppresses the backlight entirely. `isBacklightDimmedOnKeyboard:` is the one
  dependable "not the user" flag; `KeyboardBacklightUserOffset` and `KeyboardBacklightManualBrightness`
  exist as constants, look exactly like the discriminator, and **never fired once**, including with
  auto-brightness left on. And **`setBrightness:forKeyboard:` returns `YES` and changes nothing**
  whenever the backlight is suppressed or idle-dimmed, which in a lit room is most of the time.
- **The standing glance** — removed 2026-08-28. `CalendarSource` published the day and the sky as an
  `.ambient`, never-expiring activity, and `ActivityPriority.displacesPeers` is false at that level, so
  `ActivityStack.precedes` broke the tie on **arrival order**. The glance is published at launch and
  music starts later, so on every ordinary day the glance was the primary, took the leading flank that
  `.nowPlaying` also asks for, and demoted music to a companion holding the trailing sliver only. **It
  silently disabled a second feature**: `trackLipContent` gates on the leading slot being `.nowPlaying`,
  so hovering the sleeve for the title could not fire at all on a Mac with one event in the diary. The
  fix had to be a subtraction rather than a flank rule, because any rule that hands music the leading
  sliver hands it the trailing one too. The day and the sky stay, as the snapshot the pages already read.

### Measured and not built

Kept because each closes a door somebody will otherwise re-open.

- **Lyrics.** Closed through every Apple route; every symbol that suggests otherwise is the *provider*
  half of the API.
- **A live waveform equalizer.** The DSP is the cheapest thing in the report — a 1024-point real FFT
  reduced to six bands costs **0.015 % of a core at 120 Hz**. The tap is not: it needs
  `kTCCServiceAudioCapture`, the switch users associate with screen recorders; it adds **+3.5 to
  +4.0 percentage points inside `coreaudiod`**, where `--perf-report` cannot see it; **denied, it fails
  silently and successfully** — 688 callbacks, every call returning `noErr`, peak amplitude 0.0, so the
  user gets a permanently flat equalizer and no error anywhere; it blocks the calling thread for the
  life of the TCC prompt; and it was reproduced **wedging the system's entire tap path for twelve
  minutes** after a client died. ScreenCaptureKit is strictly worse — Screen Recording, and no
  audio-only filter exists.
- **An audio-quality badge from the Now Playing payload.** Not among the adapter's keys, nothing shaped
  like it in `MediaRemote.h`, and the one adjacent field (`mediaType`) answers
  `MRMediaRemoteMediaTypeMusic` for everything. (Apple's own format badge on the lock-screen card is read
  out of Music's bundle at runtime, which is a different thing.)
- **MP3 export.** macOS decodes MP3 and will not encode it below AVFoundation: `EncodeFormatIDs` has no
  `.mp3` while `DecodeFormatIDs` does, `AVAssetWriter(fileType: .mp3)` raises an **uncatchable** ObjC
  exception straight past a Swift `try`, and `afconvert -hf` lists `'MPG3' = MPEG Layer 3` as a file
  format while failing on it — the table reads as a capability list and is not one. A test pins that no
  conversion route targets `mp3`, because the failure would be a process that dies rather than an error
  the user can see. The honest export is a vendored `lame` (0.35 MB, LGPL, zero non-system dylibs,
  206 ms for a 10 s file), which the dependency decision permits and which owes what the worker already
  owes.
- **Messaging integrations.** Telegram is **20.53 MiB** and must be `dlopen`ed; Slack is dead; WhatsApp
  needs the owner.
- **A Finder extension.** Finder Sync's contextual menu is **never asked for on macOS 27**, with a
  paired control proving the toolbar item *is*; and an app extension without
  `com.apple.security.app-sandbox` simply does not exist, with `pluginkit` answering nothing and
  `codesign` happy.
- **Taking over Apple's banners and HUDs by hiding their windows.** `OSD.framework` loads and
  `OSDManager` is real, and every method on it *shows* a HUD — it is the API behind Apple's, not a way
  to stop it. SkyLight's 2,915 exports hold nothing for it. And the cross-process trick underneath every
  "just hide their window" design **returns success and does nothing**: `SLSSetWindowAlpha` against
  another process's window answered 0 and `SLSGetWindowAlpha` read the window back at 1.0. Booting out
  `com.apple.OSDUIHelper` and claiming its MachService name makes Isleta *become* the HUD with no race —
  and the bootout outlives a crash, leaving the user with no volume HUD until logout. `SIGSTOP`, which
  ships today, has the same shape and the same cost, taken knowingly and repaired at launch.

---

## The brightness keys — 2026-08-30

Volume shipped first and brightness was deferred on two named risks: the ladder was unmeasured and
external displays still are. The first is now measured; the second is unchanged.

### Brightness is not volume's ladder

Measured on macOS 27.0, Mac15,9, built-in panel, by parking the panel off-grid with
`DisplayServicesSetBrightness` and reading back after each press had **settled**:

```
1.000000  0.917500  0.835000  0.752500  0.670000  0.587500   delta -0.0825 each
0.010000 -> 0.092500                                          delta +0.0825
0.100000 -> 0.010000 -> 0.000000                              the floor, and off below it
```

The grid is `0.01 + n × 0.0825` for `n` in `0...12` — landing exactly on 1.0, since
`0.01 + 12 × 0.0825 = 1.0` — plus **0.0 as a separate stop below the floor**. Thirteen lit levels and
an off, against volume's sixteen even notches from zero. `BrightnessStep` is a separate type for that
reason; a shared one would need a floor, an offset and an extra stop passed into it.

**Settling is what made it readable.** A first pass sampled every 30 ms and produced deltas of
0.0137, 0.0184, 0.0107, 0.0062 — six different numbers that were not steps at all but points on the
ramp the system animates. A `0.1 -> 0.01, delta -0.090000` line in the same log is **two presses
merged into one plateau**, not one press of 0.09: `0.09` is not a step and `0.0075 + 0.0825` is. That
misreading reached a test expectation before the arithmetic caught it.

### `DisplayServicesSetBrightnessSmooth` takes a delta, and shipped a bug

It was chosen for its name, on the reasoning that a brightness write should glide. It has the same C
signature as `DisplayServicesSetBrightness` and **different semantics** — measured, five cases:

```
from 0.5000  smooth(+0.0825) -> 0.5825      from 0.8000  smooth(-0.3000) -> 0.5000
from 0.5000  smooth(-0.0825) -> 0.4175      from 0.5000  smooth(+0.0000) -> 0.5000
from 0.3000  smooth(+0.2000) -> 0.5000      all five match current + argument
```

Handed a *level* it adds it to the current one. A press asking for 0.9175 from 0.75 asked for 1.6675,
clamped to 1.0, and every press after that did the same. The hardware symptom was **"brightness down
does one notch, I don't see it, then nothing"** — one jump to maximum, then `pushed at its maximum`
forever. Reported by the owner; the log made it unambiguous.

The absolute setter is exact on every rung (`0.01`, `0.0925`, `0.4225`, `0.5875`, `1.0`, `0.0`) and is
what ships. The smooth one *could* be used correctly with `target - current` and deliberately is not:
an absolute write to a rung is **self-correcting**, where a relative one accumulates float error and
a single bad read leaves the panel permanently offset.

Both readings settle in **0 ms** — the getter reports a written value immediately even while the
backlight is still visually travelling — so nothing tracks a pending target. That was the other
candidate explanation for the same symptom and it was wrong.

### The lock screen gap

Found because a screen lock interrupted a test. The helper stayed frozen while locked, and on the
login screen `loginwindow` captures every event: Isleta's tap receives nothing and its panels are off
screen. A level key there would have changed the level and shown **nothing at all** — no Isleta HUD
and no Apple HUD, from a Mac that had both a minute earlier. Worse than either alternative, and
invisible from a running session because it only happens where Isleta cannot see.
`SystemOSDSuppressor.screenLockDidChange(locked:)` thaws for the length of the lock and re-freezes on
unlock, leaving `isSuppressing` alone — the user's intent has not changed, only the screen.

### What shipped

`BrightnessStep` (12 tests, every number off the hardware), `SystemBrightnessControl` behind
`SystemBrightnessWriting`, `SystemHUDSource.replacesBrightnessKeys`, and
`IsletaConfiguration.suppressBrightnessHUD` at schema 24 — **a second switch, not a widening of the
volume one**. Volume is recoverable if Isleta gets it wrong; brightness is the one that leaves
somebody unable to dim their screen, and one control would make accepting the cheaper risk mean
accepting the dearer one. `suppressible` is now `[.volume, .mute, .brightness]`.

Unlike the volume path, this one **publishes its own HUD**: a CoreAudio write fires a property
listener, and a DisplayServices write has no such guarantee for a change Isleta made itself.

### Still open

- **External displays.** Unmeasured. The keys drive the built-in panel regardless of where the menu
  bar is, and that is the only panel tested.
- **⇧⌥ quarter-steps.** The reading came back at a full ±0.0825 for presses meant to be modified,
  which is either "brightness has no fine step" or "the modifiers were not held". `fineNotch` exists
  and nothing sets it, rather than shipping an unverified behaviour.


## 2.0.1 — the schedule's bottom edge, and the page carousel

### The island shrank under an open schedule

Reported with a screenshot, 2026-08-31: opening the calendar's day view, "the bottom seemed to move
up even though most of the time it's the right height."

`AppDelegate.expandedContentHeightForStage` gated the schedule's height on
`kind == .glance || kind == .meeting`. **`.glance` is never on stage** — the kind was withdrawn when
the calendar stopped standing on the stack as an ambient activity, and `IslandScreenModel.drawsPages`
says so in as many words, keeping the case and never matching it. So for the two ordinary stages —
nothing on stage, or a track playing — the branch could not answer and the function fell through to
the **home page's** height.

The reason it was intermittent rather than constant is the reason it survived: opening the schedule
never asks. `toggleGlanceSchedule` computes the height itself and pushes it to the controller, so the
open is correct every time. The *next* stage change asks — a track change, a HUD, any activity at all
— is told the home page's height, and shrinks the island's bottom edge up through a surface still
being drawn at the schedule's. "Most of the time" is every moment between the click and the next
thing that happens on the machine.

The branch is now ungated and ordered where `IslandScreenModel.pagesOwnBody` puts it: below the drop
history and Up Next, above the meeting and the pages. `expandedContentWidthForStage` was already
ungated, and the two disagreeing was the tell.

**This is the third bug of one shape**, after Up Next's stale flag and the sixth row of the schedule
column: the shell decides the island's height from one description of what is on screen and
`IslandRootView` draws from another. `GlanceScheduleStageTests` pins the half of it IslandUI owns —
that the schedule owns the body over *every* stage a page is drawn under, `.glance` included, and
that Up Next and the drop history still take it away. What is still not pinned is the shell's own
function, which is private to `AppDelegate` and has no seam; the honest statement is that the order
is stated in prose in three places and tested in one.

### The page carousel stutters, and the island's own morph does not

Full measurements in `docs/PERF.md`. In short: `--hitch-test` was driving an **empty** island and had
no page swipe in it at all, so it reported clean. With a day, a player and a forecast on the three
pages a swipe drops ~12 frames in 9 stalls per four turns; with nothing on them it drops zero.

The cause is not the drawing. Every page read `model.contentMetrics`, which the drag re-lerps ~120
times a second because the island's bottom edge follows the finger — so under Observation all three
live pages re-evaluated their whole bodies on every sample, for a width that is the same on all three
pages and cannot change during a turn. `IslandScreenModel.contentBodyWidth` is the width without the
drag; the rain field, the one layer inside a page that genuinely reads a *height*, now takes its
ground from the caller.

Two things were measured and are **not** the cause, and both are worth not re-investigating:
WindowServer CPU is indistinguishable between an animating run and an idle window of the same length
(45.9/52.9% against 48.9/50.6%), and the close, the stow and the space re-entry drop zero frames in
every arm. A space switch with an island open is a `collapseAll()`, which is that same close.

`--hitch-test` now drives the swipe, the space hide/re-entry and a staged full day, and
`--hitch-legacy-width` is the control arm for the change above. Paired serially under `caffeinate -d`,
all four pairs favour the fix: 38.5 dropped frames and 25.5 stalls per eight turns become 23.0 and
15.25, about 40% on both.

### A day with nothing on it said nothing

Reported alongside the height bug: "some days are missing events / maybe they are truly empty." They
were truly empty. `CalendarSource.events(on:)` fetches start-of-day to start-of-next-day for both
days, sorted and filtered to the chosen calendars, and the counts go in the log — the fetch was never
the problem. The column said nothing about it.

Three states drew the same picture as a failure. An empty **today** with a full tomorrow opened at
"TOMORROW" with no word about the day the surface is headed with. An empty **tomorrow** made the
column simply stop, with no way to tell an empty day from one left off. And two empty days drew a
blank column — `GlanceSchedulePlanTests.anEmptyDayDrawsNothing` asserted exactly that, on the
argument that a heading with nothing under it says nothing. **That is right about the heading and
wrong about the column**: a surface that just stops is read as broken.

`showsTodayEmpty` and `showsTomorrowEmpty` are decided in `GlanceSchedulePlan` rather than in the
view, and each **costs a row**, charged against `entryCapacity` like everything else — the island's
height is agreed before the transition and there are five rows to spend, so a line that did not pay
would be drawn outside it. `rowCount` is the invariant in one place and `noCombinationOverflows`
walks 25 shapes of the two days.

Two rules were arrived at rather than chosen. Today's all-day **pills do not count**: they are in the
other column, and a day whose only entry is a birthday still has no hours in it, which is what the
right column is. And a tomorrow **squeezed out by a full today is never called empty** — the flag is
asked of the inputs rather than of what was fitted, because the alternative is the surface lying
about the one day it is there to look ahead at.

The old whole-column string said "Nothing left today", which was wrong twice over: it stood in for
tomorrow as well, and this surface shows the **whole** day rather than what is left of it
(`GlanceModel.todayEvents` is deliberately not the look-ahead). Withdrawn, with its three
translations, and replaced by `glance.schedule.emptyToday` / `emptyTomorrow`.

`--glance-demo --schedule --empty` is how the state is looked at, and it needed its own flag for the
reason the rest of that demo does: a granted-but-quiet calendar is not a state anybody can arrange on
demand, which is why nobody had looked at this surface on a day that had nothing on it.

**Two traps in the harness, both of which produced numbers that were believed.** A sleeping display
stops the link and the run prints as a flawless score — only the verdict says `INCONCLUSIVE`, and the
cheap check is the frame count (~960–1010 for a valid 8-cycle swipe window). And **two `--hitch-test`
runs must never overlap**: each stands up its own island on the same display, and pairs taken that
way came out as washes where the serial comparison is 40%. Both are written up in
`docs/BUILD-AND-TEST.md`.
