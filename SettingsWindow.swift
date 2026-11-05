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
    var source: SourceMode
    var display: StatusDisplay
    var customOrder: Bool
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let sourcePopup = NSPopUpButton()
    let displayPopup = NSPopUpButton()
    let table = NSTableView()
    let upButton = NSButton()
    let downButton = NSButton()
    let resetButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: L10n.text("No tools installed"))
    private(set) var state: SettingsState?
    var onSource: ((SourceMode) -> Void)?
    var onDisplay: ((StatusDisplay) -> Void)?
    var onMove: ((SourceMode, Int) -> Void)?
    var onReset: (() -> Void)?

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 394),
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
        let sourceLabel = NSTextField(labelWithString: L10n.text("Source") + ":")
        let displayLabel = NSTextField(labelWithString: L10n.text("Display") + ":")
        let grid = NSGridView(views: [[sourceLabel, sourcePopup], [displayLabel, displayPopup]])
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 84
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        sourceLabel.setContentHuggingPriority(.required, for: .horizontal)
        displayLabel.setContentHuggingPriority(.required, for: .horizontal)

        let heading = NSTextField(labelWithString: L10n.text("Tool order"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tool"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.style = .inset
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L10n.text("Tool order"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        scroll.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])

        for (button, symbol, title, offset) in [
            (upButton, "chevron.up", L10n.text("Move up"), -1),
            (downButton, "chevron.down", L10n.text("Move down"), 1)
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(moveTool(_:))
            button.tag = offset
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        resetButton.title = L10n.text("Reset")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetOrder(_:))
        let spacer = NSView()
        let actions = NSStackView(views: [upButton, downButton, spacer, resetButton])
        actions.spacing = 6
        actions.distribution = .fill
        let root = window.contentView!
        for view in [grid, heading, scroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            heading.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            heading.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 28),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 148),
            actions.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ next: SettingsState) {
        guard state != next else { return }
        let selected = state.flatMap { $0.sources.indices.contains(table.selectedRow) ? $0.sources[table.selectedRow] : nil }
        state = next
        sourcePopup.removeAllItems()
        for source in [SourceMode.auto] + next.sources {
            sourcePopup.addItem(withTitle: source.label)
            sourcePopup.lastItem?.representedObject = source.rawValue
            sourcePopup.lastItem?.image = ProviderLogo.image(source)
        }
        sourcePopup.selectItem(at: ([SourceMode.auto] + next.sources).firstIndex(of: next.source) ?? 0)
        displayPopup.removeAllItems()
        displayPopup.addItems(withTitles: StatusDisplay.allCases.map(\.label))
        displayPopup.selectItem(at: StatusDisplay.allCases.firstIndex(of: next.display) ?? 0)
        table.reloadData()
        if let index = selected.flatMap({ next.sources.firstIndex(of: $0) }) ?? next.sources.indices.first {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        emptyLabel.isHidden = !next.sources.isEmpty
        resetButton.isEnabled = next.customOrder
        updateMoveButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { state?.sources.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let sources = state?.sources, sources.indices.contains(row) else { return nil }
        let source = sources[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = ProviderLogo.image(source)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: source.label)
        cell.imageView = icon
        cell.textField = label
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateMoveButtons() }

    private func updateMoveButtons() {
        let row = table.selectedRow
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row + 1 < (state?.sources.count ?? 0)
    }

    @objc private func changeSource(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let source = SourceMode(rawValue: raw) else { return }
        onSource?(source)
    }

    @objc private func changeDisplay(_ sender: NSPopUpButton) {
        guard StatusDisplay.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onDisplay?(StatusDisplay.allCases[sender.indexOfSelectedItem])
    }

    @objc private func moveTool(_ sender: NSButton) {
        guard let sources = state?.sources, sources.indices.contains(table.selectedRow),
              sources.indices.contains(table.selectedRow + sender.tag) else { return }
        onMove?(sources[table.selectedRow], sender.tag)
    }

    @objc private func resetOrder(_ sender: NSButton) { onReset?() }
}
