import AppKit

// Indented sub-row shown under an agent in classic list view when it has >= 2 concurrent sessions.
final class ClassicSessionRowView: NSView {
    static let height: CGFloat = 24
    static let indentX: CGFloat = 26
    let titleLabel = NSTextField(labelWithString: "")
    let speedLabel = NSTextField(labelWithString: "—")
    private var active = false
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.frame = NSRect(x: Self.indentX + 12, y: 4, width: max(0, bounds.width - Self.indentX - 80), height: 16)
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        speedLabel.frame = NSRect(x: max(0, bounds.width - 66), y: 4, width: 66, height: 16)
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        speedLabel.alignment = .right
        speedLabel.lineBreakMode = .byTruncatingTail
        speedLabel.setAccessibilityElement(false)
        addSubview(speedLabel)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        titleLabel.frame = NSRect(x: Self.indentX + 12, y: 4, width: max(0, newSize.width - Self.indentX - 80), height: 16)
        speedLabel.frame = NSRect(x: max(0, newSize.width - 66), y: 4, width: 66, height: 16)
    }

    func update(_ session: SessionSummary, now: Date = Date()) {
        active = session.active
        titleLabel.stringValue = session.title
        speedLabel.stringValue = session.speedText(now: now)
        let speedColor = PanelStyle.color(active: session.active)
        titleLabel.textColor = session.active ? speedColor.withAlphaComponent(0.86) : speedColor
        speedLabel.textColor = speedColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dotRect = NSRect(x: Self.indentX, y: (bounds.height - 5) / 2, width: 5, height: 5)
        let dotColor = PanelStyle.color(active: active)
        dotColor.withAlphaComponent(active ? 0.9 : 0.45).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

// Custom views keep live values aligned without treating summaries as commands.
// Their slots stay fixed while NSMenu tracks; a drop rebinds the sources in place.
final class SummaryMenuView: NSView {
    static let sessionsBottomPadding: CGFloat = 6
    private(set) var source: SourceMode
    let layout: PanelLayout
    var onDrag: ((SummaryMenuView, NSEvent) -> Void)? {
        didSet {
            updateDetailHelp()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var onClick: ((SourceMode) -> Void)?
    var onHoverChange: ((SourceMode, Bool) -> Void)?
    var isPinned = false {
        didSet {
            if oldValue != isPinned { needsDisplay = true }
        }
    }
    var isDragging = false {
        didSet { subviews.forEach { $0.alphaValue = isDragging ? 0.35 : 1 }; needsDisplay = true }
    }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private var measurementDetails: String?
    private let valueLabel = NSTextField(labelWithString: "—")
    private let icon = NSImageView()
    private let classicName: NSTextField?
    private let classicTrend: ClassicTrendView?
    private(set) var sessionRows: [ClassicSessionRowView] = []
    private(set) var displayedSessions: [SessionSummary] = []
    override var allowsVibrancy: Bool { false }

    var preferredHeight: CGFloat {
        guard layout == .classic, !displayedSessions.isEmpty else { return SpeedPanelView.legendHeight }
        return SpeedPanelView.legendHeight + CGFloat(displayedSessions.count) * ClassicSessionRowView.height + Self.sessionsBottomPadding
    }

    init(source: SourceMode, frame: NSRect, layout: PanelLayout = .chart) {
        self.source = source
        self.layout = layout
        classicName = layout == .classic ? NSTextField(labelWithString: source.label) : nil
        classicTrend = layout == .classic ? ClassicTrendView(frame: NSRect(x: 158, y: 14, width: 94, height: 24)) : nil
        super.init(frame: frame)
        icon.frame = NSRect(x: bounds.midX - 9, y: 29, width: 18, height: 18)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        valueLabel.frame = NSRect(x: 2, y: 3, width: bounds.width - 4, height: 22)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setAccessibilityElement(false)
        addSubview(valueLabel)
        if let classicName, let classicTrend {
            classicName.font = .systemFont(ofSize: 13, weight: .medium)
            classicName.lineBreakMode = .byTruncatingTail
            classicName.setAccessibilityElement(false)
            addSubview(classicName)
            addSubview(classicTrend)
            valueLabel.alignment = .right
            layoutClassicSubviews()
        }
        icon.setAccessibilityElement(false)
        bind(source)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if layout == .classic { layoutClassicSubviews() }
    }

    private func layoutClassicSubviews() {
        let topY = bounds.height - SpeedPanelView.legendHeight
        let rowMidY = topY + SpeedPanelView.legendHeight / 2
        icon.frame = NSRect(x: 0, y: round(rowMidY - 9), width: 18, height: 18)
        if let classicName {
            let nameHeight = ceil(classicName.fittingSize.height)
            classicName.frame = NSRect(x: 26, y: round(rowMidY - nameHeight / 2), width: 124, height: nameHeight)
        }
        classicTrend?.frame = NSRect(x: 158, y: round(rowMidY - 12), width: 94, height: 24)
        let valueHeight = ceil(valueLabel.fittingSize.height)
        valueLabel.frame = NSRect(x: 258, y: round(rowMidY - valueHeight / 2), width: bounds.width - 258, height: valueHeight)
        for (index, row) in sessionRows.enumerated() {
            row.frame = NSRect(x: 0, y: topY - CGFloat(index + 1) * ClassicSessionRowView.height,
                width: bounds.width, height: ClassicSessionRowView.height)
        }
    }

    func bind(_ source: SourceMode) {
        self.source = source
        classicName?.stringValue = source.label
        icon.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and the logo must behave like the rest of the card.
        let hit = super.hitTest(point)
        return (onDrag != nil || onClick != nil) && hit != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if let onDrag {
            onDrag(self, event)
        } else if let onClick {
            MenuCardReorder.trackClick(self, event: event) { [weak self] in
                guard let self else { return }
                onClick(self.source)
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDrag != nil { addCursorRect(bounds, cursor: .openHand) }
        else if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHoverChange?(source, true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHoverChange?(source, false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hovered {
            hovered = false
            onHoverChange?(source, false)
        }
        isDragging = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered && (onDrag != nil || onClick != nil) && !isDragging {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                xRadius: 7, yRadius: 7).fill()
        }
        if layout == .chart && summary?.active == true && !isDragging {
            PanelStyle.traceColor(for: source).setFill()
            NSBezierPath(ovalIn: NSRect(x: icon.frame.maxX + 2, y: icon.frame.maxY - 4, width: 4, height: 4)).fill()
        }
        if isPinned && !isDragging {
            NSColor.controlAccentColor.setFill()
            if layout == .chart {
                NSBezierPath(roundedRect: NSRect(x: bounds.midX - 9, y: 0, width: 18, height: 2),
                    xRadius: 1, yRadius: 1).fill()
            } else {
                let topY = bounds.height - SpeedPanelView.legendHeight
                NSBezierPath(roundedRect: NSRect(x: 2, y: topY + 6, width: 14, height: 2),
                    xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private(set) var summary: SpeedSummary?

    private func updateDetailHelp() {
        let reorder = onDrag == nil ? nil : L10n.text("Drag to reorder")
        let help = [measurementDetails, reorder].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityHelp(help.isEmpty ? nil : help)
    }

    func update(_ summary: SpeedSummary, now: Date = Date()) {
        let wasActive = self.summary?.active
        if self.summary != summary {
            measurementDetails = summary.measurementDetails
            toolTip = measurementDetails.map { summary.tooltip(details: $0) }
            updateDetailHelp()
        }
        self.summary = summary
        let color = PanelStyle.color(active: summary.active)
        icon.contentTintColor = color
        valueLabel.textColor = color
        classicName?.textColor = color
        classicTrend?.update(summary.recent, active: summary.active, source: source)
        valueLabel.stringValue = summary.value
        if wasActive != summary.active {
            needsDisplay = true
        }
        if layout == .classic {
            let visible = summary.visibleSessions(now: now)
            displayedSessions = visible
            while sessionRows.count < visible.count {
                let row = ClassicSessionRowView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: ClassicSessionRowView.height))
                addSubview(row)
                sessionRows.append(row)
            }
            while sessionRows.count > visible.count {
                sessionRows.removeLast().removeFromSuperview()
            }
            for (row, session) in zip(sessionRows, visible) {
                row.update(session, now: now)
            }
            layoutClassicSubviews()
        }
        let state = summary.active ? L10n.text("Active") : L10n.text("Idle")
        let caption = source == .antigravity && summary.current != nil ? L10n.text("Recorded") : summary.caption(now: now)
        setAccessibilityLabel(summary.value == "—"
            ? L10n.text("%@, %@, %@", summary.name, state, caption)
            : L10n.text("%@, %@, %@, %@ tokens per second", summary.name, state, caption, summary.value))
    }
}

final class SpeedPanelView: NSView {
    static let legendHeight: CGFloat = 52
    static let chartY = legendHeight + 8
    static let height = chartY + PanelStyle.plotHeight + 28

    let chart: CallHistoryView
    let cards: [SummaryMenuView]
    let layout: PanelLayout
    var onHeightChange: (() -> Void)?
    private let readout = NSTextField(labelWithString: "")
    private let readoutFormatter = ChartReadoutFormatter(locale: Locale(identifier: L10n.language))
    private var hoveredCardSource: SourceMode?
    private var lastNow = Date()
    var hoverText: String { readout.stringValue }
    override var allowsVibrancy: Bool { false }

    init(sources: [SourceMode], layout: PanelLayout = .chart) {
        self.layout = layout
        chart = CallHistoryView(frame: NSRect(x: PanelStyle.inset, y: Self.chartY,
            width: PanelStyle.plotWidth, height: PanelStyle.plotHeight))
        let slotWidth = PanelStyle.plotWidth / CGFloat(max(1, sources.count))
        cards = sources.enumerated().map { index, source in
            let frame = layout == .classic
                ? NSRect(x: PanelStyle.inset, y: CGFloat(sources.count - index - 1) * Self.legendHeight,
                    width: PanelStyle.plotWidth, height: Self.legendHeight)
                : NSRect(x: PanelStyle.inset + CGFloat(index) * slotWidth,
                    y: 0, width: slotWidth, height: Self.legendHeight)
            return SummaryMenuView(source: source, frame: frame, layout: layout)
        }
        let height = layout == .classic ? CGFloat(sources.count) * Self.legendHeight + 8 : Self.height
        super.init(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: height))
        cards.forEach { card in
            card.onHoverChange = { [weak self] source, inside in
                guard let self else { return }
                if inside {
                    self.hoveredCardSource = source
                } else if self.hoveredCardSource == source {
                    self.hoveredCardSource = nil
                }
                self.chart.highlightedSource = self.hoveredCardSource
                self.refreshReadout()
            }
            addSubview(card)
        }
        guard layout == .chart else { return }
        readout.frame = NSRect(x: PanelStyle.inset, y: chart.frame.maxY + 2,
            width: PanelStyle.plotWidth, height: 18)
        readout.alignment = .center
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        readout.textColor = .labelColor
        readout.lineBreakMode = .byTruncatingTail
        readout.setAccessibilityElement(false)
        addSubview(readout)
        addSubview(chart)
        chart.onHover = { [weak self] _ in
            self?.refreshReadout()
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(_ summaries: [SourceMode: SpeedSummary], pinnedSource: SourceMode? = nil, now: Date = Date()) {
        lastNow = now
        let series: [CallHistoryView.Series] = cards.compactMap { card in
            card.isPinned = (pinnedSource == card.source)
            guard let summary = summaries[card.source] else { return nil }
            card.update(summary, now: now)
            return CallHistoryView.Series(source: card.source, active: summary.active, samples: summary.recent)
        }
        if layout == .chart {
            chart.update(series)
            refreshReadout()
        } else {
            relayoutClassic()
        }
    }

    func clearHover() {
        hoveredCardSource = nil
        chart.highlightedSource = nil
        chart.track(at: nil)
        refreshReadout()
    }

    private func refreshReadout() {
        guard layout == .chart else { return }
        if let reading = chart.hoveredReading {
            readout.stringValue = L10n.text("%@ · %@ · %@ tok/s", reading.source.label,
                readoutFormatter.timestamp(reading.sample.completedAt, now: lastNow),
                readoutFormatter.speed(reading.sample.speed))
            return
        }
        if let hovered = hoveredCardSource,
           let card = cards.first(where: { $0.source == hovered }),
           let summary = card.summary {
            var parts = [summary.name]
            if !summary.model.isEmpty { parts.append(summary.model) }
            parts.append(summary.caption(now: lastNow))
            if card.isPinned { parts.append(L10n.text("Pinned")) }
            readout.stringValue = parts.joined(separator: " · ")
            return
        }
        readout.stringValue = ""
    }

    private func relayoutClassic() {
        var y: CGFloat = 0
        for card in cards.reversed() {
            let height = card.preferredHeight
            let nextFrame = NSRect(x: PanelStyle.inset, y: y, width: PanelStyle.plotWidth, height: height)
            if card.frame != nextFrame { card.frame = nextFrame }
            y += height
        }
        let targetHeight = y + 8
        if frame.height != targetHeight {
            setFrameSize(NSSize(width: PanelStyle.width, height: targetHeight))
            onHeightChange?()
        }
    }
}

final class PanelActionButton: NSButton {
    static let side: CGFloat = 32
    private let menuAction: NSMenuItem
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    override var allowsVibrancy: Bool { false }

    init(item: NSMenuItem, symbol: String, shortcut: String) {
        menuAction = item
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        toolTip = "\(item.title) (\(shortcut))"
        target = self
        action = #selector(activateItem(_:))
        setAccessibilityLabel(item.title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.17 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func activateItem(_ sender: Any?) {
        guard let action = menuAction.action else { return }
        menuAction.menu?.cancelTracking()
        NSApp.sendAction(action, to: menuAction.target, from: menuAction)
    }
}

final class PanelFooterView: NSView {
    static let bottomPadding: CGFloat = 2
    static func topPadding(for layout: PanelLayout) -> CGFloat {
        layout == .classic ? 2 : 14
    }
    static func height(for layout: PanelLayout) -> CGFloat {
        PanelActionButton.side + topPadding(for: layout) + bottomPadding
    }
    static let topPadding: CGFloat = topPadding(for: .chart)
    static let height = height(for: .chart)
    override var allowsVibrancy: Bool { false }

    init(settings: NSMenuItem, quit: NSMenuItem, layout: PanelLayout = .chart) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: Self.height(for: layout)))
        autoresizingMask = [.width]
        setAccessibilityElement(false)
        let buttons = [PanelActionButton(item: settings, symbol: "gearshape", shortcut: "⌘,"),
                       PanelActionButton(item: quit, symbol: "power", shortcut: "⌘Q")]
        let gap: CGFloat = 4
        var right = bounds.maxX - PanelStyle.inset
        for button in buttons.reversed() {
            right -= button.frame.width
            button.frame.origin = NSPoint(x: right, y: Self.bottomPadding)
            button.autoresizingMask = [.minXMargin]
            right -= gap
        }
        buttons.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }
}
