import Foundation
import SQLite3

struct AntigravitySample {
    let completedAt: Date
    let recordedCompletion: Date?
    let model: String
    let output: Int64
    let ttft: Double
    let stream: Double

    enum Basis {
        case stream, endToEnd

        var label: String {
            switch self {
            case .stream: return L10n.text("Streaming")
            case .endToEnd: return L10n.text("E2E fallback")
            }
        }
    }

    var elapsed: Double { ttft + stream }
    var endToEndTPS: Double { Double(output) / elapsed }
    var measurement: (tps: Double, basis: Basis) {
        // Check the recorded durations, not differences between rounded timestamps.
        if stream >= 0.12 {
            let streamingTPS = Double(output) / stream
            if streamingTPS > 0 && streamingTPS <= 3000 { return (streamingTPS, .stream) }
        }
        return (endToEndTPS, .endToEnd)
    }

    var details: String {
        L10n.text("End to end: %@ tok/s (%@) · TTFT: %@",
            Fmt.tps(endToEndTPS), Fmt.secs(elapsed), Fmt.secs(ttft))
    }
}

final class AntigravityReader: SpeedSourceReader {
    let source: SourceMode = .antigravity

    private enum StepType {
        static let user: Int32 = 14
        static let model: Int32 = 15
    }

    private enum StepStatus {
        static let pending: Set<Int32> = [1, 2, 8, 9, 11]
    }

    private enum StepMetaField {
        static let startedAt = 1
        static let completedAt = 7
    }

    private enum GenField {
        static let chat = 1
        static let stepIndices = 2
    }

    private enum ChatField {
        static let usage = 4
        static let ttft = 11
        static let stream = 12
        static let model = 21
    }

    private enum UsageField {
        static let outputTokens = 3
    }

    private struct Candidate { let id: String; let running: Bool; let title: String }
    private struct Step {
        let index: Int
        let type: Int32
        let status: Int32
        let start: Date?
        let end: Date?
        var date: Date? { end ?? start }
        var pending: Bool { StepStatus.pending.contains(status) }
    }
    private struct Generation {
        let sample: AntigravitySample
        let stepIndex: Int
        let pending: Bool
    }
    private struct Conversation {
        let generations: [Generation]
        let latestStep: Date?
        let userStep: Step?
        let pendingStep: Step?
    }
    private struct Selection {
        let id: String
        let path: String
        let conversation: Conversation
        let start: Date?
    }

    private(set) var samples: [AntigravitySample] = []
    private(set) var sessionID = ""
    private var selectedPath: String?
    private(set) var inFlightStart: Date?
    private(set) var inFlightMeasurement: AntigravitySample?
    private var inFlightActivity: Date?
    private(set) var databaseReadCount = 0
    private(set) var sessions: [SessionSummary] = []
    var available: Bool { !samples.isEmpty }
    var activityDate: Date { inFlightActivity ?? samples.last?.completedAt ?? .distantPast }
    var currentTPS: Double? { inFlightMeasurement?.measurement.tps }
    var hasOnceData: Bool { available || inFlightStart != nil }

    private let rootsProvider: () -> [String]
    private var summaryCaches: [String: SQLiteDatabaseCache<[Candidate]>] = [:]
    private var conversationCaches: [String: SQLiteDatabaseCache<Conversation>] = [:]

