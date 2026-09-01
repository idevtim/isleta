# IslandSources

Every route to system state, each behind a protocol with a working fallback and a null conformance.

`ActivitySource` is the shared lifecycle every source in here conforms to, written before any of them
so four sources built in parallel share one shape. It is a **push** interface, not a pull one: §9
forbids polling on the idle path, and a getter is the thing a caller eventually puts in a timer.
`SourceAuthorization` is a value rather than a `Bool` so "denied" and "not asked yet" cannot collapse
into one case — they read identically to code and mean opposite things to a user, who is owed a
prompt in one and an explanation in the other.

## Owns

- **`NowPlayingProvider`** (§2.4) — **implemented.** Three conformances behind one push-only
  protocol, and `NowPlayingSource` republishes whichever is live as a `BuiltInActivity.nowPlaying`
  under one stable `ActivityID`, so a track change crossfades instead of reopening the island.

  - **`NowPlayingAdapterProvider`** — the vendored `ungive/mediaremote-adapter`, spawning
    `/usr/bin/perl` on its `stream` command and merging the diff payloads it prints. Since macOS
    15.4 `mediaremoted` answers `MRMediaRemoteGetNowPlayingInfo` only for callers whose
    code-signing identifier begins `com.apple.`, and Apple's Perl reports `com.apple.perl` — it
    holds **no entitlement**, so re-signing it, copying it into the bundle, or pointing at a
    Homebrew Perl all produce an interpreter that gets refused. `perlExecutable` is therefore a
    constant, not a setting. **Vendored and verified on hardware as of 2026-08-19** — see
    `Vendor/mediaremote-adapter/README.md`. `stream` is run `--no-artwork --micros`: the first is
    the memory budget, the second is the scrub bar's precision, because without it `timestamp`
    serializes as an ISO-8601 string rounded to the whole second and the playhead's anchor steps.
    It also carries `--queue --length=5` — the Up Next sneak peek, folded into the helper that is
    already running rather than spawned per track change. That option is Isleta's own addition to
    the vendored source and is marked as such; see `NowPlayingUpNext` below.
  - **`NowPlayingScriptProvider`** — the per-app fallback, and *not* an AppleScript poll. Live
    updates ride the `playerInfo` distributed notifications Music and Spotify post themselves: no
    permission, no polling. AppleScript is used only for the one-shot read at start, because the
    notification fires on change. Music posts every event twice (under its own name and iTunes'),
    so `NowPlayingScriptState` de-duplicates and decides which of several talking players owns the
    island.
  - **`NullNowPlayingProvider`** — publishes nothing at all, deliberately not a placeholder
    activity: one would sit at `.ambient` forever and the island could never reach `.rest`.

- **`NowPlayingTransport`** (§2.4) — sending commands *to* the player, which is a separate protocol
  from reading it because the two capabilities do not travel together on the same machine. The
  scripting route reads perfectly with nothing granted and can control nothing without an Automation
  grant; the adapter does both with neither. `NowPlayingAdapterTransport` spawns one short-lived
  `perl` per command (`send <MRCommand>`, `seek <microseconds>`), capped at four in flight and
  SIGKILLed after five seconds, and retires itself if one fails to launch.
  `NowPlayingUnavailableTransport` reports `isAvailable == false`, which draws *no* transport row —
  different from a dimmed one, which would advertise a feature this build does not have.

  Two commands are on the protocol rather than in `NowPlayingCommand`, because neither is "an id
  with nil options". `playQueueItem(atOffset:contentItemIdentifier:)` needs a userInfo dictionary,
  and `setLiked(_:)` is a *pair* of ids chosen from the state being asked for — like (106) and ban
  (107), both newly whitelisted in the fork. **The like is drawn from `supportsIsLiked` and never
  from `isLiked`**: the second is the state of a control the first decides the existence of, and a
  track nobody has liked yet reports zero for it while being perfectly likeable. Measured on macOS
  27.0 against a local Music library track, **neither key is in the payload at all** — so the
  honest drawing there is a heart that is dimmed and inert. Note that this limit, `prohibitsSkip`
  and the radio-station limit are mutually unrelated: answering any two of them with one flag grays
  the wrong control in each direction.

- **`NowPlayingOutputRouting`** — the **system** audio output device, through public CoreAudio, and
  deliberately not part of the Now Playing source: it is a fact about the machine rather than about
  the player, needs no adapter, no helper and no permission, and stays true when Now Playing is
  switched off. `CoreAudioOutputRouting` enumerates `kAudioHardwarePropertyDevices`, filters to
  devices with output channels, and listens on the device list and the default output — push, never
  a poll. `AudioObjectHasProperty` gates every listener, because one registered for a property the
  object does not have returns `noErr` and never fires.

  **`AudioObjectSetPropertyData` returns `noErr` for writes it refuses** — measured against a
  device id naming nothing, a real input-only device and `kAudioObjectUnknown`, all three answered
  `noErr` and left the default untouched, and `AudioObjectIsPropertySettable` answers `true`
  throughout. So `select(_:)` verifies by reading back, which is this codebase's rule everywhere
  (`AXUIElementPerformAction`, `SLSSetWindowAlpha`, `MRCommand`).

  **This is not AirPlay routing inside Music**, and the distinction is the honest one to draw: what
  ships changes where *the Mac's* audio comes out. Music's own AirPlay picker routes only that app,
  and no reachable API for it was found — the vendored `MediaRemote.h` declares route *notification*
  and user-info key names with no picker, enumerate or select function beside them, and
  `AVAudioSession` is absent from the macOS surface.

- **`NowPlayingArtworkLoader`** — the cover, fetched once per track by a separate `get`, decoded to a
  256px thumbnail off the main thread, and retained one at a time. See "Deliberately does not own"
  for the measurement that forced the split.

- **`NowPlayingUpNext`** — the track that comes after this one, and nothing else about the queue.
  `NowPlayingQueueWindow` is the pure parse and the whole of the rule is one number: **index 0 of
  the window is the current track, so index 1 is the next song.** The queue MediaRemote vends *is*
  Up Next — played items are dropped from it — and `isCurrentlyPlaying`, the field named after the
  question, answers 0 on every item including the one that is playing. Measured on macOS 27.0.

  It reaches this package as a second line type on the adapter's stream
  (`{"type":"queue","queueItems":[…]}`), which is why `stream` is now run `--queue --length=5`. A
  one-shot `perl … queue` costs 60-360 ms, of which the read is 15-30 — the spawn dominates — so
  asking per track change would be a process per skip; the streaming helper is already alive and is
  already registered for the notification that carries this, so the peek is **one extra MediaRemote
  request per track change and no timer anywhere.**

  It is on `NowPlayingSnapshot` because it passes that type's own stated test: the next track is
  true until something changes, and the player posts a notification when it does. **One item, not
  the array** — the snapshot is `Equatable` and is compared on every pause, seek and rate change,
  so the full window travels on its own channel instead. See `NowPlayingQueueItem` below.

- **`NowPlayingQueueItem` and `NowPlayingQueuePaging`** — the whole window, for the scrolling Up
  Next surface, on `NowPlayingSource.onQueue` rather than on the snapshot. Three reasons and each
  rules out the obvious alternative: it is not content (`ActivityContent` has no vocabulary for a
  list, and inventing one gives every other activity a field it cannot use), it is not snapshot
  state (forty rows compared on every scrub), and it arrives on its own line at its own cadence.

  **The window is asked for, not fetched.** `+defaultPlaybackQueueRequest` asks for the whole
  queue and a library on shuffle is tens of thousands of entries, so `NowPlayingQueuePaging` asks
  for what is on screen plus a page (`restingWindow` 5 → `lookahead` 10, ceiling 100) and again as
  the reader scrolls. An ask that is not *wider* than the last is suppressed —
  a scroll produces a sample per frame, and without that a single flick would be sixty MediaRemote
  round trips inside the helper that is also delivering track changes.

  **How the ask reaches the helper is the fork's control channel, not a spawn.** `stream --queue`
  now reads lines on stdin: `length N` re-asks with a new window, a bare `queue` re-asks with the
  current one, anything else is ignored, and **end of file is not a reason to stop**. So the
  helper's stdin is a `Pipe` in `NowPlayingAdapterReader` where it was `/dev/null` — which does not
  undo the rule that put it there: that rule is about an *inherited* stdin handing the helper
  Isleta's controlling terminal, where a Perl reading from a terminal it does not own takes SIGTTIN
  and stops. A pipe is not a terminal and cannot do that.

  **Playing an entry is `PlayItemInPlaybackQueue (131)` with the offset *and* the content-item id.**
  Measured on macOS 27.0 against a live Music queue: `kMRPlay (0)` and `SetPlaybackQueue (122)`
  with the offset both return `1` and change nothing, and the plural spelling of the content-item
  key is inert. Verified by reading the queue back, never by the return value. It needed two things
  in the vendored adapter, and only one of them is the whitelist: `adapter_send` called
  `sendCommand(value, nil)` with the userInfo **hardcoded**, so no queue command was expressible
  even with its id allowed.

  Two things the decoder does with it that are not obvious. A queue line arriving before any track
  has been reported is **silence, not a verdict** — the initial read is issued alongside the first
  state request rather than after it, and on this machine it genuinely arrives first, where
  resolving it as a snapshot would mean `.cleared` and an island taken away. And when the queue and
  the payload both name a `contentItemIdentifier` and the two **disagree**, the peek is withheld:
  the two notifications fire in the same millisecond and nothing orders the two lines, so for a few
  milliseconds after a skip one of them is describing the previous track. Where either side names no
  identifier there is nothing to check against and the queue is believed, because most players
  report none at all.

  **When it is shown is not this package’s business.** `NowPlayingUpNextPeek` (IslandUI) answers
  that against the display link IslandUI is already running — `duration - position(now) < 10` —
  because the trigger is a function of an instant and scheduling it would be a timer per track,
  re-armed on every seek.

  **The UI is fully functional with any of the three.** With Automation refused the scripting route
  still streams, so `authorization` stays `.notRequired` and the refusal is reported separately as
  `initialReadAuthorization` — reporting it as `.denied` would make `isUsable` false and invite a
  caller to skip a route that works, trading the whole feature for the tenth of it the permission
  governs.
- **`SystemEventsSource`** (§2.5) — the wake/unlock "Welcome Back" moment, and the one source with
  `SourceAuthorization.notRequired`: it needs nothing granted, so it is the source that proves the
  whole source → coordinator → island path on a machine where the user has denied everything.

  It observes six notifications on two different centers — `willSleep`, `didWake`,
  `screensDidSleep`, `screensDidWake` on `NSWorkspace.shared.notificationCenter`, and
  `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` on `DistributedNotificationCenter`
  (posted by `loginwindow`; there is no SDK constant for either, so they are string literals).
  Observers are stored paired with the center that issued them, because a token returned to the
  wrong center removes nothing and reports nothing.

  **The decision is a pure value.** `WelcomeBackPolicy` turns a stream of `SystemEvent`s and a
  `ContinuousClock` reading into at most one greeting per absence, with no AppKit and no clock of
  its own — which is what makes the whole §2.5 matrix (wake without unlock, unlock without wake,
  both in either order, repeated unlocks, a five-second screensaver blip, a Power Nap wake) a set of
  tests rather than an evening spent closing a lid. Presence is the conjunction of *system awake*,
  *displays lit* and *session unlocked*; an absence runs from the first event that breaks it to the
  first that restores it, and is greeted only past `defaultMinimumAbsence` (5 minutes). Notably
  `didWake` never lights the displays — a maintenance wake must not spend the greeting on an empty
  room — and an unlock always does, because nobody types a password into a dark screen.

  Absence is measured on `ContinuousClock` (the only clock that both survives system sleep and
  ignores wake-time resyncs) and the greeting is *phrased* from the wall clock, in the user's own
  `Calendar` and `Locale`. There are no timers: the 4-second dwell is `ActivityKind.welcomeBack`'s
  expiry, served by the coordinator's single scheduled sleep.

  This is a **wake/unlock moment and never a lock screen feature** — `loginwindow` is a separate
  secure context and Isleta draws nothing there. Nothing in the source, its tests, or its copy says
  otherwise.

- **`SystemHUDSource`** (§2.6 / §8.1.5) — **three levels, behind two switches, under one master.**

  `SystemHUD` is `.volume`, `.mute` and `.brightness`. `sources.volumeHUD` answers for the first two
  and `sources.displayBrightnessHUD` for the third, both under the `sources.systemHUDs` master. Each
  level is observed and none is polled. Which of them the source reports is `enabledHUDs`, written by
  the app shell from those switches, and it gates the **monitors** rather than the publishing: a
  level switched off leaves no CoreAudio property listener and no DisplayServices callback attached,
  because §9 measures the idle path and an observer nobody reads is the purest way to spend it.
  Assigning the set on a running source attaches and detaches only what moved, so switching
  brightness off does not re-baseline the volume — which would be silent and would cost the user the
  next HUD they asked for. The set is filtered at publish time as well, because one CoreAudio
  observer answers for both `.volume` and `.mute`.

  Volume and mute are observed through CoreAudio property listeners on the default output device
  (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and `kAudioDevicePropertyMute`, rebound
  when the default device changes). No permission, no helper process, no timer — the callback is the
  only thing that ever runs. Levels are watched rather than keys on purpose: an event tap on the
  volume keys would need Input Monitoring, would miss every change made from Control Center or a
  slider, and would fire for keys another app had already swallowed.

  Three things about CoreAudio are load-bearing and were measured, not assumed (macOS 27.0,
  26A5416b): the built-in output has **no** main-element `kAudioDevicePropertyVolumeScalar`, so
  `AudioObjectHasProperty` — not the status from `AudioObjectAddPropertyListenerBlock`, which returns
  `noErr` for properties that do not exist and then never fires — decides which address to use; one
  keypress delivers **eight** identical callbacks; and the mute listener fires on volume changes with
  mute unchanged. `SystemHUDLevelState` is the pure, CoreAudio-free value type that turns that stream
  into the HUDs worth showing, and it is where all of those rules are tested.

  **Display brightness ships since 2026-08-22, and the note that used to sit here was wrong.** It
  said macOS offered no public route to brightness on Apple Silicon *and* that nothing notifies on a
  change. The second clause was the one that mattered, and both are false.
  `DisplayServicesGetBrightness` reads the real user brightness, and
  `DisplayServicesRegisterForBrightnessChangeNotifications` pushes a callback on every change — 419
  callbacks across nine real key-holds, mean 1.94 ms to a correct re-read, and zero in the following
  45 s. No permission, no entitlement, nothing on the idle path. `DisplayBrightnessMonitor` owns
  that, as the package's second runtime-resolved private path, with `UnavailableBrightnessMonitor`
  as the fallback and the old "leave it to the system" behavior as what degrading looks like.

  **The ramp is the trap.** One key-hold is 27-78 callbacks over 0.5-1.4 s tracing the panel's
  easing, and their values all *differ*, so the equality dedupe that handles CoreAudio drops none of
  them. `SystemHUDBrightnessState` is the pure, DisplayServices-free value type that coalesces it:
  publish the first callback of a burst at once, throttle the rest to 100 ms. That interval was
  chosen by replaying the recorded session against candidates and measuring the error each leaves on
  screen; the table is in the file and the captured ramp is pinned in its tests.

  **The keyboard backlight is withdrawn, and its measurements are in "Will not own" below.**
  `KeyboardBrightnessMonitor` was the sixth private-framework path; it is deleted, along with
  `SystemHUDKeyboardBrightnessState`, `UnavailableKeyboardBrightnessMonitor` and the
  `keyboardBrightnessHUD` switch. The path never closed — what closed was the case for the feature.

  **Never drive a brightness probe with a synthesized media key.** They move the value by exactly
  zero on Apple Silicon, which is how the original measurement reached a confident wrong answer —
  its stimulus never fired, so every reading was of a value nothing had asked to move.

  **Isleta suppresses Apple's volume HUD, and that is new — 2026-08-30.** For the life of this file
  the entry here said it did not and could not. `SystemHUDSuppression` is now the mechanism as well
  as the record, and `suppressSystemHUDs` is a live setting again: removed in schema 4 as a switch
  that could never move, back in **schema 23** because the condition
  `docs/PLATFORM-CONSTRAINTS.md` set — *do not reintroduce the setting without a mechanism* — was
  finally met rather than forgotten.

  **`suppressible` is `[.volume, .mute]`, and brightness is deliberately not in it.** That is a
  scope line, not a limitation: `DisplayServicesSetBrightness` does write the panel, so the route
  exists. A test pins the set, and it should fail loudly the day somebody adds `.brightness` without
  adding the ramp behind it.

  **Consuming the key was necessary and not sufficient.** `MediaKeyMonitor` in `.replace` swallows
  the volume keys and `SystemVolumeControl` and `VolumeStep` become the implementation of what those
  keys did — the notches, the ⇧⌥ quarter-notches, the auto-unmute and the feedback click, which is
  the cost this feature always had to pay and now pays. But the HUD still appeared, because
  **Isleta's own CoreAudio write wakes `OSDUIHelper`**. So suppression is also a `SIGSTOP` on that
  process.

  **That breaks the promise this section used to make, and the break was deliberate.** CLAUDE.md
  requires suppression to be restored on quit *and* on crash and uninstall; a `SIGSTOP` outlives the
  process that sent it. The rule was knowingly overridden by the owner on 2026-08-30.
  `SystemHUDSuppression.survivesProcessDeath` is therefore `true` — it read `false` for the life of
  the file — and `repairAtLaunch()` and a synchronous `resume()` are the mitigations built on that
  admission. The inverted test is the point: a mechanism that writes state outliving the process
  must say so, and flipping the flag back without removing the `SIGSTOP` would make every mitigation
  around it look unnecessary.

  **Off by default, and it needs the Accessibility grant.** Turning it on means Isleta becomes the
  implementation of the volume keys, and an app that does that to somebody who never asked has taken
  their volume keys away. Without the grant the tap receives nothing at all — a non-nil mach port and
  an empty stream, measured twice — so a Mac that has not granted Accessibility suppresses nothing
  however the setting reads.

  **The mechanisms that were weighed and refused** are still worth keeping, because each is the
  obvious next idea. `launchctl disable` and `bootout` both outlive the process by writing launchd's
  override database, so a crash leaves the user with no volume HUD and no idea which app took it —
  and unlike a `SIGSTOP`, nothing the app can repair at its next launch. Killing `OSDUIHelper` as it
  launches restores itself on the next keypress but races the HUD it is hiding, and a visible
  flicker is worse than the HUD. **`OSD.framework` only draws** — `OSDManager` is real and loads by
  path, and every method on it is a `show`; there is no hide.

- **`BluetoothDeviceSource`** — a Bluetooth audio device connecting, said once and briefly. The one
  source with **nothing on any path but its callback**: `IOBluetoothDevice.register(forConnectNotifications:)`
  is push and permission-free, the battery percentages are read inside that callback, and the
  activity retires itself four seconds later through `ActivityKind.deviceConnected.defaultExpiry`.
  There is no value to refresh because there is no window in which it could go stale, so its idle
  cost is exactly zero. That is the shape of the feature and not a compromise: a *persistent* battery
  readout would need polling, because the properties are not KVO-compliant (below), and §9 forbids
  one on the idle path.

  **The battery is the third private path, and it is SPI on a public framework rather than a private
  framework.** Everything about it was measured on macOS 27.0 against a connected AirPods Pro, and
  the measurements are in `BluetoothDeviceBattery` and `IOBluetoothDeviceMonitor` because each one
  contradicts something that looks true:

  - **There is no other route.** A sweep of the *entire* IORegistry for any key containing "battery"
    returns the Mac's own pack and nothing else — `AppleDeviceManagementHIDEventService`, which every
    guide points at, held only the internal keyboard. `system_profiler SPBluetoothDataType` does
    report the numbers, but it shells out, takes over a second, and reports battery for devices that
    are **not connected**, from a cache: it showed a pair of AirPods Pro at 100/100/93 while they
    were shut in their case.
  - **The two fields that read like the answer are both zero.** `batteryPercentCombined` and
    `isMultiBatteryDevice` each answered `0` in the same read where `batteryPercentLeft` and
    `batteryPercentRight` answered `100`. A UI built on the field whose name promises a summary
    draws an empty ring on a full battery.
  - **KVO on those properties registers successfully and never fires.** The values move underneath
    it — a poll watched the case percentage go 0→93 while KVO was silent on the same object. Same
    shape as the CoreAudio listener that returns `noErr` and observes nothing.
  - **The case percentage is not knowable in time.** It arrived 12.5 s after the connect notification
    on one connect and read 0 on the next, against an island that is on screen for four. It is
    deliberately not carried at all.
  - **One physical connect fires the notification three or four times**, including once at a BLE
    random address reporting a zero class of device and zero for every battery field.
  - **The callback does not arrive on the main queue.** It comes in on CoreBluetooth's XPC queue, so
    the `@objc` method is `nonisolated` and reads the device there, hopping only a `Sendable` value.
    An `@objc` method on a `@MainActor` class compiles clean and takes SIGTRAP the first time real
    hardware connects.

- **`CalendarSource`** — the day, and the two things it announces. One source publishing three
  kinds (`.glance`, `.calendarAlert`, `.meeting`) because all three come from **one fetch of one
  store**; the user's three switches gate what it publishes rather than how many stores are open.
  Behind `CalendarReading`, with `EventKitCalendarStore` as the route and `UnavailableCalendarStore`
  as the stub every decision in `GlancePolicy` is actually checked against.

  Four things about EventKit, each of which looks wrong the first time:

  - **A denied calendar is indistinguishable from a user who owns no calendars.** Measured:
    `sources.count == 0`, `calendars(for:).count == 0`, `defaultCalendarForNewEvents == nil`, the
    predicate builds fine, and `events(matching:)` returns `[]` in **1–4 ms without throwing**. No
    error, no exception, no flag. `EKEventStore.authorizationStatus(for:)` is the **only**
    discriminator there is, which is why every empty-state sentence in this feature is chosen from
    `CalendarAccess` and never from `events.isEmpty`.
  - **The missing usage key does not abort, and that is the trap.** With no calendar key in the
    Info.plist, `requestFullAccessToEvents` answers `granted=false, err=nil` in **9 ms**, raises no
    prompt, logs nothing, and leaves the status at `notDetermined` rather than `denied`. A source
    that retried on `notDetermined` would ask forever, nine milliseconds at a time, and never
    advance. There is deliberately **no retry anywhere in this file**. Isleta ships
    `NSCalendarsFullAccessUsageDescription`: write-only access authorizes *saving* and returns no
    calendars to read.
  - **`.EKEventStoreChanged` fires twice for one edit**, 2,019 ms apart, 8–10 ms after each commit.
    Undeduplicated that is two full re-fetches and two islands for one thing the user did. Two
    mechanisms answer it, and the second is the one that holds: a leading edge with a short trailing
    window, and publication gated on the *snapshot* having changed. The second fetch produces an
    equal snapshot and publishes nothing.
  - **Every `EKEvent` held across that notification is invalid.** The objects are faults into a store
    that has just moved. Nothing outside `EventKitCalendarStore` has ever seen one — the predicate is
    re-run and `GlanceEvent` is rebuilt, which is also what makes the equality coalescer work.

  **Time passing announces itself to nobody**, and that is the one place this source has a timer. The
  obvious answer is a minute poll and §9 forbids one; instead `GlancePolicy.nextBoundary` names the
  next instant at which any answer could change, and one `DispatchSourceTimer` is armed at it and
  re-armed from its own handler — the shape `ActivityCoordinator` uses for the whole expiry model. An
  empty calendar has no boundary and therefore **no timer at all**.

- **`MeetingLinkParser`** — in IslandActivities, not here, because it is pure and is where the test
  value is. Measured over 33 real events: `url` **7/33**, `notes` **30/33**, `location` **8/33**, and
  every http(s) join link was in `notes`. So the parse order is `notes` → `url` → `location`, and an
  implementation that reads `event.url` first — the field named for it — finds a link in under a
  quarter of events. `EKEvent.conferenceURL` exists on the private ObjC surface, is exactly what you
  would reach for, and answered **nil on all 33**: a sixth private path with a measured payoff of
  zero, and it is not used. The `dialin.teams.microsoft.com` exclusion is part of the pattern set
  rather than a refinement of it — that host ends in `teams.microsoft.com`, sits *above* the real
  link in a real invitation, and opens a page of phone numbers.

- **`WeatherProvider`** — `WeatherKitProvider` and `UnavailableWeatherProvider`, the same shape as
  `NowPlayingProvider`/`NullProvider` and `BluetoothDeviceMonitoring`/`UnavailableBluetoothMonitor`.
  **Which one you get is decided by the signature, not by a setting.** `com.apple.developer.weatherkit`
  landed in `Config/Isleta.entitlements` on 2026-08-23 alongside `Config/Isleta.provisionprofile`,
  and the pairing is the rule: an app that claims an entitlement with no matching embedded profile is
  **SIGKILLed at `exec`** — exit 137, no stdout, no stderr, no `.ips` crash report, and `codesign`
  accepts the claim without a word. That is the 1.3.0 Bluetooth abort's shape again, and it is not
  WeatherKit-specific: an invented `com.tryisleta.nonsense` died identically.

  So a signed **Release** build is `weatherkit entitled` and has real weather, and a **Debug** build
  never can — an ad-hoc signature cannot carry a developer entitlement at all, which is why
  `Config/Isleta-Debug.entitlements` omits it and why `Tools/check.sh` is structurally unable to see
  a weather bug. `./Tools/release.sh --build-only` exists for exactly that gap.

  The failure without it does **not** look like a permission problem — it is
  `xpcConnectionFailed`, NSCocoaErrorDomain 4097, in 184–189 ms, which reads as broken XPC plumbing.
  `isAvailable` asks the *running task* for the entitlement (`SecTaskCopyValueForEntitlement`)
  rather than the bundle's plist, because the plist is what was asked for and the task is what was
  granted — and a process that is alive holding this entitlement is one whose profile validated.

- **`WeatherSource`** — **not an `ActivitySource`, and there is no `ActivityKind.weather`.** The
  island never announces the weather, it *contains* it: one card inside the glance. So it publishes a
  reading, and `CalendarSource` folds it into the snapshot, so the open island has one height decided
  by one publisher. It is the one thing in Isleta with no push signal of any kind — no notification,
  no callback, no bus — so §9's exception is taken literally: the refresh timer is armed **only while
  the glance is on the stage**, and never at all when the provider is unavailable.

- **`CitySearch`** — completions for a city being typed in Settings, through
  `MKLocalSearchCompleter` with `resultTypes = .address` and an `MKAddressFilter` that keeps the
  list to places rather than street addresses. **No permission of any kind**, which is the same
  property that makes a typed city a complete weather feature for somebody who has refused location
  rather than a degraded one — and the completer is deliberately given no region to bias against, so
  nothing here reads where the user is standing through a door marked "no permission required".

  Nothing runs between keystrokes: the completer is built on the first query and holds no timer, no
  subscription and no registered delegate in between. The debounce lives in `SettingsView`, which is
  the only layer that knows a keystroke happened. The subtlety is the delegate — a completer is a
  *stream*, and one round of it is wrapped into a single `async` answer, so exactly one continuation
  may be resumed and it must be resumed exactly once. `CoreLocationPlaceResolver.pending` guards the
  identical hazard.

- **`CoreLocationPlaceResolver`** — one `requestLocation()` per refresh, **not**
  `startMonitoringSignificantLocationChanges`, which fires on ~500 m of movement, registers a
  persistent client, and exists per its own header to relaunch apps in the background. Measured, a
  live `CLLocationManager` costs **0.0013 %** idle and a warm fix is **7 ms**, so the choice is about
  shape rather than cost. Two things worth knowing: **`.authorizedWhenInUse` does not exist on
  macOS** — the granted state is `.authorizedAlways` (raw 3), and Swift refuses to compile the
  comparison — and **location is not a TCC service**, so a missing usage string does not abort the
  way a missing Bluetooth one does; it just shows the user a prompt with no reason on it.
  Geocoding goes through **MapKit**, not `CLGeocoder`: that class and both of its methods are
  `API_DEPRECATED(… macos(10.9, 26.0))` in the 26.5 SDK, so under `Tools/check.sh`'s
  `-warnings-as-errors` they fail the build rather than warning. `MKGeocodingRequest` is equally
  public and equally permission-free, which is what keeps "type a city instead" a real answer.

- **File conversion and transcription, in a child process** — `FileConversionEngine`,
  `SpeechTranscription`, `FileActionWorker`, `FileActionRunner`, `FileActionOrphans`, `Subprocess`.
  The one thing here that is not permission-gated at all, and it is here for the other reason this
  package exists: it is the layer allowed to talk to the system. `IslandActivities.FileConversion`
  says what a conversion *is*; this performs it.

  **The child process is Isleta's own binary run again with `--file-worker`.** Not because a
  converter might wedge — though `qlmanage -t` never returns — but because of memory: measured peak
  `phys_footprint` deltas of **+182 MB** for AVIF, **+452 MB** for an H.264 downscale, +95 MB for a
  2,000-row spreadsheet, +84 MB for GIF. The video figure is *flat in duration*, so it is a fixed
  allocation in the scaler rather than a leak, and there is no file small enough to make it safe.
  §9's 60 MB is an **idle** figure, and the way it stays one is for that memory to belong to a
  process that ends when the work does. Re-exec rather than a vendored helper because every
  framework the routes need is already linked into this binary; a helper target would be a second
  executable to sign inside-out, notarize and keep in step, for code that is already here.

  Transcription is in the same child for a *different* measurement: in-process cost passes §9
  outright (23.9 MB peak, flat, 0.006 % idle afterwards), but `localspeechrecognition.xpc` settles
  at 53 MB after one run, **112 MB after four, and never shrinks**. `SpeechModels.endRetention()` —
  the API named for exactly this — did nothing measurable, and only the client exiting freed it.
  Isleta never exits. It needs **no permission and no usage string**, and
  `SFSpeechRecognizer.requestAuthorization` must never be called: it is the only thing in the area
  that needs the key, and adding it would put a Speech Recognition row in the user's System Settings
  for a feature that never asks.

  Two obligations come with the process boundary, and both are `NowPlayingAdapterReader`'s lessons
  applied: **`stopAndWait()` is synchronous through to the `waitpid`**, because
  `applicationWillTerminate` returns into `exit()` and teardown that is merely scheduled never
  happens; and **`FileActionOrphans` is the sweep sibling** for the path teardown cannot reach, a
  crash. That sweep's rule is sharper than the adapter's for one reason worth reading twice: a
  stranded worker and *the user's own running copy of Isleta* are the same executable, the same
  name, the same uid and both children of launchd, so the `--file-worker` flag is the only thing
  separating them. `FileActionOrphanTests` pins that first.

  **MP3 is not shipped.** macOS decodes it and will not encode it at any layer, and the honest
  export is a vendored `lame` — a single 0.35 MB LGPL binary with zero non-system dylibs, 206 ms for
  a 10 s file, following the `mediaremote-adapter` pattern exactly. Vendoring is permitted by the
  2026-08-23 decision; what it would owe is what this file already owes for the worker — synchronous
  teardown through to the `waitpid`, an orphan sweep sibling, and the signing and notarization of a
  second binary in the bundle. It is not in this stage, and the row simply is not offered rather
  than being drawn and refusing. MKV in is the same shape and needs an `ffmpeg` remux.

- **`PowerSource`** — the charger, the charge, and Low Power Mode, on the **specific** `notify(3)`
  keys. **Never `kIOPSNotifyAnyPowerSource`**: measured over 315 s idle, on AC, at 100 %, with
  nothing changing, the aggregate fired **5 times at exactly 60.003 s intervals** with a
  byte-identical snapshot each time — powerd's periodic refresh, and a source registered on it wakes
  once a minute forever for nothing. Every specific key fired **zero** times over the same window.
  `com.apple.system.powersources.percent` is real, is **in no SDK header** (grepped, not
  remembered), and is the one that carries the number the island draws.

  Three rules go with it. **Registration status is never evidence** — `notify_register_dispatch`
  returns OK for any string, verified against invented names — so a wrong key is indistinguishable
  from a quiet machine. **Coalesce and diff**: bursts of 3 callbacks in 39 ms are real, so the
  monitor debounces 100 ms and compares the whole `PowerState`, which is exactly the set of fields
  the island draws. And **three of the four values IOKit answers with are not durations** — −2.0
  unlimited, −1.0 unknown, 65535 the registry sentinel, and **0**, which both `Time to Empty` and
  `Time to Full Charge` read on AC at 100 %. `PowerTimeEstimate` owns that rule in one place because
  the failure is silent: "0 min left" on a full machine reads as a broken battery.

  Low Power Mode arrives on `NSProcessInfoPowerStateDidChange`, which is **posted on the global
  dispatch queue** — the IOBluetooth trap's shape — so the handler is nonisolated and hops.

  **The power-source dictionary carries `Hardware Serial Number`**, verified live among its
  seventeen keys. It never leaves `PowerSourceReader`: what comes out is a `PowerState`, which has no
  field a serial could reach, and nothing logs the dictionary or a key of it.

- **`CallSource`** / **`CallDetection`** — that a call is in progress, and for how long. The rest of
  the competitor's Calls feature cannot be built: `TUCallCenter` and `CXCallObserver` both
  instantiate, both answer every call made to them, and both return an empty array forever, because
  `com.apple.telephonyutilities.callservicesd` is held by FaceTime and by no third-party app
  (PROBES §7). What is ungated is `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
  — push, 105 ms behind a real capture — plus `kAudioHardwarePropertyProcessObjectList`, read **on
  that edge only** because enumerating 49 process objects costs 39 ms.

  **The process list on its own is not the signal, and this machine proved it while the file was
  being written**: read cold, with nobody talking to anybody, it reported `com.apple.CoreSpeech`
  running input — Siri's listener — while the device reported `isRunningSomewhere == 0`. So the
  device edge is the gate and `CallDetection`'s list is the second one, and the cost of that list is
  stated rather than hidden: a call in a browser tab is `com.google.Chrome` recording, which is the
  same thing a webcam test page is, and is deliberately not shown.

  `ActivityKind.call` is the one kind that both **opens the island** and has `.never` expiry, so this
  source owes a retraction on every path — the falling edge, `stop()`, `stopAndWait()` and the input
  device going away all go through one piece of state, and `CallSourceTests` holds each of them.

- **`FocusGate`** — **a gate, not a source.** There is no `ActivityKind.focusChanged` publisher here
  and there cannot be one: `INFocusStatusCenter.h` declares no notification constant, and
  `DoNotDisturb`, `DoNotDisturbKit`, `DoNotDisturbServer` and `Focus.framework` carry no Darwin name
  for state — only private XPC. A live Focus indicator would need a poll.

  **The value lies, confidently.** Reproduced on this machine: with `authorizationStatus` reporting
  `.notDetermined`, `focusStatus.isFocused` answered `Optional(false)` — a definite false, not a nil
  — and the same `Optional(false)` comes back when authorized and no Focus is on. Every read is
  therefore gated on the status, and `IntentsFocusStatus` does not so much as *name* the class unless
  `NSFocusStatusUsageDescription` is in the running bundle. The gate **fails open**: an unknown Focus
  is no Focus, always, because a gate that guessed the other way would silently stop showing
  notifications on every machine that never granted it.

  It is asked once, at the funnel in `SourceHub`, for the two kinds a Focus can suppress and for no
  others — `isFocused` costs **15 ms** and does not warm up, which is most of §9's 16 ms
  hover-to-frame budget, so a volume HUD never asks. The answer is reused for one second, which
  covers a burst of notifications and schedules nothing.

## Will not own

- **Notifications, in every form.** `NotificationSource` shipped via the Accessibility route —
  `NotificationAXObserverSource`, `NullNotificationSource`, `NotificationActivitySource`,
  `BuiltInActivity.notification`, quick reply, grouping, per-app rules, per-app sound, the recents
  list and missed-call recognition — and **the whole of it is withdrawn (2026-08-28)**. It announced
  a thing the user was already being shown: macOS had drawn its own banner a moment earlier and
  Isleta could not take that banner over without clearing the notification outright, so the island
  was a second copy of something already on screen. The code, the `ActivityKind` case, the settings
  controls, the shortcut, the strings and the tests all went; roughly 14.8k lines.

  **Everything below is kept because it is a fact about the Accessibility API and about
  `com.apple.notificationcenterui`, not a fact about the feature.** Every measurement was taken live
  on macOS 27.0 (26A5416b) unless it says otherwise. None of the symbols named below exist in the
  tree any more — they are named so a later reader can match a measurement to what took it.


  **What is observed, verified live on macOS 27.0 (26A5416b).** The process is
  `com.apple.notificationcenterui`. Banners live in an `AXWindow` with subrole `AXSystemDialog`;
  each notification is a group whose `AXSubrole` is `AXNotificationCenterBanner` (transient) or
  `AXNotificationCenterAlert` (persistent), carrying a UUID in `AXIdentifier`, `"App, Title[,
  Subtitle], Body"` in `AXDescription`, and its text in `AXStaticText` children identified `title`,
  `subtitle`, `body`. **We match on those markers, never on a path.** A hierarchy path is
  invalidated by any view Apple inserts above the notification; a subrole is invalidated only by
  renaming what VoiceOver announces, which breaks VoiceOver too and so does not happen quietly.

  **Three platform facts shape the implementation, all verified rather than assumed.**

  1. *AX events are incomplete.* Window creation and destruction arrive. A notification added to a
     window already on screen produced no `AXCreated`, no `AXWindowCreated` and no
     `AXLayoutChanged`. So the source rescans while something is showing, and holds no timer at all
     when nothing is — §9 forbids polling on the idle path and permits it while an activity is
     presented.
  2. *An idle NotificationCenter refuses accessibility entirely.* With nothing on screen it answers
     `cannotComplete` (-25204) to every attribute **and to `AXObserverAddNotification`**.
     Registration is only possible while it has UI up, and there is no event announcing that it woke
     — hearing that would need the registration we cannot yet make. Attachment is therefore retried
     with exponential backoff (0.5s → 16s, ~3ms per attempt, under 0.02% of a core); once one
     attempt lands the observer keeps delivering and the retry stops.
  3. *Accessibility calls are synchronous IPC costing ~0.6ms each.* Attributes are read five at a
     time with `AXUIElementCopyMultipleAttributeValues` (~3× cheaper than five separate reads), the
     walk is breadth-first and bounded (`maxDepth` 10, `maxNodes` 600),
     `AXUIElementSetMessagingTimeout` is mandatory, and the rescan reads only the cached
     notification-list subtree — the full discovery walk runs only on an accessibility event.

  **Privacy.** Notification text is never logged, never written to disk, and never reaches
  diagnostics. `ObservedNotification` overrides `description` *and* `debugDescription` to redact, so
  interpolating one into a log line yields lengths, not content. `NotificationSourceDiagnostics`
  carries only counts and flags and is safe to include in "Copy Diagnostics" by construction.

  **Permission.** Accessibility, and §10 is enforced in code rather than by convention:
  `NotificationAccessibilityTrust.isTrusted` never prompts, `prompt()` is the only caller of
  `AXIsProcessTrustedWithOptions` (whose prompt option *is* the prompt), and `start()` never asks.
  `NotificationPromptLedger` holds the one bit the API does not expose — whether we have ever asked
  — so `.undetermined` gets an offer and `.denied` gets an explanation and silence.
  **Quick reply — it was implemented, on 2026-08-23, and went with the rest.** A reply typed in
  the notch was written into the system's own field and sent, and the posting app received a real
  `UNTextInputNotificationResponse`. No Full
  Disk Access, no synthesized keystrokes, no AppleScript. The measurements are in
  `docs/PLATFORM-CONSTRAINTS.md`; what the implementation adds is below.

  - **The seam.** Four members on `NotificationSource` — `liveBannerIDs`, `beginReply(to:)`,
    `send(_:to:)`, `cancelReply(to:)` — all **defaulted** to "this source cannot". So
    `NullNotificationSource`, and the SQLite route, had it ever been written (it reads a *store* and has
    no on-screen element at all), are **absent** from the feature rather than broken by it. With
    Accessibility refused the island simply draws no reply control, which is what §10 asks the
    denied path to look like, and the type system gives the same answer the UI does.
  - **Repliability is discovered, never predicted.** `NotificationReplyStructure` matches the field
    by **role** — an `AXTextArea` (not a text field) with **no `AXIdentifier`**, the one element in
    this package a marker cannot be used on — and the Send button as the first `AXButton` *after* the
    scroll area the field is in. Order is the whole rule: the banner also carries the posting app's
    own buttons, and "the first button in the banner" is **Don't Allow** on the permission prompt
    measured in the same session.
  - **Which action opens the field cannot be decided structurally, so Isleta does not decide it.**
    Nothing separates `Reply` from `Allow` or `Skip` except the prose in the action's `Name:`, which
    is the app's and is localized. `NotificationBannerActions` therefore performs the **system's own
    expand action by position** — first after `AXPress`, and never the last entry, which is the close
    — and then looks for the text area. A banner that grows none is put back exactly as it was found
    and never offered again (`knownWithoutReply`). The price is real and is recorded: a messaging app
    whose field appears only under its own named action is not repliable from the island today.
  - **`AXUIElementPerformAction`'s return value is discarded in both directions.** The action that
    opens the field answers `-25200` every time and works every time; an action that does not exist
    answers 0. The only check worth anything is the **read-back** of `AXValue` before Send is
    pressed, because sending an empty reply is the one failure the user cannot undo.
  - **Canceling is not dismissing.** `cancelReply` empties the field and performs the (re-read, now
    collapsing) expand action, which un-pins the banner and hands it back to its own expiry clock.
    `Close` is never performed by any path, including quit — it does `removeDisplayed` *and*
    `removeDelivered`.
  - **A live banner element is held, and it is the only one this class holds past a scan.** Rebuilt
    from scratch every scan, so `liveBannerIDs` is the honest answer to "may this be replied to"
    rather than a memory of one — and a recents row older than its banner gets **no** reply button,
    not a grayed one that lies. While a reply is open the composing notification is re-announced into
    the delivery ledger if the expanded banner stops parsing, so the island cannot retract the
    surface somebody is typing into.
  - **Privacy, unchanged and extended.** The reply body is the user's own words about somebody
    else's message: it is never logged at any level, never persisted, and `NotificationReplySession`
    overrides `description` and `debugDescription` so an interpolation yields a length and a phase.
    The log lines this feature adds are phase names and character counts.

  **Taking the banner over instead of sitting beside it — researched 2026-08-22, not implemented.**
  Two routes exist and they fail in opposite directions, so this is written down rather than
  rediscovered:

  1. *Dismiss it ourselves — it works, and it clears the notification.* A banner element carries
     `AXPress` **and three custom actions, "Show Details", "Show" and "Close"**, and performing
     Close does dismiss it: a banner lives 4997/5017 ms left alone and 1100/1068 ms when it is
     performed. What the log shows it doing is the problem — `removeDisplayed` **and
     `removeDelivered`**, where a banner left to expire logs neither. Close is the ✕ button: the
     notification is gone from Notification Center as if the user had cleared it, and the only copy
     left is this package's five-entry recents list, which does not survive quit. No action in the
     list hides the banner while leaving the notification delivered. It is also not fast — the
     banner is in the tree ~145 ms after the post and takes a further ~1.05 s to withdraw once
     Close is asked, so Apple's banner is on screen for over a second either way.

     Two traps if this is ever revisited: `AXUIElementCopyActionNames` returns the custom actions as
     stringified objects (`"Name:Close\nTarget:0x0\nSelector:(null)"`), and
     `AXUIElementPerformAction` answers `.success` for a name that does not exist — so
     `performAction(banner, "Close")` reads as working and does nothing at all.
  2. *Let the system suppress it.* A Focus, or per-app "Deliver Quietly"
     (`~/Library/Preferences/com.apple.ncprefs.plist`, `apps[].flags`), suppresses the banner
     properly and with Apple's blessing — **and therefore suppresses the only thing this source can
     read.** With a Focus on there is no banner in the tree. The notifications still exist in
     `usernoted`'s store under `~/Library/Group Containers/group.com.apple.usernoted`, which is
     Full-Disk-Access walled (verified denied from a process that reads `~/Library/Preferences`
     fine), so route 2 is the SQLite route wearing a different hat and inherits its permission.
     `~/Library/DoNotDisturb/DB` is walled the same way, so Isleta cannot turn a Focus on either;
     `INFocusStatusCenter` (Intents, public, macOS 12+) can only *read* that one is on.

  **The tree carries no icon and no bundle identifier.** `AXImageData` is an attribute name on every
  element and nil on all of them, and a banner's children are three `AXStaticText`s. The posting app
  is the display name inside `AXAttributedDescription` and nothing else, which is why IslandUI
  resolves the icon from that name (`ApplicationIconResolver`) rather than being handed one.

  **Per-app rules are keyed on that display name, and it is the only handle there is.**
  `NotificationAppKey.normalize` folds case and diacritics against the **root** locale (Turkish
  lowercases `I` to `ı`, so a locale-sensitive fold would file a rule under a key the same machine
  could not reproduce after a region change). Three costs follow and none has a fix short of a bundle
  id the banner does not carry: changing the Mac's language makes existing rules unreachable, two apps
  with one display name share a rule, and an app that renames itself arrives as a new app.
  `NotificationFilter` applies them; `NotificationAppRoster` is the list of who has notified this Mac
  since launch, because **macOS will not enumerate a user's senders** — `com.apple.ncprefs` lists
  everything *registered*, which is everything installed, and the delivered store is FDA-walled. The
  roster is therefore empty on a fresh launch, which is a real state a settings pane has to draw.

  **A muted app is muted in Isleta and nowhere else.** Nothing here performs a banner action and
  nothing writes to `com.apple.ncprefs`: the app's banners still appear, still make the system's own
  sound, and are still delivered. See route 2 above for why Apple's own suppression is not available
  to us — it suppresses the element this source reads.

  **Grouping** (`NotificationGrouper`) is what stops a burst of three opening the island three times.
  `ActivityKind.notification` has no `singletonID`, deliberately, so before this every arrival was a
  new activity and each entrance interrupted the last. One group per **app** (grouping by
  conversation would leave three chats opening three islands, which is the bug), inside a 12 s window,
  with the conversation count carried inside and drawn as `Alex Chen (3)` or
  `3 new — Alex, Priya, Design team`. The count is in the *words* because a badge would need a field
  on `ActivityContent`, and appending one to that struct is the cross-package memory-layout trap.
  Two rules are load-bearing: the group's `ActivityID` is fixed at the first arrival and **stored**
  (an id computed from `members.first` renames itself the moment the oldest banner expires, leaving
  the island holding an id nothing answers to), and a withdrawal never shrinks a count — the group is
  retracted when its last member goes, and expiry still retires it on the stack's own clock.

  **Grouping put a translation in the middle of quick reply.** An activity's id is now the group's,
  so the live banner ids the source reports match nothing the island is drawing;
  `NotificationActivitySource.replyableActivityIDs` maps between them and offers a reply **only for a
  group holding one arrival**. A group of three has three text areas and picking one is a guess about
  which message the user is answering, made after they have typed it.

  **Missed calls live here** (`MissedCallRecognizer`), which is Stage 5.3 in full —
  `docs/PLATFORM-CONSTRAINTS.md` settles that the *ringing* call is behind an Apple-only
  entitlement. They are recognized by
  asking LaunchServices what `com.apple.FaceTime` is called **on this Mac** and comparing against
  that, never by matching the word "FaceTime", and they are published as `ActivityKind.call`. Nothing
  presses Call Back, Send Message or Block: they are app-supplied, localized, and distinguishable only
  by prose — taking one by position would have a one-in-three chance of blocking the caller — and
  `Close` would delete the missed-call record. A missed call is therefore never offered a reply, by
  construction: `publish` does not enter one in the banner→group map at all.

  **Focus is not gated here.** Stage 2's `FocusGate` asks at `SourceHub`'s funnel, where every
  activity passes, and `FocusSuppression.suppresses(.notification)` is true. A second gate in this
  path would arrive with a `respectsFocus` switch that could not turn the behavior off, so the seam
  was written and then removed. Worth remembering either way: with a Focus on there is usually **no
  banner to filter**, so the gate only reaches what a Focus lets through.

  **Per-app sound is opt-in with nothing preselected** (`NotificationSoundPolicy`), because macOS has
  already played the posting app's alert sound and anything Isleta adds is a second one on top. The
  value is a **system sound name**, not a path — a settings record holding a file reference the user
  can delete fails as silence with nothing to explain it. A burst is one sound, not five.

  **On the lock screen there is nothing to read.** `usernoted` logs `Presenting … as banner` and
  `com.apple.notificationcenterui` reports zero windows — success, empty, no error. The daemon's log
  and the tree disagree, and the tree is the one telling the truth about what is on screen.


