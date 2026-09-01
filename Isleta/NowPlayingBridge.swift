import AppKit
import Foundation
import IslandKit
import IslandSources
import IslandUI

/// Joins `NowPlayingSource` to the `NowPlayingController` the island renders from.
///
/// Wiring, and nothing else — the same job `SourceHub` does for the one-way half of the same source,
/// and it lives beside it for the same reason. IslandUI must build and preview with nothing granted,
/// so it cannot see IslandSources; IslandSources must be testable with no window, so it cannot see
/// IslandUI. The app shell is the only layer that legitimately sees both, and this is the whole of
/// what it has to say about music:
///
/// - what the player reports (playing, skippable, has-a-transport-at-all) becomes controller state
/// - what the user presses becomes an `MRCommand` through the adapter
/// - a cover, once per track, becomes a `CGImage` on the controller
///
/// The two command vocabularies are deliberately not the same type. `NowPlayingControlCommand` is
/// what a *button* means and lives in IslandUI; `NowPlayingCommand` carries Apple's `MRCommand` ids
/// and lives in IslandSources. Sharing one enum would put a private framework's wire format in the
/// package whose value is having no I/O in it, and the translation is the three lines below.
@MainActor
final class NowPlayingBridge {

    let controller = NowPlayingController()

    private let source: NowPlayingSource

    /// Read at the moment a change is adopted rather than held, matching `AppDelegate`'s handling of
    /// the same setting: an animation must never run against a copy the shell has not refreshed.
    private let reduceMotion: @MainActor () -> Bool

    /// Called after the player has been brought forward, so the app shell can put the island away.
    /// Held rather than passed to `init` because the bridge is built inside `startSources`, after
    /// the screens it would have to collapse already exist.
    var onOpenedPlayer: (@MainActor () -> Void)?

    /// Opens or closes the Up Next surface. Held by the shell rather than done here, because it
    /// moves the island's outline and therefore has to travel the widen-then-tighten path a content
    /// change does — which is `AppDelegate.transition(on:_:)`'s business and nothing else's.
    var onToggleQueue: (@MainActor () -> Void)?

    /// Called when the queue window changes, so the shell can re-clamp the scroll against a list
    /// that has grown or shrunk under the reader.
    var onQueueChanged: (@MainActor ([NowPlayingQueueRow]) -> Void)?

    /// Called on the **edge** — the player started or stopped — and never on the payloads in
    /// between, of which there are one or two a second while a track plays.
    ///
    /// The shell puts a paused island away when the user changes space and brings it back when the
    /// music starts again, which is what needs the resuming edge specifically. Reported from here
    /// rather than observed off `controller.isPlaying`, because an `@Observable` read would fire
    /// for every other field `apply` touches as well: the heart being lit, the rate changing, the
    /// route retiring itself.
    var onPlayingChanged: (@MainActor (Bool) -> Void)?

    /// The system audio output devices. Its own object rather than part of the Now Playing source,
    /// because it is a fact about the *machine* and not about the player: the Mac still has speakers
    /// when the music stops, and CoreAudio needs no adapter, no helper and no permission.
    private let outputRouting: any NowPlayingOutputRouting

    /// The AppleScript route, for the two things MediaRemote cannot do: Music's own Favorite, and
    /// opening the app *at the playing track*.
    ///
    /// Held here rather than reached for through `source`, because neither is a property of the
    /// Now Playing *route* — the adapter is what reads and controls playback, and these two are
    /// questions for the application. Both degrade to nothing without an Automation grant, which is
    /// why neither is allowed to gate anything the transport already does.
    private let scripting: any NowPlayingScriptEnvironment

    /// What the script route last said about the playing track, or nil where it has nothing to say.
    ///
    /// Kept so a snapshot arriving between reads does not blank the star: `onSnapshot` fires on
    /// every payload, and re-reading Music on each one would fork `osascript` several times a
    /// second. The read is issued when the *track* changes, and this holds the answer until it does.
    private var scriptedFavorite: Bool?

