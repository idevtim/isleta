# IsletaFinderExtension

Isleta's row in Finder's share sheet. A user selects files in Finder, chooses **Share… → Isleta**,
and the files land on the shelf with the island open on them — whether or not Isleta was running.

Three files, one class, no dependencies. It is a **separate signed bundle** that Xcode embeds at
`Isleta.app/Contents/PlugIns/IsletaFinderExtension.appex`, not a package and not part of the app
target.

| file | what it is |
|---|---|
| `ShareExtension.swift` | the whole extension — attachments in, one `isleta://` URL out |
| `Info.plist` | the extension point, the activation rule, and the one user-facing string |
| `IsletaFinderExtension.entitlements` | the sandbox, and nothing else |

## What it owns

- Turning the share sheet's attachments into file paths, **in the order Finder listed them**.
- Building `isleta://shelf/add?path=…&path=…&unresolved=N`.
- Opening that URL **aimed at the `.app` this `.appex` is inside**, which launches Isleta if it is
  not running.
- Finishing the share request on every path, so the sheet never hangs.

## What it deliberately does not own

- **Anything about the shelf.** It does not know what a shelf is, how many files one holds, or that
  eviction exists. It names files; the app decides.
- **Reading files.** It is sandboxed and cannot open the files it names. It does not need to — the
  app is unsandboxed and receives the same URLs a drag onto the island would have produced.
- **Any UI.** All work happens in `loadView` and the request completes from there, so `viewDidAppear`
  is never called and no window is ever presented. Moving the work later grows Isleta a window.
- **`IslandLog`.** The one place in this project that logs through a bare `os.Logger`, and the
  reasons are in the source: inside the sandbox `~` is the container, so the rotating log would be
  written where "Export Logs…" cannot see it, and `IsletaMain` already records why two processes
  appending to one log file is wrong. Only the one failure the app cannot hear is logged here;
  everything else is counted into the URL and logged by the app. The rule that *does* carry over
  unchanged: **nothing the user did not write goes in** — no paths, no file names.
- **Being added to the project.** There is no target for this yet, by design. It needs its own
  Xcode target, an entry in the `Tools/release.sh` signing loop, a `CFBundleURLTypes` entry, and
  matching `AppDelegate` / `ShelfController` changes. The two silent gates are in
  `docs/TRAPS.md`: an `.appex` without `com.apple.security.app-sandbox` is never registered by
  PlugInKit, and app extensions must be signed inside-out.

## The two things that will cost you a session if you change them

- **The sandbox entitlement is not optional and its absence is invisible.** Measured A/B/A on
  macOS 27: an `.appex` signed without `com.apple.security.app-sandbox` is not registered by
  PlugInKit at all — `pluginkit -m -i com.tryisleta.isleta.share` answers nothing, `codesign` is
  happy, and the row simply never appears. This does **not** sandbox Isleta; an `.appex` carries its
  own entitlements and the app is signed separately.
- **`NSExtensionActivationSupportsFileWithMaxCount` is a hard, silent gate.** One file over the
  number and the row disappears from the share sheet with no error and nothing for the user to read.
  It is set to 100 rather than to `ShelfContents.capacity` so that sharing many files behaves like
  dragging many files, which the shelf already handles by evicting.