- **Disks mounting and ejecting.** `SystemArrivalSource` shipped it — push, free, no permission —
  and it is withdrawn: every app installed from a `.dmg` mounted one, so the island announced a
  disk image the user was already looking at in Finder, and the volume it named was usually one
  they had never asked to be told about. Two measurements outlive the source and are kept here
  because they are facts about the notifications rather than about the feature.

  **`NSWorkspaceWillUnmount` is the trap.** A real APFS sparse image ejecting produced
  `WillUnmount` and `DidUnmount` **72 ms apart**, so a source listening to both draws two islands
  for one eject, which reads on screen as the island stuttering. Anything built on unmount observes
  `DidUnmount` only.

  **`com.apple.LaunchServices.applicationRegistered` needs a filter before it needs anything else.**
  An app arriving in `/Applications` was the other half of that source and was withdrawn a day
  earlier. The notification fires **exactly once** per install and per version bump and **zero**
  times on launch or quit, carrying `bundleIDs` as an **array** — but across macOS 26A5416b →
  26A5421a on 2026-08-24 it fired **522 times in 54.6 seconds, 245 alive at once** against a
  four-second dwell, because LaunchServices registers every bundle an installer touches and
  `/System/Library/CoreServices` alone holds 369 `.app`s. None of that was visible until an OS
  update happened to land.

