# PERF

Instruments-and-measurement log against the §9 budgets. One section per milestone. **Nothing here is
deleted when it turns out to be wrong** — a superseded conclusion is labeled and kept, because the
measurements under it are still measurements and the wrong inference is usually the instructive part.

## What in this file is superseded, and by what

Read this before quoting a number out of a section.

| Section | What is superseded | Read instead |
|---|---|---|
| Milestone 0, Milestone 9.5 | **Idle CPU only.** The baseline sat at the first frame, so those figures carry the app's own startup. Cold launch, memory and pass-through are unaffected, and 9.5's *comparison between arms* still stands because all three arms carried the same error. | Milestone 9.6 |
| Milestone 9.6, "Open: with a track playing…" | The open item is **closed**, and its stated hypothesis ("the 21×14pt `Canvas` damages the whole 608×200pt transparent panel") was tested and is **false**. | "9.6 closed — and then the conclusion corrected" |
| "9.6 closed — the panel, not the bars" | **Its cause is wrong.** Panel size is not the variable; a 40×32 panel costs the same. Its own measurements — the rate table, `.drawingGroup()`, the external probe — are correct and are kept. | "9.6 closed — and then the conclusion corrected" |
| 1.4.0, "The budget is breached, and it is not this source" | The heading's claim does not survive its own section: the later measurement shows idle is **not** over budget, and the figure tracks a connected Bluetooth audio device. | 1.4.0, "The missing measurement, taken 2026-08-22" |
| 1.4.0, the 0.0341 % reading | **Not a baseline.** The screen was locked for it, so the shield owned every pixel. Recorded only so nobody quotes it as one. | the 0.0189 % run in the same section |

**The correct rule about per-frame drawing, stated once:** per-frame drawing from this process through
SwiftUI `Canvas`/`TimelineView` is enormously expensive **regardless of the size of the thing being
drawn**. Do not conclude a small animated element is safe, and do not try to make one cheaper by making
it smaller — that lever does not exist. Continuous animation belongs to CoreAnimation, where the render
server owns it and we draw nothing.

## How these numbers are produced

```
xcodebuild -project Isleta.xcodeproj -scheme Isleta -configuration Release \
    -derivedDataPath .build/xcode build
.build/xcode/Build/Products/Release/Isleta.app/Contents/MacOS/Isleta --perf-report 60
```

`--perf-report <seconds>` idles for the given window, prints the numbers, and exits.

- **Cold launch** is measured from `kp_proc.p_starttime` (the kernel's process creation time, read via
  `sysctl`) to the completion of the `CATransaction` that commits the island's first frame. Starting
  from a timestamp taken in `main` would omit dyld and framework loading, which is most of a Swift
  app's launch cost. It is not a verified scanout, so treat it as a close lower bound on what the
  user perceives.
- **Idle CPU** is sampled with Mach `TASK_BASIC_INFO` + `TASK_THREAD_TIMES_INFO`, differenced across
  the window. `top` resolves to about 0.1% and the budget is 0.3%, so `top` cannot tell compliance
  from a threefold overshoot; Mach thread times are microsecond-resolution.
- **Memory** is `phys_footprint` from `TASK_VM_INFO` — the number Activity Monitor calls "Memory".
- The sampler is not a timer in normal operation. A baseline is taken once after launch and a delta
  is computed only when the debug overlay is opened, so the idle path stays free of polling (§9).
- **The window opens two seconds after the sources start, not at the first frame.** Until 2026-08-20
  the baseline was taken at the first frame, and `recordLaunch()` then ran the pass-through
  self-test, `startSources()` and `updater.start()` — so every idle figure in this file above
  Milestone 9.6 includes spawning `perl`, the first Now Playing snapshot and artwork decode, the
  accessibility attach and CoreAudio's first HAL call. Reports now print the window they actually
  measured and the settle they excluded; a figure whose label names a different interval is what let
  this survive two sessions. See Milestone 9.6.
- **Read the CPU accumulation curve, not one percentage.** Sampling `ps -o time` every ten seconds
  through a window separates a steady draw from a burst. One percentage cannot: 130 ms arriving at
  once looks identical to 0.7 ms/s spread evenly, and the two have completely different causes.
- **The command above is the Release recipe, and most sections after Milestone 0 say Debug.** §9's
  thresholds are Release figures, so a Debug number is a floor rather than a verdict; every section
  states which configuration it used, and the ones that did not re-take Release say so under
  "Not measured".
- **Verified against the source, 2026-08-30.** `--perf-report <seconds>` is
  `PerformanceProbe.reportModeDuration()`, the baseline is `markBaseline()` called from
  `AppDelegate.openIdleWindow()` at `PerformanceProbe.settleSeconds` (2.0) after `startSources()`, and
  the report window is scheduled from there. `ProcessMetrics` reads `TASK_BASIC_INFO` +
  `TASK_THREAD_TIMES_INFO` for CPU, `TASK_VM_INFO.phys_footprint` for memory and `kp_proc.p_starttime`
  for launch. The preamble matches the code.

## Milestone 0 — window layer, geometry, shape, hit testing

**Measured 2026-08-19** · macOS 27.0 (26A5416b) · Xcode 26.6, macOS 26.5 SDK · Swift 6.3.3 ·
Apple silicon · **three displays attached**: built-in 14" notched panel (1728x1117 @2x) plus two
1920x1080 externals. Three panels live throughout.

> **The idle CPU figures below are superseded.** They were measured with the baseline at the first
> frame, so they carry the app's own startup — see Milestone 9.6. They cannot be corrected after the
> fact, because the startup cost they include varied per run. Cold launch, memory and pass-through
> are unaffected.

| Metric | Budget | Release | Debug |
|---|---|---|---|
| Cold launch to island visible | < 300 ms | **133.5 ms** | 168.3 ms |
| Idle CPU (collapsed, no media) | < 0.3 % | **0.127 %** (60 s) | 0.421 % (20 s) |
| Memory resident | < 60 MB | **21.7 MB** | 21.8 MB |
| Click pass-through probes | all correct | **36/36** | 36/36 |

Every Release budget is met with substantial headroom. Debug exceeds the idle CPU budget at 0.42%;
that is expected for `-Onone` and is not treated as a regression — budgets are Release figures.

### After adding hover, peek and haptics

Re-measured on the same machine with hover tracking live on all three panels:

| Metric | Budget | Release |
|---|---|---|
| Cold launch to island visible | < 300 ms | **129.0 ms** |
| Idle CPU (90 s, genuinely idle) | < 0.3 % | **0.143 %** |
| Memory resident | < 60 MB | **21.3 MB** |
| Click pass-through probes | all correct | **36/36** |

Idle cost of hover is effectively nil (0.127% → 0.143%), which is the expected result: an
`NSTrackingArea` costs nothing until the pointer crosses it, and `.mouseMoved` was deliberately left
out of the options so there is no event stream to service.

One measurement to be careful with: a 60s window taken while the island was actually being hovered
read **0.245%**. That is not idle CPU and should not be recorded as such, but it is a useful data
point — it says hover-and-peek costs roughly 0.1% while it is happening, and that the §9 animation
budget (< 4%) has a lot of room.

### After the shape change and notched-displays-only placement

Same machine, same three displays attached — but Isleta now presents on the notched built-in only,
so there is **one panel instead of three**.

| Metric | Budget | Release | Previous (3 panels) |
|---|---|---|---|
| Cold launch to island visible | < 300 ms | **96.2 ms** | 129.0 ms |
| Idle CPU (90 s, genuinely idle) | < 0.3 % | **0.040 %** | 0.143 % |
| Memory resident | < 60 MB | **18.2 MB** | 21.3 MB |
| Click pass-through probes | all correct | **12/12** | 36/36 (3 screens) |

Idle CPU fell by roughly 3.5x. The cost was almost entirely per-panel — three `NSHostingView`s
attached to three live panels — so the restriction to notched displays paid for itself several times
over on every metric. Worth remembering when Phase 2 adds providers: per-panel cost multiplies.

