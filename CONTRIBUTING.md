# Contributing to Isleta

Thanks for wanting to help. Isleta is a menu-bar app that turns the MacBook notch into a live
surface, and the whole bar it is held to is this: **a Mac user cannot tell it isn't an Apple
feature.** Every curve, radius, weight and millisecond is judged against that.

## Setup

```sh
git clone https://github.com/idevtim/isleta.git
cd isleta
./Tools/check.sh
```

**Requirements:** macOS 26 or later, Apple silicon, Xcode 26+. There is no XcodeGen step and no
package manager to install — the five local SwiftPM packages and the two vendored dependencies are
all in the tree.

`Tools/check.sh` builds and tests every package, runs the localization audit, builds `Isleta.app`,
then audits the built app. **It must pass before anything is called done.**

## Building without a Developer ID

You do not need an Apple developer account to work on Isleta.

- **Debug builds are ad-hoc signed and work with no certificate at all.** This is the normal
  development path.
- **Debug builds have no weather.** WeatherKit is a `com.apple.developer.*` entitlement, an ad-hoc
  signature cannot carry one, and that is why there are two entitlements files. A Debug build logs
  `weatherkit entitlement absent` and draws the calendar half alone. That is expected, not a bug.
- **An ad-hoc signature's hash changes on every build, so TCC drops your grants each rebuild.** If
  you are working on anything permission-dependent — Accessibility, the media keys, calendar,
  Bluetooth — that makes it untestable. `Tools/sign-debug.sh` signs the Debug bundle with a stable
  identity so one grant holds across rebuilds; set `APPLE_TEAM_ID` and `CODE_SIGN_IDENTITY` to
  your own.
- **`Tools/release.sh` is not for contributors.** It signs, notarizes and publishes with the
  maintainer's Developer ID.

## Read before you touch

Isleta's docs are not decoration. Almost every entry in them was measured on real hardware, most of
it after a session was lost to the thing it warns about. **`CLAUDE.md` is the map** — it says which
file to read for the area you're about to change. The short version:

| Before you… | Read |
|---|---|
| build, test, or debug a build failure that looks impossible | `docs/BUILD-AND-TEST.md` |
| touch the panel, screen geometry, hit testing, or space transitions | `docs/ARCHITECTURE.md`, `docs/TRAPS.md` |
| add or debug a data source, or reach for **any** system API | `docs/PLATFORM-CONSTRAINTS.md` |
| write SwiftUI or AppKit anywhere in this codebase | `docs/TRAPS.md` |
| animate anything, or change hover, click, swipe or haptics | `docs/MOTION-AND-INTERACTION.md` |
| add a string a person will read on screen | `docs/LOCALIZATION.md` |
| name a feature, a setting, a `UserDefaults` key or a test | `docs/NAMING.md` |
| claim something is fast enough | `docs/PERFORMANCE.md` |
| add a dependency, use a private API, or add a persistence layer | `docs/WORKING-AGREEMENTS.md` |

`docs/PROGRESS.md` is the status file — milestones, decisions that override the brief, and open
questions. `docs/PERF.md` holds the measurements.

## Making changes

1. Fork and branch from `main`
2. Make the change, and read the doc for the area first
3. `./Tools/check.sh` — it must pass
4. Test on real hardware. A notched MacBook if you have one; note in the PR if you don't
5. Update the doc in the same commit as the work, if the change alters something a doc records
6. Open a PR

Small commits, conventional commit messages, one milestone per branch.

## The rules that hold everywhere

Each has already cost somebody a session. Don't undo one without reading its entry first.

- **Measure the effect, never the return value.** Most of this platform answers `success` and does
  nothing — an AX action that doesn't exist, a SkyLight call on another app's window, a Darwin
  notification name you invented. Registration status is evidence of nothing.
- **`open -a Isleta` is the only launch that can see a permission bug.** TCC judges a request
  against the *responsible* process, so anything run from a shell inherits Terminal's grants.
- **Springs, not durations.** The ten motion tokens live in `IslandUI/Motion.swift`. No inline
  `.animation(.easeInOut(duration:))` anywhere in this codebase, ever.