- **The standing glance activity.** `CalendarSource` published the day and the sky onto the
  activity stack as an ambient, never-expiring activity, and it is withdrawn — the factory, its
  singleton id, its three localized strings and the source's `temperatureUnit` all went with it.
  This source still publishes the same `GlanceSnapshot`; `GlanceModel` carries it to `IslandPage`
  `.home` and `.weather`, which is where a surface a person *browses* belongs. The two announcing
  kinds are untouched: `.calendarAlert` and `.meeting` arrive unasked, with deadlines, which is the
  calendar earning an interruption rather than furnishing the notch.

  **The measurement that outlives it, because it is a fact about the stage rather than about the
  calendar.** Both `.glance` and `.nowPlaying` answer `.leading` in `ActivityKind.flankAffinity`,
  and `ActivityStack.stage` gives the *primary* the side its kind asks for and the companion
  whatever is left. Both sit at `.ambient`, where `ActivityPriority.displacesPeers` is false, so the
  tie breaks on arrival order — and the glance is published at launch and never expires, while music
  starts later. The primary was therefore the glance on every ordinary day, and the resting island
  drew a calendar glyph in the sliver the album cover belongs in, with the equalizer stranded on the
  far side of the cutout. It also silently disabled a whole second feature:
  `IslandScreenModel.trackLipContent` gates on `stage.kind(for: .leading) == .nowPlaying`, so
  hovering the sleeve for the title, artist and audio-format badge could not fire at all on a Mac
  with one event in the diary. Any future kind that wants a flank alongside Now Playing has to
  answer this first: a condition that is permanently true takes a sliver permanently.

