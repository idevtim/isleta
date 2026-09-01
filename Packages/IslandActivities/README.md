# IslandActivities

What the island has to say, and which one thing it says at a time.

The activity model of §8.3, because ActivityKit does not exist on macOS and there is no
Apple-blessed way for a third party to receive another app's Live Activities (§2.2).

## Owns

- **`IslandActivity`** — the protocol: `ActivityID`, `ActivityKind`, `ActivityPriority`,
  `ActivityExpiry`, and the four presentations (`leading`, `trailing`, `compact`, `expanded`).
- **`ActivityContent` / `ActivityPresentations`** — what an activity has to say in each slot, as
  data: an SF Symbol name, strings, an `ActivityValue`, and a semantic `ActivityTint`.
- **`ActivityTimeline`** — where a player is in a track, as an *anchor* rather than a sample: the
  position, the instant it was true, the duration and the rate. That shape is §9 expressed as a
  type. A stored `elapsedTime` is wrong the moment after it is taken and the only way to keep it
  right is to re-ask, which is the poll the idle path may not have; a timeline published once is
  still exact an hour later. It also expresses "paused" with no special case at all — `rate` is
  zero, so the position never moves, so nothing downstream has any reason to redraw.
- **`ActivityStack`** — a pure value type holding the whole model: ordering, preemption, ties,
  queue drain, and expiry. No clock, no concurrency, no isolation. Every policy question about the
  island's content is answerable by a synchronous test here.
- **`ActivityStage` / `ActivityFlank`** — the pair the island draws at rest: a `primary` that owns
  the body and one sliver, and an optional `companion` that owns the other. Derived from the stack's
  order on demand, never stored, for the same reason `presented` is.
- **`IslandSides`** — the user's answer to *which side of the notch, and which way round*: a per-kind
  override of `flankAffinity`, and a mirror that swaps the two flank contents of every activity at
  once. A record here rather than in IslandSettings because `ActivityStage` is what reads it, and
  this package cannot see that one. Held on `ActivityStack` for `dwellScale`'s reason and no other.
- **`ActivityChip`** — one activity reduced to a glyph and a short value. No title: a chip says
  *which* activity, not what it says.
- **`ActivityCoordinator`** — the thin shell around one stack: supplies `now`, keeps the single
  scheduled sleep in step with the earliest deadline, and publishes `ActivityChange`.
- **`ActivityKind` and `BuiltInActivity`** — the closed vocabulary, **fourteen kinds**:
  `nowPlaying`, `systemHUD`, `welcomeBack`, `shelf`, `timer`, `deviceConnected`, `glance`,
  `calendarAlert`, `meeting`, `power`, `call`, `fileAction`, `focusChanged` and `screenSharing`,
  each with the priority and expiry its job implies. Closed on purpose: an open `String` kind, or
  a `case custom(String)`, would let a caller invent a kind the stage has no rule for.

Per §8.3 the coordinator was written with its unit tests **before** any provider. It is the piece
that accumulates subtle bugs, and it is testable in complete isolation from every permission.

- **The glance vocabulary** — `GlanceEvent`, `GlanceCalendar`, `GlanceTint`, `GlanceSnapshot`,
  `CalendarAccess`, `LocationAccess`, `WeatherReading`, `WeatherDay`, `TemperatureUnit`,
  `CitySuggestion`, and the pure policies `GlancePolicy`, `WeatherPolicy`, `CityQuery` and
  `MeetingLinkParser`. Here rather than in IslandSources for the reason
  `BluetoothDevice` is: IslandUI draws these and IslandSources produces them, and the only package
  both depend on is this one. Putting them beside the producer would mean IslandUI linking EventKit,
  WeatherKit, CoreLocation and MapKit — which is §3's layering test failing in one edit.

  `CitySuggestion` and `CityQuery` are the newest instance of exactly that argument: the city
  completions are produced by MapKit in IslandSources and drawn by IslandSettings, which may not
  import it. `WeatherPolicy.forecastDays` is here for the second half of the same rule — a cap the
  provider fetches to and the layout draws to has to be **one** number, or the day they disagree is
  the day a day of the forecast goes missing with nothing to say which.

  Everything here is pure, and the two policies are where the decisions live:
  `GlancePolicy.nextBoundary` is what lets `CalendarSource` own **one** timer instead of a minute
  poll, and `MeetingLinkParser` is the piece with the most test value in the whole feature — 30 of
  33 real events carried their join link in `notes`, none in `location`, and one Teams host that
  matches every naive rule opens a page of phone numbers. All of it is checkable with no calendar,
  no permission and no running app.