    static func defaultRoots(home: String = NSHomeDirectory(),
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             fileManager: FileManager = .default) -> [String] {
        let gemini = (home as NSString).appendingPathComponent(".gemini")
        var roots = ["antigravity", "antigravity-cli", "antigravity-ide"].map { "\(gemini)/\($0)" }
        let t3Home = environment["T3CODE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".t3")
        let t3Providers = ((t3Home as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent("userdata/providers/antigravity")
        if let entries = try? fileManager.contentsOfDirectory(atPath: t3Providers) {
            for entry in entries.sorted() {
                let candidate = "\(t3Providers)/\(entry)/antigravity-acp"
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                    roots.append(candidate)
                }
            }
        }
        return normalizeRoots(roots)
    }

    private static func normalizeRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
    }

    var summary: SpeedSummary {
        let recorded = inFlightMeasurement ?? samples.last
        return SpeedSummary(name: source.label, active: inFlightStart != nil, live: currentTPS,
            last: samples.last?.measurement.tps, completedAt: samples.last?.completedAt,
            history: samples.compactMap { sample in
                sample.recordedCompletion.map { CallHistoryPoint(completedAt: $0, speed: sample.measurement.tps) }
             }, model: recorded?.model ?? "",
            measurement: L10n.text("Latest recorded model-call speed, not live per-token speed."),
             sessions: sessions,
             metrics: recorded.map { CallMetrics(output: $0.output, firstToken: $0.ttft) })
    }

    var onceLines: [String] {
        var lines = ["session:   \(sessionID)", "responses: \(samples.count)", "active:    \(inFlightStart != nil)"]
        func append(_ prefix: String, _ label: String, _ sample: AntigravitySample) {
            let caption = L10n.text(label, sample.measurement.basis.label)
            lines.append("\(prefix) \(Fmt.tps(sample.measurement.tps)) tok/s  (\(caption))  output \(sample.output)")
            lines.append("details:   \(sample.details)")
        }
        if let sample = inFlightMeasurement {
            append("recorded: ", "This turn · %@", sample)
        } else if let sample = samples.last {
            append("last:     ", "Last completed · %@", sample)
        }
        return lines
    }

    func onceLines(now: Date = Date()) -> [String] { onceLines }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let currentSummary = summary
        let path = selectedPath ?? rootsProvider().first ?? ""
        let status = inFlightStart != nil ? "active" : (available ? "ready" : "no data")
        return SourceSnapshot(
            source: source,
            summary: currentSummary,
            activityDate: activityDate,
            inFlightStart: inFlightStart,
            liveSpeed: currentTPS,
            hasData: available || inFlightStart != nil,
            diagnostic: SourceDiagnostic(source: source, path: path, status: status, sampleCount: samples.count)
        )
    }

    convenience init() {
        self.init(rootsProvider: { Self.defaultRoots() })
    }

    convenience init(root: String) { self.init(roots: [root]) }

    convenience init(roots: [String]) {
        let normalized = Self.normalizeRoots(roots)
        self.init(rootsProvider: { normalized })
    }

    private init(rootsProvider: @escaping () -> [String]) {
        self.rootsProvider = rootsProvider
    }

