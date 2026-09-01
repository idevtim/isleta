import CoreGraphics
import Foundation
import IslandActivities
import Observation
import SwiftUI

/// What the three transport buttons ask for.
///
/// `togglePlayPause` rather than separate play and pause, because the island's idea of what is
/// playing lags the player by a pipe hop: a user who taps twice quickly would otherwise send two
/// absolute commands computed from the same stale flag and end up pausing something already paused.
public enum NowPlayingControlCommand: Equatable, Sendable {
    case previousTrack
    case togglePlayPause

    /// The two outer controls. The reference shows a favorite star and an AirPlay button there;
    /// neither can be made to work, so these are what occupy those positions instead.
    ///
    /// A star cannot act — the adapter accepts no like/favorite command — and cannot even reflect
    /// state, because Music does not report `isFavorite`. AirPlay has no public API for presenting the
    /// output picker. Shuffle and repeat are real commands the adapter accepts, so the buttons do
    /// something rather than decorating the row.
    case toggleShuffle
    case toggleRepeat
    case nextTrack

    /// The heart.
    ///
    /// The reference showed a favorite star here from the beginning and it was left out, on the
    /// evidence that "the adapter accepts no like/favorite command" and "Music does not report
    /// `isFavorite`". Half of that is now false and the other half is a property of the *track*, not of
    /// the route: the vendored adapter refused the command because its `acceptedCommands` list did
    /// not carry it and because `adapter_send` hardcoded a nil userInfo, both of which the fork
    /// fixes; and `isFavorite`/`supportsIsLiked` are payload keys that a local Music library track
    /// simply does not set. So the control ships, drawn from `canFavorite`, dimmed and inert where the
    /// player has no like to offer.
    case toggleFavorite

    /// The two fifteen-second jumps, offered only where the player says it offers them.
    ///
    /// They take the previous/next positions rather than adding buttons, which is what every
    /// spoken-word player does and what keeps the row the same width. It is also why they are
    /// separate commands rather than a seek: a podcast app implements these as its own jump, and
    /// asking it for one is the difference between the button the app draws and a scrub we
    /// computed against a duration it may not have reported.
    case skipBackFifteen
    case skipForwardFifteen

    /// Opens or closes the Up Next surface. Handled by the app shell rather than sent anywhere —
    /// it moves the island's outline, so it has to travel the widen-then-tighten path a content
    /// change does.
    case toggleQueue
}

/// The three states the repeat control cycles through.
///
/// Held by the island rather than read from the player, and that is a platform constraint rather
/// than a shortcut: **Music reports neither `shuffleMode` nor `repeatMode`.** Both keys exist in the
/// adapter's vocabulary and both come back absent from every `get` and every stream update, measured
/// on macOS 27.0 — so the only thing anything on this machine knows about these two settings is what
/// the user has asked for since the island started drawing.
///
/// The consequence is written down where it bites: the highlight says "you asked for this", not
/// "the player is doing this", and it starts at `.off` because that is the honest opening claim.
public enum NowPlayingRepeatMode: Equatable, Sendable {
    case off
    case all
    case one

    /// off → all → one → off, which is the order every player that has this control uses.
    var next: NowPlayingRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var isOn: Bool { self != .off }

    /// `repeat.1` is the whole reason this is three states rather than a flag: repeating one track
    /// and repeating the queue are different intentions and the glyph has to say which.
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

/// The Now Playing state the island needs that is *not* content, plus the way back to the player.
///
/// ## Why this is not `ActivityContent`
///
/// IslandActivities is the one package with no views, no AppKit and no I/O in it, and everything an
/// activity says travels through it as inert data. Three things here refuse to fit that:
///
/// - **A control's enabled state** is a view concept. `prohibitsSkip` decides whether the Next
///   button is drawn dimmed, and teaching the content vocabulary about buttons would mean every
///   other activity inherits a field it has no use for.
/// - **An image** is not something `ActivityContent` may carry (§6.5: SF Symbols and SF Pro, never a
///   vended asset), and putting a `CGImage` in an `Equatable` struct means comparing images on every
///   diff to decide whether the island changed.
/// - **A callback to the player** is I/O, and would drag IslandSources into the layer that must
///   build with nothing granted.
///
/// So this lives in IslandUI, keyed by `ActivityKind.nowPlaying`, which is exactly the escape hatch
/// IslandActivities' README describes: "a bespoke view belongs in IslandUI keyed on `ActivityKind`,
/// never as an `AnyView` smuggled through IslandActivities."
///
/// ## One instance, shared by every screen
///
/// Like `ActivityCoordinator` and for the same reason: there is one user listening to one thing. A
/// controller per panel would give each display its own scrub state, so a drag started on the laptop
/// would leave the external showing the old position.
@MainActor
@Observable
public final class NowPlayingController {