- **Screen Recording, in any form.** Nothing here asks for it and nothing here needs it. The one
  feature that ever wanted it was the app switcher's window thumbnails, and the switcher is gone; a
  new caller would be adding a permission row to the user's System Settings, which is a change to
  the app's permission surface rather than to this module.
- Anything requiring **SIP to be disabled**. Never proposed, never documented, never shipped (§2.4,
  §12.3).
- Lock screen drawing. `loginwindow` is a separate secure context and is closed to third parties
  (§2.5) — "Welcome Back" is a wake/unlock moment, and must not be described as a lock screen
  feature anywhere in code or copy.
- Reading other apps' notifications through any supported API, because there isn't one.
- **The keyboard backlight HUD.** It shipped, and it is withdrawn. `KeyboardBrightnessMonitor` was
  the **sixth private-framework path**; it is deleted along with `SystemHUDKeyboardBrightnessState`,
  `UnavailableKeyboardBrightnessMonitor` and the `keyboardBrightnessHUD` switch. **The path did not
  close — the case for the feature did.** macOS adjusts the backlight for ambient light on its own
  and gives no signal saying whether a change came from the user or from the room, so with the
  keyboard's own auto-brightness on the island announced the room. That is a HUD for something
  nobody did.

  **The measurements outlive it, because they are facts about `CoreBrightness` rather than about the
  feature.**

  **The backlight is a privileged device, and the level is not in HID.** The IORegistry node is
  marked `Privileged` and `IOHIDDeviceGetReport` refuses without an entitlement Apple keeps — that
  original measurement was correct and still is. What was wrong was the conclusion drawn from it:
  `CoreBrightness.KeyboardBrightnessClient` answers an unentitled process and pushes 2-6 ms after a
  change. `KeyboardBrightnessMonitor` owned it, with `UnavailableKeyboardBrightnessMonitor` as the
  fallback a desktop Mac with no backlit keyboard got. The private path never closed.

  **Its notification keys are prefixed `KeyboardBacklight`, not the `KB` its own method names
  imply** — twenty-three wrong spellings produced zero callbacks and no error, because the
  registration returns `void`. They were read out of the loaded image's `__cfstring` section.

  **`SystemHUDKeyboardBrightnessState` is a filter, not a throttle**, because this API reports its
  destination rather than easing toward it. What it filters is the backlight moving on its own:
  idle dimming notifies exactly as a keypress does, and `isBacklightDimmedOnKeyboard:` is the one
  dependable discriminator. With the keyboard's own auto-brightness on, an ambient change is still
  indistinguishable from a keypress — recorded as open rather than papered over, and it is one of the reasons the feature went.

