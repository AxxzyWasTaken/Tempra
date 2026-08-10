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

    func activity(for identity: ProcessIdentity) -> ProcessNetworkActivity {
        guard Self.identityIsCurrent(identity) else { return .unknown }

        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        guard descriptorSize > 0, descriptorSize <= Int(Int32.max) else {
            return .unknown
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
            return errno == 0 ? .inactive : .unknown
        }

        let requiredByteCount = Int(requiredBytes)
        let roundedByteCount = requiredByteCount.addingReportingOverflow(descriptorSize - 1)
        guard !roundedByteCount.overflow else { return .unknown }
        let requiredCount = roundedByteCount.partialValue / descriptorSize
        guard requiredCount > 0,
              requiredCount <= Self.maximumFileDescriptorCount else {
            return .unknown
        }

        let requestedCount = requiredCount.addingReportingOverflow(
            Self.descriptorGrowthAllowance
        )
        guard !requestedCount.overflow else { return .unknown }
        let descriptorCount = min(
            Self.maximumFileDescriptorCount,
            requestedCount.partialValue
        )
        let bufferByteCount = descriptorCount.multipliedReportingOverflow(by: descriptorSize)
        guard !bufferByteCount.overflow,
              bufferByteCount.partialValue <= Int(Int32.max) else {
            return .unknown
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
            return .unknown
        }

        let returnedCount = Int(bytesRead) / descriptorSize
        var socketInspectionFailed = false
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
            if Self.isLatencySensitive(socketInfo: socketInfo) {
                return .active
            }
        }

        guard Self.identityIsCurrent(identity) else { return .unknown }
        let descriptorListMayBeTruncated = returnedCount == descriptorCount
        return socketInspectionFailed || descriptorListMayBeTruncated ? .unknown : .inactive
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

        let connectedStates = Int32(SOI_S_ISCONNECTED | SOI_S_ISCONNECTING)
        if Int32(socket.soi_state) & connectedStates != 0 {
            return true
        }
        return socket.soi_proto.pri_tcp.tcpsi_state >= TCPS_SYN_SENT
    }

    private static func identityIsCurrent(_ identity: ProcessIdentity) -> Bool {
        guard let current = LiveProcessSystemController.currentIdentity(for: identity.pid) else {
            return false
        }
        return current.pid == identity.pid
            && current.startTimeMicroseconds == identity.startTimeMicroseconds
    }
}
