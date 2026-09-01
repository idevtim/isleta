import Foundation

/// Where a piece of work Isleta is doing to a file has got to.
///
/// Three states and no `.queued`, because there is no queue: a conversion is spawned when the user
/// picks it and there is nothing to wait behind. If that ever changes, the queued state belongs
/// here and not in the app shell, for the reason `ActivityStack` is a value — the states a thing can
/// be in are the part worth testing.
public enum FileActionStage: Equatable, Sendable {

    /// Running, with a fraction where the route can report one. `nil` is a real answer rather than
    /// zero: `AVAssetExportSession` reports genuine progress, and the TextKit and ImageIO routes
    /// have nothing to report at all — a bar sitting at 0% for the whole of a job is a worse lie
    /// than an indeterminate one.
    case running(fraction: Double?)

    /// Finished, with what it produced. The count rather than the names — see the note on
    /// `BuiltInActivity.fileAction`.
    case finished(produced: Int)

    /// It could not be done. `reason` is Isleta's own words, never the system's error text and
    /// never anything containing a path.
    case failed(reason: String)
}

/// One piece of work on one or more files: what it is, how far along, and what it produced.
///
/// The whole value is deliberately free of `URL`s. The activity built from it is a thing that ends
/// up in a log line and on a screen somebody might be sharing, and the rule this codebase keeps is
/// that **nothing the user did not write goes into either** — so the island says "Converting to
/// JPEG · 3 files" and never says which three. The app shell holds the URLs and does not hand them
/// on.
public struct FileActionJob: Equatable, Sendable {

    public let id: ActivityID

    /// What is being done, in the words the menu used: "Convert to JPEG", "Transcribe".
    public let action: String

    /// SF Symbol for the work, from `DropAction.symbol`.
    public let symbol: String

    /// How many files are in this job.
    public let fileCount: Int

    public var stage: FileActionStage

    public init(
        id: ActivityID,
        action: String,
        symbol: String,
        fileCount: Int,
        stage: FileActionStage = .running(fraction: nil)
    ) {
        self.id = id
        self.action = action
        self.symbol = symbol
        self.fileCount = fileCount
        self.stage = stage
    }

    /// The same job, further along. A value rather than a mutation so the app shell can hand the
    /// coordinator a new activity built from it without the two disagreeing about what "the job" is.
    public func advanced(to stage: FileActionStage) -> Self {
        Self(id: id, action: action, symbol: symbol, fileCount: fileCount, stage: stage)
    }
}

extension BuiltInActivity {

    /// Work Isleta is doing to a file the user dropped.
    ///
    /// ## Why this is an extension rather than a case in `BuiltInActivity.swift`
    ///
    /// `ActivityKind.fileAction` already exists, with its entries in all six tables, and the file
    /// that declares it is one of the shared records the 2.0 fan-out rule keeps for the integrator —
    /// appending to a shared struct is the cross-package memory-layout trap CLAUDE.md documents,
    /// where dependent packages read every field at the wrong offset with no compile error. A
    /// factory adds no storage and no case, so it can live beside the feature that needs it.
    ///
    /// ## What the island actually shows
    ///
    /// `fileAction` is `.standard` and `flankAffinity` is `.trailing`, and the two together are what
    /// make this work while the shelf is open. Same priority as the shelf and non-displacing, so the
    /// shelf — which arrived first — keeps the body, and this becomes the **companion**: the
    /// collapsed island draws the shelf's tray on the leading sliver and this job's fraction on the
    /// trailing one, which is the flanked island doing exactly what it was built for. Nothing is
    /// preempted and nothing had to be pinned.
    ///
    /// Only `.tracked` work ever reaches here. A JPEG encode is 80 ms and an island that appeared
    /// and left inside five frames is a flicker, so `ConversionProgressClass` is asked first and the
    /// two faster classes publish nothing at all.
    ///
    /// - Parameter job: never carries a file name, a path or a transcript — see `FileActionJob`.
    public static func fileAction(_ job: FileActionJob) -> Self {
        // One key with a plural rule behind it, not a `== 1` ternary — see `BuiltInActivity.shelf`.
        let count = activityText("fileAction.fileCount", "\(job.fileCount) files")

        switch job.stage {
        case .running(let fraction):
            let value: ActivityValue = fraction.map { .fraction($0) } ?? .indeterminate
            return Self(
                id: job.id,
                kind: .fileAction,
                presentations: ActivityPresentations(
                    leading: ActivityContent(symbol: job.symbol, tint: .accent),
                    trailing: ActivityContent(value: value, tint: .accent),
                    compact: ActivityContent(
                        symbol: job.symbol,
                        title: job.action,
                        value: value,
                        tint: .accent,
                        accessibilityLabel: activityText("fileAction.a11y.running", "\(job.action), \(count)")
                    ),
                    expanded: ActivityContent(
                        symbol: job.symbol,
                        title: job.action,
                        subtitle: count,
                        value: value,
                        tint: .accent,
                        accessibilityLabel: activityText("fileAction.a11y.running", "\(job.action), \(count)")
                    )
                )
            )

        case .finished(let produced):
            let made = activityText("fileAction.fileCount", "\(produced) files")
            // Three seconds, and it is an *expiry on the instance* rather than the kind's, which is
            // `.never`. The kind is right — work ends when the source says it ends, not when a clock
            // does — and this is the source saying so: the job is over, and what is left is a
            // confirmation with the same dwell a device connecting gets.
            return Self(
                id: job.id,
                kind: .fileAction,
                expiry: .after(.seconds(3)),
                presentations: ActivityPresentations(
                    leading: ActivityContent(symbol: "checkmark.circle.fill", tint: .positive),
                    trailing: .empty,
                    compact: ActivityContent(
                        symbol: "checkmark.circle.fill", title: made, tint: .positive
                    ),
                    expanded: ActivityContent(
                        symbol: "checkmark.circle.fill",
                        title: job.action,
                        subtitle: activityText("fileAction.finished.subtitle", "\(made) on the shelf"),
                        tint: .positive,
                        accessibilityLabel: activityText("fileAction.a11y.finished", "\(job.action) finished, \(made)")
                    )
                )
            )

        case .failed(let reason):
            // Longer than the success, because it is the one of the two that has something to read
            // and the one nobody was expecting.
            return Self(
                id: job.id,
                kind: .fileAction,
                expiry: .after(.seconds(6)),
                presentations: ActivityPresentations(
                    leading: ActivityContent(symbol: "exclamationmark.triangle.fill", tint: .warning),
                    trailing: .empty,
                    compact: ActivityContent(
                        symbol: "exclamationmark.triangle.fill", title: reason, tint: .warning
                    ),
                    expanded: ActivityContent(
                        symbol: "exclamationmark.triangle.fill",
                        title: job.action,
                        subtitle: reason,
                        tint: .warning,
                        accessibilityLabel: activityText("fileAction.a11y.failed", "\(job.action) failed, \(reason)")
                    )
                )
            )
        }
    }
}
