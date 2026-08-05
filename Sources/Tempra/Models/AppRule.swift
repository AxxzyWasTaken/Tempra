import Foundation

enum CPULimitRange {
    static let minimumPercent = 1.0
    static let oneCorePercent = 100.0

    static var logicalCoreCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    static var maximumPercent: Double {
        maximumPercent(logicalCoreCount: logicalCoreCount)
    }

    static var allowed: ClosedRange<Double> {
        minimumPercent...maximumPercent
    }

    static var singleCore: ClosedRange<Double> {
        minimumPercent...min(oneCorePercent, maximumPercent)
    }

    static func maximumPercent(logicalCoreCount: Int) -> Double {
        Double(max(1, logicalCoreCount)) * oneCorePercent
    }

    static func clamped(_ percent: Double) -> Double {
        min(max(allowed.lowerBound, percent), allowed.upperBound)
    }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case limit
    case pause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Do Nothing"
        case .limit: "Limit CPU"
        case .pause: "Pause"
        }
    }
}

enum SoundSourceCompatibilityPolicy {
    static let primaryBundleIdentifier = "com.rogueamoeba.soundsource"

    private static let protectedBundleIdentifiers: Set<String> = [
        primaryBundleIdentifier,
        "com.rogueamoeba.aceagent",
        "com.rogueamoeba.arkaudiod",
    ]
    private static let protectedExecutableNames: Set<String> = [
        "aceagent",
        "arkaudiod"
    ]

    static func isProtected(
        bundleIdentifier: String,
        applicationURL: URL? = nil
    ) -> Bool {
        let normalizedIdentifier = bundleIdentifier.lowercased()
        if protectedBundleIdentifiers.contains(normalizedIdentifier) {
            return true
        }
        if let command = BackgroundProcessPolicy.command(from: bundleIdentifier),
           isProtectedExecutable(command) {
            return true
        }
        guard let applicationURL else { return false }
        let standardizedURL = URL(
            filePath: applicationURL.path,
            directoryHint: .notDirectory
        ).standardized
        return standardizedURL.pathComponents.contains { component in
            component.caseInsensitiveCompare("SoundSource.app") == .orderedSame
        }
    }

    static func isProtectedExecutable(_ command: String) -> Bool {
        protectedExecutableNames.contains(
            (command as NSString).lastPathComponent.lowercased()
        )
    }
}

enum SystemProcessRulePolicy {
    private static let windowServerBundleIdentifier = "com.apple.WindowServer"
    private static let backgroundCommandPrefix = "tempra.background:command:"

    static func isWindowServer(bundleIdentifier: String) -> Bool {
        if bundleIdentifier.caseInsensitiveCompare(windowServerBundleIdentifier) == .orderedSame {
            return true
        }
        guard bundleIdentifier.hasPrefix(backgroundCommandPrefix) else { return false }
        let command = String(bundleIdentifier.dropFirst(backgroundCommandPrefix.count))
        return (command as NSString).lastPathComponent
            .caseInsensitiveCompare("WindowServer") == .orderedSame
    }

    static func normalized(_ rule: AppRule) -> AppRule {
        if SoundSourceCompatibilityPolicy.isProtected(
            bundleIdentifier: rule.bundleIdentifier,
            applicationURL: rule.applicationURL
        ) {
            var normalized = rule
            normalized.action = .none
            normalized.runOnEfficiencyCores = false
            normalized.hideAfterMinutes = nil
            normalized.quitAfterMinutes = nil
            return normalized
        }

        if isWindowServer(bundleIdentifier: rule.bundleIdentifier),
           rule.action == .limit {
            var normalized = rule
            normalized.action = .none
            normalized.runOnEfficiencyCores = true
            return normalized
        }

        var normalized = rule
        if normalized.action == .pause {
            normalized.runOnEfficiencyCores = false
        }
        return normalized
    }
}

