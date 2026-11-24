import AppKit

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct SettingsState: Equatable {
    var sources: [SourceMode]
    var visibleSources: [SourceMode]
    var hiddenSources: Set<SourceMode> = []
    var source: SourceMode
    var display: StatusDisplay
    var layout: PanelLayout = .chart
    var launchAtLogin: Bool = false
    var launchAtLoginAvailable: Bool = false
    var cursorInstalled: Bool = false
    var cursorHookStatus: CursorHookInstaller.HookStatus = .notInstalled
    var hermesInstalled: Bool = false
    var hermesPluginStatus: HermesPluginInstaller.PluginStatus = .notInstalled
    var versionText: String = ""

    init(sources: [SourceMode],
         visibleSources: [SourceMode]? = nil,
         hiddenSources: Set<SourceMode> = [],
         source: SourceMode,
         display: StatusDisplay,
         layout: PanelLayout = .chart,
         launchAtLogin: Bool = false,
         launchAtLoginAvailable: Bool = false,
         cursorInstalled: Bool = false,
         cursorHookStatus: CursorHookInstaller.HookStatus = .notInstalled,
         hermesInstalled: Bool = false,
         hermesPluginStatus: HermesPluginInstaller.PluginStatus = .notInstalled,
         versionText: String = "") {
        self.sources = sources
        self.visibleSources = visibleSources ?? sources.filter { !hiddenSources.contains($0) }
        self.hiddenSources = hiddenSources
        self.source = source
        self.display = display
        self.layout = layout
        self.launchAtLogin = launchAtLogin
        self.launchAtLoginAvailable = launchAtLoginAvailable
        self.cursorInstalled = cursorInstalled
        self.cursorHookStatus = cursorHookStatus
        self.hermesInstalled = hermesInstalled
        self.hermesPluginStatus = hermesPluginStatus
        self.versionText = versionText
    }
}

final class SettingsWindowController: NSWindowController {
    let sourcePopup = NSPopUpButton()
    let displayPopup = NSPopUpButton()
    let layoutPopup = NSPopUpButton()
    let launchAtLoginCheckbox = NSButton(checkboxWithTitle: L10n.text("Launch at login"), target: nil, action: nil)
    let resetOrderButton = NSButton(title: L10n.text("Reset order"), target: nil, action: nil)
    let cursorStatusLabel = NSTextField(labelWithString: "")
    let cursorActionButton = NSButton(title: L10n.text("Enable"), target: nil, action: nil)
    let hermesStatusLabel = NSTextField(labelWithString: "")
    let hermesHintLabel = NSTextField(labelWithString: "")
    let hermesActionButton = NSButton(title: L10n.text("Install"), target: nil, action: nil)
    let hermesRemoveButton = NSButton(title: L10n.text("Remove"), target: nil, action: nil)
    let diagnosticsButton = NSButton(title: L10n.text("Diagnostics…"), target: nil, action: nil)
    let versionLabel = NSTextField(labelWithString: "")
    let generalGrid: NSGridView
    private(set) var toolCheckboxes: [SourceMode: NSButton] = [:]

    private let toolsSection = NSStackView()
    private let toolsCheckboxesContainer = NSGridView()
    private let toolsSeparator = NSBox()
    private let integrationsSeparator = NSBox()
    private let integrationsSection = NSStackView()
    private let cursorRow = NSStackView()
    private let hermesRowContainer = NSStackView()
    private let hermesRow = NSStackView()
    private let rootStack = NSStackView()

    private(set) var state: SettingsState?
    var onSource: ((SourceMode) -> Void)?
    var onDisplay: ((StatusDisplay) -> Void)?
    var onLayout: ((PanelLayout) -> Void)?
    var onLaunchAtLogin: ((Bool) -> Void)?
    var onToggleTool: ((SourceMode, Bool) -> Void)?
    var onResetOrder: (() -> Void)?
    var onCursorHookAction: (() -> Void)?
    var onHermesPluginAction: (() -> Void)?
    var onHermesPluginRemove: (() -> Void)?
    var onShowDiagnostics: (() -> Void)?

