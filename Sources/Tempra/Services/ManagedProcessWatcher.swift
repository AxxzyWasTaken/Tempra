import Darwin
import Foundation

struct ProcessChangeNotification: Equatable, Sendable {
    let invalidatedMetadata: Set<ProcessIdentity>
    let processTableChanged: Bool

    static let audioActivity = ProcessChangeNotification(
        invalidatedMetadata: [],
        processTableChanged: false
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
                processTableChanged: first.processTableChanged || second.processTableChanged
            )
        }
    }
}

@MainActor
final class ManagedProcessWatcher {
    typealias ChangeHandler = @MainActor @Sendable (ProcessChangeNotification) -> Void

    private let audioMonitor: AudioActivityMonitor
    private let minimumRefreshInterval: TimeInterval = 5
    private let eventDebounceInterval: TimeInterval = 0.1
    private var processEventSources: [ProcessIdentity: any DispatchSourceProcess] = [:]
    private var processChangeWorkItem: DispatchWorkItem?
    private var pendingMetadataInvalidations: Set<ProcessIdentity> = []
    private var pendingProcessTableChange = false
    private var lastRefreshTime: TimeInterval = 0
    private var onChange: ChangeHandler?

    init(audioMonitor: AudioActivityMonitor = AudioActivityMonitor()) {
        self.audioMonitor = audioMonitor
    }

    func watch(
        processIdentities: Set<ProcessIdentity>,
        audioProcessIdentifiers: Set<pid_t>,
        onChange: @escaping ChangeHandler
    ) {
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
                scheduleRefresh(
                    for: Self.notification(
                        for: events,
                        identity: identity
                    )
                )
            }
            source.resume()
            processEventSources[identity] = source
        }

        Task { [audioMonitor] in
            await audioMonitor.watch(
                processIdentifiers: audioProcessIdentifiers,
                onActivityChange: { onChange(.audioActivity) }
            )
        }
    }

    func stop() async {
        processChangeWorkItem?.cancel()
        processChangeWorkItem = nil
        pendingMetadataInvalidations.removeAll()
        pendingProcessTableChange = false
        processEventSources.values.forEach { $0.cancel() }
        processEventSources.removeAll()
        onChange = nil
        await audioMonitor.stop()
    }

    static func notification(
        for events: DispatchSource.ProcessEvent,
        identity: ProcessIdentity
    ) -> ProcessChangeNotification {
        ProcessChangeNotification(
            invalidatedMetadata: events.contains(.exec) || events.contains(.exit)
                ? [identity]
                : [],
            processTableChanged: true
        )
    }

    private func scheduleRefresh(for notification: ProcessChangeNotification) {
        pendingMetadataInvalidations.formUnion(notification.invalidatedMetadata)
        pendingProcessTableChange = pendingProcessTableChange || notification.processTableChanged
        guard processChangeWorkItem == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(
            eventDebounceInterval,
            lastRefreshTime + minimumRefreshInterval - now
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            processChangeWorkItem = nil
            lastRefreshTime = ProcessInfo.processInfo.systemUptime
            let notification = ProcessChangeNotification(
                invalidatedMetadata: pendingMetadataInvalidations,
                processTableChanged: pendingProcessTableChange
            )
            pendingMetadataInvalidations.removeAll()
            pendingProcessTableChange = false
            onChange?(notification)
        }
        processChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