    /// How long an optimistic seek is trusted before the display falls back to what the player says.
    ///
    /// The window exists because a seek is a round trip: the command goes out through a spawned
    /// helper, the player moves, and the move comes back on the stream a few hundred milliseconds
    /// later. Without the optimistic value the bar springs back to where it was for the whole of
    /// that, which reads as the drag having failed and invites the user to drag again. With too long
    /// a window, a seek the player *refused* — a stream that prohibits it — looks like it worked
    /// until the bar jumps. Long enough for the round trip on a loaded machine, short enough that a
    /// refusal is visible within a beat.
    static let seekSettleWindow: TimeInterval = 1.5

    /// Whether the player is playing. Chooses the play/pause glyph and nothing else — the equaliser
    /// and the playhead both read `ActivityTimeline.rate`, which is the same fact measured rather
    /// than reported.
    public var isPlaying = false

    /// Whether the player permits skipping. From the payload's `prohibitsSkip`, inverted at the
    /// source. False dims the previous and next buttons *and* makes them inert, which is the honest
    /// pair: a control that looks pressable and is not is worse than one that looks unavailable.
    public var canSkip = true

    /// Whether there is a route to the player at all. False draws no transport row — see
    /// `NowPlayingUnavailableTransport` for why that is different from drawing a dimmed one.
    public var isTransportAvailable = false

    /// Whether a radio station is playing rather than a queue.
    ///
    /// `canChangeQueueBehavior` is what the view reads; this is the fact it is derived from, and
    /// they are kept separate for the reason the presentation model is: two names for one state
    /// invite a writer for each.
    public var isRadioStation = false

    /// Whether shuffle and repeat mean anything right now.
    ///
    /// A radio station has no queue, so there is nothing to shuffle and nothing to repeat — and the
    /// player says so by refusing the commands. This is `canSkip`'s sibling: the controls stay
    /// drawn, dimmed and inert, because the capability is missing from an otherwise working set
    /// rather than the set being absent.
    public var canChangeQueueBehavior: Bool { !isRadioStation }

    /// The bundle identifier of whatever is playing, when the source knows it.
    ///
    /// Held here rather than in `ActivityContent` for the same reason `canSkip` is: it is a fact
    /// about the *player*, and the package that owns content has no views and no business knowing
    /// which application to launch.
    public var playerBundleIdentifier: String?

    /// Whether tapping the artwork or the title has anywhere to go.
    ///
    /// A tap target that does nothing is worse than none — the user learns the island is
    /// unresponsive and stops trying — so the gesture is only attached when there is a player to
    /// open.
    public var canOpenPlayer: Bool { playerBundleIdentifier != nil }

    /// Whether the user has asked for shuffle, and for which repeat mode.
    ///
    /// See `NowPlayingRepeatMode`: nothing reports these back, so these two are the record of what
    /// was asked for. They are reset when the *player* changes, because they describe that player's
    /// queue and carrying one app's setting over to another's would be a highlight that means
    /// nothing.
    public private(set) var isShuffling = false

    public private(set) var repeatMode: NowPlayingRepeatMode = .off

    /// What plays after this, when the route can see a queue — the title, and the artist beside it.
    ///
    /// Two strings rather than a shared value type, and that is the same split
    /// `NowPlayingControlCommand` makes against `NowPlayingCommand`: the source's `NowPlayingUpNext`
    /// carries a content id for a command a later milestone will send, and importing it here would
    /// put IslandSources — and with it a spawned Perl process — inside the package that has to build
    /// and preview with nothing granted. Two strings are exactly what the line draws.
    ///
    /// Held for the length of the song rather than only while the peek is on screen. **Whether it is
    /// shown is not stored anywhere**: it is `NowPlayingUpNextPeek.isDue(timeline:at:)`, evaluated
    /// against the same display-link instant the numerals use. Storing a `showsUpNext` flag beside
    /// it would be a second answer to a question the timeline already answers, and it would need a
    /// timer to keep current — which is the whole thing this feature is built to avoid.
    public private(set) var upNextTitle: String?

