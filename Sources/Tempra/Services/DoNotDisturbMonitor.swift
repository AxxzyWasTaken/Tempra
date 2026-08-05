import CoreFoundation
import Foundation

final class DoNotDisturbMonitor {
    typealias ValueProvider = (String) -> Any?

    private static let preferencesDomain = "com.apple.notificationcenterui"
    private let valueProvider: ValueProvider
    private let cacheInterval: TimeInterval
    private var cachedState: (date: Date, isEnabled: Bool)?

    init(
        cacheInterval: TimeInterval = 5,
        valueProvider: @escaping ValueProvider = { key in
            CFPreferencesCopyAppValue(
                key as CFString,
                DoNotDisturbMonitor.preferencesDomain as CFString
            )
        }
    ) {
        self.cacheInterval = max(0, cacheInterval)
        self.valueProvider = valueProvider
    }

    func isEnabled(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        if let cachedState,
           abs(date.timeIntervalSince(cachedState.date)) < cacheInterval {
            return cachedState.isEnabled
        }
        let isEnabled = readState(at: date, calendar: calendar)
        cachedState = (date, isEnabled)
        return isEnabled
    }

    private func readState(at date: Date, calendar: Calendar) -> Bool {
        if (valueProvider("doNotDisturb") as? NSNumber)?.boolValue == true {
            return true
        }

        guard let start = minuteValue(for: "dndStart"),
              let end = minuteValue(for: "dndEnd"),
              start != end else {
            return false
        }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let current = Double(hour * 60 + minute)

        if start < end {
            return current >= start && current < end
        }
        return current >= start || current < end
    }

    private func minuteValue(for key: String) -> Double? {
        guard let value = (valueProvider(key) as? NSNumber)?.doubleValue,
              value.isFinite,
              (0..<1_440).contains(value) else {
            return nil
        }
        return value
    }
}