- **The drop-action vocabulary** — `DropAction`, `DropActionItem`, `FileConversion`,
  `ConversionRoute`, `ConversionTarget`, `ConversionOffer`, `ConversionProgressClass`,
  `FileActionJob` and `BuiltInActivity.fileAction`. Here for the reason the glance vocabulary is:
  IslandUI draws the menu and IslandSources performs the work, and the only package both depend on
  is this one. Putting it beside the worker would mean IslandUI linking AVFoundation, ImageIO and
  Speech, which is §3's layering test failing in one edit.

  All of it is pure, and three decisions live in it rather than in the code that acts on them:

  - **`FileConversion.offers(forPathExtension:)` is a list of measured conversions**, not a
    `UTType.conforms(to:)` rule. `ShelfItem.symbolName` asks `UTType` and says why — an extension
    table misses the next format Apple ships — and that argument is right for a *glyph*, which is a
    guess about what a file is, and wrong for this, which is a promise about what Isleta can do to
    it. Every entry was measured on a real file; a conformance rule would offer HEIC → JPEG for a
    RAW nobody has tried. **MP3 is absent from every list**, because macOS decodes it and will not
    encode it at any layer, and `AVAssetWriter(fileType: .mp3)` raises an *uncatchable* exception
    rather than returning an error. A test pins that.
  - **`DropAction.menu(for:)` takes the intersection, not the union.** "Convert to JPEG" over a PNG
    and a spreadsheet cannot mean anything, and offering it would either convert one file and skip
    the other or fail halfway with two files in two states.
  - **`ConversionProgressClass` decides which work gets an island at all.** Under 100 ms draws
    nothing (a flicker), 100–500 ms draws nothing (the tile arriving is already longer than the
    work), and seconds gets a `fileAction` activity with a fraction in it. Where a route's measured
    time straddles a boundary the slower class wins, because an announced job that finishes early is
    an island that was quick while an unannounced one that takes two and a half seconds is an island
    that has hung.

  `FileActionJob` carries **no `URL` and no field that could hold a name**, on purpose: the activity
  built from it ends up in a log line and on a screen somebody might be sharing, and a count with
  the menu's own words is all the island ever needs to say.

- **`WeatherFormat` and `GlanceFormat`** — plain `enum`s, not `static func`s on a view. A formatter
  declared on a `View` is `@MainActor` by inheritance, and the first nonisolated test to call one
  takes the whole bundle down with a signal *after* every other suite has reported passing.

## Deliberately does not own

- **Notifications, and everything that hung off them.** `ActivityKind.notification`,
  `NotificationRecents` (the bounded ring of the last fifty, with search), `NotificationPreferences`
  and `NotificationAppKey` all shipped here and are **withdrawn (2026-08-28)**, with the source and
  the UI that used them. The vocabulary case went with the feature, which is the point of the
  vocabulary being closed: there is no `.notification` for a later caller to publish into and no
  stage rule left describing one.

  **Two decisions outlive the code, because they are about this package rather than about
  notifications.** A record of what has arrived is *not* the stack with longer expiries — it is a
  different structure with a different lifetime, and nothing in it is ever re-presented; that
  distinction is why `ActivityStack` stayed pure. And a ring holding other people's messages was
  deliberately not `Codable`, reported counts rather than contents from its `description`, and was
  never logged — the shape any future in-memory record of private content has to take.

- **The switcher row.** `ActivityChip` was built for it and outlived it: a chip is still one
  activity reduced to a glyph and a short value, and the stage uses it. The switcher itself is
  withdrawn.

- **Where activity data comes from.** That is IslandSources. Nothing here does I/O, spawns a
  process, or asks for a permission.
- **How an activity looks.** No SwiftUI, no AppKit, no `Color`, no fonts, no layout — see below.
- **Any import of ActivityKit, ever.** It is iOS/iPadOS only (§2.2).
- **EventKit, WeatherKit, CoreLocation or MapKit.** The glance vocabulary above is flattened *out*
  of those by IslandSources and handed here as values. `GlanceEvent` exists precisely because every
  `EKEvent` a process holds is invalid the moment `.EKEventStoreChanged` arrives, and `GlanceTint`
  exists because a `CGColor` could not cross into a `Sendable` value.