    init() {
        let sourceLabel = NSTextField(labelWithString: L10n.text("Source") + ":")
        let displayLabel = NSTextField(labelWithString: L10n.text("Display") + ":")
        let layoutLabel = NSTextField(labelWithString: L10n.text("Panel view") + ":")
        generalGrid = NSGridView(views: [[sourceLabel, sourcePopup], [displayLabel, displayPopup], [layoutLabel, layoutPopup]])

        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("Settings")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        sourcePopup.target = self
        sourcePopup.action = #selector(changeSource(_:))
        sourcePopup.setAccessibilityLabel(L10n.text("Source"))
        displayPopup.target = self
        displayPopup.action = #selector(changeDisplay(_:))
        displayPopup.setAccessibilityLabel(L10n.text("Display"))
        layoutPopup.target = self
        layoutPopup.action = #selector(changeLayout(_:))
        layoutPopup.setAccessibilityLabel(L10n.text("Panel view"))

        generalGrid.rowSpacing = 12
        generalGrid.columnSpacing = 14
        generalGrid.column(at: 0).xPlacement = .trailing
        generalGrid.column(at: 0).width = max(92, layoutLabel.intrinsicContentSize.width)
        generalGrid.column(at: 1).xPlacement = .fill
        generalGrid.rowAlignment = .firstBaseline
        sourceLabel.setContentHuggingPriority(.required, for: .horizontal)
        displayLabel.setContentHuggingPriority(.required, for: .horizontal)
        layoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin(_:))
        let loginRow = NSStackView(views: [NSView(), launchAtLoginCheckbox])
        loginRow.orientation = .horizontal
        loginRow.alignment = .centerY
        loginRow.views.first?.widthAnchor.constraint(equalToConstant: generalGrid.column(at: 0).width + generalGrid.columnSpacing).isActive = true

        toolsSeparator.boxType = .separator
        integrationsSeparator.boxType = .separator

        let toolsHeaderLabel = NSTextField(labelWithString: L10n.text("Tools") + ":")
        toolsHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toolsHeaderLabel.textColor = .secondaryLabelColor
        resetOrderButton.bezelStyle = .rounded
        resetOrderButton.controlSize = .small
        resetOrderButton.target = self
        resetOrderButton.action = #selector(resetOrderClicked(_:))
        let toolsHeader = NSStackView(views: [toolsHeaderLabel, NSView(), resetOrderButton])
        toolsHeader.orientation = .horizontal
        toolsHeader.alignment = .centerY

        toolsCheckboxesContainer.rowSpacing = 8
        toolsCheckboxesContainer.columnSpacing = 16

        toolsSection.orientation = .vertical
        toolsSection.alignment = .leading
        toolsSection.spacing = 10
        toolsSection.addArrangedSubview(toolsHeader)
        toolsSection.addArrangedSubview(toolsCheckboxesContainer)
        toolsHeader.widthAnchor.constraint(equalTo: toolsSection.widthAnchor).isActive = true

        let integrationsHeaderLabel = NSTextField(labelWithString: L10n.text("Integrations") + ":")
        integrationsHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        integrationsHeaderLabel.textColor = .secondaryLabelColor

        let cursorTitle = NSTextField(labelWithString: L10n.text("Cursor hook") + ":")
        cursorTitle.setContentHuggingPriority(.required, for: .horizontal)
        cursorStatusLabel.textColor = .secondaryLabelColor
        cursorStatusLabel.lineBreakMode = .byTruncatingTail
        cursorActionButton.bezelStyle = .rounded
        cursorActionButton.controlSize = .small
        cursorActionButton.target = self
        cursorActionButton.action = #selector(cursorActionClicked(_:))
        cursorRow.orientation = .horizontal
        cursorRow.alignment = .centerY
        cursorRow.spacing = 8
        cursorRow.setViews([cursorTitle, cursorStatusLabel, NSView(), cursorActionButton], in: .leading)

        let hermesTitle = NSTextField(labelWithString: L10n.text("Hermes plugin") + ":")
        hermesTitle.setContentHuggingPriority(.required, for: .horizontal)
        hermesStatusLabel.textColor = .secondaryLabelColor
        hermesStatusLabel.lineBreakMode = .byTruncatingTail
        hermesActionButton.bezelStyle = .rounded
        hermesActionButton.controlSize = .small
        hermesActionButton.target = self
        hermesActionButton.action = #selector(hermesActionClicked(_:))
        hermesRemoveButton.bezelStyle = .rounded
        hermesRemoveButton.controlSize = .small
        hermesRemoveButton.target = self
        hermesRemoveButton.action = #selector(hermesRemoveClicked(_:))
        hermesRow.orientation = .horizontal
        hermesRow.alignment = .centerY
        hermesRow.spacing = 8
        hermesRow.setViews([hermesTitle, hermesStatusLabel, NSView(), hermesActionButton, hermesRemoveButton], in: .leading)

        hermesHintLabel.font = .systemFont(ofSize: 11)
        hermesHintLabel.textColor = .secondaryLabelColor
        hermesHintLabel.isSelectable = true
        hermesHintLabel.lineBreakMode = .byTruncatingMiddle