**Short measurement windows overstate idle CPU badly.** A 6-second window taken immediately after
launch reads 0.56–0.72%, because the baseline is marked at the first frame and the window then
captures AppKit and SwiftUI settling. Use 60 seconds or more; anything shorter is measuring launch,
not idle.

### Not yet measured

- **CPU during animation (< 4%)** and **hover → first frame (< 16 ms)** — nothing animates and
  nothing tracks the pointer in Milestone 0. These land with §5/§6.
- **Energy impact "Low" indefinitely** — needs a long unattended run; deferred to the first
  milestone with a live provider, which is when it can actually be wrong.
- **A full Instruments pass (Time Profiler + Energy)** has not been run. The numbers above come from
  in-process Mach sampling. Instruments should be run before the milestone is called complete if you
  want the §9 process followed to the letter; the in-process figures are far enough inside budget
  that I did not treat it as blocking.

### Notes

- Idle CPU is not zero because three `NSHostingView`s remain attached to live panels. There is no
  timer, no polling, and no run-loop source of ours firing; the residual is AppKit/SwiftUI
  bookkeeping. Worth re-checking once activities exist, since that is when a stray timer would hide.
- Memory is essentially flat between Debug and Release, so it is dominated by framework residency
  rather than anything Isleta allocates.


## 1.2.0 — the stack view, and Clock timers

Release build, MacBook Pro (Mac15,9), macOS 27.0 (26A5416b). The build under test carries the whole
of 1.2.0: the pair, the switcher row, notification recents and `TimerSource`. **The switcher row and
notification recents have both since been withdrawn** — the row became the three page dots on
2026-08-28 and notifications went the same day — so the figures below are of a build that no longer
exists. `TimerSource` and the flanked pair are still live, which is what makes the timer arm below
worth keeping.

| Metric | Budget | Result |
|---|---|---|
| Cold launch to island visible | < 300 ms | **100.3–159.8 ms** (warm), 400.5 ms first launch after a build¹ |
| Idle CPU — nothing live | < 0.3 % | **0.035–0.051 %** (60 s) |
| Idle CPU — one Clock timer counting down | < 0.3 % | **0.040 %** median of six 40 s runs |
| Memory resident | < 60 MB | **21.6–25.3 MB** |
| Pass-through probes | all correct | **12/12** |

¹ **That 400.5 ms was carried unexplained in this file for days, and it has an explanation:** it is
first-load code-signature validation, which happens once per new binary — and therefore happens to a
user after *every Sparkle update*, not only to a developer after a build. Established 2026-08-23 while
costing out a bundled dylib, which is why the working agreement now says a dependency lands on the
launch budget before the size one (250–400 ms of first-launch signature validation). The same pattern
appears as "cold page cache" in Milestones 9.5 and 9.6.

**A live timer costs nothing measurable.** Six controlled 40 s runs with the timer verified running
before *and* after each one: 0.026, 0.034, 0.039, 0.041, 0.046, 0.204 % — median 0.040 %, against a
no-timer baseline of 0.035–0.051 % in the same conditions. The Clock-gated poll shape is validated:
idle really is idle.

### The four hours of wrong numbers, and why they were wrong

This section is longer than the table because the measurements were wrong three separate ways first,
and each way is one this file's own methodology note already warns about.

**Machine load, not the app.** The first arms read 0.605 %, 0.658 % and 1.152 % — a clear budget
breach with a timer live. Then the same build with the timer source **switched off** read 0.650 % and
0.785 %. The baseline was breached too, so it was never the feature: VS Code was at 55 % and
WindowServer at 40 % of a core, and the load was *this session's own tool output* churning the
editor. `top` on the same process reported **0.0 %**, which is the cross-check this file already
prescribes — "disbelieve a single instrument" — and it was right.

**An uncontrolled variable.** A 5 s poll measured *worse* than a 1 s poll (0.658 % vs 0.605 %), which
is impossible if the poll is the cost. It was not; the arms differed in ambient load and in how many
timers happened to be live.

**The timer expiring mid-window.** Two "quiet machine" runs read 0.031 % and 0.032 % while a third
read 0.325 %. The cheap ones had no countdown on screen at all — a five-minute timer had fired
partway through the series. Nothing about the report says so, which is why the final runs assert the
timer is live on both sides of the window.

**Where the 0.3 % claim nearly went wrong in the other direction.** An intermediate arm read
0.2954 % — under budget, but with no headroom, and it was nearly written up as "the feature costs
0.24 %". It did not. The controlled median is 0.040 %.

### What was ruled out along the way

- **The shared display link is not expensive at this rate.** `ActivityClock` runs at
  `CAFrameRateRange(minimum: 1, maximum: 6, preferred: 2)` for `.seconds` and publishes only on
  second boundaries, so a countdown ticks the island's view tree once a second. CLAUDE.md's 2.8 %
  figure is the *equalizer's* frame rate, not this one; 1 Hz measures around 0.03 %.
- **`liveInterval` is 5 s rather than 1 s** — kept from the experiments even though the poll turned
  out not to be the cost. A pause or cancel made in Clock is caught by the 2 Hz frontmost poll
  instead, so the slower interval costs nothing in practice and is strictly less work.

### Not measured

- **Animating CPU** (< 4 %) — the switcher row's reveal and the recents bounce are new animations
  and neither has been measured. *(Both animations are gone: the reveal was withdrawn with the row on
  2026-08-28 and the recents bounce with notifications. The gap they leave is the page carousel, which
  is also unmeasured — see "Not yet recorded here".)*
- **Hover → first frame** (< 16 ms), which the reveal now sits on.
- **Now Playing and a timer counting at once.** They share one display link per island, so the tick
  should not double — reasoned, not measured.
- **Instruments** (Time Profiler + Energy), which §9 asks for at the end of every milestone.

## Milestone 9.5 — Sparkle

**Measured 2026-08-19** · macOS 27.0 · Xcode 26.6, macOS 26.5 SDK · Apple silicon · **one display**,
the built-in notched panel (1728x1117 @2x), one panel live. All four sources running. The machine was
under concurrent load from other builds throughout, so the absolute idle figures are higher than
Milestone 0's; the comparison between arms is the part that is meaningful, because both arms were
sampled minutes apart under the same load.

> **The idle CPU figures below are superseded** for the reason given in Milestone 9.6 — the baseline
> sat at the first frame. The "Not measured" note at the end of this section already suspected them
> ("Both arms sit above §9's 0.3 % budget. Re-measure before concluding the budget is breached"); the
> reason was the sampler, not the machine. **The comparison between arms still stands**, because all
> three arms carried the same error.

Three arms, all the **same Release binary**, differing only in `SUPublicEDKey` in the built bundle's
`Info.plist` (re-signed after each edit). Arm C used a throwaway 32-byte key generated locally for
the measurement and never written to the repository — it exists only to make `startUpdater:` succeed
so the scheduled checker actually runs.

| Arm | Cold launch | Idle CPU (20 s) | Memory |
|---|---|---|---|
| A — before Sparkle (Debug, single sample) | 125.0 ms | 0.7241 % | 18.5 MB |
| B — Sparkle linked, refuses to start (placeholder key; **what ships today**) | 119.2–123.7 ms | 0.3741–0.4469 % | 18.2–18.4 MB |
| C — Sparkle started and scheduling (throwaway key) | 114.8–141.5 ms | 0.3749–0.4481 % | 18.1–18.3 MB |

**B and C are indistinguishable.** Sparkle's scheduled update checker costs nothing measurable at
idle, which is expected: its cycle is a single long-interval dispatch timer, not a poll. Arm A is
Debug and therefore not directly comparable on CPU — it is recorded only to show that the
pre-Sparkle machine was already sampling well above 0.3 % that afternoon.

Cold launch is unchanged. `SparkleUpdater.start()` runs after the first frame, so the only launch
cost Sparkle can add is dyld mapping `Sparkle.framework`, which does not show above the noise. The
first run after a build measured 191–193 ms in both arms and settled to the figures above on
subsequent runs — that is cold page cache, not Sparkle.

Pass-through stayed **12/12** throughout.

### Not measured

- **Idle over 60 s**, the window Milestone 0 used. These are 20 s windows.
- **A quiet machine.** Both arms sit above §9's 0.3 % budget. Re-measure before concluding the
  budget is breached; the pre-Sparkle sample on the same machine that afternoon was worse than
  either arm.
