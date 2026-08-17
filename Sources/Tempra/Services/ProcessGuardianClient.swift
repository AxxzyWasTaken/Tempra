import Darwin
import Foundation
import OSLog
import ServiceManagement
import TempraSafety

protocol ProcessGuardianControlling: Sendable {
    func prepare(_ processes: Set<ProcessIdentity>) async throws
    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronize(_ processes: Set<ProcessIdentity>) async throws
    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult
    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult
    func disarm() async throws
    func renewLeaseIfConnected() async throws
    func invalidate() async
}

struct ProcessGuardianProtectionState: Equatable, Sendable {
    private(set) var guardianInstanceID: UUID?
    private(set) var protectedProcesses: Set<ProcessIdentity> = []
    private(set) var restoredProcesses: Set<ProcessIdentity> = []
    private(set) var connectionRecoveryIsPending = false

    mutating func connected(to instanceID: UUID) {
        let guardianChanged = guardianInstanceID.map { $0 != instanceID } == true
        guardianInstanceID = instanceID
        if guardianChanged || connectionRecoveryIsPending {
            restoredProcesses.formUnion(protectedProcesses)
            protectedProcesses.removeAll()
        }
        connectionRecoveryIsPending = false
    }

    mutating func connectionLost() {
        if !protectedProcesses.isEmpty {
            connectionRecoveryIsPending = true
        }
    }

    mutating func prepared(
        _ requested: Set<ProcessIdentity>,
        stale: Set<ProcessIdentity>
    ) {
        let guarded = requested.subtracting(stale)
        protectedProcesses.formUnion(guarded)
        restoredProcesses.subtract(guarded)
    }

    func processesRequiringPreparation(
        from requested: Set<ProcessIdentity>
    ) -> Set<ProcessIdentity> {
        guard !connectionRecoveryIsPending else { return requested }
        return requested.subtracting(protectedProcesses)
    }

    func requiresSynchronization(
        with requested: Set<ProcessIdentity>
    ) -> Bool {
        guardianInstanceID == nil
            || connectionRecoveryIsPending
            || !restoredProcesses.isEmpty
            || protectedProcesses != requested
    }

    mutating func synchronized(
        _ requested: Set<ProcessIdentity>,
        stale: Set<ProcessIdentity>
    ) {
        protectedProcesses = requested.subtracting(stale)
        restoredProcesses.subtract(protectedProcesses)
    }

    mutating func stopped(_ processes: Set<ProcessIdentity>) {
        protectedProcesses.formUnion(processes)
        restoredProcesses.subtract(processes)
    }

    mutating func takeRestored(
        from requested: Set<ProcessIdentity>
    ) -> Set<ProcessIdentity> {
        let restored = requested.intersection(restoredProcesses)
        restoredProcesses.subtract(restored)
        return restored
    }

    func resumeSelection(
        from requested: Set<ProcessIdentity>
    ) -> (requiresGuardian: Set<ProcessIdentity>, alreadyRunning: Set<ProcessIdentity>) {
        let requiresGuardian = requested.intersection(protectedProcesses)
        return (
            requiresGuardian: requiresGuardian,
            alreadyRunning: requested.subtracting(requiresGuardian)
        )
    }

    mutating func resumed(_ processes: Set<ProcessIdentity>) {
        protectedProcesses.subtract(processes)
        restoredProcesses.subtract(processes)
    }

    mutating func disarmed() {
        protectedProcesses.removeAll()
        restoredProcesses.removeAll()
        connectionRecoveryIsPending = false
    }
}

