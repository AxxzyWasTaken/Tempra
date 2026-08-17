import Foundation
import ServiceManagement
import TempraSafety

enum PrivilegedControlStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case helperUnavailable(String)
    case unavailable(String)

    var isEnabled: Bool {
        self == .enabled
    }

    var message: String? {
        switch self {
        case .notRegistered:
            "Administrator access is not enabled."
        case .requiresApproval:
            "Approve Tempra in System Settings › General › Login Items."
        case .enabled:
            nil
        case .helperUnavailable(let detail):
            "Administrator access is enabled. " + detail
        case .unavailable(let detail):
            detail
        }
    }

    var actionTitle: String? {
        switch self {
        case .notRegistered:
            "Enable Administrator Access"
        case .requiresApproval:
            "Open Login Items"
        case .helperUnavailable:
            "Retry Connection"
        case .enabled, .unavailable:
            nil
        }
    }
}

enum PrivilegedProcessClientError: LocalizedError, Sendable {
    case serviceNotEnabled
    case serviceRequiresApproval
    case invalidCodeSignature(String)
    case connectionFailed(String)
    case helperUpdateFailed(String)
    case timedOut
    case invalidResponse
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotEnabled:
            "Administrator access is not enabled."
        case .serviceRequiresApproval:
            "Approve Tempra in System Settings › General › Login Items."
        case .invalidCodeSignature(let detail):
            "Tempra could not verify its privileged helper: \(detail)"
        case .connectionFailed(let detail):
            "Tempra could not connect to its privileged helper: \(detail)"
        case .helperUpdateFailed(let detail):
            "Tempra could not update its privileged helper: \(detail)"
        case .timedOut:
            "The privileged helper did not respond in time."
        case .invalidResponse:
            "The privileged helper returned an invalid response."
        case .remoteFailure(let detail):
            detail
        }
    }
}

private final class XPCReplyGate: @unchecked Sendable {
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

struct PrivilegedHelperRegistrationIdentity: Codable, Equatable, Sendable {
    let executableCodeIdentifier: Data
    let servicePropertyList: Data
}

struct PrivilegedHelperPreparation: Equatable, Sendable {
    let didRefresh: Bool
}

enum PrivilegedHelperRegistrationStoreError: LocalizedError, Sendable {
    case identityDataTooLarge

    var errorDescription: String? {
        switch self {
        case .identityDataTooLarge:
            "The privileged-helper registration state is too large."
        }
    }
}

struct PrivilegedHelperRegistrationStore: Sendable {
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
                PrivilegedProcessProtocol.applicationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("privileged-helper-registration.json"))
    }

    func load() throws -> Data? {
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
                upToCount: PrivilegedProcessProtocol.maximumFrameBytes + 1
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

        guard data.count <= PrivilegedProcessProtocol.maximumFrameBytes else {
            throw PrivilegedHelperRegistrationStoreError.identityDataTooLarge
        }
        return data
    }

    func save(_ data: Data) throws {
        let fileManager = FileManager.default
        guard data.count <= PrivilegedProcessProtocol.maximumFrameBytes else {
            throw PrivilegedHelperRegistrationStoreError.identityDataTooLarge
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

enum PrivilegedHelperLifecycleError: LocalizedError, Sendable {
    case serviceNotEnabled
    case requiresApproval
    case unregistrationFailed(String)
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotEnabled:
            "Administrator access is not enabled."
        case .requiresApproval:
            "Approve Tempra in System Settings › General › Login Items."
        case .unregistrationFailed(let detail):
            "macOS could not unregister the old helper: \(detail)"
        case .registrationFailed(let detail):
            "macOS could not register the current helper: \(detail)"
        }
    }
}

private enum PrivilegedHelperBundle {
    private static let helperExecutableName = "TempraPrivilegedHelper"

    static var servicePropertyListURL: URL {
        contentsURL
            .appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(PrivilegedProcessProtocol.daemonPlistName)
    }

    static var helperExecutableURL: URL {
        contentsURL
            .appendingPathComponent("Library/HelperTools", isDirectory: true)
            .appendingPathComponent(helperExecutableName)
    }

    static func containsBundledService() -> Bool {
        FileManager.default.fileExists(atPath: servicePropertyListURL.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutableURL.path)
    }

