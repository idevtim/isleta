# Platform constraints

Verified on macOS 27.0 — what each system API actually does, and which ones report success while doing nothing. Do not design around an absent API; if you believe an entry is outdated, say so and check the installed SDK before proceeding. Never invent a symbol.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

<details>
<summary>Topics in this file (57)</summary>

- No public notch API
- No ActivityKit on macOS — and the framework is in the macOS SDK, which is what makes this worth a line
- macOS Clock timers are readable with no permission, and the signal that looks right is nine seconds late
- AirPods battery needs the Bluetooth permission — and "no prompt was ever seen" was evidence of the harness, not of the platform
- AirPods battery is not in the IORegistry
- Display brightness *is* readable, it pushes, and it is writable — this corrects a claim that shipped through 1.3.0
- Three things beside it lie, and each is the one you would reach for first
- Synthesized brightness keys do not change brightness on Apple Silicon, and that invalidated the earlier measurement
- Keyboard backlight is readable and pushes too, via CoreBrightness — and this correction is the more instructive of the two. Measured while building the keyboard HUD, which is withdrawn
- The keyboard notification keys are not the ones the class's own method names imply
- The keyboard backlight moves on its own constantly, and it notifies when it does — which is what killed the HUD it fed
- `setBrightness:forKeyboard:` returns `YES` and does nothing whenever the backlight is suppressed or idle-dimmed
- A public iCloud share link IS reachable — this reverses the finding above it, which said it was not. Measured 2026-08-23
- The superseded finding, kept because the inference is instructive
- Full Disk Access is walled at the *read*, not at the `stat` — so the cheap check lies
- WeatherKit is a real macOS API and works for a Developer ID app — but claiming its entitlement without an embedded provisioning profile SIGKILLs the process with no crash report. Measured 2026-08-23
- `.authorizedWhenInUse` does not exist on macOS, and Swift refuses to compile the comparison
- EventKit needs `NSCalendarsFullAccessUsageDescription`, and the no-key case is a silent 9 ms loop rather than a crash
- A meeting's join URL is in `EKEvent.notes`, not in the field named for it
- Calls cannot be observed by a Developer ID app, and every API for it succeeds while answering nothing. Measured 2026-08-23
- On-device transcription needs no permission, and the API named for asking is the one that would break it. Measured 2026-08-23
- `notify_register_dispatch` returns 0 for any string, including one you invented — and `DistributedNotificationCenter`'s wildcard observer is inert. Measured 2026-08-23
- `kIOPSNotifyAnyPowerSource` is a once-a-minute heartbeat, not a change signal
- Download progress is reachable for Safari and not for Chromium, and the plist that looks like the answer is walled — measured while building downloads, which are withdrawn
- Nothing reports that the screen is being recorded, and the two calls named for it answer a different question
- Focus is a gate, not an activity, and `isFocused` gives the same confident answer whether or not you are allowed to ask
- `com.apple.LaunchServices.applicationRegistered` is the cleanest system signal measured
- File conversion: seven routes return success and produce garbage, and each is the one you would pick first. Measured 2026-08-23
- macOS decodes MP3 and will not encode it, below AVFoundation, and `afconvert`'s own table implies otherwise
- Every conversion family breaches the 60 MB resident ceiling while working, and the cheaper-looking video presets are the expensive ones
- `osascript -e 'tell application "Pages" to name'` answers "Pages" and exits 0 on a machine with no Pages installed
- `CLGeocoder` is deprecated in macOS 26 — "Use MapKit" — which under `-warnings-as-errors` is a build failure rather than a warning
- No supported API to read other apps' notifications — and notifications are withdrawn
- Now Playing is entitlement-gated since macOS 15.4
- The island lives in a private window-server space, and that was the second private-API path — "and last" was wrong three paths ago
- The Now Playing *queue* is readable, it pushes, `queue[1]` is the next song, and it is behind the same door Perl already walks through — measured 2026-08-23
- Lyrics are closed through every Apple route, and the symbols say the opposite
- Shuffle and repeat cannot be read back *from MediaRemote*, and on a radio station they cannot be set — by anyone
- After a skip the player names the new track before it has the cover
- The AppleScript fallback is push, not poll
- `CGShieldingWindowLevel()` is not the lock screen's level, and `+ 1` on it is sixteen levels *below* the thing it is trying to beat
- `SLSSetWindowLevel` returns `kCGErrorFailure` (1000) and does nothing — and the first attempt to measure that was unfalsifiable
- `canBecomeVisibleWithoutLogin` is about *before login*, which a locked screen is not
- A login-item helper is not structurally different from Isleta, because locking does not log you out
- The lock screen is reachable — a SkyLight space at absolute level **400**, not any window level; and it takes no input
- `Int32.max` is not a valid space absolute level, and the overlay space has been running at 0 — this reverses a claim that the getter was unreliable
- Suppressing Apple's HUDs: consuming the key at `.cghidEventTap` works, measured 2026-08-30
- But consuming the key is not on its own enough — the CoreAudio write is what wakes `OSDUIHelper`
- `SIGSTOP` on `OSDUIHelper` is the mechanism that ships, and it breaks a rule CLAUDE.md states — this reverses "the one not to copy"
- What is actually suppressed: volume and mute, and the `suppressSystemHUDs` setting is live again at schema 23
- The four suppression mechanisms that were rejected, and why each failed the restore-after-crash rule
- Re-searched 2026-08-22, and the two frameworks that look like the answer are a client and a no-op
- Hiding another process's window from outside is the trap that reports success
- Taking over the notification banner works, and it deletes the user's notifications
- Inline quick reply IS reachable, with Accessibility alone — measured 2026-08-23
- The banner's accessibility tree has no icon and no bundle identifier in it
- On the lock screen there is nothing to read, and the logs say the opposite

</details>

---

If you believe any of these is outdated, **say so and check the installed SDK before proceeding**.
Never invent a symbol.

- **No public notch API.** It's screen geometry: `safeAreaInsets` + `auxiliaryTopLeft/RightArea`.
- **No ActivityKit on macOS — and the framework is in the macOS SDK, which is what makes this worth
  a line.** `ActivityKit.framework` is present under the MacOSX SDK with headers, a `.tbd` and a
  full `.swiftinterface`, so the rule reads as out of date the moment anyone looks. It is not:
  **every symbol in it carries `@available(macOS, unavailable)`** — verified in MacOSX26.5 — and it
  ships in the SDK for Catalyst's benefit. Never import it in the Mac target; we define our own
  activity model. **AlarmKit does not exist on macOS at all** (absent from the 26.5 SDK), so it is
  not the way to reach the Clock app either.
- **macOS Clock timers are readable with no permission, and the signal that looks right is nine
  seconds late.** There is no public API, Clock.app is not scriptable (`sdef` → error -192, no
  `NSAppleScriptEnabled`, no `CFBundleURLTypes`), and neither ActivityKit nor AlarmKit is available
  above. What works is the **`com.apple.mobiletimerd` preferences domain**, read through cfprefsd:
  a stopped timer is `MTTimerState = 1` with a *relative* `MTTimerFireTimerClass =
  MTTimerTimeInterval`, and a **running** one is `MTTimerState = 3` with `MTTimerFireTimerClass =
  MTTimerDate` carrying an **absolute** `MTTimerTimeDate`. That absolute instant is the whole
  feature — the countdown runs against the display link with nothing to poll and no drift to
  correct. Ignore `MTTimerStorageMigratedToCoreData = true`: the Core Data store it points at lives
  in `~/Library/Group Containers/group.com.apple.mobiletimerd` and **is** Full-Disk-Access walled,
  but the prefs domain is not the stale mirror it looks like — it is written on every state change,
  and we never need the store.
  **The trap is the mechanism.** Measured on macOS 27.0 with a Darwin observer, a cfprefsd read and
  a vnode watch running side by side against one real timer start: the value is visible to
  `CFPreferencesCopyAppValue` in **151 ms**, the plist **file** is not written for **8.9 s**, and
  there is **no push signal on any bus** — zero `NSDistributedNotificationCenter` posts, and zero
  Darwin `notify` on all 15 `MTTimerManager*` / `MTTimerDidFire*` names pulled out of the dyld
  shared cache (those are `MTTimerManager`'s own in-process `NSNotificationCenter` names, not a bus
  we can join). So a `DispatchSource` vnode watch on the plist — push, permission-free, no timer,
  and the thing this codebase reaches for by reflex — is **nine seconds behind the user**, because
  cfprefsd batches the flush to disk. Something has to ask. Gate the asking on Clock being frontmost
  (`NSWorkspace`, free, and Clock is not running on an idle Mac) and keep the vnode watch only as
  the late backstop for Siri, Shortcuts and Control Center.
  **Measured 2026-08-21: paused is `MTTimerState = 2`, and it reverts to a *relative* interval
  carrying the time remaining** — `MTTimerFireTimerClass = MTTimerTimeInterval`, same class, same
  field and same type as an **idle** timer, which differs only by holding the original duration and
  by `MTTimerState = 1`. So the state number is the discriminator and the fire-time class only says
  how to read the payload. A parser keyed on the class — which is the field that reads like the
  discriminator — shows every saved preset in the user's Clock as a paused countdown; on this
  machine that is four presets untouched since 2023. See `MobileTimerState`.
