# mediaremote-adapter (vendored)

Upstream: <https://github.com/ungive/mediaremote-adapter>
Commit: `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`, **plus Isleta's own `queue` function** — see
"The fork" below. Every line Isleta added is marked `ISLETA FORK`, so a rebase onto a newer upstream
is a search rather than a diff.
Licence: BSD 3-Clause — see `LICENSE`. **Clause 2 requires reproducing the copyright notice in
binary distribution**, so Isleta owes an acknowledgements entry naming Jonas van den Berg and
contributors. That is a shipping requirement, not a courtesy.

## Why this exists

`MRMediaRemoteGetNowPlayingInfo` has been entitlement-gated in `mediaremoted` since macOS 15.4.
`mediaremoted` answers callers whose **code-signing identifier** begins `com.apple.`, and Apple's
`/usr/bin/perl` reports `com.apple.perl` — so the script is the way in. Note what that does *not*
say: Perl holds no entitlement. Copying it into the bundle, re-signing it with our Developer ID, or
pointing at a Homebrew Perl each yields a working interpreter that gets refused. `/usr/bin/perl` is
a constant, not a setting.

## Layout, and why the two halves live apart

- `bin/mediaremote-adapter.pl` → ships in `Contents/Resources/MediaRemoteAdapter/`
- `MediaRemoteAdapter.framework` → ships in `Contents/Frameworks/`

Those destinations are load-bearing for notarisation: a `.framework` under `Resources` is not
signed as a nested code bundle and fails notarisation, while a `.pl` under `Frameworks` *is* signed
as code and its signature invalidates the moment anything edits it.

The framework is **bundled, not linked against**. Nothing in Isleta imports it. It is passed to the
script as an argument and dlopened there.

## Rebuilding

```sh
./build-framework.sh
```

Upstream uses CMake; this does not, because the CMake file only compiles the sources into a shared
library, wraps it in a framework bundle and ad-hoc signs it — and making CMake a prerequisite for
150KB of Objective-C is a dependency in all but name. `-fvisibility=default` is not optional: the
Perl script resolves exported functions by name, and hidden visibility produces a framework that
loads and then answers nothing.

arm64 only, matching the app target.

## The fork: `queue`, the control channel, and options on `send`

Isleta added one function, `queue`; the `--queue` option that folds it into `stream`; a stdin
control channel that lets the window be re-asked while the stream runs; and a userInfo dictionary on
`send`, which upstream hardcodes to nil. It is a **fork of source we already carry, not a new private
path** — CLAUDE.md allows two private paths and this is not a third.
`MRMediaRemoteRequestNowPlayingPlaybackQueueSync` sits behind the *same* code-signing-identifier gate
as `MRMediaRemoteGetNowPlayingInfo`: as `/usr/bin/perl` it answers, and from an ad-hoc CLI it returns
`kMRMediaRemoteFrameworkErrorDomain` Code=3, "Operation not permitted". So the only place it can live
is the framework Perl loads, which is this one.

**Everything the fork adds is opt-in.** With neither `--queue` nor a `send` option, the output of
this fork is byte-identical to upstream's and stdin is never read — other consumers of the same
script must not start receiving a line type they have never heard of, or find their helper reading a
file descriptor they expected it to ignore, because Isleta wanted them.

Four files, and one thing worth knowing in each:

- `bin/mediaremote-adapter.pl` whitelists function names **by string**. A function that is not in
  that list cannot be called however well it is exported, which is why the whitelist is the first
  thing to check when a new symbol "does not exist".
- `src/private/MediaRemote.h` gains the two notification names that actually fire —
  `kMRNowPlayingPlaybackQueueChangedNotification` and `kMRPlayerPlaybackQueueChangedNotification`.
  The one this header already declared, `kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification`,
  produced **zero** callbacks. `NSNotificationCenter` registration returns void, so registering for
  the wrong name is indistinguishable from a quiet machine.
- `src/adapter/queue.m` builds the request with `+defaultPlaybackQueueRequestWithRange:` and both
  include flags. **Index 0 is the current track and index 1 is the next one**; `isCurrentlyPlaying`
  is 0 on every item including the playing one, so the discrimination is positional.
- `src/adapter/stream.m` emits `{"type":"queue","queueItems":[…]}` beside the existing
  `{"type":"data"}` lines, on its own dedupe — `printOut` with a private "previous line" rather than
  `printOutUnique`, whose static is shared by every caller: a queue line landing between two
  identical data lines would reset it and let the second data line through. It is **opt-in**
  (`--queue`): with the flag absent the output is byte-identical to upstream's.
- `src/adapter/send.m` builds a **userInfo dictionary** from options and passes it to
  `sendCommand`, which upstream calls as `sendCommand(value, nil)` with the second argument
  hardcoded — so the four commands MediaRemote documents as taking options were unusable however
  they were whitelisted. `acceptedCommands` gains 106 (like), 107 (ban) and 131
  (`PlayItemInPlaybackQueue`). A key is either absent or carries a value and is **never present and
  null**, because a wrong option here does not fail, it succeeds and does nothing.

### The control channel

`stream --queue` reads lines on **stdin**:

| line | effect |
|---|---|
| `length N` | re-ask with a window of N (clamped 1…`QUEUE_MAX_LENGTH`), and reset the dedupe |
| `queue` | re-ask with the current window |
| anything else | ignored, silently — a caller from a later version must not be able to stop the stream |

**End of file does not stop the stream.** stdin closing says nothing about whether MediaRemote still
has something to report, so a consumer that passes `/dev/null` (which is every consumer that has
never heard of this) gets an immediate EOF, the source cancels itself, and nothing else changes.

It exists because a queue is a *window* onto a list that may be tens of thousands of entries, so a
scrollable Up Next has to ask for what is on screen plus a page and ask again on scroll. The
alternative is a one-shot `perl … queue --length=N` per flick, which costs 60-360 ms of process spawn
to cover a 15-30 ms read — process creation dominates. The one-shot still exists for checking by
hand and is on no path the app runs.

## Verified on this machine

macOS 27.0 (26A5416b), 2026-08-19 — `get` returned live data from Music with `title`, `artist`,
`album`, `duration`, `elapsedTime`, `timestamp`, `playbackRate` and `playing`, exit code 0.

`artworkData` arrives as base64 JPEG and measured **211,300 characters (~155 KB) for one track**.
That is why `stream` is run with `--no-artwork` and artwork is fetched with a separate `get` on
track change: `stream` re-emits the full artwork payload on *every* update, and a scrub would push
hundreds of KB per second through a pipe against §9's 60 MB budget.

`timestamp` + `elapsedTime` + `playbackRate` give an anchor date, which is what lets the scrubber
run off `ActivityValue.elapsed(since:)` and the display link IslandUI already has, rather than
polling for a position that is only true for the instant it was sampled.

macOS 27.0, 2026-08-23 — the fork, against a live Music queue. `queue --length=5` returned five
entries with `title`, `artist`, `album`, `duration`, `contentItemIdentifier` and
`iTunesStoreIdentifier`, and index 0's identifier matched the `contentItemIdentifier` in the `get`
payload exactly. `stream --queue --length=3` emitted its queue line **before** the first full state
line, which is why `NowPlayingAdapterDecoder` treats a queue line arriving with no track as silence
rather than as a verdict.
