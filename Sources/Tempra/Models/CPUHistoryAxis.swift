import CoreGraphics
import Foundation

enum CPUHistoryAxis {
    private static let maximumTickCount = 6
    private static let minimumTickCount = 3
    private static let horizontalAxisReserve: CGFloat = 72

    static func tickCount(for range: CPUHistoryRange, availableWidth: CGFloat) -> Int {
        let usableWidth = max(0, availableWidth - horizontalAxisReserve)
        let count = Int(floor(usableWidth / minimumLabelSpacing(for: range))) + 1
        return min(maximumTickCount, max(minimumTickCount, count))
    }

    static func tickDates(
        for range: CPUHistoryRange,
        endingAt endDate: Date,
        availableWidth: CGFloat
    ) -> [Date] {
        let count = tickCount(for: range, availableWidth: availableWidth)
        let intervalCount = Double(count - 1)
        return (0..<count).map { index in
            let offset = -range.duration + range.duration * Double(index) / intervalCount
            return endDate.addingTimeInterval(offset)
        }
    }

    static func label(
        for date: Date,
        range: CPUHistoryRange,
        relativeTo endDate: Date
    ) -> String {
        label(forOffset: date.timeIntervalSince(endDate), range: range)
    }

    static func label(forOffset offset: TimeInterval, range: CPUHistoryRange) -> String {
        let seconds = max(-range.duration, min(0, offset))
        let totalSeconds = Int(abs(seconds).rounded())

        switch range {
        case .fiveMinutes:
            guard totalSeconds > 0 else { return "0:00" }
            return "−\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
        case .hour:
            let minutes = Int((Double(totalSeconds) / 60).rounded())
            return minutes == 0 ? "0m" : "−\(minutes)m"
        case .day:
            let hours = Int((Double(totalSeconds) / 3_600).rounded())
            return hours == 0 ? "0h" : "−\(hours)h"
        }
    }

    private static func minimumLabelSpacing(for range: CPUHistoryRange) -> CGFloat {
        switch range {
        case .fiveMinutes: 52
        case .hour: 64
        case .day: 60
        }
    }
}