- ~~**The update path itself** — download, EdDSA verification, install, relaunch. It cannot be
  exercised until a key pair and a published release exist.~~ **The precondition is gone**: the key
  pair was generated 2026-08-19 and `Tools/release.sh` ran end to end on 2026-08-25 — notarization
  Accepted, stapled, and the zip extracts to a Gatekeeper-accepted app offline. The update path itself
  is still unmeasured, and is now measurable.
- **Energy impact** over a long unattended run with the scheduler live.

## Milestone 9.6 — the idle figure was measuring launch

**Measured 2026-08-20** · macOS 27.0 · Xcode 26.6, macOS 26.5 SDK · Apple silicon · one display, the
built-in notched panel (1728x1117 @2x), one panel live. Release configuration throughout unless a row
says Debug, built into a scratch derived-data path and signed inside-out with the Developer ID
identity — a Release build signed ad hoc cannot launch at all (see CLAUDE.md on library validation),
so an unsigned Release measurement is not available to compare against.

**Every idle figure above this section is too high, and the ones that "breached" the 0.3 % budget did
not.** `PerformanceProbe.markBaseline()` ran at the top of `recordLaunch()`, and the rest of that same
function then ran the pass-through self-test, `startSources()` and `updater.start()`. So the sample
window always contained the `perl` helper being spawned, the first Now Playing snapshot and its
artwork decode, the accessibility attach, CoreAudio's first HAL call and, when its interval had
elapsed, a Sparkle update check. One-off startup work, divided by the window, printed as steady state.
`--perf-report`'s window was also scheduled from `applicationDidFinishLaunching`, before the baseline
existed, so the interval measured was never the interval requested.

The tell was that the *percentage* moved 14× while the milliseconds behind it did not:

| Window | Reported | CPU it implies |
|---|---|---|
| 8 s | 3.3371 % | 267 ms |
| 15 s | 0.8985 % | 135 ms |
| 30 s | 0.3675–0.4088 % | 110–123 ms |
| 50 s | 0.2322 % | 116 ms |
| 60 s | 0.2293–0.5887 % | 138–353 ms |

Three instruments disagreed with the harness and were right: `top` read **0.0 % with 7 context
switches per 10 s**, 40 s of `sample` at 1 ms caught **no user-code stack at all** (every thread in
`mach_msg`/`workq`), and the `perl` helper had used **0.02 s** of CPU in total.

### After moving the baseline past `startSources()` + 2 s settling

| Arm | Window | Idle CPU | Memory | Cold launch |
|---|---|---|---|---|
| Four sources | 60 s | **0.0264 %** | 25.4 MB | 337.8 ms¹ |
| Four sources | 94 s | **0.0679 %** | 21.9 MB | 151.7 ms |
| Four sources | 180 s | 0.1848–0.3599 %² | 23.0 MB | 122.8–133.2 ms |
| Four sources (Debug) | 60 s | 0.0235 % | — | — |
| `--no-sources` | 60 s | 0.0811–0.1558 %² | 20.0–20.3 MB | 107.4–138.3 ms |
| `--no-sources` (Debug) | 60 s | 0.0030 % | — | — |

¹ First run of a binary signed a minute earlier — cold page cache, the same pattern Milestone 9.5
records. Every subsequent launch measured 107–152 ms. ² See "the residual" below.

Pass-through was **12/12 in every run above**, including the demo arms below.

### The residual, and how to measure it

Percentages over a whole window still disagree run to run, and the shape of the disagreement is that
**longer windows read higher** — the opposite of a startup cost. Sampling `ps -o time` every ten
seconds through a 180 s window says why:

```
t=20s   0.16s        steady:  +0.01–0.02 s per 10 s  ≈ 0.4 ms/s  →  ~0.04 %
t=120s  0.20s
t=130s  0.33s        ← a 130 ms burst
t=180s  0.45s        ← a 70 ms burst
```

**Steady-state idle is ~0.04 %**, an order of magnitude inside the 0.3 % budget. On top of it sit
occasional bursts of 70–130 ms at irregular intervals, and whether one lands inside a given window is
the whole of the run-to-run variance. **Sparkle is not the cause**: `SULastCheckTime` was unchanged
across the run above, so no update check ran in it. What the bursts *are* is not established — they
are ambient enough that they also appear with `--no-sources`, which still runs the updater.

Note that these builds carry the real bundle id, so a measurement run reads and writes the developer's
own `com.tryisleta.isleta` defaults, Sparkle's last-check time included. That is one more reason two
identical runs can differ.

### ~~Open:~~ **Closed** — with a track playing, both CPU and memory were over budget

> **Closed 2026-08-23 by the `CALayer` equalizer rewrite**, and **the hypothesis stated at the end of
> this section is false**. Panel size is not the variable: a 40×32 panel drawing the same six bars
> measures 17.83 % against the 608×200 panel's 17.72 % and carries the same ~279 MB. The measurements
> below are correct and are kept; see "9.6 closed — and then the conclusion corrected".

`--nowplaying-demo` presents an ordinary Now Playing activity with `isPlaying: true` — the island at
rest with flanks, which is what real playing music produces.

| Build | Window | CPU (budget 4 %) | Footprint (budget 60 MB) |
|---|---|---|---|
| Release | 60 s | **7.6923 %** | **287.4 MB** |
| Release | 90 s | **7.7827 %** | **255.6 MB** |
| Release, notarized 1.0.1 (old baseline) | 60 s | **9.9033 %** | — |
| Debug | 60 s | 9.2228 % | — |

Reproduced four times across both configurations. This is **not** the baseline bug — that one
inflated readings, and correcting it left this where it was — and it contradicts the 0.42–0.49 %
recorded in `NowPlayingViews.swift`, now marked superseded there.

**It is not a leak.** `ps` RSS is flat for the whole window (68–70 MB with the demo, 64–66 MB idle),
and the footprint plateaus rather than climbing — 287.4 MB at 60 s, 255.6 MB at 90 s. `phys_footprint`
counts GPU-backed allocations that RSS does not, which is why the two disagree in opposite directions,
and it is the right number to judge because it is what Activity Monitor shows a user.

CPU and memory arriving together points at one cause. ~~First hypothesis to test: the 21x14pt
equalizer `Canvas` redrawing at ProMotion 120 Hz damages the whole 608x200pt transparent panel, so the
window server recomposites it every frame — at 2x that panel is ~1.9 MB a buffer, and a deep pool of
them would look exactly like this: heavy footprint, flat RSS, high CPU, no growth over time.~~
**Tested and false** — the panel is not the variable and the 279 MB is not a backing-store pool, it is
SwiftUI `Canvas`/`TimelineView` allocation. The hypothesis is left struck through rather than deleted
because it is plausible, it is what everybody reaches for, and it was reached by varying the frame rate
and never varying the panel.

### Not measured

- **Real music rather than the demo.** The harness must not press play on somebody's speakers, so
  this needs a person at the machine.
- **Where the frames go.** Instruments (Time Profiler + Core Animation) against the demo arm.
- **What the 70–130 ms bursts are.** They are inside budget and were not chased.
- **Energy impact**, which is what a user would actually feel from the demo arm's 7.7 %.
- **Multi-display.** Every figure here is one panel on the built-in display; Milestone 0's were three.

## 1.1.0 — the island in a private window-server space

The panels moved from the shipping `IslandPanel` configuration into a private SkyLight space at
absolute level `Int32.max` (`OverlaySpace.swift`), which is what takes them out of every space
transition's picture. Measured to confirm the move costs nothing at idle — it adds no timers, no
observers and no polling, and removes the occlusion observers and the settle timer from the hosted
path, but "should be free" is not a number.

Debug build, built-in display only, pointer off the notch, four sources running, clean machine.

| | measured | budget |
|---|---|---|
| cold launch | 197.4 ms | < 300 ms |
| idle CPU (62 s, after 2 s settling) | **0.0391 %** | < 0.3 % |
| resident memory | 25.3 MB | < 60 MB |
| pass-through | 12/12 | — |
| click self-test | PASS | — |

