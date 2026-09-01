# Traps that cost hours

Verified on macOS 27.0 (26A5416b), Xcode 26.6 / macOS 26.5 SDK. Each of these looks completely correct on screen while being broken. None produces a warning, an error, or any visible difference. Do not undo them.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

<details>
<summary>Topics in this file (78)</summary>

- Under Hardened Runtime a protected resource is refused **silently** unless the app declares its `com.apple.security.personal-information.*` entitlement
- A `.nonactivatingPanel` that takes key does *not* move the frontmost app — and `NSApp.isActive` says it does
- Never assign `NSWindow.ignoresMouseEvents` — not even `false`, which is already the default
- `shape.fill(LinearGradient)` inside the panel widens the window's event shape; the same picture drawn as `shape.fill(solid).mask(gradient)` does not
- Never apply `.allowsHitTesting(false)` to a SwiftUI view that covers the panel
- `glassEffect(_:in:)` renders nothing when given a custom `Shape`
- A hit region widened during a transition must be a superset of every state it passes through
- `islandPath` being nil silently eats every click
- Inserting a stored property into a shared struct does something far worse than the added-file trap below: dependent packages keep the old memory layout and read every field at the wrong offset
- Adding a new file to IslandKit breaks every dependent package's next build
- `mouseExited` is not guaranteed to arrive, *and* it arrives when nothing left
- The pointer cannot be relied on to rest inside the notch
- `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` is alpha-aware and system-wide
- `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` is not thread-safe: concurrent calls abort the process
- A fullscreen space transition covers the island for ~1s; it does not destroy it
- Between two fullscreen spaces the transition composites a *snapshot* of the panel, not the live window — so hiding the island by redrawing it cannot work, however early the frame is flushed
- Both spaces are photographed, so `occlusion → visible=true` is not the end of anything and must never restore the island
- On the hide path `alphaValue` must be written before anything that draws
- A desktop space composites the island into its own picture; a fullscreen space does not — and no window property changes that
- No signal marks the end of a space transition, and the signals that exist disagree about the start — so the island is hidden by *anything* that might be one and comes back when they stop
- `applicationWillTerminate` returns into `exit()`, so teardown that is merely *scheduled* never happens
- Killing a stranded helper at launch is safe only because of the parent check
- `KERN_PROCARGS2` puts an unspecified run of NUL padding between the executable path and `argv`
- A teardown test that polls cannot see this class of bug
- Two days of timing work could not fix the desktop slide, and the measurements are kept so nobody repeats them
- A permission bug cannot be reproduced from a shell, and every check this project documents runs from one
- A Debug build's Accessibility grant dies on every rebuild, and System Settings goes on showing the switch turned on
- `AXUIElementPerformAction` returns `.success` for an action that does not exist
- `-25211` and `-25204` mean different things, and conflating them sends you to System Settings for a problem that is not a permission
- A successful AX attach is not evidence a source works
- An idle NotificationCenter refuses accessibility entirely, including observer registration
- AX events do not cover a child added to a window already on screen (measured on NotificationCenter, which is withdrawn)
- A depth-first AX walk with a shared node budget never reaches the notifications
- Opening NotificationCenter is a burst of 31+ AX events in 300 ms, and a scan per event stalls the main thread for over a second
- `AXUIElementSetMessagingTimeout` is mandatory, not tuning
- An app extension without `com.apple.security.app-sandbox` does not exist, and nothing says so
- Finder Sync's contextual menu is never asked for on macOS 27, and its toolbar item is
- A URL handed to a cold-launched app arrives 74 ms *before* `applicationDidFinishLaunching`
- `NSExtensionActivationSupportsFileWithMaxCount` is a hard, silent gate
- Adding a resource to an SPM package breaks a signed Release build, and the error names a package manifest that has nothing wrong with it
- `swiftc` on this toolchain stamps `minos 28.0` — higher than the running OS — so every throwaway probe `.app` is refused by LaunchServices with `-10825`
- FSEvents from Swift without `kFSEventStreamCreateFlagUseCFTypes` is a SIGTRAP
- `IOPSCopyPowerSourcesInfo`'s description dictionary carries `Hardware Serial Number`
- Per-frame drawing through SwiftUI `Canvas`/`TimelineView` costs ~18% of a core and ~279 MB, and the size of the thing drawn does not matter
- Mutating a Swift `Dictionary` while iterating `dict.keys` is a SIGTRAP, not a wrong answer
- swift-testing evaluates `.enabled(if:)` off the main actor
- A CoreAudio listener registered for a property the device does not have returns `noErr` and then never fires
- One volume keypress delivers eight identical CoreAudio callbacks, and the mute listener fires on volume changes with mute unchanged
- `IOBluetooth` delivers its connect notification on CoreBluetooth's XPC queue, not the main queue, and an `@objc` method on a `@MainActor` class takes SIGTRAP the first time real hardware connects
- A flat SF Symbol cannot be turned through 90°: `rotation3DEffect` makes it one pixel wide there and draws it *mirrored* from 90° to 270°
- A `matchedGeometryEffect` pair driven from a `ForEach` leaves two views claiming one id
- The notch is a hole, not a dark rectangle — it has no pixels to draw on
- `glassEffect(_:in:)` given to `.background(_:)` composites *above* the content it is behind
- `CGWindowListCreateImage` is *obsoleted*, not deprecated — at Isleta's deployment target it is a compile error — and its denied shape is a 30 MB flat gray rectangle. Measured 2026-08-23 while building the app switcher, which is withdrawn
- ScreenCaptureKit gates *enumeration*, not just capture, and the one call that ignores the gate is the convenient one
- `CGWindowListCopyWindowInfo` survives the refusal with everything except the titles
- ⌥Tab is claimable, ⌘Tab is not, and Fn is not a modifier at all — and `RegisterEventHotKey` returns `noErr` for all three
- Raising *another* app from an accessory app works unconditionally, and the bullet below must not be read as saying otherwise
- `NSApp.activate()` cannot activate an accessory app, and it is the call the compiler steers you to
- `System Events`' `frontmost` is not a usable observer for an `LSUIElement` app
- `setContentSize` holds the frame's *top-left*, so a window built at `.zero` and grown to its fitting size never has origin `.zero` again
- A key equivalent on a status-item menu is not a shortcut
- Assigning `NSWindow.collectionBehavior` to suppress full screen makes the window never appear
- `NavigationSplitView` on macOS hosts its sidebar toggle *inside the sidebar's* title bar, so collapsing the sidebar hides the control that reopens it — and SwiftUI answers by adding a second toggle, a double chevron, in the detail pane
- `.toolbar(removing:)` must go on the *column's content*, not on the `NavigationSplitView`
- `SMAppService.mainApp.status` answers `.notFound` for an app that has simply never been registered — it is the state of every fresh install, and it does not mean the copy is unsigned
- Outside a `Form`, SwiftUI's default `Toggle` style on macOS is a checkbox, not a switch
- Inside the island's hosting view, a SwiftUI clip does not contain scrolled content — and a shape in the same container at the same moment is clipped perfectly
- "Is this path on a mounted volume" cannot be answered by prefix-matching `mountedVolumeURLs`, and the version that can't reads as though it can
- `bookmarkDataIsStale` fires on an ordinary rename in place, with a URL that resolves correctly to the new name
- Security-scoped bookmarks work in an unsandboxed app and are the more portable form
- `QLPreviewPanel` makes an accessory app the active app for the life of the preview, and there is no way round it
- A `@MainActor` type cannot directly satisfy `CLLocationManagerDelegate` under Swift 6
- `NSImage.cgImage(forProposedRect:context:hints:)` ignores the rect you hand it
- A formatter declared on a `View` is `@MainActor`, and only fails at the test that calls it
- A `safeAreaInset` header does not stop the content scrolling under it, and neither of the two APIs for that does anything to a `NavigationSplitView` sidebar
- `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are `NSRect?` in Swift
- A closure handed to a callback parameter that is not `@Sendable` inherits the enclosing `@MainActor` isolation, and the compiler's runtime check for it SIGTRAPs the moment the callback fires on another queue

</details>

---

Each of these looks completely correct on screen while being broken. None produces a warning, an
error, or any visible difference. Do not undo them.

- **A `.nonactivatingPanel` that takes key does *not* move the frontmost app — and `NSApp.isActive`
  says it does.** There is no way to type into a window that is not key; that is what key means. A
  global `NSEvent` monitor sees keystrokes without consuming them, so every character would also land
  in the user's editor, and a consuming `CGEventTap` means hand-writing selection, dead keys, marked
  text and the IME candidate window *and* needs Input Monitoring. So `IslandPanel.acceptsKeyboardInput`
  lifts the "never key" rule for the length of one compose, and three probes on macOS 27.0 with a
  real app frontmost say what that costs: `NSWorkspace.frontmostApplication` **never moves** across
  the whole cycle, and the frontmost app's focused window stays `AXMain = true` — no Dock switch, no
  menu-bar swap, **no title-bar flicker**. `NSApp.isActive` *does* flip true for the duration and
  back on `resignKey()`, which is the reading that makes this look like a violation and is not one:
  on an `LSUIElement` app with no Dock tile and no menu bar there is nothing on screen that draws it,
  and CLAUDE.md already records `System Events`' `frontmost` and `NSApp.isActive` disagreeing in the
  other direction. Handing key back is `acceptsKeyboardInput = false` **then** `resignKey()`, in that
  order — the flag must be false first or AppKit may hand key straight back to a window that still
  says it wants it. `NSApp.hide(nil)` reads as the tidy way to finish and is both unnecessary and
  wrong: it takes the island off screen with everything else. What no probe can show is the **caret**
  in the app behind, which stops blinking while another window is key — true of every typing surface
  on macOS, and the reason this is a flag rather than a policy.
- **Never assign `NSWindow.ignoresMouseEvents` — not even `false`, which is already the default.**
  The window server derives a window's event shape from the alpha channel of its backing store; that
  is what lets clicks pass through wherever the panel is transparent. *Assigning* the property
  replaces that derived shape with the whole window frame, and the panel silently swallows every
  click across 603×200pt at the top of the display. Found by bisecting `IslandPanel` one property
  at a time.
  **`IslandBlurPanel` sets it to `true`, and that is not an exception to the rule but the other side
  of it.** The rule is about a window whose alpha-derived event shape *is* the mechanism. The blur
  panel draws no control, accepts no click and has no hit testing of its own — and an
  `NSVisualEffectView` claims every point its mask covers at any tint whatsoever, measured — so
  `true` is the documented way to say exactly that. The same goes for `LockScreenPanel`. Nothing else
  may assign it; `IslandHostingView` records the same prohibition for its own root view.
- **`shape.fill(LinearGradient)` inside the panel widens the window's event shape; the same picture
  drawn as `shape.fill(solid).mask(gradient)` does not.** Measured 2026-08-23 on macOS 27, one
  variable at a time, against the Semi-Liquid Glass island: with a gradient *fill*,
  `PassThroughSelfTest` went from **12/12 to 7 ok, 5 FAILED** — `corner-left`, `corner-right`,
  `outside-left`, `outside-right`, `beside-top`, every one a point **outside** the island that must
  reach the app below. The identical gradient applied as a `.mask` over a solid fill: **12/12**. A
  flat `shape.fill(black)` in the same position: 12/12. Two things make this expensive: the gradient
  has **lower** alpha than the solid fill it replaces, so every instinct says pass-through should
  improve rather than break; and **`ClickSelfTest` passes throughout** — clicks *on* the island work
  perfectly, and what breaks is clicks on the desktop beside it, which land nowhere. It is only
  visible to `PassThroughSelfTest`, and only when that is run against the affected style rather than
  the default one — `--style-demo <style> --perf-report` is how. See `IslandMaterialView`.
- **Never apply `.allowsHitTesting(false)` to a SwiftUI view that covers the panel.**
  `NSHostingView` reports SwiftUI's hit-testing regions up to the window server as the window's
  event shape, so a full-size view that declines hit testing collapses that shape to nothing for the
  *entire window*, including content drawn by sibling views. It reads as the obviously correct
  modifier for a read-only overlay. `IslandHitTestView` already gates everything outside the island.
- **`glassEffect(_:in:)` renders nothing when given a custom `Shape`** — zero alpha, not merely
  invisible. It works only with SwiftUI's own shape types, and filling the shape first does not
  rescue it. `IslandRootView` renders the glass against a `RoundedRectangle` and `.mask()`s it to the
  island outline; the cost is that the glass computes its edge treatment for the rectangle, so the
  rim highlight does not follow the concave corners. Revisit in §6.
- **A hit region widened during a transition must be a superset of every state it passes through.**
  A subset is what hurts: clicks land on visible island pixels, reach us, and get dropped — they
  neither activate Isleta nor fall through. A superset is unreachable anyway, because the window
  server already routed those clicks elsewhere. `widenHitRegionForTransition` uses the peek shape,
  which works *only because* the corners curve inward; with the old outward-flaring corners it had
  to be a bounding box. `PeekTests` pins this down.
- **`islandPath` being nil silently eats every click.** The window server routes clicks on the
  island's opaque pixels to us; `hitTest` then rejects them, so they neither open the island nor
  reach the app underneath. `PassThroughSelfTest` cannot see this — it asks the window server, which
  is behaving correctly throughout. This shipped for a whole milestone. `ClickSelfTest` is what
  caught it, and is why `applyHitRegion` takes an attachment rather than a display id: the id-based
  path silently did nothing when called before the attachment was registered.
- **Inserting a stored property into a shared struct does something far worse than the added-file
  trap below: dependent packages keep the old memory layout and read every field at the wrong
  offset.** Observed on 2026-08-22 when `applicationIconName` was added to `ActivityContent`
  *before* `title`. There was no compile error. `swift test` reported
  `presentations.compact.title == nil` on a greeting that plainly had one, `expanded.subtitle`
  returning the *title*, a volume HUD with a nil `value` — a clean one-field shift across three
  packages — and then the IslandSources bundle died with **signal 11**. Every one of those reads as
  a source bug in the factory that built the content, and none of them is; the sources were
  correct throughout. `Tools/check.sh`'s shared `--scratch-path` does not save you here, because the
  problem is a *stale* cached module rather than a missing one. The fix is
  `swift package --package-path <pkg> --scratch-path .build/spm clean` and a full re-run. **Suspect
  this before reading the failing factory**: a shift by exactly one field, or a segfault in a
  package you did not touch, is a layout mismatch and not arithmetic.
- **Adding a new file to IslandKit breaks every dependent package's next build**, once each, with
  "cannot find type". SwiftPM does not invalidate a path dependency's cached module when a source
  file is *added*. `Tools/check.sh` gives every package one shared `--scratch-path`, which is the
  fix; don't remove it.
- **`mouseExited` is not guaranteed to arrive, *and* it arrives when nothing left.** Both halves
  cost a session. A pointer leaving the island across the panel's transparent area stops generating
  events for our window, so AppKit can miss the tracking-rect crossing and the island stays peeked;
  `IslandHitTestView` runs a 100ms watchdog while hovered — and only while hovered, so the idle path
  keeps no timer. In the other direction, the tracking rect is rebuilt whenever the island's size
  changes, and a rect rebuilt under a stationary pointer reports an exit and a fresh entry — and
  since the blur band moved into its own window, crossing the island's own edge into the band ends
  mouse events for the island's panel and AppKit reports an exit that did not happen. **So the hint
  is evidence of nothing in either direction: ask for a position.**
  `IslandHitTestView.mouseExited` ignores the hint while `pointerIsInsideHoverRegion`, and
  `AppDelegate.pointerExitChanged` waits out a grace period and then asks
  `IslandController.isPointerInsideHoverRegion(forScreen:)`. See
  `docs/MOTION-AND-INTERACTION.md` on the blur.
- **The pointer cannot be relied on to rest inside the notch.** Warping to the notch center can
  leave it displaced above the screen, and where another display sits directly above the laptop the
  pointer travels straight through the 32pt band onto that screen. Hover works, but the target is
  small — treat discoverability as an open design question, not a solved one.
- **`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` is alpha-aware and system-wide**, which
  is what makes `PassThroughSelfTest` a real test rather than an assertion — but it only works from
  a running `NSApplication`. From a plain command-line process it returns 0 for everything.
- **`TISCopyCurrentASCIICapableKeyboardLayoutInputSource` is not thread-safe: concurrent calls abort
  the process.** Not a wrong answer — SIGABRT. Verified in isolation: 300 concurrent calls from a
  plain CLI binary die with signal 6, while 300 concurrent `UCKeyTranslate` calls against an
  already-fetched layout blob are fine, so the input-source lookup is the unsafe half. It surfaced as
  a test bundle that crashed *after every test reported passing* — swift-testing runs tests in
  parallel, three of them named a key at the same moment, and `swift test` printed green checkmarks
  and then exited 1 with "unexpected signal code 6". `HotKeyBinding.keyName(for:)` is `@MainActor` for
  this reason; caching the blob would also work but goes stale when the user switches layout. A
  second trap in the same call: passing `characters.count` as an argument to the same call that takes
  `&characters` is an exclusivity violation that traps at runtime with no compile-time warning.
  Asking the layout at all is not optional — a key code is a *position*, and the hardcoded ANSI table
  every menu-bar app ships tells a Dvorak or AZERTY user their shortcut is a letter that is not on
  the key they pressed.
- **A fullscreen space transition covers the island for ~1s; it does not destroy it.** The symptom
  invites the wrong fix — the island appears to vanish and snap back, which looks exactly like the
  panel being rebuilt. Measured with a probe standing up a panel at the same level and collection
  behavior: `auxiliaryTopLeftArea` stays set throughout (so no rebuild is triggered) and the panel
  never stops being `isVisible`. What changes is *ownership of the notch pixel* — two other windows
  come above ours for about a second, then ours returns by itself. Raising `level` is the wrong
  answer; it would put the island over system UI permanently to fix a one-second overlap. The fix is
  `orderFrontRegardless()` on `NSWorkspace.activeSpaceDidChangeNotification`, which is registered on
  **`NSWorkspace`'s** notification center — a token from one center removes nothing when handed to
  the other.
- **Between two fullscreen spaces the transition composites a *snapshot* of the panel, not the live
  window — so hiding the island by redrawing it cannot work, however early the frame is flushed.**
  Desktop↔fullscreen hides correctly and fullscreen↔fullscreen does not, which reads as one of them
  being a special case; both take the same code path. `didChangeOcclusionState` does fire, ~900ms
  before `activeSpaceDidChange`, so the hide is requested in plenty of time — but the picture the
  user watches slide past was captured at that instant, before our frame existed. The island sits
  pinned over the whole slide and then bounces in on the space it was already on. The fix is
  `panel.alphaValue = 0` in the occlusion handler: a window-server-side property, so it lands
  without a render pass and the snapshot is taken with the island already absent. **Not `orderOut`,
  which also hides it and then never brings it back** — an ordered-out window stops posting
  `didChangeOcclusionState` entirely, so the panel went off screen on the first transition and
  stayed off through ten more space changes, waiting for the one notification that no longer
  arrives. A transparent window keeps reporting. Measured on macOS 27.0 with three probes; the
  difference between them is visible only on hardware.
- **Both spaces are photographed, so `occlusion → visible=true` is not the end of anything and must
  never restore the island.** It arrives in the middle of the slide with the animation still running.
  Restoring there fixes the space being left and breaks the space being entered: the island becomes
  opaque while the incoming space is still being composited, is captured into *its* picture, and
  slides in welded to the arriving window — adrift from the notch, which reads worse than the
  original bug. Playing the re-entry there is wrong in the opposite direction: the animation runs
  while the panel is transparent, where nobody can see it, and leaves the content settled, so the
  island later *appears* instead of arriving. That branch does exactly one thing — keep the settle
  alive, because it is evidence the transition has not finished. See `TransitionSettle`.
- **On the hide path `alphaValue` must be written before anything that draws.** The margin against
  the snapshot is a few milliseconds, and `alphaValue` beats it only because it needs no render pass.
  Putting the content reset and its `CATransaction.flush()` first — which reads as the natural order,
  and is the right order when *restoring* — spends a synchronous render commit ahead of the one write
  that had to land instantly, and the island is briefly painted into the picture before it goes
  transparent. Visible on hardware as a flicker at the start of every desktop slide, and invisible in
  every test.
- **A desktop space composites the island into its own picture; a fullscreen space does not — and no
  window property changes that.** Measured on macOS 27.0 with five panels differing by one property
  each: `.stationary` removed, `level = .mainMenu`, `sharingType = .none`, `.fullScreenAuxiliary`
  removed, against the shipping baseline. All five behaved **identically** — every one vanished
  during a fullscreen↔fullscreen slide, and every one was painted into the desktop image and
  traveled with it during a desktop slide. So the flags that read as if they govern this
  (`.stationary` above all, whose whole job is "do not move with the space") govern nothing here, and
  the only lever left is being transparent before the picture is taken. Don't re-run this experiment.
- **No signal marks the end of a space transition, and the signals that exist disagree about the
  start — so the island is hidden by *anything* that might be one and comes back when they stop.**
  Measured on macOS 27.0 one switch at a time, with silence either side, because that is the only way
  these shapes are readable: desktop↔desktop is an occlusion drop, then `activeSpaceDidChange`
  779–782ms later at the end; into fullscreen is a change *first*, the drop ~400ms after it, then a
  second change ~1s later; out of fullscreen is a drop, `visible=true` 678ms later, then the change
  779ms after that. No ordering rule serves all three, and three separate attempts to write one each
  fixed a case by breaking another.
  What does hold across all of them: **a change arriving after a drop was the last signal every
  time**, which is what lets the island return in 350ms instead of waiting out the 1011ms worst-case
  gap between consecutive signals. `TransitionSettle` is that rule, kept pure and tested away from
  AppKit — every bug here was about signal *order*, which needs no window server to reproduce.
  **Do not trust a log of rapid switching.** Consecutive switches overlap and look exactly like one
  transition with two halves; an earlier version of this note claimed desktop↔desktop posts two
  `activeSpaceDidChange` per switch, and it does not — those were two switches, and a state machine
  was built on the misreading. It also claimed a quiet-period debounce "cannot work at all" because
  signals inside a transition are 1–2s apart. They are ~780ms apart; the 1–2s came from the same
  overlap, and the debounce is what shipped. **Our own `alphaValue` writes perturb the occlusion
  stream** — passive and acting probes report different patterns — so measure with the probe doing
  what the app does.
- **`applicationWillTerminate` returns into `exit()`, so teardown that is merely *scheduled* never
  happens.** `NowPlayingAdapterReader.stop()` did all of its work inside `queue.async` — correct on
  every path but this one, where the block was still queued when the process died. SIGTERM was never
  sent and **an ordinary Quit orphaned the `perl` helper every single time**, one per launch,
  reparented to launchd and accumulating until reboot; nineteen were found alive on a dev machine,
  the oldest twelve hours old. Nothing inside the app can see this: `stop()` is correct, it is
  called, it logs nothing. Only the process table shows it. The same reasoning kills the SIGKILL
  escalation on that path — it waits two seconds to check on a process that has been gone for 1999
  milliseconds — so a wedged helper was stranded whether or not it honored a signal it never got.
  Teardown on the quit path must be synchronous through to the `waitpid`; see
  `ActivitySource.stopAndWait()`. One orphan per *crash* still cannot be prevented from inside the
  dying process — macOS has no `PROC_PDEATHSIG` and a SIGKILLed process cannot send SIGTERM — so it
  is collected on the way **up** instead, by `NowPlayingAdapterOrphans.sweep`.
- **Killing a stranded helper at launch is safe only because of the parent check.** The rule is four
  conditions and each rules out a specific way of killing something that is not ours: `argv[0]` is
  `/usr/bin/perl`; `argv` contains **this bundle's absolute script path** (other notch apps vendor
  the same `ungive/mediaremote-adapter`, so matching the file name reaches into a competitor's
  processes); same uid; and — the load-bearing one — **the parent is launchd**. A helper belonging to
  a live Isleta has that instance's pid as its parent, never 1, so no arrangement of running copies
  can put a live helper in range. Verified on macOS 27.0 with two concurrent instances: the second
  one's sweep left the first one's helper alone. This is the narrow version of the thing
  `NowPlayingAdapterReader` warns against; the warning is about killing every `perl` found at launch,
  which remains wrong. Reading the table is two-stage — `KERN_PROC_ALL` once, then `KERN_PROCARGS2`
  only for processes that already pass the cheap filters — because the second is a syscall per pid
  and cold launch is budgeted at 300ms.
- **`KERN_PROCARGS2` puts an unspecified run of NUL padding between the executable path and `argv`.**
  Splitting the blob on NUL and taking the first `argc` fields therefore yields empty strings or real
  arguments depending purely on how the kernel aligned that particular executable's path — so the
  naive parser works on some processes and silently fails on others, which is the worst way for a
  parser to be wrong. Step over the path, then over *all* following NULs, then read `argc` strings.
- **A teardown test that polls cannot see this class of bug.** The existing "stop() leaves no child
  process" test retried for ten seconds and passed throughout, because the deferred teardown always
  landed well inside that window — the assertion was true, just not at the moment that mattered. The
  test that catches it asks the kernel **once**, immediately after the call returns; the absence of
  the retry loop is the test. `kill(pid, 0)` also succeeds against a zombie, so the same assertion
  pins reaping rather than only signalling.
- **Two days of timing work could not fix the desktop slide, and the measurements are kept so nobody
  repeats them.** Everything below was measured on macOS 27.0 before the private space existed, and
  every line of it is why the private space is the mechanism and not the timing. A desktop space is
  photographed with the island already in it before the occlusion drop — the earliest thing the
  window server sends — arrives. An `NSEvent` global monitor sees **zero** events for nine space
  swipes; a `CGEvent.tapCreate` at `.cghidEventTap` sees the gesture 111–723ms ahead of the drop, and
  that *did* work (≥3 fingers plus actual travel — finger count alone fired on a three-finger tap),
  but it needs Input Monitoring, which most installs will never grant, and it cannot see ⌃←/⌃→ at
  all. Without it, a space change must never be allowed to *start* a hide: the picture is already
  taken, so hiding late paints the island through the slide and then blips it out and back, two
  artifacts where there was one. That is still the rule on the fallback path. The private SkyLight
  *signals* do not help either: `SLSManagedDisplayIsAnimating` never reports true, and events 1401,
  1508 and 1329 fire in the same millisecond as the public notification. Only the private *space*
  does.
- **A permission bug cannot be reproduced from a shell, and every check this project documents runs
  from one.** TCC attributes an access request to the *responsible* process: launched from Terminal
  (or Xcode), a build is judged against **Terminal's** Info.plist strings and TCC records, so a
  missing usage string, a refused service and a prompt that should have appeared all come back
  clean. Launched through LaunchServices — Finder, the Dock, a login item, `open -a Isleta` — the
  app is its own responsible process and the real answer arrives. This cost a published release:
  1.3.0 was built, signed, notarized and put on GitHub after passing `--perf-report`, `--device-demo`
  and a hardware check of the AirPods feature, and it aborted 270 ms into every real launch for want
  of one Info.plist key. **`open -a Isleta`, then read the log and `~/Library/Logs/DiagnosticReports`,
  is part of cutting a release** — the debug flags are structurally unable to see this class of bug.
- **A Debug build's Accessibility grant dies on every rebuild, and System Settings goes on showing
  the switch turned on.** The Debug app is **ad-hoc signed** and carries the same bundle identifier
  as the release, `com.tryisleta.isleta`. An ad-hoc signature has no stable designated requirement —
  the cdhash changes with every compile — so TCC's record matches the exact binary that was granted
  and nothing built after it. The row keeps its name, its icon and its toggle, and
  `AXIsProcessTrusted()` answers false to a copy the list appears to have authorised. Worse, the
  poisoned row is shared: a grant made to a Debug build is what the *installed, Developer ID* copy
  then fails to match, because both are "Isleta" to that list. Measured on macOS 27.0 — with the
  toggle on, a **freshly launched** `/Applications/Isleta.app` (Developer ID, team `UA2RJP3TSL`) and
  a freshly launched Debug copy both logged "not attached — Accessibility is not granted"; a new
  process rules out the "it needs a relaunch" reading. The fix is `tccutil reset Accessibility
  com.tryisleta.isleta`, which also returns the source to `.undetermined`, so the settings button
  raises the real prompt again instead of the deep link. **Do not read this as a shipped bug**:
  release builds share one designated requirement (identifier plus team), which is why 1.0.1 →
  1.1.0 keeps a user's grant. It costs a session only on a machine that has run both.
The seven entries that follow were measured against `com.apple.notificationcenterui` while the
notification island was being built. **Notifications are withdrawn** — there is no notification
activity kind, no source, no recents list, no banner takeover and no setting — and the entries stay
because every one of them is a fact about Accessibility rather than about that feature, and because
the AX traps below are live for anything that ever reaches into another process's tree. The types
they name (`NotificationAXObserverSource` and the rest) are not in the tree; read "the source" as
"the source that was built", and "the island" as whatever is on the main thread next time.

- **`AXUIElementPerformAction` returns `.success` for an action that does not exist**, and
  `AXUIElementCopyActionNames` does not return the names a human would type. A notification
  banner's custom actions come back as their *stringified objects* —
  `"Name:Close\nTarget:0x0\nSelector:(null)"`, newlines and all — so the obvious
  `performAction(banner, "Close")` is an unknown action: it answers 0, changes nothing, and reads
  in every log as having worked. Verified against a deliberate `"ThisIsNotAnAction"`, which also
  answered 0. Perform the string **verbatim from the array**, and never treat the returned error as
  evidence the action ran — measure the effect instead.
- **`-25211` and `-25204` mean different things, and conflating them sends you to System Settings
  for a problem that is not a permission.** Measured 2026-08-23 by launching the *same signed
  bundle* two ways: run from Terminal, `AXIsProcessTrusted` is true and every call returns `success`;
  run with `open -a`, it is false and every call returns **`apiDisabled` (-25211)**. So **-25211 is
  "this process is not trusted"** and **`cannotComplete` (-25204) is "trusted, and the target is
  refusing"** — the second is the one this file documents for an idle NotificationCenter. This is the
  TCC-responsibility trap reproduced cleanly, and note the corollary: when what you are measuring is
  *the shape of somebody else's window* rather than Isleta's ability to obtain a grant, the Terminal
  launch is the correct one and inheriting Terminal's grant is the point.
- **A successful AX attach is not evidence a source works.** Attaching to an idle
  NotificationCenter *succeeds*; only reading it answers -25204. Treating attach-success as progress
  and resetting the retry counter there makes the backoff unable to advance — attach, scan an empty
  screen, retry at 500ms, attach, reset — a 2Hz poll on an idle Mac forever. It measured 0.38-0.42%
  against §9's 0.3% idle budget, one source spending the whole allowance. Note the shape of the
  miss: a test asserting the *delay curve* existed and passed throughout, because the curve was never
  wrong. Only the counter's progression was.
- **An idle NotificationCenter refuses accessibility entirely, including observer registration.**
  With nothing on screen `com.apple.notificationcenterui` answers `cannotComplete` (-25204) to every
  attribute *and* to `AXObserverAddNotification` — so an observer can only be registered while it has
  UI up, and no event announces that it woke, because hearing that would need the registration you
  cannot yet make. Retry with backoff; there is no edge to wait on.
- **AX events do not cover a child added to a window already on screen.** Window creation and
  destruction arrive; a notification added to a live NotificationCenter window produced no
  `AXCreated`, no `AXWindowCreated` and no `AXLayoutChanged`. A source that trusts the event stream
  sees the first banner of a burst and none of the rest — and the general form is that an AX
  observer is a *hint* to rescan, never an inventory.
- **A depth-first AX walk with a shared node budget never reaches the notifications.**
  NotificationCenter owns several windows and the widget sidebar is thousands of SwiftUI wrappers
  deep, so a depth-first copy spends the whole budget in window 0. It looks perfect — attached,
  scanning, "healthy empty hierarchy", zero notifications, forever. Walk breadth-first.
- **Opening NotificationCenter is a burst, not an event, and a scan per event stalls the island.**
  Measured 2026-08-24 on macOS 27.0 against the real `com.apple.notificationcenterui`, with a probe
  registering the same four notifications that source registered. NotificationCenter
  **sitting open and untouched raises zero events in twelve seconds** — the observer really is idle.
  But **one open plus one close raises 60 events, 40 of them `AXUIElementDestroyed`, and 31–35 of
  them land inside a single 300 ms window.** Those destroys are what kills the cached list element,
  so the next scan takes the discovery walk rather than the cached one — and the two paths are not
  close: against an open NotificationCenter (34 nodes, one notification) discovery timed at
  **25–51 ms** of synchronous main thread against **2–7 ms** for a cached rescan. Idle
  NotificationCenter is 8 nodes and ~5 ms, which is why this never showed up in banner testing.

  Scanning once per callback, which that source did until it was measured, therefore spent
  **0.8–1.8 s of blocked main thread inside that 300 ms window** — landing on the expand spring,
  which is main-thread SwiftUI, as a stall a user reads as the island being slow. The window layer
  is not involved and checking it is a dead end: the panel sits at `statusBar + 1` and
  NotificationCenter's panel far above it, and window level costs nothing at composite time.

  The fix is to coalesce the callbacks — 32 ms window, 120 ms hard deadline so a storm cannot starve
  the read — not to scan faster or to walk less. Replaying the *real* event timeline through that
  rule: 64 events and 35 in the busiest window became **8 scans and 2 in the busiest window**, so
  875–1785 ms of main thread became 50–102 ms. Both numbers are far inside the 300 ms rescan cadence
  the source already accepts, so nothing about notification latency changes.
- **`AXUIElementSetMessagingTimeout` is mandatory, not tuning.** Accessibility calls are synchronous
  IPC at roughly 0.6ms each, and one wedged target blocks the main thread indefinitely without it.
- **An app extension without `com.apple.security.app-sandbox` does not exist, and nothing says so.**
  Measured 2026-08-23 A/B/A — same sources, same signature, changing only the entitlement:
  without it, `pluginkit -m -i <id>` answers **nothing**, `codesign` is happy, and the feature is
  simply absent. Two things follow that are easy to get backwards. **It does not sandbox Isleta** —
  an `.appex` is its own signed bundle and the app stays unsandboxed, which matters because the
  sandbox is off for Accessibility and the `mediaremote-adapter` helper. And it needs **no
  provisioning profile**: `com.apple.security.*` is consumed by the sandbox rather than by AMFI, so
  it is *not* the exit-137 family. An **App Group** is that family, and is the trap — verified
  against Google Drive's shipping Finder extension, which carries no `embedded.provisionprofile`
  anywhere.
- **Finder Sync's contextual menu is never asked for on macOS 27, and its toolbar item is.**
  Measured across four `directoryURLs` configurations (`[]`, unassigned, `file:///`, one specific
  folder), each with a Finder restart: **zero** calls to `menuForMenuKind:` for kind 0 or kind 1,
  ever. The paired control in the same session, one minute apart, is what makes it a finding rather
  than a wiring bug — `kind=3` (toolbar) **was** called, the extension was enabled, Finder held a
  live XPC connection to it, and it logged `beginObserving` for the folder on screen. It also costs
  **two resident processes** (~8 MB each) for the whole Finder session. **One caveat, stated because
  it is the only hole:** the right-click was a synthesized `CGEvent`, and this file's own rule is
  that a synthesized stimulus can fail to fire (see the brightness keys). A 30-second manual check
  is the way to settle it. The **Share extension** works and leaves
  nothing resident, at the cost of being one level in — on macOS 27 Finder's "Share…" is a sheet.
