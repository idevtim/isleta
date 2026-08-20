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

Isleta turns the black cutout at the top of your MacBook into a live surface — what's playing,
the volume you just changed, the notification that just landed, a file you're carrying from one
window to another, a greeting when you open the lid. It sits there invisibly until it has
something to say, and it says it in the one place on the screen that was already dark.

> **Status:** version 1.0.0, feature complete and in testing. No public build is published yet —
> watch this repo or the site for the first download.

---

## What the island shows

- **Now Playing** — the album cover in the lit sliver to the left of the notch and an equaliser in
  the sliver to the right, moving while the music plays and frozen mid-stride the moment it pauses.
  Click in for the track, the artist, a draggable position bar, previous / play-pause / next, and
  shuffle and repeat. Works with Apple Music, Spotify and anything else that reports to the system.
  A track change crossfades in place instead of reopening the island.
- **Volume and mute** — the level you just set, in the notch, right where your eyes already are.
  It appears and dwells for the same beat Apple's own HUD does, alongside it rather than instead
  of it.
- **Notifications** — one incoming banner at a time, briefly, without the banner covering what
  you're working in.
- **The shelf** — drop a file on the notch and it stays there until you drag it out somewhere else.
  A place to put something down while you go and find where it belongs.
- **Welcome back** — a greeting on wake and unlock, in the right language for the hour and your
  time zone.

Only one thing is on the island at a time, and the more urgent thing wins: a volume press
interrupts a track, and the track is still there underneath when the HUD is gone. Anything the
interruption pushed aside is still queued behind it — swipe across the island to step through
what's waiting.

## How you use it

At rest the island is exactly the notch — pure black, filling the cutout, invisible by design.
Being invisible is the point, so **arriving with the pointer is what announces it**: move the
pointer onto the notch and the island swells a few points past it while the trackpad taps once
under your finger.

| | |
|---|---|
| Move the pointer onto the notch | The island peeks — an invitation to click |
| Click | It expands |
| Swipe across it | Step through whatever is queued behind the current activity |
| Drag a file onto it | The shelf opens and takes it |
| `esc` | It closes |
| `⌃⌥⌘I` | Open and close it from anywhere (rebindable) |
| Menu bar icon | Settings, Copy Diagnostics, quit |

There's no Dock icon and no window. Isleta lives in the menu bar.

Clicking the island never takes focus from the app you're in — no title bar flicker, no lost
caret — and the transport controls work from a window that never becomes key.

## Where it appears

**On the display with the notch, and nowhere else.** An external monitor has no cutout for the
island to be continuous with, so an island up there would just be a black rectangle stuck to the
top of the screen — a different product. Plug in as many displays as you like; the island stays
on the laptop where it belongs.

The one exception is a Mac with no notched display at all — a mini, Studio or iMac — which gets a
floating island pinned to the top of the primary display, because otherwise there'd be nothing to
use.

## Settings

- Turn each source on or off independently — Now Playing, HUDs, Notifications, Welcome Back
- Tune the island: how long the pointer must rest before it peeks, how far it peeks, how long a
  passing activity stays, how long you have to have been away to be greeted, and the opacity of a
  floating island on a Mac with no notch
- Rebind the global shortcut to anything you like (it reads your actual keyboard layout, so a
  Dvorak or AZERTY user is shown the key they actually pressed)
- Trackpad haptics on or off
- Occasional delights on or off
- Automatic update checks on or off, and a Check Now button
- Launch at login
- Reset everything to defaults

## Requirements

- macOS 26 or later
- Apple silicon
- A MacBook Pro or MacBook Air with a notch, for the island to live in — see above for other Macs

Isleta is distributed directly, signed with a Developer ID and notarised by Apple. It is not on
the Mac App Store: reading notifications requires Accessibility, which the App Store sandbox does
not permit.

## Permissions, and why

Isleta asks for as little as it can get away with, as late as it can.

- **Nothing at all** is needed for volume, mute, the shelf, the wake greeting, hover, haptics or
  the shortcut.
- **Accessibility** — only for notifications, so Isleta can see a banner arrive. Decline it and
  every other feature carries on working.
- **Automation** (Music / Spotify) — only for the one-shot "what's playing right now?" read when
  Isleta starts. Live track updates need no permission at all, so declining this costs you the
  first track of a session and nothing else.

Each of these is explained in Settings, next to the switch it belongs to, along with what stops
working if you say no.

## Privacy

There is no account, no telemetry, no analytics and no crash reporting service. Nothing about you,
what you play, or what your notifications say is uploaded anywhere.

What's playing and what your notifications say is read on your Mac, drawn on your Mac, and
forgotten. Your settings are a small preferences file in your own user library.

Isleta makes exactly one kind of network request: checking whether a new version exists. It is a
switch in Settings, and turning it off means the app never touches the network at all.

## Not there yet

- **No brightness HUD.** Changing the brightness is behind an entitlement Apple keeps for itself,
  and nothing in macOS announces it, so there is no supported way for Isleta to know it happened.
  Apple's own HUD handles brightness and Isleta says so in Settings.
- **Replacing the system HUDs** rather than appearing alongside them is written, off by default and
  currently greyed out — the switch goes live on the day there's a mechanism behind it that can be
  undone reliably if Isleta ever crashes.
- **The open island is a fixed size**, not sized to whatever is inside it.

## Feedback

Bug reports and feature requests are welcome in this repo's
[issues](https://github.com/idevtim/isleta/issues). Real hardware quirks — a display arrangement
that confuses it, a music app it doesn't recognise — are especially useful.

## Acknowledgements

Now Playing is read through [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
by Jonas van den Berg and contributors, used under the BSD 3-Clause Licence.

Updates are delivered by [Sparkle](https://github.com/sparkle-project/Sparkle), used under the MIT
Licence.

## Support the Project

Isleta is a one-person project, free while it's in testing. If it earns its place in your notch:

- ❤️ [**GitHub Sponsors**](https://github.com/sponsors/idevtim) — monthly support
- ☕ [**Buy Me a Coffee**](https://buymeacoffee.com/idevtim) — one-shot tip

## Links

- **Bugs** — [GitHub Issues](https://github.com/idevtim/isleta/issues)
- **Ideas** — [GitHub Discussions](https://github.com/idevtim/isleta/discussions)
- **Web** — https://tryisleta.com

---

**© 2026 Isleta** • Made by [Timothy Murphy](https://idevtim.com).
