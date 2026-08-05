import SwiftUI

enum TempraSettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case control = "Control"
    case detection = "Detection"
    case stats = "Stats"
    case options = "Options"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .control: "gauge.with.dots.needle.50percent"
        case .detection: "exclamationmark.triangle"
        case .stats: "chart.bar"
        case .options: "gearshape"
        }
    }
}

struct TempraSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: MenuPanelPresentation

    @State private var profileNameDraft = ""
    @State private var showsNewProfileAlert = false
    @State private var showsRenameProfileAlert = false
    @State private var renameProfileID: UUID?
    @State private var profilePendingDeletion: ManagementProfile?

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()
                .overlay(TempraPalette.separator)

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: TempraLayout.settingsPanelSize.width,
               height: TempraLayout.settingsPanelSize.height)
        .font(.system(size: 13))
        .foregroundStyle(TempraPalette.primaryText)
        .tempraAppearance(store.preferences.appearance)
        .alert("New Profile", isPresented: $showsNewProfileAlert) {
            TextField("Profile name", text: $profileNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                store.createManagementProfile(named: profileNameDraft)
            }
            .disabled(trimmedProfileName.isEmpty)
        } message: {
            Text("Name the profile you want to create.")
        }
        .alert("Rename Profile", isPresented: $showsRenameProfileAlert) {
            TextField("Profile name", text: $profileNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameProfileID {
                    store.renameManagementProfile(id: renameProfileID, to: profileNameDraft)
                }
            }
            .disabled(trimmedProfileName.isEmpty)
        }
        .alert(
            "Delete Profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteManagementProfile(id: profile.id)
                profilePendingDeletion = nil
            }
        } message: { profile in
            Text("“\(profile.name)” will be permanently removed. Saved app rules are unchanged.")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(TempraSettingsSection.allCases) { section in
                Button {
                    presentation.settingsSection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 27, weight: .regular))
                            .frame(height: 31)

                        Text(section.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(
                        presentation.settingsSection == section
                            ? TempraPalette.accent
                            : TempraPalette.tertiaryText
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background {
                        if presentation.settingsSection == section {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(TempraPalette.secondaryControlFill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(
                    presentation.settingsSection == section ? .isSelected : []
                )
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 8)
        .frame(height: 84)
        .background(TempraPalette.subtleFill)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch presentation.settingsSection {
        case .general:
            generalSettings
        case .control:
            controlSettings
        case .detection:
            detectionSettings
        case .stats:
            statsSettings
        case .options:
            optionsSettings
        }
    }

    private var generalSettings: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 17) {
                Toggle("Automatically start Tempra at login", isOn: Binding(
                    get: { store.preferences.launchAtLogin },
                    set: { enabled in store.setLaunchAtLogin(enabled) }
                ))
                .toggleStyle(.checkbox)

                if let error = store.launchAtLoginError {
                    settingsError(error)
                }

                Divider()
                    .overlay(TempraPalette.separator)

                PrivilegedAccessControl(store: store, context: .settings)

                Divider()
                    .overlay(TempraPalette.separator)

                Toggle("Continuous Monitoring", isOn: Binding(
                    get: { store.preferences.continuousMonitoringEnabled },
                    set: { enabled in store.setContinuousMonitoringEnabled(enabled) }
                ))
                .toggleStyle(.checkbox)

                Text("Keeps CPU history and high-CPU alerts live while Tempra’s panels are closed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(TempraPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Display CPU usage next to the menu bar icon", isOn: Binding(
                    get: { store.preferences.showsCPUUsageInMenuBar },
                    set: { isVisible in store.setShowsCPUUsageInMenuBar(isVisible) }
                ))
                .toggleStyle(.checkbox)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(TempraPalette.tertiaryText)

                    Text("Tempra stays in the menu bar and does not add a permanent Dock icon.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TempraPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 21)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var controlSettings: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("Enable automatic app management", isOn: Binding(
                    get: { store.isEnabled },
                    set: { enabled in store.setEnabled(enabled) }
                ))
                .toggleStyle(.checkbox)

                Text(store.isEnabled
                     ? "Tempra is applying enabled rules to background apps."
                     : "All processes controlled by Tempra have been resumed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(store.isEnabled
                                     ? TempraPalette.secondaryText
                                     : TempraPalette.waiting)

                Divider()
                    .overlay(TempraPalette.separator)

                HStack {
                    Text("Profiles")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Button {
                        profileNameDraft = ""
                        showsNewProfileAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Create Profile")

                    Button {
                        guard let profile = store.preferences.activeProfile else { return }
                        profileNameDraft = profile.name
                        renameProfileID = profile.id
                        showsRenameProfileAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .disabled(store.preferences.activeProfile == nil)
                    .help("Rename Active Profile")

                    Button {
                        profilePendingDeletion = store.preferences.activeProfile
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.preferences.activeProfile == nil)
                    .help("Delete Active Profile")
                }
                .buttonStyle(.borderless)

                settingsPickerRow("Active profile") {
                    Picker("", selection: Binding(
                        get: { store.preferences.activeProfileID },
                        set: { id in store.setActiveManagementProfile(id) }
                    )) {
                        Text("No Active Profile").tag(nil as UUID?)
                        ForEach(store.preferences.profiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                if let automaticProfileID = store.automaticProfileID,
                   let automaticProfile = store.preferences.profiles.first(
                    where: { $0.id == automaticProfileID }
                   ) {
                    Label(
                        "Automatic conditions selected \(automaticProfile.name).",
                        systemImage: "bolt.fill"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(TempraPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let profile = store.preferences.activeProfile {
                    profileEditor(profile)
                } else {
                    Text(store.preferences.profiles.isEmpty
                         ? "Create a profile to adjust saved app rules for a particular workflow."
                         : "Choose a profile to edit and apply it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TempraPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 21)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func profileEditor(_ profile: ManagementProfile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            settingsPickerRow("CPU limits") {
                HStack(spacing: 7) {
                    Picker("", selection: profileBinding(
                        profile,
                        keyPath: \.limitPolicy
                    )) {
                        ForEach(ProfileLimitPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)

                    if profile.limitPolicy != .inherit {
                        TempraNumberField(
                            value: profileBinding(profile, keyPath: \.limitPercent),
                            range: CPULimitRange.allowed,
                            width: 58,
                            suffix: "%"
                        )
                    }
                }
            }

            settingsPickerRow("Start delays") {
                HStack(spacing: 7) {
                    Picker("", selection: profileBinding(
                        profile,
                        keyPath: \.delayPolicy
                    )) {
                        ForEach(ProfileDelayPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)

                    if profile.delayPolicy != .inherit {
                        Picker("", selection: profileBinding(
                            profile,
                            keyPath: \.delaySeconds
                        )) {
                            ForEach(AppRule.delayOptions, id: \.self) { delay in
                                Text(AppRule.delayTitle(delay)).tag(delay)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 92)
                    }
                }
            }

            Divider()
                .overlay(TempraPalette.separator)

            Text("Automatic Activation")
                .font(.system(size: 12, weight: .semibold))

            settingsPickerRow("Power source") {
                Picker("", selection: profileBinding(
                    profile,
                    keyPath: \.activation.powerCondition
                )) {
                    ForEach(ProfilePowerCondition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            Toggle(
                "Activate after user inactivity",
                isOn: profileIdleActivationBinding(profile)
            )
            .toggleStyle(.checkbox)

            if profile.activation.idleAfterMinutes != nil {
                HStack {
                    Spacer()
                    Stepper(
                        value: profileIdleMinutesBinding(profile),
                        in: 1...120,
                        step: 1
                    ) {
                        Text("\(Int(profile.activation.idleAfterMinutes ?? 15)) minutes")
                            .monospacedDigit()
                            .frame(width: 86, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }

            Text(profileDescription(profile))
                .font(.system(size: 11.5))
                .foregroundStyle(TempraPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detectionSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            if !store.preferences.continuousMonitoringEnabled {
                Text("Enable Continuous Monitoring in General to use background CPU alerts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(TempraPalette.waiting)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show Tempra alerts for sustained high CPU", isOn: Binding(
                get: { store.preferences.highCPUAlertsEnabled },
                set: { enabled in store.setHighCPUAlertsEnabled(enabled) }
            ))
            .toggleStyle(.checkbox)

            Text("Alerts appear below Tempra’s menu bar icon and require no notification permission.")
                .font(.system(size: 11.5))
                .foregroundStyle(TempraPalette.secondaryText)

            Divider()
                .overlay(TempraPalette.separator)

            HStack {
                Text("Notify when an app exceeds")
                Spacer()
                Stepper(
                    value: Binding(
                        get: { store.preferences.highCPUThreshold },
                        set: { threshold in store.setHighCPUThreshold(threshold) }
                    ),
                    in: 25...CPULimitRange.maximumPercent,
                    step: 25
                ) {
                    Text("\(Int(store.preferences.highCPUThreshold))% CPU")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                .fixedSize()
            }

            settingsPickerRow("For longer than") {
                Picker("", selection: Binding(
                    get: { store.preferences.highCPUDuration },
                    set: { duration in store.setHighCPUDuration(duration) }
                )) {
                    ForEach(AppPreferences.durationOptions, id: \.self) { duration in
                        Text(AppPreferences.durationTitle(duration)).tag(duration)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }

            settingsPickerRow("Alert cooldown") {
                Picker("", selection: Binding(
                    get: { store.preferences.notificationCooldown },
                    set: { duration in store.setNotificationCooldown(duration) }
                )) {
                    ForEach(AppPreferences.cooldownOptions, id: \.self) { duration in
                        Text(AppPreferences.cooldownTitle(duration)).tag(duration)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }

            Text("Alerts clear after the app remains below 70% CPU for 10 seconds.")
                .font(.system(size: 11.5))
                .foregroundStyle(TempraPalette.secondaryText)

            if !store.preferences.ignoredHighCPUAlertBundleIdentifiers.isEmpty {
                HStack {
                    Text(
                        "\(store.preferences.ignoredHighCPUAlertBundleIdentifiers.count) ignored "
                            + "application"
                            + (store.preferences.ignoredHighCPUAlertBundleIdentifiers.count == 1
                               ? ""
                               : "s")
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(TempraPalette.secondaryText)

                    Spacer()

                    Button("Clear Ignored") {
                        store.clearIgnoredHighCPUAlerts()
                    }
                    .controlSize(.small)
                }
            }
        }
        .settingsPane()
        .disabled(!store.preferences.continuousMonitoringEnabled)
    }

    private var statsSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Current")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Last 7 days")
                    .font(.system(size: 11.5))
                    .foregroundStyle(TempraPalette.tertiaryText)
            }

            Divider()
                .overlay(TempraPalette.separator)

            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 11) {
                statsRow(
                    "Total CPU usage:",
                    value: String(format: "%.1f%%", store.systemCPU.totalPercent)
                )
                statsRow(
                    "CPU usage saved:",
                    value: String(format: "%.1f%%", store.estimatedSavedSystemPercent)
                )
                statsRow(
                    "CPU temperature:",
                    value: store.systemCPU.cpuTemperatureCelsius.map {
                        String(format: "%.1f°", $0)
                    } ?? "—"
                )
                statsRow("Time limited:", value: durationText(limitedDuration))
                statsRow("Time paused:", value: durationText(pausedDuration))
                statsRow("Interventions:", value: "\(interventionCount)")
            }
            .frame(maxWidth: .infinity)
        }
        .settingsPane()
    }

    private var optionsSettings: some View {
        VStack(alignment: .leading, spacing: 17) {
            settingsPickerRow("Appearance") {
                Picker("", selection: Binding(
                    get: { store.preferences.appearance },
                    set: { appearance in store.setAppearance(appearance) }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }

            Divider()
                .overlay(TempraPalette.separator)

            Toggle("Show graph of CPU usage", isOn: Binding(
                get: { store.preferences.showsCPUHistoryGraph },
                set: { isVisible in store.setShowsCPUHistoryGraph(isVisible) }
            ))
            .toggleStyle(.checkbox)

            settingsPickerRow("Default graph range") {
                Picker("", selection: Binding(
                    get: { store.preferences.historyRange },
                    set: { range in store.setHistoryRange(range) }
                )) {
                    ForEach(CPUHistoryRange.allCases) { range in
                        Text(range.menuTitle).tag(range)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }
            .disabled(!store.preferences.showsCPUHistoryGraph)

            Divider()
                .overlay(TempraPalette.separator)

            Text("Tempra keeps up to 24 hours of graph history and seven days of intervention activity.")
                .font(.system(size: 11.5))
                .foregroundStyle(TempraPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("System appearance follows macOS automatically as it changes.")
                .font(.system(size: 11.5))
                .foregroundStyle(TempraPalette.secondaryText)
        }
        .settingsPane()
    }

    private func settingsPickerRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            content()
        }
    }

    private func settingsError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(TempraPalette.waiting)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statsRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(TempraPalette.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(TempraPalette.primaryText)
        }
    }

    private func profileDescription(_ profile: ManagementProfile) -> String {
        let limitText = switch profile.limitPolicy {
        case .inherit:
            "saved CPU limits"
        case .maximum:
            "CPU limits capped at \(Int(profile.limitPercent))%"
        case .minimum:
            "CPU limits of at least \(Int(profile.limitPercent))%"
        }
        let delayText = switch profile.delayPolicy {
        case .inherit:
            "saved start delays"
        case .maximum:
            "start delays no longer than \(AppRule.delayTitle(profile.delaySeconds).lowercased())"
        case .minimum:
            "start delays of at least \(AppRule.delayTitle(profile.delaySeconds).lowercased())"
        }
        let activationText: String
        switch (
            profile.activation.powerCondition,
            profile.activation.idleAfterMinutes
        ) {
        case (.any, nil):
            activationText = "Select this profile manually"
        case let (.any, idleMinutes?):
            activationText = "Activates after \(Int(idleMinutes)) minutes of inactivity"
        case let (powerCondition, nil):
            activationText = "Activates \(powerCondition.title.lowercased())"
        case let (powerCondition, idleMinutes?):
            activationText = "Activates \(powerCondition.title.lowercased()) after "
                + "\(Int(idleMinutes)) minutes of inactivity"
        }
        return "Uses \(limitText) and \(delayText). \(activationText)."
    }

    private func profileIdleActivationBinding(
        _ profile: ManagementProfile
    ) -> Binding<Bool> {
        Binding(
            get: {
                store.preferences.profiles.first { $0.id == profile.id }?
                    .activation.idleAfterMinutes != nil
            },
            set: { isEnabled in
                store.updateManagementProfile(id: profile.id) {
                    $0.activation.idleAfterMinutes = isEnabled
                        ? ($0.activation.idleAfterMinutes ?? 15)
                        : nil
                }
            }
        )
    }

    private func profileIdleMinutesBinding(
        _ profile: ManagementProfile
    ) -> Binding<Double> {
        Binding(
            get: {
                store.preferences.profiles.first { $0.id == profile.id }?
                    .activation.idleAfterMinutes ?? 15
            },
            set: { minutes in
                store.updateManagementProfile(id: profile.id) {
                    $0.activation.idleAfterMinutes = minutes
                }
            }
        )
    }

    private func profileBinding<Value>(
        _ profile: ManagementProfile,
        keyPath: WritableKeyPath<ManagementProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                store.preferences.profiles.first { $0.id == profile.id }?[keyPath: keyPath]
                    ?? profile[keyPath: keyPath]
            },
            set: { value in
                store.updateManagementProfile(id: profile.id) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private var trimmedProfileName: String {
        profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentDurations: [ManagementDurationSummary] {
        store.managementDurations(
            since: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        )
    }

    private var limitedDuration: TimeInterval {
        recentDurations.reduce(0) { $0 + $1.limitedDuration }
    }

    private var pausedDuration: TimeInterval {
        recentDurations.reduce(0) { $0 + $1.pausedDuration }
    }

    private var interventionCount: Int {
        store.managementInterventionCount(
            since: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        if totalMinutes > 0 {
            return "\(totalMinutes)m"
        }
        return "\(Int(duration))s"
    }

}

private extension View {
    func settingsPane() -> some View {
        self
            .padding(.horizontal, 24)
            .padding(.vertical, 21)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