- **A URL handed to a cold-launched app arrives 74 ms *before* `applicationDidFinishLaunching`.**
  So a handler installed there misses every cold launch and works on every warm one, which is the
  worst way for this to be wrong. Use `application(_:open:)` and buffer. Do **not** register a
  `kAEGetURL` Apple Event handler as well — that splits warm and cold onto different code paths.
  Measured with an extension handing paths to Isleta: 344–430 ms cold, 270–313 ms warm, and 250 KB
  of URL (2,415 paths) delivered intact, so length is not the constraint.
- **`NSExtensionActivationSupportsFileWithMaxCount` is a hard, silent gate**: 50 files offered the
  share row and 51 removed it from the sheet entirely, with no error anywhere. And **`NSItemProvider`
  attachment order is not selection order** — a Finder selection arrives shuffled, so sort it.
- **Adding a resource to an SPM package breaks a signed Release build, and the error names a package
  manifest that has nothing wrong with it.** Adding `resources:` to a package makes SwiftPM generate
  a **resource-bundle target** for it — `IslandUI_IslandUI` and three siblings. A build setting
  passed to `xcodebuild` on the command line applies to **every target in the build graph**, so
  `Tools/release.sh` handing it `PROVISIONING_PROFILE_SPECIFIER` reached all four, and a resource
  bundle cannot hold a profile: *"IslandUI_IslandUI does not support provisioning profiles … has
  been manually specified"*, four times, and the whole build stops. Nothing in the message mentions
  resources or localization, and it points at `Package.swift`. The fix is that the specifier lives
  in the **project**, on the Isleta target's Release configuration, where it reaches one target —
  the profile still has to be copied into Xcode's own directory first, because xcodebuild resolves
  it by name from there and a file in `Config/` is invisible to it. **`Tools/check.sh` cannot see
  this**: it builds Debug, unsigned, and the first signed Release build after such a change is where
  it appears.
