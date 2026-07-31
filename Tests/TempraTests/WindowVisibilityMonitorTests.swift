import CoreGraphics
import Testing
@testable import Tempra

@Suite("Window visibility")
struct WindowVisibilityMonitorTests {
    private let appPID: pid_t = 10
    private let otherPID: pid_t = 20
    private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)

    @Test("Any meaningfully visible app window protects the app")
    func anyVisibleWindowProtectsApp() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: appPID, x: 850, width: 100),
                window(pid: otherPID, x: 0, width: 800),
                window(pid: appPID, x: 0, width: 800)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    @Test("An ordinary floating window can still cover an app")
    func ordinaryFloatingWindowOccludes() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(
                    pid: otherPID,
                    x: 0,
                    width: 1_000,
                    height: 800,
                    layer: 20,
                    ownerName: "Overlay"
                ),
                window(pid: appPID, x: 0, width: 1_000, height: 800),
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .covered)
    }

    @Test("A smaller Dock window can still cover an app")
    func smallerDockWindowOccludes() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(
                    pid: otherPID,
                    x: 0,
                    width: 100,
                    layer: 20,
                    ownerName: "Dock"
                ),
                window(pid: appPID, x: 0, width: 100),
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .covered)
    }

    @Test("A sub-threshold sliver does not prevent management")
    func tinySliverIsCovered() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 99.5),
                window(pid: appPID, x: 0, width: 100)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .covered)
    }

    @Test("One percent of a window is meaningfully visible")
    func thresholdSliverIsVisible() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 99),
                window(pid: appPID, x: 0, width: 100)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    @Test("The Dock's transparent display window does not cover an app")
    func dockDisplayWindowDoesNotOcclude() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(
                    pid: otherPID,
                    x: 0,
                    width: 1_000,
                    height: 800,
                    layer: 20,
                    ownerName: "Dock"
                ),
                window(pid: appPID, x: 0, width: 1_000, height: 800),
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
        #expect(snapshot.visibilities(for: [WindowVisibilitySnapshot.Request(
            processIdentifiers: [appPID],
            isHidden: false
        )]) == [.visible])
    }

    @Test("Batched requests preserve independent visibility and hidden state")
    func batchedRequestsPreserveIndependentState() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: appPID, x: 0, width: 100),
                window(pid: otherPID, x: 0, width: 100),
            ],
            screenBounds: [screen]
        )
        let requests = [
            WindowVisibilitySnapshot.Request(
                processIdentifiers: [appPID],
                isHidden: false
            ),
            WindowVisibilitySnapshot.Request(
                processIdentifiers: [otherPID],
                isHidden: false
            ),
            WindowVisibilitySnapshot.Request(
                processIdentifiers: [otherPID],
                isHidden: true
            ),
        ]

        #expect(snapshot.visibilities(for: requests) == [
            .visible,
            .covered,
            .hiddenOrMinimized,
        ])
    }

    @Test("Same-owner menu windows do not cover normal windows")
    func sameOwnerMenuWindowDoesNotOcclude() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: appPID, x: 0, width: 100, layer: 24),
                window(pid: appPID, x: 0, width: 100),
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    @Test("Overlapping occluders contribute their union area once")
    func overlappingOccludersUseUnionArea() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 60),
                window(pid: otherPID + 1, x: 40, width: 59),
                window(pid: appPID, x: 0, width: 100),
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    @Test("Layer and alpha boundaries select normal windows")
    func layerAndAlphaBoundariesSelectNormalWindows() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: appPID, x: 0, width: 100, layer: 24),
                window(pid: otherPID, x: 0, width: 100, alpha: 0.01),
                window(pid: otherPID + 1, x: 0, width: 100, layer: -1),
            ],
            screenBounds: [screen]
        )

        #expect(!snapshot.hasNormalWindow(for: [appPID]))
        #expect(!snapshot.hasNormalWindow(for: [otherPID]))
        #expect(snapshot.hasNormalWindow(for: [otherPID + 1]))
    }

    @Test("Off-screen display gaps do not count as visible area")
    func displayGapsDoNotCountAsVisibleArea() {
        let leftScreen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rightScreen = CGRect(x: 200, y: 0, width: 100, height: 100)
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 100),
                window(pid: otherPID, x: 200, width: 100),
                window(pid: appPID, x: 0, width: 300),
            ],
            screenBounds: [leftScreen, rightScreen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .covered)
    }

    @Test("Batched visibility matches the previous geometry algorithm")
    func randomizedDifferentialCoverage() {
        var generator = SeededGenerator(seed: 0xD1FF_EA5E)
        let processIdentifiers = (1...8).map(pid_t.init)
        let layers = [-1, 0, 1, 23, 24, 25]
        let alphaValues = [0.0, 0.01, 0.011, 0.5, 1.0]
        let screenOptions = [
            [] as [CGRect],
            [CGRect(x: 0, y: 0, width: 500, height: 400)],
            [
                CGRect(x: 0, y: 0, width: 300, height: 400),
                CGRect(x: 350, y: 0, width: 300, height: 400),
            ],
        ]

        for caseIndex in 0..<200 {
            let windowCount = Int.random(in: 0...40, using: &generator)
            let windows = (0..<windowCount).map { _ in
                WindowVisibilityRecord(
                    ownerPID: processIdentifiers.randomElement(using: &generator) ?? 1,
                    bounds: CGRect(
                        x: Int.random(in: -100...650, using: &generator),
                        y: Int.random(in: -100...450, using: &generator),
                        width: Int.random(in: 1...250, using: &generator),
                        height: Int.random(in: 1...200, using: &generator)
                    ),
                    layer: layers.randomElement(using: &generator) ?? 0,
                    alpha: alphaValues.randomElement(using: &generator) ?? 1
                )
            }
            let screens = screenOptions.randomElement(using: &generator) ?? []
            let requests = (0..<8).map { _ in
                var identifiers: Set<pid_t> = [
                    processIdentifiers.randomElement(using: &generator) ?? 1,
                ]
                if Bool.random(using: &generator) {
                    identifiers.insert(
                        processIdentifiers.randomElement(using: &generator) ?? 1
                    )
                }
                return WindowVisibilitySnapshot.Request(
                    processIdentifiers: identifiers,
                    isHidden: Int.random(in: 0...4, using: &generator) == 0
                )
            }
            let snapshot = WindowVisibilitySnapshot(
                windowsFrontToBack: windows,
                screenBounds: screens
            )
            let expected = requests.map {
                referenceVisibility(
                    windowsFrontToBack: windows,
                    screenBounds: screens,
                    request: $0
                )
            }

            #expect(
                snapshot.visibilities(for: requests) == expected,
                "Batched result differed in randomized case \(caseIndex)."
            )
            for (request, expectedVisibility) in zip(requests, expected) {
                #expect(snapshot.visibility(
                    for: request.processIdentifiers,
                    isHidden: request.isHidden
                ) == expectedVisibility)
            }
        }
    }

    @Test("Large batched visibility evaluation benchmark")
    func largeBatchBenchmark() {
        let appCount = 100
        let occluderCount = 1_000
        let appPIDs = (1...appCount).map(pid_t.init)
        let occluders = (0..<occluderCount).map { index in
            WindowVisibilityRecord(
                ownerPID: pid_t(appCount + index + 1),
                bounds: CGRect(
                    x: (index * 37) % 1_800,
                    y: (index * 53) % 1_000,
                    width: 180,
                    height: 140
                ),
                layer: 0,
                alpha: 1
            )
        }
        let targets = appPIDs.map { processIdentifier in
            WindowVisibilityRecord(
                ownerPID: processIdentifier,
                bounds: CGRect(x: 0, y: 0, width: 2_000, height: 1_200),
                layer: 0,
                alpha: 1
            )
        }
        let requests = appPIDs.map {
            WindowVisibilitySnapshot.Request(
                processIdentifiers: [$0],
                isHidden: false
            )
        }
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: occluders + targets,
            screenBounds: [CGRect(x: 0, y: 0, width: 2_000, height: 1_200)]
        )
        let clock = ContinuousClock()
        let start = clock.now
        let results = snapshot.visibilities(for: requests)
        let elapsed = start.duration(to: clock.now)

        #expect(results.count == appCount)
        #expect(results.allSatisfy { $0 == .visible || $0 == .covered })
        print(
            "Window visibility benchmark: \(occluderCount + appCount) windows, "
                + "\(appCount) requests, \(elapsed)"
        )
    }

    private func window(
        pid: pid_t,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat = 100,
        layer: Int = 0,
        alpha: Double = 1,
        ownerName: String? = nil
    ) -> WindowVisibilityRecord {
        WindowVisibilityRecord(
            ownerPID: pid,
            ownerName: ownerName,
            bounds: CGRect(x: x, y: 0, width: width, height: height),
            layer: layer,
            alpha: alpha
        )
    }

    private func referenceVisibility(
        windowsFrontToBack: [WindowVisibilityRecord],
        screenBounds: [CGRect],
        request: WindowVisibilitySnapshot.Request
    ) -> AppWindowVisibility {
        guard !request.isHidden else { return .hiddenOrMinimized }
        let targets: [(index: Int, window: WindowVisibilityRecord)] = windowsFrontToBack
            .enumerated().compactMap { index, window in
            guard request.processIdentifiers.contains(window.ownerPID),
                  window.layer < 24,
                  window.alpha > 0.01 else {
                return nil
            }
            return (index: index, window: window)
        }
        guard !targets.isEmpty else { return .hiddenOrMinimized }

        let hasVisibleWindow = targets.contains { targetIndex, target in
            let targetArea = target.bounds.width * target.bounds.height
            guard targetArea > 0 else { return false }
            let displayRegions = screenBounds.isEmpty
                ? [target.bounds]
                : screenBounds.compactMap { intersection($0, target.bounds) }
            guard !displayRegions.isEmpty else { return false }
            let occluders = windowsFrontToBack[..<targetIndex].filter { window in
                !request.processIdentifiers.contains(window.ownerPID)
                    && window.layer >= 0
                    && window.alpha > 0.01
            }
            let visibleArea = displayRegions.reduce(CGFloat.zero) { result, displayRegion in
                let coveredRects = occluders.compactMap {
                    intersection($0.bounds, displayRegion)
                }
                return result + max(
                    0,
                    displayRegion.width * displayRegion.height
                        - referenceUnionArea(of: coveredRects)
                )
            }
            let visibleFraction = min(1, max(0, Double(visibleArea / targetArea)))
            return visibleFraction >= WindowVisibilitySnapshot.visibleFractionThreshold
        }
        return hasVisibleWindow ? .visible : .covered
    }

    private func referenceUnionArea(of rects: [CGRect]) -> CGFloat {
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

    private func intersection(_ first: CGRect, _ second: CGRect) -> CGRect? {
        let result = first.intersection(second)
        return result.isNull || result.isEmpty ? nil : result
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
