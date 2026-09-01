import CoreGraphics
import Testing

@testable import IslandKit

/// The fixtures below are real values captured from the development machine (a 14" MacBook Pro
/// driving two 1920x1080 externals) by dumping `NSScreen` at runtime, not invented numbers.
@Suite("Notch geometry")
struct NotchGeometryTests {

    private enum Fixture {
        static let builtInFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        static let builtInSafeAreaTop: CGFloat = 32
        static let builtInAuxLeft = CGRect(x: 0, y: 1085, width: 771.5, height: 32)
        static let builtInAuxRight = CGRect(x: 956.5, y: 1085, width: 771.5, height: 32)

        static let externalLeftFrame = CGRect(x: -2001, y: 1117, width: 1920, height: 1080)
        static let externalRightFrame = CGRect(x: -81, y: 1117, width: 1920, height: 1080)
    }

    @Test("a real notch resolves to the gap between the auxiliary areas")
    func hardwareNotch() {
        let notch = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame,
            safeAreaTop: Fixture.builtInSafeAreaTop,
            auxiliaryTopLeft: Fixture.builtInAuxLeft,
            auxiliaryTopRight: Fixture.builtInAuxRight
        )
        #expect(notch.kind == .hardware)
        #expect(notch.rect == CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        #expect(notch.rect.maxY == Fixture.builtInFrame.maxY)   // flush with the top of the screen
    }

    /// §4.3 specifies width as `screenWidth - (auxLeft.width + auxRight.width)`. We measure the gap
    /// instead, which also yields the x position. They must agree on real hardware.
    @Test("the gap measurement agrees with the specified subtraction formula")
    func formulaEquivalence() {
        let specified = Fixture.builtInFrame.width - (Fixture.builtInAuxLeft.width + Fixture.builtInAuxRight.width)
        let measured = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame,
            safeAreaTop: Fixture.builtInSafeAreaTop,
            auxiliaryTopLeft: Fixture.builtInAuxLeft,
            auxiliaryTopRight: Fixture.builtInAuxRight
        ).rect.width
        #expect(abs(specified - measured) < 1e-9)
        #expect(measured == 185)
    }

    @Test("a display with no notch gets a synthesised one, centerd at the top",
          arguments: [Fixture.externalLeftFrame, Fixture.externalRightFrame])
    func synthesizedNotch(frame: CGRect) {
        let notch = NotchResolver.resolve(
            screenFrame: frame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        #expect(notch.kind == .synthesized)
        #expect(notch.rect.size == NotchResolver.synthesizedSize)
        #expect(abs(notch.rect.midX - frame.midX) < 1e-9)
        #expect(notch.rect.maxY == frame.maxY)
    }

    /// With the menu bar set to auto-hide we expect `safeAreaInsets.top` to collapse to zero while
    /// the physical notch stays put. Falling back to the auxiliary area height keeps the island the
    /// right size. Flagged in the README as unverified against that system setting.
    @Test("notch height falls back to the auxiliary area height when the safe area collapses")
    func autoHidingMenuBarFallback() {
        let notch = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame,
            safeAreaTop: 0,
            auxiliaryTopLeft: Fixture.builtInAuxLeft,
            auxiliaryTopRight: Fixture.builtInAuxRight
        )
        #expect(notch.kind == .hardware)
        #expect(notch.rect.height == 32)
        #expect(notch.rect.width == 185)
    }

    @Test("degenerate auxiliary areas fall back to a synthesised notch")
    func degenerateAuxiliaryAreas() {
        // Zero-width auxiliary areas, and overlapping ones that would yield a negative gap.
        let zeroWidth = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame, safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 0, height: 32),
            auxiliaryTopRight: CGRect(x: 0, y: 1085, width: 0, height: 32)
        )
        #expect(zeroWidth.kind == .synthesized)

        let overlapping = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame, safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 900, height: 32),
            auxiliaryTopRight: CGRect(x: 800, y: 1085, width: 900, height: 32)
        )
        #expect(overlapping.kind == .synthesized)

        let onlyOne = NotchResolver.resolve(
            screenFrame: Fixture.builtInFrame, safeAreaTop: 32,
            auxiliaryTopLeft: Fixture.builtInAuxLeft, auxiliaryTopRight: nil
        )
        #expect(onlyOne.kind == .synthesized)
    }
}

