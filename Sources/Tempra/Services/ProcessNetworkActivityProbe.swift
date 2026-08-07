import Darwin
import Dispatch
import Foundation

enum ProcessNetworkActivity: Equatable, Sendable {
    case inactive
    case active
    case unknown

    var isLatencySensitive: Bool {
        self != .inactive
    }
}

struct ProcessNetworkConnectionID: Hashable, Sendable {
    let process: ProcessIdentity
    let socketObject: UInt64
    let protocolControlBlock: UInt64
    let protocolNumber: Int32
    let socketGeneration: UInt64
    let localPort: Int32
    let foreignPort: Int32
    let flowIdentifier: UInt32

    init(
        process: ProcessIdentity,
        socketObject: UInt64,
        protocolControlBlock: UInt64,
        protocolNumber: Int32,
        socketGeneration: UInt64 = 0,
        localPort: Int32 = 0,
        foreignPort: Int32 = 0,
        flowIdentifier: UInt32 = 0
    ) {
        self.process = process
        self.socketObject = socketObject
        self.protocolControlBlock = protocolControlBlock
        self.protocolNumber = protocolNumber
        self.socketGeneration = socketGeneration
        self.localPort = localPort
        self.foreignPort = foreignPort
        self.flowIdentifier = flowIdentifier
    }
}

struct ProcessNetworkConnectionSnapshot: Equatable, Sendable {
    let activity: ProcessNetworkActivity
    let activeConnections: Set<ProcessNetworkConnectionID>
    let failedConnections: Set<ProcessNetworkConnectionID>
    let isComplete: Bool

    init(
        activity: ProcessNetworkActivity,
        activeConnections: Set<ProcessNetworkConnectionID> = [],
        failedConnections: Set<ProcessNetworkConnectionID> = [],
        isComplete: Bool = true
    ) {
        self.activity = activity
        self.activeConnections = activeConnections
        self.failedConnections = failedConnections
        self.isComplete = isComplete
    }

    static func combined(
        _ snapshots: [ProcessNetworkConnectionSnapshot]
    ) -> ProcessNetworkConnectionSnapshot {
        let activity: ProcessNetworkActivity
        if snapshots.contains(where: { $0.activity == .active }) {
            activity = .active
        } else if snapshots.contains(where: { $0.activity == .unknown }) {
            activity = .unknown
        } else {
            activity = .inactive
        }
        return ProcessNetworkConnectionSnapshot(
            activity: activity,
            activeConnections: snapshots.reduce(into: []) {
                $0.formUnion($1.activeConnections)
            },
            failedConnections: snapshots.reduce(into: []) {
                $0.formUnion($1.failedConnections)
            },
            isComplete: snapshots.allSatisfy(\.isComplete)
        )
    }
}

struct ProcessNetworkActivityProbe: Sendable {
    private static let maximumFileDescriptorCount = 4_096
    private static let descriptorGrowthAllowance = 16
    private static let queue = DispatchQueue(
        label: "io.github.temperapp.Temper.network-probe",
        qos: .utility
    )

