import IslandKit
import SwiftUI

/// The island outline as a SwiftUI `Shape`.
///
/// A thin wrapper over `IslandShapeGeometry` — deliberately thin, because `IslandHitTestView` uses
/// the same builder for hit testing. If this view ever grew its own path logic, the visible shape
/// and the clickable region would drift apart the moment either changed.
///
/// `animatableData` carries width, height and both corner radii in a single value. That is what
/// enforces §6.1's "all on the same spring" at the type level: there is no way to drive the corner
/// radius from a different animation than the width, because SwiftUI only ever interpolates one
/// `animatableData` per shape.
public struct IslandShape: Shape {

    public var metrics: IslandShapeMetrics

    /// Where the body's top-left corner sits inside the rect. Defaults to top-centerd.
    public var bodyOrigin: CGPoint?

    /// How far **one** edge is leaning past where the island rests, in points.
    ///
    /// The rebound at the end of a range (`IslandScreenModel.limitLean`), and it is a *magnitude*:
    /// which edge moves is `leansTrailing`, which does not animate. Zero at rest, and zero is the
    /// island's settled outline exactly.
    ///
    /// **A property of the shape rather than an offset on the view, and that is the whole fix.**
    /// The first version grew `bodySize.width` by the travel and shifted the drawn island by half
    /// of it with `.offset`, on the arithmetic that the two cancel at the fixed edge. They cancel
    /// at the *endpoints*; in between they are two animatable channels, and SwiftUI gives a
    /// retargeted spring the velocity the old one had. A lean requested while the island is still
    /// widening into a HUD therefore hands the shape's width some of `Motion.widen`'s velocity and
    /// the offset none of it — so the halves stop matching, and the edge that is supposed to be
    /// nailed down drifts and settles back. Reported from hardware three times, 2026-08-29, as the
    /// other end bouncing when it should not.
    ///
    /// Here there is one number. `path(in:)` derives both the growth and the origin from the same
    /// interpolated value, so the fixed edge is fixed at **every** frame rather than at the two
    /// ends — and it is clamped at zero, so the overshoot of a bouncy spring can never lean the
    /// island the other way.
    public var lean: CGFloat

    /// Which edge `lean` moves: the trailing one at the top of a range, the leading one at the
    /// bottom. **Not animated**, and that is deliberate — it is a fact about which key was pressed,
    /// not a value in flight, and interpolating it would sweep the lean across the island.
    public var leansTrailing: Bool

    public init(
        metrics: IslandShapeMetrics,
        bodyOrigin: CGPoint? = nil,
        lean: CGFloat = 0,
        leansTrailing: Bool = true
    ) {
        self.metrics = metrics
        self.bodyOrigin = bodyOrigin
        self.lean = lean
        self.leansTrailing = leansTrailing
    }

    public func path(in rect: CGRect) -> Path {
        // Clamped, because `Motion.rebound` is deliberately underdamped and an interpolation that
        // undershoots zero would grow the island on the side that is holding still.
        let lean = max(0, self.lean)
        var leaned = metrics
        leaned.bodySize.width += lean
        // The **resting** metrics, so the origin is where the island sits with no lean in it; the
        // leading edge then stays there and the trailing one grows away from it, or the other way
        // round. Both come off the one clamped number above.
        let origin = bodyOrigin ?? IslandLayout.bodyOrigin(for: metrics, in: rect.size)
        return Path(
            IslandShapeGeometry.path(
                metrics: leaned,
                bodyOrigin: CGPoint(
                    x: rect.minX + origin.x - (leansTrailing ? 0 : lean),
                    y: rect.minY + origin.y
                )
            )
        )
    }

    /// Carries width, height, all three radii **and the lean** in a single value.
    ///
    /// That is what enforces §6.1's "all on the same spring" at the type level: SwiftUI interpolates
    /// exactly one `animatableData` per shape, so there is no way to drive the corner flare from a
    /// different animation than the width. Nested pairs because `AnimatablePair` takes two — ugly,
    /// and the ugliness is the point, since the alternative is six properties that can drift apart.
    ///
    /// The lean is in here for that reason and not as a convenience: it used to be an `.offset` on
    /// the view *outside* this shape, which is a second channel, and two channels under one spring
    /// are still two springs the moment either is retargeted mid-flight. See `lean`.
    public var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(metrics.bodySize.width, metrics.bodySize.height),
                AnimatablePair(
                    AnimatablePair(metrics.topCornerRadius, metrics.bottomCornerRadius),
                    AnimatablePair(metrics.topFlareRadius, lean)
                )
            )
        }
        set {
            metrics.bodySize = CGSize(width: newValue.first.first, height: newValue.first.second)
            metrics.topCornerRadius = newValue.second.first.first
            metrics.bottomCornerRadius = newValue.second.first.second
            metrics.topFlareRadius = newValue.second.second.first
            lean = newValue.second.second.second
        }
    }
}
