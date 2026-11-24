import AppKit

extension Fmt {
    static func statusTitle(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        if text.isEmpty { return NSAttributedString(string: "") }
        return NSAttributedString(string: " " + text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

enum PanelStyle {
    static let width: CGFloat = 360
    static let inset: CGFloat = 16
    static let plotWidth = width - inset * 2
    static let plotHeight = plotWidth * 3 / 5

    private static let activeColor = ink(alpha: 1)
    private static let idleColor = ink(alpha: 0.52)

    static func color(active: Bool) -> NSColor { active ? activeColor : idleColor }

    static func traceColor(for source: SourceMode) -> NSColor {
        func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let c = isDark ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
        switch source {
        case .claude: return dynamic(dark: (0.88, 0.56, 0.43), light: (0.77, 0.36, 0.21))
        case .codex: return dynamic(dark: (0.35, 0.79, 0.56), light: (0.12, 0.55, 0.34))
        case .opencode: return dynamic(dark: (0.40, 0.66, 1.00), light: (0.15, 0.44, 0.84))
        case .antigravity: return dynamic(dark: (0.66, 0.55, 1.00), light: (0.43, 0.31, 0.85))
        case .hermes: return dynamic(dark: (0.90, 0.71, 0.36), light: (0.72, 0.49, 0.09))
        case .cursor: return dynamic(dark: (0.35, 0.78, 0.85), light: (0.07, 0.52, 0.59))
        case .auto: return color(active: true)
        }
    }

    private static func ink(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let white: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
            return NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
        }
    }
}

final class CallHistoryView: NSView {
    struct Series: Equatable {
        let source: SourceMode
        let active: Bool
        let samples: [CallHistoryPoint]

        var strokeWidth: CGFloat { active ? 3.4 : 2.6 }
        var ink: NSColor {
            active ? PanelStyle.traceColor(for: source) : PanelStyle.color(active: true).withAlphaComponent(0.28)
        }
    }

    struct Reading: Equatable {
        let source: SourceMode
        let sample: CallHistoryPoint
        let position: NSPoint
    }

    static let plotInset: CGFloat = 12
    static let lookback: TimeInterval = 6 * 3600
    static let minimumSpan: TimeInterval = 5 * 60
    static let maximumGap: TimeInterval = 20 * 60
    private static let detailWidth: CGFloat = 12
    private static let accessibilityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct TimeScale {
        let first: Date
        let span: TimeInterval
        let leading: TimeInterval

        init(first: Date, last: Date) {
            self.first = first
            let observed = last.timeIntervalSince(first)
            // Keep closely spaced samples from stretching across the whole plot.
            span = max(CallHistoryView.minimumSpan, observed)
            leading = (span - observed) / 2
        }

        func position(of date: Date) -> CGFloat {
            CGFloat((date.timeIntervalSince(first) + leading) / span)
        }
    }

    private(set) var series: [Series] = []
    private(set) var hoveredReading: Reading?
    var highlightedSource: SourceMode? {
        didSet {
            if oldValue != highlightedSource { needsDisplay = true }
        }
    }
    var onHover: ((Reading?) -> Void)?
    private var hoverLocation: NSPoint?
    private var hoverTracking: NSTrackingArea?
    private var cachedVisible: [[[Reading]]] = []
    private var cachedBounds: NSRect = .zero
    private let emptyLabel = NSTextField(labelWithString: L10n.text("No completed calls yet"))
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        emptyLabel.frame = NSRect(x: 12, y: bounds.midY - 9, width: bounds.width - 24, height: 18)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityElement(false)
        addSubview(emptyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("Recent completed calls"))
        setAccessibilityHelp(L10n.text("Bright lines share a completion-time scale. Faint lines show each idle tool’s own recent history, not the same times. All lines share a speed scale. Long gaps are not connected."))
        setAccessibilityValue(L10n.text("No completed calls yet"))
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        emptyLabel.frame = NSRect(x: 12, y: bounds.midY - 9, width: max(0, bounds.width - 24), height: 18)
        cachedBounds = .zero
    }

    func update(_ series: [Series]) {
        let populated = Self.windowed(series)
        guard self.series != populated else { return }
        self.series = populated
        cachedBounds = bounds
        cachedVisible = Self.visibleReadings(populated, in: bounds)
        emptyLabel.isHidden = !populated.isEmpty
        let readings = populated.map { entry in
            let history = entry.samples.map { "\(Self.accessibilityDateFormatter.string(from: $0.completedAt)): \(Fmt.tps($0.speed))" }
            let state = entry.active ? L10n.text("Active") : L10n.text("Idle")
            return "\(entry.source.label) (\(state)): \(history.joined(separator: ", "))"
        }
        setAccessibilityValue(readings.isEmpty ? L10n.text("No completed calls yet") : readings.joined(separator: "; "))
        track(at: hoverLocation)
        needsDisplay = true
    }

    private func resolvedVisibleReadings() -> [[[Reading]]] {
        if cachedBounds != bounds {
            cachedBounds = bounds
            cachedVisible = Self.visibleReadings(series, in: bounds)
        }
        return cachedVisible
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        track(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { track(at: nil) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        track(at: nil)
    }

    func track(at location: NSPoint?) {
        hoverLocation = location
        let readings = resolvedVisibleReadings()
        let reading = location.flatMap { Self.nearestReading(to: $0, series: series, readings: readings, in: bounds) }
        guard reading != hoveredReading else { return }
        hoveredReading = reading
        onHover?(reading)
        needsDisplay = true
    }

    static func nearestReading(to location: NSPoint, series: [Series], in bounds: NSRect) -> Reading? {
        nearestReading(to: location, series: series, readings: visibleReadings(series, in: bounds), in: bounds)
    }

    static func nearestReading(to location: NSPoint, series: [Series], readings: [[[Reading]]], in bounds: NSRect) -> Reading? {
        guard bounds.contains(location) else { return nil }
        var best: Reading?
        var distance: CGFloat = 16
        // At equal distances prefer the foreground (drawn last) and then the newer point.
        for (_, segments) in zip(series, readings).reversed().sorted(by: { $0.0.active && !$1.0.active }) {
            for reading in segments.flatMap({ $0 }).reversed() {
                let candidate = hypot(reading.position.x - location.x, reading.position.y - location.y)
                guard candidate < distance else { continue }
                best = reading
                distance = candidate
            }
        }
        return best
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let readings = resolvedVisibleReadings()
        let plots = readings.map { $0.map { $0.map(\.position) } }
        let layers = zip(series, plots)
        let focused = hoveredReading?.source ?? highlightedSource

        for isActive in [false, true] {
            let group = layers.filter { $0.0.active == isActive }
            for (entry, segments) in group {
                let color: NSColor
                if let focused {
                    if entry.source == focused {
                        color = entry.active
                            ? entry.ink
                            : PanelStyle.traceColor(for: entry.source).withAlphaComponent(0.85)
                    } else {
                        color = entry.ink.withAlphaComponent(entry.ink.alphaComponent * 0.25)
                    }
                } else {
                    color = entry.ink
                }
                drawTrace(entry, segments: segments, color: color)
            }
        }

        drawYAxisScale(readings: readings)

        if let hovered = hoveredReading {
            let area = bounds.insetBy(dx: Self.plotInset, dy: Self.plotInset)
            let hairline = NSBezierPath()
            hairline.move(to: NSPoint(x: hovered.position.x, y: area.minY))
            hairline.line(to: NSPoint(x: hovered.position.x, y: area.maxY))
            hairline.lineWidth = 1
            PanelStyle.color(active: true).withAlphaComponent(0.16).setStroke()
            hairline.stroke()

            let accent = PanelStyle.traceColor(for: hovered.source)
            let haloRect = NSRect(x: hovered.position.x - 5.5, y: hovered.position.y - 5.5, width: 11, height: 11)
            accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            let dotRect = NSRect(x: hovered.position.x - 3.5, y: hovered.position.y - 3.5, width: 7, height: 7)
            accent.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private func drawTrace(_ entry: Series, segments: [[NSPoint]], color: NSColor) {
        let path = Self.linePath(segments)
        path.lineWidth = entry.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()

        color.setFill()
        for segment in segments where segment.count == 1 {
            let point = segment[0]
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }
    }

    private func drawYAxisScale(readings: [[[Reading]]]) {
        let speeds = readings.flatMap { $0 }.flatMap { $0 }.map(\.sample.speed)
        guard let low = speeds.min(), let high = speeds.max() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: PanelStyle.color(active: true).withAlphaComponent(0.42),
        ]
        let area = bounds.insetBy(dx: Self.plotInset, dy: Self.plotInset)
        let highText = NSAttributedString(string: Fmt.tps(high), attributes: attrs)
        let lowText = NSAttributedString(string: Fmt.tps(low), attributes: attrs)

        if high == low || Fmt.tps(high) == Fmt.tps(low) {
            let size = highText.size()
            highText.draw(at: NSPoint(x: bounds.maxX - size.width - 4, y: area.midY - size.height / 2))
            return
        }
        let highSize = highText.size()
        let lowSize = lowText.size()
        highText.draw(at: NSPoint(x: bounds.maxX - highSize.width - 4, y: area.maxY - highSize.height / 2))
        lowText.draw(at: NSPoint(x: bounds.maxX - lowSize.width - 4, y: area.minY - lowSize.height / 2))
    }

    static func windowed(_ series: [Series]) -> [Series] {
        let latestActive = series.filter(\.active).compactMap { $0.samples.last?.completedAt }.max()
        return series.compactMap { entry in
            guard let latest = entry.active ? latestActive : entry.samples.last?.completedAt else { return nil }
            let samples = withoutIsolatedSpikes(entry.samples)
                .filter { latest.timeIntervalSince($0.completedAt) <= lookback }
            return samples.isEmpty ? nil : Series(source: entry.source, active: entry.active, samples: samples)
        }
    }

    static func withoutIsolatedSpikes(_ samples: [CallHistoryPoint]) -> [CallHistoryPoint] {
        // Require nearby observations on both sides. Keep unconfirmed endpoints,
        // ordinary variation, and consecutive high readings rather than cap TPS.
        samples.enumerated().compactMap { index, sample in
            guard index > 0 && index < samples.count - 1 else { return sample }
            let previous = samples[index - 1], next = samples[index + 1]
            let before = sample.completedAt.timeIntervalSince(previous.completedAt)
            let after = next.completedAt.timeIntervalSince(sample.completedAt)
            guard before > 0 && before <= maximumGap && after > 0 && after <= maximumGap,
                  sample.speed / 4 >= max(previous.speed, next.speed) else { return sample }
            return nil
        }
    }

    /// Outer array is per-source; each inner array holds the contiguous segments of that source.
    static func project(_ series: [Series], in bounds: NSRect) -> [[[NSPoint]]] {
        let speeds = series.flatMap(\.samples).map(\.speed)
        guard let low = speeds.min(), let high = speeds.max() else { return series.map { _ in [] } }
        let area = bounds.insetBy(dx: plotInset, dy: plotInset)
        let active = series.filter(\.active)
        let activeScale: TimeScale?
        if let first = active.compactMap({ $0.samples.first?.completedAt }).min(),
           let last = active.compactMap({ $0.samples.last?.completedAt }).max() {
            activeScale = TimeScale(first: first, last: last)
        } else {
            activeScale = nil
        }
        return series.map { entry in
            guard let first = entry.samples.first?.completedAt, let last = entry.samples.last?.completedAt else { return [] }
            // Idle histories fit their own recorded duration, never padding out the active timeline.
            let scale = (entry.active ? activeScale : nil) ?? TimeScale(first: first, last: last)
            var segments: [[NSPoint]] = []
            var previous: Date?
            for sample in entry.samples {
                if previous.map({ sample.completedAt.timeIntervalSince($0) > maximumGap }) ?? true {
                    segments.append([])
                }
                previous = sample.completedAt
                let y = high == low ? 0.5 : (sample.speed - low) / (high - low)
                segments[segments.count - 1].append(NSPoint(x: area.minX + area.width * scale.position(of: sample.completedAt),
                    y: area.minY + area.height * CGFloat(y)))
            }
            return segments
        }
    }

    static func visibleReadings(_ series: [Series], in bounds: NSRect) -> [[[Reading]]] {
        let traces = zip(series, project(series, in: bounds)).map { entry, segments in
            var samples = entry.samples.makeIterator()
            return segments.map { segment in
                var readings: [Reading] = []
                for position in segment {
                    guard let sample = samples.next() else { break }
                    let reading = Reading(source: entry.source, sample: sample, position: position)
                    // Several calls can share a coarse completion timestamp.
                    if readings.last?.position.x == position.x { readings[readings.count - 1] = reading }
                    else { readings.append(reading) }
                }
                guard readings.count > 2 else { return readings }
                // The endpoints and gaps stay put. Where calls are too close to
                // resolve comfortably, use a real middle-speed reading, not an average.
                var reduced = [readings[0]]
                var bucket: [Reading] = []
                func flush() {
                    guard !bucket.isEmpty else { return }
                    let bySpeed = bucket.sorted { $0.sample.speed < $1.sample.speed }
                    reduced.append(bySpeed[(bySpeed.count - 1) / 2])
                    bucket.removeAll(keepingCapacity: true)
                }
                for reading in readings.dropFirst().dropLast() {
                    if let start = bucket.first, reading.position.x - start.position.x >= detailWidth { flush() }
                    bucket.append(reading)
                }
                flush()
                reduced.append(readings[readings.count - 1])
                return reduced
            }
        }
        let speeds = traces.flatMap { $0 }.flatMap { $0 }.map { $0.sample.speed }
        guard let low = speeds.min(), let high = speeds.max() else { return traces }
        let area = bounds.insetBy(dx: plotInset, dy: plotInset)
        return traces.map { $0.map { $0.map { reading in
            let y = low == high ? 0.5 : (reading.sample.speed - low) / (high - low)
            return Reading(source: reading.source, sample: reading.sample,
                position: NSPoint(x: reading.position.x, y: area.minY + area.height * CGFloat(y)))
        } } }
    }

    static func linePath(_ segments: [[NSPoint]]) -> NSBezierPath {
        let path = NSBezierPath()
        for segment in segments where segment.count > 1 {
            path.move(to: segment[0])
            let slopes = zip(segment, segment.dropFirst()).map { a, b -> CGFloat in
                b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0
            }
            func tangent(_ index: Int) -> CGFloat {
                if index == 0 { return slopes[0] }
                if index == slopes.count { return slopes[index - 1] }
                let a = slopes[index - 1], b = slopes[index]
                guard (a > 0 && b > 0) || (a < 0 && b < 0) else { return 0 }
                // Limit the knot's shared slope, not the two handles separately.
                // A single tangent keeps joins smooth even when time intervals differ.
                let magnitude = min(abs(2 / (1 / a + 1 / b)), 1.5 * min(abs(a), abs(b)))
                return a > 0 ? magnitude : -magnitude
            }
            for index in slopes.indices {
                let a = segment[index], b = segment[index + 1]
                guard b.x > a.x else {
                    // Keep observations with identical timestamps at the same X.
                    path.line(to: b)
                    continue
                }
                let dx = (b.x - a.x) / 3
                path.curve(to: b,
                    controlPoint1: NSPoint(x: a.x + dx, y: a.y + dx * tangent(index)),
                    controlPoint2: NSPoint(x: b.x - dx, y: b.y - dx * tangent(index + 1)))
            }
        }
        return path
    }
}

final class ClassicTrendView: NSView {
    private var speeds: [Double] = []
    private var active = false
    private var source: SourceMode = .auto
    override var allowsVibrancy: Bool { false }

    func update(_ points: [CallHistoryPoint], active: Bool, source: SourceMode = .auto) {
        let speeds = CallHistoryView.withoutIsolatedSpikes(points).suffix(12).map(\.speed)
        guard self.speeds != speeds || self.active != active || self.source != source else { return }
        self.speeds = speeds
        self.active = active
        self.source = source
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard speeds.count > 1, let peak = speeds.max(), peak > 0 else { return }
        let area = bounds.insetBy(dx: 2, dy: 2)
        let points = speeds.enumerated().map { index, speed in
            NSPoint(x: area.minX + area.width * CGFloat(12 - speeds.count + index) / 11,
                y: area.minY + area.height * CGFloat(speed / peak))
        }
        let style = CallHistoryView.Series(source: source, active: active, samples: [])
        let path = CallHistoryView.linePath([points])
        path.lineWidth = style.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        style.ink.setStroke()
        path.stroke()
    }
}

struct ChartReadoutFormatter {
    private let time = DateFormatter()
    private let dateTime = DateFormatter()
    private let fullDateTime = DateFormatter()
    private let number = NumberFormatter()

    init(locale: Locale) {
        time.locale = locale
        time.setLocalizedDateFormatFromTemplate("jm")
        dateTime.locale = locale
        dateTime.setLocalizedDateFormatFromTemplate("MMMdjm")
        fullDateTime.locale = locale
        fullDateTime.setLocalizedDateFormatFromTemplate("yMMMdjm")
        number.locale = locale
        number.numberStyle = .decimal
        number.usesGroupingSeparator = false
    }

    func timestamp(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return dateTime.string(from: date)
        }
        // Include the year for older idle history, but still omit seconds.
        return fullDateTime.string(from: date)
    }

    func speed(_ speed: Double) -> String {
        let digits = speed > 10 ? 0 : 1
        number.minimumFractionDigits = digits
        number.maximumFractionDigits = digits
        return number.string(from: NSNumber(value: speed)) ?? Fmt.tps(speed)
    }
}
