import SwiftUI

private struct TempraDotAppearance {
    let color: Color
    let fill: TempraDotFill
}

struct ManagedProcessPresentation: Equatable {
    enum Indicator: Equatable {
        case runtimeStatus
        case cpuLimit(isActive: Bool)
    }

    let actionLabel: String
    let statusLabel: String
    let indicator: Indicator

    init(item: AppDisplayItem) {
        statusLabel = item.status.label

        switch item.status {
        case .limited(let percent):
            actionLabel = Self.limitLabel(percent)
            indicator = .cpuLimit(isActive: true)
        case .limitedWithProtectedProcesses(let percent):
            actionLabel = "Best effort · \(Int(percent))%"
            indicator = .cpuLimit(isActive: true)
        case .paused:
            actionLabel = "Paused"
            indicator = .runtimeStatus
        case .lowerPriority:
            if let rule = item.rule, rule.isEnabled, rule.action == .limit {
                actionLabel = Self.limitLabel(rule.limitPercent)
                indicator = .cpuLimit(isActive: false)
            } else {
                actionLabel = "Lower CPU priority"
                indicator = .runtimeStatus
            }
        case .normal, .waiting, .audioProtected, .networkProtected, .snoozed,
                .managementPaused, .disabled, .notRunning, .unavailable:
            guard item.isCPULimitSessionActive else {
                actionLabel = item.status.label
                indicator = .runtimeStatus
                return
            }
            if let rule = item.rule, rule.isEnabled, rule.action == .limit {
                actionLabel = Self.limitLabel(rule.limitPercent)
            } else {
                actionLabel = "CPU limit active"
            }
            indicator = .cpuLimit(isActive: true)
        }
    }

    private static func limitLabel(_ percent: Double) -> String {
        "Limited to \(Int(percent))%"
    }
}

private func dotAppearance(
    for item: AppDisplayItem,
    highlightsFrontmostWaiting: Bool = false
) -> TempraDotAppearance {
    if item.isAttention {
        return TempraDotAppearance(color: TempraPalette.waiting, fill: .full)
    }

    switch item.status {
    case .disabled, .managementPaused:
        return TempraDotAppearance(color: TempraPalette.running, fill: .none)
    case .waiting:
        return TempraDotAppearance(
            color: TempraPalette.waiting,
            fill: highlightsFrontmostWaiting && item.isFrontmost ? .full : .half
        )
    case .limited, .limitedWithProtectedProcesses:
        return TempraDotAppearance(color: TempraPalette.slowed, fill: .full)
    case .paused:
        return TempraDotAppearance(color: TempraPalette.stopped, fill: .full)
    case .lowerPriority:
        return TempraDotAppearance(color: TempraPalette.waiting, fill: .full)
    case .audioProtected:
        return TempraDotAppearance(color: .purple, fill: .half)
    case .networkProtected:
        return TempraDotAppearance(color: .blue, fill: .half)
    case .snoozed:
        return TempraDotAppearance(color: TempraPalette.accent, fill: .half)
    case .unavailable:
        return TempraDotAppearance(color: TempraPalette.stopped, fill: .half)
    case .normal, .notRunning:
        if item.isCPULimitSessionActive {
            return TempraDotAppearance(color: TempraPalette.slowed, fill: .full)
        }
        guard let rule = item.rule, rule.isEnabled else {
            return TempraDotAppearance(color: TempraPalette.running, fill: .none)
        }
        if rule.action == .pause {
            return TempraDotAppearance(color: TempraPalette.stopped, fill: .half)
        }
        if rule.action == .limit {
            return TempraDotAppearance(color: TempraPalette.slowed, fill: .half)
        }
        if rule.lowersCPUPriority {
            return TempraDotAppearance(color: TempraPalette.waiting, fill: .half)
        }
        return TempraDotAppearance(color: TempraPalette.running, fill: .none)
    }
}

