import IslandKit
import SwiftUI
import Testing

@testable import IslandUI

/// Renders the lock-screen surface to PNGs so it can be *looked at* without locking the Mac.
///
/// This exists because the surface is only on screen while the screen is locked, which makes the
/// ordinary way of checking a view — build it and glance at it — impossible. Without it the loop is
/// "ask the owner to lock, ask them what they saw, guess", which is slow and lossy: "a tiny white
/// square" is a real report and was consistent with half a dozen different drawing bugs. It found
/// two of them in one pass — a padlock at 13pt, and labels resolving in light appearance.
///
/// **What it cannot tell you.** `ImageRenderer` does not draw materials or vibrancy, and paints
/// unrenderable regions a flat gold — so gold here means "this used a material", not "this is the
/// wrong color". That is much less of a problem now than it was: the surface is pure black by
/// §6.4, exactly like the island, so there is no material left in it to mis-render.
///
/// Disabled by default so it is not part of `Tools/check.sh` — it writes files and asserts nothing.
/// Run it deliberately:
///
/// ```sh
/// ISLETA_RENDER_PROBE=1 swift test --package-path Packages/IslandUI --filter LockGlyphRenderProbe
/// ```
@Suite(
    "Lock screen render probe",
    .enabled(if: ProcessInfo.processInfo.environment["ISLETA_RENDER_PROBE"] != nil)
)
@MainActor
struct LockGlyphRenderProbe {

    /// A 14" MacBook Pro's geometry, so the renders come out at the real size.
    private static let screen = IslandScreen(
        id: 1,
        name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 663, y: 950, width: 185, height: 32))
    )

    @Test("render the lock-screen surface in each state")
    func render() throws {
        let locked = LockScreenCardModel()
        locked.screen = Self.screen
        locked.isLocked = true
        try write(LockScreenNotchView(model: locked), "notch-locked.png",
                  size: CGSize(width: 360, height: 80))

        let unlocking = LockScreenCardModel()
        unlocking.screen = Self.screen
        unlocking.isUnlocking = true
        try write(LockScreenNotchView(model: unlocking), "notch-unlocking.png",
                  size: CGSize(width: 360, height: 80))

        let playing = LockScreenCardModel()
        playing.screen = Self.screen
        playing.isLocked = true
        playing.content = .init(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        playing.timeline = .init(elapsed: 42, duration: 240, anchor: Date(), rate: 1)
        try write(LockScreenCardView(model: playing), "card-playing.png",
                  size: CGSize(width: 460, height: 250))
    }

    /// On a checkerboard, so transparent and white are distinguishable — which is the whole question
    /// a "white square" report leaves open.
    private func write(
        _ view: some View,
        _ name: String,
        size: CGSize
    ) throws {
        let renderer = ImageRenderer(
            content: ZStack {
                Checkerboard()
                view
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try png.write(to: url)
        print("wrote \(url.path)")
    }

    /// So transparency is visible in a PNG. Nothing to do with the product.
    private struct Checkerboard: View {
        var body: some View {
            Canvas { context, size in
                let step = 10.0
                for row in 0...Int(size.height / step) {
                    for column in 0...Int(size.width / step) {
                        let shade = (row + column).isMultiple(of: 2) ? 0.62 : 0.42
                        context.fill(
                            Path(CGRect(x: Double(column) * step, y: Double(row) * step,
                                        width: step, height: step)),
                            with: .color(Color(white: shade))
                        )
                    }
                }
            }
        }
    }
}