    /// Whether Music's own Favorite may be offered for what is playing.
    ///
    /// **`.undetermined` counts.** The state cannot be read until Automation is granted, and the
    /// grant cannot be asked for until the user presses the star — so a control offered only once
    /// the answer is known is a control that is never offered. An undetermined grant draws an unlit
    /// star, the press asks, and the answer arrives with the read-back. A *refused* one draws
    /// nothing, which is §10's other half.
    private var canFavoriteThroughMusic = false

    /// The track `scriptedFavorite` describes, so a change of record invalidates it.
    private var scriptedFavoriteIdentity: String?


    /// Whether the *adapter* offers a favorite for what is playing — `supportsIsLiked`, as the last
    /// snapshot reported it. Held rather than asked because the choice of route has to be made
    /// inside `onCommand`, which has no snapshot in hand.
    private var transportCanFavorite = false

    init(
        source: NowPlayingSource,
        outputRouting: any NowPlayingOutputRouting = CoreAudioOutputRouting(),
        scripting: any NowPlayingScriptEnvironment = NowPlayingSystemScriptEnvironment(),
        reduceMotion: @escaping @MainActor () -> Bool
    ) {
        self.source = source
        self.outputRouting = outputRouting
        self.scripting = scripting
        self.reduceMotion = reduceMotion

        controller.canReadQueue = source.canReadQueue

        controller.onCommand = { [weak self] command in
            guard let self else { return }
            // Two of the seven controls are not transport commands, and neither may be sent as one.
            //
            // Up Next moves the island's outline and belongs to the shell. The heart is a genuine
            // `MRCommand` but it is a *pair* of them — like and ban — chosen from the state the
            // controller has just flipped, so it cannot be expressed by the one-to-one table below.
            switch command {
            case .toggleQueue:
                self.onToggleQueue?()
            case .toggleFavorite:
                // `controller.isFavorite` has already been flipped optimistically by `send(_:)`, so
                // this reads the state being asked for rather than the one being left. The player
                // overrules it on the next payload either way — which is the correct precedence,
                // and the one shuffle and repeat can never have because nothing reports them.
                //
                // **Two routes, and the adapter's is preferred where it exists.** A player that
                // reports `supportsIsLiked` takes `kMRLikeTrack`/`kMRBanTrack` with no permission at
                // all; Music does not report it for its own library, so the star there is Music's
                // Favorite reached through AppleScript. Asking the adapter first means a player that
                // grows the capability needs no Automation grant to use it.
                if self.transportCanFavorite {
                    self.source.transport.setFavorite(self.controller.isFavorite)
                } else {
                    self.setScriptedFavorite(self.controller.isFavorite)
                }
            case .previousTrack, .togglePlayPause, .nextTrack, .toggleShuffle, .toggleRepeat,
                 .skipBackFifteen, .skipForwardFifteen:
                self.source.transport.send(Self.transportCommand(for: command))
            }
        }

        // Double-clicking a queue row. The offset **and** the id, because the command needs both —
        // and it is verified by reading the queue back rather than by a return value, which is `1`
        // for the two commands that do nothing as well as for the one that works.
        controller.onPlayQueueItem = { [weak self] offset, contentItemIdentifier in
            self?.source.transport.playQueueItem(
                atOffset: offset,
                contentItemIdentifier: contentItemIdentifier
            )
        }

        controller.onSelectOutputDevice = { [weak self] id in
            self?.outputRouting.select(id)
        }

        // The queue window, translated to the rows the list draws.
        //
        // `NowPlayingQueueItem` stops here for the reason `NowPlayingUpNext` does: it comes out of
        // a spawned Perl process, and IslandUI has to build and preview with nothing granted.
        source.onQueue = { [weak self] items in
            guard let self else { return }
            let rows = items.map {
                NowPlayingQueueRow(
                    index: $0.index,
                    title: $0.title,
                    artist: $0.artist,
                    duration: $0.duration,
                    contentItemIdentifier: $0.contentItemIdentifier
                )
            }
            self.controller.setQueue(rows)
            self.onQueueChanged?(rows)
            // **The audio format rides in on the queue**, because that is the one place MediaRemote
            // publishes it — see `AudioFormat.init(mediaRemoteFields:)` for the three routes that
            // do not. It arrives free: the stream already asks for a resting window of five on
            // every track change, so there is no extra request, no child process and no window that
            // has to be open.
            //
            // The *playing* entry only. Every entry after it answers nil, which is not a gap: the
            // badge is about what is playing.
            self.controller.applyAudioFormat(items.first { $0.isCurrent }?.audioFormat)
        }

        // The output devices, likewise — CoreAudio's `AudioDeviceID` and transport type stop here,
        // and IslandUI is handed a name, a symbol and a tick.
        outputRouting.onDevices = { [weak self] devices in
            self?.controller.setOutputDevices(
                devices.map {
                    NowPlayingOutputDeviceRow(
                        id: $0.id,
                        name: $0.name,
                        isSelected: $0.isDefault,
                        symbolName: $0.symbolName
                    )
                }
            )
        }
        controller.onSeek = { [weak self] seconds in
            self?.source.transport.seek(toSeconds: seconds)
        }

        // `onSnapshot` rather than reading the activity back out of the coordinator. The two facts
        // needed here — whether the player permits skipping, and whether it is playing — are
        // deliberately absent from `ActivityContent`, because a control's enabled state is a view
        // concern and the package that owns content has no views in it.
        source.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let wasPlaying = self.controller.isPlaying
            self.transportCanFavorite = snapshot?.canFavorite ?? false
            self.refreshScriptedFavorite(for: snapshot)
            self.controller.apply(
                isPlaying: snapshot?.isPlaying ?? false,
                canSkip: snapshot?.canSkip ?? true,
                // Re-read every time rather than captured at construction: the adapter transport
                // retires itself when a command fails to launch, and a controller holding a stale
                // `true` would keep drawing three buttons that do nothing.
                isTransportAvailable: self.source.transport.isAvailable,
                playerBundleIdentifier: snapshot?.bundleIdentifier,
                isRadioStation: snapshot?.isRadioStation ?? false,
                // The adapter's answer where it has one, and Music's own Favorite where it does
                // not — Music reports no `supportsIsLiked` for its own library, so for the player
                // most people use the star is always the second of the two.
                canFavorite: snapshot?.canFavorite ?? false || self.canFavoriteThroughMusic,
                isFavorite: snapshot?.canFavorite == true
                    ? snapshot?.isFavorite ?? false
                    : self.scriptedFavorite ?? false,
                canSkipBackFifteen: snapshot?.canSkipBackFifteen ?? false,
                canSkipForwardFifteen: snapshot?.canSkipForwardFifteen ?? false,
                // The rate the player reports, straight off the timeline that already carries it.
                // Drawn only when it is not 1× — see `NowPlayingRateFormat.chip`.
                playbackRate: snapshot?.timeline?.rate,
                reduceMotion: self.reduceMotion()
            )
            // The next track, translated to the two strings the line draws.
            //
            // Not folded into `apply` above, for the reason `NowPlayingController.setUpNext` gives:
            // the queue arrives on its own line of the adapter's stream and lands a beat either side
            // of the state it belongs to. `NowPlayingUpNext` stops here — it carries a content id
            // for a command a later milestone will send, and IslandUI must not learn about a type
            // that comes out of a spawned Perl process.
            self.controller.setUpNext(
                title: snapshot?.upNext?.title,
                artist: snapshot?.upNext?.artist
            )
            if snapshot == nil { self.controller.reset() }
            // Read back off the controller rather than from the snapshot, so this reports what the
            // island is actually drawing: `reset()` above puts it to false for a player that has
            // gone away, and a snapshot-derived edge would miss that.
            if self.controller.isPlaying != wasPlaying {
                self.onPlayingChanged?(self.controller.isPlaying)
            }
        }

