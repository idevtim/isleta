# IslandUI

Every pixel Isleta draws, and every curve it moves along.

## Owns

- **`IslandShape`** — the SwiftUI `Shape` wrapper. Its `animatableData` carries width, height and
  both corner radii in one value, which is what makes §6.1's "everything on the same spring" a
  type-level guarantee rather than a convention.
- **`Motion`** — the four motion tokens, the content-follows-container delay, the reduce-motion
  substitution, and the `ActivityChange` → token mapping (§6.2). Nothing in Isleta may write an
  inline `.animation(...)`. The tokens are **springs**, so the user's animation speed divides each
  one's *response* and leaves its damping alone — the arithmetic is `MotionSpeed` in IslandKit, and
  its note says why speeding a spring up by tightening its damping is the wrong answer.
  `contentFollowDelay` is deliberately **not** scaled: it is the gap that makes the container read
  as leading, and at 2× a 20ms lead is below the frame interval on a 60Hz panel.
- **`IslandRootView`** — what a panel draws: the island's material, with the activity layer masked
  to the island outline on top.
- **`IslandMaterialView`** — the material itself, and where both `glassEffect` traps are written
  down: it renders **nothing** against a custom `Shape` (so the glass is drawn against a
  `RoundedRectangle` and masked to ours), and handed to `.background(_:)` it composites *above* the
  content (so it is a sibling below the activity layers, never a modifier on them). Which material
  applies is `IslandStyle`'s, in IslandKit; this file only paints it. **Nothing here redraws per
  frame, and that is a hard requirement** — see "What is drawable, and when".
- **`ActivitySlotLayout`** — where each of an activity's four slots can be drawn, given the island's
  current size and the physical cutout. The one place that knows the cutout is a hole rather than a
  dark rectangle.
- **`ActivityContentView` / `ActivityPalette` / `ActivityValueFormatter`** — what an `ActivityContent`
  looks like: type, color, and the numerals a `.countdown` or `.elapsed` resolves to.
- **`AlbumColor`** — the accent a cover gives, as arithmetic: an 8×8 resample averaged by alpha,
  then lifted in HSB until it reads against pure `#000000`. Computed **once per track change**, in
  `NowPlayingController.setArtwork`, never on a frame and never on a timer. What it tints is
  deliberately narrow — the transport glyphs, the cover's fallback well, the played part of the scrub
  bar — and what it must not is written out at `ActivityPalette`: not the equalizer, which is white
  because a tinted level meter reads as decoration; not the numerals; not the timer ring or the
  battery ring, whose colors *are* the information; and not the island's own material. Increase
  Contrast returns the palette's own color, because a color taken off an arbitrary image can be
  promised no particular contrast.
- **`ActivityExpandedHeight`** — how tall the island opens for what is on stage. The open island used
  to be one constant for every activity, which is right for the Now Playing player and the shelf —
  both draw their own body against a rectangle they already agreed on — and wrong for everything
  else: it hung a one-line greeting four lines deep and cut a long two-line body off at one.
  The height is settled at the moment an activity is published and never moves while it is on stage,
  which is what keeps `islandPath` tracking a shape that has stopped changing. The text measurement
  is injected (`ActivityTextMeasure`) so the arithmetic around it is testable with no fonts.
- **`ActivityClock`** — the one display link, and only while something time-dependent is on screen.
  Two cadences: `.seconds` for numerals and `.frames(n)` for anything that has to move faster.
  `IslandScreenModel.clockRate` picks the cheaper one that will do, and picks `.stopped` almost
  always. **Nothing requests `.frames` any more** — the equalizer was its only caller and now runs on
  the render server. The cadence is kept because the next thing that wants to move will reach for it,
  and the rule it has to be told is the one below.
- **The Now Playing views** — `NowPlayingSlotView`, `NowPlayingViews`, `NowPlayingExpandedLayout`,
  `NowPlayingController`. One of the activity kinds with a bespoke renderer, which is the escape
  hatch IslandActivities' README sanctions: album artwork and a moving equalizer are not sayable in a
  vocabulary of symbols and strings. The equalizer is the one thing in this package that is **not**
  SwiftUI: `EqualiserBarsView` is six `CALayer`s behind an `NSViewRepresentable`, for the reason in
  "Nothing new may redraw per frame" below. It returns nil from `hitTest`, because a press on the
  bars has to reach `IslandHitTestView` to open or close the island. Keyed on `ActivityKind.nowPlaying` in `ActivityLayerView`;
  everything else, including this activity's own compact badge, still goes through
  `ActivityContentView`.
