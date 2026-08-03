import Foundation

enum ProcessControlTickTrigger {
    case stateUpdate
    case cadence
}

struct ProcessReconciliationContext: Sendable {
    let stateID: UUID
    let revision: UInt64
}

struct ProcessControlClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async -> Void

    static let continuous: ProcessControlClock = {
        let clock = ContinuousClock()
        return ProcessControlClock(
            now: { clock.now },
            sleepUntil: { deadline in
                try? await clock.sleep(until: deadline)
            }
        )
    }()
}

enum ProcessControlMath {
    static func duration(_ interval: TimeInterval) -> Duration {
        .nanoseconds(Int64(max(0, interval) * 1_000_000_000))
    }

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation == .max ? 0 : generation + 1
    }

    static func activationThreshold(for limitPercent: Double) -> Double {
        limitPercent + max(1, limitPercent * 0.1)
    }

    static func releaseThreshold(for limitPercent: Double) -> Double {
        max(0, limitPercent - max(1, limitPercent * 0.1))
    }
}

enum ApplicationCommand: Equatable, Sendable {
    case bringToFront
    case hide
    case quit
}

enum ApplicationCommandFailure: Equatable, Sendable {
    case notRunning
    case compatibilityProtected
    case restorationFailed
    case requestRejected
}

enum ApplicationCommandOutcome: Equatable, Sendable {
    case succeeded
    case failed(ApplicationCommandFailure)
}
