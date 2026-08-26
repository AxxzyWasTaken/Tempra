import Foundation
import Testing
@testable import Tempra

@Suite("Audio output attribution")
struct AudioOutputProbeTests {
    @Test("A playing process that is directly watched matches")
    func directMatch() {
        #expect(AudioOutputProbe.playingProcessesMatch(
            playingProcessIdentifiers: [42],
            watchedProcessIdentifiers: [42, 43],
            responsibleProcessIdentifier: { _ in nil }
        ))
    }

    @Test("A playing helper matches through its responsible process")
    func responsibleProcessMatch() {
        #expect(AudioOutputProbe.playingProcessesMatch(
            playingProcessIdentifiers: [99],
            watchedProcessIdentifiers: [42, 43],
            responsibleProcessIdentifier: { $0 == 99 ? 42 : nil }
        ))
    }

    @Test("A playing helper responsible for an unwatched app does not match")
    func unrelatedResponsibleProcessDoesNotMatch() {
        #expect(!AudioOutputProbe.playingProcessesMatch(
            playingProcessIdentifiers: [99],
            watchedProcessIdentifiers: [42, 43],
            responsibleProcessIdentifier: { $0 == 99 ? 7 : nil }
        ))
    }

    @Test("No playing processes never match")
    func emptyPlayingSetDoesNotMatch() {
        #expect(!AudioOutputProbe.playingProcessesMatch(
            playingProcessIdentifiers: [],
            watchedProcessIdentifiers: [42],
            responsibleProcessIdentifier: { _ in 42 }
        ))
    }

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

    @Test("The live responsibility resolver never maps a process to itself")
    func resolverDoesNotMapToSelf() {
        let current = ProcessInfo.processInfo.processIdentifier
        let responsible = ProcessResponsibilityResolver.responsibleProcessIdentifier(
            for: pid_t(current)
        )
        #expect(responsible != pid_t(current))
    }
}
