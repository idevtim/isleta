# Motion, visual language and interaction

The spring tokens and the visual rules, then hover, click, swipe and haptics — including the ordering every presentation change goes through.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

- **Springs, not durations. There are ten tokens**, and they all live in `IslandUI/Motion.swift`. No
  inline `.animation(.easeInOut(duration:))` anywhere in this codebase, ever. Four are Milestone 0's;
  the other six arrived one at a time, each with a hardware verdict behind it. **Count them in the
  file before quoting a number** — this list has been wrong in two other places at once (CLAUDE.md
  said seven, the `isleta-motion` skill said four), which is why the table is here and not there.

  | Token | Curve | What travels on it |
  |---|---|---|
  | `expand` | `.spring(response: 0.38, dampingFraction: 0.78)` | Compact → expanded, and any outline change that only *widens* the island. |
  | `collapse` | `.spring(response: 0.32, dampingFraction: 0.85)` | Expanded → compact, and a dismissal. Snappier and better damped: closing should read as decided, not as falling back. |
  | `contentSwap` | `.smooth(duration: 0.22)` | An activity's content changing inside a container that does not move — and the substitute Reduce Motion swaps in for every other token. |
  | `nudge` | `.bouncy(duration: 0.30, extraBounce: 0.15)` | A surface *inside* an island that is standing still: a drawer, a refusal. |
  | `lockHandover` | `.bouncy(duration: 0.70, extraBounce: 0.10)` | The island into and out of the notch at the lock and the unlock, and the padlock between them. |
  | `reveal` | `.bouncy(duration: 0.42, extraBounce: 0.12)` | The island's outline growing **downward**: the peek, the open, the track lip, the lock-screen card. |
  | `pageTurn` | `.spring(response: 0.30, dampingFraction: 1)` | A page landing on its detent, at both ends of a turn. |
  | `rebound` | `.spring(response: 0.16, dampingFraction: 0.55)` | One edge of the island leaning out at the end of a range. |
  | `reboundReturn` | `.spring(response: 0.16, dampingFraction: 1)` | That edge coming home. |
  | `widen` | `.spring(response: 0.50, dampingFraction: 0.86)` | The island arriving at its widest, for a HUD that spells itself in the flanks. |

  Two things beside them are **not** tokens and must not be reached for as if they were:
  `Motion.contentFollowDelay` (40 ms, and deliberately not scaled — see below), and `Motion.speed`,
  which divides every response and leaves every damping fraction alone, so a faster island is the
  same object moving faster rather than a twitchier one. `contentSwapDuration`, `nudgeDuration` and
  `reboundDuration` expose the seconds a token is already built from, for the three callers that
  cannot take an `Animation`; they are not a license to write a duration.

  `lockHandover` is the fifth token and the first added after Milestone 0 — the one move nobody's
  hand is on, judged "definitely slower" than `nudge` by eye on hardware, 2026-08-26. Space
  transitions keep `nudge`.
- **Two tokens are critically damped, and everything else here overshoots on purpose.** `pageTurn`
  and `reboundReturn` both take `dampingFraction: 1` — the fastest approach that never crosses the
  target — and both take it for the same reason: what they are arriving at is a **detent**, a resting
  shape the content already belongs to, so an overshoot reads as missing the mark and correcting
  rather than as weight.
  - `pageTurn` was reported on hardware 2026-08-28 as the page "not centering smoothly": the
    carousel slid a few points past centre and came back. Its response is a little brisker than
    `expand`'s 0.38 because a critically damped spring spends its last stretch creeping. Used at
    every end of a page turn — the swipe's tail (`IslandSwipeModel.landTurn`), an abandoned swipe
    going home (`settle`), and the outline resizing for a dot tapped in the indicator
    (`IslandScreenModel.setPageMetrics`, which was `nudge`) — one movement, one spring.
  - `reboundReturn` is the second half of the lean at the end of a range, and it exists because
    playing `rebound`'s 0.55 damping backwards is a bug rather than a flourish: coming home means
    arriving at *zero*, and crossing zero puts the travel on the **other** edge. Reported from
    hardware 2026-08-29 as "the other side seems to still have a small bounce at the end of the
    animation". Same response as `rebound`, so the two halves are one movement at one speed rather
    than a fast strike and a slow crawl.
- Width, height, and both corner radii animate on **one spring instance** — that's why
  `IslandShapeMetrics.lerp` interpolates every dimension together. Divergent curves are what make a
  morph look like two animations.
- Morphs use `matchedGeometryEffect`; the container leads and content follows by
  `Motion.contentFollowDelay` (40ms).
- **Reduce motion / transparency / increase contrast are correctness requirements**, not polish.
  `Motion.respectingReduceMotion` substitutes a crossfade.
- **On a real notch: pure `#000000`, no material, no blur** — spelled in sRGB so it can't pick up an
  appearance-sensitive variant and lift off the bezel by a shade. **On synthesized islands: Liquid
  Glass** (`glassEffect`), assuming nothing about the rendered result (Golden Gate made opacity
  user-tunable) — but see the trap below: it renders nothing against a custom `Shape`.
- **Font: SF Pro via `.system()` only** — never bundle a font. `.rounded` for timer/HUD numerals.
- Layout in points, snapped to the pixel grid at 1x and 2x.

## Interaction: hover, click, and haptics