- **AirPods battery needs the Bluetooth permission — and "no prompt was ever seen" was evidence of
  the harness, not of the platform.** This bullet said "readable with no permission" until a release
  build was launched from the Dock and died in 270 ms. Reading a paired device's properties really
  is ungated; what is not is *hearing the connect*, because
  `IOBluetoothDevice.register(forConnectNotifications:)` builds a `CBCentralManager` underneath it,
  and CoreBluetooth files a TCC access request. With no `NSBluetoothAlwaysUsageDescription` in the
  Info.plist TCC does not refuse that request, it **aborts the process** —
  `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, SIGABRT, before the island is drawn.
  **The reason nobody saw it is the thing to remember: TCC judges a request against the
  *responsible* process, and everything in this project is verified from a shell.** A build run as
  `.build/xcode/…/Isleta --perf-report 60` inherits Terminal's usage strings and Terminal's grant,
  so the whole feature runs, the diagnostics print "Bluetooth devices running — battery readable",
  and none of it says anything about a real launch. `open -a Isleta` is the only verification that
  counts for anything permission-shaped, and it is now the last step before a release. The battery
  route below is unchanged and still ungated.
- **The usage string is only half of it: with the hardened runtime on, Bluetooth also needs
  `com.apple.security.device.bluetooth`, and without it the request never reaches `tccd` at all.**
  Measured 2026-08-29 on macOS 27.0 (26A5421a), Developer ID signed Debug build launched with
  `open -a`. `Config/Isleta.entitlements` carried `personal-information.calendars` and
  `personal-information.location` — the two whose absence had already cost a session — and not this
  one, so the bug shipped in 2.0.0 with the fix for its own siblings sitting two lines above it.
  **It does not fail the way those two failed.** Calendars and location answered "not granted" in
  50 ms; Bluetooth *never answers*. `+[IOBluetoothHostController defaultController]` is a
  `dispatch_once` that builds `IOBluetoothCoreBluetoothCoordinator`, and that initialiser **waits on
  a dispatch semaphore, with no timeout**, for a `bluetoothd` reply the hardened runtime is
  discarding. `sample` put the main thread in `semaphore_wait_trap` for over two minutes, inside
  `applicationDidFinishLaunching` → `SourceHub.apply` → `BluetoothDeviceSource.start()` →
  `isAvailable`. No island, no crash report, no log line past the previous source, and every source
  after `.deviceConnected` in `SourceHub.entries` never started — the calendar, power and calls all
  went down with it. `tccd`'s log never mentioned `kTCCServiceBluetoothAlways` for Isleta. With the
  key added, the same launch logs `AUTHREQ_PROMPTING, service=kTCCServiceBluetoothAlways` and the
  prompt appears.
  **Invisible from a shell, for the reason the bullet above gives:** the identical call in a probe
  run from Terminal is attributed to Terminal, whose grant is decided, and returned in 3 ms. Two
  instruments, opposite answers, and only `open -a` was telling the truth.
  Two consequences. The entitlement is the fix. The seatbelt is that **no IOBluetooth call may
  happen on the main thread** — `IOBluetoothDeviceMonitor` now wakes the coordinator on its own
  queue, because a semaphore with no timeout on the launch path is a hang waiting for the next
  daemon that declines to answer.
- **Taking AirPods out of your ears is not a Bluetooth disconnect, so putting them back is not a
  connect — the only thing that moves is the system output device.** Measured 2026-08-30 on
  macOS 27.0 with AirPods Pro, one probe watching five signals at once:

  | what the user did | IOBluetooth | CoreAudio default output |
  |---|---|---|
  | case → ears | `CONNECT` ×4 | → AirPods |
  | out of ears | *silent* | → speakers |
  | back in ears | *silent* | → AirPods |
  | → case | `DISCONNECT` ×4 | → speakers |

  The link never drops across the middle two rows: `IOBluetoothDevice.isConnected()` stays true, no
  connect or disconnect notification fires in either direction, and a half-second poll of every
  paired device sees no transition. So a feature listening only to IOBluetooth is *correct* to say
  nothing and the island stays empty — which is exactly how it was reported ("I took them out of my
  ears and reconnected and it didn't show back up").
  **The event exists on the other side.** `kAudioHardwarePropertyDefaultOutputDevice` fires on all
  four rows, and a Bluetooth output device's `kAudioDevicePropertyDeviceUID` carries the MAC ahead
  of a colon — `04-9D-05-6B-19-80:output`, against an `addressString` of `04-9d-05-6b-19-80`, so the
  mapping back to the paired device is exact and needs only a lowercase. Gate on
  `kAudioDevicePropertyTransportType` being `…Bluetooth` or `…BluetoothLE` rather than on the UID's
  shape, and validate the shape anyway: another vendor's UID is not a MAC.
  Public, unentitled and push, so it costs nothing idle — the same argument `SystemHUDAudioObserver`
  makes for observing levels rather than keys. `CoreAudioRouteMonitor` is the implementation and
  `BluetoothDeviceSource` owns both routes, collapsing them on the address: a genuine connect fires
  IOBluetooth and then CoreAudio **244 ms apart**, and without that window it is two islands for one
  thing the user did.
- **AirPods battery is not in the IORegistry.** The route
  everyone reaches for first — `AppleDeviceManagementHIDEventService`, or any `ioreg` sweep — has
  **nothing** in it: a walk of the entire tree for any key containing "battery" returns the Mac's own
  pack and the internal keyboard, measured on macOS 27.0 with AirPods Pro connected. What works is
  three undocumented selectors on `IOBluetoothDevice`, a **public** framework linked normally:
  `batteryPercentLeft`, `batteryPercentRight` and `batteryPercentSingle`. This is the **third**
  private path and is held to the same rules as the other two — runtime `responds(to:)`, behind
  `BluetoothDeviceMonitoring`, with `UnavailableBluetoothMonitor` as the fallback and "the device's
  picture without the ring" as what degrading looks like.
  **Four things in the same read lie, and each is the field you would pick.** `batteryPercentCombined`
  answered **0** while left and right answered **100** — the field named as the summary is not one.
  `isMultiBatteryDevice` answered **0** on that same three-battery device, so the field named as the
  discriminator does not discriminate; ask `BluetoothDeviceKind.hasEarPieces` instead.
  `batteryPercentCase` arrived **12.5 s** after the connect notification on one connect and read 0 on
  the next, against an island that is up for four seconds, so it is not carried at all. And
  `system_profiler SPBluetoothDataType` reports battery for devices that are **not connected**, from
  a cache — it showed AirPods Pro at 100/100/93 while they were shut in their case, which is the
  `mobiletimerd` saved-preset trap in a different tool.
  **KVO on those properties registers successfully and never fires.** A poll watched the case
  percentage go 0→93 while KVO sat silent on the same object for the same key, so there is no push
  for a *changing* battery and a live readout would be a poll on the idle path. The connect
  notification itself **is** push, is raised once for the permission above, and fires immediately for already-connected
  devices at registration — so `deviceConnected` is a moment (read once, four seconds, gone) with no
  timer anywhere, and a persistent readout is deliberately not shipped. Zero means "not reported",
  never "flat": a device genuinely at 0% has disconnected.
- **Display brightness *is* readable, and it pushes — this corrects a claim that shipped through
  1.3.0.** Four release notes, PROGRESS.md and `SystemHUDBrightness` all said brightness had no
  route on Apple Silicon **and no change notification anywhere**; the second half was the
  load-bearing one, because a value nothing announces cannot drive a HUD however well it reads.
  Both halves are false. `DisplayServicesGetBrightness` (DisplayServices.framework, private) returns
  the real user brightness on the built-in panel, and
  `DisplayServicesRegisterForBrightnessChangeNotifications` is a genuine push callback — measured on
  macOS 27.0 across nine real key-holds: 419 callbacks, mean **1.94 ms** to a correct re-read, and
  **zero callbacks in the 45 s after the user stopped**. It needs no permission and no entitlement:
  the probe was unsigned, and read identically re-signed with `--options runtime`. This is the
  **fourth** private path (`DisplayServicesBrightnessMonitor`, in
  `IslandSources/DisplayBrightnessMonitor.swift`, behind `DisplayBrightnessMonitoring`), held to the
  same rules as the other three.
  **And it is writable on the same terms — measured 2026-08-30.** `DisplayServicesSetBrightness`
  moved the built-in panel 1.0 → 0.75, read back 0.7499999, from an ordinary unentitled process with
  no Accessibility grant; `DisplayServicesCanChangeBrightness` and
  `DisplayServicesSetBrightnessSmooth` resolve beside it. The **read-back is the measurement** — the
  `0` return value is worth nothing on its own. This is the fourth time in this codebase a
  capability was declared absent on the evidence of one API declining it: `IODisplaySetFloatParameter`
  answers `kIOReturnUnsupported` on Apple Silicon internal panels, which is real and reproduces, and
  which was read as the platform's answer rather than as that one API's. **Isleta never writes it** —
  brightness is deliberately outside `SystemHUDSuppression.suppressible` — and the fact is recorded
  because it is the fact that killed the "swallowing a brightness key would leave the user unable to
  change brightness" objection.
  **The trap is that one key-hold is 27-78 callbacks over 0.5-1.4 s**, tracing the panel's easing
  ramp, and unlike CoreAudio's eight-per-keypress the values all *differ*, so equality dedupe drops
  none of them. `SystemHUDBrightnessState` coalesces on a 100 ms throttle chosen by replaying the
  recorded session; the table of what each interval costs is in that file.
- **Three things beside it lie, and each is the one you would reach for first.** The
  `AppleARMBacklight` → `IODisplayParameters` registry route is **dead in all three of its keys** —
  `brightness`, `rawBrightness` *and* `BrightnessMilliNits` sit at plausible-looking values
  (32768/65536, 1488/2047, 381794/1599999) and **not one of them moved a digit** while real
  brightness went 0.835 → 0.20 → 1.00 → 0.67. `IOServiceAddInterestNotification` on that node
  returns `KERN_SUCCESS` and never fires. `CoreDisplay_Display_GetUserBrightness` answers a constant
  `1.0000`. PROGRESS.md previously recorded the registry property as "could not be shown to track
  the panel, so it may be a constant"; it is not a maybe.
- **Synthesized brightness keys do not change brightness on Apple Silicon, and that invalidated the
  earlier measurement.** An `NSEventTypeSystemDefined` subtype-8 media key for
  `NX_KEYTYPE_BRIGHTNESS_UP`/`DOWN` posted to `kCGHIDEventTap` from a process with
  `AXIsProcessTrusted() == true` moved the value by **exactly zero** across four presses — the keys
  are consumed below the event-tap layer. The 1.2.0-era probe that concluded the registry property
  "may be a constant" drove the panel this way, so its stimulus never fired and its frozen readings
  were evidence of nothing. **Any brightness measurement has to be driven by a real keypress or by
  `DisplayServicesSetBrightness`, never by a posted key event** — and the same doubt applies to any
  other probe in this file that synthesized its own stimulus.
- **Keyboard backlight is readable and pushes too, via CoreBrightness — and this correction is the
  more instructive of the two. Measured while building the keyboard-brightness HUD, which is
  withdrawn**: `KeyboardBrightnessMonitor` was the sixth private-framework path and is deleted,
  along with `SystemHUDKeyboardBrightnessState`, `UnavailableKeyboardBrightnessMonitor` and the
  `keyboardBrightnessHUD` setting (swept at schema 18). The four bullets that follow are kept as
  facts about CoreBrightness and HID, not as a feature waiting to be finished. The old claim was that the backlight is "a privileged device that
  only Apple's own software may query", and **the measurement behind it was correct**: the node
  really is marked `Privileged`, `IOHIDDeviceOpen` really does succeed, and `IOHIDDeviceGetReport`
  really does return `kIOReturnUnsupported` without an entitlement Apple keeps. All still true. It
  simply was not where the level lives. `CoreBrightness.framework`'s `KeyboardBrightnessClient`
  answers an unentitled process: `copyKeyboardBacklightIDs` → `brightnessForKeyboard:`, with
  `registerNotificationForKeys:keyboardID:block:` pushing **2-6 ms** after a change. **Proving one
  door locked says nothing about how many doors there are** — the phrase that shipped to users
  ("only Apple's own software may query") turned an observation about HID into a claim about macOS.
  **The finding stands and the feature does not**: `KeyboardBrightnessMonitor` shipped as a private
  path on 2026-08-22 and was deleted on 2026-08-27, because the entry two below this one is
  the whole story — the level moves without the user, so the HUD interrupted them over something
  they had not done. The measurement was right, the route is real, and it was still the wrong thing
  to build.
- **The keyboard notification keys are not the ones the class's own method names imply.** The
  handlers are `KBBrightnessPropertyHandler:`, `KBIdleDimPropertyHandler:` and so on, which reads as
  keys prefixed `KB`. Registering for `KBBrightness`, for the bare `Brightness`, and for
  twenty-one other spellings produced **zero callbacks**, silently — the registration returns
  `void`, so a wrong key is indistinguishable from a quiet machine. The real keys are prefixed
  `KeyboardBacklight` (`KeyboardBacklightBrightness` is the 0...1 level; `…Level` is the same change
  in nits, so acting on both doubles every HUD). They were found by walking the `__cfstring` section
  of the loaded image, which is the general move when a private API's string constants matter.
- **The keyboard backlight moves on its own constantly, and it notifies when it does.** Idle
  dimming fired unprompted 650 ms after a manual change — four callbacks, level to zero — and
  ambient light suppresses it entirely. `isBacklightDimmedOnKeyboard:` is the one reliable "this was
  not the user" flag, and it was what `SystemHUDKeyboardBrightnessState` gated on. **With the
  keyboard's own auto-brightness on (the default) an ambient adjustment is indistinguishable from a
  keypress**; `KeyboardBacklightUserOffset` and `KeyboardBacklightManualBrightness` look like the
  discriminator and never fire. **This is what killed the keyboard HUD**, and it is the whole reason
  the route above is a measurement rather than a feature. A HUD reports what you just
  did, and there is no reliable way to know whether you did it — so the island lit up as somebody
  carried the Mac into a darker room. Still open as a platform question; no longer a feature waiting
  on it. `SystemHUD` has three cases — `.volume`, `.mute`, `.brightness` — behind two switches
  (`sources.volumeHUD` serves the first two, `sources.displayBrightnessHUD` the third) under the
  `sources.systemHUDs` master. There is no fourth.
- **`setBrightness:forKeyboard:` returns `YES` and does nothing whenever the backlight is suppressed
  or idle-dimmed**, which in a lit room is most of the time. Isleta never writes; this matters
  because driving the hardware is the only way to test this area, and a no-op write looks exactly
  like a broken read.
- **A public iCloud share link IS reachable — this reverses the finding above it, which said it was
  not. Measured 2026-08-23.** `com.apple.CloudSharingUI.CopyLink`,
  invoked as an `NSSharingService`, returns a genuine
  `https://www.icloud.com/iclouddrive/<38-char token>` in **1.68–4.13 s** (median 2.0 s), identically
  from an ad-hoc bundle and from a **Developer ID bundle signed `--options runtime`** — Isleta's own
  shape. **No consent sheet, no alert, no TCC prompt, no Settings row**, including the first
  invocation ever on the account.
  **What was wrong before was the caller, not the conclusion's evidence.** The earlier
  `NSCocoaErrorDomain 4099` came from calling `BRShareCopyShareURLOperation` **ourselves**; asking
  the *extension* is a different caller, and `bird` then does the CloudKit work in its own name —
  `cloudd` logs `TCC approved access for container com.apple.clouddocs … applicationBundleID=
  com.apple.bird`. That is the Perl/`mediaremoted` shape, not the `TUCallCenter` one: a path we can
  walk, not a door. **The lesson generalises past this API — "the daemon refused us" and "the daemon
  refuses this operation" are different findings, and only the second one closes a door.**
  Three things about it decide any code that uses it. **The link comes back only on the
  pasteboard**: `didShareItems` fires and hands back an `NSItemProvider` that is the *input* — its
  `public.url` loads as the 116-byte *file* URL. The callback is the signal, `NSPasteboard.general`
  is the channel, and `changeCount` had already advanced by the time the callback ran, every time.
  **Never trust the pasteboard without a `changeCount` delta** — most users have a URL on their
  clipboard, and without that guard a request that wrote nothing hands them their own clipboard back
  and calls it a share link. And **`NSSharingService` has a state where no callback arrives at all**:
  one invocation returned neither success nor failure in 120 s, with `bird` logging a denial and
  never starting the operation, and `sample` showing the extension *idle* rather than blocked. A
  deadline is mandatory.
  Two cheaper facts from the same session: a non-iCloud file fails in **146 ms** with 4099 and is not
  copied into iCloud, so eligibility is decided locally first (`URLResourceValues.isUbiquitousItem`);
  and **`ubiquitousItemIsUploadedKey` reads false for a fully-uploaded file** that `brctl status`
  calls caught-up, so waiting on it waits forever.
