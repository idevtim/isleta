# Isleta

**The notch, finally doing something.**

Isleta turns the black cutout at the top of your MacBook into a live surface — what's playing,
the volume you just changed, the notification that just landed, a greeting when you open the lid.
It sits there invisibly until it has something to say, and it says it in the one place on the
screen that was already dark.

[tryisleta.com](https://tryisleta.com)

> **Status:** in active development. Version 0.1.0, no public build yet. Watch this repo or the
> site for the first release.

---

## What the island shows

- **Now Playing** — the track, the artist and the app it's coming from, for as long as it plays.
  Works with Apple Music, Spotify and anything else that reports to the system. A track change
  crossfades in place instead of reopening the island.
- **Volume and mute** — the level you just set, in the notch, right where your eyes already are.
  It appears and dwells for the same beat Apple's own HUD does.
- **Notifications** — one incoming banner at a time, briefly, without the banner covering what
  you're working in.
- **Welcome back** — a greeting on wake and unlock, in the right language for the hour and your
  time zone.

Only one thing is on the island at a time, and the more urgent thing wins: a volume press
interrupts a track, and the track is still there underneath when the HUD is gone.

## How you use it

At rest the island is exactly the notch — pure black, filling the cutout, invisible by design.
Being invisible is the point, so **arriving with the pointer is what announces it**: move the
pointer onto the notch and the island swells a few points past it while the trackpad taps once
under your finger.

| | |
|---|---|
| Move the pointer onto the notch | The island peeks — an invitation to click |
| Click | It expands |
| `esc` | It closes |
| `⌃⌥⌘I` | Open and close it from anywhere (rebindable) |
| Menu bar icon | Settings, toggle, quit |

There's no Dock icon and no window. Isleta lives in the menu bar.

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
- Rebind the global shortcut to anything you like (it reads your actual keyboard layout, so a
  Dvorak or AZERTY user is shown the key they actually pressed)
- Trackpad haptics on or off
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

- **Nothing at all** is needed for volume, mute, the wake greeting, hover, haptics or the
  shortcut.
- **Accessibility** — only for notifications, so Isleta can see a banner arrive. Decline it and
  every other feature carries on working.
- **Automation** (Music / Spotify) — only for the one-shot "what's playing right now?" read when
  Isleta starts. Live track updates need no permission at all, so declining this costs you the
  first track of a session and nothing else.

Each of these is explained in Settings, next to the switch it belongs to, along with what stops
working if you say no.

## Privacy

Isleta makes no network connections. There is no account, no telemetry, no analytics, no crash
reporting service, and nothing is uploaded anywhere.

What's playing and what your notifications say is read on your Mac, drawn on your Mac, and
forgotten. Your settings are a small preferences file in your own user library. (When automatic
updates ship, checking for a new version will be the app's first and only network request — and
it will be a switch you can turn off.)

## On the way

- Swipe across the island to cycle through what's queued behind the current activity
- A drag-and-drop shelf — park a file on the notch, pick it up somewhere else
- Automatic updates

## Feedback

Bug reports and feature requests are welcome in this repo's
[issues](https://github.com/idevtim/isleta/issues). Real hardware quirks — a display arrangement
that confuses it, a music app it doesn't recognise — are especially useful.

## Acknowledgements

Now Playing is read through [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
by Jonas van den Berg and contributors, used under the BSD 3-Clause Licence.

---

Made by [Timothy Murphy](https://idevtim.com).