- **`swiftc` on this toolchain stamps `minos 28.0` — higher than the running OS — so every throwaway
  probe `.app` is refused by LaunchServices with `-10825`.** From a shell `minos` is ignored, so the
  binary runs perfectly right up until the one launch that matters, and the refusal reads as a
  corrupt bundle rather than a build setting. Build probe bundles with
  `-target arm64-apple-macos26.0`. This bites every permission probe in this file, because
  `open -a` is the only launch that can see a TCC bug.
- **FSEvents from Swift without `kFSEventStreamCreateFlagUseCFTypes` is a SIGTRAP.** The callback's
  `eventPaths` is a `char**`, not a `CFArray`, so bridging it dies inside
  `Array._forceBridgeFromObjectiveC`. Related and cheaper to hit: **`notify.h` is not importable from
  Swift** — reach it through `-import-objc-header` with `#include <notify.h>`.
- **`IOPSCopyPowerSourcesInfo`'s description dictionary carries `Hardware Serial Number`.** It sits
  beside the fields a battery activity actually wants, so it lands in any `po` of the snapshot and in
  any log line that prints the dictionary. It identifies the user's machine and must never reach
  `IslandLog` or the export bundle — the log is emailed to strangers.
- **Per-frame drawing through SwiftUI `Canvas`/`TimelineView` costs ~18% of a core and ~279 MB, and
  the size of the thing drawn does not matter.** Measured 2026-08-23 across eight arms; see PERF.md's
  9.6 section. Six bars in a **40×32** panel cost **17.83%** against the same bars in a 608×200 panel
  at **17.72%**, with the **same 279.5 MB** — and the footprint is identical at 120, 30 and 8 Hz, so
  it is not a backing-store pool. Rate limiting does not rescue it: 8 Hz is still over §9's 4%.
  **Six `CALayer`s with a `CABasicAnimation` are 0.007–0.010% and 14.6 MB** for the same animation in
  the same panel — ~2400× cheaper, and *below* a static control's footprint, because the render
  server owns the animation and this process draws nothing. `.drawingGroup()` changes neither figure.
  So: **continuous animation belongs to CoreAnimation**, and a small animated element is not a safe
  one. The trap in measuring it is ProMotion — the cost tracks the display's *actual* refresh rate,
  which rises whenever anything else on screen animates, so the same arm reads 6% on an idle machine
  and 19% while the user is working. Only paired deltas against a same-session static control mean
  anything.
