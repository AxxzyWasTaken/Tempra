import Foundation
import Testing
@testable import Tempra

@Suite("Process table sysctl smoke")
struct ProcessTableSmokeTests {
    @Test("The live process table lists launchd and this process with paths")
    func liveTableSmoke() throws {
        let entries = try #require(ProcessTableEntry.readAll())
        let launchd = try #require(entries.first { $0.pid == 1 })
        #expect(launchd.userID == 0)
        #expect(launchd.parentPID == 0)
        #expect(launchd.command == "/sbin/launchd")
        let own = try #require(entries.first { $0.pid == getpid() })
        #expect(own.userID == getuid())
        #expect(own.command.hasPrefix("/"))
        #expect(entries.count > 50)
    }
}