- **`NowPlayingUpNextPeek`** — when the open island names the next track, and nothing about what the
  next track *is*. Pure: `duration - position(at:) < 10`, evaluated against the instant
  `ActivityClock` is already publishing for the numerals on the same row. That is the whole feature
  on this side, and it is arithmetic rather than a schedule on purpose — a timer per track would
  have to be canceled on every pause, re-armed after every seek, and would be wrong after a scrub.
  Four conditions withhold it (no duration, a track shorter than the window, a rate of zero — which
  is both a pause and a drag — and a rate below zero, which is a countdown), and the title itself
  is two strings on `NowPlayingController`, pushed in by the app shell. It draws in the **artist's
  line**, never a fifth row: `islandPath` tracks a settled shape, and a row appearing ten seconds
  before the end of every song would move the region clicks are accepted in, under a pointer that
  may be on the transport row.
- **The Up Next surface** — `NowPlayingQueueLayerView`, `NowPlayingQueueLayout`. The playback queue
  as a scrollable list, drawn in the open island's body in place of the player's own, with the
  flanks still saying what is playing. Two tabs — Up Next and Output — because they are the same
  question asked twice (*what plays next, and where does it come out*) and because two surfaces
  would be two heights.

  **The height is a constant, unlike the recents list's.** That list holds at most twenty rows and
  never gains one unprompted; this window *grows on its own* as the reader scrolls, because
  reaching the bottom is what asks the helper for another page — so a height derived from the row
  count would move the island's own bottom edge under a pointer that is on it, through the
  widen-then-tighten protocol, every time a page landed. The two tabs share the row geometry for
  the same reason: `islandPath` tracks a settled shape, and a tab that resized the island would be
  a second reason for the outline to move that has nothing to do with what is playing.

  The scroll mechanism is the one `RecentsLayerView` established (that view is withdrawn; the
  mechanism outlived it), verbatim and not by preference: a `ScrollView` with
  `.scrollDisabled(true)` driven from `.scrollPosition(_:)`. Inside this hosting view a SwiftUI
  clip does not contain scrolled text, images or buttons — nine combinations were measured letting
  rows draw over the header while a plain `Rectangle` overflowing the same container was clipped
  exactly. The *state* is its own type (`NowPlayingQueueScroll`) rather than `RecentsScroll`,
  because the two clamp against extents that behave differently: this one grows as a consequence of
  scrolling.

  **Double-click plays a row; a single click does nothing and is still consumed.** A single click
  on a list of songs is how a person reads down it, and making that jump the player would mean
  every stray click changed what they were listening to — but an *unconsumed* press travels back up
  the responder chain to `IslandHitTestView.mouseDown` and closes the island, so the row is a
  `Button` with an inert action carrying a high-priority double-tap. **Row 0 is the track that is
  playing** and is inert, drawn from the index and never from `isCurrentlyPlaying`, which reads
  zero on every entry including that one.

  The **playback rate** is a readout in the header, drawn only when it is not 1×. Not a control:
  `MRMediaRemoteSetPlaybackSpeed` takes an `int`, so it cannot express 1.5× and what its integers
  mean is not established. The rate itself is worth saying — a podcast left at 1.5× has no other
  indication in the island.

- **`DeviceConnectSlotView`** — a Bluetooth audio device connecting: the device's SF Symbol in one
  sliver, a filling battery arc in the other. The third use of the same escape hatch, keyed on
  `ActivityKind.deviceConnected`.

  Two things about it are worth knowing before editing it. **Its battery arc fills where the timer's
  empties**, because a battery at 80% is 80% full and a timer at 80% has 80% left to run — the two
  rings are deliberately not one shared view. And **the device turns through a limited angle, never
  a full one**: a `rotation3DEffect` of 360° on a flat SF Symbol makes it one pixel wide at 90° and
  draws it mirrored from 90° to 270°, so the first version of this had the AirPods vanish mid-arrival
  and come back as the wrong hardware. It was caught on a screenshot, because every frame of it is
  individually plausible. It also never repeats: PERF.md's open Milestone 9.6 finding is that a small
  continuously-redrawing flank appears to cost the whole transparent panel a repaint.
