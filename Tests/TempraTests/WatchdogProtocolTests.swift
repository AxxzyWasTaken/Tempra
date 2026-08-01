import Darwin
import Foundation
import TempraSafety
import Testing

@Suite("Crash watchdog protocol")
struct WatchdogProtocolTests {
    @Test("Process termination uses the force-quit signal")
    func processTerminationUsesForceQuitSignal() {
        #expect(PrivilegedProcessProtocol.forceQuitSignal == SIGKILL)
    }

    @Test("Commands decode across bounded input chunks")
    func chunkedCommands() throws {
        let first = WatchdogCommand(
            action: .update,
            processes: [WatchdogProcessIdentity(pid: 42, startTimeMicroseconds: 100)]
        )
        let second = WatchdogCommand(action: .disarm, processes: [])
        let firstFrame = try JSONEncoder().encode(first) + Data([0x0A])
        let secondFrame = try JSONEncoder().encode(second) + Data([0x0A])
        let combined = firstFrame + secondFrame
        let splitIndex = combined.index(combined.startIndex, offsetBy: combined.count / 2)

        var stream = WatchdogCommandStream()
        let initial = try stream.append(combined[..<splitIndex])
        let remaining = try stream.append(combined[splitIndex...])
        try stream.finish()

        #expect(initial + remaining == [first, second])
    }

    @Test("Oversized and incomplete commands are rejected")
    func rejectsInvalidFrames() throws {
        var oversized = WatchdogCommandStream()
        #expect(throws: WatchdogProtocolError.frameTooLarge) {
            try oversized.append(Data(
                repeating: 0x41,
                count: WatchdogCommandStream.maximumFrameBytes + 1
            ))
        }

        var incomplete = WatchdogCommandStream()
        _ = try incomplete.append(Data("{\"action\":\"update\"}".utf8))
        #expect(throws: WatchdogProtocolError.incompleteFrame) {
            try incomplete.finish()
        }
    }

    @Test("A command cannot allocate an unbounded process list")
    func rejectsTooManyProcesses() throws {
        let processes = (0...WatchdogCommandStream.maximumProcessCount).map {
            WatchdogProcessIdentity(pid: Int32($0 + 2), startTimeMicroseconds: UInt64($0))
        }
        let command = WatchdogCommand(action: .update, processes: processes)
        var frame = try JSONEncoder().encode(command)
        frame.append(0x0A)
        var stream = WatchdogCommandStream()

        #expect(throws: WatchdogProtocolError.tooManyProcesses) {
            try stream.append(frame)
        }
    }

    @Test("Privileged requests and responses preserve verified process identities")
    func privilegedProtocolRoundTrip() throws {
        let identity = PrivilegedProcessIdentity(
            pid: 42,
            startTimeMicroseconds: 123_456
        )
        let request = PrivilegedProcessRequest(
            action: .stop,
            processes: [identity]
        )
        let decodedRequest = try JSONDecoder().decode(
            PrivilegedProcessRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decodedRequest == request)

        let response = PrivilegedProcessResponse(
            applied: [identity],
            totalCPUTimeNanoseconds: 900
        )
        let decodedResponse = try JSONDecoder().decode(
            PrivilegedProcessResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decodedResponse == response)
        #expect(PrivilegedProcessProtocol.maximumProcessCount == 4_096)
    }
}
