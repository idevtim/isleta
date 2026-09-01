# Build and test

How Isleta is built, tested and run, and the build-system traps that produce impossible errors.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

`Tools/check.sh` is the whole check: it builds and tests every package under SwiftPM against one
shared scratch path, runs `Tools/localization-audit.py`, builds the app with `xcodebuild`, then runs
the audit a second time against the *built* app — the half that catches a retired `.lproj` neither
build system prunes. Run it before calling anything done.

```sh
./Tools/check.sh                                          # packages + tests + localization + Isleta.app
swift test --package-path Packages/IslandKit              # 150 tests
swift test --package-path Packages/IslandUI               # 709 tests
swift test --package-path Packages/IslandKit --filter IslandShapeTests
```

Tests are **swift-testing** (`@Suite`/`@Test`/`#expect`), not XCTest — `--filter` matches the *type*
name (`IslandShapeTests`), not the `@Suite` display name, and a filter that matches nothing exits 1.

**`Tools/check.sh` builds Debug, so a Release-only warning-as-error escapes it.** Caught 2026-08-23:
`let isUpNextDemo = false` behind `#else` made an `if` branch provably dead in Release, which
`SWIFT_TREAT_WARNINGS_AS_ERRORS` turns into a build failure — green check, failed release. Any
`#if DEBUG` flag read into a `let` must have its *call site* behind the same `#if`, not just its
declaration.

**A Debug build cannot hold a developer entitlement, which is why there are two entitlements files.**
Debug is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), and an ad-hoc signature cannot carry
`com.apple.developer.*` — Xcode refuses with "has entitlements that require signing with a
development certificate". So `Config/Isleta-Debug.entitlements` omits WeatherKit and
`Config/Isleta.entitlements` (Release) carries it. That is the accurate statement rather than a
workaround: a Debug build has no weather, logs `weatherkit entitlement absent`, and draws the
calendar alone. To exercise the weather, build Release with the Developer ID identity and
`Config/Isleta.provisionprofile`; the log says `weatherkit entitled` when it worked.

**One scratch path for every package, and it is why `check.sh` sets `--scratch-path`.** Left to
itself each package keeps its own build directory with its own cached copy of `IslandKit`, and
SwiftPM does not invalidate that copy when a *new source file* is added to a path dependency. Adding
a file to `IslandKit` then makes every dependent package fail with `cannot find type` — once each,
naming a type that is right there in the file you just added — until it is built a second time. The
error names the wrong file and the wrong problem; the shared scratch path is the fix.

