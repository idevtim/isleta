# Performance budget

Build-failing thresholds, not aspirations.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

Idle CPU < 0.3% · animating < 4% · resident memory < 60 MB · cold launch to visible < 300 ms ·
hover → first frame < 16 ms · Energy impact "Low" indefinitely.

- **No polling when idle.** Notification/callback-driven; a provider that must poll polls only while
  its activity is presented. Sampling in `PerformanceProbe` happens on demand, never on a timer.
- **No `Timer` for animation** — `NSView.displayLink(target:selector:)` (`CVDisplayLink` is
  deprecated).
- **Continuous animation belongs to CoreAnimation, and this is the largest measured saving in the
  app.** The Now Playing equalizer drawn with a SwiftUI `Canvas`/`TimelineView` cost **17.7–19.3% of
  a core and 279 MB**; the same six bars as `CALayer`s with a `CABasicAnimation` on
  `transform.scale.y` cost **≈0.0733% and 14.6 MB** — same bars, same refresh rate, same panel, and
  below a static control's footprint. The rule generalizes: per-frame drawing through SwiftUI costs
  the same regardless of the area drawn, so a 40×32 panel is no cheaper than a 608×400 one,
  shrinking is not a lever, and `.drawingGroup()` does nothing. **Beware ProMotion** — the cost
  tracks the display's actual refresh rate, so only paired deltas against a same-session static
  control mean anything.
- `ProcessMetrics` samples our own Mach task rather than shelling out to `top`, whose 0.1%
  resolution can't distinguish 0.3% compliance from a threefold overshoot.
- **The idle window opens after the sources start, not at the first frame — and where that baseline
  sits is the difference between measuring the app and measuring its launch.** `markBaseline()` used
  to run at the top of `recordLaunch()`, which then went on to run the pass-through self-test,
  `startSources()` and `updater.start()` in the same function: so every "idle CPU" figure included
  spawning `perl`, the first Now Playing snapshot and artwork decode, the accessibility attach,
  CoreAudio's first HAL call, and sometimes a Sparkle update check. A fixed ~135ms of startup over an
  8s window reads as 3.34% and over 60s as 0.23%, which is why the number appeared to wander with
  ambient conditions and why two separate sessions went hunting for a source that was polling. It was
  not; **idle measures 0.02-0.06% once the baseline is placed correctly**. The shape of this mistake
  is worth remembering: the metric was self-consistent, plausible, and wrong, and the thing that
  exposed it was that the *percentage* moved 14× while the milliseconds behind it did not.
- **Disbelieve a single instrument.** `top` reading 0.0% with 7 context switches per 10s, and 40s of
  `sample` at 1ms with no user-code stack in it, are not consistent with a process drawing 0.4% — and
  both were available for the whole of the investigation that preceded reading the sampler's own
  code. Cross-check the harness against the system's tools before believing a budget is breached.
- Instruments (Time Profiler + Energy) at the end of every milestone, results recorded in `PERF.md`.
