import AppKit
import SwiftUI

struct HighCPUAlertView: View {
    let alert: HighCPUAlert
    let onContinue: () -> Void
    let onLimit: () -> Void
    let onIgnore: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TempraLayout.mainNotchHeight)

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)

                    Text(
                        "\(alert.displayName) has been using more than "
                            + "\(Int(alert.threshold))% CPU for over "
                            + AppPreferences.durationTitle(alert.duration)
                            + "."
                    )
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(TempraPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text("What would you like to do about it?")
                    .font(.system(size: 13.5))
                    .foregroundStyle(TempraPalette.primaryText)

                VStack(spacing: 7) {
                    alertButton("Let it continue", action: onContinue)
                    alertButton("Limit its CPU usage", action: onLimit)
                    alertButton("Don’t warn about \(alert.displayName)", action: onIgnore)
                }

                Divider()
                    .overlay(TempraPalette.separator)

                alertButton("Change alert settings", action: onShowSettings)
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 18)
        }
        .frame(
            width: TempraLayout.highCPUAlertPanelSize.width,
            height: TempraLayout.highCPUAlertPanelSize.height
        )
        .tempraPanelSurface(MainPanelShape())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("High CPU alert for \(alert.displayName)")
    }

    private func alertButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .foregroundStyle(TempraPalette.prominentButtonText)
                .background(
                    TempraPalette.prominentButtonFill,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TempraPalette.border, lineWidth: 0.5)
                }
        }
        .buttonStyle(HighCPUAlertButtonStyle())
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

private struct HighCPUAlertButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
    }
}
