# IslandKit

Geometry and windowing. Everything that has to be true before a single pixel is drawn.

## Owns

- **Screen geometry** (`NotchGeometry`, `NotchResolver`, `IslandScreen`, `IslandPlacement`) —
  turning `NSScreen` into a notch rect, and deciding which displays get an island at all (only
  notched ones; see PROGRESS.md). The resolver is pure
  arithmetic with no AppKit dependency, so display-arrangement maths is unit-testable against
  captured real-hardware values.
- **The island outline** (`ContinuousCorner`, `IslandShapeGeometry`, `IslandShapeMetrics`) — the
  `CGPath`. Every corner is a continuous (squircle) curve; the bottom pair curve inward, following
  the physical cutout's own corners, and the shape never paints outside its body.
- **The thirteen shapes and the key to them** (`IslandPresentation`, `IslandFlanks`, `IslandForm`,
  `IslandLayout`) — rest, peek and expanded, with rest and peek each having a *flanked* variant 80pt
  wider so an activity has lit pixels to be drawn in beside the cutout, a *wide flanked* one 216pt
  wider for an activity that spells what it is in a noun, and a *wider flanked* one 274pt wider for
  one that needs a phrase (power); the open island has one wearing the switcher row; and each
  flanked peek has one wearing the **track lip**, 43pt taller, for the pointer resting on an album
  cover. `IslandForm` is the `(presentation, flanks, switcher, lip)` tuple, resolved from inputs and
  never stored, exactly as `IslandPresentation` is resolved from hovering and expansion. The flank
  axis is a four-case span rather than a flag, so "wide but not flanked" is not sayable; the other
  two are forced false in every state that cannot draw them. A form can never describe a shape the
  island has no way to be in.
- **The spelling forms are the one family member the open island does not contain.** They exceed it
  in width (401 and 459 against 368 on a 185pt notch) and in width only, so `AppDelegate.transition`
  names `.widerFlankedPeekWithLip` in its widen alongside `.expanded` and `.flankedPeekWithLip` —
  one form for both spans, since the widest contains the wide one. `ShelfDragTests` and
  `TrackLipTests` are what fail if one of the three is dropped.
- **The user's own size** (`IslandSizing`) — the peek amount, the two collapsed-body adjustments and
  the compact island, as **one record**. One rather than four parameters because this arithmetic is evaluated
  twice, once for the drawing and once for `IslandHitTestView.islandPath`, and a dimension that
  reaches one and not the other is clicks landing on lit island pixels and being dropped. The
  adjustments reach the **collapsed** island only, and the compact island is a *height* on the open one — the
  open island's width is a constant two IslandUI layouts compute against, so *narrowing* it draws
  their rows outside the mask. `IslandSizingTests` proves `IslandShapeMetrics.union` is still a
  superset at every sizing, which is what the widen-then-tighten protocol depends on.
- **How wide and how tall the open island is** (`IslandLayout.expandedHeight`,
  `IslandLayout.expandedWidth`) — a surface says what it needs, before the transition, and the same
  two numbers reach the drawn shape here and the clickable one through
  `IslandController.expandedContentHeight` / `expandedContentWidth`. The width can only ever *grow*
  the island past `expandedBodySize.width`, which is what keeps it out of the two layouts above;
  `GlanceMonthLayout.bodyWidth` is the only caller that asks. Both are clamped into
  `maxExpandedBodySize`, the size the panel was built at and never resized (§4.2).
- **What the island is made of** (`IslandStyle`, `IslandMaterial`) — the *rule*, not the drawing.
  Four styles resolve, against a display's notch kind and the user's Reduce Transparency setting, to
  one of three materials; `IslandMaterialView` in IslandUI paints them. `.automatic` is §6.4's
  original pair of rules — black in a cutout, Liquid Glass where the island floats — so it is here
  rather than deleted, and it is the default. Both glass styles resolve to the opaque one under
  Reduce Transparency, which §6.3 makes a correctness requirement.
- **The animation-speed arithmetic** (`MotionSpeed`) — here rather than beside the tokens it scales,
  for two reasons. SwiftUI's `Animation` is opaque, so a test in IslandUI could only compare two of
  them for inequality; and IslandSettings needs the range for its slider and does not depend on
  IslandUI, so a copy there would be two spellings of one vocabulary.
- **The widened hit region** (`IslandShapeMetrics.union`, `IslandController.widenHitRegionForTransition`)
  — the shape a transition accepts clicks in, which must be a superset of every state it passes
  through. A subset is the dangerous direction: those clicks reach us and get dropped.
- **The window layer** (`IslandPanel`, `IslandHitTestView`, `IslandController`) — one borderless
  non-activating panel per screen, its fixed frame, and precise per-pixel hit testing.