- **The Notification Center SQLite route.** Designed for, never implemented, and now without a
  consumer at all — notifications were withdrawn on 2026-08-28 and `NotificationSource` went with
  them. Kept here because the reasoning is why it was never the fallback anyone reached for: it
  needs Full Disk Access (a strictly larger grant than Accessibility), its schema is undocumented
  and fails by returning plausible wrong rows, and it reports notifications that were *delivered*,
  including ones a Focus suppressed — precisely the set the user asked not to see.
- **A sampled playback position.** `NowPlayingSnapshot` still carries no `elapsedTime` field. It
  carries an `ActivityTimeline` instead — position *plus the instant it was true* plus the rate — so
  the value published once per track change is still exact ten minutes later and IslandUI can
  evaluate it against the display link it already runs. When adding a field here, that is the test:
  is it true until something changes, or only true when it was read?
- **Deciding what a control looks like.** `canSkip` is reported, from the payload's `prohibitsSkip`;
  whether that grays a button or hides it is IslandUI's business.
- **Streaming artwork.** `stream` is run with `--no-artwork` and always will be. It re-emits the
  whole payload on every update, and `artworkData` measured **211,300 characters (~155 KB)** for one
  track — so a scrub would push hundreds of kilobytes a second through the pipe against §9's 60 MB
  budget, to redeliver an image that has not changed. `NowPlayingArtworkLoader` runs a separate
  `get` once per track instead, keyed on `NowPlayingSnapshot.artworkIdentity`, decodes at thumbnail
  size off the main thread, and retains exactly one image.