        // Tapping the cover or the title brings the player forward.
        //
        // `NSWorkspace` rather than anything in IslandUI: launching an application is the app
        // shell's business, and the package that draws the island reaches for nothing outside
        // SwiftUI. Activating another app is also exactly the thing the *island* must never do on
        // its own (§4.1) — it is fine here only because the user asked for it by tapping.
        controller.onOpenPlayer = { [weak self] bundleIdentifier in
            // **At the track, where the player can be shown it.** Music's `reveal` selects the
            // playing record in the library and `activate` brings the window forward already showing
            // it, which is what "take me to this song" means — bringing the app forward at whatever
            // it happened to be displaying is the same click doing less.
            //
            // Music alone, because Music alone offers it: `sdef /Applications/Spotify.app` has no
            // `reveal`. The fallback below is the whole of what a refusal costs, which is the same
            // bargain `NowPlayingScriptProvider` already strikes.
            //
            // **Everything but a refusal, and it used to be `== .granted`.** That is a gate that can
            // never open: Automation is `.undetermined` until something asks, macOS raises its
            // prompt on the *asking*, and requiring the grant first meant nobody was ever asked — so
            // every click opened Music at whatever it was showing and the reveal shipped dead. A
            // click on the song is exactly the user-initiated moment that prompt is for.
            //
            // Matched by *case*, never compared: `denied` carries an explanation, so an equality
            // test against `.denied(explanation: "")` matches no real refusal — the trap this file
            // documents twice already.
            var refused = false
            if case .denied = self?.scripting.automationStatus(for: .music) { refused = true }
            if bundleIdentifier == NowPlayingPlayer.music.bundleIdentifier, !refused {
                self?.scripting.revealCurrentTrack(in: .music)
                self?.onOpenedPlayer?()
                return
            }

            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)