struct AppRule: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var displayName: String
    var action: RuleAction = .none
    var runOnEfficiencyCores: Bool = false
    var limitPercent: Double = 50
    var delaySeconds: Double = 0
    var protectAudio: Bool = true
    var onlyWhenHidden: Bool = false
    var hideAfterMinutes: Double?
    var quitAfterMinutes: Double?
    var isEnabled: Bool = true
    var applicationURL: URL?
    var updatedAt: Date = Date()

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        displayName: String,
        action: RuleAction = .none,
        runOnEfficiencyCores: Bool = false,
        limitPercent: Double = 50,
        delaySeconds: Double = 0,
        protectAudio: Bool = true,
        onlyWhenHidden: Bool = false,
        hideAfterMinutes: Double? = nil,
        quitAfterMinutes: Double? = nil,
        isEnabled: Bool = true,
        applicationURL: URL? = nil,
        updatedAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.action = action
        self.runOnEfficiencyCores = action != .pause && runOnEfficiencyCores
        self.limitPercent = limitPercent
        self.delaySeconds = delaySeconds
        self.protectAudio = protectAudio
        self.onlyWhenHidden = onlyWhenHidden
        self.hideAfterMinutes = hideAfterMinutes
        self.quitAfterMinutes = quitAfterMinutes
        self.isEnabled = isEnabled
        self.applicationURL = applicationURL
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case displayName
        case action
        case runOnEfficiencyCores
        case limitPercent
        case delaySeconds
        case protectAudio
        case onlyWhenHidden
        case hideAfterMinutes
        case quitAfterMinutes
        case isEnabled
        case applicationURL
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        let storedAction = try container.decodeIfPresent(String.self, forKey: .action) ?? "none"
        let isLegacyEfficiencyRule = storedAction == "efficiency"
        if isLegacyEfficiencyRule {
            action = .none
        } else if let decodedAction = RuleAction(rawValue: storedAction) {
            action = decodedAction
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unknown rule action \(storedAction)."
            )
        }
        runOnEfficiencyCores = try container.decodeIfPresent(
            Bool.self,
            forKey: .runOnEfficiencyCores
        ) ?? isLegacyEfficiencyRule
        if action == .pause {
            runOnEfficiencyCores = false
        }
        limitPercent = try container.decodeIfPresent(Double.self, forKey: .limitPercent) ?? 50
        delaySeconds = try container.decodeIfPresent(Double.self, forKey: .delaySeconds) ?? 0
        protectAudio = try container.decodeIfPresent(Bool.self, forKey: .protectAudio) ?? true
        onlyWhenHidden = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenHidden) ?? false
        hideAfterMinutes = try container.decodeIfPresent(Double.self, forKey: .hideAfterMinutes)
        quitAfterMinutes = try container.decodeIfPresent(Double.self, forKey: .quitAfterMinutes)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        applicationURL = try container.decodeIfPresent(URL.self, forKey: .applicationURL)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(action, forKey: .action)
        try container.encode(runOnEfficiencyCores, forKey: .runOnEfficiencyCores)
        try container.encode(limitPercent, forKey: .limitPercent)
        try container.encode(delaySeconds, forKey: .delaySeconds)
        try container.encode(protectAudio, forKey: .protectAudio)
        try container.encode(onlyWhenHidden, forKey: .onlyWhenHidden)
        try container.encodeIfPresent(hideAfterMinutes, forKey: .hideAfterMinutes)
        try container.encodeIfPresent(quitAfterMinutes, forKey: .quitAfterMinutes)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(applicationURL, forKey: .applicationURL)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var summary: String {
        let actionSummary: String
        switch action {
        case .none:
            actionSummary = runOnEfficiencyCores ? "Power-saving cores" : "Idle actions"
        case .limit:
            actionSummary = "Limit to \(Int(limitPercent))%"
        case .pause:
            actionSummary = "Pause"
        }

        return isEnabled ? actionSummary : "Disabled · \(actionSummary)"
    }

    var preview: String {
        guard hasBehavior else {
            return "Tempra will not manage \(displayName)."
        }

        var behaviors: [String] = []
        switch action {
        case .none:
            break
        case .limit:
            behaviors.append("limit CPU to \(Int(limitPercent))%")
        case .pause:
            behaviors.append("pause the app")
        }
        if runOnEfficiencyCores {
            behaviors.append("run it on the CPU’s power-saving cores")
        }
        if let hideAfterMinutes {
            behaviors.append("hide it after \(Int(hideAfterMinutes)) minutes")
        }
        if let quitAfterMinutes {
            behaviors.append("force quit it after \(Int(quitAfterMinutes)) minutes")
        }

        let condition = onlyWhenHidden ? " while it is hidden" : " while it is in the background"
        let audio = protectAudio ? " Tempra will wait while it is playing audio." : ""
        let prefix = isEnabled ? "" : "When re-enabled, "
        return "\(prefix)Tempra will \(behaviors.joined(separator: " and "))\(condition).\(audio)"
    }

    var hasBehavior: Bool {
        action != .none
            || runOnEfficiencyCores
            || hideAfterMinutes != nil
            || quitAfterMinutes != nil
    }

    var usesEfficiencyCoreScheduling: Bool {
        runOnEfficiencyCores
    }
}

extension AppRule {
    static let delayOptions: [Double] = [0, 5, 10, 30, 60, 300]
    static let idleMinuteRange = 1.0...60.0

    static func delayTitle(_ seconds: Double) -> String {
        switch seconds {
        case 0: "Automatic"
        case 60: "1 minute"
        case 300: "5 minutes"
        default: "\(Int(seconds)) seconds"
        }
    }
}