- **The superseded finding, kept because the inference is instructive.**
  `NSSharingServiceNameCloudSharing` reads like the answer and shares a `CKShare` over your own
  container's records rather than producing a link; no service in `sharingServices(forItems:)`
  produces one, under any mask or `collaborationMode`. `com.apple.CloudSharingUI.CopyLink` is
  missing from every list because its Info.plist carries `AvailableInServiceMenu = false`, a menu
  suppression rather than a permission. **`canPerform` answering true is not evidence a service will
  do anything**: it answered true for a file on `/private/tmp` that iCloud has never seen — and
  the earlier probe's claim that it is *false* for a synced file is also wrong, it answered
  **true** inside `com~apple~CloudDocs`. So it is useless as a discriminator in both directions and
  the shipping code never calls it. Finder is
  not scriptable for this — its `sdef` has no share or link command and its one `copy` verb is
  documented by Apple as "(NOT AVAILABLE YET)". AirDrop works (`NSSharingService(named:
  .sendViaAirDrop)`) and **cannot be targeted**: `recipients` has no meaning for it, and the
  `SFAirDropBrowser`/`SFAirDropTransfer` API that would target it is a sixth private path for a
  picker Apple already draws well. And `pbcopy` of a `file://` URL is not a share link, however much
  it looks like one — it resolves for exactly one person on Earth.
- **Full Disk Access is walled at the *read*, not at the `stat` — so the cheap check lies.** Measured
  2026-08-23 with no grant: `ls -l ~/Library/Messages/chat.db` succeeds and reports 217 MB, while
  `head -c 16` on the same path answers **Operation not permitted** and `sqlite3` answers
  "authorization denied". A probe that checks the file exists, or checks its size, concludes FDA is
  granted and then fails on the first query. **Third-party group containers are walled the same
  way** — `…desktop.WhatsApp` and `…slackmacgap` are as closed as `group.com.apple.usernoted` — so
  "just read the other app's local store" is an FDA feature, not a free one, and it needs that app
  installed and running as well.
- **WeatherKit is a real macOS API and works for a Developer ID app — but claiming its entitlement
  without an embedded provisioning profile SIGKILLs the process with no crash report. Measured
  2026-08-23.** The framework ships in the MacOSX26.5 SDK with a native
  `arm64e-apple-macos.swiftinterface` in which `grep -c "macOS, unavailable"` returns **0** —
  `WeatherService` is `@available(macOS 13.0)` and a probe compiled, linked and bound to it, so **the
  ActivityKit rule does not apply here**. Xcode's own portal cache lists `DEVELOPER_ID` among
  WeatherKit's distribution types, which is not a default: 25 of the 83 macOS capabilities in that
  file do not carry it. Three states: **no entitlement** fails in 184–189 ms with
  `WDSJWTAuthenticatorServiceProxy.Errors.xpcConnectionFailed(… com.apple.weatherkit.authservice)`,
  NSCocoaErrorDomain 4097 — which is *not* `WeatherError.permissionDenied` and reads as broken XPC
  plumbing rather than a permission; **entitlement with no embedded profile** exits **137 (SIGKILL)**,
  no stdout, no stderr, no `.ips`, with `AMFI: Unsatisfied Entitlements` in the kernel log;
  **entitlement plus a Developer ID provisioning profile at `Contents/embedded.provisionprofile`**
  works. `codesign` accepts the entitlement without complaint either way — the gate is at `exec`, and
  it is not WeatherKit-specific (an invented `com.tryisleta.nonsense` died identically, while
  `com.apple.security.network.client` alone ran fine). **This is the 1.3.0 Bluetooth abort's shape
  again**, so `open -a Isleta` is the only check that can see it. Isleta claims the entitlement in
  `Config/Isleta.entitlements` (Release only — Debug is ad-hoc signed and omits it) and embeds
  `Config/Isleta.provisionprofile`, so two release-checklist consequences follow: Apple evaluates a
  Developer ID profile's validity **at every launch**, and editing the App ID's capabilities
  invalidates every existing profile for it. Ask the *running task*
  (`SecTaskCopyValueForEntitlement`), never the bundle plist — the plist is what was asked for and
  the task is what was granted. `WeatherKitProvider` is the third provider-with-a-null-fallback in
  this codebase and holds the four portal steps. The REST route (service ID, private key, JWT) is for
  servers; the native framework mints its own token. Quota is 500,000 calls/month pooled **per Team
  ID across every app on the team**, not per app, so the refresh interval is a business decision with
  a floor.
- **`.authorizedWhenInUse` does not exist on macOS, and Swift refuses to compile the comparison.**
  `CLLocationManager.h:73` marks `kCLAuthorizationStatusAuthorizedWhenInUse`
  `API_AVAILABLE(ios(8.0)) API_UNAVAILABLE(macos)`, though `requestWhenInUseAuthorization()` itself
  does exist. After granting a *when-in-use* request the status a Mac reports is
  **`.authorizedAlways` (raw 3)**, so any code gating on when-in-use is dead here — and it is the
  first case somebody writing this from memory adds. **Location is also not a TCC service**:
  `kTCCServiceLocation` is absent from `tccd`'s table and authorization lives in
  `/var/db/locationd/clients.plist`, so a missing usage string does **not** abort the process the way
  a missing `NSBluetoothAlwaysUsageDescription` does — measured, a probe with no location key still
  raised a prompt and was granted. Good for crash risk, bad for discipline: the missing string is
  invisible in testing and shows the user a prompt with no reason on it. One `requestLocation()` per
  refresh, not `startMonitoringSignificantLocationChanges` — that fires on ~500 m of movement,
  registers a persistent client, and per its header exists to relaunch apps in the background. A live
  `CLLocationManager` costs 0.0007–0.0013% idle (the work is in locationd) and a warm fix is **7 ms**,
  so the choice is shape and not cost. locationd stores a per-client designated requirement, so a
  Debug build's location grant dies on every rebuild exactly as its Accessibility grant does.
- **EventKit needs `NSCalendarsFullAccessUsageDescription`, and the no-key case is a silent 9 ms
  loop rather than a crash.** Measured on macOS 27: with the FullAccess key, a prompt and
  `granted=true` at 1,988 ms; with only the legacy `NSCalendarsUsageDescription`, still a prompt at
  2,339 ms (`tccd` carries all three names and falls back — a fallback, not a license); **with no
  calendar key at all, `granted=false, err=nil` in 9 ms, no prompt, nothing logged, and the status
  stays `notDetermined` rather than `denied`** — so **never retry on `.notDetermined`**, or the
  source asks forever nine milliseconds at a time and never advances. Call
  `requestFullAccessToEvents`: write-only access authorises *saving* and returns no calendars to
  read. **A denied calendar is indistinguishable from a user who owns no calendars** — measured on a
  genuinely denied store, `sources.count == 0`, `calendars(for:).count == 0`,
  `defaultCalendarForNewEvents == nil`, the predicate builds fine, and `events(matching:)` returns
  `[]` in **1–4 ms without throwing** — so `EKEventStore.authorizationStatus(for:)` is the only
  discriminator there is, and the empty-state copy has to be chosen from it: "Grant access in
  Settings" and "Nothing else today" are the same zero. `.EKEventStoreChanged` is genuine push at
  **8–10 ms** and **fires twice for one edit, ~2 s apart**, so coalesce or that is two islands for
  one thing the user did — and every `EKEvent` held across it is invalid on receipt, so re-run the
  predicate and never diff stale objects. `predicateForEvents(withStart:end:calendars:)` silently
  clamps any range longer than four years. Keeping a store alive costs **0.0010%** and +0.7 MB; a
  warm 1-day fetch is 2 ms. Expect `tccutil reset Calendar com.tryisleta.isleta` to join the
  Accessibility reset in the dev loop, for the same rebuild reason.