- **Mutating a Swift `Dictionary` while iterating `dict.keys` is a SIGTRAP, not a wrong answer.**
  `keys` is a lazy view over the dictionary. Inside a `DispatchSource` handler it presents as the
  process dying silently mid-run with a partial log — twice mistaken during the 2.0 probe wave for
  "the signal stopped arriving".
- **swift-testing evaluates `.enabled(if:)` off the main actor.** `MainActor.assumeIsolated` in a
  condition trait does not fail that test — it takes the whole bundle down with SIGTRAP *after* every
  other suite has reported passing. Same shape as the `TISCopy…` trap below: green checkmarks, then a
  non-zero exit.
- **A CoreAudio listener registered for a property the device does not have returns `noErr` and then
  never fires.** `AudioObjectHasProperty` is the only real gate; the status from
  `AudioObjectAddPropertyListenerBlock` tells you nothing. Compounding it, the built-in output on
  Apple Silicon has **no** main-element `kAudioDevicePropertyVolumeScalar` — the property every guide
  and most sample code reaches for reads as `'who?'` (2003332927). The one that exists and tracks the
  volume keys is `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`. Registering on the
  documented-but-absent property produces a source that compiles, starts, reports success, and
  observes nothing.
- **One volume keypress delivers eight identical CoreAudio callbacks, and the mute listener fires on
  volume changes with mute unchanged.** Undeduplicated that is eight `.interrupting` activities per
  keypress plus a mute HUD every time the volume moves. `SystemHUDLevelState` is where that is
  deduplicated, and it is pure so the rules are testable without touching the user's volume.
