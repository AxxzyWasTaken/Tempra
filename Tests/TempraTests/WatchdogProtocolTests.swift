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
        let second = WatchdogCommand(
            action: .armResume,
            processes: [],
            resumeDeadlines: [WatchdogResumeDeadline(
                process: first.processes[0],
                resumeAfterMilliseconds: 100
            )]
        )
        let third = WatchdogCommand(
            action: .synchronizeResume,
            processes: [],
            resumeDeadlines: []
        )
        let fourth = WatchdogCommand(action: .disarm, processes: [])
        let combined = try [first, second, third, fourth].reduce(into: Data()) {
            $0.append(try JSONEncoder().encode($1))
            $0.append(0x0A)
        }
        let splitIndex = combined.index(combined.startIndex, offsetBy: combined.count / 2)

        var stream = WatchdogCommandStream()
        let initial = try stream.append(combined[..<splitIndex])
        let remaining = try stream.append(combined[splitIndex...])
        try stream.finish()

        #expect(initial + remaining == [first, second, third, fourth])
    }

    @Test("Automatic-resume commands require a bounded positive deadline")
    func automaticResumeCommandsRequireDeadline() throws {
        let process = WatchdogProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let zeroDeadline = WatchdogResumeDeadline(
            process: process,
            resumeAfterMilliseconds: 0
        )
        let excessiveDeadline = WatchdogResumeDeadline(
            process: process,
            resumeAfterMilliseconds: UInt32(Int32.max) + 1
        )
        let validDeadline = WatchdogResumeDeadline(
            process: process,
            resumeAfterMilliseconds: 100
        )
        let invalidCommands = [
            WatchdogCommand(action: .armResume, processes: [process]),
            WatchdogCommand(
                action: .armResume,
                processes: [],
                resumeDeadlines: [zeroDeadline]
            ),
            WatchdogCommand(
                action: .synchronizeResume,
                processes: [],
                resumeDeadlines: [excessiveDeadline]
            ),
            WatchdogCommand(
                action: .armResume,
                processes: [],
                resumeDeadlines: [validDeadline, validDeadline]
            ),
            WatchdogCommand(
                action: .update,
                processes: [process],
                resumeDeadlines: [validDeadline]
            ),
            WatchdogCommand(action: .disarm, processes: [process]),
        ]

        for command in invalidCommands {
            var frame = try JSONEncoder().encode(command)
            frame.append(0x0A)
            var stream = WatchdogCommandStream()
            #expect(throws: WatchdogProtocolError.invalidCommand) {
                try stream.append(frame)
            }
        }
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
            processes: [identity],
            automaticResumeAfterMilliseconds: 100
        )
        let decodedRequest = try JSONDecoder().decode(
            PrivilegedProcessRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decodedRequest == request)
        #expect(decodedRequest.automaticResumeAfterMilliseconds == 100)

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
