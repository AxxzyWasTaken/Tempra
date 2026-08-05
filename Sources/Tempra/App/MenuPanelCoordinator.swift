import AppKit
import Combine
import SwiftUI

enum MenuPanelInspector: Equatable {
    case rule
    case activity
}

struct MenuPanelSelection: Equatable {
    let bundleIdentifier: String
    let anchorKey: String
    let localMidY: CGFloat
    let inspector: MenuPanelInspector
}

struct MenuDismissalGate {
    private(set) var trackingDepth = 0
    private(set) var suppressDismissalUntil = Date.distantPast

    var isTracking: Bool { trackingDepth > 0 }

    mutating func beginTracking() {
        trackingDepth += 1
        suppressDismissalUntil = .distantFuture
    }

    mutating func endTracking(at date: Date = Date()) {
        trackingDepth = max(0, trackingDepth - 1)
        if trackingDepth == 0 {
            suppressDismissalUntil = date.addingTimeInterval(0.2)
        }
    }

    func allowsDismissal(at date: Date = Date()) -> Bool {
        trackingDepth == 0 && date >= suppressDismissalUntil
    }
}

struct StatusItemState: Equatable {
    let symbolName: String
    let title: String
    let toolTip: String

    init(systemCPU: SystemCPUSnapshot, isEnabled: Bool, preferences: AppPreferences) {
        symbolName = isEnabled ? "gauge.with.dots.needle.67percent" : "pause.circle"
        let roundedCPU = min(100, max(0, Int(systemCPU.totalPercent.rounded())))
        if preferences.showsCPUUsageInMenuBar {
            let digits = String(roundedCPU)
            title = " " + String(repeating: "\u{2007}", count: 3 - digits.count) + digits + "%"
        } else {
            title = ""
        }
        if !isEnabled {
            toolTip = "Tempra · Management off"
        } else if preferences.showsCPUUsageInMenuBar {
            toolTip = "Tempra · \(roundedCPU)% total CPU"
        } else {
            toolTip = "Tempra · Monitoring on demand"
        }
    }
}

@MainActor
final class MenuPanelPresentation: ObservableObject {
    @Published var selection: MenuPanelSelection?
    @Published var settingsSection: TempraSettingsSection = .general
    @Published var processSort: ProcessSort = .averageDescending
    @Published var showsPrivilegedAccessOnboarding = false
    var onShowSettings: (() -> Void)?

    func select(bundleIdentifier: String, anchorKey: String, localMidY: CGFloat) {
        if selection?.bundleIdentifier == bundleIdentifier,
           selection?.anchorKey == anchorKey,
           selection?.inspector == .rule {
            selection = nil
        } else {
            selection = MenuPanelSelection(
                bundleIdentifier: bundleIdentifier,
                anchorKey: anchorKey,
                localMidY: localMidY,
                inspector: .rule
            )
        }
    }

    func showActivity(bundleIdentifier: String, anchorKey: String, localMidY: CGFloat) {
        selection = MenuPanelSelection(
            bundleIdentifier: bundleIdentifier,
            anchorKey: anchorKey,
            localMidY: localMidY,
            inspector: .activity
        )
    }

    func updateSelectionAnchor(anchorKey: String, localMidY: CGFloat) {
        guard let selection, selection.anchorKey == anchorKey else { return }
        self.selection = MenuPanelSelection(
            bundleIdentifier: selection.bundleIdentifier,
            anchorKey: anchorKey,
            localMidY: localMidY,
            inspector: selection.inspector
        )
    }

    func closeInspector() {
        selection = nil
    }

    func showPrivilegedAccessOnboarding() {
        showsPrivilegedAccessOnboarding = true
    }

    func dismissPrivilegedAccessOnboarding() {
        showsPrivilegedAccessOnboarding = false
    }

    func showSettings(section: TempraSettingsSection = .general) {
        selection = nil
        settingsSection = section
        onShowSettings?()
    }
}

@MainActor
final class MenuPanelCoordinator: NSObject, NSWindowDelegate {
    let presentation = MenuPanelPresentation()

    private let store: AppStore
    private let statusItem: NSStatusItem
    private var mainPanel: TempraPanel?
    private var inspectorPanel: TempraPanel?
    private var highCPUAlertPanel: TempraPanel?
    private var settingsPanel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var menuDismissalGate = MenuDismissalGate()
    private var renderedStatusItemState: StatusItemState?
    private var isInvalidated = false

    init(store: AppStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        presentation.onShowSettings = { [weak self] in
            self?.showSettingsPanel()
        }
        observeState()
        installMenuTrackingObservers()
    }