Both self-tests matter more than usual here: they are the proof that the window server still derives
the panel's event shape from its alpha channel inside a private space. It does.

### Not measured

- **Release / notarized.** Debug only; the Release figures in 9.6 were not re-taken.
- **Multi-display.** One panel. A panel per display is hosted in the same space.
- **The fallback path.** `UnavailableOverlaySpace` restores the occlusion observers and settle timer
  that shipped in 1.0.1, whose idle figure (0.0235 % over 60 s) is recorded in 9.6.

## 1.3.0 — the quiet island

The empty island became clickable: with nothing on stage it opens onto two compact buttons —
notifications and Settings — instead of refusing. The panel grew from 360 to 400pt tall to fit the
recents list's new header (transparency only; the island is unchanged at rest). Measured because
that panel is now bigger, and because a surface that opens on a *silent* Mac is exactly the state
the idle budget is about.

> **Both surfaces measured here are withdrawn.** The quiet menu and the recents list went with
> notifications on 2026-08-28; an empty island now opens onto the three pages. The figures stand as a
> measurement of *a taller panel with a SwiftUI surface drawn in it on a silent Mac*, which is still
> what the open island is.

Debug build, built-in display only, pointer off the notch, four sources running, screen unlocked.

| | measured | budget |
|---|---|---|
| cold launch | 136.6 ms | < 300 ms |
| idle CPU (21 s, after 2 s settling) | **0.1550 %** | < 0.3 % |
| resident memory | 18.8 MB | < 60 MB |
| pass-through | 12/12 | — |
| click self-test | PASS | — |

The quiet menu adds no timer, no observer and no provider: it is two SwiftUI buttons drawn only
while an island is open, and `ActivityClock` stays stopped because nothing in it is
time-dependent. The recents list's header is likewise inert.

### Not measured

- **Release / notarized.** Debug only.
- **Multi-display.** One panel.
- **The taller panel under a fullscreen slide.** The private space makes the panel's size irrelevant
  to space transitions, but that was verified at 360pt, not 400.

## 1.4.0 — AirPods connecting

A Bluetooth audio device connecting now puts the device's picture and its battery arc in the two
slivers for four seconds. Measured because it is a new source, and §9's rule is that a new source
justifies its idle cost before it ships.

**`BluetoothDeviceSource` costs nothing measurable, and that is a property of the design.** It has no
timer, no queue and no child process: the connect notification is push, the battery percentages are
read inside that callback, and the activity retires itself through its own expiry. The alternative —
a persistent battery readout — was rejected for exactly this reason, because the properties are not
KVO-compliant and keeping a percentage current would mean polling on the idle path. See
IslandSources' README.

Debug build, built-in display only, pointer off the notch, **six** sources running, screen unlocked,
AirPods Pro connected and selected as the output device, nothing playing.

| | measured | budget |
|---|---|---|
| cold launch | 124.6 / 130.9 / 234.6 ms | < 300 ms |
| idle CPU (47 s, after 2 s settling) | **0.4716 % / 0.5787 %** | < 0.3 % |
| resident memory | 20.7 – 22.3 MB | < 60 MB |
| pass-through | 12/12 | — |

### ~~The budget is breached~~, and it is not this source

> **This heading's first half does not survive its own section.** "The missing measurement, taken
> 2026-08-22" below shows the same build at **0.0189 %** with no Bluetooth audio device connected — a
> factor of 25 — so idle is not over budget on any machine without one. What the figure tracks is a
> connected Bluetooth audio device, cause still unknown. The heading is kept because the *second* half
> is the finding: whatever spends it, it is not `BluetoothDeviceSource`.

Measured directly rather than argued: with `sources.bluetoothDevices` switched **off** and everything
else identical, the same binary measured **0.4230 %** — inside the run-to-run spread of the runs with
it on. Turning the new source off does not recover the budget, so it is not what spent it.

**What the figure tracks is the machine's state, not the build.** An earlier run in the same session
measured 0.0341 % over 63 s, and that number is *not* a comparable baseline: the screen was locked, so
the window server's shield owned every pixel and the panel had nothing to composite against — the
same run reported the pass-through self-test as unable to run for that reason. It is recorded here
only so nobody quotes it as a regression baseline. Against 1.3.0's 0.1550 % over 21 s, which *was*
taken unlocked, the current figure is roughly 3× and unexplained.

The one variable that changed between 1.3.0's measurement and this one, other than the new source
that has been ruled out, is that **a Bluetooth audio device is now the active output device**. That
makes `SystemHUDSource`'s two CoreAudio listeners the first thing to look at — the property that
tracks the volume keys is already documented as one where the obvious choice observes nothing, and a
Bluetooth device's HAL behavior has never been measured here. **This is a hypothesis, not a
finding.** Confirming it needs a run with the AirPods disconnected and the screen unlocked, which is
the next measurement to take and has not been taken.

### The four-second island is not on the animating path

Its battery is an `ActivityValue.fraction`, which is not time-dependent, so
`ActivitySlotLayout.needsClock` answers false and no display link runs for the whole of its life —
pinned by a test in `DeviceConnectTests`. The one animation is the device's arrival turn, which runs
once on a spring and settles. It is deliberately not `repeatForever`: Milestone 9.6's open finding is
that a small continuously-redrawing flank appears to cost the whole 608×200pt transparent panel a
repaint, and the equalizer measured 9.9 % against the 4 % animating ceiling.

### The launch replay, which read as a performance bug and was a correctness one

The first run of this measured **0.8503 %**, and the cause was in the log at the same timestamp:
`IOBluetoothDevice.register(forConnectNotifications:)` **replays every already-connected device**, so
launching with AirPods in your ears announced them as though they had just connected. That put an
island and its animation inside the idle window. The number was a symptom; the bug was that the
island was saying something untrue on every launch. Fixed by bracketing the register call — the
replay is delivered synchronously inside it, measured — and covered by three tests.

### The missing measurement, taken 2026-08-22: the hypothesis holds

Same Debug binary, screen **unlocked**, six sources running, pointer off the notch — and this time
`IOBluetoothDevice.pairedDevices()` reports **zero connected devices** and the default output device
is `MacBook Pro Speakers` (`kAudioDevicePropertyTransportType` is not Bluetooth). Both were verified
in the same minute as the run rather than assumed, because "no AirPods" is exactly the kind of
condition that is true when you start and false by the time you read the number.

| | measured | budget |
|---|---|---|
| cold launch | 235.1 ms | < 300 ms |
| idle CPU (65 s, after 2 s settling) | **0.0189 %** | < 0.3 % |
| resident memory | 18.5 MB | < 60 MB |
| pass-through | 12/12 | — |

**0.0189 % against 0.4716 / 0.5787 %** with AirPods Pro connected and selected, on the same build,
both unlocked. That is a factor of 25, and it settles what the earlier section could only propose:
the idle figure tracks **a connected Bluetooth audio device**, not this build and not the Bluetooth
*source* — which was already ruled out by switching it off and measuring no change.

It is a correlation, not yet a mechanism. `SystemHUDSource`'s two CoreAudio listeners remain the
first suspect, and the way to prove it is the same trick that cleared the Bluetooth source:
reconnect the AirPods, switch the volume/mute source off, and measure. Until someone does that, the
honest statement is "a connected Bluetooth audio device costs about half a percent of a core at
idle, cause unknown", and **not** "idle is over budget", which is what the 1.3.0 notes said and what
this measurement disproves for every machine without one.

### Not measured

- **Which listener spends it.** The volume/mute source switched off with AirPods connected, which is
  the run that would name the mechanism rather than the condition.
- **The animating figure while a device arrives.** The turn is 0.3 s inside a four-second activity
  that needs real hardware to trigger, and `--perf-report`'s window cannot be aimed at it.
- **The click self-test.** Not run in this session.
- **Release / notarized.** Debug only.
- **Multi-display.** One panel.

---

## 2.0 — after the first four parity features (2026-08-23)

Debug, one panel on the notched built-in, **eight** sources running (the seven from 1.3.1 plus
Calendar), with Up Next, the shelf's persistence and scrolling, the reply composer and the glance all
in the build. *(The reply composer went with notifications on 2026-08-28, and the standing glance
activity the same day — the day and the sky survive as the home and weather pages. Up Next and the
shelf are live.)*

