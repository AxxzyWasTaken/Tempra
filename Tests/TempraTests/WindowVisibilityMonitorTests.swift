import CoreGraphics
import Testing
@testable import Tempra

@Suite("Window visibility")
struct WindowVisibilityMonitorTests {
    private let appPID: pid_t = 10
    private let otherPID: pid_t = 20
    private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)

    @Test("Any meaningfully visible app window protects the app")
    func anyVisibleWindowProtectsApp() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: appPID, x: 850, width: 100),
                window(pid: otherPID, x: 0, width: 800),
                window(pid: appPID, x: 0, width: 800)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    @Test("A sub-threshold sliver does not prevent management")
    func tinySliverIsCovered() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 99.5),
                window(pid: appPID, x: 0, width: 100)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .covered)
    }

    @Test("One percent of a window is meaningfully visible")
    func thresholdSliverIsVisible() {
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                window(pid: otherPID, x: 0, width: 99),
                window(pid: appPID, x: 0, width: 100)
            ],
            screenBounds: [screen]
        )

        #expect(snapshot.visibility(for: [appPID], isHidden: false) == .visible)
    }

    private func window(pid: pid_t, x: CGFloat, width: CGFloat) -> WindowVisibilityRecord {
        WindowVisibilityRecord(
            ownerPID: pid,
            bounds: CGRect(x: x, y: 0, width: width, height: 100),
            layer: 0,
            alpha: 1
        )
    }
}
