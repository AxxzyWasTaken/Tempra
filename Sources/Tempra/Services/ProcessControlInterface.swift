import Dispatch
import Foundation

enum ProcessControlTickTrigger {
    case stateUpdate
    case cadence
}

struct ProcessReconciliationContext: Sendable {
    let stateID: UUID
    let revision: UInt64
}

final class ProcessControlScheduledWake: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?
    private var cancellationHandler: (@Sendable () -> Void)?
    private var isComplete = false

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldCancel = withLock {
            guard !isComplete else { return true }
            cancellationHandler = handler
            return false
        }
        if shouldCancel {
            handler()
        }
    }

    func fire() {
        complete()
    }

    func cancel() {
        complete()
    }

    private func complete() {
        let completion: (
            operation: (@Sendable () -> Void)?,
            cancellationHandler: (@Sendable () -> Void)?
        )? = withLock {
            guard !isComplete else { return nil }
            isComplete = true
            let completion = (
                operation: operation,
                cancellationHandler: cancellationHandler
            )
            operation = nil
            cancellationHandler = nil
            return completion
        }
        completion?.cancellationHandler?()
        completion?.operation?()
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

struct ProcessControlClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let scheduleWake: @Sendable (
        ContinuousClock.Instant,
        @escaping @Sendable () -> Void
    ) -> ProcessControlScheduledWake

    private static let schedulingQueue = DispatchQueue(
        label: "com.tempra.process-control-clock",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )

    static let continuous: ProcessControlClock = {
        let clock = ContinuousClock()
        return ProcessControlClock(
            now: { clock.now },
            scheduleWake: { deadline, operation in
                let wake = ProcessControlScheduledWake(operation: operation)
                let delay = max(
                    0,
                    ProcessControlMath.timeInterval(clock.now.duration(to: deadline))
                )
                let timer = DispatchSource.makeTimerSource(queue: schedulingQueue)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak wake] in
                    wake?.fire()
                }
                wake.setCancellationHandler {
                    timer.setEventHandler {}
                    timer.cancel()
                }
                timer.activate()
                return wake
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

    static let limitPeriod: TimeInterval = 0.1
    static let minimumDutyFactor: TimeInterval = 0.02
    static let dutyFactorGain: Double = 0.2
    static let firstEmptySamplePeriod: TimeInterval = 1

    static func normalizedCPUPercent(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    static func controlPeriod(
        usage: Double,
        previousDutyFactor: TimeInterval
    ) -> TimeInterval {
        let normalizedUsage = normalizedCPUPercent(usage)
        let normalizedFactor = previousDutyFactor.isFinite ? max(0, previousDutyFactor) : 0
        if normalizedUsage == 0 && normalizedFactor == 0 {
            return firstEmptySamplePeriod
        }
        return limitPeriod
    }

    static func nextDutyFactor(
        usage: Double,
        limitPercent: Double,
        previousDutyFactor: TimeInterval
    ) -> TimeInterval {
        let normalizedUsage = normalizedCPUPercent(usage)
        let normalizedLimit = normalizedCPUPercent(limitPercent)
        let previousFactor = previousDutyFactor.isFinite ? max(0, previousDutyFactor) : 0
        let error = normalizedUsage - normalizedLimit
        let period = controlPeriod(
            usage: normalizedUsage,
            previousDutyFactor: previousFactor
        )
        let seed = previousFactor == 0 && error > 0
            ? minimumDutyFactor
            : previousFactor
        let factor = seed + dutyFactorGain * error * period
        if factor > period {
            return period
        }
        if factor < minimumDutyFactor {
            return 0
        }
        return factor
    }

    static func requiredDutyFactor(
        estimatedFullSpeedCPU: Double,
        limitPercent: Double
    ) -> TimeInterval {
        let normalizedLimit = normalizedCPUPercent(limitPercent)
        let demand = max(
            normalizedCPUPercent(estimatedFullSpeedCPU),
            normalizedLimit
        )
        guard demand > 0, normalizedLimit < demand else { return 0 }
        let stopDuration = limitPeriod * (1 - normalizedLimit / demand)
        return stopDuration < minimumDutyFactor
            ? 0
            : min(limitPeriod, stopDuration)
    }
}

enum ApplicationCommand: Equatable, Sendable {
    case bringToFront
    case hide
    case quitGracefully
    case quit
    case relaunch
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
