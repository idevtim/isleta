import CoreGraphics

/// The dimensions that fully determine the island outline.
public struct IslandShapeMetrics: Equatable, Sendable {

    /// The island's rectangle. Unlike an earlier design with outward-flaring corners, the shape now
    /// stays entirely inside this — its bounding box and its body are the same thing.
    public var bodySize: CGSize

    /// Nominal radius of the two corners along the top edge, where the island meets the bezel.
    /// Nominal in the Apple sense: the corner actually occupies `1.528665 * radius`.
    public var topCornerRadius: CGFloat

    /// Nominal radius of the two bottom corners.
    ///
    /// These curve *inward*, the same way the physical notch's own bottom corners do, so the island
    /// reads as a continuation of the cutout. An earlier version flared them outward to look
    /// "carved"; in practice that put two points on the bottom of the island and read as a shape
    /// pasted over the notch rather than the notch itself growing.
    public var bottomCornerRadius: CGFloat

    /// Nominal radius of the **concave flare** where the island's top corners meet the top edge of
    /// the screen.
    ///
    /// Zero everywhere except the open island. At rest the top edge is flush against the bezel and
    /// there is nothing to curve into; open, the island hangs far enough below the ceiling that a
    /// square top corner reads as a panel stuck on rather than as something the screen edge grew.
    /// The curve is the bottom corners' own, reversed — which is why it takes a radius in the same
    /// units rather than a bespoke one.
    ///
    /// It is the one dimension that paints **outside** `bodySize`: the flare widens the shape by its
    /// extent at each side, at the very top only. `boundingSize` accounts for that, and because
    /// `IslandHitTestView` builds its region from this same path, the widened top is clickable
    /// exactly where it is drawn.
    public var topFlareRadius: CGFloat

    public init(
        bodySize: CGSize,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        topFlareRadius: CGFloat = 0
    ) {
        self.bodySize = bodySize
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topFlareRadius = topFlareRadius
    }

    /// The smallest shape in this family that contains both — and therefore every shape on the
    /// straight line between them, which is what `lerp` walks.
    ///
    /// This is the hit region a transition is widened to. The argument that it is a superset is
    /// short and worth having in one place: `lerp` is componentwise, so every intermediate has a
    /// width and a height between the two endpoints' and a radius between the two endpoints'. Width
    /// and height are taken as the **max**, so no intermediate is wider or taller. Both radii are
    /// taken as the **min**, because a corner radius only ever *removes* area from the body
    /// rectangle — the least-rounded corner is the one that keeps the most.
    ///
    /// Taking the max radius is the tempting mistake, on the reasoning that "larger is safer": it
    /// is not, it carves the corners further in and produces a region that is a *subset* of one
    /// endpoint around the corners. Subsets are the dangerous direction — clicks land on visible
    /// island pixels, reach us, and get dropped (see `IslandHitTestView`).
    ///
    /// The older "whichever endpoint is taller" rule was correct only while the island's states
    /// were totally ordered by size. Flanked rest is *wider* than unflanked peek and *shorter* than
    /// it, so no endpoint contains the other and the rule silently picked a subset.
    public static func union(_ a: Self, _ b: Self) -> Self {
        Self(
            bodySize: CGSize(
                width: max(a.bodySize.width, b.bodySize.width),
                height: max(a.bodySize.height, b.bodySize.height)
            ),
            topCornerRadius: min(a.topCornerRadius, b.topCornerRadius),
            bottomCornerRadius: min(a.bottomCornerRadius, b.bottomCornerRadius),
            // **max**, where the radii take min. A radius only removes area from the body, so the
            // least-rounded corner covers the most; the flare only *adds* area outside it, so the
            // largest flare is the one that covers both. Taking min here would carve the widened
            // top out of the widened region and reintroduce exactly the subset bug this exists to
            // prevent — a click on a drawn flare that reaches us and gets dropped.
            topFlareRadius: max(a.topFlareRadius, b.topFlareRadius)
        )
    }

    /// Linear interpolation across every dimension at once.
    ///
    /// Width, height and both radii must travel on a single spring (§6.1); interpolating them
    /// together here makes it impossible to accidentally drive them from separate animations.
    public static func lerp(from a: Self, to b: Self, progress t: CGFloat) -> Self {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return Self(
            bodySize: CGSize(
                width: mix(a.bodySize.width, b.bodySize.width),
                height: mix(a.bodySize.height, b.bodySize.height)
            ),
            topCornerRadius: mix(a.topCornerRadius, b.topCornerRadius),
            bottomCornerRadius: mix(a.bottomCornerRadius, b.bottomCornerRadius),
            topFlareRadius: mix(a.topFlareRadius, b.topFlareRadius)
        )
    }
}

/// Builds the island outline as a `CGPath`.
///
/// This lives in IslandKit rather than IslandUI because hit testing needs the exact same path the
/// renderer uses (§4.2) — a click 2pt outside the visible pill must reach the app underneath, and
/// that is only true if there is precisely one definition of "the shape". IslandUI wraps this in a
/// SwiftUI `Shape`; `IslandHitTestView` calls it directly.
///
/// Every corner is a continuous (squircle) curve, never circular — see `ContinuousCorner`, which
/// also still supports concave corners should a future state want one.
///
/// **Coordinate space:** y-down, matching SwiftUI and flipped `NSView`s. The island hangs from
/// `bodyOrigin`, which is its top-left corner.
public enum IslandShapeGeometry {