    func activityWithoutBlockingController(
        for identity: ProcessIdentity
    ) async -> ProcessNetworkActivity {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: activity(for: identity))
            }
        }
    }

    func snapshotWithoutBlockingController(
        for identity: ProcessIdentity
    ) async -> ProcessNetworkConnectionSnapshot {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: snapshot(for: identity))
            }
        }
    }

    func activity(for identity: ProcessIdentity) -> ProcessNetworkActivity {
        scan(for: identity, collectsConnectionIdentity: false).activity
    }

    func snapshot(for identity: ProcessIdentity) -> ProcessNetworkConnectionSnapshot {
        scan(for: identity, collectsConnectionIdentity: true)
    }

    private func scan(
        for identity: ProcessIdentity,
        collectsConnectionIdentity: Bool
    ) -> ProcessNetworkConnectionSnapshot {
        guard Self.identityIsCurrent(identity) else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }

        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        guard descriptorSize > 0, descriptorSize <= Int(Int32.max) else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }

        errno = 0
        let requiredBytes = proc_pidinfo(
            identity.pid,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else {
            return ProcessNetworkConnectionSnapshot(
                activity: errno == 0 ? .inactive : .unknown,
                isComplete: errno == 0
            )
        }

        let requiredByteCount = Int(requiredBytes)
        let roundedByteCount = requiredByteCount.addingReportingOverflow(descriptorSize - 1)
        guard !roundedByteCount.overflow else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }
        let requiredCount = roundedByteCount.partialValue / descriptorSize
        guard requiredCount > 0,
              requiredCount <= Self.maximumFileDescriptorCount else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }

        let requestedCount = requiredCount.addingReportingOverflow(
            Self.descriptorGrowthAllowance
        )
        guard !requestedCount.overflow else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }
        let descriptorCount = min(
            Self.maximumFileDescriptorCount,
            requestedCount.partialValue
        )
        let bufferByteCount = descriptorCount.multipliedReportingOverflow(by: descriptorSize)
        guard !bufferByteCount.overflow,
              bufferByteCount.partialValue <= Int(Int32.max) else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }

        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: descriptorCount
        )
        errno = 0
        let bytesRead = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                identity.pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard bytesRead > 0,
              Int(bytesRead) <= bufferByteCount.partialValue,
              Int(bytesRead).isMultiple(of: descriptorSize),
              Self.identityIsCurrent(identity) else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }

        let returnedCount = Int(bytesRead) / descriptorSize
        var socketInspectionFailed = false
        var foundLatencySensitiveSocket = false
        var activeConnections: Set<ProcessNetworkConnectionID> = []
        var failedConnections: Set<ProcessNetworkConnectionID> = []
        for descriptor in descriptors.prefix(returnedCount)
            where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socketInfo = socket_fdinfo()
            errno = 0
            let socketBytesRead = withUnsafeMutablePointer(to: &socketInfo) { pointer in
                proc_pidfdinfo(
                    identity.pid,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    pointer,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
            }
            guard socketBytesRead == Int32(MemoryLayout<socket_fdinfo>.size) else {
                socketInspectionFailed = true
                continue
            }
            let connectionID = Self.connectionID(
                for: identity,
                socketInfo: socketInfo
            )
            if Self.hasFailureState(socketInfo: socketInfo) {
                if let connectionID {
                    failedConnections.insert(connectionID)
                }
                continue
            }
            if Self.isLatencySensitive(socketInfo: socketInfo) {
                foundLatencySensitiveSocket = true
                if !collectsConnectionIdentity {
                    guard Self.identityIsCurrent(identity) else {
                        return ProcessNetworkConnectionSnapshot(
                            activity: .unknown,
                            isComplete: false
                        )
                    }
                    return ProcessNetworkConnectionSnapshot(activity: .active)
                }
                if let connectionID {
                    activeConnections.insert(connectionID)
                }
            }
        }

        guard Self.identityIsCurrent(identity) else {
            return ProcessNetworkConnectionSnapshot(
                activity: .unknown,
                isComplete: false
            )
        }
        let descriptorListMayBeTruncated = returnedCount == descriptorCount
        let isComplete = !socketInspectionFailed && !descriptorListMayBeTruncated
        let activity: ProcessNetworkActivity
        if foundLatencySensitiveSocket {
            activity = .active
        } else {
            activity = isComplete ? .inactive : .unknown
        }
        return ProcessNetworkConnectionSnapshot(
            activity: activity,
            activeConnections: activeConnections,
            failedConnections: failedConnections,
            isComplete: isComplete
        )
    }

    static func isLatencySensitive(socketInfo: socket_fdinfo) -> Bool {
        let socket = socketInfo.psi
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else {
            return false
        }

        if socket.soi_protocol == IPPROTO_UDP {
            return true
        }
        guard socket.soi_protocol == IPPROTO_TCP else { return false }

        switch socket.soi_proto.pri_tcp.tcpsi_state {
        case TCPS_SYN_SENT, TCPS_SYN_RECEIVED, TCPS_ESTABLISHED:
            return true
        default:
            return false
        }
    }

    static func hasFailureState(socketInfo: socket_fdinfo) -> Bool {
        let socket = socketInfo.psi
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else {
            return false
        }
        let failureStates = Int32(
            SOI_S_ISDISCONNECTING
                | SOI_S_CANTSENDMORE
                | SOI_S_CANTRCVMORE
                | SOI_S_ISDISCONNECTED
        )
        if socket.soi_error != 0 || Int32(socket.soi_state) & failureStates != 0 {
            return true
        }
        guard socket.soi_protocol == IPPROTO_TCP else { return false }
        switch socket.soi_proto.pri_tcp.tcpsi_state {
        case TCPS_CLOSED, TCPS_LISTEN, TCPS_SYN_SENT, TCPS_SYN_RECEIVED,
             TCPS_ESTABLISHED:
            return false
        default:
            return true
        }
    }

    private static func connectionID(
        for process: ProcessIdentity,
        socketInfo: socket_fdinfo
    ) -> ProcessNetworkConnectionID? {
        let socket = socketInfo.psi
        guard socket.soi_protocol == IPPROTO_TCP || socket.soi_protocol == IPPROTO_UDP,
              socket.soi_so != 0 || socket.soi_pcb != 0 else {
            return nil
        }
        let internetInfo: in_sockinfo
        if socket.soi_protocol == IPPROTO_TCP {
            internetInfo = socket.soi_proto.pri_tcp.tcpsi_ini
        } else {
            internetInfo = socket.soi_proto.pri_in
        }
        return ProcessNetworkConnectionID(
            process: process,
            socketObject: socket.soi_so,
            protocolControlBlock: socket.soi_pcb,
            protocolNumber: Int32(socket.soi_protocol),
            socketGeneration: internetInfo.insi_gencnt,
            localPort: Int32(internetInfo.insi_lport),
            foreignPort: Int32(internetInfo.insi_fport),
            flowIdentifier: internetInfo.insi_flow
        )
    }

    private static func identityIsCurrent(_ identity: ProcessIdentity) -> Bool {
        guard let current = LiveProcessSystemController.currentIdentity(for: identity.pid) else {
            return false
        }
        return current.pid == identity.pid
            && current.startTimeMicroseconds == identity.startTimeMicroseconds
    }
}