- **The brightness *keys*.** Watching the level is strictly better, and consuming the key is the line
  between showing a HUD and taking over the hardware. **This no longer covers the volume keys** —
  since 2026-08-30 `MediaKeyMonitor` in `.replace` consumes them when `suppressSystemHUDs` is on,
  which is exactly "taking over the hardware", entered on purpose and off by default. Brightness
  stays on the watching side of that line.
- **A live battery readout for connected devices.** Deliberately not implemented, and the reason is
  the KVO measurement above: the only way to keep a percentage current is to ask for it repeatedly,
  which is a poll on the idle path. `deviceConnected` is a *moment* — read once, shown for four
  seconds, gone — and its expiry is what keeps that honest. A milestone that wants a persistent
  readout needs a push signal that does not exist today, not a timer.
- **A weather activity of its own.** There is no `ActivityKind.weather` and there must not be. A
  second `ActivitySource` publishing a second activity drawn in the same island would give the open
  island two publishers and two heights, and `IslandController.expandedContentHeight` is read
  *before* the transition — so a reading landing on its own clock would resize a surface somebody is
  reading. The weather is folded into `GlanceSnapshot`.
- **A month view, or anything a user would call a calendar.** The island lists a day and, behind
  the date, today and tomorrow. It carried a six-week grid from 2026-08-26 to 2026-08-28, fed by a
  `daysWithEvents(inMonthContaining:)` that fetched a month to draw a dot per day; both went with
  it. Past two days the island stops reading as the notch having opened and starts reading as a
  window bolted to one, and `IslandLayout.maxExpandedBodySize` would clamp it anyway.

  **What the grid measured survives it.** A month's fetch is *not* the cost — the predicate is warm
  and a day of it is 2 ms — but the shape of the answer is: an event spanning days has to mark every
  day it touches, and an all-day event arrives as an ordinary range in its own calendar's time zone
  rather than as midnight-to-midnight in the reader's. That is why `events(on:)` is called once per
  day rather than once across two and split by hand, which is where a fetch quietly goes wrong for
  anybody travelling.