| | Measured | §9 budget |
|---|---|---|
| cold launch | **126.0 ms** | < 300 ms |
| idle CPU | **0.0217 %** over 31 s, after 2 s settling | < 0.3 % |
| memory | **23.5 MB** | < 60 MB |
| pass-through | **12/12** | all correct |
| overlay space | private SkyLight space | — |

Every budget met with room, in **Debug** — §9's figures are Release, so the shipping numbers are
better than these. Against 1.3.1's 102.7 ms / 0.1528 % / 22.7 MB: launch is 23 ms slower and memory
0.8 MB larger, both explained by one more source and one more settings pane; **idle is seven times
lower**, which is not an improvement from this work but the AirPods correlation the section above
describes — nothing was connected during this run.

**The glance's degraded path is what this run actually proves.** Calendar reported
`undetermined (never asked)` and `weather unavailable` with no prompt, no stall and no cost — which
is the state every user is in until they open Settings, and the state every user with WeatherKit
unprovisioned stays in. A source that is on, unpermitted, and quietly free is what §10 asks for.

### Not measured

- **Release / notarized.** Debug only, again.
- **`open -a Isleta`.** The one launch that can see a TCC bug, and the one that caught the 1.3.0
  abort. Calendar is a new TCC service in this build (`NSCalendarsFullAccessUsageDescription`), so
  this is **required before any release** — a shell run is judged against Terminal's grants. *(Done as
  part of the 2026-08-25 release. It remains required before every release, and a Debug build must go
  through `Tools/sign-debug.sh` first or its TCC grants are keyed to a cdhash that changed on the last
  build.)*
- ~~**WeatherKit under a real entitlement.** The provisioning profile does not exist yet, so
  `WeatherKitProvider` has never run; `UnavailableWeatherProvider` is what was measured.~~
  **Superseded 2026-08-23/24**: `com.apple.developer.weatherkit` landed with
  `Config/Isleta.provisionprofile`, and a signed `--build-only` Release logged `weatherkit entitled`
  and a real reading. What is still true, and is permanent, is that a **Debug** build can never carry
  it — so no `--perf-report` run in this file has ever had WeatherKit live.
- **The reply composer's AX write/send path.** No real repliable notification was available. *(Moot:
  quick reply was withdrawn with notifications on 2026-08-28.)*
- **The animating figure** with the glance or the reply surface on stage.
- **Multi-display.** One panel.

### A pre-existing log line worth fixing, not a regression — **fixed 2026-08-23**

Every launch since at least 2026-08-21 writes `pass-through: 7 ok, 5 FAILED: …/inside-quarter,
…/inside-center, …/inside-three-quarter, …/inside-top` to `isleta.log`. The *same* self-test run a
moment later from `--perf-report` reports **12/12**, so the launch-time run fires before the island
has composited its shape and the `inside-*` probes correctly find no window of ours yet. Confirmed
identical across today's builds and the 2026-08-21 log, so it is not from the 2.0 work.

It still wants fixing: the line reads as a hit-testing failure, it is written on every single launch,
and it goes into the file "Export Logs…" hands to strangers in a bug report — which is exactly where
a false alarm costs the most. Either defer the launch-time run until the first composite, or say what
it means.

**Done the same day.** `PassThroughSelfTest.hasComposited` asks the window server whether the island's
own center is ours yet, which is true exactly when the pixels exist; the launch run polls that up to
eight times at 50 ms and then reports whatever it sees, saying so if it never composited. Measured on
this machine it lands on the first look. This is the launch path rather than the idle one, so §9's
no-timer rule is not in question.

---

## Stage 2 — battery, downloads and the system activities (2026-08-23)

Debug, one panel on the notched built-in, **eleven** sources running (the eight from this morning
plus power, downloads and calls, with disks-and-apps riding the downloads switch).

> **Three of the four sources measured here are withdrawn** — downloads on 2026-08-28, the
> app-installed island on 2026-08-27 and the disk island on 2026-08-28. Power and calls are live. The
> section is kept because what it measures is *the idle cost of adding three push-driven sources*, and
> that number is the evidence behind "nothing polls" rather than a claim about downloads.

| | Measured | §9 budget |
|---|---|---|
| cold launch | **117.1 ms** | < 300 ms |
| idle CPU | **0.0279 %** over 20 s, after 2 s settling | < 0.3 % |
| memory | **23.7 MB** | < 60 MB |
| pass-through | not run — the screen was locked | — |
| overlay space | private SkyLight space | — |

The same build with `--no-sources`: **121.9 ms / 0.0089 % / 17.3 MB**. Against the eight-source
baseline above (126.0 ms / 0.0217 % / 23.5 MB), three more sources cost **0.006 pp of idle and
0.2 MB**, and launch is unchanged inside the noise.

That is what "nothing polls" looks like when it is true: the four power notify keys are silent
between events (the aggregate key, deliberately not registered, would have beaten five times in this
window), the download watch is one file descriptor and no watches at all until something is
downloading, the arrivals are two free notification observers, and the call observer is one CoreAudio
property listener on the default input.

**A run measured 0.4806 % and it was the machine, not the app.** Three other builds were compiling on
this laptop at the time; the same binary measured 0.0279 % twenty minutes later, and `--no-sources`
measured 0.0089 % in between. Recorded because §9's thresholds fail the build, and a number taken
under load is exactly the kind of evidence that sends somebody hunting for a source that is polling —
the mistake this file already records once, in the section about where the idle baseline is placed.

### Not measured

- **Any of it on a real event.** The charger was never pulled, nothing was downloaded, no disk was
  mounted and no call was made during a measured window. `--power-demo` and `--transfer-demo` were
  run and neither crashed, and both put the island through the shapes; that is a *drawing* check, not
  a source check.
- **The animating figure** with a download's progress bar advancing — the one activity in this stage
  that redraws repeatedly over a long window (a Safari download raises an `.attrib` event about every
  2.3 s for the length of the download).
- **The Downloads folder's TCC prompt in a shipped build.** Measured with a probe binary, not with
  Isleta: Isleta has never asked, because nothing on any path it takes asks.
- **Release / notarized.** Debug only, again.

---

## 9.6 closed — and then the conclusion corrected (2026-08-23)

**This is the standing conclusion for the equalizer and for per-frame drawing generally.** It replaces
"9.6 closed — the panel, not the bars", further down, whose measurements are correct and whose *cause*
is wrong.

> **The rule, stated once:** per-frame drawing from this process through SwiftUI
> `Canvas`/`TimelineView` is enormously expensive **regardless of the size of the thing being drawn**.
> A 40×32 panel costs the same as a 608×200 one. Rate limiting does not reach budget — 8 Hz still
> measures 5.28 % against §9's 4 %, and it looks stepped. `.drawingGroup()` changes nothing. The fix is
> to stop drawing from this process: six `CALayer`s animated by the render server, measured at
> **0.007–0.010 % of a core and 14.6 MB** against the `Canvas` version's 17.7–19.3 % and ~279 MB.
> Continuous animation belongs to CoreAnimation.
>
> The superseded section is kept in full rather than rewritten, because the wrong inference is
> instructive: it was reached by changing one variable (the frame rate) and never testing the one it
> blamed (the panel).

### The correction — panel size is not the variable

Eight arms, one variable each, identical six bars and identical pattern, 30 s windows after 3 s
settling, **WindowServer sampled externally** because the hypothesis was about recomposition:

| arm | panel | own CPU | WindowServer | footprint |
|---|---|---|---|---|
| `static` (control) | 608×200 transparent | **0.0087 %** | 7.96 % | 17.1 MB |
| `canvas120` — what ships | 608×200 transparent | **17.72 %** | 41.17 % | 279.6 MB |
| `canvas30` | 608×200 | 8.57 % | 17.71 % | 279.1 MB |
| `canvas8` | 608×200 | 5.28 % | 9.49 % | 279.1 MB |
| `opaque120` | 608×200 **opaque** | 14.25 % | 33.03 % | 279.4 MB |
| `small120` | **40×32** | 17.83 % | 29.03 % | 279.5 MB |
| `body120` | **290×40** | 19.27 % | 25.93 % | 279.1 MB |
| `calayer120` | 608×200 transparent | **0.0100 %** | 13.87 % | **14.6 MB** |

