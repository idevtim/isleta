# Working agreements

How work is done here: verification, private frameworks, dependencies, persistence, and what to do at a platform wall.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

- **Verify before you build.** Check SDK headers or docs when unsure an API exists on macOS 26;
  state uncertainty out loud.
- **Private frameworks are allowed. Decision 2026-08-23, and it supersedes the rule that stood
  here.** That rule said "no private frameworks except two isolated paths", and the count had already
  reached five. It is now: if a feature needs a private API, use it. What the old rule was *actually*
  protecting is kept, because none of it was about permission — it was about not shipping something
  that breaks silently:
  - **Resolve at runtime** (`dlsym`, `NSClassFromString`, `responds(to:)`), so an OS that removes a
    symbol degrades instead of failing to launch.
  - **Behind a protocol, with a working fallback**, and the fallback is a real feature rather than an
    empty box — `UnavailableBluetoothMonitor` draws the device without the ring; the overlay space
    falls back to the occlusion-driven hide.
  - **Measure it before believing it.** This file is mostly a list of private calls that return
    success and do nothing, and every one of them cost a session. The measurement is the entry fee,
    not the permission.
  - **Read the daemon's log, not your own** (see the Calls bullet). It is the cheap test that
    separates a private *path* — one we can walk, like Perl into `mediaremoted` — from a locked
    *door*, where a daemon checks an entitlement against our code signature and no measurement or
    policy change will open it. `TUCallCenter` is a door. Running into one is a fact to record, not a
    rule to relax.

  **Six paths ship today**, counted by reading the tree rather than by remembering the list:
  1. `mediaremote-adapter` — the vendored Perl helper into `mediaremoted`, including this repo's own
     fork of it, which whitelists the queue and transport commands upstream refuses. The fork widens
     the same path rather than opening a second one, which is why the count moved from five to six
     rather than from five to seven.
  2. `SkyLightOverlaySpace` — SkyLight's space calls, every symbol resolved with `dlsym`.
  3. `SkyLightLockScreenSpace` — the same four SkyLight calls at absolute space level 400, which is
     what puts the lock-screen card above the shield.
  4. `BluetoothDeviceMonitoring`'s battery selectors, guarded by `instancesRespond(to:)`.
  5. `DisplayBrightnessMonitor` — DisplayServices, `dlopen`ed by path.
  6. `com.apple.CloudSharingUI.CopyLink` — the sharing service Apple suppresses from every menu with
     `AvailableInServiceMenu = false`. Resolution here is `NSSharingService(named:)` returning nil
     rather than `dlsym`: the API is public and only the *name* is private. See
     `docs/PLATFORM-CONSTRAINTS.md`.

  `KeyboardBrightnessMonitor` was a seventh and is deleted — not because the path closed, but because
  the HUD it fed was wrong (see `docs/PLATFORM-CONSTRAINTS.md` on the backlight moving on its own).
  **A private path that works is not a reason to ship the feature it enables.** One candidate is
  still open and unbuilt: `SFAirDropBrowser`/`SFAirDropTransfer` (targetable AirDrop, where Apple's
  own picker cannot be addressed) — a whole private surface for a picker Apple already draws well,
  so it is a cost question rather than a policy one. `TUCallCenter` is the door on the other side of
  the same list: `callservicesd` checks `access-calls` against the caller's signature, only FaceTime
  holds it, and no measurement moves that.
- **A large dylib in the bundle costs 250–400 ms on the *first* launch after it is signed, and it
  is code-signature validation rather than I/O.** Measured 2026-08-23 against a 20.5 MiB library.
  First `dlopen` of a freshly-signed copy: **218–386 ms**. Second and
  later: **1.6–2.5 ms**. With the file already fully in the page cache it still cost 266–279 ms, so
  it is not the disk — it is first-load signature validation, cached per-vnode. **Linked rather than
  `dlopen`ed, that whole cost lands before `main()`**: a trivial binary linking it took 0.26–0.33 s
  exec-to-exit against a fresh copy and 0.00 s without it.
  **This explains a number already in PERF.md that had no explanation** — "400.5 ms first launch
  after a build", against a 300 ms budget met at 100–160 ms warm. It is not a build artifact and it
  is not a warm-up: it is the same mechanism, and it will happen to a user on the first launch after
  every Sparkle update. So a dependency of any size is a **launch-budget** question before it is a
  bundle-size one, and the answer for a big one is `dlopen` on demand, off the launch path, at the
  moment the feature is first used.
- **Dependencies are allowed, and are still a cost worth naming in the commit that adds one.**
  Decision 2026-08-23; the rule that stood here allowed only Sparkle and `mediaremote-adapter`. A
  dependency that ships in the bundle is signed inside-out, notarized, and lands on the launch and
  size budgets — say what it costs when you add it, the way the messaging probe costed whatsmeow
  at 45.7 MB and a second long-lived helper process. (A later probe corrected
  both halves of that figure — a minimal helper is 16.3 MiB and a Rust client needs no second
  process — which is the point: the number is only worth anything if somebody measures it.) The §9 budgets are not a restriction on what may
  be built; they are how we find out what something cost.
- Persistence is SwiftData; propose GRDB before adding anything else if a query pattern outgrows it.
  **Exception, measured: the config record is a `UserDefaults` JSON blob.** A `ModelContainer` for one
  `@Model` costs 15–21 ms and ~6 MB at launch against a 300 ms budget currently met at ~96 ms, to
  store a record that was five values when it was measured and is ten stored properties now, with no
  queries, no relationships and no history — the argument scales, the number moved. Migration is
  therefore hand-written (`SettingsMigration`) and runs on the raw JSON *before* `Codable` sees it —
  the only point at which a renamed key is still distinguishable from an absent one. A later
  milestone with a real query pattern gets its own store; it does not drag the config record in.
- Small commits, conventional commit messages, one milestone per branch.
- **A withdrawn feature is a subtraction, not a deprecation.** The code, the vocabulary case, the
  settings control, the shortcut, the strings and the tests all go, so nothing is left whose status
  a later reader has to work out. The *measurements* outlive the code, in the owning module's
  README under "Will not own" and in `PROGRESS.md`, because a fact about an API is not a fact about
  the feature. **Seven have gone this way**, and no doc may describe one as live, planned or
  configurable:

  | Withdrawn | Date |
  |---|---|
  | The app switcher | 2026-08-27 |
  | The app-installed island | 2026-08-27 |
  | Notifications, and everything built on them — rich banners, quick reply, per-app rules, the recents list, link preview | 2026-08-28 |
  | The disk island | 2026-08-28 |
  | The month grid | 2026-08-28 |
  | The player bar | 2026-08-28 |
  | Downloads | 2026-08-28 |
- Every module has a `README.md` saying what it owns **and what it deliberately does not**. Keep
  them current — they are where the layering rules are written down.
- Every permission-gated feature must be tested in the **denied** state.
- When you hit a platform constraint the spec didn't anticipate, **stop and report it** with options
  and tradeoffs — don't route around it silently. Explain reasoning on architectural forks before
  writing the code.
