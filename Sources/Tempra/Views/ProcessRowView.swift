import SwiftUI

private struct TempraDotAppearance {
    let color: Color
    let fill: TempraDotFill
}

private func dotAppearance(
    for item: AppDisplayItem,
    highlightsFrontmostWaiting: Bool = false
) -> TempraDotAppearance {
    if item.isAttention {
        return TempraDotAppearance(color: TempraPalette.waiting, fill: .full)
    }

    switch item.status {
    case .disabled:
        return TempraDotAppearance(color: TempraPalette.running, fill: .none)
    case .waiting:
        return TempraDotAppearance(
            color: TempraPalette.waiting,
            fill: highlightsFrontmostWaiting && item.isFrontmost ? .full : .half
        )
    case .limited:
        return TempraDotAppearance(color: TempraPalette.slowed, fill: .full)
    case .paused:
        return TempraDotAppearance(color: TempraPalette.stopped, fill: .full)
    case .energyEfficient:
        return TempraDotAppearance(color: TempraPalette.waiting, fill: .full)
    case .audioProtected:
        return TempraDotAppearance(color: .purple, fill: .half)
    case .snoozed:
        return TempraDotAppearance(color: TempraPalette.accent, fill: .half)
    case .unavailable:
        return TempraDotAppearance(color: TempraPalette.stopped, fill: .half)
    case .normal, .notRunning:
        guard let rule = item.rule, rule.isEnabled else {
            return TempraDotAppearance(color: TempraPalette.running, fill: .none)
        }
        if rule.action == .pause {
            return TempraDotAppearance(color: TempraPalette.stopped, fill: .half)
        }
        if rule.action == .limit {
            return TempraDotAppearance(color: TempraPalette.slowed, fill: .half)
        }
        if rule.runOnEfficiencyCores {
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
                    .frame(width: 16, height: 16)

                HStack(spacing: 3) {
                    Text(item.name)
                        .font(TempraTypography.process)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let ruleTag {
                        Text(ruleTag)
                            .font(TempraTypography.ruleTag)
                            .foregroundStyle(ruleTagColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                cpuValue(item.cpuPercent)
                    .frame(width: TempraLayout.currentCPUColumnWidth, alignment: .trailing)
                cpuValue(item.averageCPUPercent)
                    .frame(width: TempraLayout.averageCPUColumnWidth, alignment: .trailing)
                Text(item.cpuPowerText)
                    .font(TempraTypography.processValue)
                    .foregroundStyle(TempraPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: TempraLayout.powerColumnWidth, alignment: .trailing)
                    .help(
                        "Approximate app power based on processor energy attributed by macOS, "
                            + "averaged over three seconds. Actual total power may be higher "
                            + "because GPU, networking, storage, display, and shared system "
                            + "power cannot be fully attributed to an app."
                    )
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .frame(height: TempraLayout.processRowHeight)
            .contentShape(Rectangle())
            .background(isSelected ? TempraPalette.selectedRow : Color.clear)
        }
        .buttonStyle(.plain)
        .opacity(item.isRunning ? 1 : 0.58)
        .help(rowHelp)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if item.isPlayingAudio {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9))
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

    private var ruleTag: String? {
        if item.isSoundSourceComponent {
            return "· audio"
        }
        if isSystemProcess {
            return "· system"
        }
        if item.isStandaloneProcess {
            return "· process"
        }
        guard let rule = item.rule else { return item.isService ? "· service" : nil }
        guard rule.isEnabled, item.status != .disabled else { return "· off" }
        return switch rule.action {
        case .none: rule.runOnEfficiencyCores ? "· efficient" : nil
        case .limit: "< \(Int(rule.limitPercent))%"
        case .pause: "· paused"
        }
    }

    private var rowHelp: String {
        if item.isSoundSourceComponent {
            return "SoundSource audio component · monitor only"
        }
        if isSystemProcess {
            return "Protected system process · monitor only"
        }
        return "\(item.stateText) · Current \(item.cpuText) · 1-minute average \(item.averageCPUText)"
    }

    private var ruleTagColor: Color {
        if isSystemProcess {
            return TempraPalette.secondaryText
        }
        guard item.rule?.isEnabled == true, item.status != .disabled else {
            return TempraPalette.tertiaryText
        }
        return item.status == .paused
            ? TempraPalette.stopped
            : TempraPalette.secondaryText
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
                    .frame(width: 16, height: 16)

                HStack(spacing: 3) {
                    Text(item.name)
                        .font(TempraTypography.process)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let ruleTag {
                        Text(ruleTag)
                            .font(TempraTypography.ruleTag)
                            .foregroundStyle(TempraPalette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text(savedCPUValue)
                    .font(TempraTypography.processValue)
                    .foregroundStyle(TempraPalette.primaryText)
                    .lineLimit(1)
                    .frame(width: TempraLayout.averageCPUColumnWidth, alignment: .trailing)

                Text(savedPowerValue)
                    .font(TempraTypography.processValue)
                    .foregroundStyle(TempraPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: TempraLayout.powerColumnWidth, alignment: .trailing)
                    .help(
                        "Approximate reduction calculated from Tempra’s prevented CPU estimate "
                            + "and this app’s measured energy per CPU time. GPU and other power "
                            + "that macOS cannot attribute to the app are not included."
                    )
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .frame(height: TempraLayout.processRowHeight)
            .contentShape(Rectangle())
            .background(isSelected ? TempraPalette.selectedRow : Color.clear)
        }
        .buttonStyle(.plain)
        .opacity(item.isRunning ? 1 : 0.58)
        .help(item.stateText)
    }

    private var savedCPUValue: String {
        guard item.isRunning, item.status != .disabled else { return "—" }
        return String(format: "%.1f%%", item.estimatedSavedCPUPercent)
    }

    private var savedPowerValue: String {
        guard item.isRunning, item.status != .disabled else { return "—" }
        return item.savedPowerText
    }

    private var ruleTag: String? {
        guard let rule = item.rule else { return nil }
        guard rule.isEnabled, item.status != .disabled else { return "· off" }
        return switch rule.action {
        case .none: rule.runOnEfficiencyCores ? "· efficient" : nil
        case .limit: "< \(Int(rule.limitPercent))%"
        case .pause: "· paused"
        }
    }

    private var dot: TempraDotAppearance {
        dotAppearance(for: item)
    }
}
