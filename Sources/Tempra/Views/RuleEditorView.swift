import SwiftUI

struct RuleEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: AppDisplayItem
    @ObservedObject var store: AppStore
    let onClose: () -> Void

    @State private var original: AppRule
    @State private var draft: AppRule
    @State private var isTitleHovered = false
    @State private var isRemovingRule = false
    @State private var allowsMultipleCPUCores: Bool

    init(
        item: AppDisplayItem,
        store: AppStore,
        initialRule: AppRule? = nil,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.store = store
        self.onClose = onClose
        let initial = SystemProcessRulePolicy.normalized(
            initialRule ?? store.rule(for: item)
        )
        _original = State(initialValue: initial)
        _draft = State(initialValue: initial)
        _allowsMultipleCPUCores = State(
            initialValue: CPULimitRange.maximumPercent > CPULimitRange.oneCorePercent
                && initial.limitPercent > CPULimitRange.oneCorePercent
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            Divider()
                .overlay(TempraPalette.separator)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    inspectorSection("When not in front") {
                        backgroundControls
                    }

                    inspectorSection("Conditions") {
                        conditionControls
                    }

                    inspectorSection("When idle") {
                        idleControls
                    }

                    if !displayedRuleGuidance.isEmpty {
                        inspectorSection("Guidance") {
                            ruleGuidanceSection
                        }
                    }

                    if item.isStandaloneProcess
                        || item.requiresPrivilegedControl
                        || draft.runOnEfficiencyCores {
                        inspectorSection("Process control") {
                            processControlNotice
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
        }
        .frame(
            width: TempraLayout.inspectorBodyWidth,
            height: TempraLayout.inspectorSize.height
        )
        .font(TempraTypography.body)
        .onChange(of: draft.limitPercent) { _, value in
            draft.limitPercent = CPULimitRange.clamped(value)
        }
        .task(id: draft) {
            guard draft != original else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistDraft()
        }
        .onDisappear {
            guard !isRemovingRule else { return }
            persistDraft()
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(TempraTypography.title)
                    .lineLimit(1)
                Text(draft.isEnabled ? "Rule enabled" : "Rule disabled")
                    .font(TempraTypography.footer)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Menu {
                    Toggle("Rule Enabled", isOn: $draft.isEnabled)

                    Divider()
                    if item.canLimitCPU {
                        Button("Gentle · 50%") {
                            draft.action = .limit
                            draft.limitPercent = 50
                        }
                        Button("Strict · 20%") {
                            draft.action = .limit
                            draft.limitPercent = 20
                        }
                    }
                    Button("Pause") {
                        draft.action = .pause
                        draft.runOnEfficiencyCores = false
                    }

                    if store.suspensionUntil(for: item.bundleIdentifier) != nil {
                        Button("End Temporary Resume") {
                            store.endSnooze(bundleIdentifier: item.bundleIdentifier)
                        }
                    } else if store.rules[item.bundleIdentifier] != nil {
                        Button("Resume for 1 Hour") {
                            store.resumeTemporarily(
                                bundleIdentifier: item.bundleIdentifier,
                                for: 60 * 60
                            )
                            onClose()
                        }
                    }

                    if store.rules[item.bundleIdentifier] != nil {
                        Divider()
                        Button("Remove Rule", role: .destructive) {
                            isRemovingRule = true
                            store.removeRule(bundleIdentifier: item.bundleIdentifier)
                            onClose()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Rule Options")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(TempraPalette.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .opacity(isTitleHovered ? 1 : 0.72)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTitleHovered)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .onHover { isTitleHovered = $0 }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Start after")
                    .font(TempraTypography.body)
                    .foregroundStyle(TempraPalette.secondaryText)

                Spacer()

                Menu {
                    Picker("Start after", selection: $draft.delaySeconds) {
                        ForEach(AppRule.delayOptions, id: \.self) { delay in
                            Text(AppRule.delayTitle(delay)).tag(delay)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(AppRule.delayTitle(draft.delaySeconds))
                    }
                    .font(TempraTypography.footer)
                    .foregroundStyle(TempraPalette.primaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Start after \(AppRule.delayTitle(draft.delaySeconds).lowercased())")
            }

            pauseToggle
            efficiencyToggle
            if item.canLimitCPU {
                limitToggle
            }

            if draft.action == .limit {
                HStack(spacing: 9) {
                    TempraNumberField(
                        value: $draft.limitPercent,
                        range: visibleCPULimitRange,
                        width: allowsMultipleCPUCores ? 58 : 48,
                        suffix: "%",
                        accented: true
                    )

                    if allowsMultipleCPUCores {
                        Spacer(minLength: 0)

                        Stepper(
                            value: $draft.limitPercent,
                            in: CPULimitRange.allowed,
                            step: 25
                        ) {
                            Text(cpuCoreSelection)
                                .font(TempraTypography.ruleTag.monospacedDigit())
                                .foregroundStyle(TempraPalette.secondaryText)
                                .frame(width: 54, alignment: .trailing)
                        }
                        .fixedSize()
                    } else {
                        TempraTickedSlider(
                            value: $draft.limitPercent,
                            range: visibleCPULimitRange,
                            step: 1
                        )
                    }
                }
                .padding(.leading, 24)

                if CPULimitRange.maximumPercent > CPULimitRange.oneCorePercent {
                    Toggle("Allow more than one CPU core", isOn: multipleCoreBinding)
                        .toggleStyle(TempraCheckboxToggleStyle())
                        .controlSize(.small)
                        .padding(.leading, 24)
                }

                Text("100% equals one CPU core; brief CPU spikes can still appear.")
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .padding(.leading, 24)
            }
        }
    }

    private var conditionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $draft.protectAudio) {
                Text("Don't stop or slow when sound is playing")
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
                .toggleStyle(TempraCheckboxToggleStyle())
                .controlSize(.small)

            if item.canControlApplication {
                Toggle(isOn: $draft.onlyWhenHidden) {
                    Text("Only stop or slow when app is hidden")
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }
                    .toggleStyle(TempraCheckboxToggleStyle())
                    .controlSize(.small)
            }
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            idleControl(
                title: "Force quit after:",
                isEnabled: quitEnabled,
                minutes: quitMinutes
            )

            if item.canControlApplication {
                idleControl(
                    title: "Hide after:",
                    isEnabled: hideEnabled,
                    minutes: hideMinutes
                )
            }
        }
    }

    private var ruleGuidanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displayedRuleGuidance) { guidance in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: guidance.symbolName)
                        .foregroundStyle(guidanceColor(guidance.severity))
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(guidance.title)
                            .font(TempraTypography.bodyEmphasized)
                        Text(guidance.message)
                            .font(TempraTypography.ruleTag)
                            .foregroundStyle(TempraPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    guidanceColor(guidance.severity).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var displayedRuleGuidance: [RuleGuidance] {
        RuleGuidanceEvaluator.evaluate(draft).filter {
            $0.kind != .administratorAccessRequired
        }
    }

    private func guidanceColor(_ severity: RuleGuidanceSeverity) -> Color {
        switch severity {
        case .information: TempraPalette.accent
        case .caution: TempraPalette.waiting
        case .critical: TempraPalette.stopped
        }
    }

    @ViewBuilder
    private var processControlNotice: some View {
        if !item.canLimitCPU {
            VStack(alignment: .leading, spacing: 7) {
                Label(
                    "WindowServer can use power-saving cores. CPU limits are unavailable because they can freeze the desktop.",
                    systemImage: "exclamationmark.shield"
                )
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.secondaryText)

                privilegedAccessNotice
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if item.requiresPrivilegedControl || draft.runOnEfficiencyCores {
            privilegedAccessNotice
        } else {
            Text("CPU limit, pause, priority, and force-quit rules work for this process. Hide requires a macOS application.")
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privilegedAccessNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                store.privilegedControlStatus.message
                    ?? "Administrator access is enabled for this process.",
                systemImage: store.privilegedControlStatus.isEnabled
                    ? "checkmark.shield"
                    : "lock.shield"
            )
            .font(TempraTypography.ruleTag)
            .foregroundStyle(TempraPalette.secondaryText)

            if let actionTitle = store.privilegedControlStatus.actionTitle {
                Button(actionTitle) {
                    Task {
                        _ = await store.requestPrivilegedControl()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var pauseToggle: some View {
        Toggle("Stop this app completely", isOn: Binding(
            get: { draft.action == .pause },
            set: { enabled in
                draft.action = enabled ? .pause : .none
                if enabled {
                    draft.runOnEfficiencyCores = false
                }
            }
        ))
        .toggleStyle(TempraCheckboxToggleStyle())
        .controlSize(.small)
    }

    private var efficiencyToggle: some View {
        Toggle(isOn: Binding(
            get: { draft.runOnEfficiencyCores },
            set: { enabled in
                draft.runOnEfficiencyCores = enabled
                if enabled, draft.action == .pause {
                    draft.action = .none
                }
                if enabled, !store.privilegedControlStatus.isEnabled {
                    Task {
                        _ = await store.requestPrivilegedControl()
                    }
                }
            }
        )) {
            Text("Run this app on the CPU’s power-saving cores")
                .font(TempraTypography.body)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .toggleStyle(TempraCheckboxToggleStyle())
        .controlSize(.small)
    }

    private var limitToggle: some View {
        Toggle("Slow down this app if it uses more than:", isOn: Binding(
            get: { draft.action == .limit },
            set: { enabled in
                draft.action = enabled ? .limit : .none
            }
        ))
        .toggleStyle(TempraCheckboxToggleStyle())
        .controlSize(.small)
    }

    private var visibleCPULimitRange: ClosedRange<Double> {
        allowsMultipleCPUCores ? CPULimitRange.allowed : CPULimitRange.singleCore
    }

    private var multipleCoreBinding: Binding<Bool> {
        Binding(
            get: { allowsMultipleCPUCores },
            set: { allowsMultipleCores in
                allowsMultipleCPUCores = allowsMultipleCores
                if !allowsMultipleCores {
                    draft.limitPercent = min(
                        draft.limitPercent,
                        CPULimitRange.oneCorePercent
                    )
                }
            }
        )
    }

    private var cpuCoreSelection: String {
        let cores = draft.limitPercent / CPULimitRange.oneCorePercent
        let coreCount = cores.formatted(
            .number.precision(.fractionLength(0...2))
        )
        let unit = cores == 1 ? "core" : "cores"
        return "\(coreCount) \(unit)"
    }

    private func idleControl(
        title: String,
        isEnabled: Binding<Bool>,
        minutes: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(title, isOn: isEnabled)
                .toggleStyle(TempraCheckboxToggleStyle())
                .controlSize(.small)

            HStack(spacing: 8) {
                TempraNumberField(
                    value: minutes,
                    range: AppRule.idleMinuteRange,
                    width: 48
                )
                .disabled(!isEnabled.wrappedValue)

                TempraTickedSlider(
                    value: minutes,
                    range: AppRule.idleMinuteRange,
                    step: 1
                )
                    .disabled(!isEnabled.wrappedValue)

                Text("Minutes")
                    .foregroundStyle(
                        isEnabled.wrappedValue
                            ? TempraPalette.primaryText
                            : TempraPalette.tertiaryText
                    )
            }
            .padding(.leading, 24)
        }
    }

    private var hideEnabled: Binding<Bool> {
        Binding(
            get: { draft.hideAfterMinutes != nil },
            set: { draft.hideAfterMinutes = $0 ? (draft.hideAfterMinutes ?? 5) : nil }
        )
    }

    private var hideMinutes: Binding<Double> {
        Binding(
            get: { draft.hideAfterMinutes ?? 5 },
            set: { draft.hideAfterMinutes = min(max(1, $0), 60) }
        )
    }

    private var quitEnabled: Binding<Bool> {
        Binding(
            get: { draft.quitAfterMinutes != nil },
            set: { draft.quitAfterMinutes = $0 ? (draft.quitAfterMinutes ?? 10) : nil }
        )
    }

    private var quitMinutes: Binding<Double> {
        Binding(
            get: { draft.quitAfterMinutes ?? 10 },
            set: { draft.quitAfterMinutes = min(max(1, $0), 60) }
        )
    }


    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TempraTypography.sectionHeading)
                .foregroundStyle(TempraPalette.secondaryText)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TempraPalette.secondaryControlFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func persistDraft() {
        guard draft != original else { return }
        guard draft.hasBehavior || store.rules[item.bundleIdentifier] != nil else { return }

        store.save(draft)
        original = store.rules[item.bundleIdentifier] ?? store.rule(for: item)
        draft = original
    }
}
