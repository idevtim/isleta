<div align="center">

<img src="assets/isleta-icon.png" alt="Isleta" width="128" height="128">

# Isleta

**The notch, finally doing something.**

A Dynamic Island for macOS.

[tryisleta.com](https://tryisleta.com)

![Version](https://img.shields.io/badge/version-1.3.1-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)
![Silicon](https://img.shields.io/badge/silicon-Apple-black.svg)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-ff69b4.svg)](https://github.com/sponsors/idevtim)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-%E2%98%95-ffdd00.svg)](https://buymeacoffee.com/idevtim)

</div>

Isleta turns the MacBook notch into a live surface — a Dynamic Island for macOS, done properly.
It stays invisible until it has something to say, then says it in the one place on screen that
was already dark.

> **Status:** v1.3.1 — released.
> [Download Isleta 1.3.1](https://github.com/idevtim/isleta/releases/latest) or get it from [the site](https://tryisleta.com).

---

## Contents

- [Features](#features)
- [How you use it](#how-you-use-it)
- [Where it appears](#where-it-appears)
- [Settings](#settings)
- [Requirements](#requirements)
- [Permissions](#permissions)
- [Privacy](#privacy)
- [Known limitations](#known-limitations)
- [Feedback & links](#feedback--links)

---

## Features

### 🎵 Now Playing
- Album cover in the sliver left of the notch, equaliser in the sliver right
- Equaliser moves with the music, freezes mid-stride on pause
- Click in for: track, artist, draggable position bar, prev / play-pause / next, shuffle, repeat
- Works with Apple Music, Spotify, and anything else that reports to the system
- Track changes crossfade in place — the Dynamic Island doesn't reopen

### ⏱ Clock timers
- Start a timer in Clock and the countdown rides in the sliver beside the notch, drawn as Clock's
  own ring — orange while it runs, grey while it's paused
- Music takes the left of the notch and a countdown the right, whichever got there first
- No permission asked, and nothing polled while no timer exists
- A finished timer shows itself the way a volume change does, and leaves Clock's own notification
  to be the thing you click

### 🔊 Volume, mute & brightness
- Shows the level you just set, right where your eyes already are
- Display brightness and the keyboard backlight too, since 1.3.0 — both were listed as impossible
  here for four releases, and neither is: macOS publishes both levels and announces every change,
  just not through the APIs everyone reaches for first
- No permission for any of them, and completely idle between changes
- Appears and dwells for the same beat as Apple's own HUD — alongside it, not instead of it

### 🎧 Bluetooth devices
- Take your AirPods out of the case and the island shows them beside a ring of how much charge is
  left, for a few seconds, then goes
- AirPods, AirPods Pro, AirPods Max, Beats and anything else that pairs — the ones Apple makes get
  their own picture, everything else gets a generic pair
- The ring turns amber below 20%, the same place Apple's own battery menu starts warning
- Two ear pieces report as the lower of the two — the one that runs out first is the one worth
  knowing about

### 🔔 Notifications
- One incoming banner at a time, in the island rather than over the document you're working in
- It opens itself and shows the whole message — who it's from and what it says
- Wears the icon of the app that sent it. Click it and that app comes forward
- **And the ones you missed:** the last twenty, including the ones that arrived while you were
  reading another. Five fit; the rest scroll. Clear All, the ✕ and `esc` are the ways out
- Held in memory only — never written to disk, never in an exported log, gone when Isleta quits

### 📂 The shelf
- Drop a file on the MacBook notch, it stays there
- Drag it out whenever you've found where it belongs

### 👋 Welcome back
- A greeting on wake and unlock
- In the right language for the hour and your time zone

### ⚫️ And when there's nothing on it
- Clicking a quiet island used to do nothing. Since 1.3.0 it opens onto the two things the island
  always has: what you missed, and Settings
- Which is what makes hiding the menu bar icon free — there's still a way into Settings that needs
  no shortcut to remember, and since 1.3.1 **Export Logs…** lives in Settings ▸ About rather than
  only behind the icon

### One thing at a time
- Only one item is on the Dynamic Island at once — the more urgent thing wins
- A volume press interrupts a track; the track is still there underneath when the HUD goes
- One exception, and it's a pair: music left of the notch, a countdown right. Neither needs more
  than one sliver, and the cutout leaves two
- Anything pushed aside stays queued — **swipe across the island** to step through it, or
  **hover an open island** for a row of chips listing everything it's holding. Since 1.3.1 that row
  carries the gear into Settings on every open island, not just a crowded one

---

## How you use it

At rest the Dynamic Island *is* the MacBook notch: pure black, filling the cutout, invisible by
design. Being invisible is the point, so arriving with the pointer is what announces it — the
island swells a few points past the notch while the trackpad taps once under your finger.

| Do this | Get this |
|---|---|
| Move the pointer onto the MacBook notch | The Dynamic Island peeks — an invitation to click |
| Click | It expands — onto whatever is on it, or onto Notifications and Settings if nothing is |
| Hover an open island | A row of chips appears along the bottom — one per thing it's holding, and the gear into Settings |
| Click a chip | That one comes to the front, and stays there for half a minute |
| Click a notification in the list | The app it came from comes forward, and the island closes behind it |
| Swipe across it | Step through whatever is queued behind the current activity |
| Drag a file onto it | The shelf opens and takes it |
| Flick it left or right | It stows out of the way. Click to bring it back |
| Swipe up with two fingers | An open island closes. Up is up, whichever way natural scrolling is set |
| The same flick, with the notification list open | The list scrolls instead — while it's up, the vertical axis belongs to the list |
| `esc` | It closes |
| `⌃⌥⌘I` | Open and close it from anywhere (rebindable) |
| Menu bar icon | Open Isleta Settings, Open Setup Guide, Export Logs…, Quit Isleta |

**Also worth knowing:**

- No Dock icon, no window — Isleta lives in the menu bar, and the menu bar icon can be hidden
- The first launch walks you through four screens: what the notch is about to start doing, the one
  permission Isleta ever asks for, launch at login, and where to find the island
- Clicking the island never steals focus: no title bar flicker, no lost caret
- Transport controls work from a window that never becomes key

---

## Where it appears

- ✅ **On the display with the MacBook notch — and nowhere else.**
  An external monitor has no cutout for the Dynamic Island to be continuous with, so an island up
  there would just be a black rectangle stuck to the top of the screen. A different product.
- ✅ Plug in as many displays as you like — the island stays on the laptop where it belongs.
- ⚠️ **Exception:** a Mac with no notched display at all (mini, Studio, iMac) gets a floating
  Dynamic Island pinned to the top of the primary display, because otherwise there'd be nothing
  to use.

---

## Settings

Five pages, not seven — Settings was cut down in 1.1.0, and a switch that could never be turned on
was removed rather than left in the window making a promise.

| Page | What's on it |
|---|---|
| **General** | Launch at login, trackpad haptics, the global shortcut, and whether Isleta shows in the menu bar |
| **Island** | Hover delay before it peeks and how far, how long a passing activity stays, how long away counts as "away", and island opacity — which appears only if you have a display without a notch, the only place it has ever done anything |
| **Sources** | Turn Now Playing, HUDs, Notifications, Welcome Back, Timers and Bluetooth devices on or off independently, each with what it needs written beside it |
| **Updates** | Automatic checks on or off, plus a Check Now button |
| **About** | Acknowledgements, Export Logs…, and everything back to defaults |

The shortcut reads your actual keyboard layout, so Dvorak and AZERTY users see the key they really
pressed.

---

## Requirements

- macOS 26 or later
- Apple silicon
- A MacBook Pro or MacBook Air with a notch — that notch is where the Dynamic Island for macOS
  lives (see [Where it appears](#where-it-appears) for other Macs)

**Distribution:** direct download, signed with a Developer ID and notarised by Apple.
Not on the Mac App Store — reading notifications requires Accessibility, which the App Store
sandbox doesn't permit.

---

## Permissions

Isleta asks for as little as it can get away with, as late as it can.

| Permission | Needed for | If you decline |
|---|---|---|
| **None** | Volume, mute, display and keyboard brightness, timers, the shelf, wake greeting, hover, haptics, the shortcut | — |
| **Accessibility** | Notifications only — so Isleta can see a banner arrive | Every other feature carries on working |
| **Bluetooth** | Hearing a device connect, so AirPods can say hello | No device ever appears; nothing else changes, and the whole source can be switched off in Settings ▸ Sources |
| **Automation** (Music / Spotify) | The one-shot "what's playing right now?" read at launch | You lose the first track of a session, nothing else — live updates need no permission |

Each is explained in Settings, next to the switch it belongs to, along with what stops working if
you say no.

---

## Privacy

- ❌ No account
- ❌ No telemetry, no analytics, no crash reporting service
- ❌ Nothing about you, what you play, or what your notifications say is uploaded anywhere
- ✅ What's playing and what notifications say is read on your Mac, drawn on your Mac, and forgotten
- ✅ The notifications you missed are held in memory only — never written to disk, never in an
  exported log, gone when Isleta quits
- ✅ Isleta keeps a log at `~/Library/Logs/Isleta` — events only, never track titles or notification
  text, so **Export Logs…** is safe to send to a stranger
- ✅ Your settings are a small preferences file in your own user library
- ✅ Exactly one kind of network request: checking whether a new version exists — a switch in
  Settings. Turn it off and the app never touches the network at all.

---

## Known limitations

- **A burst of notifications opens the island once for each.** The list is where the ones you
  missed go; grouping them as they arrive is a later release's job.
- **A timer started by Siri, Shortcuts or Control Center can take a few seconds to appear.** One
  started by hand in Clock is there immediately. macOS gives no signal for the others, and Isleta
  won't poll for them.
- **The battery is a snapshot, not a readout.** It's read once, when the device connects, and the
  island goes a few seconds later. It doesn't tick down while you wear them — macOS gives no signal
  when the level changes.
- **Third-party headphones may show no battery.** Most non-Apple devices don't report a level to
  macOS at all. They still get their moment in the notch, with no ring beside them.
- **The keyboard backlight HUD can appear when the room light changes.** macOS adjusts the backlight
  for ambient light on its own and doesn't say whether a change came from you or from the room.
  Turn off "Adjust keyboard brightness in low light" if it bothers you.
- **Apple's own HUDs and banners are not replaced.** Isleta shows its own alongside them. For
  notifications the only way to hide Apple's banner is the one the system treats as you clearing the
  notification outright, which would empty your Notification Center as the price of a tidier screen.
  Not a trade Isleta will make for you.
- **The island sits above Mission Control.** In a real notch it covers nothing; a synthesized island
  can cover the centre of the space labels.
- **The hover target is the notch itself** — 185 × 32 points, and easy to overshoot. The hover delay
  and peek amount are both adjustable.
- **Playing music costs more than it should.** About 7.7% CPU against an internal 4% budget for an
  animating island, and a 250–290 MB footprint against a 60 MB one. It isn't a leak — resident
  memory is flat and plateaus rather than climbing — and idle is unaffected.
- **Bluetooth headphones cost something at idle.** With AirPods connected, Isleta sits at about 0.5%
  of a core with nothing on stage, against an internal 0.3% budget; with none connected it measures
  0.02%. Under investigation, and not the AirPods *feature* — switching that source off doesn't move
  the figure.

---

## Feedback & links

- 🐞 **Bugs** — [GitHub Issues](https://github.com/idevtim/isleta/issues)
- 💡 **Ideas** — [GitHub Discussions](https://github.com/idevtim/isleta/discussions)
- 🌐 **Web** — [tryisleta.com](https://tryisleta.com)

Real hardware quirks are especially useful — a display arrangement that confuses it, a music app
it doesn't recognise.

---

## Support the project

Isleta is a one-person project, and free. If it earns its place in your MacBook notch:

- ❤️ [**GitHub Sponsors**](https://github.com/sponsors/idevtim) — monthly support
- ☕ [**Buy Me a Coffee**](https://buymeacoffee.com/idevtim) — one-shot tip

---

## Acknowledgements

- [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg
  and contributors — Now Playing, used under the BSD 3-Clause Licence
- [**Sparkle**](https://github.com/sparkle-project/Sparkle) — updates, used under the MIT Licence

---

<div align="center">

**© 2026 Isleta** • Made by [Timothy Murphy](https://idevtim.com)

</div>
