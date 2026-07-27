import CoreGraphics
import Darwin
import Foundation

enum AppWindowVisibility: Equatable, Sendable {
    case hiddenOrMinimized
    case covered
    case visible
    case unknown

    var minimumDisruptiveDelay: TimeInterval {
        switch self {
        case .hiddenOrMinimized:
            0
        case .covered:
            5
        case .visible, .unknown:
            15
        }
    }

    var protectsFromDisruptiveManagement: Bool {
        switch self {
        case .visible, .unknown:
            true
        case .covered, .hiddenOrMinimized:
            false
        }
    }
}

struct WindowVisibilityRecord: Equatable, Sendable {
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let alpha: Double
}

struct WindowVisibilitySnapshot: Sendable {
    static let visibleFractionThreshold = 0.01
    private static let firstMenuWindowLayer = 24

    let windowsFrontToBack: [WindowVisibilityRecord]
    let screenBounds: [CGRect]

    static func capture() -> WindowVisibilitySnapshot? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        let windows = windowInfo.compactMap { info -> WindowVisibilityRecord? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(
                boundsDictionary as CFDictionary,
                &bounds
            ),
                  bounds.width > 0,
                  bounds.height > 0 else {
                return nil
            }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowVisibilityRecord(
                ownerPID: ownerPID,
                bounds: bounds.standardized,
                layer: layer,
                alpha: alpha
            )
        }

        return WindowVisibilitySnapshot(
            windowsFrontToBack: windows,
            screenBounds: activeScreenBounds()
        )
    }

    func visibility(
        for processIdentifiers: Set<pid_t>,
        isHidden: Bool
    ) -> AppWindowVisibility {
        guard !isHidden else { return .hiddenOrMinimized }
        let targets = normalWindows(for: processIdentifiers)
        guard !targets.isEmpty else {
            return .hiddenOrMinimized
        }
        let hasVisibleWindow = targets.contains { target in
            visibleFraction(
                of: target.window,
                at: target.index,
                ownedBy: processIdentifiers
            ) >= Self.visibleFractionThreshold
        }
        return hasVisibleWindow ? .visible : .covered
    }

    func hasNormalWindow(for processIdentifiers: Set<pid_t>) -> Bool {
        !normalWindows(for: processIdentifiers).isEmpty
    }

    private func normalWindows(
        for processIdentifiers: Set<pid_t>
    ) -> [(index: Int, window: WindowVisibilityRecord)] {
        windowsFrontToBack.enumerated()
            .compactMap { index, window in
                guard processIdentifiers.contains(window.ownerPID),
                      window.layer < Self.firstMenuWindowLayer,
                      window.alpha > 0.01 else {
                    return nil
                }
                return (index: index, window: window)
            }
    }

    private func visibleFraction(
        of target: WindowVisibilityRecord,
        at targetIndex: Int,
        ownedBy processIdentifiers: Set<pid_t>
    ) -> Double {
        let targetArea = target.bounds.area
        guard targetArea > 0 else { return 0 }

        let displayRegions = screenBounds.isEmpty
            ? [target.bounds]
            : screenBounds.compactMap { $0.intersectionOrNil(target.bounds) }
        guard !displayRegions.isEmpty else { return 0 }

        let occluders = windowsFrontToBack[..<targetIndex].filter { window in
            !processIdentifiers.contains(window.ownerPID)
                && window.layer >= 0
                && window.alpha > 0.01
        }
        let visibleArea = displayRegions.reduce(CGFloat.zero) { result, displayRegion in
            let coveredRects = occluders.compactMap {
                $0.bounds.intersectionOrNil(displayRegion)
            }
            return result + max(0, displayRegion.area - Self.unionArea(of: coveredRects))
        }
        return min(1, max(0, Double(visibleArea / targetArea)))
    }

    private static func unionArea(of rects: [CGRect]) -> CGFloat {
        guard !rects.isEmpty else { return 0 }
        let xCoordinates = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xCoordinates.count > 1 else { return 0 }

        var area: CGFloat = 0
        for index in 0..<(xCoordinates.count - 1) {
            let minX = xCoordinates[index]
            let maxX = xCoordinates[index + 1]
            guard maxX > minX else { continue }

            let intervals = rects.compactMap { rect -> ClosedRange<CGFloat>? in
                guard rect.minX < maxX, rect.maxX > minX else { return nil }
                return rect.minY...rect.maxY
            }.sorted { $0.lowerBound < $1.lowerBound }
            guard var merged = intervals.first else { continue }

            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.lowerBound <= merged.upperBound {
                    merged = merged.lowerBound...max(merged.upperBound, interval.upperBound)
                } else {
                    coveredHeight += merged.upperBound - merged.lowerBound
                    merged = interval
                }
            }
            coveredHeight += merged.upperBound - merged.lowerBound
            area += (maxX - minX) * coveredHeight
        }
        return area
    }

    private static func activeScreenBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard result == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(0, width) * max(0, height)
    }

    func intersectionOrNil(_ other: CGRect) -> CGRect? {
        let result = intersection(other)
        return result.isNull || result.isEmpty ? nil : result
    }
}