**The first launch is a window, not a hint.** Isleta is invisible at rest, has no Dock icon, and its
most-wanted features are behind permissions granted in another application — so before
`OnboardingStep` existed, all three facts were discoverable only by opening Settings and finding the
Sources pane. **Eight pages** as of `OnboardingLedger.currentVersion` 2, and the `OnboardingStep`
cases are what to count: `welcome`, then `accessibility`, `music`, `calendar`, `weather` and
`devices` — five permission pages asking for Accessibility, Automation, Calendar, Location and
Bluetooth respectively, each named for the feature rather than for the permission — then `startup`
(launch at login) and `ready` (where the island is). Presented after the first frame beside `startSources()`, gated by `OnboardingLedger` (a
stored *version*, in `UserDefaults`, deliberately **not** in `IsletaConfiguration` — a first-run flag
there would make "Reset to Defaults" re-run onboarding; the bump from 1 to 2 is what reaches people
onboarded before the permission pages existed). It is not a permission wall: there is always a
control that advances — a Skip appears the moment Continue becomes an ask rather than an advance —
and **closing the window counts as finished**, which is affordable only because "Open Setup Guide" is
in the status menu. §10 still holds on the path — the page draws the permission's *state*, and the
one button that asks is the one the user clicks.

**Presentation is derived, never stored.** Hovering and being open are independent inputs;
`IslandPresentation.resolve(isHovering:isExpanded:)` turns them into `.rest` / `.peek` / `.expanded`.
Storing a single state and mutating it from both sources gives you an open island that shrinks
because the pointer wandered off, or a collapse that lands on `.rest` under a pointer sitting right
on the island and immediately re-triggers hover.

The island is invisible at rest by design, so the pointer arriving is the only thing that tells a
user Isleta exists. Every presentation change goes through `AppDelegate.transition(on:_:)`, and its
ordering is deliberate:

1. **Widen the hit region first**, before the animation starts, so a click arriving mid-grow cannot
   fall into a gap between what is drawn and what we accept.
