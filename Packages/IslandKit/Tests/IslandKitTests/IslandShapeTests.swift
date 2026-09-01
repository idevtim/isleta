import CoreGraphics
import Testing

@testable import IslandKit

@Suite("Island shape")
struct IslandShapeTests {

    /// The island as it sits at rest in a real 14" MacBook Pro notch.
    private let rest = IslandShapeMetrics(
        bodySize: CGSize(width: 185, height: 32),
        topCornerRadius: 0,
        bottomCornerRadius: 8
    )

    @Test("the shape stays entirely inside its body")
    func boundingBox() {
        let bounds = IslandShapeGeometry.path(metrics: rest).boundingBoxOfPath
        #expect(abs(bounds.width - 185) < 1e-6)
        #expect(abs(bounds.height - 32) < 1e-6)
        #expect(abs(bounds.minX) < 1e-6)
        #expect(abs(bounds.minY) < 1e-6)
        #expect(IslandShapeGeometry.boundingSize(for: rest) == bounds.size)
    }

    /// Two probes pin down "convex". The first proves material is *removed* near the corner point,
    /// which rules out a square corner. The second proves material remains along the diagonal,
    /// which rules out the outward-flaring corner this shape used to have — that version left the
    /// diagonal empty and put material outside the body wall instead.
    @Test("bottom corners curve inward, following the notch cutout", arguments: [false, true])
    func convexBottomCorners(mirrored: Bool) {
        let path = IslandShapeGeometry.path(metrics: rest)
        let extent = IslandShapeGeometry.resolvedExtents(for: rest).bottom
        let wall: CGFloat = mirrored ? 185 : 0
        let inward: CGFloat = mirrored ? -1 : 1

        // Hard against the notional square corner: cut away.
        #expect(!path.contains(CGPoint(x: wall + inward * 0.02 * extent, y: 32 - 0.02 * extent)))
        // Along the diagonal, well inside the curve: still solid.
        #expect(path.contains(CGPoint(x: wall + inward * 0.6 * extent, y: 32 - 0.6 * extent)))
    }

    /// The island must never paint outside its own body. It used to, deliberately, and that is what
    /// made it read as pasted over the notch rather than as the notch itself.
    @Test("nothing is drawn outside the body")
    func nothingEscapesTheBody() {
        let path = IslandShapeGeometry.path(metrics: rest)
        for offset in [0.5, 2.0, 6.0, 12.0] as [CGFloat] {
            #expect(!path.contains(CGPoint(x: -offset, y: 32 - offset)), "material \(offset)pt left of the body")
            #expect(!path.contains(CGPoint(x: 185 + offset, y: 32 - offset)), "material \(offset)pt right of the body")
            #expect(!path.contains(CGPoint(x: 92.5, y: 32 + offset)), "material \(offset)pt below the body")
            #expect(!path.contains(CGPoint(x: 92.5, y: -offset)), "material \(offset)pt above the body")
        }
    }

    @Test("the top edge stays flush and square against the bezel")
    func topEdgeIsFlush() {
        let path = IslandShapeGeometry.path(metrics: rest)
        // At rest the top radius is zero, so the very corners are solid — no lit sliver between
        // island and bezel.
        #expect(path.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(path.contains(CGPoint(x: 184.5, y: 0.5)))
    }

    @Test("convex top corners remove material when a top radius is set")
    func convexTopCorners() {
        var metrics = rest
        metrics.topCornerRadius = 10
        let path = IslandShapeGeometry.path(metrics: metrics)
        let extent = IslandShapeGeometry.resolvedExtents(for: metrics).top

        #expect(!path.contains(CGPoint(x: 0.05 * extent, y: 0.05 * extent)))
        #expect(!path.contains(CGPoint(x: 185 - 0.05 * extent, y: 0.05 * extent)))
        #expect(path.contains(CGPoint(x: 92.5, y: 2)))
    }