- **`IOBluetooth` delivers its connect notification on CoreBluetooth's XPC queue, not the main
  queue, and an `@objc` method on a `@MainActor` class takes SIGTRAP the first time real hardware
  connects.** It compiles clean, links, and runs — then `dispatch_assert_queue` fails inside Swift's
  isolation check and the process dies, by way of `-[IOBluetoothCoreBluetoothCoordinator
  centralManager:connectionEventDidOccur:forPeripheral:]` posting through `NSNotificationCenter`.
  **No test can reach it**, because it needs a device to actually connect, so it survives the whole
  suite and every launch until someone opens their AirPods case. Mark the `@objc` method
  `nonisolated`, read the device *there* (which is also where its percentages are freshest, and
  avoids handing a non-`Sendable` `IOBluetoothDevice` across isolation), and hop only the value. Also
  note **one physical AirPods connect fires that notification three or four times** — two or three at
  the classic address within 33ms and one at a BLE random address reporting `classOfDevice == 0` and
  zero for every battery field. Undeduplicated that is four islands for one thing the user did.
- **A flat SF Symbol cannot be turned through 90°: `rotation3DEffect` makes it one pixel wide there
  and draws it *mirrored* from 90° to 270°.** A 360° turn reads as obviously right in the code and
  in the description, and on screen the device vanishes mid-arrival and returns as the wrong
  hardware. There is no depth to catch the light because there is no depth. Nothing in the test suite
  can see this — every individual frame is plausible — and it was caught on a screenshot. Turn
  through a limited angle that never approaches edge-on; `DeviceConnectSlotView.arrivalAngle` is 62°,
  where the glyph is still 47% of its width. The same applies to any `.rotation3DEffect` on a symbol
  or a piece of text.
- **A `matchedGeometryEffect` pair driven from a `ForEach` leaves two views claiming one id.** During
  the removal transition the outgoing view is still in the hierarchy and still claims the geometry
  id, so the match resolves against the wrong one and the symbol jumps instead of traveling. Write
  the two states as the branches of a single `if`/`else` so SwiftUI swaps them in one transaction.
- **The notch is a hole, not a dark rectangle — it has no pixels to draw on.** Content in the
  `leading`/`trailing` slots lives in the lit slivers *beside* the cutout, so the drawable area is
  `bodySize` minus the cutout, not `bodySize`. At rest the two are the same rectangle and there is
  nothing to draw on at all. `ActivitySlotLayout` is the single place that arithmetic lives.
- **`glassEffect(_:in:)` given to `.background(_:)` composites *above* the content it is behind.**
  `content.background(RoundedRectangle().glassEffect(.regular, in: shape))` renders the glass as its
  own layer over the view, so every label, switch and slider inside draws blurred and unreadable
  through it — the card reads as a beautiful empty pane of glass with ghosts in it, and looks
  deliberate enough to be mistaken for the intended design. Apply it **to the content**:
  `content.padding(…).glassEffect(.regular, in: shape)`. This is the second way this one modifier has
  cost a session; the first is the custom-`Shape` trap above, which is the same call failing silently
  in the opposite direction.
