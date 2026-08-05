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
    case powerDescending = "Highest Est. Power"
    case powerAscending = "Lowest Est. Power"
    case name = "Name"

    var id: String { rawValue }
}

struct MenuBarItemLists {
    let processItems: [AppDisplayItem]
    let managedItems: [AppDisplayItem]
    let visibleManagedItems: [AppDisplayItem]

    init(
        displayItems: [AppDisplayItem],
        includesBackgroundAndSystemProcesses: Bool,
        scope: MenuScope,
        processSort: ProcessSort,
        searchText: String,
        showsAllRules: Bool,
        collapsedRuleCount: Int
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
            managedItems = displayItems
                .filter { item in
                    item.rule != nil && (searchText.isEmpty
                        || Self.matchesSearch(item, searchText: searchText))
                }
                .sorted { lhs, rhs in
                    if lhs.estimatedSavedCPUPercent != rhs.estimatedSavedCPUPercent {
                        return lhs.estimatedSavedCPUPercent > rhs.estimatedSavedCPUPercent
                    }
                    return lhs.sortName < rhs.sortName
                }
        } else {
            managedItems = []
        }
        visibleManagedItems = showsAllRules
            ? managedItems
            : Array(managedItems.prefix(collapsedRuleCount))
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
    @State private var searchText = ""
    @State private var showsAllRules = false
    @State private var rowFrames: [String: CGRect] = [:]

    private let collapsedRuleCount = 5
    private let coordinateSpaceName = "tempra.main.panel"

    var body: some View {
        let itemLists = MenuBarItemLists(
            displayItems: store.displayItems,
            includesBackgroundAndSystemProcesses: store.preferences
                .includesEssentialSystemProcesses,
            scope: scope,
            processSort: presentation.processSort,
            searchText: searchText,
            showsAllRules: showsAllRules,
            collapsedRuleCount: collapsedRuleCount
        )
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TempraLayout.mainNotchHeight)

            monitorPanel(itemLists: itemLists)
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

    private func monitorPanel(itemLists: MenuBarItemLists) -> some View {
        VStack(spacing: 0) {
            header

            if presentation.showsPrivilegedAccessOnboarding,
               !store.privilegedControlStatus.isEnabled {
                PrivilegedAccessControl(
                    store: store,
                    context: .onboarding,
                    onDismiss: presentation.dismissPrivilegedAccessOnboarding
                )
                .padding(10)
                .background(
                    TempraPalette.secondaryControlFill,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(TempraPalette.border.opacity(0.7), lineWidth: 1)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
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
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(TempraPalette.separator)

            VStack(spacing: 0) {
                processSection(items: itemLists.processItems)
                    .frame(minHeight: 64, maxHeight: .infinity)
                    .layoutPriority(1)

                if scope == .running {
                    Divider()
                        .overlay(TempraPalette.separator)
                        .padding(.vertical, 7)
                    managedSection(
                        managedItems: itemLists.managedItems,
                        visibleManagedItems: itemLists.visibleManagedItems
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .frame(maxHeight: .infinity)
            .background(TempraPalette.subtleFill)

            Divider()
                .overlay(TempraPalette.separator)
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
        let batteryComparison = store.batteryPowerComparison
        let batteryResultColor = batteryComparison.savedWatts.map {
            $0 >= 0 ? TempraPalette.saved : TempraPalette.stopped
        } ?? TempraPalette.primaryText

        return VStack(spacing: 2) {
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
                "BATTERY DRAW BEFORE LIMIT",
                value: BatteryPowerFormatter.beforeLimitText(batteryComparison),
                color: TempraPalette.primaryText
            )
            metricLine(
                "BATTERY DRAW AFTER LIMIT",
                value: BatteryPowerFormatter.afterLimitText(batteryComparison),
                color: batteryResultColor
            )
            .help(
                "Tempra freezes a stable whole-system battery baseline, waits for the limiter "
                    + "and battery sensor to settle, then measures a separate stable window. "
                    + "The result is frozen until the limiting session ends."
            )
            metricLine(
                "MEASURED BATTERY CHANGE",
                value: BatteryPowerFormatter.changeText(batteryComparison),
                color: batteryResultColor
            )
            .help(
                "This is the observed change in the Mac’s total battery draw. Tempra reports "
                    + "Inconclusive when the readings are unstable or the set of limited apps changes."
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
            Text("Include background and system processes")
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
              ? "Hide background processes and protected macOS services"
              : "Show user-owned background processes and protected macOS services")
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
            contextMenu(for: item, anchorKey: anchorKey)
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

            sortColumn(
                "EST. W",
                width: TempraLayout.powerColumnWidth,
                isSelected: isPowerSort
            ) {
                presentation.processSort = presentation.processSort == .powerDescending
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

    private func managedSection(
        managedItems: [AppDisplayItem],
        visibleManagedItems: [AppDisplayItem]
    ) -> some View {
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
            contextMenu(for: item, anchorKey: anchorKey)
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

        if item.canManageProcess {
            if item.canQuitProcess {
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
                        requiresPrivateQoS: item.rule?.runOnEfficiencyCores == true
                    )
                }
            }

            Button(item.rule?.runOnEfficiencyCores == true
                   ? "Stop Using Power-Saving Cores"
                   : "Run on Power-Saving Cores") {
                let enablesPrivateQoS = item.rule?.runOnEfficiencyCores != true
                store.setEfficiencyCoreScheduling(
                    bundleIdentifier: item.bundleIdentifier,
                    displayName: item.name,
                    applicationURL: item.applicationURL,
                    enabled: enablesPrivateQoS,
                    delaySeconds: 0
                )
                requestPrivilegedControlIfNeeded(
                    for: item,
                    requiresPrivateQoS: enablesPrivateQoS
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
        } else {
            Text("Protected for SoundSource compatibility")
        }
    }

    private func requestPrivilegedControlIfNeeded(
        for item: AppDisplayItem,
        requiresPrivateQoS: Bool = false
    ) {
        guard (item.requiresPrivilegedControl || requiresPrivateQoS),
              !store.privilegedControlStatus.isEnabled else { return }
        Task {
            _ = await store.requestPrivilegedControl()
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
        case .rules: return "Saved Rules"
        case .alerts: return "Needs Attention"
        case .running:
            return switch presentation.processSort {
            case .averageDescending, .currentDescending: "Highest CPU Processes"
            case .averageAscending, .currentAscending: "Lowest CPU Processes"
            case .powerDescending: "Highest Power Processes"
            case .powerAscending: "Lowest Power Processes"
            case .name: "Processes by Name"
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

    private var isPowerSort: Bool {
        presentation.processSort == .powerDescending
            || presentation.processSort == .powerAscending
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
