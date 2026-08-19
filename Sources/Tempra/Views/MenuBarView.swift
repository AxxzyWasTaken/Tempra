import AppKit
import SwiftUI

enum MenuScope: String, CaseIterable, Hashable, Identifiable {
    case running = "Running"
    case rules = "Rules"
    case alerts = "Alerts"

    var id: String { rawValue }
}

enum ProcessSort: String, CaseIterable, Hashable, Identifiable {
    case averageDescending = "Highest 1m Average"
    case averageAscending = "Lowest 1m Average"
    case currentDescending = "Highest Current CPU"
    case currentAscending = "Lowest Current CPU"
    case name = "Name"

    var id: String { rawValue }
}

struct MenuBarItemLists {
    let processItems: [AppDisplayItem]
    let activeManagedItems: [AppDisplayItem]

    init(
        displayItems: [AppDisplayItem],
        includesBackgroundAndSystemProcesses: Bool,
        scope: MenuScope,
        processSort: ProcessSort,
        searchText: String
    ) {
        let scopedItems = displayItems.filter { item in
            switch scope {
            case .running:
                item.isRunning && (
                    includesBackgroundAndSystemProcesses
                        || (!item.isSystemProcess && !item.isBackgroundProcess
                            && !item.isStandaloneProcess)
                )
            case .rules: item.rule != nil
            case .alerts: item.isAttention
            }
        }
        let searchedItems: [AppDisplayItem]
        if searchText.isEmpty {
            searchedItems = scopedItems
        } else {
            searchedItems = scopedItems.filter {
                Self.matchesSearch($0, searchText: searchText)
            }
        }
        processItems = searchedItems.sorted {
            Self.processOrder($0, $1, sort: processSort)
        }

        if scope == .running {
            activeManagedItems = displayItems
                .filter { item in
                    item.rule != nil
                        && item.isRunning
                        && (item.isCPULimitSessionActive
                            || item.status.isActivelySavingPower)
                        && (searchText.isEmpty
                            || Self.matchesSearch(item, searchText: searchText))
                }
                .sorted(by: Self.managedOrder)
        } else {
            activeManagedItems = []
        }
    }

    private static func matchesSearch(
        _ item: AppDisplayItem,
        searchText: String
    ) -> Bool {
        item.name.localizedCaseInsensitiveContains(searchText)
            || item.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
    }

    private static func processOrder(
        _ lhs: AppDisplayItem,
        _ rhs: AppDisplayItem,
        sort: ProcessSort
    ) -> Bool {
        switch sort {
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
        case .name:
            break
        }
        return lhs.sortName < rhs.sortName
    }

    private static func managedOrder(
        _ lhs: AppDisplayItem,
        _ rhs: AppDisplayItem
    ) -> Bool {
        let leftPriority = managedPriority(lhs)
        let rightPriority = managedPriority(rhs)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if leftPriority == 1,
           lhs.estimatedSavedCPUPercent != rhs.estimatedSavedCPUPercent {
            return lhs.estimatedSavedCPUPercent > rhs.estimatedSavedCPUPercent
        }
        if lhs.sortName != rhs.sortName {
            return lhs.sortName < rhs.sortName
        }
        return lhs.bundleIdentifier < rhs.bundleIdentifier
    }

    private static func managedPriority(_ item: AppDisplayItem) -> Int {
        switch item.status {
        case .paused:
            return 0
        case .limited, .limitedWithProtectedProcesses:
            return 1
        case .lowerPriority:
            return 2
        case .normal, .waiting, .audioProtected, .networkProtected, .snoozed,
                .managementPaused, .disabled, .notRunning, .unavailable:
            return item.isCPULimitSessionActive ? 1 : 3
        }
    }
}

private struct HeaderActionsMenu: View, Equatable {
    let scope: MenuScope
    let scopeBadges: [MenuScope: String]
    let historyRange: CPUHistoryRange
    let appearance: AppAppearance
    let managementPauseUntil: Date?
    let isMonitorDetached: Bool
    let canCheckForUpdates: Bool
    let onScopeChange: (MenuScope) -> Void
    let onHistoryRangeChange: (CPUHistoryRange) -> Void
    let onAppearanceChange: (AppAppearance) -> Void
    let onPauseManagement: (TimeInterval) -> Void
    let onResumeManagement: () -> Void
    let onSetMonitorDetached: (Bool) -> Void
    let onExportDiagnostics: () -> Void
    let onCheckForUpdates: () -> Void
    let onShowSettings: () -> Void
    let onQuit: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope
            && lhs.scopeBadges == rhs.scopeBadges
            && lhs.historyRange == rhs.historyRange
            && lhs.appearance == rhs.appearance
            && lhs.managementPauseUntil == rhs.managementPauseUntil
            && lhs.isMonitorDetached == rhs.isMonitorDetached
            && lhs.canCheckForUpdates == rhs.canCheckForUpdates
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

