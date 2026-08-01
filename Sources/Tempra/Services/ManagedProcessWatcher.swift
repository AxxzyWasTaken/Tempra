import Darwin
import Foundation

struct ProcessChangeNotification: Equatable, Sendable {
    let invalidatedMetadata: Set<ProcessIdentity>
    let processTableChanged: Bool
    let audioActivityChanged: Bool

    static let audioActivity = ProcessChangeNotification(
        invalidatedMetadata: [],
        processTableChanged: false,
        audioActivityChanged: true
    )

    static func coalescing(
        _ first: ProcessChangeNotification?,
        _ second: ProcessChangeNotification?
    ) -> ProcessChangeNotification? {
        switch (first, second) {
        case (nil, nil):
            nil
        case (let notification?, nil), (nil, let notification?):
            notification
        case (let first?, let second?):
            ProcessChangeNotification(
                invalidatedMetadata: first.invalidatedMetadata.union(
                    second.invalidatedMetadata
                ),
                processTableChanged: first.processTableChanged || second.processTableChanged,
                audioActivityChanged: first.audioActivityChanged
                    || second.audioActivityChanged
            )
        }
    }
}

@MainActor
final class ManagedProcessWatcher {
    typealias ChangeHandler = @MainActor @Sendable (ProcessChangeNotification) -> Void

    private enum AudioUpdate: Sendable {
        case watch(
            revision: UInt64,
            processIdentifiers: Set<pid_t>,
            onActivityChange: AudioActivityMonitoring.ActivityHandler
        )
        case stop(revision: UInt64)
    }

    private let audioMonitor: any AudioActivityMonitoring
    private let eventDebounceInterval: TimeInterval
    private var processEventSources: [ProcessIdentity: any DispatchSourceProcess] = [:]
    private var processChangeWorkItem: DispatchWorkItem?
    private var pendingMetadataInvalidations: Set<ProcessIdentity> = []
    private var pendingProcessTableChange = false
    private var pendingAudioUpdate: AudioUpdate?
    private var audioUpdateTask: Task<Void, Never>?
    private var watchedAudioProcessIdentifiers: Set<pid_t>?
    private var audioRevision: UInt64 = 0
    private var isStopped = false
    private var onChange: ChangeHandler?

    init(
        audioMonitor: any AudioActivityMonitoring = AudioActivityMonitor(),
        eventDebounceInterval: TimeInterval = 2
    ) {
        self.audioMonitor = audioMonitor
        self.eventDebounceInterval = eventDebounceInterval
    }

    func watch(
        processIdentities: Set<ProcessIdentity>,
        audioProcessIdentifiers: Set<pid_t>,
        onChange: @escaping ChangeHandler
    ) {
        guard !isStopped else { return }
        self.onChange = onChange
        for identity in Set(processEventSources.keys).subtracting(processIdentities) {
            processEventSources.removeValue(forKey: identity)?.cancel()
        }
        for identity in processIdentities where processEventSources[identity] == nil {
            let source = DispatchSource.makeProcessSource(
                identifier: identity.pid,
                eventMask: [.fork, .exec, .exit],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let events = source.data
                if events.contains(.exit) {
                    processEventSources.removeValue(forKey: identity)?.cancel()
                }
                handleProcessChange(
                    for: Self.notification(
                        for: events,
                        identity: identity
                    )
                )
            }
            source.resume()
            processEventSources[identity] = source
        }

        guard watchedAudioProcessIdentifiers != audioProcessIdentifiers else { return }
        watchedAudioProcessIdentifiers = audioProcessIdentifiers
        let revision = nextAudioRevision()
        enqueueAudioUpdate(.watch(
            revision: revision,
            processIdentifiers: audioProcessIdentifiers,
            onActivityChange: { [weak self] in
                guard let self,
                      !self.isStopped,
                      revision == self.audioRevision else { return }
                self.onChange?(.audioActivity)
            }
        ))
    }

    func stop() async {
        guard !isStopped else {
            await audioUpdateTask?.value
            return
        }
        isStopped = true
        processChangeWorkItem?.cancel()
        processChangeWorkItem = nil
        pendingMetadataInvalidations.removeAll()
        pendingProcessTableChange = false
        watchedAudioProcessIdentifiers = nil
        processEventSources.values.forEach { $0.cancel() }
        processEventSources.removeAll()
        onChange = nil
        enqueueAudioUpdate(.stop(revision: nextAudioRevision()))
        await audioUpdateTask?.value
    }

    static func notification(
        for events: DispatchSource.ProcessEvent,
        identity: ProcessIdentity
    ) -> ProcessChangeNotification {
        ProcessChangeNotification(
            invalidatedMetadata: events.contains(.exec) || events.contains(.exit)
                ? [identity]
                : [],
            processTableChanged: true,
            audioActivityChanged: false
        )
    }

    func handleProcessChange(for notification: ProcessChangeNotification) {
        guard !isStopped else { return }
        pendingMetadataInvalidations.formUnion(notification.invalidatedMetadata)
        pendingProcessTableChange = pendingProcessTableChange || notification.processTableChanged
        guard processChangeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            processChangeWorkItem = nil
            let notification = ProcessChangeNotification(
                invalidatedMetadata: pendingMetadataInvalidations,
                processTableChanged: pendingProcessTableChange,
                audioActivityChanged: false
            )
            pendingMetadataInvalidations.removeAll()
            pendingProcessTableChange = false
            onChange?(notification)
        }
        processChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + eventDebounceInterval,
            execute: workItem
        )
    }

    private func nextAudioRevision() -> UInt64 {
        if audioRevision < UInt64.max {
            audioRevision += 1
        }
        return audioRevision
    }

    private func enqueueAudioUpdate(_ update: AudioUpdate) {
        pendingAudioUpdate = update
        startAudioUpdateTaskIfNeeded()
    }

    private func startAudioUpdateTaskIfNeeded() {
        guard audioUpdateTask == nil else { return }
        audioUpdateTask = Task { [weak self] in
            guard let self else { return }
            while let update = self.pendingAudioUpdate {
                self.pendingAudioUpdate = nil
                switch update {
                case .watch(let revision, let processIdentifiers, let onActivityChange):
                    await self.audioMonitor.watch(
                        revision: revision,
                        processIdentifiers: processIdentifiers,
                        onActivityChange: onActivityChange
                    )
                case .stop(let revision):
                    await self.audioMonitor.stop(revision: revision)
                }
            }
            self.audioUpdateTask = nil
            if self.pendingAudioUpdate != nil {
                self.startAudioUpdateTaskIfNeeded()
            }
        }
    }
}