    static func registrationIdentity() throws -> PrivilegedHelperRegistrationIdentity {
        PrivilegedHelperRegistrationIdentity(
            executableCodeIdentifier: try TempraCodeSigningRequirement
                .staticCodeIdentifier(at: helperExecutableURL),
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

@MainActor
final class PrivilegedHelperLifecycle {
    static let shared = PrivilegedHelperLifecycle()

    private let serviceStatus: () -> SMAppService.Status
    private let registerService: () throws -> Void
    private let unregisterService: () async throws -> Void
    private let currentRegistrationIdentity:
        () async throws -> PrivilegedHelperRegistrationIdentity
    private let loadRegisteredIdentityData: () async throws -> Data?
    private let saveRegisteredIdentityData: (Data) async throws -> Void
    private var cachedCurrentIdentity: PrivilegedHelperRegistrationIdentity?
    private var cachedRegisteredIdentity: PrivilegedHelperRegistrationIdentity?
    private var hasLoadedRegisteredIdentity = false
    private var pendingPreparation:
        (id: UUID, task: Task<PrivilegedHelperPreparation, any Error>)?

    init() {
        let service = SMAppService.daemon(
            plistName: PrivilegedProcessProtocol.daemonPlistName
        )
        serviceStatus = { service.status }
        registerService = { try service.register() }
        unregisterService = { try await service.unregister() }
        currentRegistrationIdentity = {
            try await Task.detached(priority: .utility) {
                try PrivilegedHelperBundle.registrationIdentity()
            }.value
        }
        loadRegisteredIdentityData = {
            try await Task.detached(priority: .utility) {
                try PrivilegedHelperRegistrationStore.live().load()
            }.value
        }
        saveRegisteredIdentityData = { identityData in
            try await Task.detached(priority: .utility) {
                try PrivilegedHelperRegistrationStore.live().save(identityData)
            }.value
        }
    }

    init(
        serviceStatus: @escaping () -> SMAppService.Status,
        registerService: @escaping () throws -> Void,
        unregisterService: @escaping () async throws -> Void,
        currentRegistrationIdentity:
            @escaping () async throws -> PrivilegedHelperRegistrationIdentity,
        loadRegisteredIdentityData: @escaping () async throws -> Data?,
        saveRegisteredIdentityData: @escaping (Data) async throws -> Void
    ) {
        self.serviceStatus = serviceStatus
        self.registerService = registerService
        self.unregisterService = unregisterService
        self.currentRegistrationIdentity = currentRegistrationIdentity
        self.loadRegisteredIdentityData = loadRegisteredIdentityData
        self.saveRegisteredIdentityData = saveRegisteredIdentityData
    }

    func registerCurrentService() async throws {
        let identity = try await resolvedCurrentIdentity()
        do {
            try registerService()
        } catch {
            if serviceStatus() == .requiresApproval {
                try await saveRegisteredIdentity(identity)
            }
            throw error
        }
        try await saveRegisteredIdentity(identity)
    }

    func prepareForRequest() async throws -> PrivilegedHelperPreparation {
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
            clearPendingPreparation(preparationID)
            return result
        } catch {
            clearPendingPreparation(preparationID)
            throw error
        }
    }

    private func performPreparation() async throws -> PrivilegedHelperPreparation {
        let initialStatus = serviceStatus()
        switch initialStatus {
        case .enabled, .notRegistered, .notFound:
            break
        case .requiresApproval:
            throw PrivilegedHelperLifecycleError.requiresApproval
        @unknown default:
            throw PrivilegedHelperLifecycleError.serviceNotEnabled
        }

        let currentIdentity = try await resolvedCurrentIdentity()
        if initialStatus == .notRegistered || initialStatus == .notFound {
            try await registerForRequest(currentIdentity)
            return try validatedPreparation(didRefresh: true)
        }

        if try await loadRegisteredIdentity() == currentIdentity {
            return PrivilegedHelperPreparation(didRefresh: false)
        }

        do {
            try await unregisterService()
        } catch {
            throw PrivilegedHelperLifecycleError.unregistrationFailed(
                error.localizedDescription
            )
        }

        do {
            try registerService()
        } catch {
            if serviceStatus() == .requiresApproval {
                try await saveRegisteredIdentity(currentIdentity)
                throw PrivilegedHelperLifecycleError.requiresApproval
            }
            throw PrivilegedHelperLifecycleError.registrationFailed(
                error.localizedDescription
            )
        }
        try await saveRegisteredIdentity(currentIdentity)

        return try validatedPreparation(didRefresh: true)
    }

    private func validatedPreparation(
        didRefresh: Bool
    ) throws -> PrivilegedHelperPreparation {
        switch serviceStatus() {
        case .enabled:
            return PrivilegedHelperPreparation(didRefresh: didRefresh)
        case .requiresApproval:
            throw PrivilegedHelperLifecycleError.requiresApproval
        case .notRegistered, .notFound:
            throw PrivilegedHelperLifecycleError.serviceNotEnabled
        @unknown default:
            throw PrivilegedHelperLifecycleError.serviceNotEnabled
        }
    }

    private func registerForRequest(
        _ identity: PrivilegedHelperRegistrationIdentity
    ) async throws {
        do {
            try registerService()
        } catch {
            if serviceStatus() == .requiresApproval {
                try await saveRegisteredIdentity(identity)
                throw PrivilegedHelperLifecycleError.requiresApproval
            }
            throw PrivilegedHelperLifecycleError.registrationFailed(
                error.localizedDescription
            )
        }
        try await saveRegisteredIdentity(identity)
    }

    private func loadRegisteredIdentity() async throws
        -> PrivilegedHelperRegistrationIdentity? {
        if hasLoadedRegisteredIdentity { return cachedRegisteredIdentity }
        let data = try await loadRegisteredIdentityData()
        hasLoadedRegisteredIdentity = true
        guard let data else { return nil }
        cachedRegisteredIdentity = try? JSONDecoder().decode(
            PrivilegedHelperRegistrationIdentity.self,
            from: data
        )
        return cachedRegisteredIdentity
    }

    private func resolvedCurrentIdentity() async throws
        -> PrivilegedHelperRegistrationIdentity {
        if let cachedCurrentIdentity { return cachedCurrentIdentity }
        let identity = try await currentRegistrationIdentity()
        cachedCurrentIdentity = identity
        return identity
    }

    private func saveRegisteredIdentity(
        _ identity: PrivilegedHelperRegistrationIdentity
    ) async throws {
        let data = try JSONEncoder().encode(identity)
        try await saveRegisteredIdentityData(data)
        cachedRegisteredIdentity = identity
        hasLoadedRegisteredIdentity = true
    }

    private func clearPendingPreparation(_ preparationID: UUID) {
        guard pendingPreparation?.id == preparationID else { return }
        pendingPreparation = nil
    }
}

actor PrivilegedProcessClient {
    static let shared = PrivilegedProcessClient()

    private var connection: NSXPCConnection?
    private let requestTimeout: Duration
    private var lifecycle: PrivilegedHelperLifecycle?

    init(
        requestTimeout: Duration = .seconds(4),
        lifecycle: PrivilegedHelperLifecycle? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.lifecycle = lifecycle
    }

    func ping() async throws {
        _ = try await send(PrivilegedProcessRequest(action: .ping))
    }

    func snapshots(
        for processIdentifiers: [pid_t]
    ) async throws -> [pid_t: ProcessKernelSnapshot] {
        let uniqueProcessIdentifiers = Array(Set(processIdentifiers)).sorted()
        guard uniqueProcessIdentifiers.count <= PrivilegedProcessProtocol.maximumProcessCount else {
            throw PrivilegedProcessClientError.remoteFailure(
                "The process snapshot request contains too many processes."
            )
        }
        let identifiers = uniqueProcessIdentifiers.compactMap(Int32.init(exactly:))
        guard identifiers.count == uniqueProcessIdentifiers.count,
              identifiers.allSatisfy({ $0 > 0 }) else {
            throw PrivilegedProcessClientError.remoteFailure(
                "A process identifier is outside the supported range."
            )
        }
        let response = try await send(PrivilegedProcessRequest(
            action: .snapshot,
            processIdentifiers: identifiers
        ))
        let requestedIdentifiers = Set(identifiers)
        var result: [pid_t: ProcessKernelSnapshot] = [:]
        for snapshot in response.snapshots {
            guard requestedIdentifiers.contains(snapshot.identity.pid),
                  snapshot.identity.pid > 0,
                  snapshot.identity.startTimeMicroseconds > 0,
                  result[snapshot.identity.pid] == nil else {
                throw PrivilegedProcessClientError.invalidResponse
            }
            let identity = ProcessIdentity(
                pid: snapshot.identity.pid,
                startTimeMicroseconds: snapshot.identity.startTimeMicroseconds,
                requiresPrivilegedControl: true
            )
            let processSnapshot = ProcessKernelSnapshot(
                identity: identity,
                parentPID: snapshot.parentPID,
                userID: snapshot.userID,
                executableName: snapshot.executableName,
                executablePath: snapshot.executablePath,
                totalCPUTimeNanoseconds: snapshot.totalCPUTimeNanoseconds,
                residentMemoryBytes: snapshot.residentMemoryBytes
            )
            result[identity.pid] = processSnapshot
        }
        return result
    }

    func totalCPUTime(for processes: Set<ProcessIdentity>) async throws -> UInt64 {
        try validateOperationProcesses(processes)
        let response = try await send(try operationRequest(
            .totalCPUTime,
            processes: processes
        ))
        return response.totalCPUTimeNanoseconds
    }

    func perform(
        _ action: PrivilegedProcessAction,
        processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval? = nil
    ) async throws -> ProcessOperationResult {
        try validateOperationProcesses(processes)
        let response = try await send(try operationRequest(
            action,
            processes: processes,
            automaticResumeAfter: automaticResumeAfter
        ))
        let originals = Dictionary(uniqueKeysWithValues: processes.map {
            (PrivilegedProcessIdentity(
                pid: Int32($0.pid),
                startTimeMicroseconds: $0.startTimeMicroseconds
            ), $0)
        })
        let applied = Set(response.applied.compactMap { originals[$0] })
        let stale = Set(response.stale.compactMap { originals[$0] })
        let failed = Set(response.failed.compactMap { originals[$0] })
        guard applied.count == response.applied.count,
              stale.count == response.stale.count,
              failed.count == response.failed.count,
              applied.isDisjoint(with: stale),
              applied.isDisjoint(with: failed),
              stale.isDisjoint(with: failed),
              applied.union(stale).union(failed) == processes else {
            throw PrivilegedProcessClientError.invalidResponse
        }
        return ProcessOperationResult(applied: applied, stale: stale, failed: failed)
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func operationRequest(
        _ action: PrivilegedProcessAction,
        processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval? = nil
    ) throws -> PrivilegedProcessRequest {
        guard action == .stop || automaticResumeAfter == nil else {
            throw PrivilegedProcessClientError.remoteFailure(
                "Only a stop request can contain an automatic-resume deadline."
            )
        }
        let automaticResumeMilliseconds: UInt32?
        if let automaticResumeAfter {
            guard automaticResumeAfter.isFinite, automaticResumeAfter > 0 else {
                throw PrivilegedProcessClientError.remoteFailure(
                    "The automatic-resume deadline is invalid."
                )
            }
            let milliseconds = ceil(automaticResumeAfter * 1_000)
            guard milliseconds <= Double(Int32.max) else {
                throw PrivilegedProcessClientError.remoteFailure(
                    "The automatic-resume deadline is outside the supported range."
                )
            }
            automaticResumeMilliseconds = UInt32(milliseconds)
        } else {
            automaticResumeMilliseconds = nil
        }
        return PrivilegedProcessRequest(
            action: action,
            processes: processes.map {
                PrivilegedProcessIdentity(
                    pid: Int32($0.pid),
                    startTimeMicroseconds: $0.startTimeMicroseconds
                )
            }.sorted {
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return $0.startTimeMicroseconds < $1.startTimeMicroseconds
            },
            automaticResumeAfterMilliseconds: automaticResumeMilliseconds
        )
    }

    private func validateOperationProcesses(
        _ processes: Set<ProcessIdentity>
    ) throws {
        guard processes.count <= PrivilegedProcessProtocol.maximumProcessCount,
              Set(processes.map(\.pid)).count == processes.count,
              processes.allSatisfy({
                  $0.pid > 1 && $0.startTimeMicroseconds > 0
              }) else {
            throw PrivilegedProcessClientError.remoteFailure(
                "The privileged operation contains invalid process identities."
            )
        }
    }

    private func send(
        _ request: PrivilegedProcessRequest
    ) async throws -> PrivilegedProcessResponse {
        if connection == nil {
            let lifecycle = await registrationLifecycle()
            do {
                let preparation = try await lifecycle.prepareForRequest()
                if preparation.didRefresh {
                    invalidate()
                }
            } catch let error as PrivilegedHelperLifecycleError {
                invalidate()
                switch error {
                case .serviceNotEnabled:
                    throw PrivilegedProcessClientError.serviceNotEnabled
                case .requiresApproval:
                    throw PrivilegedProcessClientError.serviceRequiresApproval
                case .unregistrationFailed, .registrationFailed:
                    throw PrivilegedProcessClientError.helperUpdateFailed(
                        error.localizedDescription
                    )
                }
            } catch {
                invalidate()
                throw PrivilegedProcessClientError.helperUpdateFailed(
                    error.localizedDescription
                )
            }
        }

        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= PrivilegedProcessProtocol.maximumFrameBytes else {
            throw PrivilegedProcessClientError.remoteFailure(
                "The privileged request is too large."
            )
        }

        let connection = try activeConnection()
        let gate = XPCReplyGate()
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
                    gate.resolve(.failure(PrivilegedProcessClientError.timedOut))
                }

                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    gate.resolve(.failure(PrivilegedProcessClientError.connectionFailed(
                        error.localizedDescription
                    )))
                }
                guard let helper = proxy as? any PrivilegedProcessXPCProtocol else {
                    gate.resolve(.failure(PrivilegedProcessClientError.connectionFailed(
                        "The XPC interface is unavailable."
                    )))
                    return
                }
                helper.send(encoded) { response in
                    gate.resolve(.success(response))
                }
            }
        } catch {
            invalidate()
            throw error
        }