    func presentPrivilegedAccessOnboardingIfNeeded() {
        guard store.shouldPresentPrivilegedAccessOnboarding else { return }
        store.markPrivilegedAccessOnboardingPresented()
        presentation.showPrivilegedAccessOnboarding()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !self.isInvalidated,
                  self.presentation.showsPrivilegedAccessOnboarding else { return }
            self.showMainPanel()
        }
    }

    func closePanels() {
        presentation.closeInspector()
        inspectorPanel?.close()
        inspectorPanel?.contentViewController = nil
        inspectorPanel = nil
        mainPanel?.close()
        mainPanel?.contentViewController = nil
        mainPanel = nil
        store.setPresentationActive(false)
        removeEventMonitorsIfIdle()
        statusItem.button?.highlight(false)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        closePanels()
        highCPUAlertPanel?.close()
        highCPUAlertPanel?.contentViewController = nil
        highCPUAlertPanel = nil
        settingsPanel?.close()
        settingsPanel?.contentViewController = nil
        settingsPanel = nil
        presentation.onShowSettings = nil
        cancellables.removeAll()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggleMainPanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        updateStatusItem(
            systemCPU: store.systemCPU,
            isEnabled: store.isEnabled,
            preferences: store.preferences
        )
    }

    private func configure(panel: TempraPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func configureSettingsPanel(_ settingsPanel: NSPanel) {
        settingsPanel.title = "Tempra : General"
        settingsPanel.titleVisibility = .visible
        settingsPanel.titlebarAppearsTransparent = false
        settingsPanel.backgroundColor = .windowBackgroundColor
        settingsPanel.isReleasedWhenClosed = false
        settingsPanel.isFloatingPanel = true
        settingsPanel.hidesOnDeactivate = false
        settingsPanel.animationBehavior = .utilityWindow
        settingsPanel.level = .floating
        settingsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        settingsPanel.tabbingMode = .disallowed
        settingsPanel.isMovableByWindowBackground = true
        settingsPanel.contentMinSize = TempraLayout.settingsPanelSize
        settingsPanel.contentMaxSize = TempraLayout.settingsPanelSize
        settingsPanel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        settingsPanel.standardWindowButton(.zoomButton)?.isEnabled = false
        settingsPanel.delegate = self
    }

    private func makeTempraPanel(size: CGSize) -> TempraPanel {
        let panel = TempraPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configure(panel: panel)
        panel.setContentSize(size)
        panel.appearance = store.preferences.appearance.nsAppearance
        return panel
    }

    private func ensureMainPanel() -> TempraPanel {
        if let mainPanel { return mainPanel }
        let panel = makeTempraPanel(size: TempraLayout.mainPanelSize)
        panel.contentViewController = NSHostingController(
            rootView: MenuBarView(store: store, presentation: presentation)
        )
        mainPanel = panel
        return panel
    }

    private func ensureInspectorPanel() -> TempraPanel {
        if let inspectorPanel { return inspectorPanel }
        let panel = makeTempraPanel(size: TempraLayout.inspectorSize)
        panel.contentViewController = NSHostingController(
            rootView: InspectorPanelRoot(store: store, presentation: presentation)
        )
        inspectorPanel = panel
        return panel
    }

    private func ensureHighCPUAlertPanel() -> TempraPanel {
        if let highCPUAlertPanel { return highCPUAlertPanel }
        let panel = makeTempraPanel(size: TempraLayout.highCPUAlertPanelSize)
        panel.contentViewController = NSHostingController(
            rootView: HighCPUAlertPanelRoot(store: store, presentation: presentation)
        )
        highCPUAlertPanel = panel
        return panel
    }

    private func ensureSettingsPanel() -> NSPanel {
        if let settingsPanel { return settingsPanel }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: TempraLayout.settingsPanelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        configureSettingsPanel(panel)
        panel.contentViewController = NSHostingController(
            rootView: TempraSettingsView(store: store, presentation: presentation)
        )
        panel.setContentSize(TempraLayout.settingsPanelSize)
        panel.appearance = store.preferences.appearance.nsAppearance
        settingsPanel = panel
        return panel
    }

    private func observeState() {
        store.$systemCPU
            .combineLatest(store.$isEnabled)
            .sink { [weak self] systemCPU, isEnabled in
                guard let self else { return }
                self.updateStatusItem(
                    systemCPU: systemCPU,
                    isEnabled: isEnabled,
                    preferences: self.store.preferences
                )
            }
            .store(in: &cancellables)

        store.$preferences
            .sink { [weak self] preferences in
                guard let self else { return }
                self.applyAppearance(preferences.appearance)
                self.updateStatusItem(
                    systemCPU: self.store.systemCPU,
                    isEnabled: self.store.isEnabled,
                    preferences: preferences
                )
            }
            .store(in: &cancellables)

        presentation.$selection
            .sink { [weak self] selection in
                self?.updateInspector(for: selection)
            }
            .store(in: &cancellables)

        store.$displayItems
            .sink { [weak self] items in
                guard let self,
                      let selection = presentation.selection,
                      !items.contains(where: {
                          $0.bundleIdentifier == selection.bundleIdentifier
                      }) else {
                    return
                }
                presentation.closeInspector()
            }
            .store(in: &cancellables)

        presentation.$settingsSection
            .sink { [weak self] section in
                self?.settingsPanel?.title = "Tempra : \(section.rawValue)"
            }
            .store(in: &cancellables)

        store.$pendingHighCPUAlert
            .sink { [weak self] alert in
                self?.updateHighCPUAlertPanel(for: alert)
            }
            .store(in: &cancellables)

        store.$privilegedControlStatus
            .filter(\.isEnabled)
            .sink { [weak self] _ in
                self?.presentation.dismissPrivilegedAccessOnboarding()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(
        systemCPU: SystemCPUSnapshot,
        isEnabled: Bool,
        preferences: AppPreferences
    ) {
        guard !menuDismissalGate.isTracking else { return }
        guard let button = statusItem.button else { return }
        let state = StatusItemState(
            systemCPU: systemCPU,
            isEnabled: isEnabled,
            preferences: preferences
        )
        guard renderedStatusItemState != state else { return }
        renderedStatusItemState = state
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: "Tempra"
        )?.withSymbolConfiguration(configuration)
        button.image?.isTemplate = true
        button.title = state.title
        button.toolTip = state.toolTip
    }

    @objc private func toggleMainPanel() {
        if highCPUAlertPanel?.isVisible == true {
            store.dismissHighCPUAlert()
            showMainPanel()
        } else if mainPanel?.isVisible == true {
            closePanels()
        } else {
            showMainPanel()
        }
    }

    private func showMainPanel() {
        store.setPresentationActive(true)
        let mainPanel = ensureMainPanel()
        positionMainPanel(mainPanel)
        installEventMonitors()
        NSApp.activate(ignoringOtherApps: true)
        mainPanel.orderFrontRegardless()
        mainPanel.makeKey()
        statusItem.button?.highlight(true)
    }

    private func showSettingsPanel() {
        closePanels()
        let settingsPanel = ensureSettingsPanel()
        if !settingsPanel.isVisible {
            settingsPanel.center()
        }
        installEventMonitors()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel.makeKeyAndOrderFront(nil)
    }

    private func updateHighCPUAlertPanel(for alert: HighCPUAlert?) {
        guard alert != nil else {
            highCPUAlertPanel?.close()
            highCPUAlertPanel?.contentViewController = nil
            highCPUAlertPanel = nil
            removeEventMonitorsIfIdle()
            if mainPanel?.isVisible != true {
                statusItem.button?.highlight(false)
            }
            return
        }

        closePanels()
        let highCPUAlertPanel = ensureHighCPUAlertPanel()
        positionHighCPUAlertPanel(highCPUAlertPanel)
        installEventMonitors()
        NSApp.activate(ignoringOtherApps: true)
        highCPUAlertPanel.orderFrontRegardless()
        highCPUAlertPanel.makeKey()
        statusItem.button?.highlight(true)
    }

    private func positionMainPanel(_ mainPanel: TempraPanel) {
        guard let buttonFrame = statusButtonFrame() else { return }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = TempraLayout.mainPanelSize
        let idealX = buttonFrame.midX - size.width / 2
        let x = min(max(idealX, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        let y = buttonFrame.minY - size.height + 2
        mainPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func positionHighCPUAlertPanel(_ highCPUAlertPanel: TempraPanel) {
        guard let buttonFrame = statusButtonFrame() else { return }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = TempraLayout.highCPUAlertPanelSize
        let idealX = buttonFrame.midX - size.width / 2
        let x = min(max(idealX, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        let y = buttonFrame.minY - size.height + 2
        highCPUAlertPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func updateInspector(for selection: MenuPanelSelection?) {
        guard let mainPanel, mainPanel.isVisible, let selection else {
            inspectorPanel?.close()
            inspectorPanel?.contentViewController = nil
            inspectorPanel = nil
            return
        }

        let inspectorPanel = ensureInspectorPanel()
        let size = TempraLayout.inspectorSize
        let visibleFrame = mainPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let targetScreenY = mainPanel.frame.maxY - selection.localMidY
        let idealY = targetScreenY - size.height / 2
        let y = min(max(idealY, visibleFrame.minY + 6), visibleFrame.maxY - size.height - 6)
        let x = mainPanel.frame.minX - size.width + 2

        inspectorPanel.setFrameOrigin(CGPoint(x: x, y: y))
        inspectorPanel.orderFrontRegardless()
    }

    private func statusButtonFrame() -> CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func installEventMonitors() {
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }

                if event.type == .keyDown, event.keyCode == 53 {
                    if self.settingsPanel?.isKeyWindow == true {
                        self.settingsPanel?.performClose(nil)
                    } else if self.highCPUAlertPanel?.isKeyWindow == true {
                        self.store.dismissHighCPUAlert()
                    } else if self.inspectorPanel?.isVisible == true {
                        self.presentation.closeInspector()
                    } else {
                        self.closePanels()
                    }
                    return nil
                }

                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.dismissIfNeeded(at: NSEvent.mouseLocation)
                }
                return event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismissIfNeeded(at: NSEvent.mouseLocation)
                }
            }
        }
    }

    private func removeEventMonitorsIfIdle() {
        guard mainPanel?.isVisible != true,
              highCPUAlertPanel?.isVisible != true,
              settingsPanel?.isVisible != true else { return }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func dismissIfNeeded(at point: CGPoint) {
        guard menuDismissalGate.allowsDismissal() else { return }

        if let highCPUAlertPanel, highCPUAlertPanel.isVisible,
           !highCPUAlertPanel.frame.contains(point),
           statusButtonFrame()?.contains(point) != true {
            store.dismissHighCPUAlert()
        }

        guard let mainPanel, mainPanel.isVisible else { return }
        if mainPanel.frame.contains(point)
            || inspectorPanel?.frame.contains(point) == true {
            return
        }
        if statusButtonFrame()?.contains(point) == true {
            return
        }
        closePanels()
    }

    private func installMenuTrackingObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        menuDismissalGate.beginTracking()
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        menuDismissalGate.endTracking()
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let nsAppearance = appearance.nsAppearance
        mainPanel?.appearance = nsAppearance
        inspectorPanel?.appearance = nsAppearance
        highCPUAlertPanel?.appearance = nsAppearance
        settingsPanel?.appearance = nsAppearance
        settingsPanel?.backgroundColor = .windowBackgroundColor
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === settingsPanel else { return }
        settingsPanel?.contentViewController = nil
        settingsPanel = nil
        removeEventMonitorsIfIdle()
    }
}

private final class TempraPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct InspectorPanelRoot: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: MenuPanelPresentation

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let selection = presentation.selection,
                   let item = store.item(bundleIdentifier: selection.bundleIdentifier) {
                    Group {
                        switch selection.inspector {
                        case .rule:
                            RuleEditorView(
                                item: item,
                                store: store,
                                onClose: presentation.closeInspector
                            )
                        case .activity:
                            ActivityInspectorView(
                                item: item,
                                store: store,
                                onClose: presentation.closeInspector
                            )
                        }
                    }
                    .id("\(selection.bundleIdentifier):\(selection.inspector)")
                } else {
                    Color.clear
                }
            }
            .frame(width: TempraLayout.inspectorBodyWidth)

            Color.clear
                .frame(width: TempraLayout.inspectorNotchWidth)
        }
        .frame(
            width: TempraLayout.inspectorSize.width,
            height: TempraLayout.inspectorSize.height
        )
        .tempraPanelSurface(InspectorPanelShape())
        .tempraAppearance(store.preferences.appearance)
    }
}

private struct HighCPUAlertPanelRoot: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: MenuPanelPresentation

    var body: some View {
        Group {
            if let alert = store.pendingHighCPUAlert {
                HighCPUAlertView(
                    alert: alert,
                    onContinue: store.dismissHighCPUAlert,
                    onLimit: store.limitPendingHighCPUAlert,
                    onIgnore: {
                        store.ignoreHighCPUAlerts(for: alert.bundleIdentifier)
                    },
                    onShowSettings: {
                        store.dismissHighCPUAlert()
                        presentation.showSettings(section: .detection)
                    }
                )
                .id(alert.id)
            } else {
                Color.clear
            }
        }
        .frame(
            width: TempraLayout.highCPUAlertPanelSize.width,
            height: TempraLayout.highCPUAlertPanelSize.height
        )
        .tempraAppearance(store.preferences.appearance)
    }
}
