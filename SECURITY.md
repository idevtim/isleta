# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.1.x   | :white_check_mark: |
| < 2.1   | :x:                |

Only the latest release receives security updates.

## Reporting a Vulnerability

**Please do not open a public issue for security vulnerabilities.**

Instead, email **security@idevtim.com** with:

- A description of the vulnerability
- Steps to reproduce
- Your Isleta version and macOS version

You can expect an initial response within 48 hours. If the vulnerability is confirmed, a fix will be
prioritized and released as soon as possible. You'll be credited in the release notes unless you
prefer to remain anonymous.

## Scope

Isleta runs unsandboxed with a hardened runtime, holds Accessibility when the user grants it, and
resolves several private frameworks at runtime. Issues in the following areas are especially
relevant:

- **The Sparkle update channel.** Updates are verified against an EdDSA (ed25519) public key
  embedded in `Config/Isleta-Info.plist`; the private key is held offline and never enters this
  repository. Anything that would let an unsigned or substituted archive install is in scope.
- **The Accessibility grant.** Isleta uses it to observe and consume media-key events. Anything
  that widens what it does with that grant, or lets another process drive it, is in scope.
- **The media-key event tap.** `CGHidEventTap` consumption of volume, mute and brightness keys.
- **HUD suppression.** Isleta suspends the system OSD process with `SIGSTOP` while suppression is
  on. A path that leaves that process suspended after Isleta exits is a real bug — report it.
- **The `mediaremote-adapter` helper.** A Perl helper process reads Now Playing. Anything affecting
  what it is passed, or what it returns into the app, is in scope.
- **Private framework use.** SkyLight spaces, MediaRemote and the other runtime-resolved paths
  listed in `docs/WORKING-AGREEMENTS.md`.
- **The drop shelf and file conversion.** Isleta takes dropped files, resolves security-scoped
  bookmarks, and converts files. Path handling and bookmark staleness are in scope.
- **Network requests.** Exactly two exist — WeatherKit, and the Sparkle appcast. Both are switches.

## Not in scope

- **Requiring Accessibility, or running unsandboxed.** Both are stated, both are necessary for what
  the app does, and both are why Isleta is not on the Mac App Store.
- **Use of private frameworks as such.** These are deliberate, resolved at runtime behind a protocol
  with a working fallback, and documented. A specific exploitable consequence of one *is* in scope.
- **Anything requiring an attacker who already has code execution as the logged-in user.**

## What Isleta does not do

There is no account, no telemetry, no analytics and no crash reporting service. Nothing about the
user, what they play, where they are, or what is in their calendar is uploaded anywhere. The log at
`~/Library/Logs/Isleta` records events only — never track titles, file names, event titles or serial
numbers — which is what makes **Export Logs…** safe to send to a stranger.