- **A meeting's join URL is in `EKEvent.notes`, not in the field named for it.** Occupancy over 33
  real events: `url` **7/33**, `notes` **30/33**, `location` **8/33** — every http(s) join link was
  in `notes`, and `location` contained zero http(s) hosts at all, so an implementation that reads
  `event.url` first finds a link in under a quarter of events. Parse `notes` → `url` → `location`.
  **`EKEvent.conferenceURL` — the private property that is exactly what you would reach for — was
  nil on all 33**: the private surface is there, and has a measured payoff of zero. The
  **`dialin.teams.microsoft.com` exclusion is part of the pattern set, not a refinement of it**: that
  host ends in `teams.microsoft.com`, matches any naive rule, sits *above* the real link in a real
  invitation, and opens a page of phone numbers. Event titles, notes, locations, attendee names and
  meeting URLs are user content and go through `IslandLog` at no level — counts and enum values only.
- **Calls cannot be observed by a Developer ID app, and every API for it succeeds while answering
  nothing. Measured 2026-08-23.** `CallKit` really is in the macOS
  binary — its `.tbd` exports `CXCall`, `CXCallObserver` and 80 more classes for `arm64e-macos`, so
  this is **not** the ActivityKit shape — and `TUCallCenter` (TelephonyUtilities) has exactly the
  fields a call island needs plus `answerCall:` and `disconnectCall:withReason:`. From an unentitled
  app both instantiate, `TUCallCenter`'s **provider manager comes back populated from a successful
  XPC round trip**, `CXCallObserver` accepts a delegate — and `currentCalls` returns `__NSArray0`
  forever. Nothing errors, nothing throws, nothing logs **in our process**; the refusal is written
  only to `callservicesd`'s log, about us: *"Rejecting client for …callstatecontroller because it
  lacks the access-calls capability"*. The gate is `com.apple.telephonyutilities.callservicesd`,
  which `/System/Applications/FaceTime.app` holds and **no third-party app on this machine does** —
  not WhatsApp, not Zoom, not Slack. This is a locked door, not a private path: `mediaremoted`
  answers Perl because there is an interpreter whose code-signing identifier begins `com.apple.`, and
  there is no process we can borrow here. **The test that tells the two apart is cheap and should be
  run first against any future candidate: stand the client up from an app bundle and read the
  daemon's log, not your own.** FDA buys only `CallHistory.storedata`, whose rows carry a `duration`
  and are therefore complete only once the call is over. FaceTime is not scriptable (`sdef` → -192,
  the Clock.app finding again) and its URL schemes only *start* calls. And the ~200
  `TUCall*ChangedNotification` names in the binary are **not a bus** — they are `NSNotificationCenter`
  names posted inside `TUCallCenter`'s own process after the XPC we are refused, which is the
  `MTTimerManager*` mistake in a new framework. What *is* readable, ungated and push: that a call is
  **live** — `kAudioHardwarePropertyProcessObjectList` names the process holding the microphone with
  no permission, and `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input fires 105 ms
  after real audio starts. Who is calling is not readable at all.
  **Use the device property for the edge and the process list only for the name, never the reverse.**
  Measured 2026-08-23 on a completely idle Mac: the process list reports `corespeechd(in=1,out=1)`
  **permanently**, because that is the always-on hot-word listener, while the device-level property
  reads **0** across three reads two seconds apart. So a source that enumerates process objects and
  treats `IsRunningInput == 1` as "a call is live" fires forever on an idle machine. That is the
  version somebody writes next; the shipped one is correct.
- **On-device transcription needs no permission, and the API named for asking is the one that would
  break it. Measured 2026-08-23.** `SpeechAnalyzer`/`SpeechTranscriber`
  are the *opposite* of the ActivityKit case — the macOS `.swiftinterface` is built for
  `arm64e-apple-macos26.5` and carries no `@available(macOS, unavailable)` anywhere. A
  hardened-runtime app **with no `NSSpeechRecognitionUsageDescription` at all**, launched with
  `open -a`, transcribed in 0.88 s at `.notDetermined`, with no prompt and nothing in `tccd`'s log.
  **Do not add the usage string and never call `SFSpeechRecognizer.requestAuthorization`** — that
  call is the only thing here that needs the key, and adding it puts a Speech Recognition row in the
  user's System Settings for a feature that never asks.
  **`SFSpeechRecognizer` silently eats the first three minutes of a long file**: a 232 s file came
  back as one final whose *first* segment timestamp is 180.18 s, `isFinal` true, no error, the end
  timestamp correct, 914 characters against `SpeechAnalyzer`'s 4,024. The documented one-minute limit
  arrives as a plausible tail rather than as an error. Use `SpeechAnalyzer`.
  **`AVAudioFile(forReading:)` is the whole decoder** — MP4 and MOV open because it pulls the audio
  track, so the `AVAssetReader` step everyone writes first is unnecessary — but **a video with no
  audio and a corrupt file throw indistinguishably** (`'dta?'` vs `'wht?'`), so ask
  `AVURLAsset.loadTracks(withMediaType: .audio)` to tell them apart.
  **A missing language model reports itself as `unexpectedAudioFormat` (code 3)** on a file that
  transcribes perfectly in `en-US`, which sends you to `AVAudioConverter` for an afternoon;
  `SFSpeechError.noModel` exists, is 4, and is not what you get.
  **The memory is not in our process and is bound to our lifetime.** In-process peak is 23.9 MB and
  *flat* regardless of file length, idling at 0.006% of a core — but `localspeechrecognition.xpc`
  holds 53 MB after one run and **112 MB after four, and never shrinks**.
  `SpeechModels.endRetention()`, the API named for exactly this, did nothing measurable; only the
  client exiting freed it, and `await SpeechTranscriber.installedLocales` alone spawns the helper.
  Isleta never exits, so transcription belongs in a **short-lived child process** — the
  `NowPlayingAdapterReader` shape, with the same synchronous-teardown-through-to-`waitpid` obligation.
  Throughput is 34–57× realtime (31 minutes in 32.67 s, first text in ~300 ms), so the island can
  draw words as they arrive rather than a spinner.
- **`notify_register_dispatch` returns 0 for any string, including one you invented — and
  `DistributedNotificationCenter`'s wildcard observer is inert. Measured 2026-08-23.**
  Three nonexistent names (`com.apple.THIS.NAME.DOES.NOT.EXIST.ANYWHERE`
  among them) all registered with status 0, so **registration status is never evidence a name is
  real**. `addObserver(name: nil, object: nil)` caught **zero** notifications on macOS 27.0 — in both
  the Foundation and `CFNotificationCenter` spellings, including one the same process posted, which a
  *named* observer on the same center received 1:1. Wildcard name-discovery is dead as a technique,
  and any "nothing is on the distributed bus" conclusion reached that way is evidence of nothing.
  Related: **`__cfstring` is absent from every segment of a dyld-shared-cache framework** —
  `getsectiondata(mh, "__TEXT", "__cfstring")` returns nothing for cache-resident images and only
  `__cstring` works, so a `__cfstring` sweep silently returns zero and reads as "no such string".
- **`kIOPSNotifyAnyPowerSource` is a once-a-minute heartbeat, not a change signal.** Measured over
  315 s idle on AC at 100% with nothing changing: **5 fires at exactly 60.003 s intervals**, snapshot
  byte-identical each time, confirmed against `pmset -g pslog` at the same instants — it is powerd's
  periodic refresh, and a source registered on it wakes once a minute forever for nothing. Every
  *specific* key fired zero times in the same window: `IOPSNotificationCreateRunLoopSource`,
  `.source`, `.timeremaining`, `.lowbattery`, `.attach`. Register the specific names, and **still**
  coalesce on ~100 ms and diff the snapshot — under load the aggregate fired 3 times in 39 ms, two in
  the same millisecond, with identical content. `com.apple.system.powersources.percent` is in IOKit's
  string table and **not in the public header**; it is the right name for a battery-level activity.
  Never render the estimate raw: on AC it is `kIOPSTimeRemainingUnlimited` (**−2.0**) with the
  IORegistry reading the sentinel **65535**, and while calculating it is **−1.0**. Low Power Mode is
  `NSProcessInfoPowerStateDidChangeNotification` (Darwin `com.apple.system.lowpowermode`, in
  **Foundation**, not IOKit — `com.apple.system.powermanagement.lowpowermode` registers successfully
  and does not exist), and its handler is **posted on the global dispatch queue**, which is the
  IOBluetooth trap's shape: mark it `nonisolated` and hop.
- **Download progress is reachable for Safari and not for Chromium, and the plist that looks like the
  answer is walled.** Measured while building the download island, **which is withdrawn** — the
  measurement is about the browsers and the filesystem and outlives it; there is no download
  progress island, no source and no setting. Safari's `<name>.download` is a *package directory* with no `Info.plist` and no
  metadata — but it carries **`com.apple.progress.fractionCompleted`**, updated live about every
  2.3 s, each update raising a `.attrib` vnode event. One `DispatchSource` plus one `getxattr` gives
  real percent, push, free, no permission. Chromium sets **no progress xattr at all** (grep count
  across a full download: 0) and names the part file `Unconfirmed NNNNNN.crdownload` until the
  instant it finishes — so bytes-so-far is available and **percent and the filename are not**.
  `~/Library/Safari/Downloads.plist` **looks readable and is not**: `ls` shows `-rw-r--r--` and
  `stat` reports its size changing across a download, so a size-watcher appears to work, while `head`
  answers "Operation not permitted". Also measured: **Safari silently refuses plain-`http://`
  downloads from localhost** — no file, no error, nothing on the bus — while `https://` works first
  time, which will cost an afternoon to anyone testing this with a throwaway server.
- **Nothing reports that the screen is being recorded, and the two calls named for it answer a
  different question.** `CGDisplayIsCaptured` and `SLDisplayIsCaptured` were **false throughout** a
  real ScreenCaptureKit recording with the purple indicator up — they are *exclusive display
  capture*, for fullscreen games. `CGSessionCopyCurrentDictionary()` changed **not one key**; twenty
  candidate Darwin names fired zero times; SkyLight's 2,915 exports contain nothing. The real chain
  is `screencapture` → `SCStream` → `replayd` → `STMediaStatusDomainPublisher` → ControlCenter, and
  StatusKit refuses unentitled clients in its own words (*"Client is attempting to access StatusKit
  subscription information… but is not entitled"*, with `hasSCKSystemRecordingEntitlement=0` printed
  for our caller). The only route that works is an `AXObserver` on `com.apple.controlcenter` — silent
  when idle, then 3 × `AXCreated` + 3 × `AXWindowCreated` in the same millisecond — and **the created
  windows carry no title, no description and no identifier**, with `AXWindows` empty and no
  `AXMenuBar` at all on macOS 27. So the signal says "ControlCenter put something up" and camera,
  microphone and location would presumably look identical.