- **The panel frame never animates**, and `islandPath` tracks the *animated* shape. A nil
  `islandPath` silently eats every click.
- **Never assign `NSWindow.ignoresMouseEvents`** — not even `false` — and never put
  `.allowsHitTesting(false)` on a view covering the panel. Both swallow every click.
- **One `IslandPanel` per screen, keyed by `CGDirectDisplayID`** — never by index into
  `NSScreen.screens`, which reorders when a display sleeps.
- **Reduce motion, reduce transparency and increase contrast are correctness requirements**, not
  polish.
- **Continuous animation belongs to CoreAnimation.** SwiftUI `Canvas`/`TimelineView` per-frame
  drawing measured ~18% of a core and ~279 MB; the same animation in `CALayer`s is ~0.008% and
  14.6 MB.
- **No polling when idle.** Notification- or callback-driven. No `Timer` for animation — use
  `NSView.displayLink`.
- **Every permission-gated feature must work in the denied state**, with a `NullProvider` keeping
  the UI functional.
- **Everything logs through `IslandLog`** — never `print`, `NSLog` or a bare `os.Logger`. **Nothing
  the user did not write goes in**: no track titles, file names, event titles or serial numbers.
  The log file is emailed to strangers.
- **Plain descriptive English, and coin nothing.** Never a competitor's product vocabulary — not in
  code, not in a UI string, not in a `UserDefaults` key, not in a test name.
- **Verify before you build.** Check the SDK headers when unsure an API exists on macOS 26, and say
  so out loud when you're unsure. **Never invent a symbol.**

## Performance budget

These are build-failing thresholds, not aspirations:

> idle CPU < 0.3% · animating < 4% · resident memory < 60 MB · cold launch to visible < 300 ms ·
> hover → first frame < 16 ms · Energy impact "Low" indefinitely

`Isleta.app --perf-report 60` measures against them. Record results in `docs/PERF.md`.

## Tests

**swift-testing** (`@Suite` / `@Test` / `#expect`), not XCTest. `--filter` matches the *type* name,
not the `@Suite` display name, and a filter matching nothing exits 1.

```sh
swift test --package-path Packages/IslandKit --filter IslandShapeTests
```

## Architecture

Five local SPM packages plus a thin app shell. The layering test: **anything in `IslandUI` must
build and preview with no permission granted.**

| Package | Owns |
|---|---|
| `IslandKit` | Panel, screen geometry, hit testing, the shape path, process metrics |
| `IslandUI` | SwiftUI views, motion tokens, the three pages, activity slot layout |
| `IslandActivities` | Activity protocol, the pure `ActivityStack`, coordinator, the built-in kinds |
| `IslandSources` | NowPlaying, calendar, weather, system events, Bluetooth — all permission-gated |
| `IslandSettings` | Config model, persistence + migration, settings window, the Sparkle seam |
| `Isleta/` | App shell: wiring only |

Every module has a `README.md` saying what it owns **and what it deliberately does not**.

## Two surfaces, and keeping them apart is the design

**Pages** are what a person browses — `home → music → weather`, wrapping, turned by a two-finger
swipe. They are a fixed enum, so they are always all there.

**Activities** are what arrives — a volume key, a timer finishing, a call, a device connecting.
They take the stage because something happened, and they leave on their own.

**A feature that announces something the user is already looking at belongs to neither**, and seven
have been withdrawn on exactly that ground: notifications, the app switcher, the app-installed
island, the disk island, the month grid, the player bar, downloads. A PR that adds one will get
this reply, so it's worth knowing up front.

A withdrawn feature is a **subtraction, not a deprecation** — the code, the vocabulary case, the
settings control, the shortcut, the strings and the tests all go.

## When you hit a platform constraint

**Stop and report it** with options and tradeoffs — don't route around it silently. Open an issue
or say so in the PR. Explaining the reasoning on an architectural fork before writing the code
saves everyone the review.

## Questions?

Open an [issue](https://github.com/idevtim/isleta/issues) or a
[discussion](https://github.com/idevtim/isleta/discussions) — happy to help.
