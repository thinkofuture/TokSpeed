import Foundation

struct Sample {
    var startedAt: Date
    var completedAt: Date
    var firstOutputAt: Date?
    var model: String
    var input: Int64
    var cachedInput: Int64
    var output: Int64
    var reasoning: Int64
    var total: Int64

    var elapsed: Double { completedAt.timeIntervalSince(startedAt) }
    var effectiveTPS: Double { elapsed > 0 ? Double(output) / elapsed : 0 }
    var visibleTPS: Double { elapsed > 0 ? Double(max(0, output - reasoning)) / elapsed : 0 }
    var ttft: Double? { firstOutputAt.map { $0.timeIntervalSince(startedAt) } }
    var metrics: CallMetrics { .init(input: input, output: output, firstToken: ttft) }
}

struct SessionSummary: Equatable {
    let id: String
    let title: String
    let active: Bool
    let live: Double?
    let last: Double?
    let activityAt: Date
    let inFlightStart: Date?

    var current: Double? { active ? StatusDisplay.validSpeed(live) : nil }
    var speed: Double? { current ?? StatusDisplay.validSpeed(last) }

    func speedText(now: Date = Date()) -> String {
        if let speed { return Fmt.tps(speed) }
        if active, let start = inFlightStart {
            return L10n.text("%d s", Int(max(0, now.timeIntervalSince(start))))
        }
        return "—"
    }

    static func cleanTitle(_ raw: String?, fallback: String) -> String {
        let firstLine = (raw ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let candidate = collapsed.isEmpty ? shortID(fallback) : collapsed
        if candidate.count <= 60 { return candidate }
        return String(candidate.prefix(59)) + "…"
    }

    static func shortID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "—" }
        if trimmed.count <= 12 { return trimmed }
        return String(trimmed.prefix(8))
    }
}

enum SourceMode: String, CaseIterable {
    case auto, codex, opencode, claude, antigravity, hermes, cursor

    static let allTools: [SourceMode] = ToolOrder.popular

    var label: String {
        switch self {
        case .auto: return L10n.text("Automatic")
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .hermes: return "Hermes"
        case .cursor: return "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .codex, .auto: return "bolt.fill"
        case .opencode: return "terminal.fill"
        case .claude: return "sparkles"
        case .antigravity: return "moon.stars.fill"
        case .hermes: return "person.crop.circle.fill"
        case .cursor: return "cursorarrow"
        }
    }
}

enum ToolOrder {
    // A static popularity-oriented default, not a measured or network-fetched ranking.
    static let popular: [SourceMode] = [.claude, .codex, .opencode, .antigravity, .hermes, .cursor]

    static func normalized(_ saved: [String]) -> [SourceMode] {
        var result: [SourceMode] = []
        for raw in saved + popular.map(\.rawValue) {
            if let source = SourceMode(rawValue: raw), source != .auto, !result.contains(source) {
                result.append(source)
            }
        }
        return result
    }

    static func moving(_ source: SourceMode, to destination: Int, in order: [SourceMode]) -> [SourceMode] {
        guard let index = order.firstIndex(of: source), order.indices.contains(destination) else { return order }
        var result = order
        result.remove(at: index)
        result.insert(source, at: destination)
        return result
    }
}

enum StatusDisplay: String, CaseIterable {
    case speedAndUnit, numbersOnly, iconOnly

    var label: String {
        switch self {
        case .speedAndUnit: return L10n.text("Number and unit")
        case .numbersOnly: return L10n.text("Number only")
        case .iconOnly: return L10n.text("Icon only")
        }
    }

    func title(active: Bool, speed: Double?, elapsed: Double) -> String {
        guard active, self != .iconOnly else { return "" }
        if let speed = Self.validSpeed(speed) {
            return Fmt.tps(speed) + (self == .speedAndUnit ? " tok/s" : "")
        }
        return L10n.text("%d s", Int(max(0, elapsed)))
    }

    static func validSpeed(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    func usesLightning(active: Bool) -> Bool { !active || self == .iconOnly }
}

enum PanelLayout: String, CaseIterable {
    case chart, classic

    var label: String {
        switch self {
        case .chart: return L10n.text("Trend chart")
        case .classic: return L10n.text("Detailed list")
        }
    }
}

struct CallHistoryPoint: Equatable {
    let completedAt: Date
    let speed: Double

    var isValid: Bool { completedAt.timeIntervalSinceReferenceDate.isFinite && speed.isFinite && speed > 0 }
}

struct CallMetrics: Equatable {
    var input: Int64?
    var output: Int64
    var firstToken: Double?
    var firstChunk: Double?
}

struct SpeedSummary: Equatable {
    static let historyLimit = 60
    static let multiSessionWindow: TimeInterval = 5 * 60
    static let maxVisibleSessions = 6
    let name: String
    let active: Bool
    let live: Double?
    let last: Double?
    let completedAt: Date?
    let history: [CallHistoryPoint]
    let model: String
    let measurement: String
    let sessions: [SessionSummary]
    let metrics: CallMetrics?

