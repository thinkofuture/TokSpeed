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
}

final class SettingsWindowController: NSWindowController {
    let sourcePopup = NSPopUpButton()
    let displayPopup = NSPopUpButton()
    private(set) var state: SettingsState?
    var onSource: ((SourceMode) -> Void)?
    var onDisplay: ((StatusDisplay) -> Void)?

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
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

        let root = window.contentView!
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ next: SettingsState) {
        guard state != next else { return }
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
    }

    @objc private func changeSource(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let source = SourceMode(rawValue: raw) else { return }
        onSource?(source)
    }

    @objc private func changeDisplay(_ sender: NSPopUpButton) {
        guard StatusDisplay.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onDisplay?(StatusDisplay.allCases[sender.indexOfSelectedItem])
    }

}