            if managementPauseUntil.map({ $0 > Date() }) == true {
                Button("Resume Management Now", action: onResumeManagement)
            } else {
                Menu("Pause Management") {
                    Button("For 15 Minutes") {
                        onPauseManagement(15 * 60)
                    }
                    Button("For 1 Hour") {
                        onPauseManagement(60 * 60)
                    }
                    Button("For 4 Hours") {
                        onPauseManagement(4 * 60 * 60)
                    }
                }
            }

            Button(
                isMonitorDetached ? "Attach Monitor to Menu Bar" : "Detach Monitor",
                action: { onSetMonitorDetached(!isMonitorDetached) }
            )

            Button("Export Diagnostics…", action: onExportDiagnostics)

            Divider()

            Button("Check for Updates…", action: onCheckForUpdates)
                .disabled(!canCheckForUpdates)
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @ObservedObject var store: AppStore
    @ObservedObject var presentation: MenuPanelPresentation
    @ObservedObject var updateController: TempraUpdateController

    @State private var scope: MenuScope = .running
    @State private var searchText = ""
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var isManagedSectionExpanded = false

    private let managedViewportRowCount = 4
    private let expandedManagedViewportRowCount = 8
    private let coordinateSpaceName = "tempra.main.panel"

    var body: some View {
        let itemLists = MenuBarItemLists(
            displayItems: store.displayItems,
            includesBackgroundAndSystemProcesses: store.preferences
                .includesEssentialSystemProcesses,
            scope: scope,
            processSort: presentation.processSort,
            searchText: searchText
        )
        VStack(spacing: 0) {
            if !presentation.isMonitorDetached {
                Color.clear
                    .frame(height: TempraLayout.mainNotchHeight)
            }

            monitorPanel(itemLists: itemLists)
        }
        .frame(
            width: TempraLayout.mainPanelSize.width,
            height: TempraLayout.mainPanelSize.height
        )
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(ProcessRowFramesKey.self, perform: updateRowFrames)
        .tempraPanelSurface(
            MonitorPanelShape(isDetached: presentation.isMonitorDetached)
        )
        .tempraAppearance(store.preferences.appearance)
    }

