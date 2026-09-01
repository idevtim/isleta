import CoreGraphics
import SwiftUI
import Testing

@testable import IslandKit

/// These tests exist because `ContinuousCorner`'s constants are *measured*, not derived. If a future
/// SDK retunes SwiftUI's continuous corner, every island on screen would silently stop matching the
/// system's own curvature. Re-deriving the constants from SwiftUI on every test run turns that into
/// a build failure instead.
@Suite("Continuous corner")
struct ContinuousCornerTests {

    /// Pulls the top-left corner out of a continuous rounded rect, in the (axisIn, axisOut) frame
    /// `ContinuousCorner` uses: axisIn runs down the left edge, axisOut runs along the top edge.
    private func swiftUICorner(radius: CGFloat, side: CGFloat) -> [(major: CGFloat, minor: CGFloat)]? {
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: side, height: side))
        var elements: [Path.Element] = []
        path.forEach { elements.append($0) }

        // The traversal reaches the top-left corner via a line down the left edge to (0, extent).
        guard let index = elements.firstIndex(where: {
            guard case .line(let to) = $0 else { return false }
            return abs(to.x) < 1e-9 && to.y > 0 && to.y < side / 2
        }), case .line(let start) = elements[index], elements.count > index + 3 else { return nil }

        var points: [(CGFloat, CGFloat)] = [(start.y / radius, start.x / radius)]
        for offset in 1...3 {
            guard case .curve(let to, let c1, let c2) = elements[index + offset] else { return nil }
            points.append((c1.y / radius, c1.x / radius))
            points.append((c2.y / radius, c2.x / radius))
            points.append((to.y / radius, to.x / radius))
        }
        return points
    }

    @Test("constants still match SwiftUI's own continuous corner on this SDK",
          arguments: [(20.0, 400.0), (137.0, 2000.0), (1000.0, 40000.0)] as [(CGFloat, CGFloat)])
    func matchesSwiftUI(radius: CGFloat, side: CGFloat) throws {
        let measured = try #require(swiftUICorner(radius: radius, side: side))
        let expected: [(CGFloat, CGFloat)] = [
            (ContinuousCorner.extentRatio, 0),
            (ContinuousCorner.s1c1, 0),
            (ContinuousCorner.s1c2, 0),
            (ContinuousCorner.midMajor, ContinuousCorner.midMinor),
            (ContinuousCorner.s2Major, ContinuousCorner.s2Minor),
            (ContinuousCorner.s2Minor, ContinuousCorner.s2Major),
            (ContinuousCorner.midMinor, ContinuousCorner.midMajor),
            (0, ContinuousCorner.s1c2),
            (0, ContinuousCorner.s1c1),
            (0, ContinuousCorner.extentRatio),
        ]
        #expect(measured.count == expected.count)
        for (index, pair) in zip(measured, expected).enumerated() {
            #expect(abs(pair.0.major - pair.1.0) < 1e-6, "major mismatch at \(index)")
            #expect(abs(pair.0.minor - pair.1.1) < 1e-6, "minor mismatch at \(index)")
        }
    }

    /// End-to-end: a rounded rectangle built entirely from `ContinuousCorner.append` must cover the
    /// same points as SwiftUI's. This catches frame/axis mistakes that the constant comparison,
    /// which only looks at one corner, would miss.
    @Test("a rect built from our corners matches SwiftUI's continuous rounded rect")
    func roundedRectMatchesSwiftUI() {
        let side: CGFloat = 200
        let radius: CGFloat = 28
        let extent = ContinuousCorner.extent(forRadius: radius)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)

        let ours = CGMutablePath()
        let left = CGVector(dx: -1, dy: 0), right = CGVector(dx: 1, dy: 0)
        let up = CGVector(dx: 0, dy: -1), down = CGVector(dx: 0, dy: 1)
        ours.move(to: CGPoint(x: 0, y: rect.maxY - extent))
        ContinuousCorner.append(to: ours, corner: CGPoint(x: 0, y: rect.maxY), axisIn: up, axisOut: right, extent: extent)
        ours.addLine(to: CGPoint(x: rect.maxX - extent, y: rect.maxY))
        ContinuousCorner.append(to: ours, corner: CGPoint(x: rect.maxX, y: rect.maxY), axisIn: left, axisOut: up, extent: extent)
        ours.addLine(to: CGPoint(x: rect.maxX, y: extent))
        ContinuousCorner.append(to: ours, corner: CGPoint(x: rect.maxX, y: 0), axisIn: down, axisOut: left, extent: extent)
        ours.addLine(to: CGPoint(x: extent, y: 0))
        ContinuousCorner.append(to: ours, corner: .zero, axisIn: right, axisOut: down, extent: extent)
        ours.closeSubpath()

        let theirs = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath

        var disagreements = 0
        for xStep in 0...100 {
            for yStep in 0...100 {
                let point = CGPoint(x: CGFloat(xStep) * side / 100, y: CGFloat(yStep) * side / 100)
                if ours.contains(point) != theirs.contains(point) { disagreements += 1 }
            }
        }
        // Points landing exactly on the boundary can round either way; anything beyond a handful
        // means the curve itself differs.
        #expect(disagreements <= 4, "\(disagreements) sampled points disagreed with SwiftUI")
    }

    @Test("extent and radius are inverses")
    func extentRoundTrip() {
        let radius: CGFloat = 12.5
        #expect(abs(ContinuousCorner.radius(forExtent: ContinuousCorner.extent(forRadius: radius)) - radius) < 1e-9)
        #expect(ContinuousCorner.extent(forRadius: -5) == 0)
    }
}
