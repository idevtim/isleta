import CoreGraphics

/// Apple's continuous ("squircle") corner, reproduced exactly.
///
/// The control points below were not derived from a formula or copied from a blog post — they were
/// extracted at runtime from SwiftUI's own output on the macOS 26.5 SDK by dumping the elements of
/// `RoundedRectangle(cornerRadius:style: .continuous).path(in:)` and normalizing by the radius. The
/// values are stable to nine decimal places across radii of 20, 137 and 1000pt, which is what makes
/// them safe to treat as constants rather than as a fit. `ContinuousCornerTests` re-derives them
/// from SwiftUI on every test run, so an SDK change that moves them fails the build rather than
/// quietly detuning the shape.
///
/// A continuous corner is three cubic Bézier segments spanning `extentRatio * radius` along each of
/// the two edges that meet at the corner — noticeably further than a circular corner's `radius`.
/// That long, gradual blend into the straight edges is the whole point: curvature is continuous
/// across the join instead of stepping from zero to `1/radius`.
///
/// Corners are described in a local frame so convex and concave corners share one code path.
/// `corner` is the point the two straight edges would meet at if extended, `axisIn` is the unit
/// vector pointing from that corner back along the incoming edge, and `axisOut` points along the
/// outgoing edge. Whether the corner reads as convex or concave is decided purely by how the caller
/// stitches it into the surrounding path — the curve itself is identical, and always bulges
/// *towards* `corner`.
public enum ContinuousCorner {

    /// How far the corner extends along each edge, as a multiple of the nominal corner radius.
    public static let extentRatio: CGFloat = 1.528664947

    // Segment control points, as (major, minor) multiples of the radius in the (axisIn, axisOut)
    // frame. The corner is symmetric about the diagonal, so segment 3 is segment 1 mirrored.
    static let s1c1: CGFloat = 1.088490009
    static let s1c2: CGFloat = 0.868407011
    static let midMajor: CGFloat = 0.631493986
    static let midMinor: CGFloat = 0.074911401
    static let s2Major: CGFloat = 0.372824013
    static let s2Minor: CGFloat = 0.169060007

    /// The extent a corner of the given radius wants to occupy along each of its edges.
    public static func extent(forRadius radius: CGFloat) -> CGFloat {
        max(0, radius) * extentRatio
    }

    /// The nominal radius that produces the given extent. Inverse of `extent(forRadius:)`.
    public static func radius(forExtent extent: CGFloat) -> CGFloat {
        max(0, extent) / extentRatio
    }

    /// Appends the three cubic segments of a continuous corner.
    ///
    /// The caller must have already positioned the current point at `corner + extent * axisIn`;
    /// on return the current point is `corner + extent * axisOut`.
    ///
    /// - Parameters:
    ///   - path: Path to append to. Must have a current point.
    ///   - corner: The virtual intersection of the two edges.
    ///   - axisIn: Unit vector from `corner` along the incoming edge.
    ///   - axisOut: Unit vector from `corner` along the outgoing edge.
    ///   - extent: Distance along each edge the corner occupies, i.e. `extentRatio * radius`.
    public static func append(
        to path: CGMutablePath,
        corner: CGPoint,
        axisIn: CGVector,
        axisOut: CGVector,
        extent: CGFloat
    ) {
        guard extent > 0 else {
            path.addLine(to: corner)
            return
        }
        // Constants are expressed per unit radius; convert once to per unit extent.
        let r = extent / extentRatio
        func point(_ major: CGFloat, _ minor: CGFloat) -> CGPoint {
            CGPoint(
                x: corner.x + r * (major * axisIn.dx + minor * axisOut.dx),
                y: corner.y + r * (major * axisIn.dy + minor * axisOut.dy)
            )
        }

        path.addCurve(to: point(midMajor, midMinor), control1: point(s1c1, 0), control2: point(s1c2, 0))
        path.addCurve(to: point(midMinor, midMajor), control1: point(s2Major, s2Minor), control2: point(s2Minor, s2Major))
        path.addCurve(to: point(0, extentRatio), control1: point(0, s1c2), control2: point(0, s1c1))
    }
}
