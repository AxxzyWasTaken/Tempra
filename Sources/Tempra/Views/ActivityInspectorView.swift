import SwiftUI

struct ActivityInspectorView: View {
    let item: AppDisplayItem
    @ObservedObject var store: AppStore
    let onClose: () -> Void

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
        if item.isSystemProcess { return "System process" }
        if item.isStandaloneProcess { return "Background process" }
        if item.isService { return "Background service" }
        return "Application"
    }
}
