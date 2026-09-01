# Architecture

The package layering and the load-bearing decisions behind the window layer, in the order they matter.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

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

Load-bearing decisions, in the order they matter:

- **One `IslandPanel` (`NSPanel`) per screen, keyed by `CGDirectDisplayID`** — never by index into
  `NSScreen.screens`, which reorders on connect/disconnect/rearrange. `IslandController` owns them
  and rebuilds on `didChangeScreenParameters`, debounced (one clamshell open emits several).
- **The panel frame never animates.** It is created at max expanded bounds
  (`IslandLayout.maxExpandedBodySize` + corner flare margin) and left alone for the screen's
  lifetime. All expansion/collapse/morphing happens to SwiftUI content inside a transparent panel.
  Animating `NSWindow.setFrame` produces stepped, tearing motion — the single most common reason
  these apps feel cheap.
- **Consequence: hit testing must be exact.** `IslandHitTestView.hitTest` returns nil outside
  `islandPath`, so clicks reach the app underneath a 608×400pt transparent panel.
  `islandPath` tracks the **animated** shape, never the target shape. `PassThroughSelfTest` verifies
  this against the window server, probing the concave carve-outs specifically (they sit inside the
  bounding box but outside the shape — a rectangular hit region passes a far-field test and fails
  those).
- **Nothing outside `islandPath` may be painted into this panel, and the blur is why that rule now
  has a second window behind it.** The open island draws a band of blurred desktop around itself, and
  an `NSVisualEffectView` claims every point its mask covers at any tint — measured, so there is no
  faintness that buys pass-through. It therefore lives in `IslandBlurPanel`: one per screen, beneath
  `IslandPanel`, `ignoresMouseEvents = true`, hosted in the same overlay space. A click in the band
  reaches the app underneath, and the outside-click monitor spares it. See
  `docs/MOTION-AND-INTERACTION.md`.
- **The panel never becomes key or main — with exactly one scoped exception, and it is a flag rather
  than a policy.** Clicking the island must not deactivate the user's frontmost app: no title-bar
  flicker, no lost caret. `IslandPanel.acceptsKeyboardInput` lifts the refusal for the length of one
  shelf search and nothing else, because there is no way to type into a window that is not key
  — that is what key *means*. It is reachable only through
  `IslandController.setAcceptingKeyboardInput(_:forScreen:)`, which puts every other panel back
  before it offers one. **The measurement that makes this acceptable, and the reading that makes it
  look like a violation, are both in the Traps section** — the short version is that
  `NSWorkspace.frontmostApplication` never moves and the app behind keeps `AXMain = true`, while
  `NSApp.isActive` does flip and draws nothing on screen for an `LSUIElement` app. The user-visible
  half of the promise holds; the caret in the app behind stops blinking, which is true of every
  typing surface on macOS and is the cost. **Do not widen this to a second feature without measuring
  it again** — two callers sharing one exception is how an exception becomes the rule.

  **The caller changed on 2026-08-28, and the exception did not.** It was bought by the notification
  reply and reused by the shelf's search; notifications are gone and the search is now the only
  caller, so the flag is attributed to it. The measurement behind it is unchanged.
- **One definition of the shape.** `IslandShapeGeometry` (IslandKit) builds the `CGPath`; IslandUI's
  `IslandShape` wraps it and `IslandHitTestView` calls it directly. Never fork it.
- **Continuous (squircle) corners, never circular.** `ContinuousCorner` holds Bézier constants
  extracted at runtime from SwiftUI's own output; `ContinuousCornerTests` re-derives them from
  SwiftUI each run so an SDK change fails the build instead of quietly detuning the shape. A corner
  spans `1.528665 × radius` along each edge, not `radius`.
- **The bottom corners curve inward**, following the physical cutout's own, and the shape never
  paints outside `bodySize`. An earlier version flared them outward to look "carved"; on hardware
  that put two points on the bottom of the island and read as a shape pasted *over* the notch. See
  PROGRESS.md — this overrides §4.4 of the brief. `ContinuousCorner` still supports concave corners.
- **Only displays with a real notch get an island** (`IslandPlacement.displays(from:)`), overriding
  §1/§4.3. A Mac with no notched display at all falls back to a synthesized island on the primary
  display, or the app would have no UI on a mini/Studio/iMac.
- **Geometry math is AppKit-free** (`NotchResolver`, `IslandLayout`, `IslandShapeGeometry`) so the
  arithmetic where display-arrangement bugs hide is testable against captured hardware values with
  no running app. Notch width is measured as the *gap* between `auxiliaryTopLeftArea.maxX` and
  `auxiliaryTopRightArea.minX`, not by subtracting widths — that also survives arrangements where
  the auxiliary areas don't tile the full width. Notchless displays get a synthesized 210×32pt rect.
- **Coordinate spaces:** `NotchGeometry`/`IslandLayout.panelFrame` are global AppKit y-up;
  `IslandShapeGeometry`, `IslandHitTestView` (`isFlipped`), and SwiftUI are y-down. Convert at the
  boundary, and say which space a rect is in when adding one.
