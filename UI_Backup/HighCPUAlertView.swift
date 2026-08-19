import AppKit
import SwiftUI

struct HighCPUAlertView: View {
    let alert: HighCPUAlert
    let arrowX: CGFloat
    let onContinue: () -> Void
    let onLimit: () -> Void
    let onIgnore: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TempraLayout.mainNotchHeight)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sustained high CPU usage")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TempraPalette.primaryText)
                            .accessibilityAddTraits(.isHeader)

                        Text(alertMessage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(TempraPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("What would you like to do about it?")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TempraPalette.primaryText)

                HStack(spacing: 8) {
                    Button("Let it continue", action: onContinue)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Mutes this alert for the selected reminder interval.")

                    Button("Limit its CPU usage", action: onLimit)
                        .buttonStyle(.borderedProminent)
                        .tint(TempraPalette.accent)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Creates a 50 percent CPU limit for this app.")
                }
                .controlSize(.regular)

                Divider()
                    .overlay(TempraPalette.separator)

                HStack(spacing: 10) {
                    quietButton(
                        "Don’t warn about \(alert.displayName)",
                        help: "Permanently ignore high CPU alerts for \(alert.displayName).",
                        action: onIgnore
                    )

                    Spacer(minLength: 8)

                    quietButton(
                        "Notification settings",
                        help: "Open Tempra’s Detection settings.",
                        action: onShowSettings
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .frame(
            width: TempraLayout.highCPUAlertPanelSize.width,
            height: TempraLayout.highCPUAlertPanelSize.height
        )
        .tempraPanelSurface(MainPanelShape(arrowX: arrowX))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("High CPU alert for \(alert.displayName)")
    }

    private var alertMessage: String {
        "\(alert.displayName) has used at least \(Int(alert.threshold))% of one CPU core "
            + "for more than \(AppPreferences.durationTitle(alert.duration))."
    }

    private func quietButton(
        _ title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(TempraPalette.accent)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var appIcon: NSImage {
        guard let applicationURL = alert.applicationURL else {
            return NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: alert.displayName
            ) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}