    private func open(_ path: String) -> OpaquePointer? {
        databaseReadCount += 1
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 250)
        return db
    }

    private func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data? {
        let size = Int(sqlite3_column_bytes(stmt, column))
        guard size > 0, size <= 16 * 1024 * 1024, let ptr = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: ptr, count: size)
    }

    func poll(forceScan: Bool, now: Date) {
        poll(now: now)
    }

    func poll(now: Date = Date()) {
        inFlightStart = nil
        inFlightMeasurement = nil
        inFlightActivity = nil
        var active: Selection?
        var history: Selection?
        var visited = Set<String>()
        var hasCompleted = Set<String>()
        var readFailed = false
        var collectedSessions: [String: SessionSummary] = [:]
        func recent(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= -2 && age < 900
        }
        let roots = rootsProvider()
        for root in roots {
            let path = "\(root)/conversation_summaries.db"
            let listed = summaryCaches[root, default: .init()].read(path, load: loadCandidates)
            if listed == nil && (SQLiteDatabaseStamp(path) != nil
                || selectedPath?.hasPrefix("\(root)/conversations/") == true) { readFailed = true }
            let candidates = listed ?? []
            let directory = "\(root)/conversations"
            // If summaries lag or do not include a conversation yet, its own
            // recently written DB/WAL can still supply authoritative step status.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            let recentIDs = Set(files.compactMap { name -> String? in
                guard name.hasSuffix(".db") else { return nil }
                let id = String(name.dropLast(3))
                guard UUID(uuidString: id) != nil,
                      let stamp = SQLiteDatabaseStamp("\(directory)/\(name)"), recent(stamp.lastWrite) else { return nil }
                return id
            })
            func inspect(_ id: String, running: Bool, title: String) -> Bool {
                let path = "\(directory)/\(id).db"
                guard visited.insert(path).inserted else { return false }
                guard let conversation = conversationCaches[path, default: .init()].read(path, load: loadConversation) else {
                    // Summary rows can outlive the conversation DB.
                    if path == selectedPath || SQLiteDatabaseStamp(path) != nil { readFailed = true }
                    return false
                }
                let isActive = conversation.latestStep.map { recent($0) && (running || conversation.pendingStep != nil) } ?? false
                let start = isActive ? min(now, conversation.userStep?.start ?? conversation.pendingStep?.start ?? conversation.latestStep!) : nil
                if isActive, let latest = conversation.latestStep,
                   latest > (active?.conversation.latestStep ?? .distantPast) {
                    active = Selection(id: id, path: path, conversation: conversation, start: start)
                }
                let lastCompleted = conversation.generations.last(where: { !$0.pending })
                let currentSample: AntigravitySample?
                if isActive, let boundary = conversation.userStep?.index ?? conversation.pendingStep?.index {
                    currentSample = conversation.generations.last { $0.stepIndex >= boundary }?.sample
                } else {
                    currentSample = nil
                }
                let activityAt = max(isActive ? (conversation.latestStep ?? .distantPast) : .distantPast,
                                     lastCompleted?.sample.completedAt ?? .distantPast)
                if isActive || (lastCompleted != nil && now.timeIntervalSince(activityAt) <= SpeedSummary.multiSessionWindow) {
                    let entry = SessionSummary(
                        id: id,
                        title: SessionSummary.cleanTitle(title, fallback: id),
                        active: isActive,
                        live: currentSample?.measurement.tps,
                        last: lastCompleted?.sample.measurement.tps,
                        activityAt: activityAt,
                        inFlightStart: start
                    )
                    if let existing = collectedSessions[id] {
                        if (entry.active && !existing.active) || entry.activityAt > existing.activityAt {
                            collectedSessions[id] = entry
                        }
                    } else {
                        collectedSessions[id] = entry
                    }
                }
                if let last = lastCompleted {
                    hasCompleted.insert(path)
                    if last.sample.completedAt > (history?.conversation.generations.last(where: { !$0.pending })?.sample.completedAt ?? .distantPast) {
                        history = Selection(id: id, path: path, conversation: conversation, start: nil)
                    }
                    return true
                }
                return false
            }
            let listedIDs = Set(candidates.map(\.id))
            for (index, candidate) in candidates.enumerated()
                where index < 6 || candidate.running || recentIDs.contains(candidate.id) {
                _ = inspect(candidate.id, running: candidate.running, title: candidate.title)
            }
            for id in recentIDs.subtracting(listedIDs).sorted() {
                _ = inspect(id, running: false, title: "")
            }
            // Check ordered historical summaries only as far as the first one
            // with usable samples (or one already inspected).
            for candidate in candidates {
                let path = "\(directory)/\(candidate.id).db"
                if visited.contains(path) {
                    if hasCompleted.contains(path) { break }
                } else if inspect(candidate.id, running: candidate.running, title: candidate.title) { break }
            }
        }
        let activeRoots = Set(roots)
        summaryCaches = summaryCaches.filter { activeRoots.contains($0.key) }
        conversationCaches = conversationCaches.filter { visited.contains($0.key) }
        sessions = Array(collectedSessions.values)
        if let active {
            inFlightStart = active.start
            inFlightActivity = active.conversation.latestStep
            if let boundary = active.conversation.userStep?.index ?? active.conversation.pendingStep?.index {
                inFlightMeasurement = active.conversation.generations.last { $0.stepIndex >= boundary }?.sample
            }
            sessionID = active.id
            selectedPath = active.path
            samples = active.conversation.generations.filter { !$0.pending }.map(\.sample)
        } else if let history {
            let completed = history.conversation.generations.filter { !$0.pending }.map(\.sample)
            if readFailed, let existing = samples.last, let fallback = completed.last,
               existing.completedAt > fallback.completedAt { return }
            sessionID = history.id
            selectedPath = history.path
            samples = completed
        } else if !readFailed {
            sessionID = ""
            selectedPath = nil
            samples = []
            sessions = []
        }
    }

    private func loadCandidates(_ path: String) -> [Candidate]? {
        guard let summary = open(path) else { return nil }
        defer { sqlite3_close_v2(summary) }
        var hasTitle = false
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(summary, "PRAGMA table_info(conversation_summaries)", -1, &pragmaStmt, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(pragmaStmt, 1), String(cString: name) == "title" {
                    hasTitle = true
                    break
                }
            }
        }
        sqlite3_finalize(pragmaStmt)

        var statement: OpaquePointer?
        let titleColumn = hasTitle ? "COALESCE(title, '')" : "''"
        let sql = """
            SELECT conversation_id, status, \(titleColumn) FROM conversation_summaries
            WHERE status = 'CASCADE_RUN_STATUS_RUNNING' OR conversation_id IN
              (SELECT conversation_id FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 50)
            ORDER BY last_modified_time DESC
            """
        guard sqlite3_prepare_v2(summary, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var candidates: [Candidate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let id = String(cString: text)
                if UUID(uuidString: id) != nil {
                    let status = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                    let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                    candidates.append(Candidate(id: id, running: status == "CASCADE_RUN_STATUS_RUNNING", title: title))
                }
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? candidates : nil
    }

    private func loadConversation(_ path: String) -> Conversation? {
        guard let db = open(path) else { return nil }
        defer { sqlite3_close_v2(db) }
        // Both queries must observe the same SQLite snapshot.
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        var steps: [Int: Step] = [:]
        do {
            var stepQuery: OpaquePointer?
            let sql = "SELECT idx, metadata, step_type, status FROM steps ORDER BY idx DESC LIMIT 1000"
            let legacySQL = "SELECT idx, metadata, 0, 0 FROM steps ORDER BY idx DESC LIMIT 1000"
            guard sqlite3_prepare_v2(db, sql, -1, &stepQuery, nil) == SQLITE_OK
                    || sqlite3_prepare_v2(db, legacySQL, -1, &stepQuery, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stepQuery) }
            func timestamp(_ seconds: Double?) -> Date? {
                seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            }
            var result = sqlite3_step(stepQuery)
            while result == SQLITE_ROW {
                defer { result = sqlite3_step(stepQuery) }
                let index = Int(sqlite3_column_int64(stepQuery, 0))
                let proto = blob(stepQuery, 1).flatMap(ProtoFields.init)
                steps[index] = Step(index: index, type: sqlite3_column_int(stepQuery, 2), status: sqlite3_column_int(stepQuery, 3),
                    start: timestamp(proto?.duration(StepMetaField.startedAt)),
                    end: timestamp(proto?.duration(StepMetaField.completedAt)))
            }
            guard result == SQLITE_DONE else { return nil }
        }

        var found: [Generation] = []
        do {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 300", -1, &query, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(query) }
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                defer { result = sqlite3_step(query) }
                guard let data = blob(query, 0), let entry = ProtoFields(data),
                      let chat = entry.message(GenField.chat), let usage = chat.message(ChatField.usage),
                      let output = usage.integer(UsageField.outputTokens), output > 0, output <= UInt64(Int64.max),
                      let first = chat.generationDuration(ChatField.ttft),
                      let stream = chat.generationDuration(ChatField.stream), first + stream > 0,
                      let packed = entry.bytes(GenField.stepIndices), let indices = Self.packedIndices(packed),
                      let lastIndex = indices.max(), let step = steps[lastIndex], let end = step.date else { continue }
                let modelStep = indices.compactMap { steps[$0] }.filter { $0.type == StepType.model }.max { $0.index < $1.index } ?? step
                let model = chat.bytes(ChatField.model).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // The start-only fallback remains useful for session selection, but is not a history timestamp.
                let sample = AntigravitySample(completedAt: end, recordedCompletion: modelStep.end,
                    model: model, output: Int64(output), ttft: first, stream: stream)
                found.append(Generation(sample: sample, stepIndex: modelStep.index, pending: modelStep.pending))
            }
            guard result == SQLITE_DONE else { return nil }
        }

        let userStep = steps.values.filter { $0.type == StepType.user }.max { $0.index < $1.index }
        let lastClosedModel = steps.values.filter { $0.type == StepType.model && !$0.pending }.map(\.index).max() ?? -1
        // Ignore open rows left behind before the current user/model step.
        let pending = steps.values.filter { $0.type != StepType.user && $0.pending
            && $0.index > max(userStep?.index ?? -1, lastClosedModel) }.max { $0.index < $1.index }
        return Conversation(generations: found.reversed(), latestStep: steps.values.compactMap(\.date).max(),
            userStep: userStep, pendingStep: pending)
    }

    private static func packedIndices(_ data: Data) -> [Int]? {
        var value: UInt64 = 0, shift = 0
        var indices: [Int] = []
        for byte in data {
            guard shift <= 63, !(shift == 63 && byte > 1) else { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                guard value <= UInt64(Int.max) else { return nil }
                indices.append(Int(value)); value = 0; shift = 0
            } else { shift += 7 }
        }
        return shift == 0 ? indices : nil
    }
}
