import Foundation
import Testing
@testable import Tempra

@Suite("Menu dismissal")
struct MenuDismissalGateTests {
    @Test("Detached native menus suppress popover dismissal while tracking")
    func trackingSuppressesDismissal() {
        var gate = MenuDismissalGate()
        gate.beginTracking()

        #expect(!gate.allowsDismissal())
        #expect(gate.trackingDepth == 1)
    }

    @Test("Nested submenus stay protected until every menu ends tracking")
    func nestedSubmenusStayProtected() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var gate = MenuDismissalGate()
        gate.beginTracking()
        gate.beginTracking()
        gate.endTracking(at: start)

        #expect(!gate.allowsDismissal(at: start.addingTimeInterval(1)))
        #expect(gate.trackingDepth == 1)

        gate.endTracking(at: start)

        #expect(!gate.allowsDismissal(at: start.addingTimeInterval(0.1)))
        #expect(gate.allowsDismissal(at: start.addingTimeInterval(0.21)))
    }
}
