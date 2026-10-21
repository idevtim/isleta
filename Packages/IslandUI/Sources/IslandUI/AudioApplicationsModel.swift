import CoreGraphics
import IslandActivities
import IslandKit
import Observation

/// The audio page's fixed viewport and lazy rows share one source of sizing.
public enum AudioApplicationsLayout {
    public static let contentHeight: CGFloat = 224
    public static let headerHeight: CGFloat = 16
    public static let headerSpacing: CGFloat = 10
    public static let verticalPadding: CGFloat = 12
    public static let rowHeight: CGFloat = 50
    public static let rowSpacing: CGFloat = 8
    public static let viewportHeight = contentHeight - verticalPadding * 2 - headerHeight - headerSpacing

    public static func contentExtent(rowCount: Int) -> CGFloat {
        let count = CGFloat(max(0, rowCount))
        return count * rowHeight + max(0, count - 1) * rowSpacing
    }

    public static func scrollExtent(rowCount: Int) -> CGFloat {
        max(0, contentExtent(rowCount: rowCount) - viewportHeight)
    }
}

@MainActor @Observable
public final class AudioApplicationsModel {
    public var applications: [AudioApplication] = [] {
        didSet {
            let offset = scroll.clamped(to: AudioApplicationsLayout.scrollExtent(rowCount: applications.count))
            if offset != scrollTarget.offset { scrollTarget = scrollTarget.dragged(to: offset) }
        }
    }
    public var onOpen: ((String) -> Void)?
    public private(set) var scrollTarget = IslandListScrollTarget()
    @ObservationIgnored private var scroll = IslandListScroll()
    @ObservationIgnored private var axis: Axis?
    private enum Axis { case horizontal, vertical }

    public init() {}
    public func open(_ application: AudioApplication) { onOpen?(application.bundleIdentifier) }

    /// True only when this gesture belongs to the vertical list. Horizontal samples continue to
    /// the carousel, including their end/momentum tail. Zero-delta begins reach both recognizers.
    @discardableResult
    public func scrollIfVertical(_ sample: IslandScrollSample) -> Bool {
        if sample.phase == .began || sample.phase == .discrete { axis = nil }
        if axis == nil, sample.deltaX != 0 || sample.deltaY != 0 {
            axis = abs(sample.deltaY) > abs(sample.deltaX) ? .vertical : .horizontal
        }
        let isVertical = axis == .vertical
        if isVertical {
            let offset = scroll.consume(sample, extent: AudioApplicationsLayout.scrollExtent(rowCount: applications.count))
            scrollTarget = scrollTarget.dragged(to: offset)
        }
        if sample.phase == .canceled || sample.phase == .momentumEnded { axis = nil }
        return isVertical
    }
}
