import IslandKit
import SwiftUI

/// Where the page indicator's dots go, and how much island they cost.
///
/// Pure arithmetic, in its own type for the reason `ActivitySlotLayout` and `IslandLayout` are: the
/// height is what every other layout has to agree with, and it should be readable without a renderer.
///
/// **It replaced the switcher row's layout, and the island got shorter.** That row was 42pt —
/// a 22pt chip plus 8 above and 12 below — because it held controls that had to be aimed at. A dot
/// is 6, so the strip is 28pt and the open island gives 14pt back to whatever it is showing.
public enum IslandPageIndicatorLayout {

    /// One dot.
    public static let dotSide: CGFloat = 6

    /// Air between dots. Wider than the dots themselves, so three of them read as a row of three
    /// rather than as a dashed line.
    public static let dotSpacing: CGFloat = 7

    /// Air between the body above and the dots.
    ///
    /// **10, and it was 4.** Sized by eye from the strip alone, 4 looked like plenty; against a real
    /// page it put the dots hard under the last row of the body, so they read as part of the content
    /// rather than as chrome belonging to the island. Reported from use.
    public static let topPadding: CGFloat = 10

    /// Air below. Larger than the top, because the bottom of the island is a curve rather than an
    /// edge — a dot the same distance from the corner as from the flat above it reads as sitting
    /// lower than it does. The same asymmetry the chip row had, for the same reason.
    ///
    /// **12, and it was 6**, for the reason above and one more: this is the number the curve eats
    /// into, so it is the one that decides whether the row looks centred in the island's foot or
    /// pinned to its edge.
    public static let bottomPadding: CGFloat = 12

    /// How much height the strip takes out of the open island.
    ///
    /// A constant, and it has to be: `islandPath` tracks a settled shape, so a strip whose height
    /// followed its contents would move the island's bottom edge — and the clickable region with it.
    /// The page count is fixed, so there is nothing for it to follow anyway.
    public static var height: CGFloat { dotSide + topPadding + bottomPadding }

    /// The hit target around each dot.
    ///
    /// **Much larger than the dot**, and that is the whole reason this is a layout rather than three
    /// circles. A 6pt dot is not something a pointer that has travelled into the notch can be
    /// expected to hit; the *dot* is the picture and this is the control. It stays inside `height`
    /// vertically, so widening the target cannot widen the island.
    public static let targetSide: CGFloat = 22

    /// How wide the whole row is, for a given number of pages.
    public static func width(pageCount: Int) -> CGFloat {
        guard pageCount > 0 else { return 0 }
        return CGFloat(pageCount) * targetSide + CGFloat(pageCount - 1) * dotSpacing
    }
}

/// The three dots at the bottom of the open island: which page you are on, and how many there are.
///
/// ## Why there is an indicator at all
///
/// The chips said what you could switch to by drawing one control per thing. The pages are turned by
/// a swipe, and a swipe leaves nothing on screen — so without this the island would have three
/// surfaces and no evidence that the second two exist. Dots are what every paged surface on the
/// platform uses for exactly that, and they cost 16pt against the chip row's 42.
///
/// ## They are also the pointer's way through
///
/// Clickable, and deliberately so. Not every Mac has a trackpad, and a feature reachable only by a
/// two-finger gesture is a feature a mouse user does not have. This is the same argument the chip
/// row's gear won — a control that is sometimes there is one a person cannot learn the position of —
/// applied to a control that is always there and sometimes the only way in.
///
/// ## Why these are `Button`s
///
/// `IslandHitTestView.mouseDown` opens the island for any click that reaches it — but `hitTest`
/// returns the deepest subview that wants the point, so a press landing on a SwiftUI `Button`
/// reaches SwiftUI and never reaches that handler. That is the same mechanism the transport controls
/// run on, and `NowPlayingTransportView` documents why it works on a panel that is never key: a
/// button is driven by a press gesture over its own hit region, which needs neither key status nor
/// first responder. `.buttonStyle(.plain)` is required rather than cosmetic — the default macOS
/// style draws a bezel, and a bezel on pure `#000000` is a gray rectangle in a notch.
struct IslandPageIndicatorView: View {

    let current: IslandPage

    /// The page a live swipe is heading toward, and how far through it the finger is.
    ///
    /// **This is what stops the highlight jumping.** A committed drag changes `current` only when
    /// the turn lands, so an indicator that read `current` alone stood still through the entire
    /// gesture and then moved the white dot across in one frame — reported as the dots "jutting"
    /// into place. Given the destination and the progress, the two dots cross-fade under the finger
    /// and the eventual change of `current` moves nothing, which is the same trick the pages
    /// themselves land by.
    var incoming: IslandPage?

    var progress: CGFloat = 0

    let increaseContrast: Bool

    /// Whether the strip is sitting on glass rather than on `#000000`.
    ///
    /// The dots are drawn at the **bottom** of the open island, which under Semi-Liquid Glass is
    /// exactly where the black has cleared and the desktop shows through. A dot made of 30% white —
    /// which reads perfectly well on pure black — is invisible there, so it carries its own contrast
    /// when it has no black to sit on. The same fix the chip row needed, for the same reason:
    /// nothing drawn over a transparent island can borrow legibility from a desktop it does not
    /// control.
    let isOnGlass: Bool

