import SwiftUI

struct PrivilegedAccessControl: View {
    enum Context: Equatable {
        case onboarding
        case settings
    }

    @ObservedObject var store: AppStore
    let context: Context
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                if store.privilegedControlStatus.isEnabled {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TempraPalette.saved)
                }
            }

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)

            if actionTitle != nil || context == .onboarding {
                HStack(spacing: 8) {
                    if let actionTitle {
                        Button {
                            Task {
                                _ = await store.requestPrivilegedControl()
                            }
                        } label: {
                            if store.isRequestingPrivilegedControl {
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Requesting…")
                                }
                            } else {
                                Text(actionTitle)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.isRequestingPrivilegedControl)
                    }

                    if context == .onboarding {
                        Button("Not Now") {
                            onDismiss?()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.isRequestingPrivilegedControl)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        context == .onboarding ? "Finish Tempra Setup" : "Administrator Access"
    }

    private var actionTitle: String? {
        store.privilegedControlStatus.actionTitle
    }

    private var detail: String {
        switch store.privilegedControlStatus {
        case .notRegistered:
            "Install Tempra’s helper to use power-saving scheduling and manage supported apps "
                + "that require administrator access."
        case .requiresApproval, .helperUnavailable, .unavailable:
            store.privilegedControlStatus.message
                ?? "Administrator access is not available."
        case .enabled:
            "Tempra can use power-saving scheduling and manage supported apps that require "
                + "administrator access."
        }
    }

    private var statusSymbolName: String {
        switch store.privilegedControlStatus {
        case .enabled:
            "checkmark.shield.fill"
        case .helperUnavailable, .unavailable:
            "exclamationmark.shield.fill"
        case .notRegistered, .requiresApproval:
            "lock.shield"
        }
    }

    private var statusColor: Color {
        switch store.privilegedControlStatus {
        case .enabled:
            TempraPalette.saved
        case .requiresApproval:
            TempraPalette.waiting
        case .helperUnavailable, .unavailable:
            TempraPalette.stopped
        case .notRegistered:
            TempraPalette.accent
        }
    }

    private var detailColor: Color {
        switch store.privilegedControlStatus {
        case .helperUnavailable, .unavailable:
            TempraPalette.stopped
        case .notRegistered, .requiresApproval, .enabled:
            TempraPalette.secondaryText
        }
    }
}
