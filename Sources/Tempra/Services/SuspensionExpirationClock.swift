import Foundation

struct SuspensionExpirationClock: Sendable {
    let now: @Sendable () -> Date
    let sleepUntil: @Sendable (Date) async -> Bool

    static let continuous = SuspensionExpirationClock(
        now: { Date() },
        sleepUntil: { deadline in
            let delay = deadline.timeIntervalSinceNow
            guard delay > 0 else { return true }
            do {
                try await Task.sleep(for: .seconds(delay))
                return true
            } catch {
                return false
            }
        }
    )
}
