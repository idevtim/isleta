<div align="center">

<img src="assets/isleta-icon.png" alt="Isleta" width="128" height="128">

# Isleta

**The notch, finally doing something.**

A Dynamic Island for macOS.

[tryisleta.com](https://tryisleta.com)

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)
![Silicon](https://img.shields.io/badge/silicon-Apple-black.svg)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-ff69b4.svg)](https://github.com/sponsors/idevtim)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-%E2%98%95-ffdd00.svg)](https://buymeacoffee.com/idevtim)

</div>

Isleta turns the MacBook notch into a live surface — a Dynamic Island for macOS, done properly.
It stays invisible until it has something to say, then says it in the one place on screen that
was already dark.

> **Status:** v2.0.0 — released.
> [Download Isleta 2.0.0](https://github.com/idevtim/isleta/releases/latest) or get it from [the site](https://tryisleta.com).

---

## Contents

- [Two kinds of thing](#two-kinds-of-thing)
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

## Two kinds of thing

Everything Isleta does is one of two things, and keeping them apart is the whole design.

**Pages** are what you browse. Three of them — **Today**, **Music** and **Weather** — turned with a
two-finger swipe across an open island, with a small indicator under the cutout saying where you
are. They wrap, so there is no end to walk into, and they are always all there whether or not
anything is happening.

**Activities** are what arrives. A volume key, a timer finishing, a call starting, AirPods
connecting. They take the stage because something happened, and they leave on their own.

A feature that announces something you are already looking at is neither, and doesn't ship.

---

## Features

### 📅 Today
- What's next in your calendar, and what the sky is doing, in one surface
- A button that joins the meeting — Zoom, Meet, Teams and the rest, read out of the invitation
- Choose which calendars count, in Settings ▸ Glance

### 🌤 Weather
- Today's high and low against where the temperature sits now, what it feels like, and the chance
  of rain for each of the next few days
- Works from your location, or from a city you start typing and pick from the list
- **When it's raining, it rains in the island** — and the drops land on its bottom edge rather than
  fading out. Snow falls too. Both stop entirely if you've asked macOS to reduce motion

### 🎵 Music
- Album cover in the sliver left of the notch, equalizer in the sliver right
- The equalizer moves with the music and freezes mid-stride on pause
- Long titles scroll and then settle rather than scrolling forever
- The album artwork lends the island its color, and the audio format shows as a small badge
- **Up Next** — the queue your player is actually working through, with the output device,
  favorite and playback speed. Double-click anything in the list to play it
- Works with Apple Music, Spotify, and anything else that reports to the system
- Track changes crossfade in place — the island doesn't reopen

### 🔊 Volume, mute & brightness
- Shows the level you just set, right where your eyes already are
- The bar leans off its own edge when you press past the end of the range, so a key that does
  nothing still says so
- **Isleta can answer the keys itself.** Turn it on under Sources and the island replaces macOS's
  own HUD rather than sitting beside it. Volume and brightness are separate switches, both off
  until you turn them on

### 📂 The shelf
- Drop a file on the notch and it stays there — drag it out whenever you've found where it belongs
- **Or drop files on it to convert them:** images, images to PDF, video, audio, Word, RTF, HTML,
  spreadsheets and presentations
- **Drop audio or video to transcribe it.** The text lands beside the original. Nothing is
  uploaded, and no permission is asked
- **Copy Link** puts a shareable iCloud link on your clipboard. For files outside iCloud Drive the
  row becomes AirDrop, which is the thing that always works
- Search the shelf, preview with Space, and look back through everything Isleta has made for you.
  It survives a restart

### 🎧 Bluetooth devices
- Take your AirPods out of the case and the island shows them beside a ring of how much charge is
  left, for a few seconds, then goes
- AirPods, AirPods Pro, AirPods Max, Beats and anything else that pairs — the ones Apple makes get
  their own picture, everything else gets a generic pair
- The ring turns amber below 20%, the same place Apple's own battery menu starts warning
- Two ear pieces report as the lower of the two — the one that runs out first is the one worth
  knowing about

### 🔒 On the lock screen
- A card showing what's playing. It arrives when the Mac locks and leaves the moment you unlock it
- Off until you turn it on

### ⏱ And the rest of what arrives
- **Timers** started in Clock, counting down in the sliver beside the notch, drawn as Clock's own
  ring — orange while it runs, gray while it's paused
- **Battery and power** — the charger going in and out, a low battery, Low Power Mode
- **A call in progress**, with how long it's been going
- **Welcome back** — a greeting on wake and unlock, in the right language for the hour and your
  time zone
- **Screen sharing**, so you know when you're being watched

### 🌍 In four languages
- English, German, French and Spanish, following your Mac's language

---

## How you use it

At rest the Dynamic Island *is* the MacBook notch: pure black, filling the cutout, invisible by
design. Being invisible is the point, so arriving with the pointer is what announces it — the
island swells a few points past the notch while the trackpad taps once under your finger.

| Do this | Get this |
|---|---|
| Move the pointer onto the MacBook notch | The island peeks — an invitation to click |
| Click | It expands, onto Today |
| **Swipe two fingers across an open island** | **Turn the page — Today, Music, Weather, wrapping** |
| Drag a file onto it | The shelf opens and takes it |
| Flick a closed island left or right | Whatever is on stage stows out of the way. Click to bring it back |
| Swipe up with two fingers | An open island closes. Up is up, whichever way natural scrolling is set |
| Right-click it | Isleta's own menu, including the way into Settings |
| `esc` | It closes |
| `⌃⌥⌘I` | Open and close it from anywhere (rebindable) |
| Menu bar icon | Show Glance, Show Now Playing, Show Weather, Settings, Setup Guide, Export Logs…, Quit |

**Also worth knowing:**

- No Dock icon, no window — Isleta lives in the menu bar, and the menu bar icon can be hidden
- The first launch walks you through eight short screens, five of which are permissions — each
  showing what it's for, and which button to press, before it asks. Skip any of them and the rest
  of Isleta still works
- Clicking the island never steals focus: no title bar flicker, no lost caret
- Transport controls work from a window that never becomes key
- **A list of apps the island stays out of entirely**, for full-screen video or a presentation

---

## Where it appears

- ✅ **On the display with the MacBook notch — and nowhere else.**
  An external monitor has no cutout for the Dynamic Island to be continuous with, so an island up
  there would just be a black rectangle stuck to the top of the screen. A different product.
- ✅ Plug in as many displays as you like — the island stays on the laptop where it belongs.
- ⚠️ **Exception:** a Mac with no notched display at all (mini, Studio, iMac) gets a floating
  Dynamic Island pinned to the top of the primary display, because otherwise there'd be nothing
  to use.

The island is black in a real notch and glass where it floats, and it no longer asks you to choose.
A notch island has to be optically continuous with the bezel and a floating one has nothing to be
continuous with — that was never a matter of taste, so it is no longer a setting.

---

## Settings

Four panes, not seven — and roughly a third as many controls as 1.x had. What went were the
settings that were asking you a question Isleta can answer for itself.

| Pane | What's on it |
|---|---|
| **General** | Launch at login, the shortcuts, whether Isleta shows in the menu bar, the lock-screen card, the apps it stays out of, updates, and — on a Mac with no notch — whether the floating island keeps out of the way until something happens |
| **Sources** | Turn Now Playing, the HUDs, Today, calendar alerts, meetings, timers, Bluetooth devices, power, calls, the shelf, the wake greeting and screen sharing on or off independently — each with what it needs written beside it. Replacing Apple's volume and brightness HUDs lives here too, under the HUD row |
| **Glance** | Which calendars count, and whether the weather uses your location or a city you type |
| **About** | Acknowledgements, Export Logs…, Open Setup Guide, Quit, and everything back to defaults |

Two shortcuts: **Open the island**, which ships bound to `⌃⌥⌘I`, and **Show glance**, which starts
unassigned. Only the first ships with a key, because Isleta has no Dock icon and its menu bar item
can be hidden — a user who hides the icon needs one way back in. Everything else is a key taken
from every other app on your Mac, so nothing else claims one without being asked.

The shortcut recorder reads your actual keyboard layout, so Dvorak and AZERTY users see the key
they really pressed.

---

## Requirements

- macOS 26 or later
- Apple silicon
- A MacBook Pro or MacBook Air with a notch — that notch is where the Dynamic Island for macOS
  lives (see [Where it appears](#where-it-appears) for other Macs)

**Distribution:** direct download, signed with a Developer ID and notarized by Apple.
Not on the Mac App Store — Isleta needs Accessibility and a helper process that reads what's
playing, neither of which the App Store sandbox permits.

---

## Permissions

Isleta asks for as little as it can get away with, as late as it can. Every one of them is asked
by a button you press, never at launch.

| Permission | Needed for | If you decline |
|---|---|---|
| **None** | Volume, mute and brightness levels, timers, the shelf, file conversion, transcription, the wake greeting, power, hover, haptics, the shortcut | — |
| **Accessibility** | The media keys — so Isleta can answer them, and so it can replace Apple's HUD if you ask it to | The island still shows the level; it just can't take the key |
| **Automation** (Music / Spotify) | The one-shot "what's playing right now?" read at launch | You lose the first track of a session, nothing else — live updates need no permission |
| **Calendar** | What's next on Today, meeting links, and calendar alerts | Today shows the weather half only |
| **Location** | Weather where you are | Type a city instead — same weather, no location |
| **Bluetooth** | Hearing a device connect, so AirPods can say hello | No device ever appears; nothing else changes |

Each is explained in Settings, next to the switch it belongs to, along with what stops working if
you say no.

---

## Privacy

- ❌ No account
- ❌ No telemetry, no analytics, no crash reporting service
- ❌ Nothing about you, what you play, where you are, or what's in your calendar is uploaded
  anywhere
- ✅ What's playing and what's on your calendar is read on your Mac, drawn on your Mac, and
  forgotten
- ✅ **Transcription runs entirely on your Mac.** Audio never leaves it, and macOS asks you for
  nothing to do it
- ✅ Isleta keeps a log at `~/Library/Logs/Isleta` — events only, never track titles, file names,
  event titles or serial numbers, so **Export Logs…** is safe to send to a stranger
- ✅ Your settings are a small preferences file in your own user library
- ✅ Exactly two kinds of network request: the weather, and checking whether a new version exists.
  Both are switches. Turn them off and the app never touches the network at all.

---

## Known limitations

- **You cannot see who is calling.** macOS doesn't let apps outside Apple read that, or answer for
  you. Isleta shows that a call is happening and nothing more.
- **A connected device's battery is read once, when it connects.** It doesn't tick down while you
  wear them — macOS gives no signal when the level changes, and Isleta won't poll for one. Most
  non-Apple headphones report no level at all.
- **A timer started by Siri, Shortcuts or Control Center can take a few seconds to appear.** One
  started by hand in Clock is there immediately. macOS gives no signal for the others.
- **Replacing the system HUDs is off until you turn it on, and it needs Accessibility.** Quitting
  Isleta hands your keys straight back. If Isleta is force-quit, the system HUD stays out of the
  way until Isleta next starts. Brightness covers the built-in display only.
- **The island sits above Mission Control.** In a real notch it covers nothing; a floating island
  can sit over the middle of the space labels.
- **The hover target is the notch itself** — about 185 points wide, and easy to overshoot.
- **Weather needs your location, or a city you type.** Isleta asks for neither until you use it.

---

## Feedback & links

- 🐞 **Bugs** — [GitHub Issues](https://github.com/idevtim/isleta/issues)
- 💡 **Ideas** — [GitHub Discussions](https://github.com/idevtim/isleta/discussions)
- 🌐 **Web** — [tryisleta.com](https://tryisleta.com)

Real hardware quirks are especially useful — a display arrangement that confuses it, a music app
it doesn't recognize.

---

## Support the project

Isleta is a one-person project, and free. If it earns its place in your MacBook notch:

- ❤️ [**GitHub Sponsors**](https://github.com/sponsors/idevtim) — monthly support
- ☕ [**Buy Me a Coffee**](https://buymeacoffee.com/idevtim) — one-shot tip

---

## Acknowledgements

- [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg
  and contributors — Now Playing, used under the BSD 3-Clause License
- [**Sparkle**](https://github.com/sparkle-project/Sparkle) — updates, used under the MIT License

---

<div align="center">

**© 2026 Isleta** • Made by [Timothy Murphy](https://idevtim.com)

</div>