**A 40×32 panel costs 17.83 % against the 608×200 panel's 17.72 %, carrying the same 279.5 MB.**
Shrinking the animating surface buys nothing, and transparency is not it either — an opaque window
saved about 20 %. So "a 21×14pt view costs a quarter of a gigabyte because of the 608×400pt panel it
sits in" is **false**, and the arithmetic below about backing-store pools is struck.

**The 279 MB is not the window's backing store.** It is 278.9–279.6 MB across a 608×200 panel, a
290×40 panel *and* a 40×32 panel, and unchanged across 120/30/8 Hz. A 40×32 window does not own
279 MB of buffers. It is SwiftUI `Canvas`/`TimelineView` allocation.

**Rate limiting does not reach budget.** 17.7 / 8.6 / 5.3 % at 120 / 30 / 8 Hz — **8 Hz is still over
§9's 4 %**, and `NowPlayingViews.swift` already records that 8 Hz looked stepped. The 30 Hz throttle
shipped below is a real halving and is not a fix.

**`CALayer` is the fix, and it is not marginal.** Six `CALayer`s with a `CABasicAnimation` on
`transform.scale.y` — same bars, same 120 Hz, same full transparent panel — measured **0.007–0.010 %
of a core and 14.6 MB**, which is ~2 400× cheaper in-process than the Canvas and **1.6 MB below the
static control's footprint**. The app does zero per-frame work; the render server owns the animation.

**Why the two sessions disagree on the headline number** (6.9 % below, 17.7–19.3 % here): ProMotion.
The cost tracks the display's *actual* refresh rate, which rises whenever anything else on screen is
animating. So the shipping equalizer is ~6 % on an idle machine and **~19 % whenever the user is
doing anything** — worse than the 9.2–9.9 % on record, not better. WindowServer's own baseline moved
7.96 → 13.71 → 11.76 % between rounds for the same reason, so only paired deltas mean anything.

**Repeats, because a single arm proves nothing here.** Own CPU, % of one core:
`static` 0.0087 / 0.0118 / 0.0153 / 0.0096 · `canvas120` **17.72 / 19.28 / 19.07** ·
`calayer120` **0.0100 / 0.0071 / 0.0079**. Footprints: 16.9–17.1 MB, 278.9–279.6 MB, 14.6 MB.
WindowServer paired against the same round's static baseline: canvas **+33.2 / +13.9 / +15.2 pp**,
calayer **+5.9 / +0.6 / +3.7 pp**.

**One sample was thrown out, and the reason is the useful part.** A third-round `canvas120` printed
a WindowServer figure of 15.37 % over a 64.40 s window — but the probe's log had been deleted while
it was still running, so its `RESULT` line was never written, the runner's wait loop ran to its full
timeout instead of stopping at `=== done ===`, and roughly 35 s of that window covered **no probe at
all**. It looks exactly like a real measurement. Discarding it changed no conclusion, which is the
only reason it is a footnote rather than a finding.

### Stage 8.7 — the live waveform FFT is not shipped, and the DSP was never the problem

The arithmetic is free: **0.015 % of a core** for 1024 points at 120 Hz. The tap is not. It costs
`kTCCServiceAudioCapture`; it **fails silently and successfully when denied** — 688 callbacks, every
call returning `noErr`, peak amplitude 0.0, so a denied user gets a flat equalizer and no error
anywhere; it adds **+3.5–4.0 pp inside `coreaudiod`**, which is spend that never appears in Isleta's
own numbers; it blocks the calling thread for the life of the TCC prompt; and it was reproduced
**wedging the system's entire tap path for twelve minutes** after a client died. ScreenCaptureKit is
strictly worse — Screen Recording, and no audio-only filter exists. The synthetic equalizer stays.

### It landed, and the memory is the unambiguous half (2026-08-23)

`NowPlayingEqualiserView` is six `CALayer`s behind an `NSViewRepresentable` as of this date. Measured
with `--nowplaying-demo --perf-report 20` on the Debug build, **paired against a static control in
the same session every time**, because the ProMotion warning above makes an unpaired figure worthless:

| | own CPU | footprint |
|---|---|---|
| static control, before | 0.0733 % | 25.3 MB |
| **equalizer, `Canvas` — what shipped** | **4.7923 %** | **286.7 MB** |
| static control, after (3 rounds) | 0.0312 / 0.1155 / 0.0733 % | 22.7 / 22.8 MB |
| **equalizer, `CALayer`** (3 rounds) | **0.1121 / 0.1994 / 0.2907 %** | **22.6 / 22.6 / 20.1 MB** |

**Paired delta: +4.72 pp and +261 MB before, +0.04–0.22 pp and −0.1 MB after.** A playing track used
to cost §9's entire 60 MB budget four and a half times over; it now costs the same as an island with
nothing on it, and the whole activity sits inside the 0.3 % *idle* ceiling rather than breaching the
4 % animating one.

The CPU numbers here are lower than the 17.72 % in the table above for the reason that table records:
the cost tracks the display's actual refresh rate, and this machine's display was idle. That is
exactly why only the paired delta is quoted. **The footprint is not rate-dependent** — it was
278.9–279.6 MB at 120, 30 and 8 Hz — so the 286.7 → 22.6 MB is the figure that carries no caveat.

**A fourth round was discarded, both halves of it.** The static control printed **12.8383 % / 52.8 MB**
and the equalizer beside it 6.5307 % / 46.0 MB — a *static* control cannot cost 12 %, so something
else on the machine was in both windows. Thrown out as a pair rather than as the inconvenient half,
which is the only discipline that keeps this honest; discarding it changed no conclusion.

### The three things the measured arm did not model, and what each needed

The `calayer120` arm was six bars and a repeat. The shipping version has to be an equalizer:

- **The paused row of dots.** The measured arm animated `transform.scale.y`, and that is wrong for
  these bars: scaling a capsule to a sixth of its height squashes its round caps with it, so the dot
  would be a flat sliver. `bounds.size.height` leaves `cornerRadius` alone, so a bar is a proper
  capsule at every height and a circle at rest. Both are animated wholly inside the render server —
  `bounds` is on `CALayer`'s animatable list and the rounded rectangle is generated by the
  compositor, not by a `CGContext` — and the substitution cost nothing measurable. The floor is the
  bar's **own width**, not `minimumHeight × trackHeight`, or a bar wider than that fraction still
  collapses below its own cap radius.
- **Reduce Motion.** No animation is added at all; the layers take up `frames[0]` and hold. §6.3
  substitutes a crossfade for travel, and a held silhouette has nothing to fade between — so the
  honest reading is that the bars simply arrive at their resting shape. A *flat* row would be wrong
  in the other direction: all-equal reads as a loading placeholder, a designed silhouette below full
  height reads as a meter at rest.
- **Pixel snapping.** Six 2.25pt bars in a 21pt row land on half-pixels at 1× and quarter-pixels at
  2×, and a layer straddling a boundary is drawn soft on both edges. `Canvas` hid this behind
  antialiasing over a shape that was moving anyway; a layer holds still horizontally, so the softness
  is legible. Each bar's **two edges** are snapped and the width falls out of them — snapping the
  width and then laying the bars out is the version that looks right and walks the last bar off the
  grid. `EqualiserBarGeometry` is pure and asserted at 1×, 2× and 3×.

Two more that were not on the list and had to be handled anyway. **Implicit animations are an inline
duration by the back door**: a `CALayer` property assigned outside an explicit transaction animates
over CoreAnimation's own 0.25 s default, which §6.1 forbids whichever framework writes it — so the
bars carry `actions = [... : NSNull()]`. And **the pause and resume compose rather than fight**: the
collapse to dots removes the pattern and eases down over `Motion.contentSwapDuration`, while the
resume adds an **additive** animation alongside the still-running pattern, contributing a delta that
eases to zero, so the bars rise out of the line without the pattern being restarted or re-phased.
Phase itself is anchored to the wall clock through `CAAnimation.timeOffset`, which is what
`heights(at:)` did and is why the indicator still has no state of its own to drift.

