<div align="center">

<img src="assets/isleta-icon.png" alt="Isleta" width="128" height="128">

# Isleta

**The notch, finally doing something.**

[tryisleta.com](https://tryisleta.com)

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)
![Silicon](https://img.shields.io/badge/silicon-Apple-black.svg)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-ff69b4.svg)](https://github.com/sponsors/idevtim)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-%E2%98%95-ffdd00.svg)](https://buymeacoffee.com/idevtim)

</div>

Isleta turns the black cutout at the top of your MacBook into a live surface. It stays invisible
until it has something to say, then says it in the one place on screen that was already dark.

> **Status:** v1.0.0 — feature complete, in testing.
> No public build yet. Watch this repo or [the site](https://tryisleta.com) for the first download.

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
- Track changes crossfade in place — the island doesn't reopen

### 🔊 Volume & mute
- Shows the level you just set, right where your eyes already are
- Appears and dwells for the same beat as Apple's own HUD — alongside it, not instead of it

### 🔔 Notifications
- One incoming banner at a time, briefly
- Doesn't cover what you're working in

### 📂 The shelf
- Drop a file on the notch, it stays there
- Drag it out whenever you've found where it belongs

### 👋 Welcome back
- A greeting on wake and unlock
- In the right language for the hour and your time zone

### One thing at a time
- Only one item is on the island at once — the more urgent thing wins
- A volume press interrupts a track; the track is still there underneath when the HUD goes
- Anything pushed aside stays queued — **swipe across the island** to step through it

---

## How you use it

At rest the island *is* the notch: pure black, filling the cutout, invisible by design. Being
invisible is the point, so arriving with the pointer is what announces it — the island swells a
few points past the notch while the trackpad taps once under your finger.

| Do this | Get this |
|---|---|
| Move the pointer onto the notch | The island peeks — an invitation to click |
| Click | It expands |
| Swipe across it | Step through whatever is queued behind the current activity |
| Drag a file onto it | The shelf opens and takes it |
| `esc` | It closes |
| `⌃⌥⌘I` | Open and close it from anywhere (rebindable) |
| Menu bar icon | Settings, Copy Diagnostics, Quit |

**Also worth knowing:**

- No Dock icon, no window — Isleta lives in the menu bar
- Clicking the island never steals focus: no title bar flicker, no lost caret
- Transport controls work from a window that never becomes key

---

## Where it appears

- ✅ **On the display with the notch — and nowhere else.**
  An external monitor has no cutout for the island to be continuous with, so an island up there
  would just be a black rectangle stuck to the top of the screen. A different product.
- ✅ Plug in as many displays as you like — the island stays on the laptop where it belongs.
- ⚠️ **Exception:** a Mac with no notched display at all (mini, Studio, iMac) gets a floating
  island pinned to the top of the primary display, because otherwise there'd be nothing to use.

---

## Settings

| Setting | What it does |
|---|---|
| **Sources** | Turn Now Playing, HUDs, Notifications and Welcome Back on or off independently |
| **Timing & feel** | Hover delay before it peeks, how far it peeks, how long a passing activity stays, how long away counts as "away", floating-island opacity |
| **Shortcut** | Rebind `⌃⌥⌘I` to anything (reads your actual keyboard layout — Dvorak and AZERTY users see the key they really pressed) |
| **Haptics** | Trackpad haptics on or off |
| **Delights** | Occasional delights on or off |
| **Updates** | Automatic checks on or off, plus a Check Now button |
| **Startup** | Launch at login |
| **Reset** | Everything back to defaults |

---

## Requirements

- macOS 26 or later
- Apple silicon
- A MacBook Pro or MacBook Air with a notch (see [Where it appears](#where-it-appears) for other Macs)

**Distribution:** direct download, signed with a Developer ID and notarised by Apple.
Not on the Mac App Store — reading notifications requires Accessibility, which the App Store
sandbox doesn't permit.

---

## Permissions

Isleta asks for as little as it can get away with, as late as it can.

| Permission | Needed for | If you decline |
|---|---|---|
| **None** | Volume, mute, the shelf, wake greeting, hover, haptics, the shortcut | — |
| **Accessibility** | Notifications only — so Isleta can see a banner arrive | Every other feature carries on working |
| **Automation** (Music / Spotify) | The one-shot "what's playing right now?" read at launch | You lose the first track of a session, nothing else — live updates need no permission |

Each is explained in Settings, next to the switch it belongs to, along with what stops working if
you say no.

---

## Privacy

- ❌ No account
- ❌ No telemetry, no analytics, no crash reporting service
- ❌ Nothing about you, what you play, or what your notifications say is uploaded anywhere
- ✅ What's playing and what notifications say is read on your Mac, drawn on your Mac, and forgotten
- ✅ Your settings are a small preferences file in your own user library
- ✅ Exactly one kind of network request: checking whether a new version exists — a switch in
  Settings. Turn it off and the app never touches the network at all.

---

## Known limitations

- **No brightness HUD.** Changing brightness is behind an entitlement Apple keeps for itself, and
  nothing in macOS announces it, so there's no supported way for Isleta to know it happened.
  Apple's own HUD handles brightness; Isleta says so in Settings.
- **Replacing the system HUDs** (rather than appearing alongside them) is written, off by default
  and greyed out. The switch goes live once there's a mechanism behind it that can be undone
  reliably if Isleta ever crashes.
- **The open island is a fixed size**, not sized to whatever is inside it.

---

## Feedback & links

- 🐞 **Bugs** — [GitHub Issues](https://github.com/idevtim/isleta/issues)
- 💡 **Ideas** — [GitHub Discussions](https://github.com/idevtim/isleta/discussions)
- 🌐 **Web** — [tryisleta.com](https://tryisleta.com)

Real hardware quirks are especially useful — a display arrangement that confuses it, a music app
it doesn't recognise.

---

## Support the project

Isleta is a one-person project, free while it's in testing. If it earns its place in your notch:

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
