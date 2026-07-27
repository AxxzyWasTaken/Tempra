import SwiftUI

struct RuleEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: AppDisplayItem
    @ObservedObject var store: AppStore
    let onClose: () -> Void

    @State private var original: AppRule
    @State private var draft: AppRule
    @State private var isTitleHovered = false
    @State private var isBackgroundHeaderHovered = false
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
        let initial = initialRule ?? store.rule(for: item)
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
                VStack(alignment: .leading, spacing: 11) {
                    backgroundControls

                    Divider()
                        .overlay(TempraPalette.separator)

                    conditionControls

                    Divider()
                        .overlay(TempraPalette.separator)

                    idleControls
                }
                .padding(.leading, 17)
                .padding(.trailing, 13)
                .padding(.vertical, 10)
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
        HStack(spacing: 8) {
            Text(item.name)
                .font(TempraTypography.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Menu {
                    Toggle("Rule Enabled", isOn: $draft.isEnabled)

                    Divider()
                    Button("Gentle · 50%") {
                        draft.action = .limit
                        draft.limitPercent = 50
                    }
                    Button("Strict · 20%") {
                        draft.action = .limit
                        draft.limitPercent = 20
                    }
                    Button("Pause") {
                        draft.action = .pause
                        draft.runOnEfficiencyCores = false
                    }

                    if store.suspensionUntil(for: item.bundleIdentifier) != nil {
                        Button("End Snooze") {
                            store.endSnooze(bundleIdentifier: item.bundleIdentifier)
                        }
                    } else if store.rules[item.bundleIdentifier] != nil {
                        Button("Snooze for 1 Hour") {
                            store.snooze(bundleIdentifier: item.bundleIdentifier, for: 60 * 60)
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
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Rule Options")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(TempraPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .opacity(isTitleHovered ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTitleHovered)
        }
        .padding(.leading, 18)
        .padding(.trailing, 13)
        .frame(height: 49)
        .onHover { isTitleHovered = $0 }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("When not in front…")
                    .font(TempraTypography.bodyEmphasized)

                Spacer()

                Menu {
                    Picker("Start after", selection: $draft.delaySeconds) {
                        ForEach(AppRule.delayOptions, id: \.self) { delay in
                            Text(AppRule.delayTitle(delay)).tag(delay)
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                        .foregroundStyle(TempraPalette.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Start after \(AppRule.delayTitle(draft.delaySeconds).lowercased())")
                .opacity(isBackgroundHeaderHovered ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isBackgroundHeaderHovered
                )
            }
            .onHover { isBackgroundHeaderHovered = $0 }

            pauseToggle
            efficiencyToggle
            limitToggle

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
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $draft.protectAudio) {
                Text("Don't stop or slow when sound is playing")
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
                .toggleStyle(TempraCheckboxToggleStyle())
                .controlSize(.small)

            Toggle(isOn: $draft.onlyWhenHidden) {
                Text("Only stop or slow when app is hidden")
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
                .toggleStyle(TempraCheckboxToggleStyle())
                .controlSize(.small)
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When idle…")
                .font(TempraTypography.bodyEmphasized)

            idleControl(
                title: "Quit after:",
                isEnabled: quitEnabled,
                minutes: quitMinutes
            )

            idleControl(
                title: "Hide after:",
                isEnabled: hideEnabled,
                minutes: hideMinutes
            )
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
            }
        )) {
            Text("Run this app on the CPU’s power-saving cores")
                .lineLimit(1)
                .minimumScaleFactor(0.78)
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

    private func persistDraft() {
        guard draft != original else { return }
        guard draft.hasBehavior || store.rules[item.bundleIdentifier] != nil else { return }

        store.save(draft)
        original = store.rules[item.bundleIdentifier] ?? store.rule(for: item)
        draft = original
    }
}
