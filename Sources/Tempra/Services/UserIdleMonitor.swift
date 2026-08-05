import CoreGraphics
import Foundation

struct UserIdleMonitor {
    typealias SecondsProvider = @Sendable () -> TimeInterval

    private let secondsProvider: SecondsProvider

    init(secondsProvider: @escaping SecondsProvider = {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
    }) {
        self.secondsProvider = secondsProvider
    }

    func sample() -> TimeInterval? {
        let seconds = secondsProvider()
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}
