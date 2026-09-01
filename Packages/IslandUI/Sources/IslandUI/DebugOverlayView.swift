import IslandKit
import SwiftUI

/// The ⌥⌘D overlay (§4.4).
///
/// Draws the shape outline and the hit-test region as two *separately computed* layers even though
/// Milestone 0 derives both from the same metrics. The whole point of the overlay is to catch the
/// moment they stop agreeing — once the shape animates, the hit region has to track the shape
/// mid-flight, and a drift of a few points is invisible without something like this.
///
/// The overlay draws outside the island outline, over panel area that is otherwise fully
/// transparent. Those pixels stop being click-through while it is visible; that is a deliberate
/// property of a debug tool, not of the shipping island.
///
/// ## Do not add `.allowsHitTesting(false)` here
///
/// It reads as the obviously correct modifier for a read-only overlay, and it breaks the window.
/// `NSHostingView` reports SwiftUI's hit-testing regions up to the window server as the window's
/// event shape. A view that covers the whole panel and declines hit testing collapses that shape to
/// nothing — for the *entire window*, including the island drawn by a sibling view. The panel then
/// passes every click through, and because nothing about the rendering changes, it looks perfect.
///
/// The overlay does not need it in any case: `IslandHitTestView` already rejects everything outside
/// the island outline before AppKit ever descends into this view.
struct DebugOverlayView: View {

    let info: IslandDebugInfo
    let diagnostics: Diagnostics
    /// The form, not just the presentation: whether the island is flanked is the difference between
    /// a 185pt body and a 265pt one at the same "rest", and on hardware the two are easy to mix up
    /// at a glance because both are black against a black bezel.
    let form: IslandForm

    private static let shapeColor = Color(.sRGB, red: 0.29, green: 0.90, blue: 1.0, opacity: 1)
    private static let hitColor = Color(.sRGB, red: 1.0, green: 0.30, blue: 0.55, opacity: 1)

    var body: some View {
        ZStack(alignment: .top) {
            regions
            readout
                .padding(.top, info.metrics.bodySize.height + 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var regions: some View {
        GeometryReader { proxy in
            let shape = IslandShape(metrics: info.metrics, bodyOrigin: info.bodyOrigin)

            ZStack(alignment: .topLeading) {
                // Panel bounds — the fixed rectangle that never animates (§4.2).
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.25))

                // Hit-test region: filled, so any area that would swallow a click is obvious.
                shape.fill(Self.hitColor.opacity(0.18))

                // Shape outline.
                shape.stroke(Self.shapeColor, lineWidth: 1)

                // Body rect, to show where the flare extends beyond it.
                Rectangle()
                    .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: info.metrics.bodySize.width, height: info.metrics.bodySize.height)
                    .offset(x: info.bodyOrigin.x, y: info.bodyOrigin.y)

                // Tracking areas — none until §5 lands, and the overlay says so rather than
                // drawing an empty box that could be mistaken for a correct one.
                ForEach(Array(info.trackingAreas.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .stroke(.yellow, lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 1) {
            row("screen", "\(info.screen.name)  id \(info.screen.id)  @\(fmt(info.screen.backingScaleFactor))x")
            row("notch", "\(info.screen.notch.kind == .hardware ? "hardware" : "synthesized")  \(fmt(info.screen.notch.rect))")
            row("panel", "\(fmt(info.panelFrame))  window #\(info.windowNumber)")
            row("body", "\(fmt(info.metrics.bodySize.width)) x \(fmt(info.metrics.bodySize.height))  at \(fmt(info.bodyOrigin))")
            row("radii", "top \(fmt(info.metrics.topCornerRadius)) -> extent \(fmt(info.cornerExtents.x))   bottom \(fmt(info.metrics.bottomCornerRadius)) -> extent \(fmt(info.cornerExtents.y))")
            row("shape", "bounds \(fmt(info.shapeBounds))")
            row("hit region", "identical to shape (single source: IslandShapeGeometry)")
            row("tracking", info.trackingAreas.isEmpty
                ? "none"
                : info.trackingAreas.map { fmt($0) }.joined(separator: "  "))
            row("hover", info.isHovering ? "pointer is on the island" : "pointer is elsewhere")
            row("state", "\(label(for: form))  — hit region follows this once settled")

            Divider().frame(width: 320).padding(.vertical, 3)

            row("launch", diagnostics.launchSeconds.map { "\(fmt($0 * 1000)) ms  (budget 300)" } ?? "—")
            row("idle cpu", diagnostics.idleCPUPercent.map { String(format: "%.3f %%  (budget 0.3)", $0) } ?? "sampling…")
            row("memory", diagnostics.memoryBytes.map { String(format: "%.1f MB  (budget 60)", Double($0) / 1_048_576) } ?? "—")
            row("pass-through", diagnostics.passThrough ?? "—")
            row("probe", diagnostics.probe ?? "⌥⌘P at any pointer location")
            row("haptics", diagnostics.haptics ?? "—")
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Self.shapeColor.opacity(0.35), lineWidth: 1)
        )
        .fixedSize()
    }

    private func label(for form: IslandForm) -> String {
        let base = switch form.presentation {
        case .rest: "rest"
        case .peek: "peek"
        case .expanded: "expanded"
        }
        switch form.flanks {
        case .none: return base
        case .standard: return "flanked \(base)"
        case .wide: return "wide flanked \(base)"
        case .wider: return "wider flanked \(base)"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(Self.shapeColor)
                .frame(width: 78, alignment: .trailing)
            Text(value)
        }
    }

    private func fmt(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
    private func fmt(_ point: CGPoint) -> String { "(\(fmt(point.x)), \(fmt(point.y)))" }
    private func fmt(_ rect: CGRect) -> String {
        "(\(fmt(rect.minX)), \(fmt(rect.minY)), \(fmt(rect.width)), \(fmt(rect.height)))"
    }
}