- **When the island grows.** `IslandPresentation` and `IslandLayout` decide that; an activity only
  says what belongs in each state.

## Presentations are data, not views

The four presentations return `ActivityContent`, not `some View`. This is the one place the
original sketch said "the views are supplied by conformers", and it is worth writing down why it
went the other way:

- **The layering test for this package** is IslandUI's, one level stricter: everything here must
  build and be *exercised* with no window, no permission, no main thread and no running app. A
  view-producing requirement drags SwiftUI, and through it AppKit, into the module whose whole value
  is that it needs neither.
- **`ActivityChange.contentChanged` is a comparison of two presentations.** §6.2 crossfades content
  on `Motion.contentSwap` while morphing the container on `Motion.expand`; telling those apart means
  asking "is this the same activity with new content?", which is `Equatable` on the presentations.
  Views are not `Equatable`, so the coordinator would have to be told the answer by every provider,
  and the first one to get it wrong makes a track change look like the island reopening.
- **Sources run off the main actor.** A media adapter and an AX observer produce these on their own
  threads; `Sendable` value types cross for free, `View`s do not.

The cost is that an activity cannot draw something the vocabulary has no word for. That is the
intended trade for now: the built-in kinds cover Milestones 3 and 5–8. If a later activity
needs a bespoke view, it belongs in IslandUI keyed on `ActivityKind`, not as an `AnyView` smuggled
through this package.

**That escape hatch has now been used three times** — by `nowPlaying`, `timer` and
`deviceConnected` — and each time for the same reason: what the kind draws is not sayable in a
vocabulary of symbols and strings. One word was added to that vocabulary rather than around it:
`ActivityContent.applicationIconName` is the *name* of an installed app, which IslandUI may resolve
to its icon and draw in place of `symbol` — a name, like `symbol` is a name, so this package still
holds no pixels and an activity still cannot smuggle a view through the model layer.

Album artwork is an image and the equalizer is continuous motion;
a countdown is a shrinking arc that the generic renderer would draw as a scrub bar; a connected
device is a picture of hardware and a filling arc beside it. `NowPlayingSlotView`, `TimerSlotView`
and `DeviceConnectSlotView` live in IslandUI, are selected on `ActivityKind` **per slot** rather
than per island, and fall back to `ActivityContentView` for every slot they have no bespoke
treatment for.

Note what did *not* move in any of the three: the title, the subtitle, the playhead and the battery
fraction are still ordinary `ActivityContent`, which is why `ActivitySlotLayout` still decides where
they go and `ActivitySlotLayout.needsClock` still decides whether anything redraws — with no case
for music, timers or Bluetooth in either. Only the drawing is bespoke. `deviceConnected` is the
clearest demonstration: its battery is a `.fraction`, which is not time-dependent, so a connected
device runs no display link for the whole four seconds it is on stage, and nothing in the layout had
to be told that.

## The coordinator is `@MainActor`, not an actor

Also a deviation, also deliberate, and argued at length in `ActivityCoordinator`'s own doc comment.
The short version: everything downstream is main-actor UI reading the presented activity from
inside a SwiftUI `body`, an `actor` makes that read an `await` and therefore a mirrored copy, and a
mirrored copy is a second source of truth for what is on the island. §6.2's 40ms container-leads-
content window has no room for an actor hop either. The stack holds single digits of entries; there
is nothing here worth protecting with isolation that main-actor isolation does not already protect.

## Expiry: one sleep, and none when idle

§9 forbids polling. Expiry is therefore split in two:

- `ActivityStack` is pure. `removeExpired(at:)` takes the instant; `nextExpiry` is the earliest
  deadline on the whole stack, or `nil`.
- `ActivityCoordinator` holds **at most one** `Task` sleeping to that deadline, and **none at all**
  when `nextExpiry` is `nil` — an empty stack, or one holding only `.never` activities, costs
  nothing. An update that does not move the earliest deadline reuses the existing sleep rather than
  tearing it down and rebuilding it, which matters because Now Playing updates on every scrub.

Three consequences worth knowing:

- **Queued activities expire on the same clock as the presented one.** An expiry says when the
  information goes stale, not how much screen time the island owes it.
