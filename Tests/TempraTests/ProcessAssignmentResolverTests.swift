import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process assignment resolver")
struct ProcessAssignmentResolverTests {
    @Test("Longest path prefix wins before main-process ancestry")
    func longestPathPrefixAndParentPrecedence() {
        let bundles = fixtureBundles()
        let processes = [
            process(31, parent: 30, path: ""),
            process(20, parent: 1, path: nestedExecutable),
            process(11, parent: 1, path: nestedExecutable),
            process(33, parent: 1, path: nestedExecutable),
            process(10, parent: 1, path: hostExecutable),
            process(30, parent: 10, path: nestedExecutable),
            process(32, parent: 11, path: "/tmp/host-helper"),
            process(34, parent: 1, path: hostPath),
            process(35, parent: 1, path: hostPath + "ish/Contents/MacOS/Other"),
        ]

        let assignments = normalized(ProcessAssignmentResolver.assignments(
            processes: processes,
            bundles: bundles
        ))

        #expect(assignments[hostIdentifier] == [10, 11, 31, 32])
        #expect(assignments[nestedIdentifier] == [20, 30, 33])
        #expect(!assignments.values.contains { $0.contains(34) || $0.contains(35) })
    }

    @Test("Cycles and missing parents remain unassigned")
    func cyclesAndMissingParents() {
        let processes = [
            process(10, parent: 1, path: hostExecutable),
            process(40, parent: 41, path: ""),
            process(41, parent: 40, path: ""),
            process(42, parent: 999, path: ""),
            process(43, parent: 10, path: ""),
        ]

        let assignments = normalized(ProcessAssignmentResolver.assignments(
            processes: processes,
            bundles: fixtureBundles()
        ))

        #expect(assignments[hostIdentifier] == [10, 43])
        #expect(!assignments.values.contains { pids in
            pids.contains(40) || pids.contains(41) || pids.contains(42)
        })
    }

    @Test("Arbitrary process order matches the previous assignment algorithm")
    func arbitraryOrderMatchesLegacy() {
        let bundles = fixtureBundles()
        let originalProcesses = [
            process(10, parent: 1, path: hostExecutable),
            process(11, parent: 1, path: hostExecutable),
            process(20, parent: 1, path: nestedExecutable),
            process(30, parent: 10, path: nestedExecutable),
            process(31, parent: 30, path: ""),
            process(32, parent: 31, path: "/tmp/descendant"),
            process(40, parent: 41, path: ""),
            process(41, parent: 40, path: ""),
            process(42, parent: 999, path: ""),
        ]
        var generator = AssignmentSeededGenerator(seed: 0xA551_6EED)

        for iteration in 0..<100 {
            let processes = originalProcesses.shuffled(using: &generator)
            let expected = normalized(legacyAssignments(
                processes: processes,
                bundles: bundles
            ))
            let actual = normalized(ProcessAssignmentResolver.assignments(
                processes: processes,
                bundles: bundles
            ))
            #expect(actual == expected, "Assignment differed for shuffle \(iteration).")
        }
    }

    @Test("A large synthetic process tree assignment benchmark")
    func largeProcessTreeBenchmark() {
        let bundleCount = 128
        let descendantCount = 5_000
        let bundles = (0..<bundleCount).map { index in
            ProcessAssignmentResolver.Bundle(
                identifier: "example.app.\(index)",
                path: "/Applications/App\(index).app",
                mainPIDs: [pid_t(index + 2)]
            )
        }
        let rootPID = pid_t(2)
        var descendants: [ProcessAssignmentResolver.Process] = []
        var parentPID = rootPID
        for offset in 0..<descendantCount {
            let pid = pid_t(10_000 + offset)
            descendants.append(process(
                pid,
                parent: parentPID,
                path: "/tmp/process-\(pid)"
            ))
            parentPID = pid
        }
        let processes = [process(rootPID, parent: 1, path: hostExecutable)]
            + descendants.reversed()
        let clock = ContinuousClock()

        let legacyStart = clock.now
        let legacy = normalized(legacyAssignments(processes: processes, bundles: bundles))
        let legacyElapsed = legacyStart.duration(to: clock.now)

        let optimizedStart = clock.now
        let optimized = normalized(ProcessAssignmentResolver.assignments(
            processes: processes,
            bundles: bundles
        ))
        let optimizedElapsed = optimizedStart.duration(to: clock.now)

        #expect(optimized == legacy)
        #expect(optimized["example.app.0"]?.count == descendantCount + 1)
        print(
            "Process assignment benchmark: \(processes.count) processes, "
                + "\(bundleCount) bundles; legacy \(legacyElapsed); "
                + "indexed \(optimizedElapsed)"
        )
    }

    private var hostIdentifier: String { "example.host" }
    private var nestedIdentifier: String { "example.nested" }
    private var hostPath: String { "/Applications/Host.app" }
    private var nestedPath: String {
        hostPath + "/Contents/PlugIns/Nested.app"
    }
    private var hostExecutable: String {
        hostPath + "/Contents/MacOS/Host"
    }
    private var nestedExecutable: String {
        nestedPath + "/Contents/MacOS/Nested"
    }

    private func fixtureBundles() -> [ProcessAssignmentResolver.Bundle] {
        [
            ProcessAssignmentResolver.Bundle(
                identifier: hostIdentifier,
                path: hostPath,
                mainPIDs: [10, 11]
            ),
            ProcessAssignmentResolver.Bundle(
                identifier: nestedIdentifier,
                path: nestedPath,
                mainPIDs: [20]
            ),
        ]
    }

    private func process(
        _ pid: pid_t,
        parent parentPID: pid_t,
        path: String
    ) -> ProcessAssignmentResolver.Process {
        ProcessAssignmentResolver.Process(
            pid: pid,
            parentPID: parentPID,
            path: path
        )
    }

    private func normalized(
        _ assignments: [String: [pid_t]]
    ) -> [String: [pid_t]] {
        assignments.mapValues { $0.sorted() }
    }

    private func legacyAssignments(
        processes: [ProcessAssignmentResolver.Process],
        bundles: [ProcessAssignmentResolver.Bundle]
    ) -> [String: [pid_t]] {
        var result: [String: [pid_t]] = [:]
        var mainPIDMap: [pid_t: String] = [:]
        for bundle in bundles {
            for pid in bundle.mainPIDs {
                mainPIDMap[pid] = bundle.identifier
            }
        }
        let bundleIdentifiers = Set(bundles.map(\.identifier))
        let bundlePathPrefixes = bundles.map {
            (identifier: $0.identifier, prefix: $0.path + "/")
        }.sorted { $0.prefix.count > $1.prefix.count }
        var processByPID: [pid_t: ProcessAssignmentResolver.Process] = [:]
        for process in processes {
            processByPID[process.pid] = process
        }

        for process in processes {
            var identifier = mainPIDMap[process.pid]
            if identifier == nil, !process.path.isEmpty {
                identifier = bundlePathPrefixes.first(where: {
                    process.path.hasPrefix($0.prefix)
                })?.identifier
            }
            if identifier == nil {
                var parentPID = process.parentPID
                var visited: Set<pid_t> = []
                while parentPID > 1, visited.insert(parentPID).inserted {
                    if let parentIdentifier = mainPIDMap[parentPID] {
                        identifier = parentIdentifier
                        break
                    }
                    guard let parentProcess = processByPID[parentPID] else { break }
                    parentPID = parentProcess.parentPID
                }
            }
            if let identifier, bundleIdentifiers.contains(identifier) {
                result[identifier, default: []].append(process.pid)
            }
        }
        return result
    }
}

private struct AssignmentSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
