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
    case invalidCodeSignature(String)
    case connectionFailed(String)
    case timedOut
    case invalidResponse
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotEnabled:
            "Administrator access is not enabled."
        case .invalidCodeSignature(let detail):
            "Tempra could not verify its privileged helper: \(detail)"
        case .connectionFailed(let detail):
            "Tempra could not connect to its privileged helper: \(detail)"
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

actor PrivilegedProcessClient {
    static let shared = PrivilegedProcessClient()

    private var connection: NSXPCConnection?
    private let requestTimeout: Duration

    init(requestTimeout: Duration = .seconds(4)) {
        self.requestTimeout = requestTimeout
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
        let response = try await send(operationRequest(.totalCPUTime, processes: processes))
        return response.totalCPUTimeNanoseconds
    }

    func perform(
        _ action: PrivilegedProcessAction,
        processes: Set<ProcessIdentity>
    ) async throws -> ProcessOperationResult {
        try validateOperationProcesses(processes)
        let response = try await send(operationRequest(action, processes: processes))
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
        processes: Set<ProcessIdentity>
    ) -> PrivilegedProcessRequest {
        PrivilegedProcessRequest(
            action: action,
            processes: processes.map {
                PrivilegedProcessIdentity(
                    pid: Int32($0.pid),
                    startTimeMicroseconds: $0.startTimeMicroseconds
                )
            }.sorted {
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return $0.startTimeMicroseconds < $1.startTimeMicroseconds
            }
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
        guard SMAppService.daemon(
            plistName: PrivilegedProcessProtocol.daemonPlistName
        ).status == .enabled else {
            throw PrivilegedProcessClientError.serviceNotEnabled
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
    private static let helperExecutableName = "TempraPrivilegedHelper"

    private let serviceStatus: () -> SMAppService.Status
    private let bundledServiceIsPresent: () -> Bool
    private let registerService: () throws -> Void
    private let openApprovalSettingsAction: () -> Void
    private let pingService: () async throws -> Void

    init(client: PrivilegedProcessClient = .shared) {
        let service = SMAppService.daemon(
            plistName: PrivilegedProcessProtocol.daemonPlistName
        )
        serviceStatus = { service.status }
        bundledServiceIsPresent = { Self.containsBundledService() }
        registerService = { try service.register() }
        openApprovalSettingsAction = {
            SMAppService.openSystemSettingsLoginItems()
        }
        pingService = { try await client.ping() }
    }

    init(
        serviceStatus: @escaping () -> SMAppService.Status,
        bundledServiceIsPresent: @escaping () -> Bool,
        registerService: @escaping () throws -> Void,
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
                try registerService()
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

        do {
            try await pingService()
            return .enabled
        } catch {
            return .helperUnavailable(error.localizedDescription)
        }
    }

    func openApprovalSettings() {
        openApprovalSettingsAction()
    }

    private static func containsBundledService() -> Bool {
        let contentsURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let plistURL = contentsURL
            .appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(PrivilegedProcessProtocol.daemonPlistName)
        let helperURL = contentsURL
            .appendingPathComponent("Library/HelperTools", isDirectory: true)
            .appendingPathComponent(helperExecutableName)
        return FileManager.default.fileExists(atPath: plistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    private static func isLaunchDeniedByUser(_ error: any Error) -> Bool {
        let serviceError = error as NSError
        return serviceError.code == Int(kSMErrorLaunchDeniedByUser)
    }
}