- **Re-presenting an id keeps its place in the queue but restarts a relative expiry.** Pressing the
  volume key again buys another dwell; a Now Playing update does not jump the queue.
- **Nothing expires out from under the pointer.** While `isPointerOverIsland` is set, whatever is on
  stage keeps its place past its deadline and its deadline leaves the schedule; the queue behind it
  is untouched, and the pointer leaving sweeps. See `docs/MOTION-AND-INTERACTION.md` for why the
  held deadline may not be scheduled against.

## The stage is a pair, and the unpaired case is the old behavior

A single stage forces a choice nobody wants: a running timer that outranks Now Playing takes the
music off the island for its whole run, and one that does not is invisible for its whole run. No
priority rule fixes that, because the user wants both — and the resting island already has two lit
slivers to put them in.

- **`ActivityStage.primary` is the head of the order**, unchanged. It owns the body in every
  presentation, and the flank its kind prefers (`ActivityKind.flankAffinity`).
- **`companion` owns the other flank and nothing else.** Always `primaryFlank.opposite`, because
  there are only two — which is what makes the rule one line instead of a table.
- **With no companion the primary owns both flanks**, exactly as every build before the pair. That
  is not a compatibility shim; it is what `content(on:)` computes when there is nobody to give the
  other flank to. It is also the common case, so getting it wrong would be a regression in the state
  users spend the most time in.
- **The affinity table is what makes the pair symmetric.** The primary takes the side its kind asked
  for and the companion takes the only side left, so a kind sits on the same side whichever of the
  two owns the body. A rule written as "the companion goes trailing" would move the music to the
  right the moment a user brought the timer to the stage.
- **`ActivityStage.flanks` is how wide the slivers have to be**, asked of the pair because the island
  is one shape and the two slivers can belong to different activities. `ActivityKind.flankSpan` says
  what a kind needs — `.standard` for a glyph, `.wide` for a HUD's noun, `.wider` for power's phrase
  — and the stage asks it **per flank, and only where that flank's content carries a word**. A kind
  spells itself in one of its two contents, and a pair hands it one sliver that is not always that
  one: power behind a ringing call draws the level, and widening the island by 274pt for a bar is it
  growing to its widest to say nothing.
- **Power takes `.leading`, and that is why.** It was `.trailing` — its content was a percentage,
  which is the timer's case — until its leading sliver learned to say "Charging" on 2026-09-01. It
  outranks Now Playing, so the pair it makes is the common one, and the word is the half of it that
  is not already in the menu bar and on the open island. `BuiltInActivityTests` pins the rule the
  set it left still follows.
- **And the table is now a default rather than the answer.** `ActivityStack.stage` asks
  `IslandSides.side(for:)`, which returns the user's choice where they have made one and
  `flankAffinity` where they have not. The distinction between those two is stored: `IslandSides`
  keeps an entry only for a kind somebody actually decided about, so an install that has never
  opened the pane follows the built-in table as it changes in a later build rather than freezing
  today's version of it into a settings file. That is the whole reason `isDefault(for:)` exists.
- **The mirror is applied at the read, never to an activity's presentations.** `content(on:)` asks
  the owning activity for its *opposite* presentation when `IslandSides.mirrored` is set. Rewriting
  what a source published would make `leading` and `trailing` mean something different depending on
  a preference, in a package whose sources run off the main actor and know nothing about settings.
  Reading the other one is one line, and it is the same line for the paired and the unpaired case —
  which is what makes the mirror mean one thing: the value ends up left of the notch and the glyph
  right of it, whether the two came from one activity or two. **`companion(for:on:)` applies it
  too**, or a companion is admitted on the strength of content the mirrored island never reads and
  the pair forms around an empty sliver.
- **`maySharePair` is asked of both halves**, off the instance rather than the kind: not
  `.interrupting`, and `.never` expiry. A HUD must take the whole stage — its glyph and its level
  *are* the two flanks, so handing one away leaves a speaker icon next to nothing — and anything
  with a deadline is asking to be read, which a 40pt sliver is not where.
- **`hasFlankContent` is the union.** Asked of the primary alone, an island whose primary has empty
  flanks narrows back to the bare cutout while the companion still has something to say, and the
  companion is drawn into a sliver that no longer exists.
