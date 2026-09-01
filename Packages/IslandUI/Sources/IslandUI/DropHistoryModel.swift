import Foundation
import Observation
import SwiftUI

/// How far the drop history is scrolled, and where it should be sitting.
///
/// **Aliases rather than another copy of a value that already exists.** `ShelfScroll` and
/// `IslandListScroll` are the same forty lines with different doc comments, and a third would be a
/// third place the natural-scrolling rule could be got backwards. This surface is a vertical list
/// of rows, newest at offset zero, obeying the user's "natural scrolling" preference rather than
/// undoing it (see `IslandListScroll`, where the distinction between a list and a gesture is
/// argued) — so it takes that type by name instead of agreeing with it by hand.
public typealias DropHistoryScroll = IslandListScroll

/// Where the history should be sitting. See `IslandListScrollTarget`; the `sequence` field is what
/// makes a repeat target reach the view.
public typealias DropHistoryScrollTarget = IslandListScrollTarget

/// What Isleta has done with the files it was given, and what the island is showing of it.
///
/// **One instance, not one per screen** — `ShelfModel`'s reason exactly. There is one user who did
/// one set of things; a history per display would let the laptop and the external monitor disagree
/// about what happened, and there would be no answer to which one is right.
///
/// ## It persists, and the shelf is the precedent
///
/// The rule that decides this is about *whose* content a list holds. A list of somebody else's
/// messages is never written to disk at any level — that is why the notification list Isleta used
/// to keep lived in memory and died with the process. Every entry here is the opposite: a record of
/// an act **the user performed on their own files**, the same class of information the shelf
/// already keeps in `~/Library/Application Support/Isleta/shelf.json`, in the same form (paths and
/// bookmarks), for the same reason.
///
/// And the feature does not work without it. The question a drop history answers is "where did that
/// converted file go" and "what was that link" — questions asked *later*, usually after a quit.
/// `ShortcutAction.copyLastLink` settles it on its own: a global keyboard shortcut whose answer is
/// forgotten at every launch is a shortcut that reads as broken.
///
/// What that costs is a file listing paths to the user's own files, and three limits go with it:
///
/// - **No contents, ever.** Names, paths, bookmarks and Isleta's own words. Never a transcript —
///   the worker writes that text to disk itself and it does not enter this process (see
///   `ShelfActionController`) — and never the body of anything converted.
/// - **Nothing here is logged or exported.** Not at `debug`, not into the "Export Logs…" bundle.
///   A file name is covered by the logging rule exactly as a message would be: the log is emailed
///   to strangers. Counts and `DropHistoryAction` values only.
/// - **It is clearable from the surface it is drawn on**, which is the only privacy control that
///   means anything, and it ages out on its own (`retention`).
@MainActor
@Observable
public final class DropHistoryModel {

    /// How many acts are remembered.
    ///
    /// **Forty, evicted oldest-first.** This is a log of the user's own completed acts, read
    /// newest-first. There is no usage weight to evict by — every entry happened exactly once and
    /// will never happen again — so it is a plain ring on arrival order, because recency is the only
    /// ordering that means anything here. Forty because it is *ten screenfuls* at
    /// `DropHistoryLayout.visibleRows`, which is already more scrolling than anybody will do to find
    /// a file they converted this morning, and because this one is written
    /// to disk: the honest ceiling on a file of paths is the smallest one that still answers the
    /// question.
    ///
    /// It is deliberately **not** bounded by launch cost the way the shelf's thirty is. The shelf
    /// resolves every bookmark at launch because its whole claim is that what it shows is there;
    /// this list's claim is only that the act happened, which stays true whatever the disk says, so
    /// nothing is resolved until a row is clicked. A launch costs one JSON decode.
    public nonisolated static let capacity = 40

    /// How long an entry is kept regardless of capacity.
    ///
    /// Thirty days. A record of a conversion from last spring answers nothing anybody is about to
    /// ask and is only a longer list of the user's paths in a file — so it goes, on load, with no
    /// control to forget and no setting to get wrong. Capacity bounds a busy week; this bounds a
    /// quiet year.
    public nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Newest first, which is the order the list draws and the order the question is asked in.
    public private(set) var entries: [DropHistoryEntry] = []

    /// Whether the open island is showing the history instead of the activity's own body.
    ///
    /// Held here rather than on `IslandScreenModel` for the reason `NowPlayingController.isShowingQueue`
    /// is held on the controller: there is one user reading one list, and this class is app-wide
    /// while that one is per screen. It is set **inside** the animated transaction that also swaps
    /// the island's metrics — see the note on `IslandScreenModel.setShowingNowPlayingQueue`, and the
    /// wiring in `DropHistoryController` — because setting it from the shell instead swaps the body
    /// a frame before the island has grown to hold it.
    public var isShowing = false

    /// Where the list should be sitting, and whether it should travel there.
    ///
    /// Pushed in by the app shell, which owns the one `DropHistoryScroll` for the same reason it
    /// owns one `isShowing`: two islands showing this list must be looking at the same part of it.
    public var scrollTarget = DropHistoryScrollTarget()

    public var scrollOffset: CGFloat { scrollTarget.offset }

