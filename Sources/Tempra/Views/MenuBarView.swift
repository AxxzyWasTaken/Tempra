import AppKit
import SwiftUI

private enum MenuScope: String, CaseIterable, Hashable, Identifiable {
    case running = "Running"
    case rules = "Rules"
    case alerts = "Alerts"

    var id: String { rawValue }
}

private enum ProcessSort: String, CaseIterable, Hashable, Identifiable {
    case averageDescending = "Highest 1m Average"
    case averageAscending = "Lowest 1m Average"
    case currentDescending = "Highest Current CPU"
    case currentAscending = "Lowest Current CPU"
    case powerDescending = "Highest Est. Power"
    case powerAscending = "Lowest Est. Power"
    case name = "Name"

    var id: String { rawValue }
}

private struct HeaderActionsMenu: View, Equatable {
    let scope: MenuScope
    let scopeBadges: [MenuScope: String]
    let historyRange: CPUHistoryRange
    let appearance: AppAppearance
    let onScopeChange: (MenuScope) -> Void
    let onHistoryRangeChange: (CPUHistoryRange) -> Void
    let onAppearanceChange: (AppAppearance) -> Void
    let onShowSettings: () -> Void
    let onQuit: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope
            && lhs.scopeBadges == rhs.scopeBadges
            && lhs.historyRange == rhs.historyRange
            && lhs.appearance == rhs.appearance
    }

    var body: some View {
        Menu {
            Picker(
                "Show",
                selection: Binding(
                    get: { scope },
                    set: { newScope in onScopeChange(newScope) }
                )
            ) {
                ForEach(MenuScope.allCases) { scope in
                    Text(scope.rawValue + (scopeBadges[scope] ?? "")).tag(scope)
                }
            }

            Picker(
                "Graph Range",
                selection: Binding(
                    get: { historyRange },
                    set: { newRange in onHistoryRangeChange(newRange) }
                )
            ) {
                ForEach(CPUHistoryRange.allCases) { range in
                    Text(range.menuTitle).tag(range)
                }
            }

            Picker(
                "Appearance",
                selection: Binding(
                    get: { appearance },
                    set: { newAppearance in onAppearanceChange(newAppearance) }
                )
            ) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }

            Divider()

            Button("Settings…", action: onShowSettings)
            Button("Quit Tempra", action: onQuit)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "ellipsis.circle")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .frame(minWidth: 32, minHeight: 26)
            .contentShape(Rectangle())
            .foregroundStyle(.primary.opacity(0.88))
        }
        .menuStyle(.borderlessButton)
        .tint(TempraPalette.primaryText)
        .fixedSize()
        .help("More")
    }
}