@Suite("Island layout")
struct IslandLayoutTests {

    private func screen(frame: CGRect, notch: NotchGeometry, id: CGDirectDisplayID = 1) -> IslandScreen {
        IslandScreen(id: id, name: "test", frame: frame, backingScaleFactor: 2, notch: notch)
    }

    @Test("the panel hangs from the top of the screen, centerd on the notch")
    func panelFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let notch = NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        let panel = IslandLayout.panelFrame(for: screen(frame: frame, notch: notch))

        #expect(panel.maxY == frame.maxY)
        #expect(panel.height == IslandLayout.maxExpandedBodySize.height)
        #expect(abs(panel.midX - notch.rect.midX) < 1e-9)
        // Wide enough for the widest body plus a flare on each side.
        #expect(abs(panel.width - (IslandLayout.maxExpandedBodySize.width + 2 * IslandLayout.panelMargin)) < 1e-9)
    }

    @Test("the panel is clamped onto narrow displays and off-center notches")
    func panelFrameClamping() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let notch = NotchGeometry(kind: .hardware, rect: CGRect(x: 350, y: 268, width: 40, height: 32))
        let panel = IslandLayout.panelFrame(for: screen(frame: frame, notch: notch))

        #expect(panel.minX >= frame.minX - 1e-9)
        #expect(panel.maxX <= frame.maxX + 1e-9)
        #expect(panel.width <= frame.width)
        #expect(panel.height <= frame.height)
    }

    @Test("panels on displays that are not at the coordinate origin land on their own display")
    func panelFrameOnSecondaryDisplay() {
        let frame = CGRect(x: -2001, y: 1117, width: 1920, height: 1080)
        let notch = NotchResolver.resolve(screenFrame: frame, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let panel = IslandLayout.panelFrame(for: screen(frame: frame, notch: notch))

        #expect(frame.contains(panel))
        #expect(panel.maxY == frame.maxY)
    }

    @Test("at rest the island body is exactly the notch cutout")
    func restMetrics() {
        let notch = NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        let metrics = IslandLayout.restMetrics(for: screen(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), notch: notch))
        #expect(metrics.bodySize == CGSize(width: 185, height: 32))
        #expect(metrics.topCornerRadius == 0)
        #expect(metrics.bottomCornerRadius == IslandLayout.notchBottomCornerRadius)
    }

    /// The empty island — nothing on stage, nothing in the flanks — is the one form drawn *inside*
    /// the cutout, so a corner squarer than the hole's shows as black paint on the lit pixels either
    /// side of it. Two ways that could happen quietly: a collapsed form could carry a smaller radius
    /// than the flanked one, or the drawn extent could be clamped away on a body only 32pt tall.
    /// Neither is allowed to, so both are pinned here.
    @Test("an empty island's bottom corners are the cutout's own, at full extent")
    func emptyIslandKeepsTheFullBottomRadius() {
        let notch = NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), notch: notch)

        for form in [IslandForm.rest, .flankedRest, .peek, .flankedPeek] {
            let metrics = IslandLayout.metrics(for: form, on: screen)
            #expect(metrics.bottomCornerRadius == IslandLayout.notchBottomCornerRadius)

            // The radius has to survive into the path, not just into the metrics.
            let extents = IslandShapeGeometry.resolvedExtents(for: metrics)
            #expect(abs(extents.bottom - ContinuousCorner.extent(forRadius: IslandLayout.notchBottomCornerRadius)) < 1e-9)
        }
    }

    @Test("the island body sits flush against the top of the panel, horizontally centerd")
    func bodyOrigin() {
        let panelSize = CGSize(width: 600, height: 200)
        let metrics = IslandShapeMetrics(bodySize: CGSize(width: 185, height: 32), topCornerRadius: 0, bottomCornerRadius: 8)
        let origin = IslandLayout.bodyOrigin(for: metrics, in: panelSize)
        #expect(origin.y == 0)
        #expect(abs(origin.x - (600 - 185) / 2) < 1e-9)
    }
}