- **Writing to the user's calendar.** Isleta reads a day and offers a link. Nothing here creates,
  edits, accepts or declines an event, which is also why the *full access* usage key is the one that
  ships rather than the write-only one that sounds safer.
- **`EKEvent.conferenceURL` and the rest of the private conference surface.** It exists, it is
  exactly what you would reach for, and it answered nil on all 33 events measured. A private path in
  this codebase has to earn itself with a measurement; this one measured zero.
- **Non-audio Bluetooth devices.** A mouse, a keyboard and a phone all fire the same connect
  notification, and the island has nothing to say about any of them that the user does not already
  know from having just connected it. `IOBluetoothDeviceMonitor` filters on the Audio/Video major
  class.

- **A live battery readout or a persistent call timer that outlives its signal.** Each would need to
  be kept current and each has no push signal that keeps it current, so each is a poll. Power is a
  *moment* with a dwell, and a call is retracted on the edge that ends it — the same discipline as
  the AirPods ring.
- **Announcing a Focus turning on or off.** `ActivityKind.focusChanged` exists and has no publisher,
  because there is no change notification on macOS to publish from. `SourceToggles.focusChanges` is
  the switch for that unbuilt announcement and is deliberately not wired to the *gate*: suppression
  is governed by whether the user granted Focus access, not by a switch about a different feature.