**Warnings-as-errors lives in `Tools/check.sh`, not in the package manifests.** Xcode compiles
package dependencies with `-suppress-warnings`, which conflicts with a manifest-level
`-warnings-as-errors` and fails the app build outright. The script passes
`-Xswiftc -warnings-as-errors` under SwiftPM instead; the app target keeps
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`. Don't "fix" this by putting it back in the manifests.

The app target is `Isleta.xcodeproj` (arm64 only, deployment 26.0, strict concurrency complete,
hardened runtime on, `Config/Isleta-Info.plist` + `Config/Isleta.entitlements`), with the five
packages wired in as local package references. `check.sh` builds into `.build/xcode`, so:

```sh
.build/xcode/Build/Products/Debug/Isleta.app/Contents/MacOS/Isleta --perf-report 60
```

runs headless, idles for the window, prints launch/CPU/memory against the §9 budgets plus the
pass-through self-test and per-screen geometry, and exits. `--debug-overlay` starts with the overlay
up, `--probe-verbose` logs every pass-through probe individually, **`Tools/sign-debug.sh` signs the Debug build with the Developer ID identity**, and any
permission-dependent feature needs it. A Debug build is ad-hoc signed, TCC keys a grant to the
signature, and an ad-hoc cdhash changes on every build — so Accessibility is granted, the next
`xcodebuild` runs, and the app is silently untrusted again with nothing on screen to say so. Run it
after every build you intend to test permissions against. `--request-accessibility` (Debug only)
raises the system's own grant prompt, which is the reliable way into a Privacy & Security pane that
has been reorganized more than once.

`--media-key-test` posts a synthetic
brightness-down media key and reports whether Isleta's own monitor saw it — the one fact about the
limit rebound's *repeat* that no unit test can settle, since TCC judges the responsible process and a
shell probe would answer about Terminal, `--hover-test` warps the pointer
into the notch and back to prove hover tracking fires, `--pointer-hold-test` does the same with a
calendar alert on stage and waits out its dwell, to prove the hold reaches the coordinator from the
hover callback (both report INCONCLUSIVE rather than a verdict if a hand moves the pointer, so
run them on an idle machine), `--activity-demo` (Debug only) puts a
calendar alert and then a greeting on stage so the two content-sized islands can be looked at without
waiting for a real one, `--device-demo` (Debug only) announces three connecting devices at falling
battery levels so the flanked island and the ring's green-to-amber threshold can be seen in one run
without putting AirPods in and out of their case, `--hud-demo` (Debug only) shows five HUDs in turn — volume,
mute, brightness, then the volume at each end of its range — so the widest island, the volume glyph
filling as the level rises, and the lean at the limits can all be looked at without changing the
volume or the brightness of the machine it is being looked at on, `--power-demo` (Debug only) walks
the seven power announcements — on battery, two low thresholds, Low Power Mode on, the charger going
in, Low Power Mode off, charged — six seconds apart, which is the only way to see the widest island
and all six of its words without unplugging anything or waiting a working day for a battery to reach
5 %,
`--upnext-demo` (Debug only) puts a track four seconds outside the Up Next window and
opens the island on it, so the peek's *transition* can be watched without sitting through a song —
it is the only thing the island draws that is triggered by the clock rather than by an event, so
there is otherwise no way to make it happen, `--convert-demo` (Debug only) writes an image, an RTF
and a CSV into a scratch directory, puts them on the shelf and opens the actions menu on one of
them — its own flag rather than a use of `--shelf-demo` because that one's files are in
`/System/Library` and a conversion writes beside its source, so every row there would correctly fail
with "that folder cannot be written to", `--file-worker` is **not** a demo: it is the flag that
turns this same binary into the short-lived conversion child, reads one JSON request from stdin and
writes newline-delimited JSON events back (it is also what the orphan sweep identifies its own
strays by, and the only thing separating a stranded worker from the user's running copy of Isleta),
`--lockscreen-demo` (Debug only) puts both lock-screen surfaces — the card and the padlock at the
notch — on the **unlocked** desktop with whatever is playing, so the one surface that otherwise
costs a lock, a look and a login to inspect can be looked at; it hosts the panels in no space at
all (`DesktopLockScreenSpace`), which is why they are visible on a desktop, and it therefore cannot
answer the two questions the shield owns — whether the real space still composites above it, and
what Liquid Glass samples with loginwindow behind it — and it eats clicks over the card's rectangle
for the length of the run, `--settings [pane]` opens the settings
window on a named pane, `--onboarding [page]` opens the first-run flow on a named page and
`--onboarding-reset` puts `OnboardingLedger` back to never-onboarded (the flow is otherwise one look
per machine), `--hud-consume-test` reports whether Isleta's event tap
actually *consumed* the volume key rather than merely seeing it — the only way to tell suppression
apart from a tap that returns the event, and it must be run `open -a Isleta.app --args
--hud-consume-test --no-sources`, `--export-logs <path>` writes the "Export Logs…" bundle there
without the save panel and exits, and `--verbose-logging` (or `defaults write com.tryisleta.isleta
VerboseLogging -bool YES`) raises the log to `debug`.

## `--hitch-test`, and the one way it lies to you

`--hitch-test [cycles]` drives every transition the island has while `AnimationHitchProbe` counts
frames on a display link attached to the island's own window, and reports what each one dropped. It
is the instrument for "does this stutter", because Instruments cannot answer it: the SwiftUI
instrument charges 100 ms of its own `backtrace()` work to every transition, and the Time Profiler
samples the main thread only while it is *on CPU*, so a stall spent waiting on the window server
produces no samples at all and reads as nothing happening.

**Run it under `caffeinate -d`, and read the verdict line before any of the rows.** A display link
stops firing when the display sleeps, and a run that measured nothing prints as a perfect score —
every row zero frames, zero dropped, zero stalls. The verdict says `INCONCLUSIVE — the display link
never fired`, and it is the only place it says so. Six runs were read as a fix before that line was
read; the tell in the header is `display running at 0 Hz`.

```sh
caffeinate -d .build/xcode/Build/Products/Debug/Isleta.app/Contents/MacOS/Isleta \
    --hitch-test 8 --glance-demo --rain