- **A companion change is its own `ActivityChange`.** `StageSignature` compares the body first and
  the companion only when the body held still, so a companion arriving reports `.companionChanged`
  rather than `.swapped` — which would morph the whole island on `Motion.expand` for something
  confined to one sliver. It maps to `Motion.contentSwap`: the flank crossfades, the outline does
  not move. And because a body change already redraws the companion with everything else, the flank
  case is never reported alongside one — which is what lets `ActivityChange` stay a single value
  instead of becoming a pair of them.

## Pinning: the swipe, and the second deadline

Swiping across the island pins one `ActivityID` to the head of the order (§5). The pin is an
**input to the ordering**, in the same sense `isFlanked` and `isHovering` are inputs elsewhere —
`presented` is still defined as the head of the order, and there is still no stored "currently
presented" field. What the pin changes is what sorts to the head.

- **It outranks priority, not merely peers.** The case a swipe exists for is reaching past whatever
  has just arrived to get back to your music; a pin that only broke ties would leave the arrival on
  stage and the swipe would visibly do nothing.
- **An interrupting activity that arrived *after* the swipe still preempts it.** Both dates are
  already on the stack (`ActivityEntry.insertedAt`, `ActivityPin.placedAt`), so this needs nothing
  stored. Pressing the volume key is always visible; a HUD the user swiped *past* stays passed.
- **It lapses by itself after `ActivityStack.defaultPinHold`**, measured from the last interaction
  rather than from the swipe — `refreshPin(at:)` is what hovering, clicking and swiping again call.
- **It never resurrects an activity.** `pin(_:at:)` records nothing for an id that is not on the
  stack, and `removeExpired` retires a pin whose activity has just gone.
- **Cycling walks `cycleOrder`** — the order the stack would have had if nobody had swiped — and
  does not wrap, because §5's resistance needs an end to resist at.

**It adds no timer.** `nextDeadline` is the `min` of the earliest activity expiry and the pin's
lapse, so the pin reaches `ActivityCoordinator.rescheduleExpiry` as a date like any other and the
coordinator still holds at most one `Task`, and none at all when nothing can expire and nothing is
pinned. `noteInteraction()` on an unpinned stack writes nothing and schedules nothing, which is what
lets the app shell call it from every hover and every click.

## Localization

Every string this package puts in front of a person goes through `activityText(_:_:)` — a stable
symbolic key and the English beside it, resolved against `Bundle.module`. `ActivityText.swift` is
where the shape and its reasoning live; `LocalizationCoverageTests` is what notices a key with no
translation, a translation nothing asks for, and two languages taking different printf arguments.

**52 keys, in `Sources/IslandActivities/Resources/<lang>.lproj/Localizable.strings`** for `de`, `fr`
and `es`. English has no `.strings` table — it is each call site's second argument — but it *does*
have a `Localizable.stringsdict`, because a format string cannot express a plural rule and there is
nowhere else for one to live.

The surfaces covered: the system-HUD accessibility labels, Now Playing's two joining
separators, the connected-device labels, the timer's three states,
the shelf, the conversion menu's verbs, "Join <provider>", the glance's five empty states and its
time formatting, the four drop-action titles, the file-action job labels, and the weather formatting.

### Two counted strings, and the `== 1` branches they replaced

`shelf.itemCount` and `fileAction.fileCount` are `Localizable.stringsdict` entries in all four
languages. The Swift-side `count == 1 ? "1 item" : "\(n) items"` is gone in both places: leaving it
would be two plural rules free to disagree, and one of the three rules that matter here cannot be
written as a ternary at all. German and Spanish count like English. **French counts 0 as singular** —
"0 élément" — so its `one` string carries `%lld` rather than a literal 1.

### What is deliberately *not* localized here

- **`ConversionTarget.name`, including `"Text"`.** The shared spec calls "Text" a word rather than a
  format and asks for it to be translated. It is not, and the reason is in the file: `name` is
  inside `ConversionTarget.id` → `ConversionOffer.id` → `DropHistoryEntry.offerID`, which is
  **persisted** and matched back against a freshly rebuilt catalog by
  `DropHistoryController.action(rebuilding:)`. A locale-dependent name would make every history row
  minted before a language change stop matching, and its "Run again" button silently do nothing.
  Nothing is lost: the only route targeting it is `.transcribe`, whose row says "Transcribe" and
  never interpolates a target name. The acronyms (JPEG, PDF, HEIC…) stay verbatim for the ordinary
  reason.