- **Focus is a gate, not an activity, and `isFocused` gives the same confident answer whether or not
  you are allowed to ask.** `INFocusStatusCenter.default.focusStatus.isFocused` returned
  `Optional(false)` — a definite `false`, not nil — while `authorizationStatus` was
  `.notDetermined`, and the same value after authorization. Gate every read on
  `authorizationStatus == .authorized`, or the island tells a user with Do Not Disturb on that no
  Focus is active. Key: `NSFocusStatusUsageDescription`; `requestAuthorization` returned
  `.authorized` after 8.42 s. **There is no change notification** — the header declares two
  properties and one method and no constant, and `DoNotDisturb`, `DoNotDisturbKit` and
  `Focus.framework` carry no Darwin names for state, only private XPC. So read it *once, when an
  activity is about to be published*, and never on a timer.
- **`com.apple.LaunchServices.applicationRegistered` is the cleanest system signal measured**, and
  nothing consumes it: the app-installed island and the disk island are both withdrawn, so what
  follows is a measurement of the *signals*, not a description of a feature. A
  named distributed notification, push, free, **exactly one callback** per install and per
  version-bump update, **zero** on launch or quit, carrying `bundleIDs` as an **array** (drive off
  the array: one installer, several ids, one notification). The obvious alternative, a vnode watch on
  `/Applications`, is worse — non-recursive, anonymous, and blind to in-place Sparkle updates.
  Beside it, `NSWorkspaceDidMount`/`DidUnmount` is clean (ignore `WillUnmount` or one eject draws two
  islands). Out, measured: **Time Machine** has no push, and its vnode watch is *impossible* rather than late —
  the plist is mode 644 root:wheel and `open(O_EVTONLY)` still returns EPERM, so there is no fd to
  hang a `DispatchSource` on (unlike `mobiletimerd`, where the watch works and is nine seconds
  behind);
  **AirDrop**'s `LSQuarantineSenderName` is empty in all 1,492 rows of `QuarantineEventsV2`;
  **the clipboard has no notification of any kind** — `NSPasteboard.h` declares none, `changeCount`
  is a bare readonly property — and on macOS 26+ `NSPasteboardAccessBehavior` gates content reads and
  notifies the user, so a clipboard history would poll on the idle path *and* accuse itself; and
  **`com.apple.bluetooth.status`** reads like the ideal connect moment and is a telemetry beacon at
  25 fires per 90 s idle.
- **File conversion: seven routes return success and produce garbage, and each is the one you would
  pick first. Measured 2026-08-23.**
  **`NSAttributedString(url:)` reads an XLSX or a PPTX successfully and hands back nothing** — no
  throw, `documentAttributes[.documentType] == NSOfficeOpenXML` (the *correct* type), and
  `length == 0`, which through TextKit is a one-page, 3,740-byte, blank PDF. `textutil` is the same
  importer with a CLI on it and writes a **zero-byte file, exit 0**. Apple's OOXML importer is a
  *Word* importer that recognizes the container family and has no spreadsheet or presentation reader
  behind it.
  **`CGPDFContext` re-encodes every image losslessly**: three photos → **65.7 MB in 1885 ms** (six
  `/FlateDecode`), against **6.5 MB in 497 ms** (three `/DCTDecode`) for the same three pages through
  `CGImageDestinationCreateWithURL(url, "com.adobe.pdf", 3, nil)` — which is documented nowhere as a
  paginator and is ten times better at it.
  **`AVAssetExportSession.supportedFileTypes` answers thirteen types for a file AVFoundation cannot
  open** — the same list as for a working MP4, while `AVURLAsset.load(.isReadable)` throws `-11828`.
  Ask the *asset*; the session will tell you anything.
  **`AVAssetWriter(url:fileType: .mp3)` raises an uncatchable ObjC exception** rather than returning
  an error — `AVFileType.mp3` exists, autocomplete offers it, and it is a *read* type.
  **A background thread touching `NSTextView` aborts the process** via `TUINSWindow` — "NSWindow
  should only be instantiated on the main thread!", also uncatchable — and the trap is that the
  *expensive* half is fine off-thread (`NSAttributedString(url: docx)` 6 ms, `(url: html)` 290 ms),
  so parse-in-background-lay-out-on-main is exactly backwards. Use `NSTextStorage` +
  `NSLayoutManager` straight into a `CGPDFContext`: 62 ms, off-thread, no `NSTextView` anywhere.
  **`NSGraphicsContext(cgContext:flipped: false)` writes a PDF with every glyph mirrored** that has
  the right page count, media boxes, colors and selectable text, differs from the correct one by 800
  bytes, and is invisible to every API. Caught on a screenshot.
  **`CGImageSourceCreateWithURL` on an SVG returns a non-nil source** whose type is nil and count is
  0 — ImageIO has no SVG reader and hands you a live object anyway. SVG is AppKit's
  `NSImage(contentsOf:)`, 23 ms off-thread.
  Two smaller ones: `WKWebView.loadFileURL` into a `.qlpreview` directory **hangs forever** with no
  callback of any kind (the same file in a plain directory loads in 200 ms), and `qlmanage -p` prints
  an exception and **exits 0** while `qlmanage -t` never returns — so any QuickLook route needs a
  hard timeout and a did-a-file-appear check.
- **macOS decodes MP3 and will not encode it, below AVFoundation, and `afconvert`'s own table implies
  otherwise.** `kAudioFormatProperty_EncodeFormatIDs` has no `.mp3` while `DecodeFormatIDs` does.
  `afconvert -hf` lists `'MPG3' = MPEG Layer 3` as a file format and `'.mp3'` as a data format inside
  `m4af`/`caff` — both being a container's ability to *hold* an MP3 stream — and asking for either
  fails with `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')`. MP3 export is an external encoder;
  `lame` is a single 0.35 MB binary with zero non-system dylibs, LGPL, 206 ms for a 10 s file. MKV is
  the same shape: AVFoundation reads no Matroska, and `ffmpeg -c copy` remuxes in 39 ms.
- **Every conversion family breaches the 60 MB resident ceiling while working, and the cheaper-looking
  video presets are the expensive ones.** Peak `phys_footprint` deltas: AVIF **+182 MB**, H.264
  downscale **+452 MB**, multi-image PDF +82 MB, a 2000-row sheet +95 MB, GIF +84 MB, HEIC +53 MB.
  The video figure is **flat in duration** (60 s peaks at 451 MB, 10 s at 442 MB) — a fixed
  allocation in the scaler, not a leak — and `HEVC1920x1080`, which genuinely re-encodes every frame,
  costs +18.5 MB while `1280x720` costs twenty-three times that. Also:
  `AVAssetExportPresetHighestQuality` and `1920x1080` on a 1080p source are **silently passthrough**,
  byte-identical to the Passthrough preset, so **timing a preset is not evidence it re-encoded**. §9's
  60 MB is an *idle* figure; conversion belongs in a child process, which is also the right answer
  for a helper that can wedge on a malformed file.
- **`osascript -e 'tell application "Pages" to name'` answers "Pages" and exits 0 on a machine with
  no Pages installed.** AppleScript resolves the *term* without resolving the application, so the
  property that reads like an identity probe is a literal. `version` errors `-1728`; `running`
  answers false honestly **and does not launch the app**, which is a real exception to the
  launch-on-demand rule above. The correct check is
  `NSWorkspace.urlForApplication(withBundleIdentifier:)`. Related: an iWork `export … as PDF` script
  **fails to compile** (`-2740`) where iWork is absent, because the `PDF` enumerator lives in Pages'
  own sdef — so such a script must be built as a string and compiled at runtime, and the failure to
  expect is a compile error rather than a runtime one.
- **`CLGeocoder` is deprecated in macOS 26 — "Use MapKit" — which under `-warnings-as-errors` is a
  build failure rather than a warning.** `CLGeocoder`, `geocodeAddressString` and
  `reverseGeocodeLocation` are all `API_DEPRECATED(… macos(10.9, 26.0))` in the 26.5 SDK.
  `MKGeocodingRequest` / `MKReverseGeocodingRequest` are the replacements, are equally public and
  need no permission either — which is what keeps "type a city instead of using your location" a
  real answer rather than a degraded one. `MKAddressRepresentations.cityName` is also a better
  answer than the old `CLPlacemark.locality`.
- **No supported API to read other apps' notifications**, and the two unsupported routes are an AX
  observer on the notification UI process (Accessibility) and the Notification Center SQLite store
  (Full Disk Access, undocumented schema, and walled — see the group-container finding above).
  **Notifications are withdrawn**: there is no notification activity kind, no source, no protocol
  and no setting, and the paragraph that stood here was a build plan for them. Everything measured
  about NotificationCenter's own behavior on the way is kept below, because a fact about an API
  outlives the feature that motivated it.
- **Now Playing is entitlement-gated since macOS 15.4.** Path is the vendored
  `ungive/mediaremote-adapter`, which spawns `/usr/bin/perl`; AppleScript/JXA is the fallback; a
  `NullProvider` must keep the UI fully functional. **SIP is not a lever available to this app** —
  not as a policy, as a fact: a Developer ID app that is notarized and shipped to users cannot
  require a machine-wide protection to be switched off, and a build that depends on it is one no
  installed copy would run. Design as if it is on, because for every user it is. **Correction, measured 2026-08-19: Perl holds no entitlement.** `mediaremoted` answers
  `MRMediaRemoteGetNowPlayingInfo` for callers whose *code-signing identifier* begins `com.apple.`,
  and Apple's Perl reports `com.apple.perl` with an empty entitlement set. This is operational, not
  trivia: copying Perl into the bundle, re-signing it with our Developer ID, or pointing at a
  Homebrew Perl each yields a working interpreter that gets refused. `perlExecutable` is a constant
  with a test pinning it, never a setting.
- **The island lives in a private window-server space, and that was the second private-API path.**
  It was written here as "the second and last", which stopped being true three paths later — the
  AirPods battery selectors are the third, `DisplayServicesBrightnessMonitor` the fourth, and the
  rule that capped the count was withdrawn on 2026-08-23. **The count is kept in
  `docs/WORKING-AGREEMENTS.md` and nowhere else**; five ship today. A desktop space composites every
  window it contains into its own picture at the instant a
  slide begins; the island was in that picture and traveled with it. No public signal arrives before
  the picture is taken, and no window property opts out — five were measured, one per panel, all
  identical. A window in a space the user can never switch to belongs to no desktop's picture and
  stays pinned through every slide. `SkyLightOverlaySpace` is that: `SLSSpaceCreate` → absolute level
  `Int32.max` → `SLSAddWindowsToSpaces`, the mechanism boring.notch has shipped since October 2024.
  **The level assignment silently fails and the space is really at 0** — see the
  `SLSSpaceSetAbsoluteLevel` entry below; the window's own level does the ordering, which is why
  nothing surfaced it.
  Held to the same rule as `mediaremote-adapter`: `dlsym` at runtime, behind `OverlaySpaceHost`,
  with `UnavailableOverlaySpace` as the fallback and the occlusion-driven hide as what the fallback
  does. **The space lives in the window server, not in this process** — `tearDown()` on quit is
  synchronous through to it for the same reason `stopAndWait()` is, and a crash leaks one until
  logout. Verified on macOS 27.0: a hosted panel reports **zero** occlusion changes across nine space
  switches where an ordinary one flips on every one; `PassThroughSelfTest` 12/12 and `ClickSelfTest`
  pass with the panel hosted. `CGSSpaceCreate`'s first argument is `1` and nobody documents why;
  boring.notch's note says anything else makes Finder draw desktop icons in the space.