enum ProcessGuardianClientError: LocalizedError, Sendable {
    case serviceNotEnabled
    case serviceRequiresApproval
    case guardianMissing
    case invalidCodeSignature(String)
    case connectionFailed(String)
    case registrationFailed(String)
    case timedOut
    case invalidRequest
    case invalidResponse
    case revisionExhausted
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotEnabled:
            "The process guardian is not enabled."
        case .serviceRequiresApproval:
            "Approve Tempra in System Settings › General › Login Items."
        case .guardianMissing:
            "Tempra’s process guardian is missing from the app bundle."
        case .invalidCodeSignature(let detail):
            "Tempra could not verify its process guardian: \(detail)"
        case .connectionFailed(let detail):
            "Tempra could not connect to its process guardian: \(detail)"
        case .registrationFailed(let detail):
            "Tempra could not register its process guardian: \(detail)"
        case .timedOut:
            "The process guardian did not respond in time."
        case .invalidRequest:
            "Tempra created an invalid process guardian request."
        case .invalidResponse:
            "The process guardian returned an invalid response."
        case .revisionExhausted:
            "The process guardian request revision is exhausted."
        case .remoteFailure(let detail):
            detail
        }
    }
}

private final class ProcessGuardianReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var pendingResult: Result<Data, any Error>?

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Data, any Error>) {
        lock.lock()
        guard let continuation else {
            if pendingResult == nil {
                pendingResult = result
            }
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private struct ProcessGuardianRegistrationIdentity: Codable, Equatable, Sendable {
    let executableCodeIdentifier: Data
    let servicePropertyList: Data
}

private struct ProcessGuardianJournalSummary: Decodable {
    let version: Int
    let trackedProcesses: [WatchdogProcessIdentity]

    var isValid: Bool {
        version == ProcessGuardianProtocol.journalSchemaVersion
            && trackedProcesses.count
                <= ProcessGuardianProtocol.maximumProcessCount
            && Set(trackedProcesses).count == trackedProcesses.count
            && Set(trackedProcesses.map(\.pid)).count == trackedProcesses.count
            && trackedProcesses.allSatisfy {
                $0.pid > 1 && $0.startTimeMicroseconds > 0
            }
    }
}

struct ProcessGuardianJournalProbe {
    let fileURL: URL

    static func live() throws -> Self {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(fileURL: applicationSupportURL
            .appendingPathComponent(
                ProcessGuardianProtocol.applicationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent(ProcessGuardianProtocol.journalFileName))
    }

    func isClear() throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return true
        }

        let data: Data
        do {
            data = try handle.read(
                upToCount: ProcessGuardianProtocol.maximumFrameBytes + 1
            ) ?? Data()
        } catch {
            let readError = error
            do {
                try handle.close()
            } catch {
                throw error
            }
            throw readError
        }
        try handle.close()

        guard !data.isEmpty,
              data.count <= ProcessGuardianProtocol.maximumFrameBytes,
              let summary = try? JSONDecoder().decode(
                  ProcessGuardianJournalSummary.self,
                  from: data
              ),
              summary.isValid else {
            throw ProcessGuardianClientError.invalidResponse
        }
        return summary.trackedProcesses.isEmpty
    }
}

private struct ProcessGuardianRegistrationStore: Sendable {
    let fileURL: URL

    static func live() throws -> Self {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(fileURL: applicationSupportURL
            .appendingPathComponent(
                ProcessGuardianProtocol.applicationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("process-guardian-registration.json"))
    }

    func load() throws -> ProcessGuardianRegistrationIdentity? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        let data: Data
        do {
            data = try handle.read(
                upToCount: ProcessGuardianProtocol.maximumFrameBytes + 1
            ) ?? Data()
        } catch {
            let readError = error
            do {
                try handle.close()
            } catch {
                throw error
            }
            throw readError
        }
        try handle.close()
        guard data.count <= ProcessGuardianProtocol.maximumFrameBytes,
              let identity = try? JSONDecoder().decode(
                  ProcessGuardianRegistrationIdentity.self,
                  from: data
              ) else {
            throw ProcessGuardianClientError.invalidResponse
        }
        return identity
    }

    func save(_ identity: ProcessGuardianRegistrationIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        guard data.count <= ProcessGuardianProtocol.maximumFrameBytes else {
            throw ProcessGuardianClientError.invalidResponse
        }
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

private enum ProcessGuardianBundle {
    private static let executableName = "TempraWatchdog"

    static var servicePropertyListURL: URL {
        contentsURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(ProcessGuardianProtocol.agentPlistName)
    }

    static var executableURL: URL {
        contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
    }

    static func registrationIdentity() throws -> ProcessGuardianRegistrationIdentity {
        guard FileManager.default.fileExists(atPath: servicePropertyListURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessGuardianClientError.guardianMissing
        }
        return ProcessGuardianRegistrationIdentity(
            executableCodeIdentifier: try TempraCodeSigningRequirement
                .staticCodeIdentifier(at: executableURL),
            servicePropertyList: try Data(
                contentsOf: servicePropertyListURL,
                options: .mappedIfSafe
            )
        )
    }

    private static var contentsURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    }
}

private struct ProcessGuardianPreparation: Sendable {
    let didRefresh: Bool
}

@MainActor
private final class ProcessGuardianLifecycle {
    static let shared = ProcessGuardianLifecycle()

    private let service = SMAppService.agent(
        plistName: ProcessGuardianProtocol.agentPlistName
    )
    private var cachedCurrentIdentity: ProcessGuardianRegistrationIdentity?
    private var cachedRegisteredIdentity: ProcessGuardianRegistrationIdentity?
    private var loadedRegisteredIdentity = false
    private var pendingPreparation:
        (id: UUID, task: Task<ProcessGuardianPreparation, any Error>)?

    func prepareForRequest() async throws -> ProcessGuardianPreparation {
        if let pendingPreparation {
            return try await pendingPreparation.task.value
        }
        let preparationID = UUID()
        let task = Task { @MainActor [self] in
            try await performPreparation()
        }
        pendingPreparation = (preparationID, task)
        do {
            let result = try await task.value
            clearPreparation(preparationID)
            return result
        } catch {
            clearPreparation(preparationID)
            throw error
        }
    }

    private func performPreparation() async throws -> ProcessGuardianPreparation {
        let initialStatus = service.status
        switch initialStatus {
        case .enabled, .notRegistered, .notFound:
            break
        case .requiresApproval:
            throw ProcessGuardianClientError.serviceRequiresApproval
        @unknown default:
            throw ProcessGuardianClientError.serviceNotEnabled
        }

        let currentIdentity = try await resolvedCurrentIdentity()
        if initialStatus == .notRegistered || initialStatus == .notFound {
            try await register(currentIdentity)
            return try validatePreparation(didRefresh: true)
        }
        if try await registeredIdentity() == currentIdentity {
            return ProcessGuardianPreparation(didRefresh: false)
        }

        let journalIsClear = try await Task.detached(priority: .utility) {
            try ProcessGuardianJournalProbe.live().isClear()
        }.value
        guard journalIsClear else {
            throw ProcessGuardianClientError.registrationFailed(
                "The existing process guardian still protects a managed process."
            )
        }

        do {
            try await service.unregister()
        } catch {
            throw ProcessGuardianClientError.registrationFailed(
                error.localizedDescription
            )
        }
        try await register(currentIdentity)
        return try validatePreparation(didRefresh: true)
    }

    private func register(
        _ identity: ProcessGuardianRegistrationIdentity
    ) async throws {
        do {
            try await Task.detached(priority: .utility) {
                try SMAppService.agent(
                    plistName: ProcessGuardianProtocol.agentPlistName
                ).register()
            }.value
        } catch {
            if service.status == .requiresApproval {
                try saveRegisteredIdentity(identity)
                throw ProcessGuardianClientError.serviceRequiresApproval
            }
            throw ProcessGuardianClientError.registrationFailed(
                error.localizedDescription
            )
        }
        try saveRegisteredIdentity(identity)
    }

    private func validatePreparation(
        didRefresh: Bool
    ) throws -> ProcessGuardianPreparation {
        switch service.status {
        case .enabled:
            return ProcessGuardianPreparation(didRefresh: didRefresh)
        case .requiresApproval:
            throw ProcessGuardianClientError.serviceRequiresApproval
        case .notRegistered, .notFound:
            throw ProcessGuardianClientError.serviceNotEnabled
        @unknown default:
            throw ProcessGuardianClientError.serviceNotEnabled
        }
    }

    private func resolvedCurrentIdentity() async throws
        -> ProcessGuardianRegistrationIdentity {
        if let cachedCurrentIdentity { return cachedCurrentIdentity }
        let identity = try await Task.detached(priority: .utility) {
            try ProcessGuardianBundle.registrationIdentity()
        }.value
        cachedCurrentIdentity = identity
        return identity
    }

    private func registeredIdentity() async throws
        -> ProcessGuardianRegistrationIdentity? {
        if loadedRegisteredIdentity { return cachedRegisteredIdentity }
        let identity = try await Task.detached(priority: .utility) {
            try ProcessGuardianRegistrationStore.live().load()
        }.value
        cachedRegisteredIdentity = identity
        loadedRegisteredIdentity = true
        return identity
    }

    private func saveRegisteredIdentity(
        _ identity: ProcessGuardianRegistrationIdentity
    ) throws {
        try ProcessGuardianRegistrationStore.live().save(identity)
        cachedRegisteredIdentity = identity
        loadedRegisteredIdentity = true
    }

    private func clearPreparation(_ preparationID: UUID) {
        guard pendingPreparation?.id == preparationID else { return }
        pendingPreparation = nil
    }
}

actor ProcessGuardianClient: ProcessGuardianControlling {
    static let shared = ProcessGuardianClient()

    private let sessionID = UUID()
    private let requestTimeout: Duration
    private var revision: UInt64 = 0
    private var connection: NSXPCConnection?
    private var connectionIsHandshaken = false
    private var cachedPeerRequirement: String?
    private var protectionState = ProcessGuardianProtectionState()
    private var automaticResumeIntervals: [ProcessIdentity: TimeInterval] = [:]

    init(requestTimeout: Duration = .seconds(4)) {
        self.requestTimeout = requestTimeout
    }

    func prepare(_ processes: Set<ProcessIdentity>) async throws {
        let processesToPrepare = protectionState.processesRequiringPreparation(
            from: processes
        )
        guard !processesToPrepare.isEmpty else { return }
        let response = try await perform(.prepare, processes: processesToPrepare)
        let mapped = try mappedOperationState(response, among: processesToPrepare)
        try requireSuccessfulStateResponse(response)
        protectionState.prepared(processesToPrepare, stale: mapped.stale)
    }

    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {
        let response = try await perform(
            .armResume,
            resumeDeadlines: try Self.resumeDeadlines(for: intervalsByProcess)
        )
        try requireSuccessfulStateResponse(response)
        try requireEmptyOperationState(response)
        automaticResumeIntervals.merge(
            intervalsByProcess,
            uniquingKeysWith: { _, newValue in newValue }
        )
    }

    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {
        guard Self.requiresAutomaticResumeSynchronization(
            requested: intervalsByProcess,
            cached: automaticResumeIntervals,
            connectionIsCurrent: protectionState.guardianInstanceID != nil
                && !protectionState.connectionRecoveryIsPending
        ) else { return }
        let response = try await perform(
            .synchronizeResume,
            resumeDeadlines: try Self.resumeDeadlines(for: intervalsByProcess)
        )
        try requireSuccessfulStateResponse(response)
        try requireEmptyOperationState(response)
        automaticResumeIntervals = intervalsByProcess
    }

    func synchronize(_ processes: Set<ProcessIdentity>) async throws {
        guard protectionState.requiresSynchronization(with: processes) else {
            return
        }
        let knownProcesses = processes
            .union(protectionState.protectedProcesses)
            .union(protectionState.restoredProcesses)
        let response = try await perform(.synchronize, processes: processes)
        let mapped = try mappedOperationState(response, among: knownProcesses)
        try requireSuccessfulStateResponse(response)
        protectionState.synchronized(
            processes,
            stale: mapped.stale.intersection(processes)
        )
        automaticResumeIntervals = automaticResumeIntervals.filter {
            protectionState.protectedProcesses.contains($0.key)
        }
    }

    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult {
        let deadlines: [WatchdogResumeDeadline]
        do {
            if let automaticResumeAfter {
                deadlines = try Self.resumeDeadlines(
                    for: Dictionary(uniqueKeysWithValues: processes.map {
                        ($0, automaticResumeAfter)
                    })
                )
            } else {
                deadlines = []
            }
            let response = try await perform(
                .stop,
                processes: processes,
                resumeDeadlines: deadlines
            )
            let result = try operationResult(response, requested: processes)
            protectionState.stopped(result.applied)
            protectionState.resumed(result.stale)
            if let automaticResumeAfter {
                for process in result.applied {
                    automaticResumeIntervals[process] = automaticResumeAfter
                }
            }
            for process in result.stale.union(result.failed) {
                automaticResumeIntervals.removeValue(forKey: process)
            }
            return result
        } catch {
            return ProcessOperationResult(
                failed: processes,
                failureDescription: error.localizedDescription
            )
        }
    }

    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        var selection = protectionState.resumeSelection(from: processes)
        protectionState.resumed(selection.alreadyRunning)
        guard !selection.requiresGuardian.isEmpty else {
            return ProcessOperationResult(applied: selection.alreadyRunning)
        }
        do {
            let connection = try await readyConnection()
            selection = protectionState.resumeSelection(from: processes)
            protectionState.resumed(selection.alreadyRunning)
            guard !selection.requiresGuardian.isEmpty else {
                return ProcessOperationResult(applied: selection.alreadyRunning)
            }
            let response = try await sendRequest(
                .resume,
                processes: selection.requiresGuardian,
                through: connection
            )
            var result = try operationResult(
                response,
                requested: selection.requiresGuardian
            )
            protectionState.resumed(result.applied.union(result.stale))
            for process in result.applied.union(result.stale) {
                automaticResumeIntervals.removeValue(forKey: process)
            }
            result.applied.formUnion(selection.alreadyRunning)
            return result
        } catch {
            return ProcessOperationResult(
                applied: selection.alreadyRunning,
                failed: selection.requiresGuardian,
                failureDescription: error.localizedDescription
            )
        }
    }

    func disarm() async throws {
        let response = try await perform(.disarm)
        _ = try mappedOperationState(
            response,
            among: protectionState.protectedProcesses
                .union(protectionState.restoredProcesses)
        )
        try requireSuccessfulStateResponse(response)
        protectionState.disarmed()
        automaticResumeIntervals.removeAll()
    }

    func renewLeaseIfConnected() async throws {
        guard connection != nil, connectionIsHandshaken else { return }
        let request = try makeRequest(action: .renewLease)
        let response = try await send(request, through: connection)
        try validate(response, for: request)
        if let errorMessage = response.errorMessage {
            throw ProcessGuardianClientError.remoteFailure(errorMessage)
        }
        try requireEmptyOperationState(response)
    }

    func invalidate() {
        protectionState.connectionLost()
        connection?.invalidate()
        connection = nil
        connectionIsHandshaken = false
    }

    private func perform(
        _ action: ProcessGuardianAction,
        processes: Set<ProcessIdentity> = [],
        resumeDeadlines: [WatchdogResumeDeadline] = []
    ) async throws -> ProcessGuardianResponse {
        let connection = try await readyConnection()
        return try await sendRequest(
            action,
            processes: processes,
            resumeDeadlines: resumeDeadlines,
            through: connection
        )
    }

    private func readyConnection() async throws -> NSXPCConnection {
        if let connection, connectionIsHandshaken {
            return connection
        }
        let preparation = try await ProcessGuardianLifecycle.shared
            .prepareForRequest()
        if preparation.didRefresh {
            invalidate()
        }
        let connection = try await activeConnection()
        try await handshakeIfNeeded(connection)
        return connection
    }

    private func sendRequest(
        _ action: ProcessGuardianAction,
        processes: Set<ProcessIdentity> = [],
        resumeDeadlines: [WatchdogResumeDeadline] = [],
        through connection: NSXPCConnection
    ) async throws -> ProcessGuardianResponse {
        let request = try makeRequest(
            action: action,
            processes: processes,
            resumeDeadlines: resumeDeadlines
        )
        let response = try await send(request, through: connection)
        try validate(response, for: request)
        return response
    }

    private func activeConnection() async throws -> NSXPCConnection {
        if let connection { return connection }

        let requirement = try await peerRequirement()
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: ProcessGuardianProtocol.machServiceName
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ProcessGuardianXPCProtocol.self
        )
        connection.setCodeSigningRequirement(requirement)
        connection.interruptionHandler = { [weak connection] in
            connection?.invalidate()
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task {
                await self?.connectionInvalidated(connection)
            }
        }
        connection.activate()
        self.connection = connection
        connectionIsHandshaken = false
        return connection
    }

    private func peerRequirement() async throws -> String {
        if let cachedPeerRequirement { return cachedPeerRequirement }
        let requirement: String
        do {
            requirement = try await Task.detached(priority: .utility) {
                try TempraCodeSigningRequirement.peerRequirement(
                    identifier: ProcessGuardianProtocol.guardianIdentifier
                )
            }.value
        } catch {
            throw ProcessGuardianClientError.invalidCodeSignature(
                error.localizedDescription
            )
        }
        if let cachedPeerRequirement { return cachedPeerRequirement }
        cachedPeerRequirement = requirement
        return requirement
    }

    private func handshakeIfNeeded(_ connection: NSXPCConnection) async throws {
        guard !connectionIsHandshaken else { return }
        let request = try makeRequest(action: .ping)
        let response = try await send(request, through: connection)
        try validate(response, for: request)
        if let errorMessage = response.errorMessage {
            throw ProcessGuardianClientError.remoteFailure(errorMessage)
        }
        try requireEmptyOperationState(response)
        let connectionRecoveryWasPending = protectionState.connectionRecoveryIsPending
        let guardianChanged = protectionState.guardianInstanceID.map {
            $0 != response.guardianInstanceID
        } ?? false
        protectionState.connected(to: response.guardianInstanceID)
        if connectionRecoveryWasPending || guardianChanged {
            automaticResumeIntervals.removeAll()
        }
        connectionIsHandshaken = true
    }

    static func requiresAutomaticResumeSynchronization(
        requested: [ProcessIdentity: TimeInterval],
        cached: [ProcessIdentity: TimeInterval],
        connectionIsCurrent: Bool
    ) -> Bool {
        !connectionIsCurrent || requested != cached
    }

    private func makeRequest(
        action: ProcessGuardianAction,
        processes: Set<ProcessIdentity> = [],
        resumeDeadlines: [WatchdogResumeDeadline] = []
    ) throws -> ProcessGuardianRequest {
        guard revision < .max else {
            throw ProcessGuardianClientError.revisionExhausted
        }
        guard let owner = LiveProcessSystemController.currentIdentity(for: getpid()) else {
            throw ProcessGuardianClientError.connectionFailed(
                "Tempra could not verify its process identity."
            )
        }
        revision += 1
        let request = ProcessGuardianRequest(
            sessionID: sessionID,
            revision: revision,
            action: action,
            owner: Self.watchdogIdentity(owner),
            processes: Self.sortedIdentities(processes),
            resumeDeadlines: resumeDeadlines
        )
        guard request.isValid else {
            throw ProcessGuardianClientError.invalidRequest
        }
        return request
    }

    private func send(
        _ request: ProcessGuardianRequest,
        through connection: NSXPCConnection?
    ) async throws -> ProcessGuardianResponse {
        guard let connection else {
            throw ProcessGuardianClientError.connectionFailed(
                "The process guardian connection is unavailable."
            )
        }
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= ProcessGuardianProtocol.maximumFrameBytes else {
            throw ProcessGuardianClientError.invalidResponse
        }

        let gate = ProcessGuardianReplyGate()
        let timeout = requestTimeout
        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    gate.resolve(.failure(ProcessGuardianClientError.timedOut))
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    gate.resolve(.failure(ProcessGuardianClientError.connectionFailed(
                        error.localizedDescription
                    )))
                }
                guard let guardian = proxy as? any ProcessGuardianXPCProtocol else {
                    gate.resolve(.failure(ProcessGuardianClientError.connectionFailed(
                        "The process guardian XPC interface is unavailable."
                    )))
                    return
                }
                guardian.send(encoded) { responseData in
                    gate.resolve(.success(responseData))
                }
            }
        } catch {
            invalidate()
            throw error
        }

        guard data.count <= ProcessGuardianProtocol.maximumFrameBytes,
              let response = try? JSONDecoder().decode(
                  ProcessGuardianResponse.self,
                  from: data
              ) else {
            invalidate()
            throw ProcessGuardianClientError.invalidResponse
        }
        return response
    }

    private func validate(
        _ response: ProcessGuardianResponse,
        for request: ProcessGuardianRequest
    ) throws {
        let applied = Set(response.applied)
        let stale = Set(response.stale)
        let failed = Set(response.failed)
        let resolved = applied.union(stale).union(failed)
        guard response.protocolVersion == ProcessGuardianProtocol.version,
              response.sessionID == request.sessionID,
              response.requestID == request.requestID,
              response.revision == request.revision,
              response.applied.count <= ProcessGuardianProtocol.maximumProcessCount,
              response.stale.count <= ProcessGuardianProtocol.maximumProcessCount,
              response.failed.count <= ProcessGuardianProtocol.maximumProcessCount,
              applied.count == response.applied.count,
              stale.count == response.stale.count,
              failed.count == response.failed.count,
              applied.isDisjoint(with: stale),
              applied.isDisjoint(with: failed),
              stale.isDisjoint(with: failed),
              Set(resolved.map(\.pid)).count == resolved.count,
              resolved.allSatisfy({
                  $0.pid > 1 && $0.startTimeMicroseconds > 0
              }),
              (response.errorCode == nil) == (response.errorMessage == nil),
              response.errorMessage.map({ !$0.isEmpty }) != false else {
            invalidate()
            throw ProcessGuardianClientError.invalidResponse
        }
    }

    private func requireSuccessfulStateResponse(
        _ response: ProcessGuardianResponse
    ) throws {
        guard response.errorCode == nil,
              response.errorMessage == nil,
              response.failed.isEmpty else {
            throw ProcessGuardianClientError.remoteFailure(
                response.errorMessage
                    ?? "The process guardian could not synchronize its state."
            )
        }
    }

    private func requireEmptyOperationState(
        _ response: ProcessGuardianResponse
    ) throws {
        guard response.applied.isEmpty,
              response.stale.isEmpty,
              response.failed.isEmpty else {
            invalidate()
            throw ProcessGuardianClientError.invalidResponse
        }
    }

    private func operationResult(
        _ response: ProcessGuardianResponse,
        requested: Set<ProcessIdentity>
    ) throws -> ProcessOperationResult {
        let mapped = try mappedOperationState(response, among: requested)
        let applied = mapped.applied
        let stale = mapped.stale
        var failed = mapped.failed
        if response.errorCode != nil || response.errorMessage != nil {
            failed.formUnion(
                requested.subtracting(applied.union(stale).union(failed))
            )
        }
        guard applied.union(stale).union(failed) == requested else {
            invalidate()
            throw ProcessGuardianClientError.invalidResponse
        }
        return ProcessOperationResult(
            applied: applied,
            stale: stale,
            failed: failed,
            failureDescription: response.errorMessage
        )
    }

    private func mappedOperationState(
        _ response: ProcessGuardianResponse,
        among candidates: Set<ProcessIdentity>
    ) throws -> (
        applied: Set<ProcessIdentity>,
        stale: Set<ProcessIdentity>,
        failed: Set<ProcessIdentity>
    ) {
        let originals = try mappedIdentityTable(for: candidates)
        return (
            applied: try mappedIdentities(response.applied, using: originals),
            stale: try mappedIdentities(response.stale, using: originals),
            failed: try mappedIdentities(response.failed, using: originals)
        )
    }

    private func mappedIdentityTable(
        for candidates: Set<ProcessIdentity>
    ) throws -> [WatchdogProcessIdentity: ProcessIdentity] {
        var originals: [WatchdogProcessIdentity: ProcessIdentity] = [:]
        originals.reserveCapacity(candidates.count)
        for candidate in candidates {
            let identity = Self.watchdogIdentity(candidate)
            guard originals.updateValue(candidate, forKey: identity) == nil else {
                invalidate()
                throw ProcessGuardianClientError.invalidResponse
            }
        }
        return originals
    }

    private func mappedIdentities(
        _ identities: [WatchdogProcessIdentity],
        using originals: [WatchdogProcessIdentity: ProcessIdentity]
    ) throws -> Set<ProcessIdentity> {
        let mapped = Set(identities.compactMap { originals[$0] })
        guard mapped.count == identities.count else {
            invalidate()
            throw ProcessGuardianClientError.invalidResponse
        }
        return mapped
    }

    private func connectionInvalidated(_ invalidated: NSXPCConnection?) {
        if connection === invalidated {
            protectionState.connectionLost()
            connection = nil
            connectionIsHandshaken = false
        }
    }

    private static func resumeDeadlines(
        for intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) throws -> [WatchdogResumeDeadline] {
        guard intervalsByProcess.count <= ProcessGuardianProtocol.maximumProcessCount else {
            throw ProcessGuardianClientError.invalidResponse
        }
        return try intervalsByProcess.map { process, interval in
            guard interval.isFinite, interval > 0 else {
                throw ProcessGuardianClientError.remoteFailure(
                    "The automatic-resume deadline is invalid."
                )
            }
            let milliseconds = ceil(interval * 1_000)
            guard milliseconds <= Double(Int32.max) else {
                throw ProcessGuardianClientError.remoteFailure(
                    "The automatic-resume deadline is outside the supported range."
                )
            }
            return WatchdogResumeDeadline(
                process: watchdogIdentity(process),
                resumeAfterMilliseconds: UInt32(milliseconds)
            )
        }.sorted {
            if $0.process.pid != $1.process.pid {
                return $0.process.pid < $1.process.pid
            }
            return $0.process.startTimeMicroseconds
                < $1.process.startTimeMicroseconds
        }
    }

    private static func sortedIdentities(
        _ processes: Set<ProcessIdentity>
    ) -> [WatchdogProcessIdentity] {
        processes.map(watchdogIdentity).sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.startTimeMicroseconds < $1.startTimeMicroseconds
        }
    }

    private static func watchdogIdentity(
        _ process: ProcessIdentity
    ) -> WatchdogProcessIdentity {
        WatchdogProcessIdentity(
            pid: Int32(process.pid),
            startTimeMicroseconds: process.startTimeMicroseconds
        )
    }
}

@MainActor
final class ProcessGuardianLeaseHeartbeat {
    private let client: any ProcessGuardianControlling
    private let logger = Logger(
        subsystem: ProcessGuardianProtocol.applicationIdentifier,
        category: "ProcessGuardianLease"
    )
    private var task: Task<Void, Never>?

    init(client: any ProcessGuardianControlling = ProcessGuardianClient.shared) {
        self.client = client
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self, client] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            ProcessGuardianProtocol.heartbeatIntervalMilliseconds
                        )
                    )
                    guard !Task.isCancelled else { return }
                    try await client.renewLeaseIfConnected()
                } catch is CancellationError {
                    return
                } catch {
                    self?.logger.error(
                        "Process guardian heartbeat failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