2. **Request the haptic as the animation is committed.** `.alignment` (the "you have arrived on
   something" tap, not `.levelChange`) at `.drawCompleted`, so AppKit lands the tap on the frame
   that draws the peek instead of a frame or two ahead of it.
3. **Tighten the hit region only on completion**, from the animation's completion handler.

Which spring applies is decided by where the island *ends up*, not by which input changed — and
since 2026-08-27 by **which edge moves**. The island grows in two directions and they do not read
alike: a shape hanging off the bezel that drops, overshoots a little and settles is the notch
behaving like a physical thing, and the same bounce applied to a widen is a wobble. So down is
`Motion.reveal` (the peek, the open, the track lip), sideways is `Motion.expand`, and up is
`Motion.collapse`, which should stay decisive. `IslandScreenModel.apply` selects by comparing the
two forms' **heights** rather than by listing the changes that happen to grow downward — a list is
a second copy of the shape table, and it is wrong the first time a form is added, which has now
happened twice. **Sideways has since split in two**: a widen into the wide flanks is 108pt each
side rather than 40, far enough that `expand` reads as the island appearing rather than growing, so
that one move takes `Motion.widen` — see the wide-flanks section below.

**The lock-screen card arrives on `reveal` too**, changed 2026-08-29 on the owner's report that a
surface appearing on a screen nobody is touching should announce itself the way the notch does. It
was on `expand`, which grows and *arrives* — right for a panel being opened onto, wrong for this —
and the transition's scale was 0.96, an overshoot smaller than the card's own corner radius. It is
now 0.90 anchored at the card's **top edge**, so the card grows downward out of nothing, which is
what makes `reveal` the honest token rather than a bounce borrowed for its shape. The way out stays
`collapse`, the shortest and best damped spring in the file: the Mac is the user's again the instant
they unlock, and a surface still settling over their own desktop is the two-animations-at-once
complaint `AppDelegate.returnDelay` already records for the island.

A bounce needs somewhere to go, and a window clips its contents to its bounds whatever SwiftUI drew
— so `LockScreenCardLayout.overshootMargin` (8pt) is real room in the *panel*, the same thing the
notch surface gets by sizing its panel for the peeked island rather than the resting one. Two
consequences worth knowing before touching that file: `panelFrame` takes the margin off its origin
as well as adding it to the size, because `centerOffset` measures the **card's** top edge and not
the panel's; and the root view is `panelSize` rather than `size`, so the card is centred by the
layout rather than by whatever `NSHostingView` does with spare points — which is not a thing to
discover on a surface only a lock can show.

`reveal` sits deliberately one step below `nudge`: `nudge` moves a surface *inside* an island that
is standing still (a drawer, a refusal), while `reveal` carries the island and everything drawn in
it. A page turn used to be on `nudge` and is now on `pageTurn`, above. `lockHandover` already records what happens when a large shape overshoots as hard as a
small one — it reads as wobbling rather than settling. The hover
tracking region tracks the largest state reachable without another click — too small and the island
growing under a stationary pointer hands itself a `mouseExited` and oscillates; too large and it
stays peeked with the pointer far away over transparent pixels.

The system suppresses haptics unless the user is touching the trackpad, so mouse users correctly get
the animation and no tap — don't add device detection. `Haptics.isEnabled` is the single off switch
until IslandSettings exists. Peek is deliberately small (`IslandLayout.peekWidthGrowth` /
`peekHeightGrowth`): an invitation to click, never the click's result.

Hover uses `NSTrackingArea` with `.activeAlways` (Isleta is never frontmost) sized to the island's
*largest* state, so the island growing under a stationary pointer can't hand itself a `mouseExited`
and start oscillating. `.mouseMoved` **is** in the options, and only because hysteresis needs it:
`mouseEntered` fires once, at the edge of the outer region, and a pointer traveling inward to the
island generates no second crossing — so without move events the inner test could only be evaluated
at the moment it is guaranteed to be false. The §9 cost is bounded by the rect, since a tracking
area delivers move events only while the pointer is inside it.

### The island widens further for an activity that spells itself

Added 2026-08-28, and a fourth case added 2026-09-01. The flank axis of `IslandForm` is a span
(`IslandFlanks`), not a flag: `.standard` buys a 40pt sliver each side of the cutout, `.wide` buys
108, and `.wider` buys 137. The two spelling spans are for the kinds `ActivityKind.flankSpan` names,
where the leading sliver carries the glyph **and the word beside it**:

- **`.wide` — the volume, mute and brightness HUDs.** A volume key and a brightness key draw the
  same picture at a glance and the word is the whole of the difference.
  `IslandLayout.wideFlankedWidthGrowth` (216) is measured against the longest label the shipped
  languages produce (German's "Lautstärke", 61.4pt).
- **`.wider` — power.** `battery.100percent.bolt` on a charger and `battery.100percent` on a full
  battery differ by a bolt 4pt wide, in a notch, from a meter away, and they mean opposite things
  about whether the user has to go and find a cable. The labels are *phrases* rather than nouns —
  "On Battery", "Low Power Off", "Sparmodus aus" — and every shortening that fits the HUD's 61pt
  sliver reads as a different fact, so `IslandLayout.widerFlankedWidthGrowth` (274) is sized to them
  and to the battery glyph, which at 23pt is wider than any HUD's.

`WideFlankLayoutTests` re-measures all thirty-six labels every run, against the sliver each span
actually affords, because a system font update moves them.

**Two constants and not one shared widest**, and that was the owner's call on 2026-09-01: the two
kinds are sized to different words, and growing the HUD's island from 401pt to 459 to hold "Volume"
— 43pt of word in 90pt of room — spends `flankedWidthGrowth`'s "a wider notch, not a black bar that
happens to contain the notch" budget on the kind that does not need it. Four discrete shapes on this
axis is still a table, not a continuum.

**A span is asked of the sliver that carries the word, not of the kind alone.** A pair hands a kind
one sliver and it is not always the one with the word in it — power behind a ringing call takes the
flank the call did not, and draws the level there. `ActivityStage.flanks` therefore asks whether that
flank's content has a `title`, so the island never widens by 274pt for a bar. The same change moved
`ActivityKind.power.flankAffinity` to `.leading`: power outranks Now Playing, so a charger going in
while music plays is the common pair, and the word is the half of power that could not be inferred
from anywhere else on screen — the percentage is already in the menu bar and on the open island.

Four things about it are worth keeping in mind before touching the flank axis:

- **It travels on `Motion.widen`, which exists for this move and nothing else.** 185pt of cutout to
  401pt of body is 108pt out on each side — nearly three times `flankedWidthGrowth`'s 40pt sliver,
  which is the travel `expand`'s 0.38s response was tuned against. At this distance the same curve
  does not read as growing; it reads as the island *appearing*, full width, in one frame. The
  owner's verdict on hardware, 2026-08-29: "let's have a slightly slower animation out from the
  notch so it's not so jarring to the users." 0.50s, and damped **above** `expand` at 0.86 rather
  than below it — `reveal` records the rule this obeys, that a shape dropping out of the bezel should
  overshoot and the same bounce applied sideways is a wobble, and the wider the shape the worse that
  reads. Deliberately not `lockHandover`: 0.70s is half the life of a HUD that expires in 1.5s.
- **They are the collapsed shapes wider than the open island** — 401pt and 459 against 368 on a
  185pt notch. So the widen-then-tighten protocol names a *third* maximal form,
  `.widerFlankedPeekWithLip`, alongside `.expanded` and `.flankedPeekWithLip`. One form covers both
  spans because the widest contains the wide one at the same presentation, and they exceed the open
  island in width and only in width, which is what makes one extra call sufficient.
- **Nothing ambient may ask for either span.** The width is paid for by the kind expiring — 1.5s for
  a HUD, 5s for a power moment; a condition that is permanently true would leave the island
  permanently at its widest, which is a black bar with a notch in it rather than a notch — the
  failure `flankedWidthGrowth`'s own ceiling exists to avoid.
- **The shell compares the span, not a flag.** A HUD arriving over music leaves "has flank content"
  true on both sides of the change while moving the outline by 136pt, and a boolean comparison there
  decides nothing moved and skips the widen.

### The rebound at the end of a range

Added 2026-08-29. A level the user is driving — volume, display brightness — at its top or bottom
springs **one edge** of the island `IslandLayout.limitBounceDistance` (16pt) out and back, on
`Motion.rebound`. The right edge for the maximum, the left for the minimum. It is the rubber-band at
the end of a scroll, and it says the one thing a full bar cannot: that there is no more.

- **One edge, not the island.** It started as a translation of the whole shape and that was wrong on
  a notched Mac in a way a synthesized island hides: the physical hole does not move, so a slid
  island reads as sitting crooked on its notch. The owner's verdict, 2026-08-29: "we don't move the
  whole notch just that side."
- **The lean is a property of `IslandShape`, not an effect composed outside it**, and getting there
  took three hardware reports of the far edge moving anyway. The second version grew the outline
  symmetrically and shifted the drawn island by half the growth, on the arithmetic that the two
  cancel at the fixed edge. **They cancel at the endpoints and nowhere in between.** Those are two
  animatable channels, SwiftUI hands a retargeted spring the velocity the old one had, and a lean
  requested while the island is still widening into a HUD gives the shape's width some of
  `Motion.widen`'s velocity and the `.offset` none of it — so the halves stop matching mid-flight
  and the nailed-down edge drifts and settles back. Measured as arithmetic, not as pixels: the two
  channels are only equal at t=0 and t=1.
  `IslandShape.lean` is now one number inside the shape's own `animatableData`, alongside width,
  height and the radii, for §6.1's reason said again — `path(in:)` derives both the growth and the
  origin from it, so the fixed edge is fixed at *every* frame. It is a **magnitude**, clamped at
  zero, and which edge it moves is `leansTrailing`, which never animates: a spring aimed at zero
  overshoots through it, and a signed value would put the lean on the far side for those frames.
  The model splits the same way — `limitLean` and `limitLeansTrailing`.
- **Only the outline and the bar move.** The content is laid out against `contentMetrics`, so the
  glyph and the word hold still; the bar in the stretching sliver grows with the edge from a fixed
  anchor (`bounceStretchAnchor`, also not animated, for the same reason).
- **A test on the model could not have caught any of this.** The model holds only the two endpoints
  of an animation; everything the user reported lived in the frames between them. The check that
  matters walks `IslandShape`'s geometry across the whole range a spring can produce, negative
  values included — `IslandShapeTests.leanMovesOneEdge`.
- **`Motion.rebound` is the eighth token**, and the first tuned for a movement that repeats several
  times a second. At `nudge`'s 0.30s a held key never lets the spring finish its outward swing, so
  the edge parks and the island reads as having stopped responding — macOS repeats a volume key
  about ten times a second. 0.16s, `dampingFraction` 0.55. Each press strikes from zero rather than
  easing toward a target it may already be at — setting the same target again is a no-op to a
  spring, which is what made a held key produce one beat. It is not a variant of `nudge`: `nudge` is
  an *attention* nudge, something the island does to be noticed, and this is an *answer* — the user
  pushed and there is nothing left to give. It fires only from `IslandScreenModel.limitBounce`.
- **`Motion.reboundReturn` is the ninth, and it is the half that must not overshoot.** The way out
  is a real overshoot because 16pt is invisible without one; played backwards that same overshoot
  crosses zero, and crossing zero puts the travel on the **other** edge — the right edge stretches
  out, comes back, and then briefly stretches the left. Reported from hardware 2026-08-29 as "the
  other side seems to still have a small bounce at the end of the animation". `dampingFraction: 1`,
  at `rebound`'s own response, so the strike and the return are one movement at one speed. The
  return is *scheduled* against `Motion.reboundDuration` rather than hung off
  `withAnimation(_:completion:)`, for the reason `nudgeDuration` already records: that completion
  fires immediately where nothing is hosting the transaction, which is every test process.
- **Which means it is the dangerous direction for hit testing**, and the only thing here that is.
  The window server derives the panel's event shape from the alpha of what we draw, so a leaning
  island is opaque 16pt beyond what `islandPath` accepts — drawn pixels we refuse. Both ends of the
  widen-then-tighten protocol carry the allowance: `AppDelegate.transition` widens to the wide
  flanked peek **plus** the travel, and `IslandScreenModel.hitRegionMetrics` tightens to the same.
  Symmetric, so one answer covers a lean either way, and gated on the *activity* rather than on the
  live value — the region is set once, when the change settles, and the lean is still moving then.
  (The re-entry `scaleEffect` in `IslandRootView` is the mirror image and is safe: it only ever runs
  smaller, which is a subset.)
- **Which end of the range means which way is decided in IslandUI and nowhere else.**
  `ActivityLimit` says `.minimum` or `.maximum`; a level is drawn filling left to right, so the
  maximum is to the right. That is a fact about drawing, so IslandActivities does not carry it.
- **The source decides *whether*, and that is not fussiness.** `SystemHUDLevelState` publishes level
  zero for a **mute**, which is not a range being run to its bottom — an island reading the number
  back would bounce every time anybody muted.
- **Reduce Motion drops it entirely** rather than substituting a crossfade. Every other substitution
  in this codebase exists because the movement is *carrying* something; nothing is carried here.
- **Pushing against a limit already reached is invisible to the levels, so the keys are watched for
  it — and only for it.** Measured 2026-08-29: setting the volume to the value it already holds fires
  no CoreAudio listener at all, so a key pressed at the top produces no reading. `MediaKeyMonitor` is
  a `CGEventTap` on `NX_SYSDEFINED` that, for the rebound's purposes, speaks **only** when a key asks
  for more of a level that is already at that end; everything else is left to the level observers,
  which see it properly. **Its `MediaKeyMode` is `.observe` here and that is the whole of it** — the
  same tap gained a `.replace` mode on 2026-08-30 for HUD suppression, where it consumes the key
  instead, and nothing about the rebound depends on that mode being on. It needs Accessibility,
  which Isleta already asks for in onboarding, and without it
  nothing prompts and nothing breaks — the island still rebounds when a level *reaches* an end,
  because that is a change. A tap rather than `NSEvent.addGlobalMonitorForEvents` because the tap
  reports its own refusal; `--media-key-test` is what answers whether real keys arrive, and it waits
  for a human press because synthesised media keys are the invalid stimulus
  `DisplayServicesBrightnessMonitor` already records.
- **Brightness needed the opposite fix**: its 100ms throttle was swallowing the settled value, so an
  end of the range now publishes inside the window — the one value in a ramp that is not a transient.

The volume glyph carries the same news a second way. `ActivityContent.symbolVariableValue` feeds the
level into SF Symbols' variable value, and `speaker.wave.2.fill`'s two wave layers light in turn —
three states, no waves through both. Measured 2026-08-29 by rendering each candidate at 0, 0.34, 0.67
and 1 and comparing bitmaps: the two `speaker.wave.*` symbols respond, `speaker.slash.fill`,
`sun.max.fill` and `sun.min.fill` do not, and there is no brightness glyph in SF Symbols that would.
Setting it on a symbol that ignores it costs nothing, so all three HUDs carry it.

### The pointer on the album cover, which is a second hover inside the first

The collapsed island's leading flank is the album sleeve, and the pointer resting on it springs a
43pt **lip** out under the cutout with the track's title and artist in it — the seventh island shape
(`IslandForm.showsTrackLip`). It is a second hover, nested inside the island's own, and four things
about it were arrived at rather than chosen:

- **It is a pointer *position*, not a tracking area over the cover.** The first version put an
  `NSTrackingArea` on the artwork view and it failed in the one gesture the feature is for:
  approaching the cover from outside the island worked, sliding to it from the middle of the notch
  did nothing. A nested tracking area hears only about crossings of its own rect, and the working
  case was never a crossing — it was the island growing rest→peek under the pointer, relaying the
  view out and re-reading the position as a side effect. This view already records the same lesson
  one level up for its own hysteresis: the crossing happens at the outer edge, so everything inside
  the island must be answered from where the pointer *is*. `IslandHitTestView.onPointerMoved` now
  carries it, and `IslandScreenModel.isPointOnAlbumArtwork` answers it — one rect-contains test on a
  stream that only flows while the pointer is on the island.
- **It travels `AppDelegate.transition(on:_:)` like every other presentation change**, because it
  moves the island's outline. A view reporting the pointer straight into the model would resize the
  island with its hit region a frame behind. It is also the one shape the open island does not
  contain — at the ceiling of both size settings the lip is 112pt against an open island's minimum
  of 108 — so the widen names **both** maximal forms rather than only `.expanded`.
- **No dwell, in either direction.** It shipped with 180ms on arrival, guarding against a pointer
  crossing the notch flashing the strip in transit; the owner's verdict on hardware was that coming
  to the cover from inside the notch the lip has to be there *already*. The guard was redundant
  anyway — the lip is forced false unless the island is peeking, and peeking was itself behind
  `hoverDelay` (a setting through 2.0, removed at schema 18 and pinned at its neutral zero), so a
  pointer merely passing through never had a lip to flash.
- **It springs on `Motion.reveal`**, along with every other downward move the island makes — see
  below. Both directions, like every other outline change that leaves the presentation alone.
- **The title's marquee is CoreAnimation** (`MarqueeText`), for §9's rule about continuous
  animation. Two copies of the line with a 44pt gap, scrolled by exactly one copy plus the gap so
  the loop is seamless. Reduce Motion clips and fades instead of traveling.

The lip does not contradict `IslandLayout.flankedHeightGrowth` being zero. That rule is about a strip
of text hanging under the notch **at rest**, which is a panel and not a notch; this is under the
pointer, and gone when the pointer is.

## The click opens; the pointer leaving closes

Reworked 2026-08-26. **A click on the island only ever opens it.** It was `toggleExpanded`, and the
toggle was wrong the way a toggle usually is: its two halves are not the same gesture. Opening is
aimed at the island — the pointer crosses the notch, something is there, the user clicks it. Closing
by clicking again means aiming at the *body* of an open panel, which is where all of its content is,
so the second click of a toggle is indistinguishable from a click on whatever the island is showing.
Every surface that grew its own controls made that worse, and the page indicator's gaps are carved
out of the toggle for the same reason: a click that lands on a control must not also mean "close".

So the click means one thing, and every way out points somewhere that is **not** the island:

| Way out | Where |
|---|---|
| The pointer leaves the island and its blur | `AppDelegate.pointerExitChanged` |
| A click in the blur | `IslandHitTestView.onBlurClick` → `closeIsland` |
| A click anywhere else on screen | `updateOutsideClickMonitor` |
| Escape | `handleEscape` |
| Two-finger swipe up | `IslandCloseGesture` |

| Right-click | Isleta's own menu — Settings and the rest (`AppDelegate.showIslandMenu`) |

All of them land in `collapseIslands`, so the island is handed back in one state however it was
closed — a second way of closing that closed it *differently* would be a second state machine.

**Only the user's own island.** One Isleta opened by itself — a greeting, a meeting, a ringing call
— is not dismissed by the pointer wandering off it, exactly as it is not dismissed by a click
elsewhere. It has a dwell of its own, and the pointer resting on it already holds that dwell open and
releases it on leaving; closing here as well would take it away at the instant the grace period was
meant to begin.

**And not while Isleta's own menu is up.** A right-click on the island raises an `NSMenu`, and moving
onto it *is* the pointer leaving — so `AppDelegate.isShowingIslandMenu` holds the grace open for as
long as the menu is, and `menuDidClose` re-asks the question rather than assuming the pointer came
back.

**It closes on the pointer *leaving*, never on the pointer being outside.** An island opened by the
global hot key with the pointer on another display has no hover to lose, and treating "not hovering"
as the trigger would close it in the frame it opened.

**And there is a grace period** (`AppDelegate.pointerExitGrace`, 220 ms) before it acts, because
`mouseExited` is not only about the pointer having gone anywhere: the tracking rect is rebuilt
whenever the island's size changes, and a rect rebuilt under a stationary pointer reports an exit and
a fresh entry. Waiting, then asking `IslandController.isHovering(forScreen:)` where the pointer
actually **is**, settles both — a real departure is still outside, a rebuild is not. It is
deliberately not a `Motion` token: it is a grace period, not a curve, and scaling it with the user's
animation speed would make a faster island a twitchier one.

## The horizontal swipe means two different things, and the island's state is what decides

A two-finger horizontal swipe over the notch is read by **two** gestures, and which one answers is
decided by whether the island is open. Nothing else separates them — they share an axis, they see
the same `scrollWheel` samples, and they are kept disjoint by one `guard`.

| Island | Gesture | What it means |
|---|---|---|
| Closed | `IslandStowGesture` | **Stow** — put what is on stage away, back to the bare cutout. Swipe again to bring it out. |
| Open | `IslandSwipeModel` + `IslandPageModel` | **Turn a page** — `home ⇄ music ⇄ weather`, wrapping. |

Three things about that split are load-bearing:

- **`IslandStowGesture` ignores an open island outright**, in its first `guard`. That is the only
  thing keeping a page drag from also stowing the island out from under itself, and
  `--swipe-test` checks it explicitly: it pages an open island through sixty samples and asserts
  nothing stowed.
- **The stow is direction-agnostic; either way toggles.** It started out directional — left away,
  right back — and that requires the app and the user to agree on which way is left, which they do
  not: `deltaX`'s sign follows the trackpad's scroll-direction setting, so the same flick means
  opposite things on two Macs. Toggling needs no such agreement.
- **The commit distances differ because the mistakes differ.** `IslandStowGesture.commitDistance`
  is 28pt and `IslandCloseGesture.commitDistance` — the vertical swipe up that closes an open
  island — is 24pt. A false stow takes content away from somebody who never asked for the island,
  which to them is indistinguishable from a crash; a false close costs one click to undo. The close
  gesture is vertical and only acts on an open island, so it is disjoint from both of the above.

This axis has had a third meaning and does not any more: swipe-to-cycle, which turned the activity
queue. It lost to stowing because the queue usually holds one thing, so the gesture spent most of
its life doing nothing while stowing always has an answer. `ActivityCoordinator`'s pin,
rubber-banding and momentum are still there and still tested; nothing drives them.

## The page carousel, and why a turn commits before it finishes

Measured on hardware 2026-08-28, against two reports: quick swipes "stop on the one it's animated
into" instead of going on to the next, and the landing "moves a few pixels too far and then back".

**The turn now steps the page at the commit and settles a *tail* against it.** It used to travel the
remaining inches of the page and swap the identities in the spring's completion — invisible, and
correct for one swipe at a time. For two it was not: for the whole length of that spring
`IslandPageModel.current` still named the page being left, so a second gesture arriving inside the
window computed its neighbours from the wrong page and was then overwritten when the first turn
landed, which zeroed a live finger offset and took the carousel down mid-gesture.

The swap moves nothing because the offset is **re-expressed** rather than travelled:
`IslandSwipeModel.rebased(offset:by:)` is `offset - destination`, so content 184pt short of the next
page becomes 184pt past the page it just left. The outline is continuous by the same arithmetic —
the shape table becomes the arriving page's and `incoming` becomes the departing one's, and lerping
the old height at `1 - progress` is the height it was already at. So is the page indicator, whose
highlight is `pageBeingDraggedTo` weighted by the same progress.

**The offset is two numbers, and that is what makes a turn interruptible.**
`IslandSwipeModel.offset` is `landing + drag`: `landing` is the tail still easing into its detent,
`drag` is where the finger has it. `track` writes `drag` only, so a gesture that starts on a moving
surface adds to it rather than seizing it. `AppDelegate.beginPageDrag` therefore arms the carousel
from the direction the *content* is displaced in, not the direction of the finger — until the drag
pulls the offset through zero, the neighbour on screen is the one the tail is showing.

**Whoever armed the carousel last is the only one allowed to take it down.** The completions here
end the gesture — neighbours off screen, hit region tightened — and an interrupted spring still
delivers one, so `IslandSwipeModel` drops any completion from a generation older than the last
`beginPaging`. The gesture that interrupted it owns the teardown, and closing the island clears the
offset outright rather than waiting for a completion with nothing left to complete.

**Nothing inside a page may read the outline the drag is moving.** The carousel is the only
animation in this app a finger is on for its whole length, and the island's bottom edge follows that
finger — `IslandScreenModel.draggedTowardIncomingPage` re-lerps `contentMetrics` on every tracked
sample, about 120 a second. Under Observation that makes any page body which reads it re-evaluate at
the frame rate, and during a drag there are **three** live pages, so a day, a player and a forecast
were all being rebuilt per sample. Measured 2026-08-31: an empty island's swipe drops zero frames and
a loaded one drops a dozen per four turns, which is the whole tell — the cost is not the carousel,
it is what the carousel is carrying. So a page asks `IslandScreenModel.contentBodyWidth`, which is the
same number without the drag applied, and `IslandLayout.bodyOrigin` has a spelling that takes a width
rather than a shape. **The width genuinely cannot move under a drag** — all three pages are
`IslandLayout.expandedBodySize.width` and only their heights differ, and the one surface that is
wider, the schedule, is a drill-down that takes the carousel down while it is up. This is
`IslandPageHeight`'s argument in the other axis, and the rain field is where the two meet: it is the
one layer inside a page that is really a function of the island's *height*, and it now takes its
ground from its caller, because `contentMetrics` while the weather page is a **neighbour** is the
shape of the page being left. `docs/PERF.md` has the paired numbers and the two things that were
measured and found not to be the cause.

**`--swipe-test` walks it.** It turns three pages and back, then swipes twice with no pause between
and checks *both* turns landed — a one-step check cannot tell "it turned twice" from "it turned once
and stopped", which is the whole symptom. Two steps and no settle in between, deliberately. Reverted
against the previous implementation the same binary reports
`swiped left twice with no pause between → home`.

## The dots go away, and what keeps them reachable

Decided 2026-08-29, on the report that three permanent marks under every page are saying "there are
three pages" to somebody who has not moved for a minute and is reading a forecast. **The row of dots
is a signpost, not a control bar.** What it says is only ever news at the moment the page changes:
which of the three you arrived on, and that there are others either side.

So the dots are lit at a page change, held for `IslandPageModel.indicatorDwell` — **1.2s** — and
faded on `Motion.contentSwap`. It was 2s, on the argument that that is what a row of three dots is
*read* in; on hardware that was the wrong measurement. Nobody reads the dots, they glance at them,
and the interval that matters is how long the island goes on wearing a mark after the user has
finished with it. The dwell is not a motion token and deliberately does not scale with
`Motion.speed`: the fade is motion, the dwell is a person glancing, and glancing does not get faster
because the animations do.

**The fade is an opacity and never a branch.** The strip's 28pt is reserved by
`IslandForm.showsPageIndicator` for as long as the island is open — see `IslandPageIndicatorLayout`
for why that height cannot follow its contents — so dots that came and went by *existing* would move
the island's bottom edge, and the hit region pinned to it, two seconds after the user stopped
touching anything. `IslandScreenModel.showsPageDots` is the drawn question;
`contentShowsPageIndicator` remains the height one, and the two are not the same question.

Four things light them, and they divide into a clock and two hands:

| | |
|---|---|
| a page turn, and a dot in the row | `IslandPageModel.go`/`step` → `showIndicator`, dwell restarts |
| the island opening onto a page | `IslandScreenModel.setExpanded`, guarded on it not already being open |
| a finger on the carousel | `holdIndicator` at `beginPageDrag`, released where the gesture ends |
| a pointer on the strip | `PointerPresence` over the row → `holdIndicator`/`releaseIndicator` |

The last one is a **correctness requirement, not polish**, and it is why the pointer case exists at
all: the dots are the only pointer route between the pages — the swipe is a trackpad gesture — so a
row that faded on a clock and stayed faded would take page turning away from every mouse user. A
pointer travelling to the bottom of the island brings them back and holds them, which is what every
other control on this platform that hides itself does. It is also why nothing is ever clicked blind:
hovering is what reveals them, so a press lands on dots that have been under the pointer for the
length of the journey. `PointerPresence` rather than `.onHover` for the reason written on that type
— this panel is never key, and the window server delivers tracking events to one in that state only
through an `.activeAlways` area.

Opening is included on the same argument. It is the one appearance that is not a turn, and it is the
only one a person who has never swiped will ever see; without it the row exists solely as the answer
to a gesture nobody has been told about.

## The island comes back to where you were, except the weather

Decided 2026-08-29. `IslandPageModel.reset()` sent the island to `.home` on every close, on the
argument that reopening onto the weather because that is where somebody stood three hours ago is the
island deciding what they came back for.

**That argument is right about the weather and wrong about the other two.** Home and music are where
a person *lives* — one is the day, the other is what is playing — and somebody who keeps the island
on the player is answering the question every time they reopen it. The weather is different in kind:
it is a thing you go and look at and are then finished with, there is no state of the world in which
"check the forecast" is a standing preference, and a reading fetched a quarter of an hour ago is the
one page that can be stale on arrival (`WeatherSource.refreshInterval`).

So `rememberedPage` is written by every turn **except** one to the weather, and `reset()` goes there.
A trip to the forecast therefore leaves the memory standing rather than clearing it to home — home →
weather → close comes back to home, music → weather → close comes back to music, which is the answer
each of those users would give. Both routes write it through one private `arrive(at:)`, so a page
change added later cannot quietly skip it.

**Session-scoped, deliberately.** It is not in `IsletaConfiguration` and is not persisted: appending
a stored property to that struct is the cross-package memory-layout trap, and it belongs in a change
that is only that. This is an agent that runs for weeks, so the memory outlives every session that
needs it.

`AppDelegate.resetPageAfterClose` asks `pages.current != pages.rememberedPage` rather than
`!= .home`. Against `.home` it skipped the reset for somebody closing on home with music remembered,
and the island reopened where it closed rather than where it was told to.

## The blur around the open island

The band of blurred desktop around an open island is a **region first and a picture second**. A
368pt panel whose edge is a hair trigger is unusable — a pointer traveling to a control near the rim
would close the thing it was aiming at — so there is 24pt of forgiveness (`IslandLayout.blurSpread`,
bounded by `panelMargin` so it always fits the panel), and the blur is that forgiveness made visible.

| Fact | Where |
|---|---|
| What is drawn | `IslandBlurView` / `IslandBlurRootView` (IslandUI) |
| Where the pointer may rest without closing | `IslandLayout.hoverRegion` for an open island, which *is* `blurRegion` |
| What a click there does | Nothing of ours — it reaches the app underneath, and `updateOutsideClickMonitor` spares it |

### It is drawn in its own window, and that was forced by measurement

`IslandBlurPanel`, one per screen, directly beneath `IslandPanel`, `ignoresMouseEvents = true`,
hosted in the same private overlay space.

It started as a layer inside `IslandRootView` and that cost every click in the band. The window
server derives a window's event shape from the alpha of its backing store, so anything painted
outside `islandPath` routes its clicks to us — and an `NSVisualEffectView` claims **every point its
mask covers, at any tint whatsoever**. Measured 2026-08-26 with `--click-test`, sweeping the band at
2, 6, 12 and 20pt outside the island's wall across blur strengths of 0.34, 0.20, 0.12 and 0.06:
*claimed at every point and every strength*. The mask does bound it — the panel's far corner reports
`NOT Isleta` throughout, so the shape is honored — but inside that shape the surface is opaque to
the window server however faint it looks.

So there is no strength at which a blur drawn in the island's panel lets a click through, and
`IslandBlurView.strength` is free to be chosen by eye precisely because the split settles the
hit-testing question elsewhere.

**`ignoresMouseEvents = true` is forbidden on `IslandPanel` and required here.** The rule in
CLAUDE.md is about the island's panel, where the alpha-derived event shape is the whole mechanism and
*assigning* the property — either value — replaces it with the window's entire frame. This window
draws no control, accepts no click and has no hit testing of its own; `true` is the documented way to
say exactly that.

### Two consequences that are easy to miss

**A click in the band does not close the island.** It passes through to whatever is behind Isleta,
and the global outside-click monitor — which would otherwise read it as "not this" — checks
`IslandController.isPointInBlur` first and spares it. A coordinate check is correct *there
specifically*, and only because the blur is in a window that ignores mouse events; everything else
that monitor sees is genuinely somewhere else.

**`mouseExited` stopped being evidence.** The band is not in the island's panel, so that panel stops
receiving mouse events the moment the pointer crosses the island's own edge, and AppKit reports an
exit that did not happen. Both places that acted on it now ask for a **position** instead:
`IslandHitTestView.mouseExited` ignores the hint while `pointerIsInsideHoverRegion`, and
`AppDelegate.pointerExitChanged`'s grace timer asks
`IslandController.isPointerInsideHoverRegion(forScreen:)` rather than `isHovering`. Genuine
departures are still caught, because `startHoverWatchdog` was already asking the same question every
100 ms.

### The material was measured, and the obvious ones were wrong

Three routes to blurring the desktop behind a transparent window, all tested on hardware 2026-08-26:

| Route | Tint | Result |
|---|---|---|
| `CALayer.backgroundFilters` + `CIGaussianBlur` (public) | none | **Draws nothing.** Background filters see only what is composited inside the same window; they never see the desktop. |
| `SLSSetWindowBackgroundBlurRadius` (private, SkyLight) | **none** | A true colorless blur — and **window-wide**, with a hard rectangular edge, not masked by alpha. `SLSSetWindowClipShape` bounds it but clips the window's *content* with it (the island vanished) and wants device pixels. A region is a list of rectangles, so the edge could never feather. |
| `NSVisualEffectView` (public) | yes | What ships. |

`glassEffect` is not in the table because it is not a blur: Liquid Glass is mostly its *edge*, and
this band has no edge to give it — the whole point is that it ends in nothing.

`.fullScreenUI` with the appearance **pinned to `.darkAqua`**, measured against `.hudWindow` and
`.underWindowBackground` over both a dark and a light desktop: left to follow the system, the light
variant renders a **white glow** around a pure black island — the one shape in this app whose edge
has to be invisible against the bezel, wearing a halo. Pinned dark it is a soft blur of whatever is
behind it on either desktop.

It rides `IslandMaterialView.openPresence` — the ramp Liquid Glass and the shadow already arrive on —
so a closed island and a peek have none, and the view is **absent** there rather than transparent. A
behind-window blur is work the window server does on our behalf and it does not stop because a layer
above is at zero opacity, and §9's idle budget is measured on a closed island, which is the state
Isleta is in essentially always.