- **The shelf's model and geometry** (`ShelfItem`, `ShelfContents`, `ShelfLayout`, `ShelfModel`,
  `ShelfLayerView`) — what the shelf holds, where its tiles and controls are, and what they look
  like. `ShelfContents` and `ShelfLayout` are pure values with no I/O, so capacity, duplicates,
  eviction and every hit region are testable without a drag; `ShelfLayerView` is another bespoke
  view, keyed on `ActivityKind.shelf`.

  Since 1.5.0 it is a workbench rather than a landing strip, and four more pure values carry that:
  **`ShelfSearch`** (what a query matches — substring, every token, case- and diacritic-insensitive,
  and never the path, which is not on screen and would produce hits with no visible reason),
  **`ShelfScroll`** (how far the grid is scrolled, and the one thing that differs from
  `RecentsScroll`: the shelf appends, so a drop is revealed at the *end* rather than at the top),
  **`ShelfArchive`** (what is written to `~/Library/Application Support/Isleta/shelf.json`, and the
  two rules that decide what survives a launch — a materialised file is never written down, and a
  file that is gone keeps its tile), and `ShelfLayout`'s grid, which owns both the drawn rects and
  the scrolled ones so a tile cannot be clickable a row from where it is drawn.

  **The actions menu is a second layer in the same rectangle** (`ShelfActionLayout`,
  `ShelfActionsLayerView`, `ShelfActionMenu`, `ShelfJobStatus`) — what the island can *do* with what
  it is holding. `ShelfLayout.contentHeight` is a constant because `islandPath` has to track a
  settled shape, and this layer honors that constant rather than asking for a height of its own, so
  opening the menu moves no part of the island's outline: no widen-then-tighten, no new form to
  prove, no transition at all. What changes is which of two layers is drawn inside a rectangle both
  had already agreed on, and `ShelfLayerView` draws one or the other, never both.

  Three smaller decisions go with it. The menu **scrolls** rather than growing, on its own
  `ShelfScroll` and its own target — a shared offset would put a menu of nine rows wherever the user
  had left a grid of thirty tiles. The way out sits where **Clear All** does, the trailing-most
  control on either layer, so the last thing in the strip is always the one that ends what you are
  doing. And a running job takes over the **header line**: while the island is open the flanks are
  not on screen at all, so the `fileAction` activity's progress — which lives in the trailing sliver
  of the *collapsed* island — is invisible to exactly the person who asked for the work.
  `ShelfJobStatus` is what the header says instead, in the place the item count already occupies.

  **The grid scrolls the way the recents list does, and for the same measured reason**: a `ScrollView`
  with `scrollDisabled(true)`, driven from our own offset through `.scrollPosition(_:)`. Nine other
  mechanisms were measured failing to contain scrolled content inside this hosting view. Do not try
  a tenth.

  **The search field takes the keyboard**, which is the one thing on the island that costs anything:
  it reuses `IslandPanel.acceptsKeyboardInput`, the narrow exception the reply surface bought and
  measured, rather than standing up a second key-capable window. Two mechanisms for taking the
  keyboard would be two things that can each forget to give it back.
- **The gestures** — `SwipeTracker`, `IslandStowGesture`, `IslandCloseGesture`, `SwipeOffset`. Pure
  values that take scroll samples and return verdicts, so every one is testable without a trackpad.
  They are disjoint by construction rather than by arbitration: stowing is horizontal and only on a
  *collapsed* island, closing is vertical-and-upward and only on an *open* one.
- **`DebugOverlayView`** — the ⌥⌘D overlay.
- **`IslandScreenModel`** — per-screen observable render state.

- **`ApplicationIconStore` / `ApplicationIconResolver`** — another app's icon, drawn in the island.
  Its caller today is Now Playing: a track with no cover shows the player's own icon
  (`NowPlayingSlotView.applicationIcon`), asked for only when `artwork` is nil. The general seam is
  still there — IslandActivities hands over a *name* (`ActivityContent.applicationIconName`),
  because an image in that package would need a resource bundle in the one place with no rendering
  in it; this is where the name becomes a bitmap. Asking is free and answering is not — the catalog
  scan is 29 ms and the first rasterisation 68 ms — so the whole resolve happens on a background
  queue and the icon arrives a beat after the island does, exactly as album artwork does.
  `content.symbol` is what is drawn until it lands, and what stays if the app is not on this disk.


- **`IslandListScroll`** — how far a list inside the island is scrolled. It was `RecentsScroll`,
  written for the notification list and borrowed by the drop history; the list went with
  notifications on 2026-08-28 and the borrower is now the only caller, so the type took a name with
  no subject in it. The gesture is ours, because a scroll view would never be sent an event:
  `IslandHitTestView.scrollWheel` handles scrolls and does not call `super`. It is also the only
  thing in Isleta that reads `IslandScrollSample.deltaY` rather than `upwardDeltaY` — a list obeys
  the user's natural-scrolling setting, where a gesture must not. The *drawing* is a `ScrollView`
  with `.scrollDisabled(true)`, parked at our offset with `.scrollPosition(_:)`, and it is there for
  one reason: nothing else in this hosting view clips scrolled content. See the trap in CLAUDE.md
  and `DropHistoryLayerView.viewport`.