        guard data.count <= PrivilegedProcessProtocol.maximumFrameBytes,
              let response = try? JSONDecoder().decode(
                PrivilegedProcessResponse.self,
                from: data
              ),
              response.protocolVersion == PrivilegedProcessProtocol.version,
              response.snapshots.count <= PrivilegedProcessProtocol.maximumProcessCount,
              response.applied.count <= PrivilegedProcessProtocol.maximumProcessCount,
              response.stale.count <= PrivilegedProcessProtocol.maximumProcessCount,
              response.failed.count <= PrivilegedProcessProtocol.maximumProcessCount else {
            invalidate()
            throw PrivilegedProcessClientError.invalidResponse
        }
        if response.errorCode != nil || response.errorMessage != nil {
            throw PrivilegedProcessClientError.remoteFailure(
                response.errorMessage ?? "The privileged helper reported an operation failure."
            )
        }
        return response
    }

    private func registrationLifecycle() async -> PrivilegedHelperLifecycle {
        if let lifecycle { return lifecycle }
        let sharedLifecycle = await PrivilegedHelperLifecycle.shared
        lifecycle = sharedLifecycle
        return sharedLifecycle
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let connection { return connection }

        let requirement: String
        do {
            requirement = try TempraCodeSigningRequirement.peerRequirement(
                identifier: PrivilegedProcessProtocol.helperIdentifier
            )
        } catch {
            throw PrivilegedProcessClientError.invalidCodeSignature(
                error.localizedDescription
            )
        }

        let connection = NSXPCConnection(
            machServiceName: PrivilegedProcessProtocol.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: PrivilegedProcessXPCProtocol.self
        )
        connection.setCodeSigningRequirement(requirement)
        connection.interruptionHandler = { [weak connection] in
            connection?.invalidate()
        }
        connection.invalidationHandler = {}
        connection.activate()
        self.connection = connection
        return connection
    }
}

