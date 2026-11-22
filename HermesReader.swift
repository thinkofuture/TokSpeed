import Foundation
import CryptoKit

final class HermesReader {
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

    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var latestBasis: Basis?
    private let home: String
    private var signature: [String] = []
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

    func poll() {
        let root = URL(fileURLWithPath: home).appendingPathComponent("logs")
        let logs = (0...3).map { root.appendingPathComponent($0 == 0 ? "agent.log" : "agent.log.\($0)") }
        let hook = Self.logURL(home: home)
        let eventFiles = [hook, hook.appendingPathExtension("1")]
        let current = (logs + eventFiles).map { url -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(attributes[.systemFileNumber] ?? 0):\(attributes[.size] ?? 0):\(modified)"
        }
        guard current != signature else { return }
        sessionDigests.removeAll(keepingCapacity: true)
        var legacy: [Entry] = [], hooks: [Entry] = []
        let decoder = JSONDecoder()
        for (file, isHook) in logs.reversed().map({ ($0, false) }) + eventFiles.reversed().map({ ($0, true) }) {
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                if FileManager.default.fileExists(atPath: file.path) { return }
                continue
            }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
                try handle.seek(toOffset: offset)
                // A bounded snapshot also handles truncation, rotation and partial UTF-8.
                let data = try handle.read(upToCount: tailBytes) ?? Data()
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    if index == lines.count - 1 || (offset > 0 && index == 0) { continue }
                    if isHook {
                        if let entry = parseHook(Data(line), decoder: decoder) { hooks.append(entry) }
                    } else if let text = String(data: Data(line), encoding: .utf8), let entry = parseLog(text) {
                        legacy.append(entry)
                    }
                }
            } catch {
                // Retry transient I/O failures on the next poll, even if metadata is unchanged.
                return
            }
        }
        var seen = Set<String>()
        hooks = hooks.filter { seen.insert($0.key).inserted }
        seen.removeAll()
        legacy = legacy.filter { seen.insert($0.key).inserted }

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
        let latestSession = entries.last?.session ?? ""
        samples = entries.filter { $0.session == latestSession }.suffix(300).map(\.sample)
        sessionID = latestSession
        latestBasis = entries.last?.basis
        signature = current
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", Int($0)) }.joined()
    }

    private func parseHook(_ data: Data, decoder: JSONDecoder) -> Entry? {
        func validID(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func epoch(_ value: Double) -> Bool { (946_684_800..<4_102_444_800).contains(value) }
        guard data.count <= 4096, let row = try? decoder.decode(HookRow.self, from: data), row.v == 1,
              validID(row.session), validID(row.request), epoch(row.started_at), epoch(row.ended_at),
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

    private var sessionDigests: [String: String] = [:]

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
        let digest = session.isEmpty ? "" : sessionDigests[session] ?? Self.digest(session)
        if !session.isEmpty { sessionDigests[session] = digest }
        return Entry(session: digest, key: field(1) + ":" + digest + ":" + field(3),
                     provider: field(5), sample: sample, basis: .log)
    }
}
