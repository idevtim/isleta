# Localization

Measured 2026-08-23. Three of these fail silently in one build system and not the other.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

- **The base language is US English, and it is a rule about the whole tree rather than about the
  strings.** `de`, `fr` and `es` ship; `en` is the source. Spelling was swept US-wide across roughly
  1,100 files — `colour` → `color`, `favourite` → `favorite`, `equaliser` → `equalizer`,
  `synthesised` → `synthesized`, `localisation` → `localization` — and that sweep covers doc
  comments, tests and prose as well as user-facing copy, because a codebase with two spellings of
  the same word is a codebase where `grep` misses half its hits. It does **not** cover names macOS
  or another app chose: an API symbol, a `UserDefaults` key already in a shipped file, or a system
  string keeps its own spelling. Never do this as a blind global replace.
- **SwiftPM does not compile `.xcstrings`, and that decides the mechanism.** It copies the catalog's
  JSON into the resource bundle verbatim, produces no `.lproj`, and every lookup returns the key. So
  a string catalog works in the Xcode app build and is **silently inert under `swift test`** — the
  two-build-systems divergence this project already fights over warnings-as-errors, in a new place.
  `.strings` behaves identically in both. English stays in the source as `String(localized:
  defaultValue:bundle:)`'s default, so the argued captions sit next to the doc comments arguing for
  them; there is deliberately **no `en.lproj/Localizable.strings`**, because a second copy of the
  English is free to drift and only an English reader would ever see it. The one exception is
  `en.lproj/Localizable.stringsdict`, because a format string cannot express a plural rule.
- **`CFBundleLocalizations` in the *app's* Info.plist is what switches a *package's* translations on,
  and its absence is silent.** CFBundle negotiates a nested bundle's language against the **main**
  bundle, so with `de` missing from that array every package's `Bundle.module.preferredLocalizations`
  collapses to `["en"]` and all four packages draw English — no warning, no log line, nothing to
  grep. Adding `de` to the array with **no `de.lproj` in the app at all** was enough on its own to
  make all four resolve.
- **Neither build system prunes a deleted `.lproj`, and the stale one is not inert.** After a
  language was removed from the source tree, an incremental `xcodebuild` still shipped its `.lproj`
  in `Isleta.app` *and* in all four package bundles, and `swift build` did the same.
  `Bundle.localizations` unions the on-disk set with the plist, so the retired language goes on being
  offered. `Tools/release.sh` cannot ship one because it `rm -rf`s its build directory first, but
  `--perf-report` and `open -a` against `.build/xcode` will lie to you. `Tools/check.sh` now fails
  on it. Same family as the stale-cached-module trap for *added* files, pointing the other way.
- **SwiftPM lowercases the `.lproj` on the way into the bundle** — `zh-Hans.lproj` arrives as
  `zh-hans.lproj`, where Xcode preserves case. Harmless in itself, but a probe that looks the folder
  up by its source spelling finds nothing and reads it as a missing translation.
- **The runtime proof is the built app, and `swift test` structurally cannot give it.**
  `Isleta.app/Contents/MacOS/Isleta -AppleLanguages '(de)'` is what proves a translation resolves. A
  test process has no main bundle to negotiate against, and `-AppleLanguages` moves
  `Locale.preferredLanguages` while leaving `Bundle.preferredLocalizations` alone — so a test asserting
  on the German string passes for the wrong reason or fails for one.
- **"German is famously long" is wrong for this corpus, and the danger is the short label.** Measured
  across 405 strings in real SF Pro: median expansion de ×1.21, fr ×1.21, **es ×1.23**, with Spanish
  also worst at the tail (×3.90 against German's ×2.90). Long sentences regress to the mean; the
  blow-ups are one- and two-word labels — `Off` → `Desactivado`, `Play` → `Wiedergabe`, `Timer` →
  `Temporizador` — which are exactly the strings that live in fixed-width controls. Also measured: an
  accented Latin glyph has **identical advance width** to its base in SF Pro (`a`/`á`, `n`/`ñ`,
  `A`/`À`, equal to four decimal places), so a character-count estimate mis-ranks Spanish and French.
- **What is not localized is a rule, not a list.** Localize what Isleta wrote for a person to read on
  screen; nothing else. Out: everything read by a machine or by whoever is debugging (all
  `IslandLog`, the diagnostics report, `--export-logs` stdout, `--flag` names, self-test verdicts,
  `matchedGeometryEffect` ids, `CustomStringConvertible`, everything `#if DEBUG`); everything
  persisted or matched on (`UserDefaults` keys, `ActivityKind`/`ShortcutAction`/`SettingsSection` raw
  values, `Notification.Name`s, UTTypes, SF Symbols, and `SystemSounds` names — which are both a
  filename *and* the argument to `NSSound(named:)`); and everything named by macOS or another app.
  **A live violation was found by applying it**: `SourceHub.statuses` fed a display title into the
  diagnostics report, so localizing that title would have shipped German column headings inside bug
  reports emailed to a developer who does not read German.
