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
    let ownerName: String?
    let bounds: CGRect
    let layer: Int
    let alpha: Double

    init(
        ownerPID: pid_t,
        ownerName: String? = nil,
        bounds: CGRect,
        layer: Int,
        alpha: Double
    ) {
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }

    func canOccludeWindowsBehind(screenBounds: [CGRect]) -> Bool {
        guard ownerName == "Dock" else { return true }
        return !occupiesDisplay(in: screenBounds)
    }

    func occupiesDisplay(in screenBounds: [CGRect]) -> Bool {
        screenBounds.contains { screen in
            guard screen.area > 0,
                  let intersection = bounds.intersectionOrNil(screen) else {
                return false
            }
            return intersection.area >= screen.area * 0.99
        }
    }
}

struct WindowVisibilitySnapshot: Sendable {
    struct Request: Sendable {
        let processIdentifiers: Set<pid_t>
        let isHidden: Bool
    }

    static let visibleFractionThreshold = 0.01
    private static let firstMenuWindowLayer = 24

    let windowsFrontToBack: [WindowVisibilityRecord]
    let screenBounds: [CGRect]
    private let windowIndicesByOwnerPID: [pid_t: [Int]]

    init(
        windowsFrontToBack: [WindowVisibilityRecord],
        screenBounds: [CGRect]
    ) {
        self.windowsFrontToBack = windowsFrontToBack
        self.screenBounds = screenBounds
        var indicesByOwnerPID: [pid_t: [Int]] = [:]
        for (index, window) in windowsFrontToBack.enumerated() {
            indicesByOwnerPID[window.ownerPID, default: []].append(index)
        }
        windowIndicesByOwnerPID = indicesByOwnerPID
    }

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
                ownerName: info[kCGWindowOwnerName as String] as? String,
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
        isHidden: Bool,
        ignoringOccludersOwnedBy ignoredProcessIdentifiers: Set<pid_t> = []
    ) -> AppWindowVisibility {
        guard !isHidden else { return .hiddenOrMinimized }
        let targetIndices = normalWindowIndices(for: processIdentifiers)
        guard !targetIndices.isEmpty else {
            return .hiddenOrMinimized
        }
        let hasVisibleWindow = targetIndices.contains { targetIndex in
            visibleFraction(
                of: windowsFrontToBack[targetIndex],
                behind: windowsFrontToBack[..<targetIndex],
                ownedBy: processIdentifiers,
                ignoringOccludersOwnedBy: ignoredProcessIdentifiers
            ) >= Self.visibleFractionThreshold
        }
        return hasVisibleWindow ? .visible : .covered
    }

    func visibilities(
        for requests: [Request],
        ignoringOccludersOwnedBy ignoredProcessIdentifiers: Set<pid_t> = []
    ) -> [AppWindowVisibility] {
        var results = [AppWindowVisibility](
            repeating: .hiddenOrMinimized,
            count: requests.count
        )
        var requestIndicesByOwnerPID: [pid_t: [Int]] = [:]
        for (requestIndex, request) in requests.enumerated() where !request.isHidden {
            for processIdentifier in request.processIdentifiers {
                requestIndicesByOwnerPID[processIdentifier, default: []].append(requestIndex)
            }
        }

        var occluders: [WindowVisibilityRecord] = []
        occluders.reserveCapacity(windowsFrontToBack.count)
        for window in windowsFrontToBack {
            if window.layer < Self.firstMenuWindowLayer,
               window.alpha > 0.01,
               let requestIndices = requestIndicesByOwnerPID[window.ownerPID] {
                for requestIndex in requestIndices where results[requestIndex] != .visible {
                    results[requestIndex] = .covered
                    if visibleFraction(
                        of: window,
                        behind: occluders[...],
                        ownedBy: requests[requestIndex].processIdentifiers,
                        ignoringOccludersOwnedBy: ignoredProcessIdentifiers
                    ) >= Self.visibleFractionThreshold {
                        results[requestIndex] = .visible
                    }
                }
            }
            if !ignoredProcessIdentifiers.contains(window.ownerPID),
               window.layer >= 0,
               window.alpha > 0.01,
               window.canOccludeWindowsBehind(screenBounds: screenBounds) {
                occluders.append(window)
            }
        }
        return results
    }

    func hasNormalWindow(for processIdentifiers: Set<pid_t>) -> Bool {
        !normalWindowIndices(for: processIdentifiers).isEmpty
    }

    func hasDisplaySizedWindow(for processIdentifier: pid_t) -> Bool {
        windowIndicesByOwnerPID[processIdentifier, default: []].contains { index in
            let window = windowsFrontToBack[index]
            return window.layer >= 0
                && window.alpha > 0.01
                && window.occupiesDisplay(in: screenBounds)
        }
    }

    private func normalWindowIndices(
        for processIdentifiers: Set<pid_t>
    ) -> [Int] {
        processIdentifiers.flatMap { processIdentifier in
            windowIndicesByOwnerPID[processIdentifier, default: []].filter { index in
                let window = windowsFrontToBack[index]
                return window.layer < Self.firstMenuWindowLayer && window.alpha > 0.01
            }
        }
    }

    private func visibleFraction(
        of target: WindowVisibilityRecord,
        behind windowsInFront: ArraySlice<WindowVisibilityRecord>,
        ownedBy processIdentifiers: Set<pid_t>,
        ignoringOccludersOwnedBy ignoredProcessIdentifiers: Set<pid_t>
    ) -> Double {
        let targetArea = target.bounds.area
        guard targetArea > 0 else { return 0 }

        let displayRegions = screenBounds.isEmpty
            ? [target.bounds]
            : screenBounds.compactMap { $0.intersectionOrNil(target.bounds) }
        guard !displayRegions.isEmpty else { return 0 }

        let occluders = windowsInFront.filter { window in
            !processIdentifiers.contains(window.ownerPID)
                && !ignoredProcessIdentifiers.contains(window.ownerPID)
                && window.layer >= 0
                && window.alpha > 0.01
                && window.canOccludeWindowsBehind(screenBounds: screenBounds)
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
        let validRects = rects.filter {
            !$0.isNull
                && !$0.isEmpty
                && $0.minX.isFinite
                && $0.maxX.isFinite
                && $0.minY.isFinite
                && $0.maxY.isFinite
        }
        guard !validRects.isEmpty else { return 0 }
        let yCoordinates = Array(Set(validRects.flatMap { [$0.minY, $0.maxY] })).sorted()
        guard yCoordinates.count > 1 else { return 0 }
        let events = validRects.flatMap { rect in
            let lowerYIndex = insertionIndex(of: rect.minY, in: yCoordinates)
            let upperYIndex = insertionIndex(of: rect.maxY, in: yCoordinates)
            return [
                SweepEvent(
                    x: rect.minX,
                    lowerYIndex: lowerYIndex,
                    upperYIndex: upperYIndex,
                    delta: 1
                ),
                SweepEvent(
                    x: rect.maxX,
                    lowerYIndex: lowerYIndex,
                    upperYIndex: upperYIndex,
                    delta: -1
                ),
            ]
        }.sorted { first, second in
            if first.x != second.x { return first.x < second.x }
            return first.delta < second.delta
        }

        var coverage = YCoverageTree(coordinates: yCoordinates)
        var area: CGFloat = 0
        var previousX = events[0].x
        var eventIndex = 0
        while eventIndex < events.count {
            let x = events[eventIndex].x
            area += (x - previousX) * coverage.coveredLength
            while eventIndex < events.count, events[eventIndex].x == x {
                let event = events[eventIndex]
                coverage.update(
                    lowerBound: event.lowerYIndex,
                    upperBound: event.upperYIndex,
                    delta: event.delta
                )
                eventIndex += 1
            }
            previousX = x
        }
        return area
    }

    private static func insertionIndex(
        of value: CGFloat,
        in sortedValues: [CGFloat]
    ) -> Int {
        var lowerBound = 0
        var upperBound = sortedValues.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if sortedValues[midpoint] < value {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private struct SweepEvent {
        let x: CGFloat
        let lowerYIndex: Int
        let upperYIndex: Int
        let delta: Int
    }

    private struct YCoverageTree {
        private struct Node {
            let lowerBound: Int
            let upperBound: Int
            var leftChild: Int?
            var rightChild: Int?
            var coverCount = 0
            var coveredLength: CGFloat = 0
        }

        private let coordinates: [CGFloat]
        private var nodes: [Node]

        var coveredLength: CGFloat {
            nodes[0].coveredLength
        }

        init(coordinates: [CGFloat]) {
            self.coordinates = coordinates
            nodes = [Node(lowerBound: 0, upperBound: coordinates.count - 1)]
            var pendingNodeIndices = [0]
            while let nodeIndex = pendingNodeIndices.popLast() {
                let node = nodes[nodeIndex]
                guard node.upperBound - node.lowerBound > 1 else { continue }
                let midpoint = node.lowerBound
                    + (node.upperBound - node.lowerBound) / 2
                let leftChild = nodes.count
                nodes.append(Node(lowerBound: node.lowerBound, upperBound: midpoint))
                let rightChild = nodes.count
                nodes.append(Node(lowerBound: midpoint, upperBound: node.upperBound))
                nodes[nodeIndex].leftChild = leftChild
                nodes[nodeIndex].rightChild = rightChild
                pendingNodeIndices.append(leftChild)
                pendingNodeIndices.append(rightChild)
            }
        }

        mutating func update(lowerBound: Int, upperBound: Int, delta: Int) {
            var pending: [(nodeIndex: Int, refreshOnly: Bool)] = [(0, false)]
            while let operation = pending.popLast() {
                let node = nodes[operation.nodeIndex]
                if operation.refreshOnly {
                    refresh(operation.nodeIndex)
                    continue
                }
                guard lowerBound < node.upperBound, upperBound > node.lowerBound else {
                    continue
                }
                if lowerBound <= node.lowerBound, node.upperBound <= upperBound {
                    nodes[operation.nodeIndex].coverCount += delta
                    refresh(operation.nodeIndex)
                    continue
                }
                pending.append((operation.nodeIndex, true))
                if let rightChild = node.rightChild {
                    pending.append((rightChild, false))
                }
                if let leftChild = node.leftChild {
                    pending.append((leftChild, false))
                }
            }
        }

        private mutating func refresh(_ nodeIndex: Int) {
            let node = nodes[nodeIndex]
            if node.coverCount > 0 {
                nodes[nodeIndex].coveredLength = coordinates[node.upperBound]
                    - coordinates[node.lowerBound]
            } else if let leftChild = node.leftChild, let rightChild = node.rightChild {
                nodes[nodeIndex].coveredLength = nodes[leftChild].coveredLength
                    + nodes[rightChild].coveredLength
            } else {
                nodes[nodeIndex].coveredLength = 0
            }
        }
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