- **`GlanceLayout`, `GlanceModel`, `GlanceLayerView`** — the day, and a meeting about to start. The
  third and fourth kinds to take the bespoke-renderer escape hatch, and both for the reason the
  shelf did: what they draw is a *list* of events with their own time column, color dot and Join
  button, and a `.meeting` is a title over a button — neither is sayable in a vocabulary of symbols
  and strings.

  The mechanism is the shelf's exactly: `CalendarSource` publishes an **empty** `expanded` slot,
  `ActivitySlotLayout.bodySlot` returns nil for one, `ActivityLayerView` therefore draws nothing in
  the body, and this view has it to itself. No overlap to arbitrate, no z-order to get right, and
  the flanks keep drawing — music beside the calendar is the pair `ActivityStack` exists to form.

  `ActivityKind.glance.sizesOpenIslandToContent` is **false**, so the obligation
  `NowPlayingExpandedLayout` carries applies here: **agree a height and hold it.**
  `IslandController.expandedContentHeight` is read *before* the transition, so every number in
  `GlanceLayout` is arithmetic on a row count that is fixed the moment the activity is published.
  `rowsHeight(inContentHeight:)` is the inverse of `contentHeight(rowCount:)` and the two are pinned
  against each other, because the way they fail on screen when they drift is a row sliced in half by
  the island's own bottom edge with every test still passing — which is exactly how the withdrawn
  `RecentsLayout` failed once already.

  **`GlanceWeatherLayout`, `GlanceWeatherLayerView`, `WeatherRangeBar`** — the page behind the
  weather chip: what the sky is doing now, four readings, and the next few days with a chance of
  precipitation against each. Reached by clicking the chip on the day, the same chip on the glance,
  or by swiping to it; left the way any page is — by turning to another one or by closing the
  island. **It has no ✕**, and that is the whole difference between a page and a drill-down: the
  button was a leftover from when the weather was a flag on `GlanceModel`, and it put the reader on
  home whether or not that is where they came from.

  It costs **no second request**. Everything on it arrived in the same `weather(for:)` the chip's
  temperature came from, so opening it is free against WeatherKit's pooled quota — which is also why
  it cannot disagree with the chip.

  `contentHeight` takes no arguments, exactly like `GlanceScheduleLayout`'s, and for the same reason:
  the island's height is agreed before the transition and `islandPath` has to track a shape that has
  settled, so a forecast row with no day is drawn **empty** rather than omitted and a refresh landing
  while the page is open cannot move the island's bottom edge under a pointer. `WeatherRangeBar` is
  the one piece of arithmetic here that can be *wrong* rather than merely ugly — a week with no
  spread is a division by zero that SwiftUI draws as no bars at all — so it is a pure function with
  its own suite.

  **Which nothing decides the words.** A refused calendar and a genuinely free afternoon return
  byte-identical results from every EventKit call there is, so the empty state's sentence comes from
  `CalendarAccess` and never from `events.isEmpty` — and the "Allow…" button appears only in
  `.notDetermined`, the one state where a prompt would actually show.

  **`GlanceScheduleLayout`, `GlanceSchedulePlan`, `GlanceScheduleLayerView`** — today and tomorrow
  behind the date: the day and everything true of all of it on the left, the hours on the right.
  Reached by clicking the date block on home or the day on the glance, and left by its **✕ Close**
  button. A drill-down over the home page rather than a page of its own, which is what decides its
  three departures from every other open island:

  - It is the one surface that asks for **width** — `GlanceScheduleLayout.bodyWidth`, 440 against
    the default 368 — because it is two lists side by side rather than a column of rows.
    `IslandLayout.expandedWidth` clamps the request so it can only ever widen the island; see that
    function for why a *narrower* one is not expressible.
  - It wears **no page indicator**. The dots say which of three pages you are on, and this is not
    one of them — a page turn is refused while it is up. `IslandScreenModel.hasPageIndicator` is the
    single property both the shape and the body's own room read, so the strip and the height
    reserved for it cannot disagree.
  - Its two days are **pulled and then forgotten** — `CalendarSource.events(on:)` twice when the
    surface opens, cleared when the island closes. §9's rule: the snapshot is pushed, a surface
    nobody has open is not kept warm, and somebody's calendar is not held in memory for it.

  **`GlanceSchedulePlan` is where the product rule lives, and it is deliberately not the view's own
  arithmetic.** Which events are dropped when two days do not fit five rows is a decision, and a
  decision inside a `ViewBuilder` is one nobody can check without a screen: today takes the rows it
  needs, tomorrow fills what is left, the heading is drawn only when something follows it, and the
  count of what neither day could show takes a row of its own — *out of* the budget, which is the
  bug its own test caught before it was ever drawn.

  **It replaced a month grid on 2026-08-28**, which is a subtraction: `GlanceMonthGrid`, the two
  arrows, day selection, `daysWithEvents` and their tests all went. Six weeks of dots answered "what
  does this month look like", which is a question people ask a wall planner; what they ask a notch
  is what is next.

