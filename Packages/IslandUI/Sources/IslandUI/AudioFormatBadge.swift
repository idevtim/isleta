import AppKit
import IslandActivities
import SwiftUI

/// Apple's own audio badges, borrowed from Music at runtime rather than shipped.
///
/// ## Why these are not in our asset catalog
///
/// The badge for a Dolby Atmos track is Dolby's registered trademark, and the Lossless one is
/// Apple's. Apple draws them under licence; Isleta has none, so a copy of either sitting inside a
/// notarised app is redistribution of somebody else's mark. Loading the artwork Music already has
/// on the machine is a different act: nothing is copied, nothing is redistributed, and what appears
/// under the artist is the same file Music itself is drawing from.
///
/// It also ages better than a copy would. These are the marks Apple ships with *this* macOS, so a
/// redesigned badge arrives with the OS instead of waiting for a release of Isleta.
///
/// ## How
///
/// `NSBundle.imageForResource:` reads another bundle's asset catalog, and it is public API — the
/// private `CUICatalog` route this looked like it would need turns out to be unnecessary. Measured
/// on macOS 27.0, 2026-08-28, against `/System/Applications/Music.app`:
///
/// | Asset | Size | Template |
/// |---|---|---|
/// | `audioBadgeLosslessTemplate` | 60×18 | yes |
/// | `audioBadgeHi-ResLosslessTemplate` | 57×18 | yes |
/// | `audioBadgeDolbyAtmosTemplate` | 83×14 | yes |
/// | `audioBadgeAppleDigitalMasterTemplate` | 72×18 | yes |
/// | `audioBadgeSpatialAudioTemplate` | 47×20 | yes |
///
/// Every one is a **template**, which is what makes them usable here at all: the island is white on
/// black and these are drawn in whatever colour the row asks for, rather than being black artwork
/// that would vanish into it.
///
/// **Each badge already contains its own words.** "Lossless" at 60pt wide is the mark *and* the
/// word, so a row drawing one of these draws no text beside it — see `NowPlayingSlotView`.
///
/// ## When it is not there
///
/// A Mac with Music removed, or a macOS that renamed an asset, answers nil — and nil is a real
/// answer that the caller has a real feature underneath: the SF Symbol and the word Isleta drew
/// before this existed. That is §8's rule for every private or fragile path in this app, and this
/// one is fragile in exactly the documented way: the names are Apple's and Apple may change them.
@MainActor
public enum AudioFormatBadge {

    /// Music, or nil where it is not installed.
    ///
    /// Resolved once. `Bundle(path:)` reads a plist off disk, and while that is cheap it is not
    /// free, and this is asked on every track change.
    private static let musicBundle = Bundle(path: "/System/Applications/Music.app")

    /// Apple's own name for each badge.
    ///
    /// Nil where Isleta has a kind Apple has no badge for. `.multichannel` is one: MediaRemote's
    /// vocabulary has it (Stereo, Multichannel, Atmos) and Music's badge set does not, because a
    /// multichannel track that is not Atmos is not something Apple Music sells. It keeps the SF
    /// Symbol and the word.
    static func assetName(for kind: AudioFormat.Kind) -> String? {
        switch kind {
        case .dolbyAtmos: "audioBadgeDolbyAtmosTemplate"
        case .lossless: "audioBadgeLosslessTemplate"
        case .hiResLossless: "audioBadgeHi-ResLosslessTemplate"
        case .multichannel, .lossy: nil
        }
    }

    /// One badge per kind, loaded once.
    ///
    /// **Cached because this is asked on every track change and the answer cannot change without a
    /// macOS update.** A miss is cached too — as `.some(nil)` — so a Mac without Music does not go
    /// back to the disk once per song for an answer that will not have changed.
    private static var cache: [AudioFormat.Kind: NSImage?] = [:]

    /// Apple's badge for this format, or nil to draw Isleta's own.
    public static func image(for kind: AudioFormat.Kind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = assetName(for: kind).flatMap { musicBundle?.image(forResource: $0) }
        // Belt and braces: the catalog says these are templates and every one measured as such, but
        // an asset that arrives non-template would paint black on black and read as nothing at all.
        image?.isTemplate = true
        cache[kind] = image
        return image
    }
}