`heights(at:playing:reduceMotion:)` survives unchanged as the **specification**, and a test asserts
the keyframes handed to CoreAnimation equal it at every frame boundary — otherwise a wrong keyframe
table would be invisible to a suite in which nothing draws.

### The rule, restated correctly

The rule is **not** "the panel is big, so drawing in it is expensive". It is: **per-frame drawing
from this process through SwiftUI `Canvas`/`TimelineView` is enormously expensive regardless of the
size of the thing being drawn.** Do not conclude a small animated element is safe, and do not try to
make one cheaper by making it smaller — that lever does not exist. Continuous animation belongs to
CoreAnimation, where the render server owns it and we draw nothing.

What must still be re-checked when the `CALayer` version lands, because the measured arm modeled
none of them: the reduce-motion crossfade, the paused "row of dots" state (`minimumHeight`, bars
collapsing to a line rather than to nothing), and pixel snapping at 1× and 2×.

Unmeasured: the recents bounce, the switcher reveal, the device arrival turn. They are ordinary
SwiftUI animations rather than per-frame `Canvas` redraws, so they are probably a different shape —
but that is reasoning, not a number.

---

## SUPERSEDED — 9.6 closed — "the panel, not the bars" (2026-08-23)

> **The cause stated in this section is wrong, and it is corrected in "9.6 closed — and then the
> conclusion corrected" above.** Panel size is not the variable: a 40×32 panel drawing the same six
> bars measures 17.83 % and carries the same ~279 MB. **Every measurement in this section is correct
> and is retained** — the rate table, the `.drawingGroup()` pair, and the external probe — and two of
> them are recorded nowhere else in this file. What shipped from here (a 30 Hz throttle) was itself
> superseded the same day by the `CALayer` rewrite.

Milestone 9.6 left an open hypothesis: *"a 21×14pt Canvas redrawing at 120Hz damages the whole
608×200pt transparent panel and the window server recomposites it every frame, which would make this
about the panel rather than about the bars."* It is confirmed, and the answer is worse than a frame
rate.

Measured with `--nowplaying-demo --perf-report 20`, Debug, changing **only**
`TimelineView(.animation(minimumInterval:))` on `NowPlayingEqualiserView`:

| Equaliser rate | idle CPU | memory |
|---|---|---|
| 120 Hz — `.animation`, what shipped | **6.909 %** | **286.8 MB** |
| 30 Hz | 3.389 % | 286.9 MB |
| 1 Hz | 0.345 % | 256.6 MB |
| 0.1 Hz — near-static | **0.309 %** | **25.4 MB** |

Two things fall out, and the second is the important one.

**CPU is proportional to the rate.** Halving from 120 Hz to 30 Hz halves it. Nothing surprising.

**Memory is not proportional to anything.** It is ~256 MB the moment this Canvas redraws repeatedly
*at all*, 287 MB once it has been going a moment, and **steady rather than accumulating** — an 8 s
window reads 287.2 MB and a 40 s window 286.8 MB, so it is a pool that fills to a cap and holds, not
a leak. ~~A 21×14pt view is costing a quarter of a gigabyte because of the 608×400pt transparent panel
it sits in.~~ **Corrected above:** the 279–287 MB is SwiftUI `Canvas`/`TimelineView` allocation, not
the window's backing store — it is unchanged across a 608×200 panel, a 290×40 panel and a 40×32 panel,
and a 40×32 window does not own 279 MB of buffers.

**`.drawingGroup()` changes neither figure** (3.529 % / 287.0 MB against 3.389 % / 286.9 MB — noise).
The damage is not confinable by a modifier, which is the result that decides the fix.

An independent measurement from outside Isleta agrees: a bare 608×200 transparent panel hosting the
same Canvas measures **6.31 % / 279.6 MB** with `TimelineView(.animation)` and **0.0134 % / 17.2 MB**
drawn once. Nothing about Isleta's content is involved.

### What shipped from here, and what replaced it the same day

**30 Hz**, as an honest half-measure. It halves the CPU for a smoothstep the eye cannot separate from
120 Hz — ten samples across each 0.34 s transition, against the ~2.7 that made the 8 Hz experiment
look stepped — and it does **nothing** for the memory. *(Superseded: the throttle went with the
`Canvas` when the `CALayer` version landed later the same day.)*

**The real fix is to stop redrawing from this process at all**: six `CALayer`s with a repeating
`CABasicAnimation`, animated by the render server, Isleta drawing zero frames. *(Done, 2026-08-23 —
see "It landed, and the memory is the unambiguous half" above.)* Until it landed, **a playing track
cost §9's 60 MB memory budget four times over**, and that was a measured, understood number rather
than an open question.

### The general rule this establishes — **cause corrected above**

**Anything that redraws continuously through SwiftUI `Canvas`/`TimelineView` is expensive out of all
proportion to its size.** ~~because the panel is 608×400pt, transparent, and recomposited whole~~ —
that inference was wrong; a 40×32 panel costs the same. See "9.6 closed — and then the conclusion
corrected", which is where the standing version of this rule lives. Before adding any per-frame
drawing to the island — a waveform, a spinner, a progress ring, a live preview — measure it the way
this table was measured, by changing one interval and nothing else, **and vary the thing you are about
to blame**. `ActivityClock` already avoids the trap for the timer's countdown by gating on the
*second*; new work should follow it or follow CoreAnimation, and should not assume a small view is a
cheap one.

---

## 2.0.1 — the page carousel drops frames, and it is not the drawing