- **Screen recording.** Nothing reports it. `CGDisplayIsCaptured` read false throughout a real
  12-second recording — it is the exclusive display-capture API — and StatusKit refuses unentitled
  clients in its own words. The one working signal, an AX observer on ControlCenter, is anonymous:
  camera, microphone and location would look identical.
- **Who is calling, and answering or declining.** Behind an entitlement Apple issues to FaceTime.
  And explicitly not the "call spectrum": drawing a waveform of a call means tapping the call's
  audio, which is a microphone grant plus a recording of the other party.
- **Downloads, in any form.** `DownloadSource` and `DownloadFolderWatcher` shipped it — vnode-driven,
  no timer — and it is withdrawn on 2026-08-28: **only Safari can be drawn**, and an island that
  shows a percentage for one browser and a shrug for every other is not a feature, it is a
  coin toss the user has to learn the rules of. Four measurements outlive the source and are kept
  here because each is a fact about the platform rather than about the feature.

  **Safari and Chromium were never two implementations of one thing.** Measured on macOS 27.0
  against a local server throttled to 200 KB/s, so a 4 MB file took 21 s. Safari's `.download`
  package carries a live `com.apple.progress.fractionCompleted` (0 → 0.059 → 0.171 → … → 0.864, one
  `.attrib` event about every 2.3 s) and its artifact is named for the user's real file. Chromium —
  Chrome, Brave, Arc, Edge — publishes **no progress xattr at all**: a grep over the whole run
  counted **zero**, its part file raised **206 vnode events in 21.7 s, one per 20 KB**, and it is
  called `Unconfirmed NNNNNN.crdownload` until the instant it finishes. So one flavor could be drawn
  as a percentage with a real file name and the other could only ever be bytes with no name.

  **Opening the Downloads folder is TCC-gated and the gate *blocks* the caller.** Measured on
  macOS 27.0 from a fresh ad-hoc identity running as its own responsible process:
  `open("~/Downloads", O_EVTONLY)` **had not returned after 25 seconds**, while `~/Library/Mail` and
  the `usernoted` group container answered `EPERM` in under a millisecond in the same run. Anything
  that opens this folder later opens it on a private queue and never at launch — a main thread
  parked behind a dialog is an app that has hung, and it is a worse failure than a refusal.

  **`~/Library/Safari/Downloads.plist` is dead and looks alive.** `ls` and `stat` succeed and its
  size changes during a download; every read answers "Operation not permitted".

  **A download's total size does not exist to be inferred.** Chromium reports none, and a percentage
  computed against a guessed total is a number the island would be making up.

## Localization

German, French and Spanish, in `Sources/IslandSources/Resources/{de,fr,es}.lproj/Localizable.strings`.
English is not a table: it is the second argument at every `sourceText(_:_:)` call site, which is also
the fallback for a language Isleta does not yet speak. 84 keys, no plurals — nothing in this package
branches on a count, so there is no `.stringsdict` here. `LocalizationCoverageTests` fails the build
when a key is missing from a language, when a language keeps a key the source has dropped, or when
two languages take different printf arguments for one key.

**This is the package where the boundary matters most**, because Isleta's own words and content owned
by macOS sit in the same string. The rule is in `SourceText.swift`'s doc comment and it is applied
ruthlessly here:

- **Every `IslandLog` line in this package is English and stays English**, at every level, including
  the ones that describe something the user also sees. Where a sentence is both logged and shown,
  there are two strings.
- **Names the system gave us travel as arguments, never through a table** — the app a call is in
  (`FileManager.displayName(atPath:)` has already localized it), a volume's name, a conversation's
  name, an event's title, a player's scripting name, a version number. The sentence *around* each of
  them is Isleta's and is translated with the name interpolated.
- **`NotificationAppKey.normalize` is untouched**, and nothing localized goes anywhere near the
  per-app key. It folds against the root locale on purpose; the cost of that is recorded above.
- `SystemSounds` names, `SpeechTranscription`'s BCP-47 locale identifier, and the `"Images"` base
  name a multi-image PDF is written under are all deliberately **not** localized: the first two are
  arguments to APIs that match on them, and the third becomes a file name on the user's disk.

**The captions that were hard.** The `WelcomeBackGreeting` pools are the only place in Isleta with a
*voice*, and several lines had to be written rather than translated: German has no "good afternoon"
anybody says (`Guten Tag`), Spanish has no separate evening greeting before `Buenas noches`, and
"Finish gently" has no German verb (`Lass den Tag ruhig ausklingen`). Spanish marks gender on
"Welcome back", which Isleta cannot know, so the late-night greeting is the agreement-free
`Hola de nuevo`. The battery estimate's "%@ left" cannot agree in number in French or Spanish for the
one-hour case, so both use a construction that does not have to (`encore %@`, `quedan %@`). The
file-conversion failures are the tightest budget in the package: they are drawn as a `fileAction`
compact title, which does not grow, so the German ones truncate sooner than the English.

## Non-negotiable

Every feature here must be fully usable in the **denied** state, with a clear in-app explanation of
what each permission unlocks, and no nagging (§10).
