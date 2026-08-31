import Foundation
import Testing
@testable import Tempra

@Suite("Audio output attribution")
struct AudioOutputProbeTests {
    @Test("Playing pids are expanded with their responsible processes")
    func expansionAddsResponsibleProcesses() {
        let expanded = AudioOutputProbe.expandingResponsibleProcesses(
            [99, 50],
            responsibleProcessIdentifier: { $0 == 99 ? 42 : nil }
        )
        #expect(expanded == [99, 50, 42])
    }

    @Test("Expansion keeps the original playing pids")
    func expansionPreservesOriginals() {
        let expanded = AudioOutputProbe.expandingResponsibleProcesses(
            [10],
            responsibleProcessIdentifier: { _ in nil }
        )
        #expect(expanded == [10])
    }

    @Test("Expansion matches a watched app only through its own helpers")
    func expansionMatchesOnlyTheResponsibleApp() {
        let watched: Set<pid_t> = [42, 43]

        // A helper macOS holds the watched app responsible for.
        #expect(!watched.isDisjoint(with: AudioOutputProbe.expandingResponsibleProcesses(
            [99],
            responsibleProcessIdentifier: { $0 == 99 ? 42 : nil }
        )))
        // A helper belonging to some other app.
        #expect(watched.isDisjoint(with: AudioOutputProbe.expandingResponsibleProcesses(
            [99],
            responsibleProcessIdentifier: { $0 == 99 ? 7 : nil }
        )))
        // Nothing is playing.
        #expect(watched.isDisjoint(with: AudioOutputProbe.expandingResponsibleProcesses(
            [],
            responsibleProcessIdentifier: { _ in 42 }
        )))
    }

    @Test("The live responsibility resolver never maps a process to itself")
    func resolverDoesNotMapToSelf() {
        let current = ProcessInfo.processInfo.processIdentifier
        let responsible = ProcessResponsibilityResolver.responsibleProcessIdentifier(
            for: pid_t(current)
        )
        #expect(responsible != pid_t(current))
    }
}
