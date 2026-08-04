import Foundation

enum ProcessLimitSchedulerModel {
    enum Phase: Sendable {
        case observing
        case running
        case stopped
    }

    struct Runtime: Sendable {
        var lastCPUNanoseconds: UInt64
        var lastAccountingAt: ContinuousClock.Instant
        var runStartedAt: ContinuousClock.Instant?
        var estimatedFullSpeedCPU: Double
        var cpuCreditNanoseconds: Double
        var lastMeasuredCPUPercent: Double?
        var stoppedAt: ContinuousClock.Instant?
        var generation: UInt64
        var phase: Phase
        var processIdentities: Set<ProcessIdentity>
    }

    enum DeadlineKind: Sendable {
        case stop
        case evaluate
    }

    struct Deadline: Sendable {
        let identifier: String
        let deadline: ContinuousClock.Instant
        let generation: UInt64
        let limitPercent: Double
        let processIdentities: Set<ProcessIdentity>
        let kind: DeadlineKind
    }

    struct DeadlineQueue: Sendable {
        private var heap: [Deadline] = []
        private var indicesByIdentifier: [String: Int] = [:]

        var first: Deadline? {
            heap.first
        }

        mutating func upsert(_ entry: Deadline) {
            if let index = indicesByIdentifier[entry.identifier] {
                heap[index] = entry
                if !siftUp(from: index) {
                    siftDown(from: index)
                }
                return
            }

            let index = heap.endIndex
            heap.append(entry)
            indicesByIdentifier[entry.identifier] = index
            _ = siftUp(from: index)
        }

        @discardableResult
        mutating func remove(identifier: String) -> Deadline? {
            guard let index = indicesByIdentifier[identifier] else { return nil }
            return remove(at: index)
        }

        mutating func popFirst() -> Deadline? {
            guard !heap.isEmpty else { return nil }
            return remove(at: heap.startIndex)
        }

        mutating func removeAll() {
            heap.removeAll(keepingCapacity: true)
            indicesByIdentifier.removeAll(keepingCapacity: true)
        }

        private mutating func remove(at index: Int) -> Deadline {
            let lastIndex = heap.index(before: heap.endIndex)
            if index != lastIndex {
                swapEntries(at: index, and: lastIndex)
            }
            let removed = heap.removeLast()
            indicesByIdentifier.removeValue(forKey: removed.identifier)
            if index < heap.endIndex, !siftUp(from: index) {
                siftDown(from: index)
            }
            return removed
        }

        @discardableResult
        private mutating func siftUp(from initialIndex: Int) -> Bool {
            var index = initialIndex
            var moved = false
            while index > heap.startIndex {
                let parent = (index - 1) / 2
                guard isOrderedBefore(heap[index], heap[parent]) else { break }
                swapEntries(at: index, and: parent)
                index = parent
                moved = true
            }
            return moved
        }

        private mutating func siftDown(from initialIndex: Int) {
            var index = initialIndex
            while true {
                guard index < heap.count / 2 else { return }
                let left = index * 2 + 1
                let right = left + 1
                let candidate: Int
                if right < heap.endIndex, isOrderedBefore(heap[right], heap[left]) {
                    candidate = right
                } else {
                    candidate = left
                }
                guard isOrderedBefore(heap[candidate], heap[index]) else { return }
                swapEntries(at: index, and: candidate)
                index = candidate
            }
        }

        private mutating func swapEntries(at firstIndex: Int, and secondIndex: Int) {
            heap.swapAt(firstIndex, secondIndex)
            indicesByIdentifier[heap[firstIndex].identifier] = firstIndex
            indicesByIdentifier[heap[secondIndex].identifier] = secondIndex
        }

        private func isOrderedBefore(_ first: Deadline, _ second: Deadline) -> Bool {
            if first.deadline != second.deadline {
                return first.deadline < second.deadline
            }
            return first.identifier < second.identifier
        }
    }

    struct PulseArbiter: Sendable {
        struct Request: Sendable {
            let identifier: String
            let generation: UInt64
            let requestedAt: ContinuousClock.Instant
            let latestStart: ContinuousClock.Instant
            let isLatencySensitive: Bool
        }

        enum Decision: Sendable {
            case start(overlapsExistingPulse: Bool)
            case deferUntil(ContinuousClock.Instant)
        }

        private struct Lease: Sendable {
            let generation: UInt64
            let expectedEnd: ContinuousClock.Instant
        }

        private var leases: [String: Lease] = [:]

        var activeCount: Int {
            leases.count
        }

        mutating func decision(
            for request: Request,
            minimumGap: Duration
        ) -> Decision {
            guard leases[request.identifier] == nil else {
                return .start(overlapsExistingPulse: leases.count > 1)
            }
            guard let latestExpectedEnd = leases.values.lazy.map(\.expectedEnd).max() else {
                return .start(overlapsExistingPulse: false)
            }

            let nextOrdinaryStart = max(
                request.requestedAt.advanced(by: minimumGap),
                latestExpectedEnd.advanced(by: minimumGap)
            )
            if request.isLatencySensitive, nextOrdinaryStart > request.latestStart {
                return .start(overlapsExistingPulse: true)
            }
            return .deferUntil(nextOrdinaryStart)
        }

        mutating func acquire(
            identifier: String,
            generation: UInt64,
            expectedEnd: ContinuousClock.Instant
        ) {
            leases[identifier] = Lease(
                generation: generation,
                expectedEnd: expectedEnd
            )
        }

        mutating func release(identifier: String, generation: UInt64) {
            guard leases[identifier]?.generation == generation else { return }
            leases.removeValue(forKey: identifier)
        }

        mutating func release(identifier: String) {
            leases.removeValue(forKey: identifier)
        }

        mutating func removeAll() {
            leases.removeAll(keepingCapacity: true)
        }
    }
}
