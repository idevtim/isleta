import CoreGraphics
import IslandKit
import Testing
@testable import IslandSources

@Suite("Menu bar avoidance")
struct MenuBarAvoidanceTests {
    private func screen(x: CGFloat = 0, y: CGFloat = 0, kind: NotchGeometry.Kind = .hardware) -> IslandScreen {
        IslandScreen(id: 1, name: "Test", frame: CGRect(x: x, y: y, width: 1512, height: 982),
                     backingScaleFactor: 2,
                     notch: NotchGeometry(kind: kind, rect: CGRect(x: x + 663, y: y + 950, width: 185, height: 32)))
    }

    @Test("the screenshot menu overlaps the added left flank, but a shorter menu fits")
    func leadingMenu() {
        let overlap = CGRect(x: 612, y: 0, width: 45, height: 32)
        #expect(MenuBarAvoidance.needsSpace(items: [overlap], on: screen(), closedWidth: 265, desktopTop: 982))
        #expect(!MenuBarAvoidance.needsSpace(items: [CGRect(x: 550, y: 0, width: 50, height: 32)],
                                           on: screen(), closedWidth: 265, desktopTop: 982))
    }

    @Test("right-hand overlaps and wider activities use the full unattended width")
    func trailingAndWide() {
        let item = CGRect(x: 895, y: 0, width: 40, height: 32)
        #expect(!MenuBarAvoidance.needsSpace(items: [item], on: screen(), closedWidth: 265, desktopTop: 982))
        #expect(MenuBarAvoidance.needsSpace(items: [item], on: screen(), closedWidth: 459, desktopTop: 982))
    }

    @Test("global y conversion handles a display above, below or left of the primary")
    func arrangedDisplays() {
        for (x, y) in [(CGFloat(-1512), CGFloat(0)), (0, 982), (0, -982)] {
            let item = CGRect(x: x + 612, y: -y, width: 45, height: 32)
            #expect(MenuBarAvoidance.needsSpace(items: [item], on: screen(x: x, y: y), closedWidth: 265, desktopTop: 982))
            #expect(!MenuBarAvoidance.needsSpace(items: [CGRect(x: x + 612, y: -y + 100, width: 45, height: 32)],
                                               on: screen(x: x, y: y), closedWidth: 265, desktopTop: 982))
        }
    }

    @Test("pending and denied reads keep the last confirmed shape")
    func unavailable() {
        #expect(!MenuBarAvoidance.needsSpace(items: nil, on: screen(), closedWidth: 265, desktopTop: 982))
        #expect(MenuBarAvoidance.needsSpace(items: nil, on: screen(), closedWidth: 265, desktopTop: 982, wasRetracted: true))
        #expect(!MenuBarAvoidance.needsSpace(items: [], on: screen(), closedWidth: 265, desktopTop: 982))
        #expect(MenuBarGeometryReader.read(processID: -1, isTrusted: { false }) == nil)
    }

    @Test("app switches only change the shape after a successful collision check")
    func switchingApplications() {
        let clear = [CGRect(x: 500, y: 0, width: 40, height: 32)]
        let overlapping = [CGRect(x: 612, y: 0, width: 45, height: 32)]
        var retracted = false
        var changes: [Bool] = []
        // App A fits; app B is pending, fails once, then fits; app C really overlaps.
        let snapshots: [[CGRect]?] = [clear, nil, nil, clear, nil, overlapping, nil, clear]
        for items in snapshots {
            let next = MenuBarAvoidance.needsSpace(items: items, on: screen(), closedWidth: 265,
                                                  desktopTop: 982, wasRetracted: retracted)
            if next != retracted { changes.append(next) }
            retracted = next
        }
        #expect(changes == [true, false])
    }

    @Test("notchless screens keep their existing behavior")
    func synthesized() {
        #expect(!MenuBarAvoidance.needsSpace(items: nil, on: screen(kind: .synthesized), closedWidth: 265, desktopTop: 982))
    }
}