- **`ApplicationIconStore`** resolves a *display name* against a catalog of 151 bundles on disk —
  the shape it was given when a notification banner carried nothing else — and caches eight. The rasterisation is
  `ApplicationIconResolver.icon(atApplicationURL:)`.

## Localization

Every word this package draws goes through **`islandText(_:_:)`** (`IslandText.swift`) — a symbolic
key, the English beside it as the `defaultValue`, resolved against `Bundle.module`. There is no
`en.lproj/Localizable.strings`: English is the Swift source. The tables are
`Sources/IslandUI/Resources/{de,fr,es}.lproj/Localizable.strings`, plus a
`Localizable.stringsdict` in each of those **and in `en.lproj`** for the six keys that are plurals —
English needs a table there because a format string cannot express a plural rule.
`LocalizationCoverageTests` fails on a key missing from a language, a stale key nothing asks for,
and two languages taking different printf arguments for one key.

**`Text("literal")` is the trap and it is why nothing here uses one.** A string literal handed to
`Text` is a `LocalizedStringKey` resolved against `Bundle.main` — the *app*, not this package — so it
would silently find nothing and draw the English forever. Everything goes through `islandText` and
reaches SwiftUI already resolved.

**The length budget is this package's whole constraint**, and it is why IslandUI has its own table
rather than sharing IslandActivities'. Measured with real SF Pro at the sizes these views use:

- **A fixed frame is the only place a translation can actually break.** `ShelfLayout.clearWidth` is a
  constant **62pt**, and "Clear All" is 46pt — but "Alle löschen", "Tout effacer" and "Borrar todo"
  are 66, 66 and 62. So the shelf's control is **"Leeren" / "Vider" / "Vaciar"** (37/29/34pt) while
  the drop history's identical English stays "Alle löschen" / "Tout effacer" / "Borrar todo",
  because that one is a capsule that grows. The full phrase survives in each one's accessibility label.
- **`IslandListFormat.age` is four keys, not `RelativeDateTimeFormatter`.** The formatter's output length
  is not ours to bound and this is drawn in a column at the trailing edge of every row. The column is
  elastic, so a long age steals from the title rather than truncating — French "à l'instant" is 49pt
  against English's 21.
- Kinds that draw their own body (`nowPlaying`, `shelf`, `glance`, the drop history, the Up Next
  surface) are `.lineLimit(1)` + `.truncationMode(.tail)` throughout, so **a long
  translation is cut off silently**. Anything added here is measured, not guessed.

Three things that were hand-rolled English rather than formatting have been fixed, and each was a bug
in any other locale: `NowPlayingRateFormat.text` used `String(format: "%g×")`, which takes no locale
and drew `1.5×` on a machine that writes `1,5`; `ShelfJobStatus.label` wrote its own `%`, where French
and German put a no-break space before the sign; and `ActivityValueFormatter.spoken` took the word
"remaining"/"elapsed" as a *suffix* parameter, which puts word order in Swift where no translator can
reach it. `ActivityValueFormatter.clock`'s `:` is deliberately **not** localized — it is universal for
a running clock — while the `h` in `1h04` is, because that one is a convention.

`ActivityKindName` exists because `ActivitySwitcherView` used to speak `chip.kind.rawValue` aloud
when a provider supplied no label: a persisted enum raw value, in English, on a German machine.

## Deliberately does not own