- **The Now Playing *queue* is readable, it pushes, `queue[1]` is the next song, and it is behind
  the same door Perl already walks through — measured 2026-08-23.**
  `MRMediaRemoteRequestNowPlayingPlaybackQueueSync` answers in 15–30 ms for a 25-item window (4–5 ms
  for five) as `/usr/bin/perl`, and returns `kMRMediaRemoteFrameworkErrorDomain` **Code=3, "Operation
  not permitted"** from an ad-hoc CLI — the *identical* gate as `MRMediaRemoteGetNowPlayingInfo`, so
  this is the sanctioned adapter path and not a new private one. Build the request with
  `+defaultPlaybackQueueRequestWithRange:` plus `setIncludeMetadata:`/`setIncludeInfo:`; without
  those the items come back as bare identifiers. Played items are dropped, so index 0 is always the
  current track.
  **The two fields named for the queue are the two that say nothing about it.** `queueIndex` and
  `totalQueueCount` are in the adapter's vocabulary and come back **absent from every payload** with
  36 items queued — the `shuffleMode`/`repeatMode` shape again. Dump `get`, see no queue keys,
  conclude MediaRemote has no queue, and you have read the one part of it that was never going to
  answer.
  Three more lies in the same area. **The notification name in our own vendored header never
  fires**: `kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification` produced zero callbacks, and
  the two that do fire drop the infix — `kMRNowPlayingPlaybackQueueChangedNotification` and
  `kMRPlayerPlaybackQueueChangedNotification`, both in the same millisecond as the info change the
  stream already handles (registration returns void, so a wrong name is silent). **Two of three ways
  to play a queue item return success and do nothing**: `kMRPlay (0)` and `SetPlaybackQueue (122)`
  both answer `1` and change nothing, and only `PlayItemInPlaybackQueue (131)` with the offset *and*
  `kMRMediaRemoteOptionContentItemID` (the plural spelling is inert) actually jumps. And
  **`isCurrentlyPlaying` is 0 on every item including the one that is playing** — the working
  discriminator is positional, index 0 of the returned window. Measure the effect, never the return.
  The queue is the true Up Next: after a skip 36 items became 35 with the new track at index 0, and
  under shuffle the order changed completely while `current playlist` did not move — so `queue[1]`
  is the next song, and the 10-seconds-early peek is that plus `duration - elapsed(now) < 10`, which
  costs one read per track change and no timer. **Fold it into `stream`, never a one-shot**: a
  one-shot `perl … queue` is 60–360 ms because spawn dominates, so one per skip is a process per
  skip. The adapter as vendored cannot express any of this — `mediaremote-adapter.pl` whitelists
  eight function names and `send.m` hardcodes `sendCommand(value, nil)` — which is a three-file fork
  of source we already carry, not a third private path.
- **Lyrics are closed through every Apple route, and the symbols say the opposite.** Measured
  2026-08-23: `MRPlaybackQueueRequest.includeLyrics`, `MRContentItemGetLyrics`, `…GetLyricsURL`,
  `…GetLyricsAdamID`, `lyricsAvailable` and `MRTranscriptAlignment` (the karaoke-timing type) all
  resolve, and against Apple Music subscription tracks with `setIncludeLyrics:YES` every one answers
  **empty with no error**. They are the *provider* half —
  `MRMediaRemotePlaybackQueueDataSourceAddContentItemLyricsCallback` is how an app **supplies**
  lyrics to a remote display; Music renders them in-process and publishes nothing. AppleScript's
  `lyrics of track` is the local file's ID3 field and read length 0; there is no local cache
  (`com.apple.Music/Cache.db` is an ordinary `NSURLCache` of `amp-api` album responses, zero lyric
  entries); the public Apple Music API has no lyrics endpoint. Lyrics are a third-party service or
  they are nothing — and each queue item carries its `iTunesStoreIdentifier`, which is a far better
  match key than a title search.
- **Shuffle and repeat cannot be read back *from MediaRemote*, and on a radio station they cannot be
  set — by anyone.** Narrowed 2026-08-23: Music's own scripting interface *does* read them back
  (`shuffleEnabled=true shuffleMode=songs songRepeat=off`, live, on the same machine where
  MediaRemote reports neither). It does not change the shipped design — the scripting route needs an
  Automation grant the adapter does not — but the claim as it stood was too broad.
  Original finding, unchanged:
  `shuffleMode` and `repeatMode` are in the adapter's vocabulary and come back **absent from every
  `get` and every stream update**, so there is no state to reflect: the island holds these two as
  *what the user asked for*, starting at off. See `NowPlayingRepeatMode`.
  Measured on macOS 27.0, the MRCommand toggles (`send 6`, `send 7`), the adapter's explicit
  `shuffle <mode>` / `repeat <mode>` **and AppleScript's own setters** all returned successfully and
  changed nothing — *on Apple Music radio*, where there is no queue to shuffle. They work on an
  ordinary queue. **The tell is `radioStationHash` in the payload** (`radioStationIdentifier` is the
  other spelling; Music sets the hash and not the identifier). An ordinary queue reports neither.
  This is a capability limit in the same family as `prohibitsSkip` and is drawn the same way — the
  pair stays on screen, dimmed and inert. Note the two limits are **unrelated**: a station usually
  permits skipping, and a stream that forbids skipping still has a queue, so answering both with
  `canSkip` grays the wrong pair in each direction. This is also the trap in testing either one — a
  transport command that silently does nothing looks exactly like a wiring bug, and the difference
  is what is playing at the time.
- **After a skip the player names the new track before it has the cover.** Measured on Music: `get`
  reports the new `contentItemIdentifier` within ~35ms and answers with **no `artworkData` at all**
  for a further ~130ms. So the first ask for any track a user skips to comes back empty, always. The
  re-ask has to be on its own clock — see `NowPlayingArtworkLoader.retryingIdentity` for what
  happens when it is left to the stream instead.
- **The AppleScript fallback is push, not poll.** Music and Spotify post `playerInfo` distributed
  notifications carrying player state, name, artist and album — no permission, no polling. Scripting
  is needed only for the *initial* snapshot, because the notification fires on change. Re-running a
  script to notice changes is a timer by another name and a §9 violation. Music also posts every
  event **twice**, under both `com.apple.Music.playerInfo` and `com.apple.iTunes.playerInfo` with
  byte-identical `userInfo`, so an undeduplicated listener runs `contentSwap` twice per track change.
  And `tell application "Music"` **launches Music** — AppleScript specifiers are launch-on-demand, so
  the naive read opens a music app on a silent machine at every login; guard on
  `NSWorkspace.runningApplications`.
- **`CGShieldingWindowLevel()` is not the lock screen's level, and `+ 1` on it is sixteen levels
  *below* the thing it is trying to beat.** Measured 2026-08-23.
  It returns **2147483628** and belongs to `CGDisplayCapture` — its header says "the shield window
  for the *captured* display", and `CGShieldingWindowID(display)` answers **0** for every display
  here because nothing is captured. loginwindow's lock shield is a different window at
  **2147483646** (the value `Isleta/ScreenLock.swift` already records), eighteen levels higher. So
  the advice everyone gives reads, in code, as though it had thought about it, and is wrong.
  **`Int32.max` is the only value in `Int32` above the shield** — and it is the number
  `SkyLightOverlaySpace` already uses for its space's absolute level. Two more from the same column:
  **AppKit does not clamp `NSWindow.level`** (asked = accepted = reported by the window server, at
  every value up to `Int32.max`, so there is no ceiling to route around), and **anything at or above
  2147483631 is above the cursor** (`kCGCursorWindowLevel` is 2147483630) — which costs a closed
  island nothing and would make a lock-screen surface swallow the pointer wherever it overlapped.
- **`SLSSetWindowLevel` returns `kCGErrorFailure` (1000) and does nothing — and the first attempt to
  measure that was unfalsifiable.** Setting *both* `NSWindow.level` and the SkyLight level makes the
  read-back correct whatever SkyLight did, so the experiment could not fail. Left at 0 in AppKit and
  raised only through SkyLight, it reads back 0. Other `SLS` calls on the same connection answer
  fine, so it is that one call. The lesson generalises past this symbol: **if a probe would report
  success when the thing under test did nothing, it is not a probe.**
- **`canBecomeVisibleWithoutLogin` is about *before login*, which a locked screen is not.** It leaves
  both window-server tag words untouched (`0x200100000000, 0x0` before and after), and throughout a
  locked session `kCGSessionLoginDoneKey` and `kCGSSessionOnConsoleKey` are both **1**. No SkyLight
  symbol is named for the job either: 50 candidates resolved, and
  `SLSSetWindowCanBecomeVisibleWithoutLogin`, `SLSSetWindowIsVisibleOnLoginScreen`,
  `SLSSpaceSetVisibleWithoutLogin`, `SLSSetLoginWindowMode`, `SLSSetWindowSecurityLevel` and eight
  more are **absent**. `SLSGetOnScreenWindowList` does exist and gives session-wide z-order with no
  Screen Recording involved.
- **A login-item helper is not structurally different from Isleta, because locking does not log you
  out.** This supersedes the 2.0 plan's premise, which was that the route to the lock
  screen is a separate helper app because that is the route the competitor took. Measured: with the
  screen locked the Aqua session stays on console and Isleta stays running, with its panels and its
  window-server connection intact — so a helper launched as a login item is **the same kind of
  process in the same session**, and there is no measured mechanism by which it composites where
  Isleta's own panel does not. The only structurally different helper is a LaunchAgent in the
  **LoginWindow** session, which runs before anybody logs in, is where `canBecomeVisibleWithoutLogin`
  actually applies, and has no user calendar or Now Playing to draw — which is not §9.2. **Do not
  create a second target on the strength of the competitor having one.** The cost floor, if one turns
  out to be needed: 12 MB and no measurable CPU for an empty window, plus a second signature inside
  the notarized bundle, an install/uninstall path with a stale-helper-after-Sparkle case, the
  `applicationWillTerminate` teardown obligation twice over, and a shared `UserDefaults` record with
  two writers.
- **The lock screen is reachable, and the lever is the SkyLight *space's* absolute level — not any
  window level.** Measured 2026-08-25, macOS 27.0 (26A5421a), run 14, four arms varying one thing at
  a time, three locked samples each, unanimous.

  ```swift
  let space = SLSSpaceCreate(connection, 1, nil)
  SLSSpaceSetAbsoluteLevel(connection, space, 400)   // the whole answer
  SLSShowSpaces(connection, [space])
  SLSAddWindowsToSpaces(connection, [window.windowNumber], [space])
  ```

  **400 is `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`** — the level macOS uses for
  Notification Center *on the locked screen*. `SkyLightOverlaySpace` already makes exactly these four
  calls and passes **`Int32.max`**, inherited from boring.notch. That is the only thing wrong with it.
  - **The window's level is irrelevant** once the space is right: `CGShieldingWindowLevel()` and
    `Int32.max` both composite above. `SLSSpaceAddWindowsAndRemoveFromSpaces` is not needed either —
    the plain `SLSAddWindowsToSpaces` we already call works.
  - **`Int32.max` was never a valid space level and the getter said so from run 1.**
    `SLSSpaceSetAbsoluteLevel(space, Int32.max)` silently fails and `SLSSpaceGetAbsoluteLevel` reads
    back **0**; asked for 400 it reads back 400. That disagreement was written off as an unreliable
    symbol. **A readback that disagrees with what you set is data, not a broken instrument** — the
    counterpart to this file's usual warning about calls that report success and do nothing.
  - **Nothing on the lock screen receives events — not us, not any competitor.** Every window's
    center routes to loginwindow's shield; it captures all input at the lock by design. **A
    lock-screen surface is a readout, not a control.** Do not ship buttons there that look pressable.
  - **Two instruments, different questions.** `CGWindowListCopyWindowInfo` z-order answers *is it
    painted*; `NSWindow.windowNumber(at:)` answers *would a click land*. The second is right for
    `PassThroughSelfTest`/`ClickSelfTest` and wrong for lock-screen visibility — reading it as the
    first is what produced the retracted entry below.
  - **The shield is at layers 2001–2004** (four windows), not 2147483646 — that number came from
    `ScreenLock.swift`'s comment and had never been measured.
  - It is a private, undocumented space level: gate it, re-measure every OS bump, and make its
    absence a missing feature rather than a broken app.