            // And close the island behind it. The tap said "take me to the player", and leaving the
            // island open would put it over the app the user just asked to look at — the one place
            // on screen they are now certain to be looking.
            self?.onOpenedPlayer?()
        }

        source.artwork?.onArtwork = { [weak self] artwork in
            guard let self else { return }
            self.controller.setArtwork(artwork?.image, reduceMotion: self.reduceMotion())
        }
    }

    /// Starts and stops the CoreAudio device list.
    ///
    /// Separate from the Now Playing source's own `start()`, and it must be: the output device is a
    /// fact about the machine rather than about the player, so it keeps working — and keeps being
    /// worth showing — on a build where Now Playing is switched off entirely. `start()` is
    /// idempotent, per the same contract every source in this app follows.
    func startOutputRouting() {
        outputRouting.start()
    }

    func stopOutputRouting() {
        outputRouting.stop()
    }

    /// Asks for a wider queue window as the reader scrolls.
    ///
    /// Down the streaming helper's stdin, never as a `perl … queue` spawn: that costs 60-360 ms of
    /// process creation to cover a 15-30 ms read, so a spawn per scroll sample would be a process
    /// per flick of a trackpad. `NowPlayingQueuePaging` decides what to ask for and
    /// `NowPlayingAdapterProvider` suppresses an ask that is not wider than the last.
    func requestQueueWindow(lastVisibleRow: Int, isOpen: Bool) {
        source.requestQueueWindow(
            length: NowPlayingQueuePaging.window(lastVisibleRow: lastVisibleRow, isOpen: isOpen),
            isOpen: isOpen
        )
    }

    private static func transportCommand(for command: NowPlayingControlCommand) -> NowPlayingCommand {
        switch command {
        case .previousTrack: .previousTrack
        case .togglePlayPause: .togglePlayPause
        case .nextTrack: .nextTrack
        case .toggleShuffle: .toggleShuffle
        case .toggleRepeat: .toggleRepeat
        case .skipBackFifteen: .goBackFifteenSeconds
        case .skipForwardFifteen: .skipFifteenSeconds
        // Neither reaches here — `onCommand` above routes them before this table is consulted, and
        // the compiler is what keeps that true. `.togglePlayPause` is the least wrong thing to name
        // for a case that cannot occur; it is not a fallback, it is a value the switch requires.
        case .toggleFavorite, .toggleQueue: .togglePlayPause
        }
    }

    // MARK: - Music's own Favorite

    /// Re-reads Music's Favorite when the *track* changes, and at no other time.
    ///
    /// `onSnapshot` fires on every payload the adapter emits — several a second while a track is
    /// playing — and each read is one `osascript` fork. Keyed on `artworkIdentity`, which is the
    /// `contentItemIdentifier` the adapter already carries, so the fork happens once per record.
    ///
    /// Skipped entirely where the adapter has its own answer: a player reporting `supportsIsLiked`
    /// needs no Automation grant and no child process, and asking Music about a track Spotify is
    /// playing would be a question about the wrong application.
    private func refreshScriptedFavorite(for snapshot: NowPlayingSnapshot?) {
        guard let snapshot, snapshot.bundleIdentifier == NowPlayingPlayer.music.bundleIdentifier,
              snapshot.canFavorite == false
        else {
            scriptedFavorite = nil
            scriptedFavoriteIdentity = nil
            canFavoriteThroughMusic = false
            return
        }

        // Music is playing and the adapter has no favorite of its own, so the star is Music's —
        // unless the user has refused Automation, which is the one state that takes it away.
        // `denied` carries an explanation, so it is matched by *case* rather than compared — an
        // equality test against `.denied(explanation: "")` never matches a real refusal.
        switch scripting.automationStatus(for: .music) {
        case .granted, .undetermined, .notRequired:
            canFavoriteThroughMusic = scripting.isRunning(.music)
        case .denied:
            canFavoriteThroughMusic = false
        }

        let identity = snapshot.artworkIdentity ?? snapshot.title
        guard identity != scriptedFavoriteIdentity else { return }
        scriptedFavoriteIdentity = identity
        // Cleared before the read rather than after it, so the star is not lit from the *previous*
        // record for the length of one fork. A track with no answer yet draws no star, which is the
        // honest state — the alternative is one that says the wrong thing about the wrong song.
        scriptedFavorite = nil

        scripting.readFavorite(from: .music) { [weak self] answer in
            guard let self, self.scriptedFavoriteIdentity == identity else { return }
            self.scriptedFavorite = answer
            self.controller.applyFavorite(
                canFavorite: self.canFavoriteThroughMusic, isFavorite: answer == true
            )
        }
    }

    /// Writes Music's Favorite, and adopts what the player settles on.
    ///
    /// The read-back is not politeness: `set favorited` returns before Music agrees, and by an
    /// amount that is not constant — see `NowPlayingPlayer.favoriteWriteScript`, which polls rather
    /// than sleeping a fixed time because a fixed one was measured, believed, and then watched to
    /// fail on a first click.
    private func setScriptedFavorite(_ favorite: Bool) {
        let identity = scriptedFavoriteIdentity
        // **Adopted before the write is sent, not after it comes back.**
        //
        // `send(_:)` has already flipped the controller optimistically, and without this the very
        // next snapshot — milliseconds later, several a second while a track plays — pushes
        // `scriptedFavorite`, which is still the value the user just changed away from. The flip is
        // stomped before a frame is drawn and the star sits dark for the whole of the write.
        // Reported as "I clicked it, it did it, but it doesn't show that it's a favorite".
        //
        // The read-back still overrules this: if Music disagrees, its answer is what stays. This is
        // the optimism, not a second source of truth.
        scriptedFavorite = favorite

        scripting.setFavorite(favorite, on: .music) { [weak self] answer in
            guard let self, self.scriptedFavoriteIdentity == identity else { return }
            self.scriptedFavorite = answer
            self.controller.applyFavorite(
                canFavorite: self.canFavoriteThroughMusic, isFavorite: answer == true
            )
        }
    }

}
