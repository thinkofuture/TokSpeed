import AppKit

struct AppSnapshot {
    var installedSources: Set<SourceMode>
    var snapshots: [SourceMode: SourceSnapshot]
    var cursorHookStatus: CursorHookInstaller.HookStatus
    var hermesPluginStatus: HermesPluginInstaller.PluginStatus
    var capturedAt: Date

    static func empty(installedSources: Set<SourceMode> = []) -> AppSnapshot {
        AppSnapshot(
            installedSources: installedSources,
            snapshots: [:],
            cursorHookStatus: .notInstalled,
            hermesPluginStatus: .notInstalled,
            capturedAt: .distantPast
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct StatusRenderKey: Equatable {
        let source: SourceMode
        let active: Bool
        let display: StatusDisplay
        let title: String
        let toolTip: String
    }

    private let defaults: UserDefaults
    private let detectInstalledTools: () -> Set<SourceMode>
    private let pollQueue = DispatchQueue(label: "io.github.thinkofuture.tokspeed.poll", qos: .utility)

    // Readers and poll timestamps are mutated exclusively on `pollQueue`.
    private let readers: [SourceMode: any SpeedSourceReader] = [
        .codex: CodexMultiReader(),
        .opencode: OpenCodeReader(),
        .claude: ClaudeReader(),
        .antigravity: AntigravityReader(),
        .hermes: HermesReader(),
        .cursor: CursorReader()
    ]
    private var lastInstalledScan = Date.distantPast
    private var lastSlowPoll = Date.distantPast
    private var lastOpenCodePoll = Date.distantPast
    private var cachedInstalledSources: Set<SourceMode>
    private var cachedCursorHookStatus: CursorHookInstaller.HookStatus = .notInstalled
    private var cachedHermesPluginStatus: HermesPluginInstaller.PluginStatus = .notInstalled

    // Main-thread state.
    private(set) var latestSnapshot: AppSnapshot
    private var installedSources: Set<SourceMode>
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var sleepObservers: [NSObjectProtocol] = []
    private var isPolling = false
    private var pendingForceScan = false
    private var isSleeping = false
    private var isMenuOpen = false
    private var isReordering = false
    private var lastStatusKey: StatusRenderKey?
    private var lastStatusSymbol: String?
    var selftest = false
    var currentSymbol = "-"
    private weak var speedPanel: SpeedPanelView?
    private weak var panelMenuItem: NSMenuItem?
    private var settingsController: SettingsWindowController?
    private var launchAtLoginOverride: Bool?

    var settingsState: SettingsState {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .map { L10n.text("Version %@", $0) } ?? ""
        return SettingsState(
            sources: installedToolOrder,
            visibleSources: toolOrder,
            hiddenSources: hiddenSources,
            source: effectiveMode,
            display: display,
            layout: panelLayout,
            launchAtLogin: launchAtLoginOverride ?? LaunchAtLogin.isEnabled,
            launchAtLoginAvailable: LaunchAtLogin.isAvailable,
            cursorInstalled: installedSources.contains(.cursor),
            cursorHookStatus: latestSnapshot.cursorHookStatus,
            hermesInstalled: installedSources.contains(.hermes),
            hermesPluginStatus: latestSnapshot.hermesPluginStatus,
            versionText: version
        )
    }

    init(defaults: UserDefaults = .standard,
         detectInstalledTools: (() -> Set<SourceMode>)? = nil) {
        self.defaults = defaults
        self.detectInstalledTools = detectInstalledTools ?? { InstalledTools.detect() }
        let initialInstalled = detectInstalledTools?() ?? []
        self.cachedInstalledSources = initialInstalled
        self.installedSources = initialInstalled
        self.latestSnapshot = .empty(installedSources: initialInstalled)
        super.init()
    }

    deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
    }

    var mode: SourceMode {
        get { SourceMode(rawValue: defaults.string(forKey: "sourceMode") ?? "auto") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "sourceMode") }
    }