@MainActor
final class PrivilegedHelperManager {
    private let serviceStatus: () -> SMAppService.Status
    private let bundledServiceIsPresent: () -> Bool
    private let registerService: () async throws -> Void
    private let openApprovalSettingsAction: () -> Void
    private let pingService: () async throws -> Void

    init(client: PrivilegedProcessClient = .shared) {
        let service = SMAppService.daemon(
            plistName: PrivilegedProcessProtocol.daemonPlistName
        )
        let lifecycle = PrivilegedHelperLifecycle.shared
        serviceStatus = { service.status }
        bundledServiceIsPresent = { PrivilegedHelperBundle.containsBundledService() }
        registerService = { try await lifecycle.registerCurrentService() }
        openApprovalSettingsAction = {
            SMAppService.openSystemSettingsLoginItems()
        }
        pingService = { try await client.ping() }
    }

    init(
        serviceStatus: @escaping () -> SMAppService.Status,
        bundledServiceIsPresent: @escaping () -> Bool,
        registerService: @escaping () async throws -> Void,
        openApprovalSettings: @escaping () -> Void,
        pingService: @escaping () async throws -> Void
    ) {
        self.serviceStatus = serviceStatus
        self.bundledServiceIsPresent = bundledServiceIsPresent
        self.registerService = registerService
        openApprovalSettingsAction = openApprovalSettings
        self.pingService = pingService
    }

