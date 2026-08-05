import Darwin
import TempraSafety
import Testing

@Suite("Private process QoS", .serialized)
struct PrivateQoSControllerTests {
    @Test("The energy-efficient role uses utility QoS without Darwin background networking")
    func usesUtilityQoSRole() {
        #expect(PrivateQoSController.energyEfficientState.darwinRole == 5)
    }

    @Test("The energy-efficient policy applies and restores the exact prior state")
    func appliesAndRestoresPolicy() throws {
        let controller = PrivateQoSController()
        let processIdentifier = getpid()
        let original = try controller.state(for: processIdentifier)

        try controller.applyEnergyEfficientPolicy(to: processIdentifier)
        var applied: PrivateQoSPolicyState?
        var observationError: (any Error)?
        do {
            applied = try controller.state(for: processIdentifier)
        } catch {
            observationError = error
        }
        try controller.restore(original, to: processIdentifier)
        if let observationError {
            throw observationError
        }

        #expect(applied == PrivateQoSController.energyEfficientState)
        #expect(try controller.state(for: processIdentifier) == original)
    }

    @Test("Invalid process identifiers are rejected before priority access")
    func rejectsInvalidProcessIdentifier() {
        let controller = PrivateQoSController()

        #expect(throws: PrivateQoSControllerError.invalidProcessIdentifier) {
            try controller.state(for: 1)
        }
    }

    @Test("Only kernel-supported Darwin roles can be restored")
    func rejectsInvalidPolicyState() {
        let controller = PrivateQoSController()
        let invalid = PrivateQoSPolicyState(
            darwinRole: Int32.max
        )

        #expect(!invalid.isValid)
        #expect(throws: PrivateQoSControllerError.invalidPolicyState) {
            try controller.restore(invalid, to: getpid())
        }
    }

    @Test("Restore does not overwrite a newer process role")
    func preservesNewerProcessRole() throws {
        let controller = PrivateQoSController()
        let processIdentifier = getpid()
        let original = try controller.state(for: processIdentifier)

        try controller.applyEnergyEfficientPolicy(to: processIdentifier)
        try controller.restore(
            PrivateQoSPolicyState(darwinRole: 3),
            to: processIdentifier
        )
        try controller.restore(original, to: processIdentifier)
        let preserved = try controller.state(for: processIdentifier)

        try controller.applyEnergyEfficientPolicy(to: processIdentifier)
        try controller.restore(original, to: processIdentifier)

        #expect(preserved.darwinRole == 3)
        #expect(try controller.state(for: processIdentifier) == original)
    }
}