    /// Rows whose file could not be reached when they were last clicked, and Isleta's words for why.
    ///
    /// **The answer to "what does a row do when the file is gone" is that it says so, in the row,
    /// and stops there.** Three alternatives were rejected. Publishing an activity puts the message
    /// in the flanks of a *collapsed* island, which are not on screen while this surface is open —
    /// the bug `ShelfJobStatus` exists to fix, one surface along. A banner in the header would need a
    /// clock to take it away again, and §9 forbids a timer on the idle path. And rewriting the
    /// entry's `failure` would destroy the record of what actually happened, which is the one thing
    /// this list is for.
    ///
    /// So it is per row, it is *not* persisted, and it is cleared whenever the surface opens or
    /// closes — because the two facts it can carry are both temporary (a disk that is not plugged in
    /// today) or already permanent and visible (a file that has been deleted, whose row now offers
    /// nothing to click). Keeping it would make a row that once failed go on saying so after the
    /// disk came back.
    public private(set) var unavailable: [UUID: String] = [:]

    /// Whether the drop actions are switched on (`SourceToggles.dropActions`).
    ///
    /// Pushed in by the app shell, which owns the configuration. Off means nothing is recorded and
    /// the surface is unreachable — the history of a feature that is switched off is empty by
    /// definition, and drawing it would be a list that can only ever say "nothing yet".
    public var isEnabled = true

    // MARK: - What the rows do. Set by the app shell.

    /// Reveal this entry's file in the Finder. The whole row is this control.
    public var onReveal: ((UUID) -> Void)?

    /// Do the same thing again. Drawn only where `DropHistoryEntry.canRunAgain`.
    public var onRunAgain: ((UUID) -> Void)?

    /// Put this entry's link on the pasteboard. Drawn only where there is one.
    public var onCopyLink: ((UUID) -> Void)?

    /// Forget everything, and close.
    public var onClear: (() -> Void)?

    /// Close, and keep it.
    public var onClose: (() -> Void)?

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    /// The most recent link Isleta produced, or nil.
    ///
    /// What `ShortcutAction.copyLastLink` reads, and the reason this list is written to disk at all:
    /// a shortcut that answers nothing after a relaunch is a shortcut that reads as broken. Only
    /// successful entries are considered — a `shareLink` row that failed has a `failure` and no
    /// `link`, so this cannot hand back the last link that *did not* get made.
    public var lastLink: String? {
        entries.first(where: { $0.succeeded && $0.link != nil })?.link
    }

    public func entry(id: UUID) -> DropHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// Records one act, newest first, and evicts whatever no longer fits.
    ///
    /// `Motion.contentSwap` — the token for "the same thing, saying something new" (§6.2), which is
    /// exactly what a row appearing in a list already on screen is. The island's shape does not
    /// move: `DropHistoryLayout.contentHeight` is a constant precisely so that a conversion
    /// finishing while somebody is reading cannot resize the surface under them.
    public func record(_ entry: DropHistoryEntry, reduceMotion: Bool) {
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            entries.insert(entry, at: 0)
            trimToCapacity()
        }
    }

    /// Replaces one entry in place, keeping its position.
    ///
    /// What a row does when the file behind it turns out to have been renamed or moved: the record
    /// follows the file and is written back, so the *next* click does not have to resolve the
    /// bookmark again. Silent — no animation — because nothing the user can see has changed, and a
    /// crossfade on a row whose text is identical is a flicker for nothing.
    public func replace(_ entry: DropHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
    }

    /// Notes that a row's file could not be reached, in Isleta's own words.
    ///
    /// `Motion.contentSwap` — the row is saying something new about itself and nothing has moved.
    public func markUnavailable(id: UUID, because explanation: String, reduceMotion: Bool) {
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            unavailable[id] = explanation
        }
    }

    /// Forgets every such note. Called on both edges of the surface opening — see `unavailable`.
    public func clearUnavailable() {
        unavailable.removeAll()
    }

    /// What a row's second line says: why the last click did not work, or what came of the work.
    public func detail(for entry: DropHistoryEntry) -> String {
        unavailable[entry.id] ?? entry.detail
    }

    /// Whether a row should be drawn as a problem: the work failed, or the file cannot be reached.
    public func isTroubled(_ entry: DropHistoryEntry) -> Bool {
        !entry.succeeded || unavailable[entry.id] != nil
    }

    @discardableResult
    public func removeAll(reduceMotion: Bool) -> Int {
        let removed = entries.count
        withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: reduceMotion)) {
            entries.removeAll()
            unavailable.removeAll()
        }
        return removed
    }

    /// Adopts a history read back from disk.
    ///
    /// Un-animated, for the reason `ShelfModel.restore` is: this runs before the first island frame,
    /// and a spring played against a view that has never been drawn is a spring nobody sees.
    ///
    /// The two eviction rules are applied **here** as well as on `record`, because a record written
    /// by a build with a larger capacity, or one left on disk over a long absence, must not come
    /// back longer or older than this build's rules allow.
    public func restore(_ entries: [DropHistoryEntry], now: Date = Date()) {
        self.entries = entries.sorted { $0.finishedAt > $1.finishedAt }
        trim(now: now)
    }

    /// At most `capacity`, oldest off the end.
    private func trimToCapacity() {
        guard entries.count > Self.capacity else { return }
        entries.removeLast(entries.count - Self.capacity)
    }

    /// The same, plus the age rule.
    ///
    /// **Retention is applied on load and not on record**, which is deliberate and is what the two
    /// rules mean. Capacity is about how long a list a person will read and is enforced continuously;
    /// retention is about how long a file of the user's paths should exist, and the moment to answer
    /// that is when the file is opened. Applying it on `record` as well would also make the method
    /// depend on the wall clock agreeing with the entry it is being handed — which is exactly the
    /// shape of dependency that turns a fixed date in a test, or a machine whose clock has just been
    /// corrected, into a list that silently discards what it was told to remember.
    private func trim(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.finishedAt) > Self.retention }
        trimToCapacity()
    }
}
