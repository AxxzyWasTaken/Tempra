import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process critical file activity probe")
struct ProcessCriticalFileActivityProbeTests {
    @Test("Writable partial-download files are protected", arguments: [
        "/tmp/video.crdownload",
        "/tmp/archive.download",
        "/tmp/package.part",
    ])
    func writableDownloadFile(path: String) {
        #expect(ProcessCriticalFileActivityProbe.isActiveDownload(
            path: path,
            openFlags: UInt32(bitPattern: O_WRONLY)
        ))
        #expect(ProcessCriticalFileActivityProbe.isActiveDownload(
            path: path,
            openFlags: UInt32(bitPattern: O_RDWR)
        ))
    }

    @Test("Read-only and completed files are not protected")
    func ordinaryFiles() {
        #expect(!ProcessCriticalFileActivityProbe.isActiveDownload(
            path: "/tmp/video.crdownload",
            openFlags: UInt32(bitPattern: O_RDONLY)
        ))
        #expect(!ProcessCriticalFileActivityProbe.isActiveDownload(
            path: "/tmp/video.mp4",
            openFlags: UInt32(bitPattern: O_WRONLY)
        ))
    }

    @Test("The live probe finds an open partial-download file")
    func liveProbeFindsOpenDownload() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("part")
        try Data().write(to: fileURL, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: fileURL)
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: getpid())
        )

        let activity = ProcessCriticalFileActivityProbe().activity(for: identity)

        try handle.close()
        try FileManager.default.removeItem(at: fileURL)
        #expect(activity == .activeDownload)
    }
}