- **The notification surfaces, and the switcher row that reached them.** `RecentsLayout`,
  `RecentsLayerView`, `RecentsSearch`, `RecentsSwipe`, `NotificationLinkPreview`, `ReplyLayerView`,
  `QuietMenuLayout`, `QuietMenuLayerView`, `ActivitySwitcherLayout`, `ActivitySwitcherView` and
  `ActivitySwitcherLayerView` all shipped and are **withdrawn** — notifications and the app switcher
  on 2026-08-27/28, and the quiet menu with them, since what it existed to open was the notification
  list. `IslandForm` lost its `expandedWithSwitcher` shape. The way into Settings is the right-click
  menu and the menu bar item.

  **Four findings outlive them, because each is about this package rather than about
  notifications.**

  - **A control that is sometimes there is one a person cannot learn the position of.** The switcher
    row was the pointer's to reveal until 2026-08-27, and the reveal lost the argument to a row that
    is simply worn for as long as the island is open. Any later hover-revealed control in the island
    has to answer this first.
  - **A list that resizes per keystroke is unusable on a spring.** A searching list was pinned to a
    fixed five rows, because the ordinary size-to-contents rule took the island through a new height
    per keystroke with the field the user was typing into moving under the caret each time.
  - **`IslandPanel.acceptsKeyboardInput` has exactly one *mechanism*, not one caller.**
    `ReplyLayerView` bought the exception and `ShelfLayerView` reuses it; the rule that mattered is
    that a third mechanism for taking the keyboard is a third thing that can forget to give it back.
    The shelf's search field is the flagged exception that remains.
  - **Nothing is fetched on the render path.** `NotificationLinkPreview` showed a link's address and
    never loaded the page: a request per row would be a DNS lookup on the frame the island arrives
    (§9 budgets it at 16 ms) and would hand the sender's server a read receipt the user never agreed
    to. Hand-written rather than `NSDataDetector`, which is not `Sendable`, is expensive to construct
    per row on a lazy stack's build path, and detects bare domains and dates — so "see you at 3 on
    Tuesday" would acquire a chip.

- **Haptics on the lock screen.** The card and the padlock buzzed on every crossing and on both
  press edges until 2026-08-28 — `updatePointer` and `updateCardPress` answered *which* region had
  been entered, and `LockScreenHover` existed to carry that answer to the tick. All three are gone.
  §7's vocabulary is the island's, where the surface moves under a pointer that arrived without
  being asked; a locked screen is a person looking straight at the button they are pointing at, and
  the lit wash already says it is live. Three buzzes for one glance at a track title is the feature
  announcing itself.

  **What the removal cost, so nobody re-derives it:** the *edge* in `updateCardPress` is load-bearing
  and stayed — acting on the state would send a skip thirty times a second for as long as somebody
  leaned on the trackpad — and that it sends exactly one command per press is asserted through what
  the player receives rather than through a return value. `updatePointer`'s edge was not
  load-bearing: what the surface draws is a function of where the pointer is now, so the three
  assignments are all that is left of it. Haptics remain everywhere else, including
  `NowPlayingViews`' own arrival tick on the open island.

- **Windows.** No `NSPanel`, no hit testing, no screen enumeration. `IslandBlurRootView` is the near
  miss and stays on the right side of the line: it draws an `NSVisualEffectView`, and the window that
  view goes into — `IslandBlurPanel`, which takes no clicks — is IslandKit's. Both windows are driven
  from the same `IslandScreenModel`, so the island and its blur cannot disagree about how open the
  island is. The one `NSView` in this package that owns a display link
  (`ActivityClock.DisplayLinkView`) is zero-sized, draws nothing, and exists solely because a
  `CADisplayLink` has to come from a view that is in a window.
- **Its own geometry.** `IslandShape` delegates to `IslandShapeGeometry`; if it computed a path of
  its own, the visible shape and the clickable region would drift the moment either changed.
  `ActivitySlotLayout` is not an exception — it subdivides a body it is handed, and never decides
  how big that body is. `ActivityExpandedHeight` is the near miss: it says how much *drawable* room
  a content needs, and `IslandLayout` turns that into a body — adding the cutout, applying the
  clamps. So the island's size is still decided in one place, by the package that also answers for
  the clickable one.
- **Where the day comes from.** `GlanceModel` holds a `GlanceSnapshot` and knows nothing about
  EventKit, WeatherKit or CoreLocation — IslandUI links none of them, which is what keeps §3's
  layering test true: everything here builds and previews with no permission granted. The app shell
  pushes values in and supplies `onJoin`, because opening a URL is `NSWorkspace`'s and this package
  has no business reaching for it.
- **What the island says.** IslandActivities decides which activity is presented and what it has to
  say; this package decides only what that looks like. There is no `AnyView` path through
  IslandActivities and there must never be one.
