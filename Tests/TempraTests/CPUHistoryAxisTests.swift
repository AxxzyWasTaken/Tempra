import CoreGraphics
import Foundation
import Testing
@testable import Tempra

@Suite("CPU history axis")
struct CPUHistoryAxisTests {
    @Test(
        "Tick density adapts to chart width",
        arguments: [
            (CGFloat(220), 3),
            (CGFloat(304), 4),
            (CGFloat(420), 6)
        ]
    )
    func adaptiveTickDensity(width: CGFloat, expectedCount: Int) {
        #expect(
            CPUHistoryAxis.tickCount(for: .hour, availableWidth: width) == expectedCount
        )
    }

    @Test("Minute-second labels retain one extra tick at popover width")
    func minuteSecondDensity() {
        #expect(
            CPUHistoryAxis.tickCount(for: .fiveMinutes, availableWidth: 304) == 5
        )
    }

    @Test("Five-minute labels keep minute-second format at the one-minute boundary")
    func minuteBoundaryFormatting() {
        #expect(CPUHistoryAxis.label(forOffset: -300, range: .fiveMinutes) == "−5:00")
        #expect(CPUHistoryAxis.label(forOffset: -60, range: .fiveMinutes) == "−1:00")
        #expect(CPUHistoryAxis.label(forOffset: 0, range: .fiveMinutes) == "0:00")
    }

    @Test(
        "Every range uses one consistent label format",
        arguments: CPUHistoryRange.allCases
    )
    func consistentFormat(range: CPUHistoryRange) {
        let endDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let labels = CPUHistoryAxis.tickDates(
            for: range,
            endingAt: endDate,
            availableWidth: 304
        ).map {
            CPUHistoryAxis.label(for: $0, range: range, relativeTo: endDate)
        }

        switch range {
        case .fiveMinutes:
            #expect(labels.allSatisfy { $0.contains(":") })
            #expect(labels.allSatisfy { !$0.contains("h") && !$0.contains("m") })
        case .hour:
            #expect(labels.allSatisfy { $0.hasSuffix("m") })
        case .day:
            #expect(labels.allSatisfy { $0.hasSuffix("h") })
        }
    }
}
