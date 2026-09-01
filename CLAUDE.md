# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Isleta is

A macOS menu-bar agent (`LSUIElement`, no Dock icon) that turns the MacBook notch into an
interactive animated surface — the Dynamic Island, done properly for the Mac. On notchless displays
it renders a floating island pinned to the top center.

- Bundle id `com.tryisleta.isleta`, site `tryisleta.com`
- Distribution: Developer ID + notarization + Sparkle. **Not** the Mac App Store — sandbox is off
  because Accessibility and the `mediaremote-adapter` Perl helper are incompatible with it.
- **The bar:** a Mac user cannot tell it isn't an Apple feature. Every curve, radius, weight, and
  millisecond is judged against that. "Close enough" on a cross-platform toolkit is wrong here.

**Two surfaces, and keeping them apart is the design.** *Pages* are what a person browses — `home →
music → weather`, wrapping, turned by a two-finger swipe on an open island, with an indicator under
the cutout. They are a fixed enum (`IslandPage`), so they are always all there. *Activities* are what
arrives: a volume key, a timer finishing, a call, a device connecting. They take the stage because
something happened and they leave on their own. A feature that announces something the user is
already looking at belongs to neither, and has seven times now been withdrawn — see below.

**`docs/PROGRESS.md` is the status file** — milestones, decisions that override this brief, and open
questions. Read it first and keep it current in the same commit as the work it describes.

## Where the detail lives

**This file is the map, not the record.** Everything below was measured on real hardware, most of it
after a session was lost to it, and it is deliberately not repeated here. Read the file for the area
you are about to touch, *before* you touch it.

| Before you… | Read |
|---|---|
| build, test, run the app, or debug a build failure that looks impossible | `docs/BUILD-AND-TEST.md` |
| touch the panel, screen geometry, hit testing, or space transitions | `docs/ARCHITECTURE.md` then `docs/TRAPS.md` |
| add or debug a data source, or reach for **any** system API | `docs/PLATFORM-CONSTRAINTS.md` |
| write SwiftUI or AppKit anywhere in this codebase | `docs/TRAPS.md` |
| animate anything, or change hover, click, swipe or haptics | `docs/MOTION-AND-INTERACTION.md` |
| add a string a person will read on screen | `docs/LOCALIZATION.md` |
| name a feature, a setting, a `UserDefaults` key or a test | `docs/NAMING.md` |
| claim something is fast enough, or finish a milestone | `docs/PERFORMANCE.md` |
| add a dependency, use a private API, or add a persistence layer | `docs/WORKING-AGREEMENTS.md` |

The files above are the full record. The raw probe sessions those findings were distilled from are
not published — `docs/PLATFORM-CONSTRAINTS.md` and `docs/TRAPS.md` carry every finding that survived
them, with the date and the control it was measured against, and they are what a claim here is
checked against.

**When a finding changes, edit the doc, not this file** — and say what was measured, on what OS,
against what control. A claim with no measurement behind it is how three of the entries in
`docs/PLATFORM-CONSTRAINTS.md` came to be wrong for a whole release.

## The repository, and what is not in it

**Isleta is open source under the MIT License as of 2026-09-01.** Source, releases and the appcast
are all `idevtim/isleta`, which is public and must stay public — Sparkle's feed is served from it by
raw URL, and a private repo would 404 for every user without a token.

Some files are deliberately kept out of it and are **gitignored, not deleted**. They are still on
disk, and `Tools/private-sync.sh` commits them to `idevtim/isleta-app`, the private archive that also
holds the pre-open-source history:

- `docs/PROBES-2.0.md`, `docs/PROBE-*.md` — the raw probe sessions. Session records rather than
  documentation, and they quote absolute paths from the machines they ran on.
- `docs/PLAN-2.0.md` — the competitive analysis. It names a competitor's features throughout, which
  is what analysis is and not what a public repo should carry.
- `docs/BRIEF.md`, `docs/NEXT-SESSION.md` — a reconstruction and a hand-off, neither authoritative.
- `.claude/` — the skills and settings.

