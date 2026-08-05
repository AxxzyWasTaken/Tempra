import Foundation

struct HighCPUAlert: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL?
    let processIdentity: ProcessIdentity
    let cpuPercent: Double
    let threshold: Double
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        applicationURL: URL?,
        processIdentity: ProcessIdentity,
        cpuPercent: Double,
        threshold: Double,
        duration: TimeInterval
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationURL = applicationURL
        self.processIdentity = processIdentity
        self.cpuPercent = cpuPercent
        self.threshold = threshold
        self.duration = duration
    }
}
