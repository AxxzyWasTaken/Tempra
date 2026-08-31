import CoreAudio
import Darwin

enum ProcessAudioActivity: Equatable, Sendable {
    case active
    case inactive
    case unknown
}

/// Maps a process to the process macOS holds responsible for it. Audio is
/// often produced by helpers that are spawned by launchd rather than by the
/// app itself (for example WebKit GPU processes), so the playing pid never
/// appears among the app's own processes. The responsibility mapping is the
/// only reliable way to attribute that audio back to the app.
enum ProcessResponsibilityResolver {
    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t

    private static let responsibleForPID: ResponsibleForPID? = {
        // RTLD_DEFAULT; the constant is not importable from Swift.
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "responsibility_get_pid_responsible_for_pid"
        ) else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleForPID.self)
    }()

    static func responsibleProcessIdentifier(for processIdentifier: pid_t) -> pid_t? {
        guard let responsibleForPID else { return nil }
        let responsible = responsibleForPID(processIdentifier)
        guard responsible > 0, responsible != processIdentifier else { return nil }
        return responsible
    }
}

enum AudioOutputProbe {
    static func activity(
        for processIdentifiers: Set<pid_t>,
        responsibleProcessIdentifier: (pid_t) -> pid_t? =
            ProcessResponsibilityResolver.responsibleProcessIdentifier(for:)
    ) -> ProcessAudioActivity {
        guard !processIdentifiers.isEmpty else { return .inactive }
        var hadReadFailure = false

        // The direct lookup answers the common case without enumerating every
        // audio process, and it is the only place a per-process read failure
        // is observable.
        for processIdentifier in processIdentifiers.sorted() {
            let processObject = LiveAudioActivityBackend.processObjectResult(
                for: processIdentifier
            )
            guard processObject.status == noErr else {
                hadReadFailure = true
                continue
            }
            guard processObject.objectID != kAudioObjectUnknown else { continue }
            let output = runningOutputState(processObject: processObject.objectID)
            guard output.status == noErr else {
                hadReadFailure = true
                continue
            }
            if output.isRunning {
                return .active
            }
        }

        // Audio can come from helpers outside the app's own process set, such
        // as launchd-spawned XPC services. Attribute every playing process to
        // its responsible process and match again.
        let playing = playingProcessIdentifiers(
            responsibleProcessIdentifier: responsibleProcessIdentifier
        )
        if !processIdentifiers.isDisjoint(with: playing) {
            return .active
        }

        return hadReadFailure ? .unknown : .inactive
    }

    static func playingProcessIdentifiers(
        responsibleProcessIdentifier: (pid_t) -> pid_t? =
            ProcessResponsibilityResolver.responsibleProcessIdentifier(for:)
    ) -> Set<pid_t> {
        var playing: Set<pid_t> = []
        for processObject in processObjects() {
            let output = runningOutputState(processObject: processObject)
            guard output.status == noErr,
                  output.isRunning,
                  let playingIdentifier = processIdentifier(for: processObject) else {
                continue
            }
            playing.insert(playingIdentifier)
        }
        return expandingResponsibleProcesses(
            playing,
            responsibleProcessIdentifier: responsibleProcessIdentifier
        )
    }

    static func expandingResponsibleProcesses(
        _ playingProcessIdentifiers: Set<pid_t>,
        responsibleProcessIdentifier: (pid_t) -> pid_t?
    ) -> Set<pid_t> {
        var expanded = playingProcessIdentifiers
        for playingIdentifier in playingProcessIdentifiers {
            if let responsible = responsibleProcessIdentifier(playingIdentifier) {
                expanded.insert(responsible)
            }
        }
        return expanded
    }

    private static func processObjects() -> [AudioObjectID] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &dataSize,
            &objects
        ) == noErr else { return [] }
        return objects
    }

    private static func processIdentifier(for processObject: AudioObjectID) -> pid_t? {
        var processIdentifier: pid_t = 0
        var valueSize = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &valueSize,
            &processIdentifier
        )
        return status == noErr && processIdentifier > 0 ? processIdentifier : nil
    }

    private static func runningOutputState(
        processObject: AudioObjectID
    ) -> (status: OSStatus, isRunning: Bool) {
        var isRunningOutput: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        var outputAddress = LiveAudioActivityBackend.runningOutputAddress
        let status = AudioObjectGetPropertyData(
            processObject,
            &outputAddress,
            0,
            nil,
            &valueSize,
            &isRunningOutput
        )
        return (status, isRunningOutput != 0)
    }
}

enum AudioListenerTarget: Hashable, Sendable {
    case processList
    case runningOutput(AudioObjectID)
}

struct AudioListenerToken: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

protocol AudioActivityBackend: Sendable {
    func processObject(for processIdentifier: pid_t) -> AudioObjectID?
    func addListener(
        for target: AudioListenerTarget,
        onChange: @escaping @Sendable () -> Void
    ) -> AudioListenerToken?
    func removeListener(_ token: AudioListenerToken)
}

protocol AudioActivityMonitoring: Sendable {
    typealias ActivityHandler = @MainActor @Sendable () -> Void

    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) async
    func stop(revision: UInt64) async
}

