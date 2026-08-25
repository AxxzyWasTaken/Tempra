import Foundation
import Testing
@testable import Tempra

@Suite("Launch at login location policy")
struct LaunchAtLoginControllerTests {
    private let policy = LaunchAtLoginLocationPolicy(applicationDirectories: [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/Users/example/Applications", isDirectory: true),
    ])

    @Test("Permits apps in system and user Applications directories")
    func permitsInstalledApps() {
        #expect(policy.permitsRegistration(
            for: URL(fileURLWithPath: "/Applications/Tempra.app", isDirectory: true)
        ))
        #expect(policy.permitsRegistration(
            for: URL(
                fileURLWithPath: "/Users/example/Applications/Tempra.app",
                isDirectory: true
            )
        ))
    }

    @Test("Rejects development and similar-prefix directories")
    func rejectsAppsOutsideApplicationsDirectories() {
        #expect(!policy.permitsRegistration(
            for: URL(
                fileURLWithPath: "/Users/example/project/dist/Tempra.app",
                isDirectory: true
            )
        ))
        #expect(!policy.permitsRegistration(
            for: URL(
                fileURLWithPath: "/Applications-old/Tempra.app",
                isDirectory: true
            )
        ))
    }
}