    init(name: String, active: Bool, live: Double?, last: Double?, completedAt: Date?,
         history: [CallHistoryPoint], model: String, measurement: String,
         sessions: [SessionSummary] = [], metrics: CallMetrics? = nil) {
        self.name = name
        self.active = active
        self.live = live
        self.last = last
        self.completedAt = completedAt
        self.history = history
        self.model = model
        self.measurement = measurement
        self.sessions = sessions
        self.metrics = metrics
    }

    var current: Double? { active ? StatusDisplay.validSpeed(live) : nil }
    var value: String { (current ?? StatusDisplay.validSpeed(last)).map(Fmt.tps) ?? "—" }
    var recent: [CallHistoryPoint] {
        Array(history.filter(\.isValid).sorted { $0.completedAt < $1.completedAt }.suffix(Self.historyLimit))
    }

    func visibleSessions(now: Date = Date()) -> [SessionSummary] {
        let cutoff = now.addingTimeInterval(-Self.multiSessionWindow)
        let eligible = sessions.filter { session in
            (session.active || session.activityAt >= cutoff) && (session.active || session.speed != nil)
        }
        guard eligible.count >= 2 else { return [] }
        return Array(eligible.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            if lhs.activityAt != rhs.activityAt { return lhs.activityAt > rhs.activityAt }
            return lhs.id < rhs.id
        }.prefix(Self.maxVisibleSessions))
    }

    func caption(now: Date = Date()) -> String {
        if current != nil { return L10n.text("This turn") }
        guard StatusDisplay.validSpeed(last) != nil else { return active ? L10n.text("Waiting for data") : L10n.text("No data") }
        guard let date = completedAt else { return L10n.text("Last call") }
        let age = max(0, now.timeIntervalSince(date))
        let time: String
        if age < 5 { time = L10n.text("Just now") }
        else if age < 60 { time = L10n.text("%d s ago", Int(age)) }
        else if age < 3600 { time = L10n.text("%d min ago", Int(age / 60)) }
        else if age < 86400 { time = L10n.text("%d h ago", Int(age / 3600)) }
        else { time = L10n.text("%d d ago", Int(age / 86400)) }
        return L10n.text("Last · %@", time)
    }

    var measurementDetails: String? {
        guard !measurement.isEmpty else { return nil }
        var lines: [String] = []
        if let input = metrics?.input { lines.append(L10n.text("Input: %@ tokens", Fmt.int(input))) }
        if let output = metrics?.output { lines.append(L10n.text("Output: %@ tokens", Fmt.int(output))) }
        if let wait = metrics?.firstToken { lines.append(L10n.text("First token: %@", Fmt.secs(wait))) }
        if let wait = metrics?.firstChunk { lines.append(L10n.text("First chunk: %@", Fmt.secs(wait))) }
        let speeds = history.filter(\.isValid).map(\.speed).sorted()
        if !speeds.isEmpty {
            let middle = speeds.count / 2
            let median = speeds.count.isMultiple(of: 2) ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
            lines.append(L10n.text("Median: %@ tok/s", Fmt.tps(median)))
        }
        lines.append(measurement)
        return lines.joined(separator: "\n")
    }

    func tooltip(details: String) -> String {
        let identity = model.isEmpty ? name : "\(name) · \(model)"
        return "\(identity)\n\(details)"
    }
}

struct SourceDiagnostic: Equatable {
    let source: SourceMode
    let path: String
    let status: String
    let sampleCount: Int
}

struct SourceSnapshot {
    let source: SourceMode
    let summary: SpeedSummary
    let activityDate: Date
    let inFlightStart: Date?
    let liveSpeed: Double?
    let hasData: Bool
    let diagnostic: SourceDiagnostic
}

enum Fmt {
    private static let lock = NSLock()
    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func tps(_ v: Double) -> String { String(format: v > 10 ? "%.0f" : "%.1f", v) }
    static func secs(_ v: Double) -> String { String(format: "%.2fs", v) }

    static func int(_ v: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return integerFormatter.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func clock(_ d: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return clockFormatter.string(from: d)
    }
}

enum ISO8601DateParser {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: text) ?? wholeSeconds.date(from: text)
    }
}

extension ISO8601DateFormatter {
    static let codex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64 {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let i = self[key] as? Int64 { return i }
        if let i = self[key] as? Int { return Int64(i) }
        return 0
    }
}