    var display: StatusDisplay {
        get { StatusDisplay(rawValue: defaults.string(forKey: "statusDisplay") ?? "") ?? .speedAndUnit }
        set { defaults.set(newValue.rawValue, forKey: "statusDisplay") }
    }

    var panelLayout: PanelLayout {
        get { PanelLayout(rawValue: defaults.string(forKey: "panelLayout") ?? "") ?? .chart }
        set { defaults.set(newValue.rawValue, forKey: "panelLayout") }
    }

    var hiddenSources: Set<SourceMode> {
        get {
            let saved = defaults.stringArray(forKey: "hiddenSources") ?? []
            return Set(saved.compactMap(SourceMode.init(rawValue:)).filter { $0 != .auto })
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: "hiddenSources")
        }
    }

    var savedToolOrder: [SourceMode] {
        ToolOrder.normalized(defaults.stringArray(forKey: "toolOrder") ?? [])
    }

    var installedToolOrder: [SourceMode] {
        savedToolOrder.filter { installedSources.contains($0) }
    }

    var toolOrder: [SourceMode] {
        savedToolOrder.filter { installedSources.contains($0) && !hiddenSources.contains($0) }
    }

    var effectiveMode: SourceMode {
        toolOrder.contains(mode) ? mode : .auto
    }

    static func preferredSource(mode: SourceMode, activity: [(source: SourceMode, active: Bool, date: Date)]) -> SourceMode {
        guard mode == .auto else { return mode }
        let active = activity.filter(\.active)
        return (active.isEmpty ? activity : active).max { $0.date < $1.date }?.source ?? .auto
    }

    var activeSource: SourceMode {
        let visible = Set(toolOrder)
        let activity: [(source: SourceMode, active: Bool, date: Date)] = ToolOrder.popular.filter { visible.contains($0) }.map { source in
            if let snap = latestSnapshot.snapshots[source] {
                return (source, snap.inFlightStart != nil, snap.activityDate)
            }
            return (source, false, .distantPast)
        }
        return Self.preferredSource(mode: effectiveMode, activity: activity)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerPowerObservers()
        startTimer()
        scheduleRefresh(forceScan: true)

        if selftest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.report() }
        }
    }

    private func registerPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        for name in sleepNames {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleSleep()
            })
        }
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in wakeNames {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            })
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let scheduled = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        scheduled.tolerance = 0.25
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    func handleSleep() {
        isSleeping = true
        timer?.invalidate()
        timer = nil
    }

    func handleWake() {
        isSleeping = false
        startTimer()
        scheduleRefresh(forceScan: true)
    }

    private func tick() {
        guard !isSleeping else { return }
        scheduleRefresh(forceScan: false)
        // Update elapsed seconds smoothly even while waiting for a poll cycle.
        updateTitle()
    }

    func scheduleRefresh(forceScan: Bool = false) {
        if isPolling {
            if forceScan { pendingForceScan = true }
            return
        }
        isPolling = true
        let shouldForce = forceScan || pendingForceScan
        pendingForceScan = false
        pollQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.collectSnapshot(forceScan: shouldForce, now: Date())
            DispatchQueue.main.async {
                self.isPolling = false
                self.applySnapshot(snapshot)
                if self.pendingForceScan && !self.isSleeping {
                    self.scheduleRefresh(forceScan: true)
                }
            }
        }
    }

    private func collectSnapshot(forceScan: Bool, now: Date) -> AppSnapshot {
        if forceScan || now.timeIntervalSince(lastInstalledScan) >= 30 {
            lastInstalledScan = now
            cachedInstalledSources = detectInstalledTools()
        }
        let installed = cachedInstalledSources
        let slowDue = forceScan || now.timeIntervalSince(lastSlowPoll) >= 5
        let openCodeDue = forceScan || now.timeIntervalSince(lastOpenCodePoll) >= 2
        if slowDue { lastSlowPoll = now }
        if openCodeDue { lastOpenCodePoll = now }

        var snapshots: [SourceMode: SourceSnapshot] = [:]
        for source in ToolOrder.popular where installed.contains(source) {
            guard let reader = readers[source] else { continue }
            switch source {
            case .codex:
                reader.poll(forceScan: forceScan, now: now)
            case .antigravity, .cursor:
                reader.poll(forceScan: forceScan, now: now)
            case .opencode:
                if openCodeDue { reader.poll(forceScan: forceScan, now: now) }
            case .claude:
                if slowDue || (openCodeDue && reader.snapshot(now: now).inFlightStart != nil) {
                    reader.poll(forceScan: forceScan, now: now)
                }
            case .hermes:
                if openCodeDue { reader.poll(forceScan: forceScan, now: now) }
            case .auto:
                break
            }
            snapshots[source] = reader.snapshot(now: now)
        }

        if slowDue {
            cachedCursorHookStatus = CursorHookInstaller.status()
            cachedHermesPluginStatus = HermesPluginInstaller.status()
        }

        return AppSnapshot(
            installedSources: installed,
            snapshots: snapshots,
            cursorHookStatus: cachedCursorHookStatus,
            hermesPluginStatus: cachedHermesPluginStatus,
            capturedAt: now
        )
    }

    func applySnapshot(_ snapshot: AppSnapshot) {
        let oldVisible = toolOrder
        latestSnapshot = snapshot
        installedSources = snapshot.installedSources
        if isMenuOpen && !isReordering && oldVisible != toolOrder, let menu = statusItem?.menu {
            rebuildMenu(menu)
        }
        updateTitle(now: Date())
        if isMenuOpen && !isReordering {
            updateSpeedPanel()
        }
        settingsController?.update(settingsState)
    }

    private func report() {
        let button = statusItem.button
        let snaps = latestSnapshot.snapshots
        print("selftest: visible=\(statusItem.isVisible)")
        print("selftest: title=\(button?.title ?? "<nil>") icon=\(currentSymbol)")
        print("selftest: source=\(activeSource.label)")
        for source in ToolOrder.popular {
            let snap = snaps[source]
            let count = snap?.diagnostic.sampleCount ?? 0
            let last = snap?.summary.last.map { Fmt.tps($0) } ?? "-"
            let live = snap?.liveSpeed.map { Fmt.tps($0) } ?? "-"
            print("selftest: \(source.rawValue)=\(count) last=\(last) live=\(live) active=\(snap?.inFlightStart != nil)")
        }
        if let menu = statusItem.menu {
            menuWillOpen(menu)
            for source in ToolOrder.popular {
                let summary = speedPanel?.cards.first { $0.source == source }?.summary
                print("selftest: menu \(summary.map { "\($0.name) · \($0.caption()) · \($0.value) tok/s" } ?? "missing")")
            }
            menuDidClose(menu)
        }
        NSApp.terminate(nil)
    }

    private var generating: Bool {
        guard activeSource != .auto else { return false }
        return latestSnapshot.snapshots[activeSource]?.inFlightStart != nil
    }

    private func liveSpeed() -> Double? {
        guard activeSource != .auto else { return nil }
        return latestSnapshot.snapshots[activeSource]?.liveSpeed
    }

    private func turnElapsed(now: Date = Date()) -> Double? {
        guard activeSource != .auto,
              let start = latestSnapshot.snapshots[activeSource]?.inFlightStart else { return nil }
        return now.timeIntervalSince(start)
    }

    func updateTitle(now: Date = Date()) {
        renderStatus(source: activeSource, active: generating, speed: liveSpeed(), elapsed: max(0, turnElapsed(now: now) ?? 0))
    }

    func renderStatus(source: SourceMode, active: Bool, speed: Double?, elapsed: Double) {
        guard let button = statusItem?.button else { return }
        let titleText = display.title(active: active, speed: speed, elapsed: elapsed)
        let toolTipText: String
        if source == .auto {
            toolTipText = installedSources.isEmpty
                ? L10n.text("No tools installed")
                : L10n.text("All tools hidden")
        } else if !active {
            toolTipText = L10n.text("%@ is idle. Open the menu for speed history.", source.label)
        } else if source == .antigravity, let valid = StatusDisplay.validSpeed(speed) {
            toolTipText = L10n.text("%@: latest recorded model call, %@ tok/s", source.label, Fmt.tps(valid))
        } else if let valid = StatusDisplay.validSpeed(speed) {
            toolTipText = L10n.text("%@: %@ tok/s this turn (%d s elapsed)", source.label, Fmt.tps(valid), Int(elapsed))
        } else {
            toolTipText = L10n.text("%@ is generating (%d s elapsed)", source.label, Int(elapsed))
        }

        let key = StatusRenderKey(source: source, active: active, display: display, title: titleText, toolTip: toolTipText)
        guard key != lastStatusKey else { return }
        if titleText != lastStatusKey?.title {
            button.attributedTitle = Fmt.statusTitle(titleText)
        }
        if toolTipText != lastStatusKey?.toolTip {
            button.toolTip = toolTipText
            button.setAccessibilityLabel(toolTipText)
        }
        lastStatusKey = key

        let lightning = display.usesLightning(active: active)
        currentSymbol = lightning ? "bolt.fill" : "logo-\(source.rawValue)"
        if currentSymbol != lastStatusSymbol {
            lastStatusSymbol = currentSymbol
            button.image = lightning
                ? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "TokSpeed")
                : ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: source.label)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu(menu)
        scheduleRefresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        speedPanel?.clearHover()
    }

    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let item = header(L10n.text("Recent completed calls"))
        let panel = SpeedPanelView(sources: toolOrder, layout: panelLayout)
        panel.onHeightChange = { [weak menu, weak item] in
            guard let menu, let item else { return }
            menu.itemChanged(item)
        }
        item.view = panel
        menu.addItem(item)
        speedPanel = panel
        panelMenuItem = item
        if toolOrder.isEmpty {
            let emptyKey = installedSources.isEmpty ? "No tools installed" : "All tools hidden"
            menu.addItem(header(L10n.text(emptyKey)))
        }
        configureReordering(in: menu)
        renderPanel(panel)
        let settings = NSMenuItem(title: L10n.text("Settings") + "…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: L10n.text("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        // Keep native menu shortcut dispatch without adding visible text rows.
        for action in [settings, quit] {
            action.isHidden = true
            action.allowsKeyEquivalentWhenHidden = true
            menu.addItem(action)
        }
        let footer = header("")
        footer.view = PanelFooterView(settings: settings, quit: quit, layout: panelLayout)
        menu.addItem(footer)
    }

    func prepareSettings() -> SettingsWindowController {
        if let controller = settingsController {
            controller.update(settingsState)
            return controller
        }
        let controller = SettingsWindowController()
        controller.onSource = { [weak self] source in
            self?.mode = source
            self?.settingsChanged()
        }
        controller.onDisplay = { [weak self] display in
            self?.display = display
            self?.settingsChanged()
        }
        controller.onLayout = { [weak self] layout in
            self?.panelLayout = layout
            self?.settingsChanged()
        }
        controller.onLaunchAtLogin = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        controller.onToggleTool = { [weak self] source, visible in
            self?.setToolVisible(source, visible: visible)
        }
        controller.onResetOrder = { [weak self] in
            self?.resetToolOrder()
        }
        controller.onCursorHookAction = { [weak self] in
            self?.handleCursorHookAction()
        }
        controller.onHermesPluginAction = { [weak self] in
            self?.handleHermesPluginAction()
        }
        controller.onHermesPluginRemove = { [weak self] in
            self?.handleHermesPluginRemove()
        }
        controller.onShowDiagnostics = { [weak self] in
            self?.showDiagnostics()
        }
        settingsController = controller
        controller.update(settingsState)
        return controller
    }

    @objc private func showSettings(_ sender: Any?) {
        scheduleRefresh(forceScan: true)
        let controller = prepareSettings()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    private func settingsChanged() {
        updateTitle()
        updateSpeedPanel()
        settingsController?.update(settingsState)
    }

    func togglePin(_ source: SourceMode) {
        guard toolOrder.contains(source) else { return }
        mode = (mode == source) ? .auto : source
        settingsChanged()
    }

    func setToolVisible(_ source: SourceMode, visible: Bool) {
        var hidden = hiddenSources
        if visible { hidden.remove(source) } else { hidden.insert(source) }
        hiddenSources = hidden
        if isMenuOpen, let menu = statusItem?.menu {
            rebuildMenu(menu)
        }
        settingsChanged()
    }

    func resetToolOrder() {
        defaults.removeObject(forKey: "toolOrder")
        if isMenuOpen, let menu = statusItem?.menu {
            rebuildMenu(menu)
        }
        settingsChanged()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginOverride = LaunchAtLogin.isAvailable ? LaunchAtLogin.isEnabled : enabled
        } catch {
            launchAtLoginOverride = nil
            presentAlert(title: L10n.text("Launch at login"), message: error.localizedDescription)
        }
        settingsController?.update(settingsState)
    }

    private func handleCursorHookAction() {
        let status: CursorHookInstaller.Status
        if latestSnapshot.cursorHookStatus == .installed {
            status = CursorHookInstaller.remove()
        } else {
            status = CursorHookInstaller.install()
        }
        if let error = status.error {
            presentAlert(title: L10n.text("Cursor hook"), message: error)
        }
        latestSnapshot.cursorHookStatus = CursorHookInstaller.status()
        settingsController?.update(settingsState)
        scheduleRefresh(forceScan: true)
    }

    private func handleHermesPluginAction() {
        do {
            _ = try HermesPluginInstaller.install(force: true)
        } catch {
            presentAlert(title: L10n.text("Hermes plugin"), message: error.localizedDescription)
        }
        latestSnapshot.hermesPluginStatus = HermesPluginInstaller.status()
        settingsController?.update(settingsState)
        scheduleRefresh(forceScan: true)
    }

    private func handleHermesPluginRemove() {
        do {
            _ = try HermesPluginInstaller.uninstall()
        } catch {
            presentAlert(title: L10n.text("Hermes plugin"), message: error.localizedDescription)
        }
        latestSnapshot.hermesPluginStatus = HermesPluginInstaller.status()
        settingsController?.update(settingsState)
        scheduleRefresh(forceScan: true)
    }

    private func showDiagnostics() {
        let lines = diagnosticsReportLines()
        let report = lines.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = L10n.text("Diagnostics")
        alert.informativeText = report
        alert.addButton(withTitle: L10n.text("OK"))
        alert.addButton(withTitle: L10n.text("Copy"))
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    func diagnosticsReportLines() -> [String] {
        var lines: [String] = []
        for source in installedToolOrder {
            let hidden = hiddenSources.contains(source) ? " [hidden]" : ""
            if let diag = latestSnapshot.snapshots[source]?.diagnostic {
                lines.append("\(source.label)\(hidden): \(diag.status) (\(diag.sampleCount))")
                lines.append("  \(diag.path)")
            } else {
                lines.append("\(source.label)\(hidden): pending")
            }
        }
        if installedSources.contains(.cursor) || latestSnapshot.cursorHookStatus != .notInstalled {
            lines.append("\(L10n.text("Cursor hook")): \(String(describing: latestSnapshot.cursorHookStatus))")
        }
        if installedSources.contains(.hermes) || latestSnapshot.hermesPluginStatus != .notInstalled {
            lines.append("\(L10n.text("Hermes plugin")): \(String(describing: latestSnapshot.hermesPluginStatus))")
        }
        if lines.isEmpty {
            lines.append(L10n.text("No tools installed"))
        }
        return lines
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    @discardableResult
    func moveTool(_ source: SourceMode, to destination: Int, in menu: NSMenu? = nil) -> Bool {
        let order = ToolOrder.moving(source, to: destination, in: toolOrder)
        guard order != toolOrder else { return false }
        var visible = order.makeIterator()
        let saved = savedToolOrder.map { (installedSources.contains($0) && !hiddenSources.contains($0)) ? visible.next()! : $0 }
        defaults.set(saved.map(\.rawValue), forKey: "toolOrder")
        if let menu, let panel = menu.items.first?.view as? SpeedPanelView {
            // Rebind fixed slots rather than removing/inserting items in an open NSMenu.
            if panel.cards.count == order.count {
                for (card, source) in zip(panel.cards, order) {
                    card.bind(source)
                }
                configureReordering(in: menu)
                renderPanel(panel)
            }
        }
        settingsChanged()
        return true
    }

    private func configureReordering(in menu: NSMenu) {
        guard let panel = menu.items.first?.view as? SpeedPanelView else { return }
        let cards = panel.cards
        let sources = cards.map(\.source)
        for (index, card) in cards.enumerated() {
            card.onClick = { [weak self] clickedSource in
                self?.togglePin(clickedSource)
            }
            card.onDrag = cards.count > 1 ? { [weak self, weak menu, weak panel] card, event in
                guard let self, let menu, let panel else { return }
                MenuCardReorder.track(card, event: event, cards: panel.cards, vertical: panel.layout == .classic,
                    onTrackingChange: { [weak self] active in
                        guard let self else { return }
                        self.isReordering = active
                        guard !active, self.isMenuOpen else { return }
                        if panel.cards.map(\.source) != self.toolOrder {
                            self.rebuildMenu(menu)
                        } else {
                            self.updateSpeedPanel()
                        }
                    },
                    onClick: { [weak self] in
                        self?.togglePin(card.source)
                    },
                    onDrop: { destination in
                        // Installation detection can refresh during tracking. Do not commit a stale list.
                        guard self.toolOrder == sources else { return }
                        self.moveTool(card.source, to: destination, in: menu)
                    })
            } : nil
            var actions: [NSAccessibilityCustomAction] = []
            let labels = panel.layout == .classic ? ("Move up", "Move down") : ("Move left", "Move right")
            for (title, destination) in [(labels.0, index - 1), (labels.1, index + 1)] where cards.indices.contains(destination) {
                actions.append(NSAccessibilityCustomAction(name: L10n.text(title), handler: { [weak self, weak menu, weak card] in
                    guard let self, let menu, let card, self.toolOrder == sources else { return false }
                    return self.moveTool(card.source, to: destination, in: menu)
                }))
            }
            card.setAccessibilityCustomActions(actions)
        }
    }

    func updateSpeedPanel() {
        guard isMenuOpen, !isReordering, let panel = speedPanel else { return }
        renderPanel(panel)
    }

    private func renderPanel(_ panel: SpeedPanelView) {
        guard !panel.cards.isEmpty else { return }
        var summaries: [SourceMode: SpeedSummary] = [:]
        for source in ToolOrder.popular {
            if let snap = latestSnapshot.snapshots[source] {
                summaries[source] = snap.summary
            } else {
                summaries[source] = SpeedSummary(name: source.label, active: false, live: nil, last: nil,
                    completedAt: nil, history: [], model: "", measurement: "")
            }
        }
        panel.update(summaries, pinnedSource: effectiveMode == .auto ? nil : effectiveMode)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Testing hooks for deterministic unit verification without file system races.
    func setStatusItemForTesting(_ item: NSStatusItem) {
        statusItem = item
        lastStatusKey = nil
        lastStatusSymbol = nil
    }
    var testSettingsController: SettingsWindowController? { settingsController }
    var testTimerIsActive: Bool { timer != nil && !isSleeping }
}
