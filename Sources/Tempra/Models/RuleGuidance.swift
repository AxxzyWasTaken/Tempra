import Foundation

enum RuleGuidanceSeverity: Int, Comparable, Sendable {
    case information
    case caution
    case critical

    static func < (lhs: RuleGuidanceSeverity, rhs: RuleGuidanceSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RuleGuidanceKind: String, Sendable {
    case forceQuitCanDiscardWork
    case audioProtectionDisabled
    case visibleBackgroundPause
    case aggressiveImmediateLimit
    case administratorAccessRequired
}

struct RuleGuidance: Identifiable, Equatable, Sendable {
    let kind: RuleGuidanceKind
    let severity: RuleGuidanceSeverity
    let title: String
    let message: String
    let symbolName: String

    var id: RuleGuidanceKind { kind }
}

enum RuleGuidanceEvaluator {
    static func evaluate(_ rule: AppRule) -> [RuleGuidance] {
        var guidance: [RuleGuidance] = []

        if rule.quitAfterMinutes != nil {
            guidance.append(RuleGuidance(
                kind: .forceQuitCanDiscardWork,
                severity: .critical,
                title: "Force quit can discard work",
                message: "The idle action stops the app without asking it to save open documents.",
                symbolName: "exclamationmark.octagon.fill"
            ))
        }

        if rule.action != .none, !rule.protectAudio {
            guidance.append(RuleGuidance(
                kind: .audioProtectionDisabled,
                severity: .caution,
                title: "Audio can stop",
                message: "This rule can pause or slow a process while it is producing audio.",
                symbolName: "speaker.slash.fill"
            ))
        }

        if rule.action == .pause, !rule.onlyWhenHidden {
            guidance.append(RuleGuidance(
                kind: .visibleBackgroundPause,
                severity: .caution,
                title: "Visible windows can stop updating",
                message: "A background app can remain visible even when it is not the frontmost app.",
                symbolName: "macwindow.badge.exclamationmark"
            ))
        }

        if rule.action == .limit,
           rule.limitPercent <= 10,
           rule.delaySeconds == 0 {
            guidance.append(RuleGuidance(
                kind: .aggressiveImmediateLimit,
                severity: .caution,
                title: "Immediate limit is strict",
                message: "A limit of 10% CPU or less starts as soon as the app is eligible. Interactive work can feel delayed.",
                symbolName: "gauge.with.dots.needle.0percent"
            ))
        }

        if rule.runOnEfficiencyCores {
            guidance.append(RuleGuidance(
                kind: .administratorAccessRequired,
                severity: .information,
                title: "Administrator access is required",
                message: "macOS requires Tempra’s verified helper to change process scheduling policy.",
                symbolName: "lock.shield"
            ))
        }

        return guidance.sorted {
            if $0.severity != $1.severity {
                return $0.severity > $1.severity
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}