    private func monitorPanel(itemLists: MenuBarItemLists) -> some View {
        VStack(spacing: 0) {
            header

            if let managementPauseUntil = activeManagementPauseUntil {
                panelNotice(
                    symbolName: "pause.circle.fill",
                    color: TempraPalette.waiting,
                    message: "Management is paused until "
                        + managementPauseUntil.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                        + ". All controlled processes are resumed.",
                    actionTitle: "Resume",
                    action: store.resumeManagement
                )
            }

            if let restorationFailure = store.lifecycleRestorationFailure {
                panelNotice(
                    symbolName: "exclamationmark.triangle.fill",
                    color: TempraPalette.stopped,
                    message: Self.lifecycleFailureMessage(restorationFailure),
                    actionTitle: "Retry",
                    action: {
                        Task {
                            await store.retryLifecycleRestoration()
                        }
                    }
                )
            }

            diagnosticNotice

            if presentation.showsPrivilegedAccessOnboarding,
               !store.privilegedControlStatus.isEnabled {
                PrivilegedAccessControl(
                    store: store,
                    context: .onboarding,
                    onDismiss: presentation.dismissPrivilegedAccessOnboarding
                )
                .padding(12)
                .background(
                    TempraPalette.secondaryControlFill,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            summaryMetrics
                .fixedSize(horizontal: false, vertical: true)

            if store.preferences.showsCPUHistoryGraph {
                CPUHistoryChartView(
                    samples: displayedHistory,
                    range: historyRangeBinding,
                    performanceCoreCount: displayedCPU.performanceCoreCount,
                    efficiencyCoreCount: displayedCPU.efficiencyCoreCount
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                if scope == .running, !itemLists.activeManagedItems.isEmpty {
                    managedSection(activeItems: itemLists.activeManagedItems)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                processSection(items: itemLists.processItems)
                    .frame(minHeight: 64, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)

            footer
                .fixedSize(horizontal: false, vertical: true)
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
            .help(managementToggleHelp)
            .accessibilityLabel("Management")

            searchField

            HeaderActionsMenu(
                scope: scope,
                scopeBadges: Dictionary(
                    uniqueKeysWithValues: MenuScope.allCases.map { ($0, badge(for: $0)) }
                ),
                historyRange: store.preferences.historyRange,
                appearance: store.preferences.appearance,
                managementPauseUntil: store.preferences.managementPauseUntil,
                isMonitorDetached: presentation.isMonitorDetached,
                canCheckForUpdates: updateController.canCheckForUpdates,
                onScopeChange: { scope = $0 },
                onHistoryRangeChange: store.setHistoryRange,
                onAppearanceChange: store.setAppearance,
                onPauseManagement: store.pauseManagement,
                onResumeManagement: store.resumeManagement,
                onSetMonitorDetached: presentation.setMonitorDetached,
                onExportDiagnostics: {
                    Task {
                        await store.exportDiagnostics()
                    }
                },
                onCheckForUpdates: updateController.checkForUpdates,
                onShowSettings: {
                    presentation.showSettings()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .equatable()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(height: 44)
    }

    private func panelNotice(
        symbolName: String,
        color: Color,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(message)
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TempraPalette.secondaryText)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var diagnosticNotice: some View {
        switch store.diagnosticExportStatus {
        case .idle:
            EmptyView()
        case .exporting:
            panelNotice(
                symbolName: "arrow.down.doc.fill",
                color: TempraPalette.accent,
                message: "Preparing the diagnostic report…"
            )
        case .saved(let url):
            panelNotice(
                symbolName: "checkmark.circle.fill",
                color: TempraPalette.saved,
                message: "Saved diagnostics as \(url.lastPathComponent).",
                dismiss: store.dismissDiagnosticExportStatus
            )
        case .failed(let message):
            panelNotice(
                symbolName: "exclamationmark.triangle.fill",
                color: TempraPalette.stopped,
                message: "Diagnostic export failed: \(message)",
                dismiss: store.dismissDiagnosticExportStatus
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TempraPalette.secondaryText)

            TextField("Search apps", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(TempraPalette.tertiaryText)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            TempraPalette.searchFill,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var summaryMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Total CPU")
                            .font(TempraTypography.heroLabel)
                            .foregroundStyle(TempraPalette.secondaryText)

                        Circle()
                            .fill(displayedCPU.totalPercent > 70 ? TempraPalette.stopped : TempraPalette.accent)
                            .frame(width: 5, height: 5)
                    }

                    Text(cpuText(displayedCPU.totalPercent))
                        .font(TempraTypography.heroValue)
                        .foregroundStyle(TempraPalette.primaryText)
                        .accessibilityLabel("Total CPU usage \(cpuText(displayedCPU.totalPercent))")
                }

                Spacer(minLength: 8)

                if displayedCPU.performanceCoreCount > 0 || displayedCPU.efficiencyCoreCount > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 5) {
                            if displayedCPU.performanceCoreCount > 0 {
                                Text("\(displayedCPU.performanceCoreCount)P")
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(TempraPalette.performance)
                            }
                            if displayedCPU.efficiencyCoreCount > 0 {
                                Text("\(displayedCPU.efficiencyCoreCount)E")
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(TempraPalette.efficiency)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            TempraPalette.secondaryControlFill,
                            in: Capsule(style: .continuous)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(TempraPalette.border.opacity(0.35), lineWidth: 0.5)
                        )

                        // Capacity breakdown miniature bar
                        GeometryReader { barGeo in
                            let pFraction = min(1.0, displayedCPU.performancePercent / 100.0)
                            let eFraction = min(1.0, displayedCPU.efficiencyPercent / 100.0)
                            let barWidth = barGeo.size.width

                            HStack(spacing: 1.5) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(TempraPalette.performance)
                                    .frame(width: max(2, barWidth * pFraction))
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(TempraPalette.efficiency)
                                    .frame(width: max(2, barWidth * eFraction))
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(TempraPalette.controlFill)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(width: 58, height: 3.5)
                        .clipShape(Capsule(style: .continuous))
                    }
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                metricChip(
                    "Performance",
                    value: cpuText(displayedCPU.performancePercent),
                    color: TempraPalette.performance,
                    icon: "bolt.fill"
                )
                if displayedCPU.efficiencyCoreCount > 0 {
                    metricChip(
                        "Efficiency",
                        value: cpuText(displayedCPU.efficiencyPercent),
                        color: TempraPalette.efficiency,
                        icon: "leaf.fill"
                    )
                }
                metricChip(
                    "System Saved",
                    value: cpuText(displayedSavedCPU),
                    color: TempraPalette.saved,
                    icon: "shield.lefthalf.filled"
                )
                .help(
                    "Estimated share of total CPU capacity saved across all logical CPUs. "
                        + "Per-app values use the Activity Monitor scale, where 100% "
                        + "equals one logical CPU."
                )
                metricChip(
                    "Temperature",
                    value: temperatureText(displayedCPU.cpuTemperatureCelsius),
                    color: TempraPalette.thermal,
                    icon: "thermometer.medium"
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func metricChip(
        _ title: String,
        value: String,
        color: Color,
        icon: String
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TempraTypography.metric)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .lineLimit(1)
                Text(value)
                    .font(TempraTypography.metricValue)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            TempraPalette.secondaryControlFill,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(TempraPalette.border.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }

    private func processSection(items: [AppDisplayItem]) -> some View {
        VStack(spacing: 0) {
            processHeader
                .padding(.top, 4)
                .padding(.bottom, 1)

            if items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
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
            HStack(spacing: 6) {
                Image(systemName: isIncluded
                      ? "checkmark.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(isIncluded
                      ? "Showing background and system processes"
                      : "Include background and system processes")
                    .font(TempraTypography.footer)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(
                isIncluded
                    ? TempraPalette.primaryText
                    : TempraPalette.accent
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(
                TempraPalette.secondaryControlFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .help(isIncluded
              ? "Hide background processes and protected macOS services"
              : "Show user-owned background processes and protected macOS services")
        .accessibilityLabel("Include background and system processes")
        .accessibilityValue(isIncluded ? "On" : "Off")
    }

    private func processRow(_ item: AppDisplayItem) -> some View {
        let anchorKey = "process:\(item.bundleIdentifier)"
        return ProcessRowView(
            item: item,
            isSystemProcess: item.isSystemProcess,
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
            if !item.isCurrentApplication {
                contextMenu(for: item, anchorKey: anchorKey)
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: TempraLayout.processColumnSpacing) {
            Menu {
                Picker("Sort", selection: $presentation.processSort) {
                    ForEach(ProcessSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
            } label: {
                Text(processHeading)
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
                presentation.processSort = presentation.processSort == .currentDescending
                    ? .currentAscending
                    : .currentDescending
            }

            sortColumn(
                "AVG %",
                width: TempraLayout.averageCPUColumnWidth,
                isSelected: isAverageSort
            ) {
                presentation.processSort = presentation.processSort == .averageDescending
                    ? .averageAscending
                    : .averageDescending
            }

        }
        .padding(.horizontal, TempraLayout.processRowHorizontalInset)
        .foregroundStyle(TempraPalette.secondaryText)
        .frame(height: 26)
        .padding(.top, 2)
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

    private func managedSection(activeItems: [AppDisplayItem]) -> some View {
        let visibleItems = activeItems.prefix(
            isManagedSectionExpanded
                ? activeItems.count
                : managedViewportRowCount
        )

        return VStack(spacing: 0) {
            HStack(spacing: TempraLayout.processColumnSpacing) {
                Text("Managed now")
                    .font(TempraTypography.sectionHeading)
                    .foregroundStyle(TempraPalette.primaryText)

                Text("\(activeItems.count)")
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.secondaryText)

                Spacer(minLength: 4)

                Button("All Rules") {
                    scope = .rules
                }
                .buttonStyle(.plain)
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.accent)
                .help("Show all saved rules")
                .accessibilityLabel("All Rules")

                Text("Saved % CPU")
                    .font(TempraTypography.tableHeader)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(
                        width: TempraLayout.averageCPUColumnWidth,
                        alignment: .trailing
                    )
                    .help(
                        "Estimated CPU use prevented for each app. Values use the "
                            + "Activity Monitor scale, where 100% equals one logical CPU."
                    )
            }
            .padding(.horizontal, TempraLayout.processRowHorizontalInset)
            .frame(height: 28)

            if isManagedSectionExpanded,
               activeItems.count > expandedManagedViewportRowCount {
                ScrollView(.vertical) {
                    managedRows(visibleItems)
                }
                .scrollIndicators(.visible)
                .frame(
                    height: CGFloat(expandedManagedViewportRowCount)
                        * TempraLayout.processRowHeight
                )
            } else {
                managedRows(visibleItems)
            }

            if activeItems.count > managedViewportRowCount {
                Button {
                    withAnimation(
                        accessibilityReduceMotion
                            ? nil
                            : .easeOut(duration: 0.18)
                    ) {
                        isManagedSectionExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isManagedSectionExpanded ? "Show Less" : "Show All")
                        Image(systemName: isManagedSectionExpanded
                              ? "chevron.up"
                              : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(TempraTypography.footer)
                    .foregroundStyle(TempraPalette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isManagedSectionExpanded
                        ? "Show Less Managed Apps"
                        : "Show All Managed Apps"
                )
                .accessibilityValue(
                    isManagedSectionExpanded ? "Expanded" : "Collapsed"
                )
            }
        }
    }

    private func managedRows(
        _ items: ArraySlice<AppDisplayItem>
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                managedRow(item)
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
            contextMenu(for: item, anchorKey: anchorKey)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: emptySymbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(TempraPalette.tertiaryText)
            Text(emptyTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(emptyDescription)
                .font(.system(size: 11))
                .foregroundStyle(TempraPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func contextMenu(for item: AppDisplayItem, anchorKey: String) -> some View {
        Button("View Activity Details…") {
            showActivity(item: item, anchorKey: anchorKey)
        }

        if item.canControlApplication || item.applicationURL != nil {
            Divider()
        }

        if item.canControlApplication {
            Button("Bring to Front") {
                performApplicationCommand(
                    .bringToFront,
                    item: item,
                    anchorKey: anchorKey
                )
            }

            if !item.isHidden {
                Button("Hide") {
                    performApplicationCommand(
                        .hide,
                        item: item,
                        anchorKey: anchorKey
                    )
                }
            }
        }

        if item.applicationURL != nil {
            Button("Show in Finder") {
                guard store.revealApplication(item) else {
                    showActivity(item: item, anchorKey: anchorKey)
                    return
                }
            }
        }

        if item.canControlApplication {
            Divider()

            Button("Quit") {
                performApplicationCommand(
                    .quitGracefully,
                    item: item,
                    anchorKey: anchorKey
                )
            }

            Button("Relaunch") {
                performApplicationCommand(
                    .relaunch,
                    item: item,
                    anchorKey: anchorKey
                )
            }
        }

        if item.canManageProcess {
            if item.canQuitProcess {
                Divider()

                Button(item.canControlApplication ? "Force Quit" : "Force Quit Process") {
                    performApplicationCommand(
                        .quit,
                        item: item,
                        anchorKey: anchorKey
                    )
                }
            }

            Divider()

            if item.canLimitCPU {
                Button("Limit to 50%") {
                    store.applyQuickRule(
                        bundleIdentifier: item.bundleIdentifier,
                        displayName: item.name,
                        applicationURL: item.applicationURL,
                        action: .limit,
                        limitPercent: 50,
                        delaySeconds: 0
                    )
                    requestPrivilegedControlIfNeeded(
                        for: item,
                        requiresLowerPriority: item.rule?.lowersCPUPriority == true
                    )
                }
            }

            Button(item.rule?.lowersCPUPriority == true
                   ? "Restore Normal CPU Priority"
                   : "Lower CPU Priority") {
                let enablesLowerPriority = item.rule?.lowersCPUPriority != true
                store.setLowerCPUPriority(
                    bundleIdentifier: item.bundleIdentifier,
                    displayName: item.name,
                    applicationURL: item.applicationURL,
                    enabled: enablesLowerPriority,
                    delaySeconds: 0
                )
                requestPrivilegedControlIfNeeded(
                    for: item,
                    requiresLowerPriority: enablesLowerPriority
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
                requestPrivilegedControlIfNeeded(for: item)
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

                Divider()
                Button("Remove Rule", role: .destructive) {
                    store.removeRule(bundleIdentifier: item.bundleIdentifier)
                }
            }
        } else {
            Text(item.isSoundSourceComponent
                 ? "Protected for SoundSource compatibility"
                 : "Protected system process · monitor only")
        }
    }

    private func requestPrivilegedControlIfNeeded(
        for item: AppDisplayItem,
        requiresLowerPriority: Bool = false
    ) {
        guard (item.requiresPrivilegedControl || requiresLowerPriority),
              !store.privilegedControlStatus.isEnabled else { return }
        Task {
            _ = await store.requestPrivilegedControl()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                legendItem("Running", color: TempraPalette.running)
                legendItem("Slowed", color: TempraPalette.slowed)
                legendItem("Stopped", color: TempraPalette.stopped)
            }

            HStack(spacing: 4) {
                Text("Profile")
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
                    Text(profileLabel)
                        .foregroundStyle(TempraPalette.primaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .tint(TempraPalette.primaryText)
                .fixedSize()
            }
        }
        .font(TempraTypography.footer)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            TempraStatusDot(color: color, fill: .full, size: 7)
            Text(title)
                .foregroundStyle(TempraPalette.secondaryText)
        }
    }

    private func showActivity(item: AppDisplayItem, anchorKey: String) {
        presentation.showActivity(
            bundleIdentifier: item.bundleIdentifier,
            anchorKey: anchorKey,
            localMidY: rowFrames[anchorKey]?.midY
                ?? TempraLayout.mainPanelSize.height * 0.57
        )
    }

    private func performApplicationCommand(
        _ command: ApplicationCommand,
        item: AppDisplayItem,
        anchorKey: String
    ) {
        Task {
            guard await store.performApplicationCommand(command, for: item) else {
                showActivity(item: item, anchorKey: anchorKey)
                return
            }
        }
    }

    private func select(item: AppDisplayItem, anchorKey: String) {
        guard !item.isCurrentApplication else { return }
        if !item.canManageProcess {
            showActivity(item: item, anchorKey: anchorKey)
            return
        }
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

    private var processHeading: String {
        switch scope {
        case .rules: return "Saved rules"
        case .alerts: return "Needs attention"
        case .running:
            return switch presentation.processSort {
            case .averageDescending, .currentDescending: "Highest CPU"
            case .averageAscending, .currentAscending: "Lowest CPU"
            case .name: "Processes"
            }
        }
    }

    private var isCurrentSort: Bool {
        presentation.processSort == .currentDescending
            || presentation.processSort == .currentAscending
    }

    private var isAverageSort: Bool {
        presentation.processSort == .averageDescending
            || presentation.processSort == .averageAscending
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

    private var activeManagementPauseUntil: Date? {
        store.preferences.managementPauseUntil.flatMap {
            $0 > Date() ? $0 : nil
        }
    }

    private var managementToggleHelp: String {
        if let activeManagementPauseUntil {
            return "Management is enabled but paused until "
                + activeManagementPauseUntil.formatted(
                    date: .omitted,
                    time: .shortened
                )
        }
        return displayedManagementEnabled
            ? "Management is on"
            : "Management is off; all apps are resumed"
    }


    private var profileLabel: String {
        guard let profile = store.effectiveManagementProfile else {
            return "No Active Profile"
        }
        return store.automaticProfileID == profile.id
            ? "Auto: \(profile.name)"
            : profile.name
    }

    static func lifecycleFailureMessage(_ result: ProcessRestorationResult) -> String {
        var messages: [String] = []
        let resumeFailures = result.failures.filter { !$0.stoppedProcesses.isEmpty }
        let resumeProcessCount = Set(resumeFailures.flatMap(\.stoppedProcesses)).count
        if resumeProcessCount > 0 {
            let appCount = resumeFailures.count
            messages.append(
                "Tempra could not resume \(resumeProcessCount) "
                    + (resumeProcessCount == 1 ? "process" : "processes")
                    + " in \(appCount) "
                    + (appCount == 1 ? "app." : "apps.")
            )
        }

        let priorityFailures = result.failures.filter {
            !$0.backgroundPriorityProcesses.isEmpty
        }
        let priorityProcessCount = Set(
            priorityFailures.flatMap(\.backgroundPriorityProcesses)
        ).count
        if priorityProcessCount > 0 {
            let appCount = priorityFailures.count
            messages.append(
                "Tempra could not restore normal priority for \(priorityProcessCount) "
                    + (priorityProcessCount == 1 ? "process" : "processes")
                    + " in \(appCount) "
                    + (appCount == 1 ? "app." : "apps.")
            )
        }

        let details = Set(result.failures.flatMap {
            [$0.resumeFailureDescription, $0.priorityFailureDescription].compactMap { $0 }
        })
        messages.append(contentsOf: details.sorted())
        messages.append("Management remains blocked.")
        return messages.joined(separator: " ")
    }
}
