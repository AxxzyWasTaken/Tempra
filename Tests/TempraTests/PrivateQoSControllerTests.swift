import Darwin
import Foundation
@testable import TempraSafety
import Testing

@Suite("Darwin background process priority", .serialized)
struct ProcessPriorityControllerTests {
    @Test("Lowering and limiting both background the process")
    func lowerAndLimitBackground() {
        #expect(ProcessPriorityController.loweredState(from: .normal) == .backgrounded)
        #expect(ProcessPriorityController.loweredState(from: .backgrounded) == .backgrounded)
        #expect(ProcessPriorityController.limitState(from: .normal) == .backgrounded)
        #expect(ProcessPriorityController.limitState(from: .backgrounded) == .backgrounded)
    }

    @Test("A process that was already backgrounded is an unchanged target")
    func identifiesUnchangedTargetPriority() {
        #expect(
            ProcessPriorityController.loweredState(from: .backgrounded) == .backgrounded
        )
        #expect(!ProcessPriorityController.shouldRestore(
            current: .backgrounded,
            original: .backgrounded
        ))
    }

    @Test("Restore only writes when the current state differs from the original")
    func restoresOnlyWhenChanged() {
        #expect(ProcessPriorityController.shouldRestore(
            current: .backgrounded,
            original: .normal
        ))
        #expect(!ProcessPriorityController.shouldRestore(
            current: .normal,
            original: .normal
        ))
    }

    @Test("The controller reads the current process background state")
    func readsCurrentPriority() throws {
        let state = try ProcessPriorityController().state(for: getpid())
        #expect(state == .normal)
    }

    @Test("Invalid process identifiers are rejected before priority access")
    func rejectsInvalidProcessIdentifier() {
        let controller = ProcessPriorityController()

        #expect(throws: ProcessPriorityControllerError.invalidProcessIdentifier) {
            try controller.state(for: 1)
        }
        #expect(throws: ProcessPriorityControllerError.invalidProcessIdentifier) {
            try controller.restore(.normal, to: 0)
        }
    }

    @Test("Backgrounding a same-user child is visible in its flags and reversible")
    func backgroundsAndRestoresAChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let pid = child.processIdentifier
        let controller = ProcessPriorityController()

        let original = try controller.state(for: pid)
        #expect(original == .normal)

        try controller.lowerPriority(from: original, for: pid)
        #expect(try controller.state(for: pid) == .backgrounded)

        try controller.restore(original, to: pid)
        #expect(try controller.state(for: pid) == .normal)
    }

    @Test("Backgrounding a root-owned process without privilege is a permission failure")
    func permissionDeniedIsDistinguishable() {
        let controller = ProcessPriorityController()
        // launchd (pid 1) is rejected outright; pick the first root-owned pid above it.
        guard let rootPID = firstRootOwnedProcessIdentifier() else { return }
        do {
            try controller.lowerPriority(from: .normal, for: rootPID)
            Issue.record("Expected EPERM when backgrounding pid \(rootPID) unprivileged.")
        } catch let error as ProcessPriorityControllerError {
            #expect(error.isPermissionDenied)
        } catch {
            Issue.record("Unexpected error \(error).")
        }
    }

    private func firstRootOwnedProcessIdentifier() -> Int32? {
        guard geteuid() != 0 else { return nil }
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(count)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == 0 else { continue }
            return pid
        }
        return nil
    }
}
