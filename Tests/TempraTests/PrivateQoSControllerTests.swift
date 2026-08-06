import Darwin
@testable import TempraSafety
import Testing

@Suite("POSIX process priority", .serialized)
struct ProcessPriorityControllerTests {
    @Test("Lower priority uses a supported nice value")
    func usesSupportedNiceValue() {
        #expect(ProcessPriorityController.lowerPriorityNiceValue == 10)
    }

    @Test("Lower priority never raises a process priority")
    func doesNotRaisePriority() throws {
        #expect(try ProcessPriorityController.loweredState(
            from: ProcessPriorityPolicyState(niceValue: -10)
        ).niceValue == 10)
        #expect(try ProcessPriorityController.loweredState(
            from: ProcessPriorityPolicyState(niceValue: 0)
        ).niceValue == 10)
        #expect(try ProcessPriorityController.loweredState(
            from: ProcessPriorityPolicyState(niceValue: 15)
        ).niceValue == 15)
    }

    @Test("The controller reads the current process nice value")
    func readsCurrentPriority() throws {
        let state = try ProcessPriorityController().state(for: getpid())
        #expect(state.isValid)
    }

    @Test("Invalid process identifiers are rejected before priority access")
    func rejectsInvalidProcessIdentifier() {
        let controller = ProcessPriorityController()

        #expect(throws: ProcessPriorityControllerError.invalidProcessIdentifier) {
            try controller.state(for: 1)
        }
    }

    @Test("Only supported nice values can be restored")
    func rejectsInvalidPolicyState() {
        let controller = ProcessPriorityController()
        let invalid = ProcessPriorityPolicyState(
            niceValue: Int32.max
        )

        #expect(!invalid.isValid)
        #expect(throws: ProcessPriorityControllerError.invalidPolicyState) {
            try controller.restore(invalid, to: getpid())
        }
    }

    @Test("Restore does not overwrite a newer priority value")
    func preservesNewerPriority() throws {
        let original = ProcessPriorityPolicyState(niceValue: 0)
        #expect(try ProcessPriorityController.shouldRestore(
            current: ProcessPriorityPolicyState(niceValue: 10),
            original: original
        ))
        #expect(try !ProcessPriorityController.shouldRestore(
            current: ProcessPriorityPolicyState(niceValue: 12),
            original: original
        ))
    }
}