        hermesRowContainer.orientation = .vertical
        hermesRowContainer.alignment = .leading
        hermesRowContainer.spacing = 4
        hermesRowContainer.addArrangedSubview(hermesRow)
        hermesRowContainer.addArrangedSubview(hermesHintLabel)
        hermesRow.widthAnchor.constraint(equalTo: hermesRowContainer.widthAnchor).isActive = true

        integrationsSection.orientation = .vertical
        integrationsSection.alignment = .leading
        integrationsSection.spacing = 10
        integrationsSection.addArrangedSubview(integrationsHeaderLabel)
        integrationsSection.addArrangedSubview(cursorRow)
        integrationsSection.addArrangedSubview(hermesRowContainer)
        cursorRow.widthAnchor.constraint(equalTo: integrationsSection.widthAnchor).isActive = true
        hermesRowContainer.widthAnchor.constraint(equalTo: integrationsSection.widthAnchor).isActive = true

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        diagnosticsButton.bezelStyle = .rounded
        diagnosticsButton.controlSize = .small
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(diagnosticsClicked(_:))
        let footerRow = NSStackView(views: [versionLabel, NSView(), diagnosticsButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        for item in [generalGrid, loginRow, toolsSeparator, toolsSection, integrationsSeparator, integrationsSection, footerSeparator, footerRow] {
            rootStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        let root = window.contentView!
        root.addSubview(rootStack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            rootStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ next: SettingsState) {
        let oldSources = state?.sources
        guard state != next else { return }
        state = next

        sourcePopup.removeAllItems()
        let selectableSources = [SourceMode.auto] + next.visibleSources
        for source in selectableSources {
            sourcePopup.addItem(withTitle: source.label)
            sourcePopup.lastItem?.representedObject = source.rawValue
            sourcePopup.lastItem?.image = ProviderLogo.image(source)
        }
        sourcePopup.selectItem(at: selectableSources.firstIndex(of: next.source) ?? 0)

        displayPopup.removeAllItems()
        displayPopup.addItems(withTitles: StatusDisplay.allCases.map(\.label))
        displayPopup.selectItem(at: StatusDisplay.allCases.firstIndex(of: next.display) ?? 0)

        layoutPopup.removeAllItems()
        layoutPopup.addItems(withTitles: PanelLayout.allCases.map(\.label))
        layoutPopup.selectItem(at: PanelLayout.allCases.firstIndex(of: next.layout) ?? 0)

        launchAtLoginCheckbox.state = next.launchAtLogin ? .on : .off
        launchAtLoginCheckbox.isEnabled = next.launchAtLoginAvailable
        launchAtLoginCheckbox.toolTip = next.launchAtLoginAvailable
            ? nil
            : L10n.text("Install TokSpeed.app to enable Launch at login.")

        if oldSources != next.sources {
            rebuildToolCheckboxes(sources: next.sources)
        }
        for (source, checkbox) in toolCheckboxes {
            checkbox.state = next.hiddenSources.contains(source) ? .off : .on
        }
        let hasTools = !next.sources.isEmpty
        toolsSeparator.isHidden = !hasTools
        toolsSection.isHidden = !hasTools
        resetOrderButton.isEnabled = next.sources.count > 1

        let showCursor = next.cursorInstalled || next.cursorHookStatus != .notInstalled
        let showHermes = next.hermesInstalled || next.hermesPluginStatus != .notInstalled
        cursorRow.isHidden = !showCursor
        hermesRowContainer.isHidden = !showHermes
        integrationsSeparator.isHidden = !showCursor && !showHermes
        integrationsSection.isHidden = !showCursor && !showHermes

        if showCursor { updateCursorRow(next.cursorHookStatus) }
        if showHermes { updateHermesRow(next.hermesPluginStatus) }

        versionLabel.stringValue = next.versionText.isEmpty
            ? L10n.text("Local logs only · no network")
            : L10n.text("%@ · %@", next.versionText, L10n.text("Local logs only · no network"))

        window?.layoutIfNeeded()
    }

    private func rebuildToolCheckboxes(sources: [SourceMode]) {
        while toolsCheckboxesContainer.numberOfRows > 0 {
            toolsCheckboxesContainer.removeRow(at: 0)
        }
        toolCheckboxes.removeAll()
        let columns = 3
        var rowViews: [NSView] = []
        for source in sources {
            let button = NSButton(checkboxWithTitle: source.label, target: self, action: #selector(toggleTool(_:)))
            button.tag = ToolOrder.popular.firstIndex(of: source) ?? -1
            button.setAccessibilityLabel(source.label)
            toolCheckboxes[source] = button
            rowViews.append(button)
            if rowViews.count == columns {
                toolsCheckboxesContainer.addRow(with: rowViews)
                rowViews.removeAll()
            }
        }
        if !rowViews.isEmpty {
            while rowViews.count < columns { rowViews.append(NSView()) }
            toolsCheckboxesContainer.addRow(with: rowViews)
        }
        for index in 0..<toolsCheckboxesContainer.numberOfColumns {
            let column = toolsCheckboxesContainer.column(at: index)
            column.width = 132
            column.xPlacement = .leading
        }
    }

    private func updateCursorRow(_ status: CursorHookInstaller.HookStatus) {
        cursorStatusLabel.toolTip = nil
        switch status {
        case .notInstalled:
            cursorStatusLabel.stringValue = L10n.text("Not installed")
            cursorActionButton.title = L10n.text("Enable")
            cursorActionButton.isEnabled = true
        case .installed:
            cursorStatusLabel.stringValue = L10n.text("Enabled")
            cursorActionButton.title = L10n.text("Remove")
            cursorActionButton.isEnabled = true
        case .outdatedPath:
            cursorStatusLabel.stringValue = L10n.text("Update needed")
            cursorActionButton.title = L10n.text("Update")
            cursorActionButton.isEnabled = true
        case .error(let message):
            cursorStatusLabel.stringValue = L10n.text("Error")
            cursorStatusLabel.toolTip = message
            cursorActionButton.title = L10n.text("Enable")
            cursorActionButton.isEnabled = true
        }
    }

    private func updateHermesRow(_ status: HermesPluginInstaller.PluginStatus) {
        hermesStatusLabel.toolTip = nil
        switch status {
        case .notInstalled:
            hermesStatusLabel.stringValue = L10n.text("Not installed")
            hermesActionButton.title = L10n.text("Install")
            hermesActionButton.isHidden = false
            hermesActionButton.isEnabled = true
            hermesRemoveButton.isHidden = true
            hermesHintLabel.isHidden = true
        case .installed:
            hermesStatusLabel.stringValue = L10n.text("Installed")
            hermesActionButton.isHidden = true
            hermesRemoveButton.isHidden = false
            hermesHintLabel.stringValue = L10n.text("Enable in Hermes: %@", "hermes plugins enable \(HermesReader.pluginName)")
            hermesHintLabel.isHidden = false
        case .outdated:
            hermesStatusLabel.stringValue = L10n.text("Update available")
            hermesActionButton.title = L10n.text("Update")
            hermesActionButton.isHidden = false
            hermesActionButton.isEnabled = true
            hermesRemoveButton.isHidden = false
            hermesHintLabel.isHidden = true
        case .conflict(let path):
            hermesStatusLabel.stringValue = L10n.text("Conflict")
            hermesStatusLabel.toolTip = path
            hermesActionButton.isHidden = true
            hermesRemoveButton.isHidden = true
            hermesHintLabel.isHidden = true
        case .missingResources:
            hermesStatusLabel.stringValue = L10n.text("Error")
            hermesActionButton.isHidden = true
            hermesRemoveButton.isHidden = true
            hermesHintLabel.isHidden = true
        }
    }

    @objc private func changeSource(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let source = SourceMode(rawValue: raw) else { return }
        onSource?(source)
    }

    @objc private func changeDisplay(_ sender: NSPopUpButton) {
        guard StatusDisplay.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onDisplay?(StatusDisplay.allCases[sender.indexOfSelectedItem])
    }

    @objc private func changeLayout(_ sender: NSPopUpButton) {
        guard PanelLayout.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onLayout?(PanelLayout.allCases[sender.indexOfSelectedItem])
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        onLaunchAtLogin?(sender.state == .on)
    }

    @objc private func toggleTool(_ sender: NSButton) {
        guard ToolOrder.popular.indices.contains(sender.tag) else { return }
        onToggleTool?(ToolOrder.popular[sender.tag], sender.state == .on)
    }

    @objc private func resetOrderClicked(_ sender: NSButton) {
        onResetOrder?()
    }

    @objc private func cursorActionClicked(_ sender: NSButton) {
        onCursorHookAction?()
    }

    @objc private func hermesActionClicked(_ sender: NSButton) {
        onHermesPluginAction?()
    }

    @objc private func hermesRemoveClicked(_ sender: NSButton) {
        onHermesPluginRemove?()
    }

    @objc private func diagnosticsClicked(_ sender: NSButton) {
        onShowDiagnostics?()
    }
}