    public private(set) var upNextArtist: String?

    public var hasUpNext: Bool { upNextTitle != nil }

    // MARK: - The Up Next surface

    /// The queue window, as rows.
    ///
    /// A UI-side value type rather than IslandSources' `NowPlayingQueueItem`, for the same reason
    /// `upNextTitle` is two strings: importing the source's type would put IslandSources — and with
    /// it a spawned Perl process — inside the package that has to build and preview with nothing
    /// granted (§3). The bridge in the app shell is the translation, and it is five lines.
    public private(set) var queue: [NowPlayingQueueRow] = []

    /// Whether the open island is showing the Up Next surface instead of the player's own body.
    ///
    /// App-wide, because this controller is app-wide: there is one user deciding what to listen to
    /// next, and two islands disagreeing about whether the list is up would be two answers to a
    /// question that has one. Set through `IslandScreenModel.setShowingNowPlayingQueue`, so the
    /// flag and the island's height move on the same spring (§6.1).
    public var isShowingQueue = false

    /// Which of the surface's two tabs is showing.
    ///
    /// Not stored on the model and not derived from anything: it is a thing the user chose. It
    /// deliberately does **not** change the island's height — see `NowPlayingQueueLayout` — so it
    /// is the one piece of state on this surface that can move without the outline moving.
    public var queueTab: NowPlayingQueueTab = .upNext

    /// Whether there is a route that can read a queue at all. False draws no Up Next button — not a
    /// dimmed one, for the reason `isTransportAvailable` draws no transport row.
    public var canReadQueue = false

    /// Whether the player offers a like for what is playing, from `supportsIsLiked`.
    ///
    /// `isFavorite` is the *state* of that control and is not evidence of it existing: a track nobody
    /// has favorite yet reports zero for it and is perfectly likeable. Reading the state as the
    /// capability draws a dead heart on every likeable track, which is the same mistake as
    /// answering `prohibitsSkip` and the radio-station limit with one flag — and note those two are
    /// unrelated to *this* one as well.
    public var canFavorite = false

    public var isFavorite = false

    /// Adopts a Favorite answered by something other than the payload.
    ///
    /// Its own entry point rather than two more parameters on `apply(isPlaying:…)`, because it
    /// arrives on a different clock: the adapter pushes a snapshot several times a second, and
    /// Music's own Favorite is one `osascript` read per *track*. Folding it into `apply` would mean
    /// every payload carrying a stale answer, or the read being issued on every payload.
    ///
    /// Animated on `contentSwap` for the reason `apply` is: the star filling is a content change in
    /// §6.2's sense and crossfades with the row it sits in.
    public func applyFavorite(canFavorite: Bool, isFavorite: Bool) {
        guard canFavorite != self.canFavorite || isFavorite != self.isFavorite else { return }
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            self.canFavorite = canFavorite
            self.isFavorite = isFavorite
        }
    }

    /// What the playing track's audio is, or nil where nothing can be known about it.
    ///
    /// **Nil is the common case and not a failure.** Anything streamed from Apple Music reports no
    /// `kind` at all — see `AudioFormat`, which has the measurement and the reason a badge is not
    /// inferred from the user's Lossless setting instead. The player draws one line fewer.
    public var audioFormat: AudioFormat?