    /// The corner extents actually used after clamping, in points along each edge.
    ///
    /// Corners are clamped so that two corners fit across the width and so the top and bottom
    /// corners do not overlap along the side edges. Past its own clamp threshold Apple stops
    /// scaling a continuous corner and reshapes it toward a circular arc; we scale instead, which
    /// diverges from Apple only in a regime real island geometry never enters (a 185x32pt notch
    /// with radii under ~10pt sits far inside the linear range). `IslandShapeTests` asserts that.
    public static func resolvedExtents(for metrics: IslandShapeMetrics) -> (top: CGFloat, bottom: CGFloat) {
        let w = max(0, metrics.bodySize.width)
        let h = max(0, metrics.bodySize.height)

        var top = min(ContinuousCorner.extent(forRadius: metrics.topCornerRadius), w / 2)
        var bottom = min(ContinuousCorner.extent(forRadius: metrics.bottomCornerRadius), w / 2)

        // Both corners consume height along the same side edge.
        let totalVertical = top + bottom
        if totalVertical > h, totalVertical > 0 {
            let scale = h / totalVertical
            top *= scale
            bottom *= scale
        }
        return (top, bottom)
    }

    /// The bounding box of the shape. Now simply the body — nothing extends beyond it.
    public static func boundingSize(for metrics: IslandShapeMetrics) -> CGSize {
        // The flare is the one thing that reaches past the body, and only sideways at the top.
        CGSize(
            width: max(0, metrics.bodySize.width) + flareExtent(for: metrics) * 2,
            height: max(0, metrics.bodySize.height)
        )
    }

    /// The flare's reach along the top edge, clamped so two flares plus two top corners cannot ask
    /// for more width than the island has.
    public static func flareExtent(for metrics: IslandShapeMetrics) -> CGFloat {
        guard metrics.topFlareRadius > 0 else { return 0 }
        let w = max(0, metrics.bodySize.width)
        let h = max(0, metrics.bodySize.height)
        // Never taller than the body: a flare deeper than the island would fold the side edge back
        // on itself and produce a self-intersecting path, which hit-tests unpredictably.
        return min(ContinuousCorner.extent(forRadius: metrics.topFlareRadius), w / 4, h / 2)
    }

    /// The island outline, traversed clockwise in a y-down space.
    ///
    /// - Parameter bodyOrigin: Top-left corner of the body.
    public static func path(metrics: IslandShapeMetrics, bodyOrigin: CGPoint = .zero) -> CGPath {
        let w = max(0, metrics.bodySize.width)
        let h = max(0, metrics.bodySize.height)
        let path = CGMutablePath()
        guard w > 0, h > 0 else { return path }

        let (et, eb) = resolvedExtents(for: metrics)
        let x0 = bodyOrigin.x
        let x1 = bodyOrigin.x + w
        let yTop = bodyOrigin.y
        let yBottom = bodyOrigin.y + h

        let left = CGVector(dx: -1, dy: 0)
        let right = CGVector(dx: 1, dy: 0)
        let up = CGVector(dx: 0, dy: -1)
        let down = CGVector(dx: 0, dy: 1)

        let ef = flareExtent(for: metrics)

        // Start partway down the left edge and travel clockwise.
        path.move(to: CGPoint(x: x0, y: yTop + max(et, ef)))

        if ef > 0 {
            // The top corners curve *outward* into the ceiling — the bottom corners' curve,
            // reversed. Same `ContinuousCorner`, and concavity is decided purely by which way the
            // two axes point away from the corner: `down` then `left` sweeps away from the body
            // where `down` then `right` would sweep into it.
            ContinuousCorner.append(
                to: path, corner: CGPoint(x: x0, y: yTop),
                axisIn: down, axisOut: left, extent: ef
            )
            path.addLine(to: CGPoint(x: x1 + ef, y: yTop))
            ContinuousCorner.append(
                to: path, corner: CGPoint(x: x1, y: yTop),
                axisIn: right, axisOut: down, extent: ef
            )
        } else {
            ContinuousCorner.append(
                to: path, corner: CGPoint(x: x0, y: yTop),
                axisIn: down, axisOut: right, extent: et
            )
            path.addLine(to: CGPoint(x: x1 - et, y: yTop))
            ContinuousCorner.append(
                to: path, corner: CGPoint(x: x1, y: yTop),
                axisIn: left, axisOut: down, extent: et
            )
        }
        path.addLine(to: CGPoint(x: x1, y: yBottom - eb))

        ContinuousCorner.append(
            to: path, corner: CGPoint(x: x1, y: yBottom),
            axisIn: up, axisOut: left, extent: eb
        )
        path.addLine(to: CGPoint(x: x0 + eb, y: yBottom))

        ContinuousCorner.append(
            to: path, corner: CGPoint(x: x0, y: yBottom),
            axisIn: right, axisOut: up, extent: eb
        )

        path.closeSubpath()
        return path
    }
}