- **`DropAction.airDrop`'s title.** "AirDrop" is Apple's own name for the feature in German, French
  and Spanish alike, as are Finder, Dock and Spotlight — so "Reveal in Finder" is *Mostrar en el
  Finder*, not a translated Finder.
- **`ActivityKind` / `ConversionRoute` raw values, SF Symbol names, `MeetingProvider.displayName`,
  and every `IslandLog` line.** Persisted, matched on, or read by whoever is debugging.

### The captions that were hard

- **`glance.empty.notDetermined`** — "Isleta hasn't asked for your calendar yet" argues two things at
  once: nothing is broken, and *Isleta* has not asked, so the user has not refused. All three
  translations keep both halves, and all three keep the agent as Isleta rather than as a passive
  ("todavía no te ha pedido", "hat noch nicht … gefragt", "n'a pas encore demandé"). German and
  Spanish use the familiar form (`du`, `tú`) per Apple's own macOS; French uses `vous`.
- **`convert.to`** — "Convert to JPEG" is a menu row inside the 368pt island body. German's natural
  "In JPEG konvertieren" is a third longer than the English, so it ships as "Umwandeln in %@", which
  is the same length as the English and is still Apple's verb for the operation. Spanish "Convertir
  a %@" needs no such care.
- **`nowPlaying.a11ySeparator`** — English " by ", spoken only. All three languages have an exact
  preposition (" von ", " par ", " de "), so this one turned out easy once Chinese left the set; the
  Chinese answer had to be a full-width comma because no Chinese preposition covers both a singer
  and a podcast host.

### `weather.temperature.range` is the widest string here, and nothing truncates it — yet

Measured on this machine with real SF Pro Rounded at 12pt medium with monospaced digits, which is the
weather chip's own font and the only font any weather text is drawn in today:

| | one digit | two digits | vs. English |
|---|---|---|---|
| en `H:8°  L:1°` | 56.35pt | 72.30pt | — |
| de `H:8°  T:1°` | 57.04pt | 72.99pt | **+0.69pt** |
| fr `Max 8°  Min 1°` | 83.47pt | 99.42pt | **+27.12pt (+48%)** |
| es `Máx 8°  Mín 1°` | 83.47pt | 99.42pt | **+27.12pt (+48%)** |

Two things worth writing down. **Spanish and French are the same width to the hundredth of a point** —
the acute accents on `á`/`í` sit above the glyph and add no advance in SF Pro, so "Máx"/"Mín" costs
exactly what "Max"/"Min" costs. Anyone reasoning about this from character counts will predict
Spanish to be the wider of the two and be wrong. And **`WeatherFormat.range` is not rendered
anywhere**: the glance header draws `compact` ("8°") and speaks `full` ("4 °C"), and `range` has no
call site outside its own test. So the +48% overruns nothing today.

Where it would matter, if it is ever drawn: the glance's content width is 368 − 2 × 18 = **332pt**,
and the header strip currently spends about 30pt of it, so 83.47pt beside even "Aujourd’hui"
(62.92pt) comes to 154pt and fits with room over. What it must **not** go in is
`GlanceLayout.timeColumnWidth`, which is a fixed **58pt** — English at 56.35pt only just clears it and
both Romance languages would be cut mid-word. The translations are not the constraint; the column
would be.

### Proving the tables reach the running app

`LocalizationCoverageTests` reads the source tree and the `.lproj` folders and deliberately does not
check that CFBundle picks the right one — it cannot, from a `swift test` process with no main bundle.
What *was* measured here, by loading each `.lproj` as a `Bundle` directly: all three tables parse,
both plurals expand from `Localizable.stringsdict`, and `%%` survives into a literal `%`.

Two things about the bundle to know before adding a locale. **SwiftPM lowercases the directory on the
way in** — this package briefly shipped Simplified Chinese, and `zh-Hans.lproj` in the source tree
arrived as `zh-hans.lproj` in `IslandActivities_IslandActivities.bundle`. It is harmless
(`Bundle.preferredLocalizations(from:forPreferences: ["zh-Hans"])` answers `["zh-hans"]`) and it is
why a probe that looks a folder up by its source-tree spelling finds nothing. And **SwiftPM does not
prune a resource you deleted**: after `zh-Hans.lproj` was removed from the source tree,
`Bundle.module.localizations` went on reporting it until `swift package clean`. A fresh build reports
exactly `["de", "en", "es", "fr"]`.
