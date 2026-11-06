import Foundation

// Hermes' database stores aggregate usage, not per-call timing. Its INFO log
// records provider-reported tokens and rounded API latency after each call.
final class HermesReader {
    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
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
        #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) INFO(?: \[([^\]\r\n]+)\])? agent\.conversation_loop: API call #(\d+): (?:model=(\S+) provider=\S+ )?in=(\d+) out=(\d+) total=(\d+) latency=(\d+(?:\.\d+)?)s(?: .*)?$"#)

    static func home(environment: [String: String] = ProcessInfo.processInfo.environment,
                     userHome: String = NSHomeDirectory()) -> String {
        if let value = environment["HERMES_HOME"], !value.isEmpty { return value }
        return (userHome as NSString).appendingPathComponent(".hermes")
    }

    init(home: String = HermesReader.home()) { self.home = home }

    func poll() {
        let root = URL(fileURLWithPath: home).appendingPathComponent("logs")
        let files = (0...3).map { root.appendingPathComponent($0 == 0 ? "agent.log" : "agent.log.\($0)") }
        let current = files.map { url -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(attributes[.systemFileNumber] ?? 0):\(attributes[.size] ?? 0):\(modified)"
        }
        guard current != signature else { return }
        var entries: [(session: String, key: String, sample: Sample)] = []
        for file in files.reversed() {
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
                    guard let text = String(data: Data(line), encoding: .utf8),
                          let entry = parse(text) else { continue }
                    entries.append(entry)
                }
            } catch {
                // Retry transient I/O failures on the next poll, even if metadata is unchanged.
                return
            }
        }
        entries.sort { $0.sample.completedAt < $1.sample.completedAt }
        let latestSession = entries.last?.session ?? ""
        var seen = Set<String>()
        samples = entries.filter { $0.session == latestSession && seen.insert($0.key).inserted }.suffix(300).map(\.sample)
        sessionID = latestSession
        signature = current
    }

    private func parse(_ text: String) -> (session: String, key: String, sample: Sample)? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func field(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        guard let end = dateFormatter.date(from: field(1)),
              let input = Int64(field(5)), let output = Int64(field(6)), output > 0,
              let total = Int64(field(7)), let seconds = Double(field(8)), seconds.isFinite, seconds > 0 else { return nil }
        let sample = Sample(startedAt: end.addingTimeInterval(-seconds), completedAt: end,
            firstOutputAt: nil, model: field(4), input: input, cachedInput: 0,
            output: output, reasoning: 0, total: total)
        return (field(2), field(1) + ":" + field(2) + ":" + field(3), sample)
    }
}