- **Data sources.** No provider, no permission, no I/O. The shelf is the case that tests this:
  `ShelfItem` describes a file and never opens one, and everything that touches the pasteboard, a
  bookmark or a file promise is in the app shell's `ShelfStore`. `NowPlayingController` is not an
  exception either: it holds the transport's *closures*, not the transport. The app shell
  (`NowPlayingBridge`) is the only thing that sees both this package and IslandSources, and
  translating a button press into an `MRCommand` id happens there.
- **Deciding a control's availability.** `canSkip` and `isTransportAvailable` are pushed in from the
  source's own report (`prohibitsSkip`, whether the adapter is vendored). This package draws a
  disabled button; it never infers that one should be.
- **The user's island size.** the compact island, the two collapsed-body adjustments and the peek amount are
  `IslandSizing` in IslandKit, and they reach this package only as an already-resolved
  `metricsByForm`. One file here would break if that changed: `NowPlayingExpandedLayout`'s transport
  arithmetic is written against `IslandLayout.expandedBodySize.width` as a *constant* rather than
  against the body it is handed — which is exactly why the open island's width is not adjustable, and
  `CompactIslandTests` is where a later change finds that out.
- **A permanently visible player.** The player bar is withdrawn — a slim always-there Now Playing
  window for the displays the island is not the answer on. What it measured outlives it: a
  permanently visible window *can* hold §9 (no clock anywhere, the equalizer driven by `CALayer`
  rather than a `Canvas`), and it was **not** in the private overlay space, so a desktop slide
  carried it across with the desktop rather than leaving it pinned. Its other finding was a
  localization one: a 154pt text column had no slack in any language, and "Now Playing is
  unavailable" was already 149pt in English against 159 (de), 167 (fr) and 165 (es) — every
  translation truncated even after each was cut to the shortest wording that still said the feature
  was unavailable rather than that playback had failed. The lock-screen card is the surface that
  remains, and it is transient by construction.
- **Sizing the island from its content.** `IslandLayout.expandedBodySize` and the flanked sizes are
  constants, and content that does not fit is truncated rather than allowed to grow the island.
  Whether an activity has *any* flank content selects between two constant shapes; how much it has
  never changes either of them. Hit testing tracks the *animated* shape, and a container whose size
  depended on its content would have to be resolved before the path could be built.

## The layering test

Everything here must build and preview with no permission granted, on any Mac, with no external
process running. That is the check that the split in §3 is honest rather than decorative — if a
view ever needs a permission to render, the abstraction has leaked.

## Nothing new may redraw per frame

Measured 2026-08-23, and it is the rule that governs every view added to this package. Per-frame
drawing from this process through SwiftUI's `Canvas`/`TimelineView` costs **17.7% of a core and
279MB**, and it is **not** a function of how big the drawing or its panel is — a 40×32pt panel
measured 17.83% against a 608×200pt panel's 17.72%, with the same 279MB. `.drawingGroup()` changes
neither. The same six bars drawn as `CALayer`s with a `CABasicAnimation`, animated by the render
server, measured **0.007–0.010% and 14.6MB**.

So: do not conclude a small animated element is safe, and do not try to make one cheap by making it
smaller — that lever does not exist. Anything that has to move continuously is CoreAnimation on the
render server, not a SwiftUI redraw. Every material in `IslandMaterialView` is static for exactly
this reason, and `AlbumColor` is read once per track change rather than sampled.

**The equalizer is the worked example, and it landed 2026-08-23.** Same session, same machine, paired
against a static control both times: the `Canvas` version measured **4.79 % and 286.7 MB** against a
control of 0.073 % and 25.3 MB; the `CALayer` version measures **0.11–0.29 % and 22.6 MB** against a
control of 0.031–0.116 % and 22.7 MB. The memory difference is the unambiguous half — a playing track
used to cost §9's whole 60 MB budget four and a half times over and now costs the same as an island
with nothing on it. The CPU figures here are lower than PERF.md's 17.7 % for the reason recorded
there: the cost tracks the display's *actual* refresh rate, so only the paired delta means anything,
and that went from **+4.72 pp** to **+0.04–0.22 pp**.

## What is drawable, and when

On a Mac with a real notch the island body is not all screen: the cutout is a hole with no pixels
in it. The drawable area is the body **minus** the cutout, which makes `leading` and `trailing` the
two slivers of lit pixels either side of the hole and puts `expanded` underneath it.