final class LiveAudioActivityBackend: AudioActivityBackend, @unchecked Sendable {
    private struct Registration {
        let target: AudioListenerTarget
        let block: AudioObjectPropertyListenerBlock
    }

    private let listenerQueue = DispatchQueue(
        label: "io.github.temperapp.Tempra.audio-events",
        qos: .utility
    )
    private var registrations: [AudioListenerToken: Registration] = [:]

    func processObject(for processIdentifier: pid_t) -> AudioObjectID? {
        Self.processObject(for: processIdentifier)
    }

    func addListener(
        for target: AudioListenerTarget,
        onChange: @escaping @Sendable () -> Void
    ) -> AudioListenerToken? {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = Self.address(for: target)
        let objectID = Self.objectID(for: target)
        guard AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            listenerQueue,
            block
        ) == noErr else { return nil }
        let token = AudioListenerToken()
        registrations[token] = Registration(target: target, block: block)
        return token
    }

    func removeListener(_ token: AudioListenerToken) {
        guard let registration = registrations.removeValue(forKey: token) else { return }
        var address = Self.address(for: registration.target)
        AudioObjectRemovePropertyListenerBlock(
            Self.objectID(for: registration.target),
            &address,
            listenerQueue,
            registration.block
        )
    }

    fileprivate static func processObject(for processIdentifier: pid_t) -> AudioObjectID? {
        let result = processObjectResult(for: processIdentifier)
        return result.status == noErr && result.objectID != kAudioObjectUnknown
            ? result.objectID
            : nil
    }

    fileprivate static func processObjectResult(
        for processIdentifier: pid_t
    ) -> (status: OSStatus, objectID: AudioObjectID) {
        var pid = processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &pid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &objectID
            )
        }
        return (status, objectID)
    }

    fileprivate static var runningOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func address(for target: AudioListenerTarget) -> AudioObjectPropertyAddress {
        switch target {
        case .processList:
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        case .runningOutput:
            runningOutputAddress
        }
    }

    private static func objectID(for target: AudioListenerTarget) -> AudioObjectID {
        switch target {
        case .processList:
            AudioObjectID(kAudioObjectSystemObject)
        case .runningOutput(let objectID):
            objectID
        }
    }
}

actor AudioActivityMonitor: AudioActivityMonitoring {
    typealias ActivityHandler = @MainActor @Sendable () -> Void

    private struct ProcessListener {
        let id: UUID
        let token: AudioListenerToken
    }

    private let backend: any AudioActivityBackend
    private var watchedProcessIdentifiers: Set<pid_t> = []
    private var processListeners: [AudioObjectID: ProcessListener] = [:]
    private var processListListener: AudioListenerToken?
    private var onActivityChange: ActivityHandler?
    private var revision: UInt64 = 0

    init(backend: any AudioActivityBackend = LiveAudioActivityBackend()) {
        self.backend = backend
    }

    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) {
        guard revision >= self.revision else { return }
        self.revision = revision
        watchedProcessIdentifiers = processIdentifiers
        self.onActivityChange = onActivityChange
        updateListeners()
    }

    func stop(revision: UInt64) {
        guard revision >= self.revision else { return }
        self.revision = revision
        watchedProcessIdentifiers.removeAll()
        onActivityChange = nil
        removeAllListeners()
    }

    private func updateListeners() {
        guard !watchedProcessIdentifiers.isEmpty else {
            removeAllListeners()
            return
        }
        installProcessListListenerIfNeeded()

        let desiredObjects = Set(watchedProcessIdentifiers.compactMap(backend.processObject))
        for objectID in Set(processListeners.keys).subtracting(desiredObjects) {
            guard let listener = processListeners.removeValue(forKey: objectID) else { continue }
            backend.removeListener(listener.token)
        }

        for objectID in desiredObjects where processListeners[objectID] == nil {
            let listenerID = UUID()
            let token = backend.addListener(for: .runningOutput(objectID)) { [weak self] in
                Task {
                    await self?.notifyActivityChanged(
                        processObject: objectID,
                        listenerID: listenerID
                    )
                }
            }
            if let token {
                processListeners[objectID] = ProcessListener(id: listenerID, token: token)
            }
        }
    }

    private func installProcessListListenerIfNeeded() {
        guard processListListener == nil else { return }
        processListListener = backend.addListener(for: .processList) { [weak self] in
            Task { await self?.processListChanged() }
        }
    }

    private func processListChanged() async {
        updateListeners()
        await notifyActivityChanged(revision: revision)
    }

    private func removeAllListeners() {
        processListeners.values.forEach { backend.removeListener($0.token) }
        processListeners.removeAll()
        if let processListListener {
            backend.removeListener(processListListener)
            self.processListListener = nil
        }
    }

    private func notifyActivityChanged(revision: UInt64) async {
        guard revision == self.revision else { return }
        await onActivityChange?()
    }

    private func notifyActivityChanged(
        processObject: AudioObjectID,
        listenerID: UUID
    ) async {
        guard processListeners[processObject]?.id == listenerID else { return }
        await onActivityChange?()
    }
}
