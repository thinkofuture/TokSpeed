import Foundation
import CryptoKit

final class HermesReader: SpeedSourceReader {
    let source: SourceMode = .hermes

    enum Basis: String {
        case stream = "Stream estimate"
        case hook = "E2E fallback (hook)"
        case log = "E2E fallback (agent log)"
    }

    private struct Entry {
        var session: String
        var key: String
        var provider: String
        var sample: Sample
        var basis: Basis
    }

    private struct MatchKey: Hashable {
        let session, model, provider: String
        let input, output, second: Int64

        init(_ entry: Entry, shift: Int64 = 0) {
            session = entry.session
            model = entry.sample.model
            provider = entry.provider
            input = entry.sample.input
            output = entry.sample.output
            second = Int64(entry.sample.completedAt.timeIntervalSince1970.rounded(.down)) + shift
        }
    }

    private struct HookRow: Decodable {
        let v: Int
        let session, request, model, provider: String
        let started_at, ended_at: Double
        let first_chunk_at: Double?
        let input, output: Int64
    }

    private struct CachedFile {
        let stamp: LocalFileStamp
        let entries: [Entry]
    }

    private struct ActivityRow: Decodable {
        enum Event: String, Decodable { case start, stop }
        let v: Int
        let event: Event
        let session, request: String
        let started_at: Double
    }

    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var latestBasis: Basis?
    private(set) var sessions: [SessionSummary] = []
    private(set) var inFlightStart: Date?
    private(set) var fileReadCount = 0
    private let home: String
    private var fileCache: [String: CachedFile] = [:]
    private var completedBySession: [String: [Entry]] = [:]
    private var latestCompletedSession = ""
    private var callsNeedMerge = false
    private var activityStamps: [LocalFileStamp?] = []
    private var pendingActivity: [ActivityRow] = []
    private var sessionDigests: [String: String] = [:]
    private let tailBytes = 2 * 1024 * 1024
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        formatter.isLenient = false
        return formatter
    }()
    private let pattern = try! NSRegularExpression(pattern:
        #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) INFO(?: \[([^\]\r\n]+)\])? agent\.conversation_loop: API call #(\d+): (?:model=(\S+) provider=(\S+) )?in=(\d+) out=(\d+) total=(\d+) latency=(\d+(?:\.\d+)?)s(?: .*)?$"#)

    static func home(environment: [String: String] = ProcessInfo.processInfo.environment,
                     userHome: String = NSHomeDirectory()) -> String {
        if let value = environment["HERMES_HOME"], !value.isEmpty { return value }
        return (userHome as NSString).appendingPathComponent(".hermes")
    }

    init(home: String = HermesReader.home()) { self.home = home }

    static func speed(_ sample: Sample) -> Double {
        guard let first = sample.firstOutputAt else { return sample.effectiveTPS }
        return Double(sample.output) / sample.completedAt.timeIntervalSince(first)
    }

    static let pluginName = "tokspeed-metrics"

    static func logURL(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("plugin-data/\(pluginName)/calls.jsonl")
    }

    var hasOnceData: Bool { !samples.isEmpty || inFlightStart != nil }

    func poll(forceScan: Bool, now: Date) {
        poll(now: now)
    }

    func poll(now: Date = Date()) {
        let root = URL(fileURLWithPath: home).appendingPathComponent("logs")
        let logs = (0...3).map { root.appendingPathComponent($0 == 0 ? "agent.log" : "agent.log.\($0)") }
        let hook = Self.logURL(home: home)
        let activity = hook.deletingLastPathComponent().appendingPathComponent("activity.jsonl")
        let pending = readActivity(at: activity, now: now)
        let eventFiles = [hook, hook.appendingPathExtension("1")]
        let trackedFiles = logs.reversed().map { ($0, false) } + eventFiles.reversed().map { ($0, true) }

        var legacy: [Entry] = []
        var hooks: [Entry] = []
        let decoder = JSONDecoder()
        for (file, isHook) in trackedFiles {
            guard let stamp = LocalFileStamp(file.path) else {
                if fileCache.removeValue(forKey: file.path) != nil { callsNeedMerge = true }
                continue
            }
            if let cached = fileCache[file.path], cached.stamp == stamp {
                if isHook { hooks.append(contentsOf: cached.entries) }
                else { legacy.append(contentsOf: cached.entries) }
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: file) else {
                // Retry transient I/O failures on the next poll without dropping old cache.
                updateSelection(pending: pending, now: now)
                return
            }
            defer { try? handle.close() }
            do {
                fileReadCount += 1
                let size = try handle.seekToEnd()
                let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
                try handle.seek(toOffset: offset)
                // A bounded snapshot also handles truncation, rotation and partial UTF-8.
                let data = try handle.read(upToCount: tailBytes) ?? Data()
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                var parsed: [Entry] = []
                for (index, line) in lines.enumerated() {
                    if index == lines.count - 1 || (offset > 0 && index == 0) { continue }
                    if isHook {
                        if let entry = parseHook(Data(line), decoder: decoder) { parsed.append(entry) }
                    } else if let text = String(data: Data(line), encoding: .utf8), let entry = parseLog(text) {
                        parsed.append(entry)
                    }
                }
                fileCache[file.path] = CachedFile(stamp: stamp, entries: parsed)
                callsNeedMerge = true
                if isHook { hooks.append(contentsOf: parsed) }
                else { legacy.append(contentsOf: parsed) }
            } catch {
                updateSelection(pending: pending, now: now)
                return
            }
        }

        if callsNeedMerge {
            mergeCalls(hooks: hooks, legacy: legacy)
            callsNeedMerge = false
        }
        updateSelection(pending: pending, now: now)
    }

    private func mergeCalls(hooks: [Entry], legacy: [Entry]) {
        var seen = Set<String>()
        let hooks = hooks.reversed().filter { seen.insert($0.key).inserted }
        seen.removeAll()
        let legacy = legacy.reversed().filter { seen.insert($0.key).inserted }

        // Hermes' #N in agent.log counts the entire session; the hook ID counts
        // within a turn. Match only a unique nearby log row with the same call metadata.
        let candidates = Dictionary(grouping: legacy.indices.filter {
            !legacy[$0].session.isEmpty && !legacy[$0].sample.model.isEmpty && !legacy[$0].provider.isEmpty
        }, by: { MatchKey(legacy[$0]) })
        var proposals: [Int: Int] = [:]
        for entry in hooks {
            let end = entry.sample.completedAt
            var match: Int?
            var ambiguous = false
            search: for shift in -1...2 {
                for index in candidates[MatchKey(entry, shift: Int64(shift))] ?? [] {
                    let log = legacy[index].sample
                    // INFO time is local wall clock, millisecond-truncated, shortly after API completion.
                    guard (-0.002...2).contains(log.completedAt.timeIntervalSince(end)),
                          abs(log.elapsed - entry.sample.elapsed) <= 0.051 else { continue }
                    if match != nil {
                        ambiguous = true
                        break search
                    }
                    match = index
                }
            }
            if let match, !ambiguous { proposals[match, default: 0] += 1 }
        }
        var entries = hooks + legacy.indices.filter { proposals[$0] != 1 }.map { legacy[$0] }
        entries.sort {
            if $0.sample.completedAt != $1.sample.completedAt { return $0.sample.completedAt < $1.sample.completedAt }
            return $0.basis == .log && $1.basis != .log
        }
        latestCompletedSession = entries.last?.session ?? ""
        completedBySession = Dictionary(grouping: entries, by: \.session).mapValues { Array($0.suffix(300)) }
    }

    private func readActivity(at url: URL, now: Date) -> [String: Date] {
        let urls = [url.appendingPathExtension("1"), url]
        let stamps = urls.map { LocalFileStamp($0.path) }
        if stamps != activityStamps {
            var pending: [String: ActivityRow] = [:]
            let decoder = JSONDecoder()
            do {
                for (url, stamp) in zip(urls, stamps) where stamp != nil {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let size = try handle.seekToEnd()
                    let limit = 256 * 1024
                    let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
                    try handle.seek(toOffset: offset)
                    let data = try handle.read(upToCount: limit) ?? Data()
                    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                    for line in lines.dropLast().dropFirst(offset > 0 ? 1 : 0) {
                        guard line.count <= 512,
                              let row = try? decoder.decode(ActivityRow.self, from: Data(line)),
                              row.v == 1, Self.validID(row.session), Self.validID(row.request),
                              Self.isEpoch(row.started_at) else { continue }
                        let key = row.session + row.request
                        let storedStart = pending[key]?.started_at ?? 0
                        switch row.event {
                        case .start:
                            if row.started_at >= storedStart { pending[key] = row }
                        case .stop:
                            if row.started_at >= storedStart { pending.removeValue(forKey: key) }
                        }
                    }
                }
                pendingActivity = Array(pending.values)
                activityStamps = stamps
            } catch {
                // A writer may rotate a file between the stat and open; retry on the next poll.
            }
        }
        var active: [String: Date] = [:]
        for row in pendingActivity {
            let start = Date(timeIntervalSince1970: row.started_at)
            guard (-2..<SpeedSummary.multiSessionWindow).contains(now.timeIntervalSince(start)) else { continue }
            active[row.session] = max(active[row.session] ?? .distantPast, start)
        }
        return active
    }

    private func updateSelection(pending: [String: Date], now: Date) {
        let activeSession = pending.max { $0.value < $1.value }
        inFlightStart = activeSession?.value
        sessionID = activeSession?.key ?? latestCompletedSession
        let entries = completedBySession[sessionID] ?? []
        samples = entries.map(\.sample)
        latestBasis = entries.last?.basis

        let cutoff = now.addingTimeInterval(-SpeedSummary.multiSessionWindow)
        var eligible = Set(completedBySession.compactMap { key, entries in
            entries.last.map { $0.sample.completedAt >= cutoff } == true ? key : nil
        })
        eligible.formUnion(pending.keys)
        sessions = eligible.map { key in
            let sample = completedBySession[key]?.last?.sample
            let start = pending[key]
            let id = key.isEmpty ? "hermes" : key
            return SessionSummary(
                id: id,
                title: SessionSummary.cleanTitle(sample?.model, fallback: id),
                active: start != nil,
                live: nil,
                last: sample.map(Self.speed),
                activityAt: max(start ?? .distantPast, sample?.completedAt ?? .distantPast),
                inFlightStart: start
            )
        }
    }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let last = samples.last.map(Self.speed)
        let completed = samples.last?.completedAt
        let history = samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: Self.speed($0)) }
        let measurement = latestBasis == .stream
            ? L10n.text("Last call: estimated stream speed (first chunk to API completion).")
            : L10n.text("Last call: output tokens / full API time.")
        let summary = SpeedSummary(name: source.label, active: inFlightStart != nil, live: nil, last: last,
            completedAt: completed, history: history, model: samples.last?.model ?? "",
            measurement: measurement, sessions: sessions,
            metrics: samples.last.map { CallMetrics(input: $0.input, output: $0.output, firstChunk: $0.ttft) })
        let hookURL = Self.logURL(home: home)
        let diagPath = FileManager.default.fileExists(atPath: hookURL.path)
            ? hookURL.path
            : URL(fileURLWithPath: home).appendingPathComponent("logs/agent.log").path
        let status = inFlightStart != nil ? "active" : (samples.isEmpty ? "no data" : (latestBasis?.rawValue ?? "ready"))
        return SourceSnapshot(
            source: source,
            summary: summary,
            activityDate: max(completed ?? .distantPast, inFlightStart ?? .distantPast),
            inFlightStart: inFlightStart,
            liveSpeed: nil,
            hasData: hasOnceData,
            diagnostic: SourceDiagnostic(source: source, path: diagPath, status: status, sampleCount: samples.count)
        )
    }

    func onceLines(now: Date = Date()) -> [String] {
        var lines = ["samples:   \(samples.count)", "active:    \(inFlightStart != nil)"]
        if let sample = samples.last, let basis = latestBasis {
            lines.append("model:     \(sample.model)")
            lines.append("output:    \(sample.output)")
            lines.append("basis:     \(basis.rawValue)")
            lines.append("elapsed:   \(Fmt.secs(sample.elapsed))")
            if let first = sample.firstOutputAt, let wait = sample.ttft {
                lines.append("TTFC:      \(Fmt.secs(wait))")
                lines.append("stream:    \(Fmt.secs(sample.completedAt.timeIntervalSince(first)))")
                lines.append("E2E speed: \(Fmt.tps(sample.effectiveTPS)) tok/s")
            }
            lines.append("speed:     \(Fmt.tps(Self.speed(sample))) tok/s")
        }
        return lines
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isEpoch(_ value: Double) -> Bool { (946_684_800..<4_102_444_800).contains(value) }

    private func parseHook(_ data: Data, decoder: JSONDecoder) -> Entry? {
        guard data.count <= 4096, let row = try? decoder.decode(HookRow.self, from: data), row.v == 1,
              Self.validID(row.session), Self.validID(row.request), Self.isEpoch(row.started_at), Self.isEpoch(row.ended_at),
              (0.001...86_400).contains(row.ended_at - row.started_at),
              (1...100_000_000).contains(row.output), (0...100_000_000).contains(row.input) else { return nil }
        var first: Date?
        if let chunk = row.first_chunk_at, chunk >= row.started_at, chunk < row.ended_at {
            let span = row.ended_at - chunk
            if span >= 0.12 && Double(row.output) / span <= 3_000 {
                first = Date(timeIntervalSince1970: chunk)
            }
        }
        let sample = Sample(startedAt: Date(timeIntervalSince1970: row.started_at),
            completedAt: Date(timeIntervalSince1970: row.ended_at), firstOutputAt: first,
            model: row.model, input: row.input, cachedInput: 0, output: row.output,
            reasoning: 0, total: row.input + row.output)
        return Entry(session: row.session, key: row.session + row.request, provider: row.provider,
                     sample: sample, basis: first == nil ? .hook : .stream)
    }

    private func parseLog(_ text: String) -> Entry? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func field(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        guard let end = dateFormatter.date(from: field(1)),
              let input = Int64(field(6)), let output = Int64(field(7)), output > 0,
              let total = Int64(field(8)), let seconds = Double(field(9)), seconds > 0, seconds <= 86_400 else { return nil }
        let sample = Sample(startedAt: end.addingTimeInterval(-seconds), completedAt: end,
            firstOutputAt: nil, model: field(4), input: input, cachedInput: 0,
            output: output, reasoning: 0, total: total)
        let session = field(2)
        if sessionDigests.count > 1000 { sessionDigests.removeAll(keepingCapacity: true) }
        let digest = session.isEmpty ? "" : sessionDigests[session] ?? Self.digest(session)
        if !session.isEmpty { sessionDigests[session] = digest }
        return Entry(session: digest, key: field(1) + ":" + digest + ":" + field(3),
                     provider: field(5), sample: sample, basis: .log)
    }
}
