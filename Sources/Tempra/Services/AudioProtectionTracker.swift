import Foundation

struct AudioProtectionTracker: Sendable {
    enum State: Equatable, Sendable {
        case playing
        case releaseDelay(until: ContinuousClock.Instant)
    }

    private var states: [String: State] = [:]

    mutating func update(
        identifier: String,
        isPlayingAudio: Bool,
        protectsAudio: Bool,
        now: ContinuousClock.Instant,
        releaseDelay: Duration
    ) -> Bool {
        guard protectsAudio else {
            states.removeValue(forKey: identifier)
            return false
        }

        if isPlayingAudio {
            states[identifier] = .playing
            return true
        }

        switch states[identifier] {
        case .playing:
            states[identifier] = .releaseDelay(until: now.advanced(by: releaseDelay))
            return true
        case .releaseDelay(let deadline) where now < deadline:
            return true
        case .releaseDelay, nil:
            states.removeValue(forKey: identifier)
            return false
        }
    }

    func state(for identifier: String) -> State? {
        states[identifier]
    }

    mutating func retain(_ shouldRetain: (String) -> Bool) {
        states = states.filter { identifier, _ in shouldRetain(identifier) }
    }

    mutating func removeAll() {
        states.removeAll()
    }
}
