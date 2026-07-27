import Foundation

struct HighCPUAlert: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL?
    let cpuPercent: Double
    let threshold: Double
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        applicationURL: URL?,
        cpuPercent: Double,
        threshold: Double,
        duration: TimeInterval
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationURL = applicationURL
        self.cpuPercent = cpuPercent
        self.threshold = threshold
        self.duration = duration
    }
}
