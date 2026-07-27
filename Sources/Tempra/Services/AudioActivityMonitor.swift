import CoreAudio
import Darwin

enum AudioOutputProbe {
    static func playingProcessIdentifiers() -> Set<pid_t> {
        Set(processObjects().compactMap { processObject in
            guard isProducingOutput(processObject: processObject) else { return nil }
            return processIdentifier(for: processObject)
        })
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

    private static func isProducingOutput(processObject: AudioObjectID) -> Bool {
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
        return status == noErr && isRunningOutput != 0
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
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
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

actor AudioActivityMonitor {
    typealias ActivityHandler = @MainActor @Sendable () -> Void

    private let backend: any AudioActivityBackend
    private var watchedProcessIdentifiers: Set<pid_t> = []
    private var processListeners: [AudioObjectID: AudioListenerToken] = [:]
    private var processListListener: AudioListenerToken?
    private var onActivityChange: ActivityHandler?

    init(backend: any AudioActivityBackend = LiveAudioActivityBackend()) {
        self.backend = backend
    }

    func watch(
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) {
        watchedProcessIdentifiers = processIdentifiers
        self.onActivityChange = onActivityChange
        updateListeners()
    }

    func stop() {
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
            guard let token = processListeners.removeValue(forKey: objectID) else { continue }
            backend.removeListener(token)
        }

        for objectID in desiredObjects where processListeners[objectID] == nil {
            let token = backend.addListener(for: .runningOutput(objectID)) { [weak self] in
                Task { await self?.notifyActivityChanged() }
            }
            processListeners[objectID] = token
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
        await notifyActivityChanged()
    }

    private func removeAllListeners() {
        processListeners.values.forEach(backend.removeListener)
        processListeners.removeAll()
        if let processListListener {
            backend.removeListener(processListListener)
            self.processListListener = nil
        }
    }

    private func notifyActivityChanged() async {
        await onActivityChange?()
    }
}