**Do not cite an unpublished file from a published one.** A source comment or a doc that points at
`docs/PROBE-*.md` is a dead pointer for everyone but you; cite `docs/PLATFORM-CONSTRAINTS.md` or
`docs/TRAPS.md`, which is where the finding lives, or state the measurement inline.
`CONTRIBUTING.md`, `SECURITY.md` and `CODE_OF_CONDUCT.md` are the public-facing contracts and are
worth keeping true.

## Architecture

Five local SPM packages plus a thin app shell. The layering test: **anything in `IslandUI` must
build and preview with no permission granted.**

| Package | Owns |
|---|---|
| `IslandKit` | Panel, screen geometry, hit testing, the shape path, process metrics (AppKit + CoreGraphics) |
| `IslandUI` | SwiftUI views, motion tokens, debug overlay, per-screen view model, the three pages and the swipe between them, activity slot layout and content views (depends on IslandActivities) |
| `IslandActivities` | Activity protocol, `ActivityContent`, the pure `ActivityStack`, `ActivityCoordinator`, the fourteen built-in kinds (depends on IslandKit) |
| `IslandSources` | NowPlaying, calendar, weather, system events, Bluetooth device connections — all permission-gated |
| `IslandSettings` | Config model, `UserDefaults` persistence + migration, settings window, the first-run flow, launch at login, the Sparkle seam |
| `Isleta/` | App shell: wiring only — controller, one model per screen, hot keys, status item |

Entry point is `IsletaMain.swift`, not `@main` on the delegate. The load-bearing decisions —
panel-per-display, the frame that never animates, exact hit testing, the private overlay space, the
coordinate spaces — are in `docs/ARCHITECTURE.md`.

## Build and test

```sh
./Tools/check.sh                                          # packages + tests + Isleta.app
swift test --package-path Packages/IslandKit --filter IslandShapeTests
```

`Tools/check.sh` is the whole check, and it must pass before anything is called done. Tests are
**swift-testing** (`@Suite`/`@Test`/`#expect`), not XCTest, and `--filter` matches the *type* name.
The debug flags, the two entitlements files, and the build-system traps that produce errors naming
the wrong file are in `docs/BUILD-AND-TEST.md`.

## The rules that hold everywhere

Each of these has already cost a session, and each is a one-line summary of a measured entry in the
docs above. Do not undo one without reading its entry first.

**Measurement**

- **Measure the effect, never the return value.** Most of this platform answers `success` and does
  nothing: an AX action that doesn't exist, a SkyLight call on another app's window, a CoreAudio
  listener for an absent property, a Darwin notification name you invented, a preset that was never
  running. Registration status is evidence of nothing.
- **`open -a Isleta` is the only launch that can see a permission bug.** TCC judges a request
  against the *responsible* process, so anything run from a shell inherits Terminal's grants and its
  usage strings. This class of bug shipped in 1.3.0 and aborted every real launch.
- **Read the daemon's log, not your own.** It is what separates a private path we can walk from a
  door that checks an entitlement against our signature.

**The window layer**

- One `IslandPanel` per screen, keyed by `CGDirectDisplayID` — never by index into `NSScreen.screens`.
- **The panel frame never animates**, and `islandPath` tracks the **animated** shape, never the
  target shape. A nil `islandPath` silently eats every click.
- **Never assign `NSWindow.ignoresMouseEvents`** — not even `false` — and never put
  `.allowsHitTesting(false)` on a view that covers the panel. Both collapse the window's event shape
  and swallow every click across the panel.