    /// Whether the dots are lit at all.
    ///
    /// **They fade two seconds after the page stops changing** — see `IslandPageModel.indicatorDwell`
    /// for the argument, and `IslandScreenModel.showsPageDots` for the states that keep them. What
    /// matters here is that this is an *opacity* and never a branch: the strip's height is reserved
    /// by `IslandForm.showsPageIndicator` for as long as the island is open, so dots that came and
    /// went by existing or not would move the island's bottom edge — and the hit region pinned to
    /// it — two seconds after the user stopped touching anything.
    ///
    /// Faded rather than removed also keeps the row in the accessibility tree, which is the point:
    /// VoiceOver reaches the three pages through these buttons, and a control that disappears on a
    /// clock is a control a screen reader cannot be given.
    let isVisible: Bool

    let onSelect: (IslandPage) -> Void

    /// The pointer arriving on the strip, and leaving it.
    ///
    /// **This is what keeps the dots reachable with a mouse.** They are the only pointer route
    /// between the pages — the swipe is a trackpad gesture — so a row that fades on a clock would
    /// take page turning away from anyone without one. A pointer travelling to the bottom of the
    /// island brings them back and holds them there, which is what every other control on the
    /// platform that hides itself does; the dwell restarts when it leaves.
    ///
    /// It is also why nothing here is ever clicked blind: hovering is what reveals them, so by the
    /// time a press lands the dots have been under the pointer for the length of the journey.
    let onPointer: (Bool) -> Void

    var body: some View {
        HStack(spacing: IslandPageIndicatorLayout.dotSpacing) {
            ForEach(IslandPage.allCases, id: \.self) { page in
                Button { onSelect(page) } label: {
                    Circle()
                        .fill(fill(for: page))
                        .frame(
                            width: IslandPageIndicatorLayout.dotSide,
                            height: IslandPageIndicatorLayout.dotSide
                        )
                        // Anchored to the **top** of the strip by `topPadding`, not centred in it.
                        // The two paddings are deliberately unequal — the island's foot is a curve,
                        // so a dot the same distance from the corner as from the flat above reads as
                        // sitting lower than it does — and centring throws that asymmetry away.
                        .padding(.top, IslandPageIndicatorLayout.topPadding)
                        // The target is the box, not the dot. A 6pt circle is not a click target on
                        // a surface the pointer has to travel into the notch to reach.
                        .frame(
                            width: IslandPageIndicatorLayout.targetSide,
                            height: IslandPageIndicatorLayout.height,
                            alignment: .top
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.spokenName)
                .accessibilityAddTraits(page == current ? [.isSelected] : [])
            }
        }
        .frame(height: IslandPageIndicatorLayout.height)
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(isVisible ? 1 : 0)
        // `Motion.contentSwap`, the token every other change to what the island is *saying* travels
        // on. The dots arriving and leaving is not the island changing shape — the strip's height is
        // reserved either way — so it takes the crossfade rather than a spring, and it takes the
        // same one a track title changing does. No inline duration, §6.1.
        .animation(Motion.contentSwap, value: isVisible)
        // Sized to the whole strip, not to the dots: the region that brings them back is the band
        // the pointer would travel into to reach them, and aiming at a 6pt circle that is not drawn
        // yet is not something anyone can do. `PointerPresence` rather than `.onHover` for the
        // reason written on that type — this panel is never key, and the window server does not
        // deliver tracking events to one in that state without `.activeAlways`.
        .background(PointerPresence(isOver: onPointer))
    }

    /// The dot you are on is white; the rest are a wash of it — and mid-swipe, two of them are
    /// somewhere in between.
    ///
    /// A difference of *fill* rather than of size, deliberately. A larger current dot moves its
    /// neighbours every time the page turns, which on a 16pt strip reads as the row twitching rather
    /// than as the page changing — and the row would then have to be laid out for its widest state
    /// to stop the whole thing shifting sideways. It is also what makes the crossfade below possible
    /// at all: an opacity has somewhere to be half way to, and a diameter does not without moving
    /// everything beside it.
    private func fill(for page: IslandPage) -> Color {
        .white.opacity(offOpacity + (onOpacity - offOpacity) * weight(for: page))
    }

    /// How lit this dot should be: 1 for the page you are on, 0 for the others, and split between
    /// two of them while a finger is dragging from one to the next.
    ///
    /// Clamped rather than trusted. `progress` comes from a gesture that can be dragged past a whole
    /// page, and a weight above 1 would take the fill past white into a colour that does not exist.
    private func weight(for page: IslandPage) -> CGFloat {
        let travelled = max(0, min(1, progress))
        guard let incoming, incoming != current, travelled > 0 else {
            return page == current ? 1 : 0
        }
        if page == current { return 1 - travelled }
        if page == incoming { return travelled }
        return 0
    }

    private var onOpacity: CGFloat { increaseContrast ? 1 : 0.95 }

    /// Brighter on glass. 0.3 is a considered weight against `#000000`; over a bright window it
    /// is a gray speck on a pale field.
    private var offOpacity: CGFloat {
        if increaseContrast { return 0.6 }
        return isOnGlass ? 0.55 : 0.3
    }
}
