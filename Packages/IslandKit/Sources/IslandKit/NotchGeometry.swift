import CoreGraphics

/// Where the island lives on one display.
///
/// All rects are in AppKit's global screen space: y-up, origin at the bottom-left of the main
/// display. Convert to the panel's y-down content space with `IslandLayout` before drawing.
public struct NotchGeometry: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// A real hardware notch, reported by `NSScreen`'s auxiliary top areas.
        case hardware
        /// No notch on this display; the rect is synthesised so the island still has somewhere
        /// to live (§4.3). Renders with a material background rather than pure black (§6.4).
        case synthesized
    }

    public let kind: Kind

    /// The notch cutout (or its synthesised stand-in) in global screen coordinates.
    public let rect: CGRect

    public init(kind: Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }

    /// The part of the island body that is a *hole*: no pixels, nothing that can be lit.
    ///
    /// A synthesized notch reports a 210x32pt rect so the island has somewhere to live, but there is
    /// no hole in that display — every pixel under the island is lit. Treating the synthesized rect
    /// as a cutout would carve a dead zone out of the middle of a perfectly good island, which is
    /// why this is `.zero` there rather than `rect.size`.
    ///
    /// Here rather than in IslandUI because both the *drawn* height of the open island
    /// (`IslandLayout.metrics`) and the *slot layout* inside it (`ActivitySlotLayout`) have to
    /// subtract the same hole, and two copies of that rule is two places for it to be wrong.
    public var cutoutSize: CGSize {
        kind == .hardware ? rect.size : .zero
    }
}

/// Derives notch geometry from raw `NSScreen` values.
///
/// Deliberately free of AppKit so the arithmetic — which is where display-arrangement bugs hide —
/// is unit-testable against captured real-hardware values without a running app.
public enum NotchResolver {

    /// Stand-in notch for displays without one (§4.3).
    public static let synthesizedSize = CGSize(width: 210, height: 32)

    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame`, global coordinates.
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`.
    ///   - auxiliaryTopLeft: `NSScreen.auxiliaryTopLeftArea` — nil on displays without a notch.
    ///   - auxiliaryTopRight: `NSScreen.auxiliaryTopRightArea`.
    public static func resolve(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) -> NotchGeometry {
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
           left.width > 0, right.width > 0 {
            // Measure the gap between the two unobscured areas directly rather than subtracting
            // their widths from the screen width. Both give 185pt on a 14" MacBook Pro, but the gap
            // also survives a display arrangement where the auxiliary areas do not tile the full
            // width, and it yields the notch's x position for free instead of assuming it is centerd.
            let width = right.minX - left.maxX

            // With the menu bar set to auto-hide, `safeAreaInsets.top` is expected to collapse to 0
            // while the physical notch obviously does not move; the auxiliary areas still report
            // their height, so prefer that as the fallback. See README — unverified on hardware.
            let height = safeAreaTop > 0 ? safeAreaTop : max(left.height, right.height)

            if width > 0, height > 0 {
                return NotchGeometry(
                    kind: .hardware,
                    rect: CGRect(
                        x: left.maxX,
                        y: screenFrame.maxY - height,
                        width: width,
                        height: height
                    )
                )
            }
        }

        let size = synthesizedSize
        return NotchGeometry(
            kind: .synthesized,
            rect: CGRect(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        )
    }
}

/// One display's full island context.
public struct IslandScreen: Equatable, Sendable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let backingScaleFactor: CGFloat
    public let notch: NotchGeometry

    public init(
        id: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        backingScaleFactor: CGFloat,
        notch: NotchGeometry
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
        self.notch = notch
    }
}
