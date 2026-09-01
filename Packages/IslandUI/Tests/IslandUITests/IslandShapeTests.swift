import CoreGraphics
import IslandKit
import SwiftUI
import Testing

@testable import IslandUI

@Suite("IslandShape")
struct IslandShapeViewTests {

    private let metrics = IslandShapeMetrics(
        bodySize: CGSize(width: 185, height: 32),
        topCornerRadius: 0,
        bottomCornerRadius: 8
    )

    /// The claim that hit testing and rendering share one definition of the shape is only true if
    /// this wrapper adds nothing of its own. Verified by containment rather than by path equality,
    /// because `Path` round-trips through `CGPath` and may renormalize element order.
    @Test("the SwiftUI shape covers exactly what IslandShapeGeometry produces")
    func agreesWithGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 200)
        let origin = IslandLayout.bodyOrigin(for: metrics, in: rect.size)
        let reference = IslandShapeGeometry.path(metrics: metrics, bodyOrigin: origin)
        let rendered = IslandShape(metrics: metrics).path(in: rect).cgPath

        var disagreements = 0
        for xStep in 0...200 {
            for yStep in 0...80 {
                let point = CGPoint(x: CGFloat(xStep) * 3, y: CGFloat(yStep) * 2.5)
                if reference.contains(point) != rendered.contains(point) { disagreements += 1 }
            }
        }
        #expect(disagreements == 0)
    }

    @Test("an explicit bodyOrigin is honored and offset by the rect")
    func explicitOrigin() {
        let rect = CGRect(x: 40, y: 10, width: 600, height: 200)
        let path = IslandShape(metrics: metrics, bodyOrigin: CGPoint(x: 5, y: 0)).path(in: rect).cgPath
        #expect(abs(path.boundingBoxOfPath.minX - (40 + 5)) < 1e-6)
        #expect(abs(path.boundingBoxOfPath.minY - 10) < 1e-6)
    }

    /// §6.1: width, height and both radii must ride a single spring. They do so here because they
    /// share one `animatableData`; this pins that down so a future refactor cannot split them.
    @Test("animatableData carries every dimension and round-trips")
    func animatableDataRoundTrip() {
        var shape = IslandShape(metrics: metrics)
        let expanded = IslandShapeMetrics(
            bodySize: CGSize(width: 460, height: 160),
            topCornerRadius: 22,
            bottomCornerRadius: 14
        )
        shape.animatableData = IslandShape(metrics: expanded).animatableData
        #expect(shape.metrics == expanded)

        // Halfway through the interpolation every dimension must have moved, not just the size.
        var midpoint = IslandShape(metrics: metrics)
        var data = midpoint.animatableData
        data.interpolate(towards: IslandShape(metrics: expanded).animatableData, amount: 0.5)
        midpoint.animatableData = data
        #expect(midpoint.metrics == IslandShapeMetrics.lerp(from: metrics, to: expanded, progress: 0.5))

        // The lean rides the same value, which is the whole reason it is a property of the shape
        // rather than an `.offset` on the view outside it. See `IslandShape.lean`.
        var leaning = IslandShape(metrics: metrics)
        leaning.animatableData = IslandShape(metrics: metrics, lean: 16).animatableData
        #expect(leaning.lean == 16)
    }

    /// **The invariant three hardware reports were about**, stated where it can actually be
    /// checked: not on the model's value, which only ever holds the two endpoints, but on the
    /// geometry the spring draws in between.
    ///
    /// A lean grows one edge and nails the other down at *every* value the spring can hand it —
    /// including the negative ones an underdamped return passes through, where the island simply
    /// rests rather than leaning the other way.
    @Test("a lean moves one edge and never the other", arguments: [true, false])
    func leanMovesOneEdge(leansTrailing: Bool) {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 200)
        let rest = IslandShape(metrics: metrics).path(in: rect).cgPath.boundingBoxOfPath

        for step in -16...48 {
            let lean = CGFloat(step) / 2
            let box = IslandShape(metrics: metrics, lean: lean, leansTrailing: leansTrailing)
                .path(in: rect).cgPath.boundingBoxOfPath
            let fixed = leansTrailing ? box.minX : box.maxX
            let atRest = leansTrailing ? rest.minX : rest.maxX
            #expect(abs(fixed - atRest) < 1e-6, "the fixed edge moved at lean \(lean)")

            let travel = leansTrailing ? box.maxX - rest.maxX : rest.minX - box.minX
            #expect(abs(travel - max(0, lean)) < 1e-6, "the leaning edge is wrong at lean \(lean)")
        }
    }
}

// Main-actor since `Motion.speed`, for the reason recorded on that property.
@MainActor
@Suite("Motion tokens")
struct MotionTests {

    @Test("reduce motion substitutes a crossfade for every morph")
    func reduceMotion() {
        #expect(Motion.respectingReduceMotion(Motion.expand, reduceMotion: true) == Motion.contentSwap)
        #expect(Motion.respectingReduceMotion(Motion.collapse, reduceMotion: true) == Motion.contentSwap)
        #expect(Motion.respectingReduceMotion(Motion.expand, reduceMotion: false) == Motion.expand)
    }

    @Test("content lags the container so the morph reads as one object")
    func contentFollowsContainer() {
        #expect(Motion.contentFollowDelay == .milliseconds(40))
    }
}