**Measured 2026-08-31** · macOS 27.0 · 120 Hz built-in panel · **Debug**, so these are floors rather
than verdicts (§9's thresholds are Release figures) — but every number here is a **paired delta**
between two arms of one binary, interleaved, which is the only form a comparison takes in this file.

Reported from use as frame-rate drops "when collapsing the island, moving workspaces, swiping between
the panels".

### The instrument was answering about an island with nothing in it

`--hitch-test` drove open and close, an alert, and the drop history. It did not drive the page
carousel, the stow, or the space re-entry, and it drove all of them on an **empty** island. So it
said the island was clean, and it was clean — of the three surfaces the user named, the one that
stutters is the one the harness did not have.

Added: `swipe (page turn)` (real samples through `SwipeController`, not a call to `commitPageDrag` —
the recognizer and the neighbour pages being built at `beginPageDrag` are part of what is measured),
`hide (space leaving)` / `re-enter (space arriving)` (the two calls the space handlers make; a real
space switch cannot be driven from inside the process), and a staged full day before the swipe steps
so `--glance-demo`'s own timed activities cannot land inside a measurement window.

**What the content is worth, at 4 swipes, `--hitch-test 4`:**

| On the carousel | dropped | stalls |
|---|---|---|
| nothing | **0** | 0 |
| `--rain` alone | 1 | 1 |
| `--nowplaying-demo` | 8 | 7 |
| `--glance-demo` | 10 | 8 |
| all three | 12 | 9 |

An empty island's page turn is perfect and a loaded one is not, which is the whole finding: **the
cost is not the carousel, it is that everything on all three pages is re-laid-out while it runs.**

### Why, and it is one line of Observation

A page turn is the only animation in this app a finger is on for its whole length, and the island's
bottom edge follows that finger — `IslandScreenModel.draggedTowardIncomingPage` re-lerps
`contentMetrics` on every tracked sample, ~120 a second. Every page read `model.contentMetrics`, so
under Observation every live page — three of them during a drag — re-evaluated its whole body on
every sample. For a **width that cannot change**: the three pages are all
`IslandLayout.expandedBodySize.width` and only their heights differ, so the lerp's width term
interpolates a value to itself.

`IslandScreenModel.contentBodyWidth` answers the width without the drag; `IslandLayout.bodyOrigin`
gained a spelling that takes one. The home, music and weather pages and `ActivityLayerView` read it.
The rain field was the one layer inside a page that is genuinely a function of the island's *height*,
and it now takes its ground from the caller — the weather page answers with its own settled height,
which is `IslandPageHeight`'s argument in the other axis, and is also the *correct* height while that
page is a neighbour (`contentMetrics` there is the shape of the page being **left**).

### The paired numbers

`--hitch-test 8`, `--glance-demo --rain`, under `caffeinate -d`, arms interleaved with
`--hitch-legacy-width` as the control, **strictly serial** — see the second trap below.

| pair | legacy | new |
|---|---|---|
| 1 | 29 dropped / 21 stalls | **0 / 0** |
| 2 | 33 / 22 | **27 / 17** |
| 3 | 44 / 28 | **35 / 22** |
| 4 | 48 / 31 | **30 / 22** |
| mean | 38.5 / 25.5 | **23.0 / 15.25** |

**All four pairs favour the new arm**, by about 40% on both the frames dropped and the number of
separate stalls they arrived in. Read the *pairs* and not the columns: legacy climbs 29 → 33 → 44 →
48 across the session and the new arm climbs with it, so something on the machine is accumulating
over a fifteen-minute run and only the within-pair difference means anything. Pair 1's zero is a real
run and not a sleeping display — 1007 frames were delivered — but it is the least representative of
the four.

On a nearly-empty carousel the two arms are indistinguishable, which is consistent rather than
contradictory: with nothing on the pages there is nothing for a redundant body evaluation to rebuild.
That is also why the arm has to be measured with `--glance-demo --rain` rather than on a bare island.

**Not established: a Release figure.** `--hitch-test` is `#if DEBUG` and there is no Release arm of
it, so these are floors. `-Onone` makes each body evaluation dearer, which if anything makes the
difference easier to see here than it will be in a shipped build.

### Two things measured and found not to be the cause

- **The compositor.** WindowServer CPU across a whole `--hitch-test` run against an idle window of
  the same length, interleaved twice: 45.9% / 52.9% of a core animating against 48.9% / 50.6% idle.
  Isleta's animations are not detectable against that floor. The floor itself is the machine, not
  Isleta — §9's own idle figures for this process are ~0.02–0.04%.
- **The island's own morph.** `close (stage)`, `close (island)`, `hide`/`re-enter` all drop **zero**
  frames across every run of every arm, loaded or empty. The two surfaces the user named alongside
  the swipe are, on this instrument, already clean — and a space switch with an island open is a
  `collapseAll()` (`AppDelegate.spaceChanged`), which is that same clean close.

### Two methodological traps, and both produced numbers that were believed

**A display link stops firing when the display sleeps, and a run that measured nothing prints as a
perfect score.** Every row zero frames, zero dropped, zero stalls — indistinguishable from a fix at a
glance, and six runs were read that way. The only place it says otherwise is the verdict
(`INCONCLUSIVE — the display link never fired`) and the header (`display running at 0 Hz`). Run
`--hitch-test` under `caffeinate -d`, and read the verdict before the rows. **The frame count is the
check that costs nothing**: a valid 8-cycle swipe window delivers ~960–1010 frames, and a zero-drop
row with a plausible frame count beside it is the only zero worth believing.

**Two `--hitch-test` runs must never overlap, and it is not merely untidy.** Each stands up its own
island on the same display, so the two animate against each other and both arms are measured under a
load that is not in either of them. Several pairs taken that way came out as washes (32 against 32)
where the same comparison run serially is 40% — so the contaminated runs did not add scatter around
the right answer, they moved the answer. Caught by the owner, who noticed two were in flight at once.
The numbers above are a single serial loop; nothing else was built or tested while it ran.

---

## Not yet recorded here

**Nothing in this list is a measurement this file has taken.** Each is a figure that exists in
`PROGRESS.md` or is cited by another section here without ever having its own entry. They are named so
the gap is visible, and so nobody quotes one as though this log had verified it. Taking them properly —
Release, paired against a same-session control, on a quiet machine — is owed.

**Cited in this file but never recorded in it**

- **1.3.1 has no section.** The 2.0 section compares against "1.3.1's 102.7 ms / 0.1528 % / 22.7 MB"
  and `PROGRESS.md` separately records a 1.3.1 `--perf-report` at "114.9 ms launch, 0.045 % idle,
  12/12 pass-through". Two different runs, neither written up here, and they disagree on idle by 3×.

**Post-2026-08-23 work with figures in `PROGRESS.md` only**

- **The blur band (2026-08-26).** Idle 0.0308 / 0.1272 / 0.0302 % over three 20 s Debug windows, and
  interleaved against a pre-change baseline at 20 s each — base 0.0199 / 0.0233, new 0.0180 / 0.0194.
  Memory 23.3–24.5 MB, cold launch 165.5 ms, `PassThroughSelfTest` 12/12. Also a `--hitch-test 2` run
  on a 120 Hz panel, Debug, interleaved: base 1 / 1 / 2 dropped frames, new 2 / 1 / 8 / 0 / 3 / 2,
  median 1 against 2, worst gap 16.7–19.6 ms in every run but one — the **8, at a 48.7 ms worst gap**,
  did not reappear in the four runs after it and landed in the tallest island the app had.
- **The four island styles (2026-08-23),** `--nowplaying-demo --perf-report 20`, Debug, changing only
  `--style-demo`: automatic 0.0079–0.0095 % / 18.6–18.8 MB, normal 0.0095 % / 18.6 MB, semi-liquid
  glass 0.0083–0.0285 % / 19.5–20.3 MB, liquid glass 0.0079–0.0091 % / 19.6–19.7 MB. With the
  interleaved A/B that killed four earlier readings: normal/glass 0.0239/0.0079, 0.0155/0.0134,
  0.0138/0.0127, 0.0113/0.0153.
- **`CoreAudioOutputRouting`'s two property listeners, isolated in their own binary (2026-08-23):**
  0.0340 % and 0.0424 % of a core with the listeners live against 0.0558 % with them absent, over 20 s
  windows.
- **The logger (2026-08-21),** Debug, `--perf-report 12`: 22 lines for a 15-second run, idle 0.10 %,
  memory 25.5 MB.
- **Wide flanks, the limit rebound, the page carousel, the lock-screen card and HUD suppression have no
  §9 figures at all.** The rebound and the widen were measured *geometrically*, frame by frame from a
  620×64pt capture over the notch, and those numbers are in `PROGRESS.md`; nothing measured what the
  new event tap, the `SIGSTOP` check on every volume keypress, or a `CAKeyframeAnimation` marquee per
  open island cost at idle or while animating.

**Two figures that are quoted elsewhere and must not be taken from here**

- **"The equalizer costs ≈0.0733 % of a core."** `PROGRESS.md` (2026-08-28, the lock-screen card)
  attributes 0.0733 % to the `CALayer` bars. **In this file 0.0733 % is a *static control* reading** —
  the "static control, before" row of the paired table in "It landed, and the memory is the unambiguous
  half", and again one of the three "static control, after" values. The equalizer's own measured own-CPU
  in that table is **0.1121 / 0.1994 / 0.2907 %**, and the honest statement is the **paired delta**:
  **+4.72 pp and +261 MB before, +0.04–0.22 pp and −0.1 MB after**. The unambiguous half is the
  footprint, which is not rate-dependent: **286.7 MB → 22.6 MB**. The `Canvas` version's CPU is
  4.7923 % in that paired session and 17.72–19.28 % in the eight-arm table, and the difference is
  ProMotion — the cost tracks the display's *actual* refresh rate, so only paired deltas mean anything.
  **This file has no measurement of the `CALayer` equalizer at 0.0733 %.** Whichever number is right,
  one of the two documents needs correcting by a person who was in the room.
- **"Latest recorded idle ≈ 0.0341 %."** That figure is in this file, in 1.4.0, and the section that
  records it says in as many words that **it is not a comparable baseline: the screen was locked**, so
  the window server's shield owned every pixel and the same run reported the pass-through self-test as
  unable to run. The last idle figure taken unlocked, with a verified-quiet Bluetooth state, is
  **0.0189 % over 65 s** (1.4.0, 2026-08-22, Debug); the last taken at all is **0.0279 % over 20 s**
  (Stage 2, 2026-08-23, Debug). Do not quote 0.0341 % as the current idle.
