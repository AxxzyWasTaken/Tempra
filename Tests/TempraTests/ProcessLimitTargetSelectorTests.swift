import Foundation
import Testing
@testable import Tempra

@Suite("Process limit target selector")
struct ProcessLimitTargetSelectorTests {
    @Test("Spotify-shaped groups limit only the expensive renderer")
    func spotifyRendererIsSelected() throws {
        let main = sample(1, cpu: 3, main: true)
        let renderer = sample(2, cpu: 55)
        let network = sample(3, cpu: 0.4, network: .active)
        let storage = sample(4, cpu: 0.2)
        let media = sample(5, cpu: 0.2)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, renderer, network, storage, media],
            limitPercent: 9
        )

        #expect(selection.controlledProcesses == [renderer.identity])
        #expect(selection.alwaysRunningProcesses == [
            main.identity, network.identity, storage.identity, media.identity
        ])
        #expect(abs(selection.alwaysRunningCPUPercent - 3.8) < 0.000_001)
        #expect(abs(selection.controlledLimitPercent - 5.2) < 0.000_001)
        #expect(selection.targetIsReachable)
    }

    @Test("The smallest sufficient set of expensive workers is selected")
    func smallestSufficientSetIsSelected() {
        let main = sample(10, cpu: 2, main: true)
        let renderer = sample(11, cpu: 60)
        let worker = sample(12, cpu: 30)
        let network = sample(13, cpu: 1, network: .active)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, renderer, worker, network],
            limitPercent: 9
        )

        #expect(selection.controlledProcesses == [renderer.identity, worker.identity])
        #expect(selection.alwaysRunningProcesses == [main.identity, network.identity])
        #expect(selection.controlledLimitPercent == 6)
    }

    @Test("A new helper remains protected until it has a CPU measurement")
    func newHelperIsProtected() {
        let main = sample(20, cpu: 1, main: true)
        let establishedWorker = sample(21, cpu: 50)
        let newHelper = sample(22, cpu: 40, measured: false)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, establishedWorker, newHelper],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [establishedWorker.identity])
        #expect(selection.alwaysRunningProcesses.contains(newHelper.identity))
        #expect(!selection.targetIsReachable)
    }

    @Test("A connected single-process app waits instead of being stopped")
    func connectedSingleProcessIsProtected() {
        let onlineGame = sample(30, cpu: 80, main: true, network: .active)

        let selection = ProcessLimitTargetSelector.select(
            samples: [onlineGame],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses.isEmpty)
        #expect(selection.alwaysRunningProcesses == [onlineGame.identity])
        #expect(!selection.targetIsReachable)
    }

    @Test("An offline single-process app remains limitable")
    func offlineSingleProcessIsSelected() {
        let worker = sample(40, cpu: 80, main: true)

        let selection = ProcessLimitTargetSelector.select(
            samples: [worker],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.controlledLimitPercent == 10)
        #expect(selection.targetIsReachable)
    }

    @Test("A still-effective previous selection does not churn")
    func previousSelectionRemainsStable() {
        let main = sample(50, cpu: 1, main: true)
        let firstWorker = sample(51, cpu: 11)
        let secondWorker = sample(52, cpu: 10)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, firstWorker, secondWorker],
            limitPercent: 12,
            previousControlledProcesses: [secondWorker.identity]
        )

        #expect(selection.controlledProcesses == [secondWorker.identity])
    }

    @Test("A multi-process app always retains a coordinator lifeline")
    func coordinatorLifelineIsRetained() {
        let main = sample(60, cpu: 100, main: true)
        let worker = sample(61, cpu: 100)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, worker],
            limitPercent: 1
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.alwaysRunningProcesses == [main.identity])
        #expect(!selection.targetIsReachable)
    }

    private func sample(
        _ pid: Int32,
        cpu: Double,
        main: Bool = false,
        network: ProcessNetworkActivity = .inactive,
        measured: Bool = true
    ) -> ManagedProcessSample {
        ManagedProcessSample(
            identity: ProcessIdentity(
                pid: pid,
                startTimeMicroseconds: UInt64(pid) * 1_000_000
            ),
            cpuPercent: cpu,
            isMainProcess: main,
            networkActivity: network,
            hasCPUMeasurement: measured
        )
    }
}