    @Test("body interior and exterior")
    func containment() {
        let path = IslandShapeGeometry.path(metrics: rest)
        #expect(path.contains(CGPoint(x: 92.5, y: 16)))
        #expect(!path.contains(CGPoint(x: 92.5, y: -0.5)))
        #expect(!path.contains(CGPoint(x: 92.5, y: 32.5)))
        #expect(!path.contains(CGPoint(x: -40, y: 16)))
    }

    @Test("bodyOrigin translates the shape without reshaping it")
    func origin() {
        let base = IslandShapeGeometry.path(metrics: rest).boundingBoxOfPath
        let moved = IslandShapeGeometry.path(metrics: rest, bodyOrigin: CGPoint(x: 200, y: 0)).boundingBoxOfPath
        #expect(abs(moved.minX - (base.minX + 200)) < 1e-6)
        #expect(abs(moved.width - base.width) < 1e-6)
        #expect(abs(moved.height - base.height) < 1e-6)
    }

    /// §4.4 requires the shape to be well defined at any point along the spring, not just at its
    /// endpoints — every dimension has to travel together.
    @Test("interpolated metrics stay well formed across the whole morph",
          arguments: [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] as [CGFloat])
    func interpolation(progress: CGFloat) {
        let expanded = IslandShapeMetrics(
            bodySize: CGSize(width: 460, height: 160),
            topCornerRadius: 22,
            bottomCornerRadius: 22
        )
        let metrics = IslandShapeMetrics.lerp(from: rest, to: expanded, progress: progress)
        let bounds = IslandShapeGeometry.path(metrics: metrics).boundingBoxOfPath

        #expect(abs(bounds.width - metrics.bodySize.width) < 1e-6)
        #expect(abs(bounds.height - metrics.bodySize.height) < 1e-6)
        #expect(metrics.bodySize.width >= rest.bodySize.width)
        #expect(metrics.bodySize.width <= expanded.bodySize.width)
        #expect(metrics.bottomCornerRadius >= rest.bottomCornerRadius)
        #expect(metrics.bottomCornerRadius <= expanded.bottomCornerRadius)
    }

    /// We scale corners past Apple's clamp threshold instead of reshaping them toward a circular
    /// arc. That divergence is only acceptable while real geometry never reaches the threshold.
    @Test("real island geometry never enters the clamped regime")
    func clampingIsNotReachedInPractice() {
        for metrics in [rest, IslandShapeMetrics(bodySize: CGSize(width: 460, height: 160), topCornerRadius: 22, bottomCornerRadius: 22)] {
            let extents = IslandShapeGeometry.resolvedExtents(for: metrics)
            #expect(abs(extents.top - ContinuousCorner.extent(forRadius: metrics.topCornerRadius)) < 1e-9)
            #expect(abs(extents.bottom - ContinuousCorner.extent(forRadius: metrics.bottomCornerRadius)) < 1e-9)
        }
    }

    @Test("corners clamp rather than overlap when radii exceed the body")
    func clamping() {
        let metrics = IslandShapeMetrics(
            bodySize: CGSize(width: 40, height: 20),
            topCornerRadius: 30,
            bottomCornerRadius: 30
        )
        let extents = IslandShapeGeometry.resolvedExtents(for: metrics)
        #expect(extents.top <= 20 + 1e-9)
        #expect(extents.bottom <= 20 + 1e-9)
        #expect(extents.top + extents.bottom <= 20 + 1e-9)
        #expect(!IslandShapeGeometry.path(metrics: metrics).isEmpty)
    }

    @Test("degenerate metrics produce an empty path rather than a crash")
    func degenerate() {
        #expect(IslandShapeGeometry.path(metrics: IslandShapeMetrics(bodySize: .zero, topCornerRadius: 8, bottomCornerRadius: 8)).isEmpty)
        #expect(IslandShapeGeometry.path(metrics: IslandShapeMetrics(bodySize: CGSize(width: -10, height: -10), topCornerRadius: 0, bottomCornerRadius: 0)).isEmpty)
    }
}