private struct ProcessRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct MenuBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: MenuPanelPresentation

    @State private var scope: MenuScope = .running
    @State private var processSort: ProcessSort = .averageDescending
    @State private var searchText = ""
    @State private var showsAllRules = false
    @State private var rowFrames: [String: CGRect] = [:]

    private let collapsedRuleCount = 5
    private let coordinateSpaceName = "tempra.main.panel"

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TempraLayout.mainNotchHeight)

            monitorPanel
        }
        .frame(
            width: TempraLayout.mainPanelSize.width,
            height: TempraLayout.mainPanelSize.height
        )
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(ProcessRowFramesKey.self, perform: updateRowFrames)
        .tempraPanelSurface(MainPanelShape())
        .tempraAppearance(store.preferences.appearance)
    }

    private var monitorPanel: some View {
        VStack(spacing: 0) {
            header

            summaryMetrics

            if store.preferences.showsCPUHistoryGraph {
                CPUHistoryChartView(
                    samples: displayedHistory,
                    range: historyRangeBinding,
                    performanceCoreCount: displayedCPU.performanceCoreCount,
                    efficiencyCoreCount: displayedCPU.efficiencyCoreCount
                )
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
            }

            Divider()
                .overlay(TempraPalette.separator)

            VStack(spacing: 0) {
                processSection
                    .frame(height: scope == .running ? processSectionHeight : nil)

                if scope == .running {
                    Divider()
                        .overlay(TempraPalette.separator)
                        .padding(.vertical, 7)
                    managedSection
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 11)
            .frame(maxHeight: .infinity)
            .background(TempraPalette.subtleFill)

            Divider()
                .overlay(TempraPalette.separator)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Toggle("Management", isOn: Binding(
                get: { displayedManagementEnabled },
                set: { enabled in
                    store.setEnabled(enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(TempraSwitchToggleStyle())
            .help(displayedManagementEnabled ? "Management is on" : "Management is off; all apps are resumed")
            .accessibilityLabel("Management")

            searchField

            HeaderActionsMenu(
                scope: scope,
                scopeBadges: Dictionary(
                    uniqueKeysWithValues: MenuScope.allCases.map { ($0, badge(for: $0)) }
                ),
                historyRange: store.preferences.historyRange,
                appearance: store.preferences.appearance,
                onScopeChange: { scope = $0 },
                onHistoryRangeChange: store.setHistoryRange,
                onAppearanceChange: store.setAppearance,
                onShowSettings: {
                    presentation.showSettings()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .equatable()
        }
        .padding(.horizontal, 11)
        .frame(height: 39)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TempraPalette.secondaryText)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(TempraPalette.secondaryText)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(TempraPalette.searchFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(TempraPalette.border.opacity(0.72), lineWidth: 1)
        }
    }

    private var summaryMetrics: some View {
        VStack(spacing: 2) {
            metricLine(
                "TOTAL CPU USAGE",
                value: cpuText(displayedCPU.totalPercent),
                color: TempraPalette.primaryText,
                isHeading: true
            )
            if displayedCPU.efficiencyCoreCount > 0 {
                metricLine(
                    "PERFORMANCE CORE USAGE",
                    value: cpuText(displayedCPU.performancePercent),
                    color: TempraPalette.performance
                )
                metricLine(
                    "EFFICIENCY CORE USAGE",
                    value: cpuText(displayedCPU.efficiencyPercent),
                    color: TempraPalette.efficiency
                )
            } else {
                metricLine(
                    "PERFORMANCE CORE USAGE",
                    value: cpuText(displayedCPU.performancePercent),
                    color: TempraPalette.performance
                )
            }
            metricLine(
                "CPU USAGE SAVED",
                value: cpuText(displayedSavedCPU),
                color: TempraPalette.saved
            )
            metricLine(
                "EST. APP POWER",
                value: PowerMetricFormatter.text(watts: store.trackedAppCPUPowerWatts),
                color: TempraPalette.primaryText
            )
            .help(
                "Approximate app power based on processor energy attributed by macOS, "
                    + "averaged over three seconds. Actual total power may be higher because "
                    + "GPU, networking, storage, display, and shared system power cannot be "
                    + "fully attributed to an app."
            )
            metricLine(
                "EST. POWER SAVED",
                value: PowerMetricFormatter.text(watts: store.estimatedSavedCPUPowerWatts),
                color: TempraPalette.saved
            )
            .help(
                "Approximate reduction calculated from Tempra’s prevented CPU estimate and "
                    + "the app’s measured energy per CPU time. GPU and other power that macOS "
                    + "cannot attribute to the app are not included."
            )
            metricLine(
                "CPU TEMPERATURE",
                value: temperatureText(displayedCPU.cpuTemperatureCelsius),
                color: TempraPalette.thermal
            )
        }
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 7)
    }

    private func metricLine(
        _ title: String,
        value: String,
        color: Color,
        isHeading: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(isHeading ? TempraTypography.sectionHeading : TempraTypography.metric)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(value)
                .font(TempraTypography.metricValue)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var processSection: some View {
        VStack(spacing: 0) {
            processHeader
                .padding(.top, 4)
                .padding(.bottom, 1)

            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredItems) { item in
                            processRow(item)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }

            if scope == .running {
                backgroundProcessControl
            }
        }
    }

    private var backgroundProcessControl: some View {
        let isIncluded = store.preferences.includesEssentialSystemProcesses

        return Button {
            store.setIncludesEssentialSystemProcesses(
                !isIncluded
            )
        } label: {
            Text("Include essential system processes")
                .font(TempraTypography.footer)
                .foregroundStyle(isIncluded ? TempraPalette.primaryText : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 21)
                .background(
                    isIncluded ? TempraPalette.secondaryControlFill : TempraPalette.accent,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.top, 3)
        .animation(.easeInOut(duration: 0.15), value: isIncluded)
        .help(isIncluded
              ? "Hide macOS daemons and background services"
              : "Show every process macOS exposes, including daemons and background services")
        .accessibilityValue(isIncluded ? "On" : "Off")
    }

    private func processRow(_ item: AppDisplayItem) -> some View {
        let anchorKey = "process:\(item.bundleIdentifier)"
        return ProcessRowView(
            item: item,
            isSystemProcess: item.isSystemProcess,
            isSelected: activeSelection?.anchorKey == anchorKey
        ) {
            guard !item.isSystemProcess else { return }
            select(item: item, anchorKey: anchorKey)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ProcessRowFramesKey.self,
                    value: [anchorKey: geometry.frame(in: .named(coordinateSpaceName))]
                )
            }
        }
        .contextMenu {
            if !item.isSystemProcess {
                contextMenu(for: item)
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: TempraLayout.processColumnSpacing) {
            Menu {
                Picker("Sort", selection: $processSort) {
                    ForEach(ProcessSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
            } label: {
                Text(processHeading.uppercased())
                    .font(TempraTypography.sectionHeading)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(TempraPalette.secondaryText)
            .help("Sort processes")

            Spacer(minLength: 4)

            sortColumn(
                "CPU %",
                width: TempraLayout.currentCPUColumnWidth,
                isSelected: isCurrentSort
            ) {
                processSort = processSort == .currentDescending
                    ? .currentAscending
                    : .currentDescending
            }

            sortColumn(
                "AVG %",
                width: TempraLayout.averageCPUColumnWidth,
                isSelected: isAverageSort
            ) {
                processSort = processSort == .averageDescending
                    ? .averageAscending
                    : .averageDescending
            }

            sortColumn(
                "EST. W",
                width: TempraLayout.powerColumnWidth,
                isSelected: isPowerSort
            ) {
                processSort = processSort == .powerDescending
                    ? .powerAscending
                    : .powerDescending
            }
        }
        .padding(.horizontal, TempraLayout.processRowHorizontalInset)
        .foregroundStyle(TempraPalette.secondaryText)
        .frame(height: 20)
    }

    private func sortColumn(
        _ title: String,
        width: CGFloat,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(TempraTypography.tableHeader)
                .underline(isSelected)
                .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    private var managedSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: TempraLayout.processColumnSpacing) {
                Text(displayedManagementEnabled ? "TAMED PROCESSES" : "MANAGEMENT OFF")
                    .font(TempraTypography.sectionHeading)
                Spacer(minLength: 4)
                Text("CPU")
                    .font(TempraTypography.tableHeader)
                    .frame(width: TempraLayout.averageCPUColumnWidth, alignment: .trailing)
                Text("EST. W")
                    .font(TempraTypography.tableHeader)
                    .frame(width: TempraLayout.powerColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .foregroundStyle(TempraPalette.secondaryText)
            .frame(height: 20)

            if managedItems.isEmpty {
                Text("Select a process to add a background rule.")
                    .font(.system(size: 10))
                    .foregroundStyle(TempraPalette.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleManagedItems) { item in
                            managedRow(item)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(
                    height: CGFloat(min(visibleManagedItems.count, collapsedRuleCount))
                        * TempraLayout.processRowHeight + 12
                )
            }

            if managedItems.count > collapsedRuleCount {
                showMoreButton(
                    title: showsAllRules
                        ? "Show fewer…"
                        : "Show all tamed processes…"
                ) {
                    showsAllRules.toggle()
                }
            }
        }
    }

    private func managedRow(_ item: AppDisplayItem) -> some View {
        let anchorKey = "managed:\(item.bundleIdentifier)"
        return ManagedProcessRowView(
            item: item,
            isSelected: activeSelection?.anchorKey == anchorKey
        ) {
            select(item: item, anchorKey: anchorKey)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ProcessRowFramesKey.self,
                    value: [anchorKey: geometry.frame(in: .named(coordinateSpaceName))]
                )
            }
        }
        .contextMenu {
            contextMenu(for: item)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: emptySymbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.system(size: 12, weight: .medium))
            Text(emptyDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
    }

    private func showMoreButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TempraTypography.footer)
                .frame(maxWidth: .infinity)
                .frame(height: 21)
                .background(TempraPalette.secondaryControlFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.top, 3)
    }

    @ViewBuilder
    private func contextMenu(for item: AppDisplayItem) -> some View {
        Button("Limit to 50%") {
            store.applyQuickRule(
                bundleIdentifier: item.bundleIdentifier,
                displayName: item.name,
                applicationURL: item.applicationURL,
                action: .limit,
                limitPercent: 50,
                delaySeconds: 0
            )
        }

        Button(item.rule?.runOnEfficiencyCores == true
               ? "Stop Using Power-Saving Cores"
               : "Run on Power-Saving Cores") {
            store.setEfficiencyCoreScheduling(
                bundleIdentifier: item.bundleIdentifier,
                displayName: item.name,
                applicationURL: item.applicationURL,
                enabled: item.rule?.runOnEfficiencyCores != true,
                delaySeconds: 0
            )
        }

        Button("Pause after 30 seconds") {
            store.applyQuickRule(
                bundleIdentifier: item.bundleIdentifier,
                displayName: item.name,
                applicationURL: item.applicationURL,
                action: .pause,
                delaySeconds: 30
            )
        }

        if let rule = item.rule {
            Divider()

            Button(rule.isEnabled ? "Disable Rule" : "Enable Rule") {
                store.setRuleEnabled(
                    bundleIdentifier: item.bundleIdentifier,
                    enabled: !rule.isEnabled
                )
            }

            if store.suspensionUntil(for: item.bundleIdentifier) != nil {
                Button("End Snooze") {
                    store.endSnooze(bundleIdentifier: item.bundleIdentifier)
                }
            } else {
                Button("Snooze for 15 Minutes") {
                    store.snooze(bundleIdentifier: item.bundleIdentifier, for: 15 * 60)
                }
                Button("Snooze for 1 Hour") {
                    store.snooze(bundleIdentifier: item.bundleIdentifier, for: 60 * 60)
                }
            }

            Divider()
            Button("Remove Rule", role: .destructive) {
                store.removeRule(bundleIdentifier: item.bundleIdentifier)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                legendItem("Running", color: TempraPalette.running)
                HStack(spacing: 3) {
                    HStack(spacing: 2) {
                        TempraStatusDot(color: TempraPalette.slowed, fill: .full, size: 7)
                        TempraStatusDot(color: TempraPalette.waiting, fill: .full, size: 7)
                    }
                    Text("Slowed")
                        .foregroundStyle(TempraPalette.secondaryText)
                }
                legendItem("Stopped", color: TempraPalette.stopped)
            }

            HStack(spacing: 4) {
                Text("Profile:")
                    .foregroundStyle(TempraPalette.secondaryText)

                Menu {
                    if store.preferences.profiles.isEmpty {
                        Text("No custom profiles")
                        Divider()
                        Button("Create Profile…") {
                            presentation.showSettings(section: .control)
                        }
                    } else {
                        ForEach(store.preferences.profiles) { profile in
                            Button {
                                store.setActiveManagementProfile(profile.id)
                            } label: {
                                if store.preferences.activeProfileID == profile.id {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                        }
                        Divider()
                        Button("Manage Profiles…") {
                            presentation.showSettings(section: .control)
                        }
                    }
                } label: {
                    Text(store.preferences.activeProfile?.name ?? "No Active Profile")
                        .foregroundStyle(TempraPalette.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .tint(TempraPalette.primaryText)
                .fixedSize()
            }
        }
        .font(TempraTypography.footer)
        .frame(height: 48)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            TempraStatusDot(color: color, fill: .full, size: 7)
            Text(title)
                .foregroundStyle(TempraPalette.secondaryText)
        }
    }

    private func select(item: AppDisplayItem, anchorKey: String) {
        presentation.select(
            bundleIdentifier: item.bundleIdentifier,
            anchorKey: anchorKey,
            localMidY: rowFrames[anchorKey]?.midY ?? TempraLayout.mainPanelSize.height * 0.57
        )
    }

    private func updateRowFrames(_ frames: [String: CGRect]) {
        rowFrames = frames
        guard let selection = activeSelection,
              let frame = frames[selection.anchorKey],
              abs(frame.midY - selection.localMidY) > 0.5 else {
            return
        }
        presentation.updateSelectionAnchor(
            anchorKey: selection.anchorKey,
            localMidY: frame.midY
        )
    }

    private var activeSelection: MenuPanelSelection? {
        presentation.selection
    }

    private var filteredItems: [AppDisplayItem] {
        let scoped = store.displayItems.filter { item in
            switch scope {
            case .running: item.isRunning
            case .rules: item.rule != nil
            case .alerts: item.isAttention
            }
        }

        let searched: [AppDisplayItem]
        if searchText.isEmpty {
            searched = scoped
        } else {
            searched = scoped.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }

        return searched.sorted { lhs, rhs in
            switch processSort {
            case .averageDescending:
                if lhs.averageCPUPercent != rhs.averageCPUPercent {
                    return lhs.averageCPUPercent > rhs.averageCPUPercent
                }
            case .averageAscending:
                if lhs.averageCPUPercent != rhs.averageCPUPercent {
                    return lhs.averageCPUPercent < rhs.averageCPUPercent
                }
            case .currentDescending:
                if lhs.cpuPercent != rhs.cpuPercent {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
            case .currentAscending:
                if lhs.cpuPercent != rhs.cpuPercent {
                    return lhs.cpuPercent < rhs.cpuPercent
                }
            case .powerDescending:
                switch (lhs.cpuPowerWatts, rhs.cpuPowerWatts) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            case .powerAscending:
                switch (lhs.cpuPowerWatts, rhs.cpuPowerWatts) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            case .name:
                break
            }
            return lhs.sortName < rhs.sortName
        }
    }

    private var processSectionHeight: CGFloat {
        store.preferences.showsCPUHistoryGraph ? 255 : 399
    }

    private var managedItems: [AppDisplayItem] {
        let actualItems = store.displayItems
            .filter { item in
                guard item.rule != nil else { return false }
                return searchText.isEmpty
                    || item.name.localizedCaseInsensitiveContains(searchText)
                    || item.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { lhs, rhs in
                if lhs.estimatedSavedCPUPercent != rhs.estimatedSavedCPUPercent {
                    return lhs.estimatedSavedCPUPercent > rhs.estimatedSavedCPUPercent
                }
                return lhs.sortName < rhs.sortName
            }

        return actualItems
    }

    private var visibleManagedItems: [AppDisplayItem] {
        showsAllRules
            ? managedItems
            : Array(managedItems.prefix(collapsedRuleCount))
    }

    private var processHeading: String {
        switch scope {
        case .rules: return "Saved Rules"
        case .alerts: return "Needs Attention"
        case .running:
            return switch processSort {
            case .averageDescending, .currentDescending: "Highest CPU Processes"
            case .averageAscending, .currentAscending: "Lowest CPU Processes"
            case .powerDescending: "Highest Power Processes"
            case .powerAscending: "Lowest Power Processes"
            case .name: "Processes by Name"
            }
        }
    }

    private var isCurrentSort: Bool {
        processSort == .currentDescending || processSort == .currentAscending
    }

    private var isAverageSort: Bool {
        processSort == .averageDescending || processSort == .averageAscending
    }

    private var isPowerSort: Bool {
        processSort == .powerDescending || processSort == .powerAscending
    }

    private func badge(for scope: MenuScope) -> String {
        switch scope {
        case .running: ""
        case .rules: store.rules.isEmpty ? "" : " (\(store.rules.count))"
        case .alerts: store.attentionCount == 0 ? "" : " (\(store.attentionCount))"
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No Matches" }
        return switch scope {
        case .running: "No Running Apps"
        case .rules: "No Saved Rules"
        case .alerts: "Nothing Needs Attention"
        }
    }

    private var emptySymbol: String {
        switch scope {
        case .running: "app.dashed"
        case .rules: "checklist"
        case .alerts: "checkmark.circle"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Try a different app name." }
        return switch scope {
        case .running: "Tempra only shows apps owned by the current user."
        case .rules: "Select a running app to create its first rule."
        case .alerts: "Sustained high-CPU apps appear here."
        }
    }

    private func cpuText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func temperatureText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°", value)
    }

    private var displayedCPU: SystemCPUSnapshot {
        store.systemCPU
    }

    private var displayedHistory: [CPUHistorySample] {
        store.cpuHistorySamples
    }

    private var displayedSavedCPU: Double {
        store.estimatedSavedSystemPercent
    }

    private var historyRangeBinding: Binding<CPUHistoryRange> {
        Binding(
            get: { store.preferences.historyRange },
            set: { range in store.setHistoryRange(range) }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { store.preferences.appearance },
            set: { appearance in store.setAppearance(appearance) }
        )
    }

    private var displayedManagementEnabled: Bool {
        store.isEnabled
    }
}