- **`CGWindowListCreateImage` is *obsoleted*, not deprecated — at Isleta's deployment target it is a
  compile error — and its denied shape is a 30 MB flat gray rectangle. Measured 2026-08-23 while
  building the app switcher, which is withdrawn; the window-capture findings here and in the two
  entries below outlive it, and nothing in the tree captures a window today.** The SDK says
  `SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)`; at
  `-target arm64-apple-macos26.0` that is `error: 'CGWindowListCreateImage' is unavailable`, while at
  `…macos14.0` the same line is only a warning, which is why every sample still uses it. The symbol
  is still exported, and what it does without Screen Recording is worth knowing because **one
  function has two different denied shapes**: a whole-screen call returns a **non-nil** 3456×2234
  `CGImage`, 30,882,816 bytes, in 6.4–7.3 ms, with **every pixel `#2D2D31`**; the per-window call
  returns **nil**. A `guard let image` passes on the first and fails
  on the second, and neither says the permission is missing.
- **ScreenCaptureKit gates *enumeration*, not just capture, and the one call that ignores the gate is
  the convenient one.** `SCShareableContent.current` throws `SCStreamErrorDomain / -3801` in 11 ms
  when denied, with the message *"The user declined TCCs…"* **before the user has been asked** — and
  the string is identical either way, so it cannot separate undetermined from denied.
  `SCScreenshotManager.captureImage(in:)` **succeeds while denied**, returning the same flat
  `#2D2D31` with `uniqueColors == 1`. Granted costs: `SCShareableContent.current` is **~65 ms every
  time, with no caching**; per-window capture is **39 ms mean at 300×200 and 50 ms at 3456×2168**, so
  **the cost is stream setup, not pixels** — a 300× area reduction buys 12 ms, and shrinking
  thumbnails is not a performance lever. Fan-out buys only **1.4×** (12 windows in a `TaskGroup` =
  337 ms), and **5.3% of windows refuse outright** with `-3811`, unpredictably, so anything drawing
  a grid of window thumbnails needs a per-item icon fallback whatever the permission says. The good half: **SCK reads the backing store**, so a
  window that is behind another app, hidden with ⌘H, or on another Space captures byte-identically.
  **Never open an `SCStream` for a preview**: 171 ms to start one and 834 ms to start eight, and a
  static or occluded window delivers **zero complete frames in 5 s**, because the window server sends
  nothing without dirty rects.
- **`CGWindowListCopyWindowInfo` survives the refusal with everything except the titles.** Denied, 15
  entries carried every key but `kCGWindowName` (present on 1/15, and on 0/8 layer-0 windows). So
  with no permission at all you still know which apps have windows, how many, where, how big, their
  alpha and their z-order. It is also 6× *faster* denied (4.2–7.2 ms vs 38–45 ms) because there are
  no titles to marshal — a timing tell, though `CGPreflightScreenCaptureAccess` is the honest probe.
