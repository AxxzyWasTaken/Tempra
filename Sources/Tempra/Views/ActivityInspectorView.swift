import SwiftUI

struct ActivityInspectorView: View {
    let item: AppDisplayItem
    @ObservedObject var store: AppStore
    let onClose: () -> Void

    @State private var historyRange: CPUHistoryRange = .hour

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            Divider()
                .overlay(TempraPalette.separator)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if let failureMessage = store.applicationActionFailureMessage(
                        for: item.bundleIdentifier
                    ) {
                        failureNotice(failureMessage)
                    }

                    usageSection

                    Divider()
                        .overlay(TempraPalette.separator)

                    historySection

                    Divider()
                        .overlay(TempraPalette.separator)

                    processSection

                    Divider()
                        .overlay(TempraPalette.separator)

                    applicationSection

                    if item.requiresPrivilegedControl {
                        privilegedControlNotice
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
        }
        .frame(
            width: TempraLayout.inspectorBodyWidth,
            height: TempraLayout.inspectorSize.height
        )
        .font(TempraTypography.body)
    }

    private var titleBar: some View {
        HStack(spacing: 9) {
            Image(nsImage: item.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 27, height: 27)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(TempraTypography.title)
                    .lineLimit(1)

                Text(item.stateText)
                    .font(TempraTypography.footer)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if item.canControlApplication || item.canQuitProcess {
                applicationActionsMenu
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(TempraPalette.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Activity Details")
            .accessibilityLabel("Close Activity Details")
        }
        .padding(.horizontal, 14)
        .frame(height: 49)
    }

    private var applicationActionsMenu: some View {
        Menu {
            if item.canControlApplication {
                Button("Bring to Front") {
                    performApplicationCommand(.bringToFront)
                }
                if !item.isHidden {
                    Button("Hide") {
                        performApplicationCommand(.hide)
                    }
                }

                Divider()
                Button("Quit") {
                    performApplicationCommand(.quitGracefully)
                }
                Button("Relaunch") {
                    performApplicationCommand(.relaunch)
                }
            }

            if item.canQuitProcess {
                Divider()
                Button(item.canControlApplication ? "Force Quit" : "Force Quit Process") {
                    performApplicationCommand(.quit)
                }
            }

            if item.rule != nil {
                Divider()
                if store.suspensionUntil(for: item.bundleIdentifier) != nil {
                    Button("End Temporary Resume") {
                        store.endSnooze(bundleIdentifier: item.bundleIdentifier)
                    }
                } else {
                    Button("Resume for 15 Minutes") {
                        store.resumeTemporarily(
                            bundleIdentifier: item.bundleIdentifier,
                            for: 15 * 60
                        )
                    }
                    Button("Resume for 1 Hour") {
                        store.resumeTemporarily(
                            bundleIdentifier: item.bundleIdentifier,
                            for: 60 * 60
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Application Actions")
        .accessibilityLabel("Application Actions")
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Live Usage")

            metricRow("Current CPU", value: item.cpuText)
            metricRow("1-minute average", value: item.averageCPUText)
            metricRow(
                "Resident memory",
                value: item.residentMemoryText,
                help: "The sum of resident memory for this app and its helper processes. Shared memory can be counted more than once."
            )
            metricRow(
                "Estimated CPU power",
                value: item.cpuPowerText,
                help: "Approximate processor power attributed by macOS. GPU and other system power are not included."
            )
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionHeading("CPU History")

                Spacer()

                Picker("History range", selection: $historyRange) {
                    ForEach(CPUHistoryRange.allCases) { range in
                        Text(range.menuTitle).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }

            AppCPUHistoryChartView(
                samples: store.appCPUHistory(for: item.bundleIdentifier),
                range: historyRange
            )

            HStack(spacing: 12) {
                chartLegend("CPU used", color: TempraPalette.performance)
                chartLegend("Est. CPU saved", color: TempraPalette.saved)
            }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Subprocesses")

            if item.processSamples.isEmpty {
                Text(item.isRunning
                     ? "Waiting for process details."
                     : "The app is not running.")
                    .foregroundStyle(TempraPalette.secondaryText)
            } else {
                ForEach(item.processSamples, id: \.identity) { sample in
                    processDetail(sample)
                }
            }
        }
    }

    private func processDetail(_ sample: ManagedProcessSample) -> some View {
        let reasons = item.protectionReasons(for: sample)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("PID \(sample.identity.pid)")
                    .font(TempraTypography.bodyEmphasized.monospacedDigit())

                Text(sample.isMainProcess ? "Main" : "Helper")
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.secondaryText)

                Spacer(minLength: 4)

                Text(String(format: "%.1f%%", sample.cpuPercent))
                    .font(TempraTypography.metricValue)
            }

            if reasons.isEmpty {
                Text("No active protection")
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.tertiaryText)
            } else {
                ForEach(reasons, id: \.self) { reason in
                    Label(reason.title, systemImage: reason.symbolName)
                        .font(TempraTypography.ruleTag)
                        .foregroundStyle(TempraPalette.secondaryText)
                }
            }

            if sample.identity.requiresPrivilegedControl {
                Label("Administrator access required", systemImage: "lock.shield")
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.secondaryText)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(
            TempraPalette.secondaryControlFill,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 13, height: 2)
            Text(title)
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.secondaryText)
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Application")

            metricRow("State", value: item.stateText)
            metricRow("Running for", value: item.runningTimeText)
            metricRow(
                "Processes",
                value: item.isRunning ? String(item.processCount) : "—"
            )
            metricRow("Visibility", value: visibilityText)
            metricRow("Audio", value: audioText)
            metricRow("Type", value: applicationTypeText)
        }
    }

    private var privilegedControlNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: store.privilegedControlStatus.isEnabled
                      ? "checkmark.shield"
                      : "lock.shield")
                    .foregroundStyle(TempraPalette.secondaryText)
                    .accessibilityHidden(true)

                Text(store.privilegedControlStatus.message
                     ?? "Administrator access is enabled for this process.")
                    .foregroundStyle(TempraPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .padding(9)
        .background(
            TempraPalette.secondaryControlFill,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func failureNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TempraPalette.stopped)
                .accessibilityHidden(true)

            Text(message)
                .foregroundStyle(TempraPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                store.dismissApplicationActionFailure()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TempraPalette.secondaryText)
            .help("Dismiss Error")
            .accessibilityLabel("Dismiss Error")
        }
        .padding(9)
        .background(
            TempraPalette.stopped.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(TempraTypography.sectionHeading)
            .foregroundStyle(TempraPalette.secondaryText)
    }

    @ViewBuilder
    private func metricRow(_ label: String, value: String, help: String? = nil) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(TempraPalette.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(value)
                .font(TempraTypography.metricValue)
                .foregroundStyle(TempraPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")

        if let help {
            row.help(help)
        } else {
            row
        }
    }

    private var visibilityText: String {
        guard item.isRunning else { return "—" }
        if item.isFrontmost { return "Frontmost" }
        if item.isHidden { return "Hidden" }
        return "Background"
    }

    private var audioText: String {
        guard item.isRunning else { return "—" }
        return item.isPlayingAudio ? "Playing audio" : "No audio"
    }

    private var applicationTypeText: String {
        if item.isSoundSourceComponent { return "SoundSource audio component" }
        if item.isSystemProcess { return "System process" }
        if item.isStandaloneProcess { return "Background process" }
        if item.isService { return "Background service" }
        return "Application"
    }

    private func performApplicationCommand(_ command: ApplicationCommand) {
        Task {
            _ = await store.performApplicationCommand(command, for: item)
        }
    }
}
