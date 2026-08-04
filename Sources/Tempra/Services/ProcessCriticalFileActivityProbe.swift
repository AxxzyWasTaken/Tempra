import Darwin
import Dispatch
import Foundation

enum ProcessCriticalFileActivity: Equatable, Sendable {
    case inactive
    case activeDownload
    case unknown
}

struct ProcessCriticalFileActivityProbe: Sendable {
    private static let maximumFileDescriptorCount = 4_096
    private static let descriptorGrowthAllowance = 16
    private static let downloadExtensions: Set<String> = [
        "crdownload",
        "download",
        "part",
    ]
    private static let queue = DispatchQueue(
        label: "io.github.temperapp.Temper.file-activity-probe",
        qos: .utility
    )

    func activityWithoutBlockingController(
        for identity: ProcessIdentity
    ) async -> ProcessCriticalFileActivity {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: activity(for: identity))
            }
        }
    }

    func activity(for identity: ProcessIdentity) -> ProcessCriticalFileActivity {
        guard Self.identityIsCurrent(identity) else { return .unknown }

        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        guard descriptorSize > 0, descriptorSize <= Int(Int32.max) else {
            return .unknown
        }

        errno = 0
        let requiredBytes = proc_pidinfo(identity.pid, PROC_PIDLISTFDS, 0, nil, 0)
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
        var vnodeInspectionFailed = false
        for descriptor in descriptors.prefix(returnedCount)
            where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnodeInfo = vnode_fdinfowithpath()
            errno = 0
            let vnodeBytesRead = withUnsafeMutablePointer(to: &vnodeInfo) { pointer in
                proc_pidfdinfo(
                    identity.pid,
                    descriptor.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    pointer,
                    Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                )
            }
            guard vnodeBytesRead == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else {
                vnodeInspectionFailed = true
                continue
            }
            let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    let length = strnlen($0, Int(MAXPATHLEN))
                    let bytes = UnsafeRawBufferPointer(start: $0, count: length)
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            if Self.isActiveDownload(
                path: path,
                openFlags: vnodeInfo.pfi.fi_openflags
            ) {
                return .activeDownload
            }
        }

        guard Self.identityIsCurrent(identity) else { return .unknown }
        let descriptorListMayBeTruncated = returnedCount == descriptorCount
        return vnodeInspectionFailed || descriptorListMayBeTruncated ? .unknown : .inactive
    }

    static func isActiveDownload(path: String, openFlags: UInt32) -> Bool {
        let accessMode = Int32(bitPattern: openFlags) & O_ACCMODE
        guard accessMode == O_WRONLY || accessMode == O_RDWR else { return false }
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return downloadExtensions.contains(pathExtension)
    }

    private static func identityIsCurrent(_ identity: ProcessIdentity) -> Bool {
        guard let current = LiveProcessSystemController.currentIdentity(for: identity.pid) else {
            return false
        }
        return current.pid == identity.pid
            && current.startTimeMicroseconds == identity.startTimeMicroseconds
    }
}