    /// Adopts a format answered by the scripting route.
    ///
    /// Its own entry point rather than another parameter on `apply(isPlaying:…)`, for
    /// `applyFavorite`'s reason exactly: it arrives on a different clock. The adapter pushes a
    /// snapshot several times a second and this is one `osascript` read per *track*, so folding it
    /// in would mean every payload carrying a stale answer or a fork on every payload.
    ///
    /// Animated on `contentSwap`, like the star: a line appearing under the artist is a content
    /// change in §6.2's sense and crossfades with the block it sits in.
    public func applyAudioFormat(_ format: AudioFormat?) {
        guard format != audioFormat else { return }
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            audioFormat = format
        }
    }

    /// Whether the player offers the two fifteen-second jumps. When it does, they take the
    /// previous/next positions in the transport row.
    public var canSkipBackFifteen = false

    public var canSkipForwardFifteen = false

    /// The rate the player reports, or nil when it reports none.
    ///
    /// A **readout**, not a control, and the distinction is the whole of what shipped for playback
    /// speed. `MRMediaRemoteSetPlaybackSpeed` takes an `int`, so it cannot express 1.5×, and what
    /// the integers mean is not established — a control built on it would be a chip that changes a
    /// setting nobody can predict. The rate itself is already in the payload, already drives
    /// `ActivityTimeline.rate`, and is worth saying out loud: a podcast at 1.5× with a bar
    /// advancing at 1× drifts a minute every two, and a listener who has forgotten they left it
    /// there has no other indication.
    ///
    /// Nil at 1× as well as when unreported. "1.0×" on every song is a chip that means nothing on
    /// the overwhelmingly common path.
    public var playbackRate: Double?

    /// The output devices this Mac can play through, and which one it is using.
    ///
    /// The **system** output device, which is a different thing from AirPlay routing inside Music —
    /// see `NowPlayingOutputDevices` in IslandSources, where the distinction and the evidence for
    /// it are written down. Empty draws the tab as unavailable rather than as an empty list.
    public private(set) var outputDevices: [NowPlayingOutputDeviceRow] = []

    public var hasOutputRouting: Bool { !outputDevices.isEmpty }

    /// Where the Up Next list is sitting, and whether it should travel there.
    ///
    /// Pushed in by the shell, which owns the one `NowPlayingQueueScroll` for the same reason it
    /// owns one shelf: two islands showing the same queue must be looking at the same
    /// part of it.
    public var queueScrollTarget = NowPlayingQueueScrollTarget()

    public var queueScrollOffset: CGFloat { queueScrollTarget.offset }

    /// Plays a queue entry. The offset and the id, because the command needs both — see
    /// `NowPlayingAdapterLocation.playQueueItemArguments`.
    @ObservationIgnored public var onPlayQueueItem: ((Int, String?) -> Void)?

    /// Selects a system output device.
    @ObservationIgnored public var onSelectOutputDevice: ((UInt32) -> Void)?

    /// Adopts a new queue window.
    ///
    /// Its own entry point rather than more parameters on `apply`, for the reason `setUpNext` is:
    /// the queue arrives on its own line of the adapter's stream and lands a beat either side of
    /// the state it belongs to. Folding it in would mean every pause restated the queue, and the
    /// one that arrived first would clear it.
    ///
    /// Unanimated. The rows are behind a scroll view whose contents SwiftUI diffs by `id`, and a
    /// spring on the collection would animate every row's frame every time a page landed —
    /// including the rows that did not move, which is what makes a list look like it is breathing.
    public func setQueue(_ rows: [NowPlayingQueueRow]) {
        guard rows != queue else { return }
        queue = rows
    }

    public func setOutputDevices(_ devices: [NowPlayingOutputDeviceRow]) {
        guard devices != outputDevices else { return }
        outputDevices = devices
    }

    /// Plays the entry at a window offset. Zero is refused: it is the track already playing, and
    /// the honest answer to "play what is playing" is nothing rather than a restart nobody asked
    /// for.
    public func playQueueItem(at index: Int) {
        guard let row = queue.first(where: { $0.index == index }), !row.isCurrent else { return }
        onPlayQueueItem?(row.index, row.contentItemIdentifier)
    }

    public func selectOutputDevice(_ id: UInt32) {
        onSelectOutputDevice?(id)
    }

    /// The current track's cover, already downsampled. Nil draws the fallback glyph.
    ///
    /// `@ObservationIgnored` would be wrong here — the whole point is that the island redraws when
    /// the artwork arrives, a beat after the title.
    public var artwork: CGImage?

    /// The last value the app shell pushed in, so a change originating *here* — a control the user
    /// pressed — animates under the same setting as one arriving from the player. §6.3 is a
    /// correctness requirement, and a button that crossfades regardless of it would breach it in the
    /// one place the user is certain to be looking.
    @ObservationIgnored private var reduceMotion = false

    @ObservationIgnored public var onCommand: ((NowPlayingControlCommand) -> Void)?

    /// Asks the app shell to bring the player forward. IslandUI cannot do it itself: launching an
    /// application is `NSWorkspace`'s, and this package deliberately reaches for nothing outside
    /// SwiftUI.
    @ObservationIgnored public var onOpenPlayer: ((String) -> Void)?

    /// Brings whatever is playing to the front.
    public func openPlayer() {
        guard let playerBundleIdentifier else { return }
        onOpenPlayer?(playerBundleIdentifier)
    }

    /// Seconds, not a fraction. The fraction is a property of the bar's width and the caller does
    /// not have one; converting here, once, against the duration the timeline already carries, is
    /// what stops a rounding difference between the drawn playhead and the position seeked to.
    @ObservationIgnored public var onSeek: ((TimeInterval) -> Void)?

    /// Where the playhead is being dragged to, while a drag is in progress.
    ///
    /// Held as a whole `ActivityTimeline` rather than as a bare fraction so that exactly one type
    /// answers "where is the playhead" everywhere on screen. A `Double?` beside a timeline is two
    /// sources of truth for one number, and the numerals under the bar would be reading a different
    /// one from the bar itself.
    public private(set) var draggedTimeline: ActivityTimeline?

    /// The position asked for, and the instant it stops being believed. See `seekSettleWindow`.
    private var pendingSeek: (timeline: ActivityTimeline, instant: Date, deadline: Date)?

    public init() {}

    // MARK: - What the app shell pushes in

    /// Adopts the player's state, animated on the token a content change travels on.
    ///
    /// Animated *here* rather than at the call site, and that is the same rule the rest of the
    /// codebase follows in the other direction: motion decisions belong to IslandUI, and the app
    /// shell is wiring. The token is `contentSwap` because this is §6.2's "same activity, new
    /// content" exactly — the play glyph becoming a pause glyph must crossfade on the same curve as
    /// the title beside it, not snap a frame ahead of it.
    public func apply(
        isPlaying: Bool,
        canSkip: Bool,
        isTransportAvailable: Bool,
        playerBundleIdentifier: String? = nil,
        isRadioStation: Bool = false,
        canFavorite: Bool = false,
        isFavorite: Bool = false,
        canSkipBackFifteen: Bool = false,
        canSkipForwardFifteen: Bool = false,
        playbackRate: Double? = nil,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        if let playerBundleIdentifier, playerBundleIdentifier != self.playerBundleIdentifier {
            // A different application's queue. What the user asked Music for says nothing about
            // Spotify, and leaving the highlight lit would be the island asserting a setting it has
            // never been told anything about.
            isShuffling = false
            repeatMode = .off
        }
        // Leaving a station for a queue changes nothing else about the track, so the comparison has
        // to include it or the two controls stay dimmed until something unrelated moves.
        if isRadioStation, !self.isRadioStation {
            // A station has no queue to carry a setting, and the player has forgotten whatever was
            // asked for before it started. Claiming otherwise would light a control the user cannot
            // press.
            isShuffling = false
            repeatMode = .off
        }
        guard isPlaying != self.isPlaying
            || canSkip != self.canSkip
            || isTransportAvailable != self.isTransportAvailable
            || playerBundleIdentifier != self.playerBundleIdentifier
            || isRadioStation != self.isRadioStation
            || canFavorite != self.canFavorite
            || isFavorite != self.isFavorite
            || canSkipBackFifteen != self.canSkipBackFifteen
            || canSkipForwardFifteen != self.canSkipForwardFifteen
            || playbackRate != self.playbackRate
        else { return }
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            self.isPlaying = isPlaying
            self.canSkip = canSkip
            self.isTransportAvailable = isTransportAvailable
            self.playerBundleIdentifier = playerBundleIdentifier
            self.isRadioStation = isRadioStation
            // The heart's fill and the previous/next glyphs becoming the fifteen-second jumps are
            // content changes in §6.2's sense and crossfade with the title beside them, rather than
            // snapping a frame ahead of it.
            self.canFavorite = canFavorite
            self.isFavorite = isFavorite
            self.canSkipBackFifteen = canSkipBackFifteen
            self.canSkipForwardFifteen = canSkipForwardFifteen
            self.playbackRate = playbackRate
        }
    }

    /// Adopts the next track.
    ///
    /// Its own entry point rather than two more parameters on `apply`, because it arrives on its own
    /// clock: the queue is a second line on the adapter's stream and lands a beat either side of the
    /// state it belongs to. Folding it into `apply` would mean every state change had to restate the
    /// queue, and the one that arrived first would clear it.
    ///
    /// Unanimated, unlike everything else the shell pushes in. Nothing is on screen when this
    /// changes — the peek is ten seconds from the end of a track whose next song has just been
    /// decided — and the crossfade that matters is the one at the boundary, which
    /// `NowPlayingSlotView` runs against `isDue` rather than against this.
    public func setUpNext(title: String?, artist: String?) {
        guard title != upNextTitle || artist != upNextArtist else { return }
        upNextTitle = title
        upNextArtist = artist
    }

    /// Adopts a new cover. Crossfaded for the same reason, and it is the more visible of the two:
    /// artwork lands a beat *after* the title it belongs to, because it costs a second helper
    /// invocation and an image decode, so an unanimated swap reads as a glitch rather than as the
    /// rest of the track arriving.
    public func setArtwork(_ image: CGImage?, reduceMotion: Bool) {
        guard image !== artwork else { return }
        // Read once, here, on the one event that can change it — never on a frame, never on a
        // timer. It is one CoreGraphics draw of an already-decoded image into an 8x8 context (see
        // `AlbumColor.average(of:)`), and it happens on the same transaction as the crossfade so
        // the accent and the cover it came from arrive together rather than a frame apart.
        let accent = image.flatMap(AlbumColor.accent(from:))
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            artwork = image
            albumColor = accent
        }
    }

    /// The accent this track's cover gives, or nil.
    ///
    /// Nil is the ordinary state and the whole of the degraded path: no artwork, or an unreadable
    /// image, and `ActivityPalette.albumAccent` then answers with the palette's own color — so a
    /// record with no cover and one whose cover could not be read look identical, which is what
    /// they should.
    ///
    /// **This is the only switch there is.** There was a `usesAlbumColor` flag beside it, pushed in
    /// from `AppearanceSettings.albumColor`, and it went with that record: taking the accent from
    /// the sleeve is what the Now Playing island *is*, and the alternative it offered was the same
    /// island in the palette's gray. Increase Contrast is still honored below, which is the one
    /// case where a color off an arbitrary image is the wrong answer.
    public private(set) var albumColor: AlbumColor?

    /// The accent the Now Playing chrome should use — the cover's, or the one it is handed.
    ///
    /// **What this tints, and what it deliberately does not.** It tints the transport glyphs, the
    /// cover's fallback well and the played portion of the scrub bar — the chrome that belongs to
    /// *this track* — the equaliser included, through `barColors(increaseContrast:)`, which leans
    /// this same color across the six bars rather than answering with a second one. It does not
    /// tint the numerals, which are gray because a colored number reads as a value that means something by its color; it does
    /// not tint the titles, which have to stay legible; it does not touch the island's own material,
    /// which is `IslandStyle`'s; and it reaches no other activity — a timer keeps Clock's orange and
    /// a battery ring keeps its green and amber, because those two colors *mean* something and an
    /// album cannot be allowed to restate them.
    ///
    /// Increase Contrast returns the fallback. A color derived from an arbitrary image cannot be
    /// promised any particular contrast, and a user who has asked the system for more of it has
    /// already answered this question.
    public func accent(_ fallback: Color, increaseContrast: Bool) -> Color {
        guard !increaseContrast, let albumColor else { return fallback }
        return albumColor.color
    }

    /// The color each equaliser bar should be drawn in, or nil for the white row.
    ///
    /// **The accent, not a second reading of the cover.** An earlier version took a color per
    /// vertical band of the sleeve, which put a row of up to six unrelated hues 40pt from a scrub
    /// bar drawn in one — two answers to "what color is this record" on the same island, and on a
    /// busy sleeve the row read as a rainbow rather than as the record. This is the color
    /// `accent(_:increaseContrast:)` already hands the scrub bar, leaned across the row by
    /// `AlbumColor.row(_:count:)` so the bars have a direction without having a second color.
    ///
    /// Derived on demand rather than stored beside `albumColor`: it is arithmetic on three doubles
    /// with no image in it, and a stored copy would be one more thing `reset()` has to remember to
    /// clear with the track.
    ///
    /// Gated exactly like `accent(_:increaseContrast:)`, and for its reason: off under Increase
    /// Contrast, where no color taken off an arbitrary image can be promised any contrast and white
    /// is the answer the user has already given.
    public func barColors(increaseContrast: Bool) -> [AlbumColor]? {
        guard !increaseContrast, let albumColor else { return nil }
        return AlbumColor.row(albumColor)
    }

    /// Whether a drag is in progress. The playhead must not run under the pointer while it is.
    public var isScrubbing: Bool { draggedTimeline != nil }

    // MARK: - The one answer to "where is the playhead"

    /// Resolves what the player reports against what the user has asked for.
    ///
    /// Pure, and that is what lets the optimistic seek expire with no timer: the deadline is checked
    /// against the `now` the display link is already publishing, so the value corrects itself on the
    /// next frame the island draws and costs nothing on the frames it does not.
    ///
    /// The precedence is drag, then pending seek, then the player — and the middle case has one
    /// subtlety worth spelling out. A pending seek is abandoned the moment the player reports a
    /// timeline anchored *after* the command went out, because that report is the player answering.
    /// Comparing positions instead would be wrong in the case that matters: a player that refused
    /// the seek reports the old position, which is exactly when the optimistic value must give way.
    public func timeline(reportedBy base: ActivityTimeline?, at now: Date) -> ActivityTimeline? {
        if let draggedTimeline { return draggedTimeline }
        if let pendingSeek, now < pendingSeek.deadline {
            if let base, base.anchor > pendingSeek.instant { return base }
            return pendingSeek.timeline
        }
        return base
    }

    // MARK: - Scrubbing

    /// Starts a drag from the timeline currently on screen.
    ///
    /// The dragged timeline is pinned at `rate` zero for the length of the drag. Leaving it
    /// advancing would have the playhead crawl away from the pointer while the pointer is holding
    /// it still — the bar and the finger disagreeing about where the drag is, which reads as the
    /// control being laggy rather than as playback continuing.
    public func beginScrub(from base: ActivityTimeline?, toFraction fraction: Double, at now: Date) {
        guard let base, base.duration > 0 else { return }
        draggedTimeline = ActivityTimeline(
            elapsed: Self.position(of: fraction, in: base),
            duration: base.duration,
            anchor: now,
            rate: 0
        )
    }

    public func updateScrub(toFraction fraction: Double) {
        guard let dragged = draggedTimeline else { return }
        draggedTimeline = ActivityTimeline(
            elapsed: Self.position(of: fraction, in: dragged),
            duration: dragged.duration,
            anchor: dragged.anchor,
            rate: 0
        )
    }

    /// Ends the drag and sends the seek.
    ///
    /// The optimistic value takes the *player's* rate back, not the drag's zero: a track that was
    /// playing when the drag started is still playing, and a playhead that stopped dead at the drop
    /// point for a second and a half before lurching forward is worse than no optimism at all.
    public func endScrub(reportedBy base: ActivityTimeline?, at now: Date) {
        guard let dragged = draggedTimeline else { return }
        draggedTimeline = nil

        let position = dragged.elapsed
        let rate = base?.rate ?? dragged.rate
        pendingSeek = (
            timeline: ActivityTimeline(
                elapsed: position,
                duration: dragged.duration,
                anchor: now,
                rate: rate
            ),
            instant: now,
            deadline: now.addingTimeInterval(Self.seekSettleWindow)
        )
        onSeek?(position)
    }

    /// Abandons a drag without seeking — the panel was rebuilt, or the activity went away underneath
    /// it. Distinct from `endScrub`, which commits: a display reconfiguration must not move the
    /// user's music.
    public func cancelScrub() {
        draggedTimeline = nil
    }

    // MARK: - Transport

    public func send(_ command: NowPlayingControlCommand) {
        // The Up Next button is not a transport command and must not be gated on there being a
        // transport: reading the queue and controlling the player are separate capabilities on the
        // same machine, which is why they are separate protocols in IslandSources. In practice both
        // come from the adapter, but a build where one retires and the other does not is exactly
        // the case this ordering exists for.
        if command == .toggleQueue {
            guard canReadQueue else { return }
            onCommand?(command)
            return
        }
        guard isTransportAvailable else { return }
        guard Self.permits(
            command,
            canSkip: canSkip,
            canChangeQueueBehavior: canChangeQueueBehavior,
            canFavorite: canFavorite,
            canReadQueue: canReadQueue
        ) else { return }
        // A skip abandons any optimistic position: it belonged to a track that is no longer the one
        // playing, and leaving it in place would paint the new track's bar at the old one's offset
        // for the length of the settle window. Shuffle and repeat change neither the track nor the
        // playhead, so they leave a drag that is still settling alone.
        if command == .previousTrack || command == .nextTrack { pendingSeek = nil }

        // Adopted here rather than waiting to be told, because nothing tells us — see
        // `NowPlayingRepeatMode`. Animated on `contentSwap` for the same reason the play glyph is:
        // the highlight arriving is a content change, and it lands beside four glyphs that all
        // crossfade.
        switch command {
        case .toggleShuffle:
            withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
                isShuffling.toggle()
            }
        case .toggleRepeat:
            withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
                repeatMode = repeatMode.next
            }
        case .toggleFavorite:
            // Adopted here rather than waiting to be told, exactly as shuffle and repeat are — but
            // for the opposite reason, and that is worth being precise about. Those two are held
            // because **nothing ever reports them**; this one *is* reported, on the next payload
            // the player emits, and the optimistic flip is only covering the pipe hop. If the
            // player disagrees, the next `apply` overrules this, which is the correct precedence
            // and the one shuffle and repeat can never have.
            withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
                isFavorite.toggle()
            }
        case .previousTrack, .togglePlayPause, .nextTrack,
             .skipBackFifteen, .skipForwardFifteen, .toggleQueue:
            break
        }
        onCommand?(command)
    }

    /// Whether a control may act, per command.
    ///
    /// Pure, and one rule per command rather than one rule for "not play/pause": the two ways a
    /// player limits its transport are unrelated. A stream that forbids skipping still has a queue
    /// to shuffle; a radio station usually *allows* skipping and has no queue at all. Answering both
    /// with `canSkip` grayed the wrong pair in each direction.
    /// Whether a control may act, per command.
    ///
    /// **One rule per command, never a shared "not play/pause".** The four ways a player limits
    /// what the island may offer are mutually unrelated, and answering any two of them with one
    /// flag grays the wrong control in each direction:
    ///
    /// - `prohibitsSkip` — a stream that forbids skipping still has a queue to shuffle.
    /// - a radio station — usually *allows* skipping and has no queue at all.
    /// - `supportsIsLiked` — a local library track permits everything else and offers no like.
    /// - a route that reads no queue — a scripting-fallback build controls the player perfectly and
    ///   has nothing to list.
    static func permits(
        _ command: NowPlayingControlCommand,
        canSkip: Bool,
        canChangeQueueBehavior: Bool,
        canFavorite: Bool = false,
        canReadQueue: Bool = false
    ) -> Bool {
        switch command {
        case .togglePlayPause: true
        // The fifteen-second jumps are *not* gated on `canSkip`: they move the playhead inside the
        // item rather than leaving it, so a stream that forbids skipping to the next track may
        // perfectly well permit going back fifteen seconds. Whether they are drawn at all is the
        // player's own `supportsRewind15Seconds` / `supportsFastForward15Seconds`, which is a
        // different question from whether they are permitted once drawn.
        case .previousTrack, .nextTrack: canSkip
        case .skipBackFifteen, .skipForwardFifteen: true
        case .toggleShuffle, .toggleRepeat: canChangeQueueBehavior
        case .toggleFavorite: canFavorite
        case .toggleQueue: canReadQueue
        }
    }

    /// Clears everything a track change or a stop invalidates.
    public func reset() {
        draggedTimeline = nil
        pendingSeek = nil
        artwork = nil
        // With the cover. An accent outliving the track it was taken from is the transport row of
        // the *next* song wearing the *last* one's color, which is the one way this feature could
        // look broken rather than merely absent.
        albumColor = nil
        isPlaying = false
        // Cleared with the rest of it. A next track outliving the queue it came from is the one
        // failure mode of this feature that a user would actually notice: the island naming a song
        // that will not play, ten seconds before it does not.
        upNextTitle = nil
        upNextArtist = nil
        // The list goes with the track for the same reason the peek does, and it is the more
        // visible of the two: rows naming songs that will not play, in a surface whose double-click
        // would ask a player that has stopped to jump to one of them.
        queue = []
        queueScrollTarget = NowPlayingQueueScrollTarget()
        isFavorite = false
        canFavorite = false
        canSkipBackFifteen = false
        canSkipForwardFifteen = false
        playbackRate = nil
        // **`outputDevices` is deliberately not cleared.** It is a fact about the machine, not about
        // the track — the Mac still has speakers when the music stops — and clearing it would empty
        // the Output tab every time playback ended.
    }

    private static func position(of fraction: Double, in timeline: ActivityTimeline) -> TimeInterval {
        min(max(0, fraction), 1) * timeline.duration
    }
}