```

**An empty island does not stutter, so measure a full one.** The three pages carry a day, a player
and a forecast, and with none of them present the swipe drops nothing at all — the same swipe with
`--glance-demo --rain` drops a dozen frames. `--nowplaying-demo`, `--glance-demo`, `--rain` and
`--snow` are how the carousel gets something to carry; the run stages a full day of its own before
the swipe steps, so the flags' own timed activities cannot land inside a measurement window.

**Never run two of them at once.** Each stands up its own island on the same display, so the two
animate against each other and both arms are measured under a load that is in neither of them. That
does not add scatter around the right answer, it moves it: pairs taken with a second run in flight
came out as washes where the same comparison run serially is 40%.

**Check the frame count before believing a zero.** A valid 8-cycle swipe window delivers ~960–1010
frames; a zero-drop row with no frames beside it is a display that went to sleep.

**Interleave the arms.** Everything here is a paired delta — see `docs/PERF.md` — and the numbers
drift upward across a long run, so only the within-pair difference means anything. `--hitch-legacy-width` is the control arm for the page
carousel's own change and exists for exactly that (`IslandScreenModel.contentBodyWidth`), the way
`--hitch-rows N` and `--hitch-no-icons` answer *why* rather than *whether* for the drop history.

**The debug affordances are `#if DEBUG` and are not in a release build.** ⌥⌘D (overlay), ⌥⌘P
(probe at pointer) and "Copy Diagnostics", and their three status-menu items, exist only in Debug —
`RegisterEventHotKey` is system-wide and exclusive, so shipping the first two would take both
shortcuts from every other app on the user's machine for features they cannot see; Copy Diagnostics
shipped through 1.0.1 and was pulled once "Export Logs…" carried the same report. "Export Logs…"
**does** ship: it is what a person is asked for in a bug report, holds no shortcut, and writes one
file — diagnostics plus the log history — where the user chooses.

**Logging goes through `IslandLog` (IslandKit), never `print`, `NSLog` or a bare `os.Logger`.**
`IslandLog.<category>.info("…")` writes to the unified log *and* to `~/Library/Logs/Isleta/isleta.log`
(size-rotated), which "Export Logs…" bundles with the diagnostics report. Categories are a fixed
taxonomy of *concerns* (`space`, `nowPlaying`, `shelf`, `calendar`, `weather`…), not components —
add one only for a new concern. Two rules, both load-bearing: **nothing the user did not write goes
in** (no track titles, file names, event titles, cities or serial numbers — the file is emailed to
strangers and the unified log is readable by every process), and **nothing on the hot or idle path logs** (`debug` is an autoclosure
and free when off; `info` is for things that happen once per user action or system event). There is
no default sink — tests never write into the user's home — and lines logged before `IsletaMain`
attaches one are replayed in order. Quit drains the sink synchronously, for the same reason
`stopAndWait()` exists.

Entry point is `IsletaMain.swift`, not `@main` on the delegate: `@main` on an
`NSApplicationDelegate` resolves to `NSApplicationMain`, which finds its delegate in the main nib —
Isleta has no nib, so the delegate was never set and `applicationDidFinishLaunching` never ran.
