import Foundation

enum ActivityKind: String, Codable, Sendable {
    case waiting
    case limited
    case paused
    case restored
    case audioProtected
    case networkProtected
    case energyEfficient
    case hidden
    case quit
    case gracefulQuit
    case relaunched
    case snoozed
    case ruleSaved
    case ruleDisabled
    case ruleRemoved
    case highCPU
    case error

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .limited: "CPU limited"
        case .paused: "Paused"
        case .restored: "Restored"
        case .audioProtected: "Audio protected"
        case .networkProtected: "Network protected"
        case .energyEfficient: "Lower CPU priority"
        case .hidden: "App hidden"
        case .quit: "App force quit"
        case .gracefulQuit: "App quit"
        case .relaunched: "App relaunched"
        case .snoozed: "Temporarily resumed"
        case .ruleSaved: "Rule saved"
        case .ruleDisabled: "Rule disabled"
        case .ruleRemoved: "Rule removed"
        case .highCPU: "High CPU"
        case .error: "Action failed"
        }
    }

    var symbolName: String {
        switch self {
        case .waiting: "clock.fill"
        case .limited: "gauge.with.dots.needle.33percent"
        case .paused: "pause.circle.fill"
        case .restored: "play.circle.fill"
        case .audioProtected: "speaker.wave.2.fill"
        case .networkProtected: "network"
        case .energyEfficient: "arrow.down.circle.fill"
        case .hidden: "eye.slash.fill"
        case .quit: "xmark.circle.fill"
        case .gracefulQuit: "power"
        case .relaunched: "arrow.clockwise.circle.fill"
        case .snoozed: "moon.zzz.fill"
        case .ruleSaved: "checkmark.circle.fill"
        case .ruleDisabled: "slash.circle.fill"
        case .ruleRemoved: "trash.fill"
        case .highCPU: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let bundleIdentifier: String
    let displayName: String
    let kind: ActivityKind
    let detail: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        bundleIdentifier: String,
        displayName: String,
        kind: ActivityKind,
        detail: String
    ) {
        self.id = id
        self.date = date
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.kind = kind
        self.detail = detail
    }
}