    var status: PrivilegedControlStatus {
        Self.controlStatus(
            serviceStatus: serviceStatus(),
            bundledServiceIsPresent: bundledServiceIsPresent()
        )
    }

    static func controlStatus(
        serviceStatus: SMAppService.Status,
        bundledServiceIsPresent: Bool
    ) -> PrivilegedControlStatus {
        guard bundledServiceIsPresent else {
            return .unavailable(
                "Tempra’s privileged helper is missing from this app bundle."
            )
        }
        switch serviceStatus {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notRegistered
        @unknown default:
            return .unavailable(
                "macOS returned an unknown privileged-helper status."
            )
        }
    }

    func requestEnable() async -> PrivilegedControlStatus {
        let currentServiceStatus = serviceStatus()
        let containsBundledService = bundledServiceIsPresent()
        guard containsBundledService else {
            return Self.controlStatus(
                serviceStatus: currentServiceStatus,
                bundledServiceIsPresent: false
            )
        }
        if currentServiceStatus == .notRegistered || currentServiceStatus == .notFound {
            do {
                try await registerService()
            } catch {
                if Self.isLaunchDeniedByUser(error) {
                    openApprovalSettingsAction()
                    return .requiresApproval
                }
                return .unavailable(
                    "Tempra could not register administrator access: "
                        + error.localizedDescription
                )
            }
        }

        if serviceStatus() == .requiresApproval {
            openApprovalSettingsAction()
            return .requiresApproval
        }
        guard serviceStatus() == .enabled else { return status }

        return await verifyConnection(opensSettingsForApproval: true)
    }

