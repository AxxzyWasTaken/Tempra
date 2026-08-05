import Foundation

enum CPUHistoryRange: String, Codable, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case hour = "1h"
    case day = "24h"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        }
    }

    var menuTitle: String {
        switch self {
        case .fiveMinutes: "Last 5 Minutes"
        case .hour: "Last Hour"
        case .day: "Last 24 Hours"
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum ProfileLimitPolicy: String, Codable, CaseIterable, Identifiable {
    case inherit
    case maximum
    case minimum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: "Use Saved"
        case .maximum: "Cap At"
        case .minimum: "At Least"
        }
    }
}

enum ProfileDelayPolicy: String, Codable, CaseIterable, Identifiable {
    case inherit
    case maximum
    case minimum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: "Use Saved"
        case .maximum: "At Most"
        case .minimum: "At Least"
        }
    }
}

enum ProfilePowerCondition: String, Codable, CaseIterable, Identifiable {
    case any
    case battery
    case externalPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any power source"
        case .battery: "On battery"
        case .externalPower: "On external power"
        }
    }
}

struct ProfileActivation: Codable, Equatable {
    var powerCondition: ProfilePowerCondition = .any
    var idleAfterMinutes: Double?

    var isAutomatic: Bool {
        powerCondition != .any || idleAfterMinutes != nil
    }

    var conditionCount: Int {
        (powerCondition == .any ? 0 : 1) + (idleAfterMinutes == nil ? 0 : 1)
    }
}

struct ManagementProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var limitPolicy: ProfileLimitPolicy
    var limitPercent: Double
    var delayPolicy: ProfileDelayPolicy
    var delaySeconds: TimeInterval
    var activation: ProfileActivation

    init(
        id: UUID = UUID(),
        name: String,
        limitPolicy: ProfileLimitPolicy = .inherit,
        limitPercent: Double = 50,
        delayPolicy: ProfileDelayPolicy = .inherit,
        delaySeconds: TimeInterval = 10,
        activation: ProfileActivation = ProfileActivation()
    ) {
        self.id = id
        self.name = name
        self.limitPolicy = limitPolicy
        self.limitPercent = limitPercent
        self.delayPolicy = delayPolicy
        self.delaySeconds = delaySeconds
        self.activation = activation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case limitPolicy
        case limitPercent
        case delayPolicy
        case delaySeconds
        case activation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        limitPolicy = try container.decode(ProfileLimitPolicy.self, forKey: .limitPolicy)
        limitPercent = try container.decode(Double.self, forKey: .limitPercent)
        delayPolicy = try container.decode(ProfileDelayPolicy.self, forKey: .delayPolicy)
        delaySeconds = try container.decode(TimeInterval.self, forKey: .delaySeconds)
        activation = try container.decodeIfPresent(
            ProfileActivation.self,
            forKey: .activation
        ) ?? ProfileActivation()
    }

    func applying(to rule: AppRule) -> AppRule {
        var adjusted = rule
        if adjusted.action == .limit {
            switch limitPolicy {
            case .inherit:
                break
            case .maximum:
                adjusted.limitPercent = min(adjusted.limitPercent, limitPercent)
            case .minimum:
                adjusted.limitPercent = max(adjusted.limitPercent, limitPercent)
            }
        }

        switch delayPolicy {
        case .inherit:
            break
        case .maximum:
            adjusted.delaySeconds = min(adjusted.delaySeconds, delaySeconds)
        case .minimum:
            adjusted.delaySeconds = max(adjusted.delaySeconds, delaySeconds)
        }
        return adjusted
    }
}

struct AppPreferences: Codable, Equatable {
    var highCPUAlertsEnabled = false
    var highCPUThreshold: Double = 100
    var highCPUDuration: TimeInterval = 30
    var notificationCooldown: TimeInterval = 15 * 60
    var ignoredHighCPUAlertBundleIdentifiers: Set<String> = []
    var launchAtLogin = false
    var profiles: [ManagementProfile] = []
    var activeProfileID: UUID?
    var appearance: AppAppearance = .system
    var includesEssentialSystemProcesses = false
    var continuousMonitoringEnabled = false
    var showsCPUHistoryGraph = true
    var showsCPUUsageInMenuBar = true
    var historyRange: CPUHistoryRange = .fiveMinutes
    var hasPresentedPrivilegedAccessOnboarding = false
    var managementPauseUntil: Date?

    var activeProfile: ManagementProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    private enum CodingKeys: String, CodingKey {
        case highCPUAlertsEnabled = "notificationsEnabled"
        case highCPUThreshold
        case highCPUDuration
        case notificationCooldown
        case ignoredHighCPUAlertBundleIdentifiers
        case launchAtLogin
        case profiles
        case activeProfileID
        case appearance
        case includesEssentialSystemProcesses
        case continuousMonitoringEnabled
        case showsCPUHistoryGraph
        case showsCPUUsageInMenuBar
        case historyRange
        case hasPresentedPrivilegedAccessOnboarding
        case managementPauseUntil
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        highCPUAlertsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .highCPUAlertsEnabled
        ) ?? false
        highCPUThreshold = try container.decodeIfPresent(Double.self, forKey: .highCPUThreshold) ?? 100
        highCPUDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .highCPUDuration) ?? 30
        notificationCooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .notificationCooldown) ?? 15 * 60
        ignoredHighCPUAlertBundleIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .ignoredHighCPUAlertBundleIdentifiers
        ) ?? []
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        let decodedProfiles = try container.decodeIfPresent(
            [ManagementProfile].self,
            forKey: .profiles
        ) ?? []
        var seenProfileIDs = Set<UUID>()
        guard decodedProfiles.allSatisfy({ seenProfileIDs.insert($0.id).inserted }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .profiles,
                in: container,
                debugDescription: "Profile identifiers must be unique."
            )
        }
        profiles = decodedProfiles
        let decodedActiveProfileID = try container.decodeIfPresent(
            UUID.self,
            forKey: .activeProfileID
        )
        activeProfileID = profiles.contains { $0.id == decodedActiveProfileID }
            ? decodedActiveProfileID
            : nil
        appearance = try container.decodeIfPresent(
            AppAppearance.self,
            forKey: .appearance
        ) ?? .system
        includesEssentialSystemProcesses = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesEssentialSystemProcesses
        ) ?? false
        continuousMonitoringEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .continuousMonitoringEnabled
        ) ?? false
        showsCPUHistoryGraph = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsCPUHistoryGraph
        ) ?? true
        showsCPUUsageInMenuBar = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsCPUUsageInMenuBar
        ) ?? true
        historyRange = try container.decodeIfPresent(
            CPUHistoryRange.self,
            forKey: .historyRange
        ) ?? .fiveMinutes
        hasPresentedPrivilegedAccessOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasPresentedPrivilegedAccessOnboarding
        ) ?? false
        managementPauseUntil = try container.decodeIfPresent(
            Date.self,
            forKey: .managementPauseUntil
        )
    }

    static let durationOptions: [TimeInterval] = [10, 30, 60, 300]
    static let cooldownOptions: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]

    static func durationTitle(_ duration: TimeInterval) -> String {
        switch duration {
        case 60: "1 minute"
        case 300: "5 minutes"
        default: "\(Int(duration)) seconds"
        }
    }

    static func cooldownTitle(_ duration: TimeInterval) -> String {
        switch duration {
        case 60 * 60: "1 hour"
        default: "\(Int(duration / 60)) minutes"
        }
    }
}