| Form (14" MacBook Pro) | body | flank each side | below the cutout | drawn |
|---|---|---|---|---|
| rest | 185×32 | 0 | 0 | nothing |
| peek | 197×40 | 6 | 8 | nothing |
| flanked rest | 265×32 | 40 | 0 | `leading`, `trailing` |
| flanked peek | 277×40 | 46 | 8 | `leading`, `trailing` |
| flanked peek + lip | 277×80 | 46 | 48 | `leading`, `trailing`, the track lip |
| **wide flanked rest** | **401×32** | **108** | **0** | `leading`, `trailing` |
| **wide flanked peek** | **413×40** | **114** | **8** | `leading`, `trailing` |
| expanded | 380×140 | 97.5 | 108 | `leading`, `trailing`, `expanded` |

**With nothing on stage the island is exactly the cutout, so nothing can be drawn in it at all.**
That is the same fact as "the island is invisible at rest", seen from the content's side. The
*flanked* rows are the answer to it: when the presented activity has something to say in a flank,
`IslandLayout.flankedWidthGrowth` widens the resting body by a constant 80pt, buying two 40pt
slivers of real screen — so a track change is visible with no click. Flanked-ness is an input to
`IslandForm`, resolved alongside hovering and expansion and never stored; the flanked sizes are
constants, because `islandPath` has to track a settled shape for hit testing to stay exact.

**The *wide* and *wider* rows are the same idea for an activity that says what it is in words.** A
volume key and a brightness key draw the same picture in a 40pt sliver — a small glyph and a bar —
so `ActivityKind.flankSpan` puts the system HUDs on `IslandFlanks.wide` instead, and
`IslandLayout.wideFlankedWidthGrowth` buys 108pt each side: enough for the glyph, 4pt of spacing and
the word, at the longest label the shipped languages produce (German's "Lautstärke", 61.4pt in real
SF Pro at 12pt medium). Power is on `.wider` — 137pt each side, `widerFlankedWidthGrowth` — because
its labels are phrases rather than nouns ("On Battery", "Sparmodus aus", 89.8pt) and its battery
glyph is 23pt against a HUD's widest 20. Still constants, still not sizing from content — four
shapes on the flank axis, not a continuum. Both are deliberately wider than the *open* island, which
is argued at those two constants and paid for by the kinds expiring in 1.5 and 5 seconds; nothing
ambient may ask for either span, and a sliver drawing no word asks for no room for one.

`compact` is the badge for an island with nothing to flank — a synthesized island on a notchless
display, where the whole body is real.

**The lip row is the one collapsed state with a body region**, and it exists only while the pointer
is on the album cover (`IslandForm.showsTrackLip`). What is drawn there is `NowPlayingTrackLipView` —
the title and the artist — and `ActivityLayerView` gives the region up for it, because `bodySlot`
would otherwise answer `.compact` and draw the activity's badge in the same rectangle. It does not
contradict `flankedHeightGrowth` being zero: that rule is about a strip hanging under the notch *at
rest*, and this one is under the pointer and gone when the pointer is.

## The swipe (§5)

`SwipeTracker` turns `IslandScrollSample`s into one of four outcomes — ignore, track, commit, settle
— and `IslandSwipeModel` applies them. It is a pure value type with no clock and no AppKit, so
rubber-banding and momentum are pinned by synchronous tests rather than judged by feel on hardware.

- **Rubber-banding** is one asymptotic curve used twice. A swipe that has somewhere to go follows
  the finger 1:1 and saturates at `SwipeMetrics.travel`; one that does not is damped from the first
  millimetre and saturates at `resistance`, a quarter of the distance. Asymptotic rather than
  clamped: a clamp has a corner in it, and a corner reads as the app having lost the gesture.
- **Momentum** is read at the moment the fingers lift, out of the velocity accumulated up to that
  point, and the glide that follows is deliberately ignored — accumulating it would put the content
  back out under a spring already on its way home.
- **No fifth motion token, and none was needed.** A rejected swipe releases on `Motion.nudge` ("an
  attention nudge that does not change state" is a description of a rubber-band release), a
  committed one settles on `Motion.contentSwap` while `ActivityChange.swapped` morphs the container
  on `Motion.expand` — §6.2's container-leads-content, with the offset as content. Tracking the
  finger is not animated at all.
- **Reduce motion keeps the gesture and drops the drag.** Same thresholds, same cycling, but nothing
  follows the finger and nothing springs back — and a rejected swipe becomes silence rather than a
  transaction animating zero to zero.

The offset is applied **inside** `IslandRootView`'s mask, which is why a swipe costs nothing in hit
testing: the content slides under a stationary island outline, so the panel's alpha, the window
server's event shape and `islandPath` are all exactly as they were. That is also why the offset is
its own object rather than a property on `IslandScreenModel` — everything on that model is an input
to the island's *shape*, and this deliberately is not.