    func prepareRegisteredService() async -> PrivilegedControlStatus {
        let currentServiceStatus = serviceStatus()
        guard bundledServiceIsPresent() else {
            return Self.controlStatus(
                serviceStatus: currentServiceStatus,
                bundledServiceIsPresent: false
            )
        }
        guard currentServiceStatus == .enabled else { return status }
        return await verifyConnection(opensSettingsForApproval: false)
    }

    func openApprovalSettings() {
        openApprovalSettingsAction()
    }

    private func verifyConnection(
        opensSettingsForApproval: Bool
    ) async -> PrivilegedControlStatus {
        do {
            try await pingService()
            return .enabled
        } catch {
            if serviceStatus() == .requiresApproval
                || Self.isApprovalRequired(error) {
                if opensSettingsForApproval {
                    openApprovalSettingsAction()
                }
                return .requiresApproval
            }
            return .helperUnavailable(error.localizedDescription)
        }
    }

    private static func isApprovalRequired(_ error: any Error) -> Bool {
        guard let clientError = error as? PrivilegedProcessClientError else {
            return false
        }
        if case .serviceRequiresApproval = clientError { return true }
        return false
    }

    private static func isLaunchDeniedByUser(_ error: any Error) -> Bool {
        let serviceError = error as NSError
        return serviceError.code == Int(kSMErrorLaunchDeniedByUser)
    }
}