- ~~**The lock screen is closed — measured behind the shield, 2026-08-25, not inferred.**~~
  **WRONG — superseded above.** Kept because the reasoning failure is the instructive part: ten arms
  all failed, the failure was consistent, the baseline was healthy, and the conclusion was still
  wrong. **A probe with no positive control cannot tell "impossible" from "we did it wrong."** Every
  arm shared one assumption — that a window put up before the lock is the thing to measure — and no
  arm tested that assumption. The competitor was the control, and running it took twenty minutes.
  Original text follows. Ten arms
  (levels 0, 1000, 2147483631, 2147483646, `Int32.max`; `canBecomeVisibleWithoutLogin`; all four
  collection behaviors; a private SkyLight space at `Int32.max`; and `SLSSetWindowLevel`) through
  one lock-and-unlock cycle on macOS 27.0 (26A5421a). **All ten answered `ownsItsPixel=no` in all
  fourteen locked samples**, every one of them naming loginwindow's shield. The unlocked baseline
  had all ten owning their own pixel, so the ten `no`s mean something. Three details decide the
  design and each kills a different plan:
  - **Level is not the mechanism.** The shield measures at layer **2004**, and our windows at
    **2147483647** are composited below it. There is no number to beat. Every proposal that begins
    "raise the level above the shield" is aiming at a comparison the window server is not making —
    it composites the locked screen from loginwindow's windows and leaves everyone else out.
    (2147483646, in `ScreenLock.swift`'s comment and quoted onward as though measured, was wrong.)
  - **The process is alive and scheduled.** Fourteen samples landed on a 250 ms timer behind the
    shield. So a helper app would be scheduled too, and §7's conclusion is strengthened rather than
    merely unrefuted: composition is refused, not execution.
  - **Our windows are excluded, not dimmed.** `SLSGetWindowAlpha` read **1.00** on all ten
    throughout, and seven of the ten dropped out of the on-screen list entirely at the lock.
  That block's closing advice was "what we ship is a wake/unlock moment (Welcome Back) on
  `didWakeNotification` / `com.apple.screenIsUnlocked`; don't call it a lock screen feature". **Both
  ship now**: the welcome-back moment, and a real lock-screen card in `LockScreenSpace` at absolute
  level 400. The half of that advice that survives is "don't spend another session on a *level*" —
  the window level was never the mechanism, and the space's was.
- **`Int32.max` is not a valid space absolute level, and `SkyLightOverlaySpace`'s space has been
  running at level 0 since it was written.** `SLSSpaceSetAbsoluteLevel(space, Int32.max)` **silently
  fails** — `SLSSpaceGetAbsoluteLevel` reads back **0**, while the same call asked for 400 reads back
  400. Measured 2026-08-25 across thirteen runs; the shipping arm is `LockScreenSpace`.
  **An earlier entry here said the opposite** — that the getter was another return value meaning
  nothing, and that the space "demonstrably works" at `Int32.max` — and it was wrong in the
  instructive direction. The island does work, but not for the reason claimed: its *window* level
  does the ordering, so a space stuck at 0 never surfaced. The disagreement between what was set and
  what was read was the whole answer to the lock-screen investigation and was written off as an
  unreliable symbol for thirteen runs. **A readback that disagrees with what you set is data, not a
  broken instrument** — the counterpart to this file's usual warning about calls that report success
  and do nothing.
  `OverlaySpace.swift`'s comment still claims `Int32.max`, and the discrepancy is **deliberately not
  fixed**: the island's behavior is verified on hardware at the level it is actually running at, and
  changing it is a separate change with its own probe. See PROGRESS.md.
- **Suppressing Apple's HUDs: consuming the key at `.cghidEventTap` works — measured 2026-08-30**,
  reversing the two objections that made "ship alongside the system HUD" the answer.
  `HUDConsumeSelfTest` (`--hud-consume-test`), signed Debug build with Accessibility granted, macOS
  27.0 (26A5421a), Mac15,9: phase A passed events through and five volume-up presses moved 0.2000 →
  0.5000 with the HUD appearing; phase B consumed them and five presses moved 0.5000 → **0.5000**
  with **no HUD**. A control phase in the same run is what makes the second half readable.
  `DisplayServicesSetBrightness` writes the panel too (1.0 → 0.75, read back 0.7499999, unentitled),
  so "swallowing a brightness key would leave the user unable to change brightness" was false — the
  same error `SystemHUDBrightness` records for the getter, on the same API family. What is left is
  fidelity, not possibility: Isleta becomes the implementation of the key it swallows.
- **But consuming the key is not on its own enough to suppress the HUD, and that is the second
  measurement of the same day.** Once Isleta swallows the key it has to *write* the level itself,
  and **the CoreAudio write is what wakes `OSDUIHelper`** — the HUD follows the level change as well
  as the keypress. There is no quieter write on this hardware: the default output publishes
  `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and **no per-channel
  `kAudioDevicePropertyVolumeScalar` at all** (measured — `ch1 present: false`, `ch2 present:
  false`), so there is exactly one writable level property and it is the one that draws. This is why
  the shipped mechanism is a freeze on Apple's helper and not the tap alone.
- **`SIGSTOP` on `OSDUIHelper` is the mechanism that ships, and it breaks a rule CLAUDE.md states.**
  This reverses the entry that stood here, which said the SIGSTOP was "the one not to copy" because
  consuming the key needed neither a freeze nor a poll; the measurement above is why. A stopped
  process cannot draw, keeps its process and its ports, and `SIGCONT` puts it back exactly as it
  was — no flicker, no launchd override database write, no `defaults write`. `SystemOSDSuppressor`
  is the implementation and it shells out to nothing: `kill(2)` is a syscall, and forking `killall`
  would put a fork on the volume key.
  **What it costs, said plainly: a `SIGSTOP` outlives the process that sent it.** CLAUDE.md requires
  suppression to be restored on quit *and* on crash and uninstall, and this cannot meet the second
  half — a force-quit or a panic leaves the helper frozen and the user with no volume HUD from
  anything, and nothing on screen naming the app responsible.
  `SystemHUDSuppression.survivesProcessDeath` is **`true`** as of 2026-08-30, a reversal taken by
  the owner with the cost
  named. Three things narrow the exposure: `SystemOSDSuppressor.repairAtLaunch()` runs
  **unconditionally** at every launch before any setting is read, so a crash costs the HUD until
  Isleta next starts rather than until logout; `resume()` is synchronous and runs first in
  `applicationWillTerminate` (a detached `Task` never completes during termination — the
  `applicationWillTerminate` trap in `docs/TRAPS.md` again); and the feature is off by default. The
  way back, if it is judged too expensive, is `suppressible = []`.
  **Nothing polls.** The reference implementation this was taken from (`~/Sites/Atoll`,
  `SystemOSDManager`) re-freezes each respawn from a 150 ms–1 s watcher, because the helper is
  jetsam-exited when idle and respawned on the next key; §9 forbids that outright. Isleta checks
  instead at the one moment it already knows a HUD is wanted — the keypress it is handling
  (`ensureSuspended()`) — which is a user action rather than a clock.
- **What is actually suppressed: volume and mute, and nothing else.**
  `SystemHUDSuppression.suppressible` is `[.volume, .mute]`. `MediaKeyMonitor` in
  `MediaKeyMode.replace` swallows the key, `SystemVolumeControl` does what the key would have done,
  and `VolumeStep` decides where the level lands — sixteen notches, ⇧⌥ quarter-notches, volume-up
  unmuting rather than raising, volume-down walking to zero without muting, and the feedback click
  only when the user's own Sound setting asks for one. **Brightness is deliberately not in the
  set**: the route exists and is measured, but a brightness ramp has a feel of its own and the
  external-display case is unmeasured, and swallowing a key Isleta reproduces badly is worse than
  leaving Apple's HUD in place.
  **The `suppressSystemHUDs` setting is live again.** It and the System pane that held it were
  removed in schema 4, on the argument that a switch that can never move is not made honest by
  graying it; it came back at **schema 23**, off for everybody, now that there is a mechanism behind
  it. `SystemHUDSuppression.apply(enabled:accessibilityGranted:)` answers what the setting will
  amount to on this Mac — without Accessibility the tap receives nothing at all, so it can suppress
  nothing whatever the switch says.
  **`SystemHUDSuppressionTests` is where the reversal is written down.** Four of its assertions were
  inverted on 2026-08-30 and their doc comments say why: they used to pin that nothing was
  suppressible and that nothing outlived the process, which were measured facts for as long as they
  were true. Do not flip `survivesProcessDeath` back to `false` while the SIGSTOP is there — the
  constant exists to make the mitigations around it look necessary, which they are.
- **Two invalid measurements got there first, and both are reusable.** A shell-launched probe
  reported `AXIsProcessTrusted() == true`, a non-nil port and `tapIsEnabled == true` while receiving
  **nothing at all** — no mouse, key or flags events across 20 s on a broad mask. A shell process
  inherits Terminal's grant, and it inherits *the answer, not the capability*; "volume frozen" meant
  "nothing arriving", which is indistinguishable from perfect consumption without a working control.
  Then the in-app version read its phase boundary synchronously inside the tap callback while the
  last pass-through key was still travelling, under-reading by one notch and reporting FAIL.
  **A tap that receives nothing looks exactly like a tap that consumes everything.** Always run a
  pass-through control in the same process, and read a level after the system has had time to act.
- **The four mechanisms that were rejected, and why each failed the restore-after-crash rule.**
  `SystemHUDSuppression` holds them in full. `launchctl disable gui/$UID/com.apple.OSDUIHelper`
  writes launchd's override database, which survives reboot. `launchctl bootout` is session-scoped
  but still outlives the process: after a crash the HUD stays gone until logout. **Killing**
  `OSDUIHelper` as it launches restores itself on the next keypress, so it passes the crash test,
  but it is a race with the thing it is racing to suppress and the HUD gets a frame or two on screen
  before it dies — a visible flicker is worse than the HUD it is hiding. And booting the
  `com.apple.OSDUIHelper` launchd **MachService** agent out and claiming the name would make Isleta
  *be* the HUD with no race and no flicker, and still needs the bootout. The freeze above is a fifth
  mechanism and the only one that never flickers; it fails the same restore-after-crash rule, which
  is the trade that was taken knowingly rather than the one that was overlooked.
- **Re-searched 2026-08-22, and the two frameworks that look like the answer are a client and a
  no-op.** `OSD.framework` is present and loads, and `OSDManager` is the API *behind* Apple's HUD —
  every one of its methods is a `show` (`showImage:onDisplayID:priority:msecUntilFade:`,
  `…filledChiclets:totalChiclets:locked:`, `showFullScreenImage:…`). There is no hide, no mute and
  no suppress on it; it is how you **draw** the system HUD, which is the opposite request. SkyLight
  exports 2,915 symbols and **not one** of them suppresses an OSD, a banner or an alert. So the
  mechanism list is still the four in `SystemHUDSuppression`, plus one that is new and fails the
  same test: `com.apple.OSDUIHelper` is a launchd **MachService** agent, so booting the agent out
  and claiming the name would make Isleta *be* the HUD with no race and no flicker — and it still
  needs the bootout, so a crash still leaves the user with no HUD until logout.
- **Hiding another process's window from outside is the trap that reports success.**
  `SLSSetWindowAlpha(ourConnection, foreignWindowID, 0.42)` returns **0** — the same value it
  returns for our own windows — and `SLSGetWindowAlpha` then reads the window back at **1.0**.
  Measured on five windows owned by three other processes on macOS 27.0. The window server
  validates ownership and answers success anyway, so every "just make Apple's banner/HUD
  transparent" design compiles, runs, logs nothing and changes nothing on screen. `SLSMoveWindow`,
  `SLSSetWindowLevel` and `SLSSetWindowListSystemAlpha` all exist beside it and are all
  connection-scoped in the same way.
### Notification Center, measured while building notifications — which are withdrawn

The five entries that follow were all measured against `com.apple.notificationcenterui` on macOS 27
while the notification island was being built. **That feature is gone** — no activity kind, no
source, no banner takeover, no quick reply, no recents list, no per-app rules, and no setting. The
readings are kept because they are facts about NotificationCenter, Accessibility and the window
server that the next person to reach into that process will need, and because two of them are the
strongest working examples this file has of a private route that reports success and does something
the user would never forgive. Read them as a record of what the API does, never as a description of
what Isleta does. The types they name — `NotificationAXObserverSource`,
`NotificationBannerActions`, `NotificationSource`, the `hidesSystemBanners` setting — do not exist
in the tree.

- **Taking over the notification banner works, and it deletes the user's notifications.** Measured
  end to end on macOS 27.0. A banner element carries `AXPress` **plus three custom actions — "Show
  Details", "Show", "Close"** — and performing Close really does dismiss it: banners live
  **4997/5017 ms** left alone and **1100/1068 ms** when it is performed. But the log says what it
  actually did — `removeDisplayed` *and then* **`removeDelivered`** — and a banner left to expire
  logs neither. So Close is the **✕ button**, not "hide the banner": the notification is cleared
  from Notification Center as though the user had swiped it away, and the only copy left is
  whatever the calling app kept. **There is no action in the list that withdraws the banner and
  leaves the notification delivered**, which is the finding. On top of that it is not even
  fast — the banner is in the tree ~145 ms after the post and takes a further **~1.05 s** to leave
  after Close is asked, so Apple's banner is on screen for over a second regardless. The
  alternative is Apple's own switch — a Focus, or per-app "Deliver
  Quietly" in `~/Library/Preferences/com.apple.ncprefs.plist` — which suppresses the banner
  *properly* and therefore suppresses the only thing we can read: with a Focus on there is no
  banner in the tree, and the notifications still exist only in `usernoted`'s store under
  `~/Library/Group Containers/group.com.apple.usernoted`, which is **Full-Disk-Access walled**
  (verified: denied, from a process that reads `~/Library/Preferences` and `~/Library/Containers`
  fine). `~/Library/DoNotDisturb/DB` is walled the same way, so a Focus cannot be set from here
  either. `INFocusStatusCenter` (Intents, public, macOS 12+, TCC `kTCCServiceFocusStatus`) is the
  supported way to **know** a Focus is on; there is no supported way to turn one on.
- **The banner window can be moved off screen, and that is the one route that hides Apple's banner
  without touching the user's notification. Measured 2026-08-25 on macOS 27.0.** It sits between the
  two dead ends above and is neither of them. NotificationCenter draws banners in an **`AXWindow`
  with subrole `AXSystemDialog`, the size of the whole display**, and `AXPosition` on that window
  reads `settable = YES`. Setting it **moves the window**, and the proof is
  `CGWindowListCopyWindowInfo` — the *window server's* answer rather than NotificationCenter's own,
  which is exactly the cross-check `SLSSetWindowAlpha` fails (it answers 0 and reads back 1.0).
  Four things were measured with it:
  1. **The banner survives the move.** The element stays alive, expires on its ordinary clock
     (3,189 ms in that run), and performing the expand action off screen still grows the
     `AXTextArea` — so **quick reply works on a banner nobody can see**.
  2. **A pinned banner survives it too.** Expanded and hidden, the element was still alive at
     **+40 s**, where an untouched one lives 4,705–4,924 ms.
  3. **The move survives between banners.** NotificationCenter tears its accessibility interface
     down when nothing is on screen (`AXWindows` reports zero) while the window itself persists in
     the window server — and the next banner arrives *into the moved window*: same AX object, still
     at the displaced origin.
  4. **The banner element's own `AXPosition` is `settable = no`**, and setting it returns success
     and does nothing. The window is the thing that moves; the banner is not.
  Two limits go with it. The window is at its origin when a banner arrives, so **Apple's banner is
  visible for as long as it takes to notice**. Measured against two real
  notifications: the window comes on screen at (0, 0) and is off screen **71 ms and 86 ms later**,
  restored ~5 s after that when the banner expires. Apple's banner animates in over roughly 300 ms,
  so what is on screen is the first quarter of a slide-in. And the same window **is** what the
  **Notification Center panel** is drawn in — confirmed the same day by a user who could no longer
  open it. Two things follow, and the second is the one that is not obvious:
  1. The panel draws the delivered notifications in the **same list, with the same subroles and the
     same identifiers a banner has**, in the same window. Nothing in the notification subtree
     separates "a banner is up" from "the panel is open".
  2. **"Something arrived recently" does not separate them either.** Opening the panel re-presents
     every delivered notification, and to a delivery ledger that has not seen them they are all
     arrivals — which, after a launch, is all of them. That version shipped for an hour and took the
     panel away from the user.
  What separates them is **`AXExpanded` on the NotificationCenter *application* element**: measured
  `false` with nothing on screen and `true` for as long as the panel is open, one round trip on an
  element an observer already holds. The rule that was built on it, and the one to rebuild if anyone
  moves that window again: restore the window whenever `AXExpanded` reads true, and treat a read
  that *fails* as open — an OS that renames the attribute then leaves Apple's banners alone rather
  than leaving somebody unable to reach their widgets. And never perform `Close`, so the
  notification stays delivered and is dismissed by the user in Notification Center.
- **Inline quick reply IS reachable, with Accessibility alone — measured 2026-08-23.**
  A reply typed in the notch can be pushed into the system's field and
  sent, and the posting app receives a real `UNTextInputNotificationResponse`. No FDA, no synthesized
  keystrokes, no AppleScript, sub-100 ms of work. **The banner's custom actions are the posting
  app's own**, not a fixed system set — Music offers `Skip`, a reply-capable app offers `Reply`, the
  permission prompt itself offers `Allow`. Performing `Reply` grows an **`AXTextArea`** (not a text
  field, and with no `AXIdentifier`) inside an `AXScrollArea` under the banner element we already
  hold; `AXUIElementSetAttributeValue(field, kAXValueAttribute, …)` returns 0 and really sets it, and
  the sibling `AXButton` sends.
  **The action that opens the field returns -25200 every time and works every time** — the exact
  inverse of the "success for an action that does not exist" trap above, and together they mean
  `AXUIElementPerformAction`'s return value carries **no** information in either direction. A
  wrapper that checked it and fell back would abandon a flow that had already opened.
  Three rules fall out. **Never `CGEvent` the text**: the banner's focus is internal to
  NotificationCenter's window, `AXFocusedUIElement` never becomes the field, so synthesized
  keystrokes go to the user's app. **Never match on "Reply"/"Send"**: those titles come from the
  posting app and are localized — match the `AXTextArea` in the subtree and the `AXButton` after its
  `AXScrollArea`. And **never exit through `Close`**, which still deletes the notification; sending
  dismisses the banner itself within 1.4 s.
  **The cost is that Apple's banner is expanded on screen for the whole exchange — unless the window
  it is drawn in is moved, which the entry above measures `AXPosition` accepting.** Expanded off
  screen, everything below still holds. An
  untouched banner lives 4705–4924 ms; one whose `Reply` has been performed is pinned — still there
  at 45 s — until Send or Close. So reply is a *banner-lifetime* affordance: once it expires the
  element is gone, and any control offered on a list of past notifications has nothing left to act
  on. FDA buys nothing for this: it opens the stored notification, and in every state it unlocks
  there is no banner to reply to.
  **The hardest part is one the probe did not have to answer: *which* action to perform cannot be
  decided structurally.** Nothing separates
  `Reply` from `Allow` or `Skip` except the prose in the action's `Name:` field, which is the posting
  app's and is localized — so the two available designs are to match a string (wrong on the first
  non-English machine) or to perform an app action nobody can identify, which on the permission
  prompt measured in that same session means a background process pressing **Don't Allow** for the
  user. The version that was built took neither: it performed the **system's own expand action, by
  position** — first after `AXPress`, never the last entry, which is the close — and then *looked*
  for the `AXTextArea`, so repliability was detected by the presence of a text-input affordance and
  by nothing else, a banner that grew none was put back the way it was found, and the price was that
  a messaging app whose field appears only under its own named action was not repliable at all. The
  non-destructive exit is the same action again, now the collapse — it un-pins the banner and hands
  it back to its own expiry clock. `Close` remains the thing that must never be performed.
- **The banner's accessibility tree has no icon and no bundle identifier in it.** `AXImageData` is
  an attribute *name* on every element of it and reads nil on all of them, the banner included, and
  the children are three `AXStaticText`s (`title`, `subtitle`, `body`) and nothing else.
  **That is a fact about NotificationCenter's tree and must not be generalised to Accessibility.**
  Measured 2026-08-23 against a **Mac Catalyst** tree (Phone.app, read while idle, no call placed):
  136 elements returned real `AXImageData` of 500 B – 3.7 KB, against 649 returning a non-nil but
  *empty* CFArray. So the attribute does carry bytes on this OS; the banner simply does not fill it.
  The payloads there are glyph-sized, so this moves "can we read a caller's photo" from no to open
  and no further. The
  posting app is only ever the display name inside `AXAttributedDescription` — "Script Editor,
  Title, Subtitle, Body" — so an app icon has to be resolved from that name against the disk. See
  `ApplicationIconResolver`.
- **On the lock screen there is nothing to read, and the logs say the opposite.** With
  `CGSSessionScreenIsLocked = 1`, `usernoted` logs `Presenting … as banner` for a notification that
  was genuinely delivered, and `com.apple.notificationcenterui` reports **zero windows** to
  Accessibility — success, empty, not an error. So a source that trusts the daemon's log will hunt
  for a bug that is the system behaving correctly. (Also measured there: an idle NotificationCenter
  answered `AXWindows` with success and an empty array rather than the -25204 this file documents
  elsewhere, so that refusal is a state it can be in, not one it is always in.)