- **⌥Tab is claimable, ⌘Tab is not, and Fn is not a modifier at all — and `RegisterEventHotKey`
  returns `noErr` for all three.** Measured while choosing a shortcut for the app switcher, which
  is withdrawn; the finding is about Carbon hot keys, and it is why `HotKeyBinding` trusts no
  registration status. Measured by firing, against a positive control (⌥\` fired 3/3):
  ⌥Tab **3/3**, ⌃⌥Tab 2/3, ⌘Tab **0/3** (reserved below the Carbon layer), `kVK_Function` as a key
  **0/3**. Registration status is evidence of nothing; the only collision it reports honestly is with
  *yourself* (`eventHotKeyExistsErr`, -9878). The Carbon modifier set is `cmdKey/shiftKey/optionKey/
  controlKey` and **has no Fn bit** — passing `NSEvent.ModifierFlags.function` (`0x800000`) as the
  Carbon mask registers successfully **because it collides with nothing**, and silently gives you
  plain Tab under a different name. Fn+Tab needs a `CGEventTap` at `.cghidEventTap`, i.e. Input
  Monitoring, which the space-swipe note already writes off.
- **Raising *another* app from an accessory app works unconditionally, and the bullet below must not
  be read as saying otherwise.** Measured from a real `LSUIElement` bundle launched by
  LaunchServices with `NSApp.isActive == false`: `activate(options: [])` (3.5 ms),
  `.activateAllWindows` (8.4 ms), `activate(from:options:)`, `unhide()`-then-activate, and a
  **hidden** app all raised their target, every time. The finding below is about an accessory app
  activating **itself**, where nothing yields to a status-item click; `NSRunningApplication.activate`
  is a different call, and the target is not being asked to give anything up.
- **`NSApp.activate()` cannot activate an accessory app, and it is the call the compiler steers you
  to.** Since macOS 14 it is a *cooperative* request — the header says the framework "does not
  guarantee that the app will be activated at all", and that the other app should call
  `yieldActivation(to:)` **first**. Nothing yields to a status-item click, so the settings window
  arrives on screen, correctly drawn, behind the user's frontmost app and without key focus: the
  toggles work, the window looks dead, and Escape does nothing because the keystrokes are going
  somewhere else. Measured in Isleta on macOS 27.0, one second after clicking "Open Isleta
  Settings" with Chrome frontmost — `activate()` gives `isActive=false, frontmost=Chrome,
  keyWindow=none`; `activate(ignoringOtherApps: true)` gives `isActive=true, frontmost=Isleta,
  keyWindow=General`. A six-variant probe killed the plausible alternatives: activating on the next
  runloop pass, `orderFrontRegardless()`, and
  `NSRunningApplication.current.activate(.activateAllWindows)` all leave the app inactive, and the
  first two put the window on screen anyway, so they look like they worked until you notice the
  title bar. `activateIgnoringOtherApps:` is annotated `API_TO_BE_DEPRECATED`, not deprecated, and
  raises no warning under `-warnings-as-errors`. The island panel is **not** involved — a probe
  standing up a faithful `IslandPanel` copy activated fine either way.
- **`System Events`' `frontmost` is not a usable observer for an `LSUIElement` app.** It reported
  the *other* app frontmost in runs where the app itself measured `NSApp.isActive == true`,
  `isKeyWindow == true` and `NSWorkspace.frontmostApplication` as itself. Chasing activation from
  AppleScript therefore produces a convincing false negative and hides a fix that is already
  working. Instrument the app and read `NSApp.isActive`.
- **`setContentSize` holds the frame's *top-left*, so a window built at `.zero` and grown to its
  fitting size never has origin `.zero` again** — measured at about `-623` in y, with x left at 0.
  An `if frame.origin == .zero { center() }` first-run guard is therefore dead code that reads as
  live, and AppKit constrains the off-screen frame back onto the display, so the window opens flush
  against the left edge and low rather than obviously nowhere. **It only moves once the window has a
  `contentViewController`** — a bare `NSWindow` grown identically keeps its origin at `.zero`
  exactly, so the two-line disproof passes and says the guard was fine. Ask
  `setFrameUsingName(_:)`, whose `false` means "nothing was ever saved". One drag fixes the window
  for good on any given Mac, which is why this survived to 1.0.1: it is invisible to anyone who has
  opened Settings once.
- **A key equivalent on a status-item menu is not a shortcut.** An `.accessory` app installs no menu
  bar, so nothing dispatches it unless that menu is already open — at which point the pointer is on
  the item. It draws a ⌘-glyph promising a global shortcut, and ⌘, goes to whichever app is actually
  frontmost, opening *its* settings.
- **Assigning `NSWindow.collectionBehavior` to suppress full screen makes the window never appear.**
  Both `= [.fullScreenNone]` and `= [.managed, .fullScreenNone]` leave `makeKeyAndOrderFront` running
  to completion and `isVisible` true, with nothing on screen — no warning, no exception, nothing in
  the log. `.insert(.fullScreenNone)` fails the same way, because the default behavior it joins
  already carries a conflicting full-screen flag. Verified twice on macOS 27.0 by building and
  launching. The symptom is indistinguishable from the window having been broken by whatever else
  changed in the same build, which is what makes it expensive. See `SettingsWindowController`.
- **`NavigationSplitView` on macOS hosts its sidebar toggle *inside the sidebar's* title bar, so
  collapsing the sidebar hides the control that reopens it — and SwiftUI answers by adding a second
  toggle, a double chevron, in the detail pane.** Both exist during the transition, in different
  places, and the collapse visibly stalls between them while the title bar is relaid out. It reads
  as a broken animation; it is two controls for one state. Remove the toggle with
  `.toolbar(removing: .sidebarToggle)` and pin `columnVisibility` if the sidebar has no reason to
  collapse — which, in a settings window, it does not.
- **`.toolbar(removing:)` must go on the *column's content*, not on the `NavigationSplitView`.** The
  toggle is contributed by the column's own toolbar. Applied to the split view the modifier compiles,
  runs, and removes nothing — a full build-and-look to notice, twice if you assume the API is broken
  rather than misplaced.
- **`SMAppService.mainApp.status` answers `.notFound` for an app that has simply never been
  registered — it is the state of every fresh install, and it does not mean the copy is unsigned.**
  The header's wording for it ("an error occurred and no such service could be found") invites the
  opposite reading, and a debug build appears to confirm it, so 1.0.0 mapped `.notFound` to
  "unavailable — this copy of Isleta is not code signed" and drew the switch grayed out. That is
  exactly backwards: the switch was dead for precisely the users who had never used it, and live only
  for those who had. Measured on macOS 27.0 with two probe apps — one Developer ID signed and
  notarized in `/Applications`, one ad-hoc signed run from a scratch directory. **Both** reported
  `.notFound` before their first `register()`, **both** registered successfully, and both then
  reported `.notRegistered` after `unregister()`. So the two "off" answers differ only by whether a
  Background Task Management record has ever existed, and no status value on this OS reports a
  signature problem at all — only `register()` can, with `kSMErrorInvalidSignature` (3). Treat both
  as off, keep the switch live, and say something only when the attempt fails. The reason this is
  worth a probe rather than a guess: on the developer's own machine the app has been registered at
  some point, so it reads `.notRegistered` and the bug is invisible. See `LaunchAtLogin`.
- **Outside a `Form`, SwiftUI's default `Toggle` style on macOS is a checkbox, not a switch.** `Form`
  substitutes switches quietly, so replacing a `Form` with custom containers silently turns every
  switch in an app into a tick box. Both work and both read as "on"; a checkbox says "include this in
  something" and a switch says "this is running now". Set `.toggleStyle(.switch)` once on the
  container.
- **Inside the island's hosting view, a SwiftUI clip does not contain scrolled content — and a
  shape in the same container at the same moment is clipped perfectly.** Every mechanism was tried
  against a list scrolled by an offset: `.clipped()`, `.clipShape(_:)`, `.mask(_:)`,
  `.compositingGroup()` ahead of a clip, and `.drawingGroup()`; with the offset applied to the
  container and applied to a child inside it; with `.position` instead of `.offset`; and with the
  island's own ancestor `.mask(IslandShape…)` present and removed. All nine combinations drew rows
  straight over the "Notifications" header and its two buttons. What settled it was a control — a
  plain `Rectangle` overflowing the *same* container by the same amount in the same frame was
  clipped exactly — so the container was never wrong and the modifiers were never ignored; text,
  images and buttons here simply end up beyond a clip's reach. **Use a `ScrollView` with
  `.scrollDisabled(true)`**, driven by `.scrollPosition(_:)` from our own offset: its clipping is
  structural rather than a request. Measured on the notification recents drawer, which went with
  notifications; the rule is about `NSHostingView` inside the island's panel and applies to the next
  scrolled surface drawn there. Two hours, and the tests
  passed the whole way through — the arithmetic was right from the first version, so nothing but a
  screenshot could see it.
- **"Is this path on a mounted volume" cannot be answered by prefix-matching `mountedVolumeURLs`,
  and the version that can't reads as though it can.** Measured 2026-08-23 while building the drop
  history. The structural rule — *a path is on a mounted volume when some mounted volume's path is a
  component prefix of it* — compiles, reads correctly, and answers **mounted for every path on the
  machine**: `/` is always in `mountedVolumeURLs` and `/` is a prefix of everything, an absent
  `/Volumes/Backup` included. So every file on a disconnected disk is reported as *deleted*, which is
  the exact question the function was written to get right. Name `/Volumes` explicitly instead: a
  path under `/Volumes/<name>` is present iff that mount point is itself mounted, and everything else
  is on the boot volume, which cannot be absent while the process runs. Compare **component-wise**,
  or a mounted `/Volumes/Backup` answers for `/Volumes/Backup2`. The distinction is worth the care —
  deleted and *your disk is unplugged* are indistinguishable at the filesystem and are completely
  different things to tell somebody about their own files.
- **`bookmarkDataIsStale` fires on an ordinary rename in place, with a URL that resolves correctly
  to the new name.** Measured 2026-08-23 while building the shelf's persistence. Reading it as death
  marks every file the user has since renamed — the exact case bookmarks exist for — as missing.
  Deletion is the different answer: it throws `NSCocoaErrorDomain` 4. So `isStale` means "renew this
  bookmark", never "this file is gone".
- **Security-scoped bookmarks work in an unsandboxed app and are the more portable form.** 872 bytes
  against 1172 for a plain one, and — the part that decides the design — a scoped bookmark resolves
  **with or without** `.withSecurityScope`, while a plain one resolved *with* it throws 259. So write
  scoped and read with no options: one code path, and no per-item flag recording which kind it was.
- **`QLPreviewPanel` makes an accessory app the active app for the life of the preview, and there is
  no way round it.** It is Apple's panel, it needs key status, and it refuses to open unless
  something in the *key window's* responder chain accepts control — which for an app whose only
  window refuses key is nobody. `IslandPanel` is untouched and still refuses key; the cost lands on
  the user's frontmost app, which loses key while the preview is up. `yieldActivation(to:)` hands it
  back and is cooperative, therefore best-effort. It is the same trade Finder's space-bar preview
  makes, and it is a different mechanism from `acceptsKeyboardInput` above — do not conflate them.
- **A `@MainActor` type cannot directly satisfy `CLLocationManagerDelegate` under Swift 6**
  (`#ConformanceIsolation`). The delegate methods are `nonisolated` with `MainActor.assumeIsolated`,
  and that is sound **because CoreLocation delivers on the run loop its manager was created on** —
  explicitly unlike `IOBluetooth`, which delivers on CoreBluetooth's XPC queue and takes SIGTRAP for
  exactly this shortcut. The two look identical in the source and are not.
- **`NSImage.cgImage(forProposedRect:context:hints:)` ignores the rect you hand it.** It is a
  *representation picker*, not a resize: asked for 128×128, the same call in the same run returned
  Calendar's icon at 128 and Finder's at 256. Nothing warns, and both images draw correctly — what
  changes silently is the memory, 64 KB against 1 MB for a 512px rep, so a cache sized in megabytes
  is sized against whichever apps happened to notify the user. Draw into a `CGContext` of the size
  you actually want. See `ApplicationIconResolver.icon(atApplicationURL:)`, and note the first such
  draw costs **68 ms** because it is where IconServices finally rasterises — four frames, on the
  frame the island arrives.
- **A formatter declared on a `View` is `@MainActor`, and only fails at the test that calls it.**
  `View` conformance is main-actor isolated, so a `static func format(_:) -> String` on one is too.
  Nothing complains until a synchronous nonisolated test calls it, and then it is an error rather
  than a warning under `Tools/check.sh`'s `-warnings-as-errors`. Pure formatting belongs on a plain
  `enum`.
- **A `safeAreaInset` header does not stop the content scrolling under it, and neither of the two
  APIs for that does anything to a `NavigationSplitView` sidebar.** The settings sidebar's icon and
  version number are a `.safeAreaInset(edge: .top)` on the pane `List`, which places them *outside*
  the scrolling region — so the rows slide underneath and draw straight through the words, which
  reads as a rendering fault rather than as a header. `.scrollEdgeEffectStyle(.soft, for: .top)` is
  the macOS 26 API for exactly this; it exists in the 26.5 SDK, compiles, raises no warning and
  changes nothing here. `.defaultScrollAnchor(.bottom)` is equally inert on the same `List`. Verified
  on macOS 27.0 by shortening the window until the sidebar genuinely scrolls. The fix is an explicit
  `.ultraThinMaterial` behind the header, masked to fade out **below** the version number rather than
  across it — the first attempt faded over the text and left a legible ghost on its baseline.

  **Both materials were removed on 2026-08-28 and the API finding above still stands.** The sidebar's
  went because four rows under a 560pt minimum height cannot scroll, so there was never anything to
  slide under it; the detail column's went with the `navigationTitle` it was covering for. What
  replaced the detail one is an *opaque* header (`SettingsView.paneHeader`), because the material was
  the bug in the second half of this entry. If a fifth pane or a smaller minimum height brings the
  sidebar's scrolling back, use `SettingsPalette.chrome`, not a material — and do not reach for
  `.scrollEdgeEffectStyle` a third time.
- **`.scrollEdgeEffectStyle` is inert on the settings *detail* `ScrollView` too, and the fix there has
  to reach over the title bar.** Same failure one column across: the window is `.fullSizeContentView`
  with a transparent title bar, so the detail pane scrolls to the window's top edge and the pane title
  `navigationTitle` draws in the title bar has nothing behind it — scroll the Appearance pane and
  "Island width" passes straight through "Appearance". `.scrollEdgeEffectStyle(.soft, for: .top)`
  compiles and changes nothing, verified on macOS 27.0 by building it and comparing scrolled shots
  with and without. So a second explicit material, and two things it taught:
  - **The ramp is the `safeAreaInset`'s own height, and the material reaches past it with
    `ignoresSafeArea(edges: .top)`.** The inset comes from the content's laid-out height, so a
    ramp-tall inset means the first card starts below the fade and nothing interactive is ever under
    it — which is how this avoids the swallowed-click bug the sidebar's version caused, without
    `.allowsHitTesting(false)`.
  - **Fixing one column exposes the other.** Once the detail's material ran to the window's top edge
    and the sidebar's still stopped at the title bar, the two met at the divider in different tones —
    a visible step in the sidebar's top-right corner. `identityBackdrop` needed the same
    `ignoresSafeArea`, and its mask had to change from a fraction of the header to a fixed ramp at
    the bottom, because the measured height now includes a title bar whose height is not ours.
  - **And the material was the wrong surface all along.** `.ultraThinMaterial` samples what is behind
    it and resolves toward the system's neutral, so on a window whose backdrop is a teal gradient
    both bands came out gray — a gray bar across the top of a tinted window, reported as exactly
    that. An opaque fill mixed from the app icon's own colors cannot drift, because there is nothing
    behind it to sample. `SettingsView.paneHeader` is the replacement and `SettingsPalette.chrome` is
    its fill; the `ignoresSafeArea` and safe-area-inset arrangement above carried over unchanged,
    which is the half of this entry that was right.
- **`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are `NSRect?` in Swift**, nil on displays with
  no notch, despite the header describing them as empty rects.

## Under Hardened Runtime a protected resource is refused silently, and it looks exactly like a missing usage string

Measured 2026-08-24 against the shipped 2.0.0 build, which had `ENABLE_HARDENED_RUNTIME = YES` and
neither `com.apple.security.personal-information.calendars` nor `…location`.

`EKEventStore.requestFullAccessToEvents` answered **`granted=false` with a nil error in 50 ms**, no
dialog appeared, the status stayed `notDetermined`, and **tccd's own log never mentioned Isleta at
all**. `CLLocationManager.requestWhenInUseAuthorization()` failed identically, with `locationd`
equally silent. The request is not refused by the daemon — it never reaches it.

**That is indistinguishable from a missing usage string**, and the usage strings were correct in
`Config/Isleta-Info.plist` the whole time. A usage string says *why* the app wants a resource; these
entitlements say the app is **allowed to ask**. Both are required, and only one of them fails loudly.

The control that settled it: an ad-hoc probe with the same usage string and **no hardened runtime**
prompted and was granted in 2.4 s, from three different bundle identifiers — including one carrying
Isleta's own. So it was neither the machine, nor the bundle identity, nor TCC's records.

Three hypotheses were tested and disproved on the way, each of which looked right:

- **EventKit store ordering** — that touching the store while `notDetermined` poisons the request. A
  probe that read `sources`, `calendars` and `events` first still prompted and was granted.
- **Poisoned TCC rows.** `tccutil reset Calendar com.tryisleta.isleta` reported success **eight
  times** — one row per distinct signature installed that day — but resetting them changed nothing.
- **A stale LaunchServices view of `/Applications/Isleta.app`**, left by 1.3.1, which genuinely has
  no calendar usage key. Re-registering changed nothing.

**The cheap check that would have found it first is the one this file already prescribes: read the
daemon's log, not your own.** tccd's silence was visible early and was read as "no record" when it
meant "no arrival" — and a request that never arrives is a fact about the caller's entitlements, not
about the daemon's records.

The entitlements are `com.apple.security.*`, so they are consumed by the sandbox and the hardened
runtime rather than by AMFI: unlike `com.apple.developer.weatherkit`, they need no
provisioning-profile authorisation and cannot cause the exit-137 abort.

**`Tools/check.sh` structurally cannot see this.** It builds Debug and unsigned, and an entitlement
problem only exists in a signed Release build. That is now twice in one night that a Release-only
failure passed a green check — the other being `PROVISIONING_PROFILE_SPECIFIER` reaching SwiftPM's
generated resource-bundle targets.



## A closure passed to a non-`@Sendable` callback parameter inherits `@MainActor`, and traps when the callback fires off the main queue

Measured 2026-08-25 against the shipped 2.0.0 build, from two crash reports of a real download.
**The source this was found in is gone** — downloads were withdrawn on 2026-08-28 — and the entry
stays because the trap is about Swift's isolation inference and dispatch, not about that source. It
is live for the next handler registered on any queue that is not `.main`.

`DownloadFolderWatcher` was `@MainActor`, and registered its vnode handlers like this:

```swift
source.setEventHandler { [weak self] in                     // <- inherits @MainActor
    DispatchQueue.main.async { MainActor.assumeIsolated { self?.rescan() } }
}
```

`DispatchSourceHandler` is a bare `@convention(block) () -> Void` with no `NS_SWIFT_SENDABLE`, so it
imports **non-`Sendable`** — and a non-`Sendable` closure literal written inside an isolated type
*inherits that type's isolation*. The compiler then plants a runtime isolation precondition at the
closure's entry. The source was created with `queue: queue`, a private utility queue, so the first
vnode event ran the precondition off the main actor and the process took `EXC_BREAKPOINT` /
`SIGTRAP` in `swift_task_isCurrentExecutorWithFlags → dispatch_assert_queue`.

**The body was already correct.** It hops to main and asserts isolation there. The trap is in the
prologue the compiler wrote, before a line of it runs — which is why reading the closure tells you
nothing.

The fix is to say the closure is not isolated:

```swift
source.setEventHandler { @Sendable [weak self] in … }
```

**Why every other source in `IslandSources` survived this.** The other five `setEventHandler` sites —
`TimerSource` ×2, `CalendarSource` ×2, `WeatherSource` — all pass `queue: .main`, so their inherited
precondition passes and is invisible. Only the download watcher delivered on a private queue, because
its `open(2)` could block behind a TCC dialog. **The isolation is inherited everywhere; only the queue
decides whether it kills you** — which is why this outlives the one site that proved it.

The three `AudioObjectAddPropertyListenerBlock` sites — `SystemHUDAudioObserver`,
`CoreAudioOutputRouting`, `CoreAudioCallObserver` — *are* `@MainActor` and *do* register on private
queues, and are nonetheless clean. Verified in the disassembly rather than by reading: none of the
three block bodies calls the check.

**How to check a suspect closure without waiting for it to crash.** The precondition is a call to
the `_swift_task_isCurrentExecutor` stub, and the mangled name says whether the closure is
`@Sendable` — `yyYbcfU_` has it, `yycfU_` does not:

```sh
BIN=…/IslandSourcesPackageTests.xctest/Contents/MacOS/IslandSourcesPackageTests
STUB=$(otool -Iv "$BIN" | awk '/_swift_task_isCurrentExecutor$/{print $1; exit}')
objdump -d --disassemble-symbols="<mangled closure>" "$BIN" | grep "bl.*${STUB#0x0000000000}"
```

A hit inside a `…ScMYc…` (MainActor) frame is the legitimate `assumeIsolated`. A hit in the handler
closure itself is this bug.

**Why 1,801 tests missed it.** Everything covering that source tested the pure pieces — the flavor,
the reading, the name — and nothing ever built a real dispatch source and let the kernel call back
into it. A test that called `rescan()` directly, or substituted a fake source, passes against the
crashing build. The fix was a live test that drove a real folder on disk and died with signal 5 if it
regressed. That test went with the feature, and the rule it was written for did not: **a source whose
handler runs on a private queue needs a test that lets the kernel invoke it.**

## A probe that finds nothing has to be able to find something

Two method failures on 2026-08-25 each produced a *confident wrong answer* about the lock screen and
each went into the docs before it was caught. Both are general, so they live here rather than in
`docs/PLATFORM-CONSTRAINTS.md`.

**A probe with no positive control cannot distinguish "impossible" from "we did it wrong."** Ten
arms swept every window level, space and collection behavior; every one failed; the unlocked
baseline was healthy; the conclusion — *the lock screen is closed* — was written into four files. It
was wrong. Installing a competitor that already does the thing, and putting it in the same window
stack as the arms, inverted the finding in twenty minutes. **Before concluding that something cannot
be done, find something that already does it and measure that alongside.** If nothing does it, say
so — "no existing app does this and neither could we" is a much weaker claim than "impossible", and
it is the honest one.

**A readback that disagrees with what you set is data, not a broken instrument.** Run 1 asked
`SLSSpaceSetAbsoluteLevel` for `Int32.max` and `SLSSpaceGetAbsoluteLevel` answered **0**. The note
written at the time called the getter unreliable and moved on. It was not unreliable — `Int32.max` is
not a valid space absolute level, the setter had silently failed, and thirteen runs later the correct
value (400) arriving from someone else's source was the answer to the whole investigation. This is
the mirror image of the warning that dominates `docs/PLATFORM-CONSTRAINTS.md`: yes, most of this
platform reports success and does nothing — but the reflex that produces ("distrust the return
value") turns into a way to discard findings when the return value is the one thing telling you the
truth. **Measure the effect, and when a readback contradicts the write, that contradiction is the
effect.**

**Apply the same test to the control and to the subject.** For six runs the competitor was judged by
its position in `CGWindowListCopyWindowInfo`'s z-order while our own windows were judged by
`NSWindow.windowNumber(at:)`. Two standards, so the comparison was not one — and the mismatch hid
that the second test answers a different question entirely (*would a click land*, not *is it
painted*). It survived six runs because it always confirmed what was expected. **A measurement that
only ever agrees with you is not being used as a measurement.**

The corollary for this codebase: `windowNumber(at:)` is the right instrument for
`PassThroughSelfTest` and `ClickSelfTest`, which genuinely ask about hit testing. It is the **wrong**
instrument for any question about whether something is *drawn*, because a window can be composited
and still lose every event — which is exactly what the lock screen does to everybody.
