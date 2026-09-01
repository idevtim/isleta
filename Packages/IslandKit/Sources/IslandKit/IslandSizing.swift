import CoreGraphics

/// Everything the user has said about how big the island is.
///
/// One value rather than four parameters, and that is the whole point of the type. The drawn shape
/// and the shape `IslandHitTestView.islandPath` accepts clicks in are the same arithmetic evaluated
/// twice, in two packages — `IslandLayout.metrics` for the renderer and `IslandController` for the
/// window server — and a dimension that reaches one and not the other is not a cosmetic mismatch: a
/// hit region smaller than the drawing is clicks landing on lit island pixels and being dropped,
/// which neither opens the island nor reaches the app underneath. `peekScale` already had to be
/// threaded through both by hand; three more loose numbers is three more chances to thread one of
/// them into only one of the two. Passing the whole record means a new dimension is added in one
/// place and cannot be half-applied.
///
/// Every field is a *user* value with a default that reproduces what shipped before it existed, so
/// `IslandSizing.standard` is the geometry this app has always drawn.
public struct IslandSizing: Equatable, Sendable {

    /// How much a peek grows, as a multiple of `IslandLayout.peekWidthGrowth`/`peekHeightGrowth`.
    public var peekScale: Double

    /// Points added to the **collapsed** island's width, split evenly either side of the cutout.
    ///
    /// Collapsed only — rest and peek, flanked or not. The open island's width is deliberately
    /// untouched: `NowPlayingExpandedLayout`'s transport arithmetic is written against
    /// `IslandLayout.expandedBodySize.width` as a constant rather than against the body it is
    /// handed, so moving it would draw its rows outside the mask — where a button is visibly shaved
    /// *and* invisibly unhittable.
    ///
    /// Negative is allowed and is the direction that costs nothing on a real notch: the cutout is a
    /// hole, so an island narrower than it simply uncovers pixels that do not exist. Wider is the
    /// direction the user can see, because it is black paint on lit bezel either side of the notch.
    public var widthAdjustment: CGFloat

    /// Points added to the **collapsed** island's height, all of it below the cutout where there
    /// are lit pixels to show it in. Collapsed only, for `widthAdjustment`'s reason.
    public var heightAdjustment: CGFloat

    /// Whether the open island takes its compact height.
    ///
    /// See `IslandLayout.miniExpandedBodyHeight` for what "compact" is measured against and why it
    /// is a height and not also a width.
    public var compactIsland: Bool

    public init(
        peekScale: Double = 1,
        widthAdjustment: CGFloat = 0,
        heightAdjustment: CGFloat = 0,
        compactIsland: Bool = false
    ) {
        self.peekScale = peekScale
        self.widthAdjustment = widthAdjustment
        self.heightAdjustment = heightAdjustment
        self.compactIsland = compactIsland
    }

    /// The geometry Isleta drew before any of this was adjustable.
    public static let standard = IslandSizing()

    /// The adjustment as a size, rounded to whole points.
    ///
    /// Rounded here rather than at each call site, for `IslandLayout.peekGrowth(scale:)`'s reason:
    /// §6.6 asks for layout snapped to the pixel grid at 1x and 2x, and — more importantly — the
    /// drawn shape and the hit region are the same function of the same value, so they cannot
    /// disagree by a rounding step if the rounding happens once.
    var collapsedGrowth: CGSize {
        CGSize(width: widthAdjustment.rounded(), height: heightAdjustment.rounded())
    }
}