struct ProcessRowView: View {
    let item: AppDisplayItem
    let isSystemProcess: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: TempraLayout.processColumnSpacing) {
                statusIndicator
                    .frame(width: 12)

                Image(nsImage: item.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

                HStack(spacing: 6) {
                    Text(item.name)
                        .font(TempraTypography.process)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let classificationTag {
                        Text(classificationTag)
                            .font(TempraTypography.ruleTag)
                            .foregroundStyle(TempraPalette.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                cpuValue(item.cpuPercent)
                    .frame(width: TempraLayout.currentCPUColumnWidth, alignment: .trailing)
                cpuValue(item.averageCPUPercent)
                    .frame(width: TempraLayout.averageCPUColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .frame(height: TempraLayout.processRowHeight)
            .contentShape(Rectangle())
            .background(
                isSelected ? TempraPalette.selectedRow : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(item.isCurrentApplication)
        .opacity(
            item.isCurrentApplication ? 0.45 : (item.isRunning ? 1 : 0.58)
        )
        .help(rowHelp)
        .accessibilityHint(rowHelp)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if item.isPlayingAudio {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(TempraPalette.tertiaryText)
                .help("Playing audio")
        } else {
            TempraStatusDot(color: dot.color, fill: dot.fill)
                .help(item.stateText)
        }
    }

    private func cpuValue(_ value: Double) -> some View {
        Text(item.isRunning ? String(format: "%.1f", value) : "—")
            .font(TempraTypography.processValue)
            .foregroundStyle(item.isAttention ? TempraPalette.waiting : TempraPalette.primaryText)
    }

    private var classificationTag: String? {
        if item.isCurrentApplication {
            return "this app"
        }
        if item.isSoundSourceComponent {
            return "audio"
        }
        if isSystemProcess {
            return "system"
        }
        if item.isStandaloneProcess {
            return "process"
        }
        return item.isService ? "service" : nil
    }

    private var rowHelp: String {
        if item.isCurrentApplication {
            return "Tempra cannot control itself"
        }
        if item.isSoundSourceComponent {
            return "SoundSource audio component · monitor only"
        }
        if isSystemProcess {
            return "Protected system process · monitor only"
        }
        return "\(item.stateText) · Current \(item.cpuText) · 1-minute average \(item.averageCPUText)"
    }


    private var dot: TempraDotAppearance {
        dotAppearance(for: item, highlightsFrontmostWaiting: true)
    }
}

struct ManagedProcessRowView: View {
    let item: AppDisplayItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: TempraLayout.processColumnSpacing) {
                TempraStatusDot(color: dot.color, fill: dot.fill)
                    .frame(width: 12)

                Image(nsImage: item.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

                HStack(spacing: 6) {
                    Text(item.name)
                        .font(TempraTypography.process)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(actionLabel)
                        .font(TempraTypography.ruleTag)
                        .foregroundStyle(TempraPalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(savedCPUValue)
                    .font(TempraTypography.processValue)
                    .foregroundStyle(TempraPalette.primaryText)
                    .lineLimit(1)
                    .frame(width: TempraLayout.averageCPUColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .frame(height: TempraLayout.processRowHeight)
            .contentShape(Rectangle())
            .background(
                isSelected ? TempraPalette.selectedRow : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .opacity(item.isRunning ? 1 : 0.58)
        .help(
            "\(actionLabel) · Current state: \(presentation.statusLabel) "
                + "· Saved CPU \(savedCPUValue)"
        )
        .accessibilityLabel("\(item.name), \(actionLabel)")
        .accessibilityValue(
            "Current state: \(presentation.statusLabel), saved CPU \(savedCPUValue)"
        )
    }

    private var savedCPUValue: String {
        item.savedCPUText
    }

    private var actionLabel: String {
        presentation.actionLabel
    }

    private var presentation: ManagedProcessPresentation {
        ManagedProcessPresentation(item: item)
    }

    private var dot: TempraDotAppearance {
        switch presentation.indicator {
        case .runtimeStatus:
            dotAppearance(for: item)
        case .cpuLimit(let isActive):
            TempraDotAppearance(
                color: TempraPalette.slowed,
                fill: isActive ? .full : .half
            )
        }
    }
}