- **The overlay space** (`OverlaySpace`) — a private window-server space at the highest absolute
  level that every panel is hosted in, so a space transition has nothing of ours to photograph. This
  is the second and only other private-API path in the app, held to the same rule as the first:
  resolved with `dlsym`, behind `OverlaySpaceHost`, with `UnavailableOverlaySpace` as the fallback
  and the occlusion-driven hide in `IslandController` as what the fallback does. `TransitionSettle`
  is that hide's timing rule and runs *only* on the fallback.
- **Drag and drop** (`IslandDragAndDrop`, `IslandDragHandlers`) — the panel as an
  `NSDraggingDestination` and an `NSDraggingSource`, gated by the same `islandPath` that gates
  clicks, so there is one definition of "on the island" rather than two. It owns the enter/exit
  latch and the rule that a drag out of the island can never `.move` or `.delete` the original; it
  owns nothing about what is being dragged, which is the shelf's business (IslandUI, and the app
  shell for anything that touches the filesystem).
- **Hover** (`IslandHitTestView`'s tracking area and watchdog) and **`Haptics`** — the pointer
  arriving is the only thing that tells a user Isleta exists.
- **Support** (`HotKeyMonitor`, `AccessibilityPreferences`, `ProcessMetrics`) — permission-free
  global hot keys, observed accessibility settings, and self-measurement against the §9 budget.
- **The log** (`IslandLog`, `LogFileSink`, `LogExport`) — a fixed taxonomy of categories, one line
  format, and two outputs: the unified log and a size-rotated file under `~/Library/Logs/Isleta`
  that "Export Logs…" bundles with the diagnostics report. It lives here because it is the one thing
  every other package needs and IslandKit is the package they all already depend on. The rules are
  in `IslandLog`'s header; the two that matter: **nothing the user did not write themselves goes
  in** (no notification text, track titles or file names — counts, states, pids and error codes),
  and **nothing on the hot or idle path logs** (`debug` costs nothing when off, because the message
  is an autoclosure). There is deliberately no default sink, so a package test never writes into the
  user's `~/Library/Logs`; lines before the app attaches one are held in a bounded backlog and
  replayed in order.

## Deliberately does not own

- **Any SwiftUI.** The panel takes an `NSView`; the app shell supplies one. IslandKit must never
  import IslandUI — hit testing needs the shape, IslandUI needs the shape, and if the dependency ran
  the other way the two would end up with separate definitions of it.
- **Animation.** `IslandShapeMetrics.lerp` and `MotionSpeed` exist, but nothing here decides when
  anything animates or holds an `Animation`. The four motion tokens live in IslandUI (§6.1);
  `MotionSpeed` is the arithmetic they scale by and nothing more.
- **Drawing a material.** `IslandStyle` says which material applies; `IslandMaterialView` in
  IslandUI is what puts pixels on screen, and every `glassEffect` trap lives with it.
- **Anything permission-gated.** No Accessibility, no media, no notifications; those are
  IslandSources.

## Why the shape lives here and not in IslandUI

A click 2pt outside the visible pill has to reach the app underneath (§4.2). That is only true if
the rendered shape and the clickable region are the same path. `IslandHitTestView` calls
`IslandShapeGeometry` directly and IslandUI's `IslandShape` is a thin wrapper over the same
function, so there is exactly one definition and no way for them to drift.

## The continuous-corner constants

`ContinuousCorner`'s control points were extracted at runtime from SwiftUI's own
`RoundedRectangle(style: .continuous)` output rather than derived or copied. `ContinuousCornerTests`
re-derives them from SwiftUI on every run, so an SDK change that retunes Apple's curve fails the
build instead of silently detuning every island on screen.

## Coordinate spaces

- `NotchGeometry.rect`, `IslandScreen.frame`, `IslandLayout.panelFrame` — AppKit global screen
  space: **y-up**, origin at the bottom-left of the main display.
- `IslandShapeGeometry.path`, `IslandHitTestView` — **y-down**, matching SwiftUI and flipped
  `NSView`s. `IslandHitTestView.isFlipped` returns true for exactly this reason.

## Scroll events, and why they reach a non-key panel

`IslandScrollSample` reduces an `NSEvent` scroll to the four facts a swipe needs — phase, horizontal
delta, vertical delta, whether the deltas are points or lines — and `IslandHitTestView.scrollWheel`
hands one up per event, gated by the same `hitTest` that gates clicks. The physics live in IslandUI;
this package only knows which events arrive and on which screen.

They arrive because scroll events are routed by **location**, not by focus: AppKit's own header says
gesture events go "to the view under the cursor". Key status decides where *keyboard* events go, and
a swipe is not one — so `canBecomeKey` returning false costs nothing here. Verified rather than
assumed: `--swipe-test` synthesises a phased gesture, sends it through `NSWindow.sendEvent`, and
checks that it cycled the queue while the frontmost application and the panel's key status were both
unchanged.

`NSEvent.trackSwipeEvent(options:…)` is the other AppKit route and would supply rubber-banding and
momentum directly. It is not used because it is gated on the user's "swipe between pages" trackpad
preference — measured `false` on the development machine — and a user with that off would find the
island simply did not respond, with nothing on screen to explain why.
