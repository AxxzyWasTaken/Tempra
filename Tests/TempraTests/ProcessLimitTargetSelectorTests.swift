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
        #expect(selection.protectionReasons[main.identity] == [.mainProcessLifeline])
        #expect(selection.protectionReasons[network.identity] == [.networkActivity])
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
        #expect(selection.protectionReasons[newHelper.identity] == [
            .missingCPUMeasurement
        ])
    }

    @Test("A single unmeasured process remains eligible for limiting")
    func unmeasuredSingleProcessIsSelected() {
        let worker = sample(23, cpu: 80, main: true, measured: false)

        let selection = ProcessLimitTargetSelector.select(
            samples: [worker],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.alwaysRunningProcesses.isEmpty)
        #expect(selection.targetIsReachable)
        #expect(selection.protectionReasons[worker.identity] == nil)
    }

    @Test("An unmeasured helper beside a measured worker stays protected")
    func unmeasuredHelperBesideMeasuredWorkerIsProtected() {
        let worker = sample(24, cpu: 80, main: true)
        let helper = sample(25, cpu: 40, measured: false)

        let selection = ProcessLimitTargetSelector.select(
            samples: [worker, helper],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.alwaysRunningProcesses == [helper.identity])
        #expect(!selection.targetIsReachable)
        #expect(selection.protectionReasons[helper.identity] == [
            .missingCPUMeasurement
        ])
    }

    @Test("A connected single-process app remains limitable")
    func connectedSingleProcessIsSelected() {
        let onlineGame = sample(30, cpu: 80, main: true, network: .active)

        let selection = ProcessLimitTargetSelector.select(
            samples: [onlineGame],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [onlineGame.identity])
        #expect(selection.alwaysRunningProcesses.isEmpty)
        #expect(selection.targetIsReachable)
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

    @Test("A limited sample does not release the previously controlled worker")
    func constrainedSampleKeepsPreviousSelection() {
        let main = sample(53, cpu: 2, main: true)
        let worker = sample(54, cpu: 7)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, worker],
            limitPercent: 10,
            previousControlledProcesses: [worker.identity]
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.controlledLimitPercent == 8)
    }

    @Test("A CPU-heavy main process is selected instead of an idle helper")
    func cpuHeavyMainProcessIsSelected() {
        let player = sample(60, cpu: 114, main: true, network: .active)
        let crashHandler = sample(61, cpu: 0.1)

        let selection = ProcessLimitTargetSelector.select(
            samples: [player, crashHandler],
            limitPercent: 10
        )

        #expect(selection.controlledProcesses == [player.identity])
        #expect(selection.alwaysRunningProcesses == [crashHandler.identity])
        #expect(selection.targetIsReachable)
    }

    @Test("A constrained main process stays selected across monitor samples")
    func constrainedMainProcessKeepsPreviousSelection() {
        for sampledCPU in [6.5, 0.2] {
            let player = sample(62, cpu: sampledCPU, main: true)
            let crashHandler = sample(63, cpu: 0)

            let selection = ProcessLimitTargetSelector.select(
                samples: [player, crashHandler],
                limitPercent: 6,
                previousControlledProcesses: [player.identity]
            )

            #expect(selection.controlledProcesses == [player.identity])
            #expect(selection.alwaysRunningProcesses == [crashHandler.identity])
            #expect(selection.targetIsReachable)
        }
    }

    @Test("A network worker is selected when it is required to reach the target")
    func requiredNetworkWorkerIsSelected() {
        let main = sample(70, cpu: 2, main: true)
        let networkWorker = sample(71, cpu: 30)
        let renderer = sample(72, cpu: 60)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, networkWorker, renderer],
            limitPercent: 10,
            latencySensitiveProcesses: [networkWorker.identity]
        )

        #expect(selection.controlledProcesses == [networkWorker.identity, renderer.identity])
        #expect(selection.alwaysRunningProcesses == [main.identity])
        #expect(selection.targetIsReachable)
    }

    @Test("A low-CPU network helper stays running when another worker is sufficient")
    func unnecessaryNetworkHelperIsNotSelected() {
        let main = sample(73, cpu: 2, main: true)
        let networkHelper = sample(74, cpu: 1)
        let renderer = sample(75, cpu: 60)

        let selection = ProcessLimitTargetSelector.select(
            samples: [main, networkHelper, renderer],
            limitPercent: 10,
            latencySensitiveProcesses: [networkHelper.identity]
        )

        #expect(selection.controlledProcesses == [renderer.identity])
        #expect(selection.alwaysRunningProcesses == [main.identity, networkHelper.identity])
    }

    @Test("Audio activity is limitable when audio protection is disabled")
    func unprotectedAudioProcessIsSelected() {
        let mediaProcess = sample(76, cpu: 80, main: true, audio: true)

        let selection = ProcessLimitTargetSelector.select(
            samples: [mediaProcess],
            limitPercent: 10,
            protectsAudio: false
        )

        #expect(selection.controlledProcesses == [mediaProcess.identity])
    }

    @Test("Audio activity remains protected when audio protection is enabled")
    func protectedAudioProcessIsNotSelected() {
        let mediaProcess = sample(77, cpu: 80, main: true, audio: true)

        let selection = ProcessLimitTargetSelector.select(
            samples: [mediaProcess],
            limitPercent: 10,
            protectsAudio: true
        )

        #expect(selection.controlledProcesses.isEmpty)
        #expect(selection.alwaysRunningProcesses == [mediaProcess.identity])
        #expect(!selection.targetIsReachable)
        #expect(selection.protectionReasons[mediaProcess.identity] == [.audioPlayback])
    }

    @Test("Critical file activity remains limitable when the target requires it")
    func criticalFileActivityRemainsLimitable() {
        let downloader = sample(78, cpu: 20, main: true)
        let worker = sample(79, cpu: 80)

        let selection = ProcessLimitTargetSelector.select(
            samples: [downloader, worker],
            limitPercent: 10,
            criticalActivityProcesses: [downloader.identity]
        )

        #expect(selection.controlledProcesses == [downloader.identity, worker.identity])
        #expect(selection.alwaysRunningProcesses.isEmpty)
        #expect(selection.targetIsReachable)
    }

    @Test("Low-CPU critical file activity stays running when another worker is enough")
    func unnecessaryCriticalFileProcessIsNotSelected() {
        let downloader = sample(80, cpu: 1, main: true)
        let worker = sample(81, cpu: 80)

        let selection = ProcessLimitTargetSelector.select(
            samples: [downloader, worker],
            limitPercent: 10,
            criticalActivityProcesses: [downloader.identity]
        )

        #expect(selection.controlledProcesses == [worker.identity])
        #expect(selection.alwaysRunningProcesses == [downloader.identity])
        #expect(selection.targetIsReachable)
        #expect(selection.protectionReasons[downloader.identity]?.contains(
            .criticalFileActivity
        ) == true)
    }

    @Test("The responsiveness duty floor reports an unreachable exact limit")
    func responsivenessDutyFloorCanMakeTargetUnreachable() {
        let busyProcess = sample(80, cpu: 800, main: true)

        let selection = ProcessLimitTargetSelector.select(
            samples: [busyProcess],
            limitPercent: 7,
            minimumControlledDutyCycle: 0.05
        )

        #expect(selection.controlledProcesses == [busyProcess.identity])
        #expect(!selection.targetIsReachable)
    }

    private func sample(
        _ pid: Int32,
        cpu: Double,
        main: Bool = false,
        audio: Bool = false,
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
            isPlayingAudio: audio,
            networkActivity: network,
            hasCPUMeasurement: measured
        )
    }
}