- The panel never becomes key or main, with one flagged exception (`acceptsKeyboardInput`, the
  shelf's search field). Do not widen it to a second caller without measuring it again.

**Motion and appearance**

- **Springs, not durations.** The ten tokens live in `IslandUI/Motion.swift`. No inline
  `.animation(.easeInOut(duration:))` anywhere in this codebase, ever.
- Width, height and both corner radii animate on **one spring instance**; divergent curves are what
  make a morph look like two animations.
- **The horizontal swipe means two different things** — stowing what is on stage when the island is
  closed, turning a page when it is open — and `pageTurn` is one of the two critically damped tokens
  (`reboundReturn` is the other), because a page is a detent. `docs/MOTION-AND-INTERACTION.md` has
  the carousel.
- **Reduce motion, reduce transparency and increase contrast are correctness requirements**, not
  polish.
- On a real notch: pure `#000000` in sRGB, no material, no blur. On synthesized islands: Liquid
  Glass. **Font is SF Pro via `.system()` only** — never bundle a font.
- **Continuous animation belongs to CoreAnimation.** SwiftUI `Canvas`/`TimelineView` per-frame
  drawing measured ~18% of a core and ~279 MB regardless of how small the thing drawn is; the same
  animation in `CALayer`s is ~0.008% and 14.6 MB.

**Sources and system APIs**

- **No polling when idle.** Notification- or callback-driven; a provider that must poll polls only
  while its activity is presented. No `Timer` for animation — use `NSView.displayLink`.
- **Every permission-gated feature must be tested in the denied state**, and a `NullProvider` must
  keep the UI fully functional.
- **Private frameworks are allowed** — resolve at runtime, put them behind a protocol with a
  fallback that is a real feature, and measure before believing. `docs/WORKING-AGREEMENTS.md` lists
  the paths that ship and is where the count is kept — do not restate a number here.
- **An entitlement not authorized by an embedded provisioning profile SIGKILLs the app at `exec`**
  with no stdout, no stderr and no crash report. `codesign` accepts it silently.

**Logging**

- **Everything goes through `IslandLog`** (IslandKit) — never `print`, `NSLog` or a bare
  `os.Logger`. Categories are a fixed taxonomy of *concerns*, not components.
- **Nothing the user did not write goes in**: no track titles, file names, event titles, or serial
  numbers. The file is emailed to strangers and the unified log is world-readable.
- **Nothing on the hot or idle path logs.** `debug` is an autoclosure and free when off; `info` is
  for things that happen once per user action or system event.

**Naming and copy**

- Plain descriptive English, and coin nothing. Never a competitor's product vocabulary — in code, in
  a UI string, in a `UserDefaults` key, or in a test name.
- Localize what Isleta wrote for a person to read on screen, and nothing else: not logs, not
  diagnostics, not anything persisted or matched on, not anything macOS or another app named.

**Performance** — build-failing thresholds, not aspirations:

> idle CPU < 0.3% · animating < 4% · resident memory < 60 MB · cold launch to visible < 300 ms ·
> hover → first frame < 16 ms · Energy impact "Low" indefinitely

## Working agreements

- **Verify before you build.** Check SDK headers or docs when unsure an API exists on macOS 26, and
  state uncertainty out loud. **Never invent a symbol.**
- **Disbelieve a single instrument.** Cross-check against the system's own tools before believing a
  budget is breached, or a measurement harness will send you hunting a source that isn't there.
- Persistence is SwiftData; propose GRDB before adding anything else. The config record is a
  `UserDefaults` JSON blob with hand-written migration — see `docs/WORKING-AGREEMENTS.md` for why.
- Dependencies are allowed and are a cost worth naming in the commit that adds one: a bundled dylib
  lands on the *launch* budget before the size one (250–400 ms of first-launch signature validation).
- Small commits, conventional commit messages, one milestone per branch.
- **A withdrawn feature is a subtraction, not a deprecation.** The code, the vocabulary case, the
  settings control, the shortcut, the strings and the tests all go, so nothing is left whose status a
  later reader has to work out — and the *measurements* outlive the code, in the module README's
  "Will not own" and in `docs/PROGRESS.md`, because a fact about an API is not a fact about the feature.
  Seven have gone this way: notifications, the app switcher, the app-installed island, the disk
  island, the month grid, the player bar, downloads.
- Every module has a `README.md` saying what it owns **and what it deliberately does not**.
- **When you hit a platform constraint the spec didn't anticipate, stop and report it** with options
  and tradeoffs — don't route around it silently. Explain reasoning on architectural forks before
  writing the code.
