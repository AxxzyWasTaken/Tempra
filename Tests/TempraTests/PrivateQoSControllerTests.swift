import Darwin
import Foundation
@testable import TempraSafety
import Testing

@Suite("Darwin background process priority", .serialized)
struct ProcessPriorityControllerTests {
    @Test("Lowering backgrounds the process; the limit pulse leaves it alone")
    func lowerBackgroundsAndLimitIsIdentity() {
        #expect(ProcessPriorityController.loweredState(from: .normal) == .backgrounded)
        #expect(ProcessPriorityController.loweredState(from: .backgrounded) == .backgrounded)
        #expect(ProcessPriorityController.limitState(from: .normal) == .normal)
        #expect(ProcessPriorityController.limitState(from: .backgrounded) == .backgrounded)
    }

    @Test("A process that was already backgrounded is an unchanged target")
    func identifiesUnchangedTargetPriority() {
        let alreadyBackgrounded = ProcessPriorityPolicyState(
            isBackgrounded: true,
            observedAtMicroseconds: 42
        )
        #expect(
            ProcessPriorityController.loweredState(from: alreadyBackgrounded) == alreadyBackgrounded
        )
        #expect(!ProcessPriorityController.shouldRestore(
            current: .backgrounded,
            original: alreadyBackgrounded
        ))
    }

    @Test("Lowering keeps the observation time so restore can find inherited children")
    func loweredStateKeepsObservationTime() {
        let original = ProcessPriorityPolicyState(isBackgrounded: false, observedAtMicroseconds: 42)
        #expect(ProcessPriorityController.loweredState(from: original).observedAtMicroseconds == 42)
        #expect(ProcessPriorityController.limitState(from: original).observedAtMicroseconds == 42)
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
        #expect(!state.isBackgrounded)
        #expect(state.observedAtMicroseconds > 0)
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
        #expect(!original.isBackgrounded)

        try controller.lowerPriority(from: original, for: pid)
        #expect(try controller.state(for: pid).isBackgrounded)

        try controller.restore(original, to: pid)
        #expect(try !controller.state(for: pid).isBackgrounded)
    }

    @Test("Restoring a parent clears the background state its later children inherited")
    func restoreClearsInheritedBackgroundOnDescendants() throws {
        // The parent shell waits for a file to appear, then spawns a child.
        // Backgrounding the shell before that child exists makes the child
        // inherit the external background state, which clearing the parent
        // alone does not undo.
        let trigger = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempra-bg-inherit-\(UUID().uuidString)")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = [
            "-c",
            "while [ ! -e '\(trigger.path)' ]; do sleep 0.05; done; /bin/sleep 30 & wait",
        ]
        try parent.run()
        defer {
            _ = try? FileManager.default.removeItem(at: trigger)
            killProcessTree(parent.processIdentifier)
            parent.waitUntilExit()
        }
        let parentPID = parent.processIdentifier
        let controller = ProcessPriorityController()

        let original = try controller.state(for: parentPID)
        #expect(!original.isBackgrounded)
        try controller.lowerPriority(from: original, for: parentPID)
        #expect(try controller.state(for: parentPID).isBackgrounded)

        FileManager.default.createFile(atPath: trigger.path, contents: nil)
        let child = try #require(waitForChild(of: parentPID, named: "sleep"))
        #expect(try controller.state(for: child).isBackgrounded)

        try controller.restore(original, to: parentPID)
        #expect(try !controller.state(for: parentPID).isBackgrounded)
        #expect(try !controller.state(for: child).isBackgrounded)
    }

    private func waitForChild(of parent: Int32, named name: String) -> Int32? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var buffer = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(parent, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            for pid in buffer.prefix(Int(max(0, count))) where pid > 1 {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
                let comm = withUnsafeBytes(of: &info.pbi_comm) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                if comm == name { return pid }
            }
            usleep(20_000)
        }
        return nil
    }

    private func killProcessTree(_ pid: Int32) {
        var buffer = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        for child in buffer.prefix(Int(max(0, count))) where child > 1 {
            kill(child, SIGKILL)
        }
        kill(pid, SIGKILL)
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
