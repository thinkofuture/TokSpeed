import AppKit
import Foundation
import SQLite3

// Cursor launches this executable directly as a hook. Handle that before
// AppKit starts so the collector is fast and never creates a visible app.
if CursorHook.runIfRequested() { exit(0) }

// MARK: - Model

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
}

enum CodexHome {
    static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return env }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static func newestRollout() -> URL? {
        var best: (url: URL, date: Date)?
        let fm = FileManager.default
        for dir in ["sessions", "archived_sessions"] {
            let root = (path as NSString).appendingPathComponent(dir)
            guard let walker = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".jsonl") && rel.contains("rollout-") {
                let full = (root as NSString).appendingPathComponent(rel)
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let mod = attrs[.modificationDate] as? Date else { continue }
                if best == nil || mod > best!.date { best = (URL(fileURLWithPath: full), mod) }
            }
        }
        return best?.url
    }
}

// MARK: - Incremental rollout reader

final class RolloutReader {
    private(set) var samples: [Sample] = []
    private(set) var model = ""
    private(set) var sessionID = ""
    private(set) var path = ""
    private(set) var inFlightStart: Date?
    private var turnOpen = false
    private var lastEventAt: Date?
    func isActive(at now: Date) -> Bool {
        guard turnOpen, let lastEventAt else { return false }
        return abs(now.timeIntervalSince(lastEventAt)) < 15 * 60
    }
    var turnActive: Bool { isActive(at: Date()) }
    private(set) var turnStart: Date?
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0

    /// 本次回复的实时速度 = 已完成调用的输出 token ÷ 这些调用的实际生成时间（不含工具执行）
    func liveTPS(now: Date = Date()) -> Double? {
        guard isActive(at: now), turnOutput > 0, turnGenSeconds > 0 else { return nil }
        return Double(turnOutput) / turnGenSeconds
    }

    private var offset: Int64 = 0
    private var remainder = Data()
    private var samplingStart: Date?
    private var firstGeneratedAt: Date?
    private var generatedEnd: Date?

    private let tailBytes: Int64 = 8 * 1024 * 1024

    func read(_ url: URL) {
        if url.path != path { reset(url) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size < offset { reset(url) }
        if size == offset { return }

        var from = offset
        if from == 0 && size > tailBytes { from = size - tailBytes }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(from))
            offset = from
            while true {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                consume(chunk)
            }
        } catch {
            return
        }
    }

    private func reset(_ url: URL) {
        path = url.path
        samples.removeAll()
        remainder = Data()
        offset = 0
        samplingStart = nil
        firstGeneratedAt = nil
        generatedEnd = nil
        model = ""
        sessionID = ""
        inFlightStart = nil
        turnOpen = false
        lastEventAt = nil
        turnStart = nil
        turnOutput = 0
        turnGenSeconds = 0
    }

    private func consume(_ chunk: Data) {
        remainder.append(chunk)
        // The file cursor includes buffered partial lines, not just parsed rows.
        offset += Int64(chunk.count)
        var cursor = remainder.startIndex
        while let nl = remainder[cursor...].firstIndex(of: 0x0A) {
            ingest(remainder[cursor..<nl])
            cursor = nl + 1
        }
        let consumedUpTo = cursor - remainder.startIndex
        if consumedUpTo > 0 {
            remainder = Data(remainder[cursor...])
        }
    }

    private func ingest(_ line: Data) {
        guard !line.isEmpty, let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let tsText = row["timestamp"] as? String,
              let ts = ISO8601DateFormatter.codex.date(from: tsText) else { return }
        let type = (row["type"] as? String) ?? ""
        let payload = (row["payload"] as? [String: Any]) ?? [:]
        let payloadType = (payload["type"] as? String) ?? ""
        lastEventAt = ts

        switch (type, payloadType) {
        case ("session_meta", _):
            if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty {
                sessionID = id
            }
        case ("turn_context", _):
            if let m = payload["model"] as? String { model = m }
            if generatedEnd == nil { samplingStart = ts }
            if !turnOpen { beginTurn(at: ts) }
        case ("event_msg", "task_started"):
            samplingStart = ts
            generatedEnd = nil
            firstGeneratedAt = nil
            beginTurn(at: ts)
        case ("event_msg", "user_message"):
            if generatedEnd == nil { samplingStart = ts }
            if !turnOpen { beginTurn(at: ts) }
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            turnOpen = false
            inFlightStart = nil
        case ("response_item", _):
            if isGenerated(payload) {
                if firstGeneratedAt == nil { firstGeneratedAt = ts }
                generatedEnd = ts
            } else if generatedEnd == nil && isInput(payload) {
                samplingStart = ts
            }
        case ("event_msg", "token_count"):
            let info = payload["info"] as? [String: Any]
            let usage = info?["last_token_usage"] as? [String: Any]
            if let usage,
               let start = samplingStart, let end = generatedEnd {
                let elapsed = end.timeIntervalSince(start)
                let output = usage.int64("output_tokens")
                let reasoning = usage.int64("reasoning_output_tokens")
                if elapsed > 0 && output > 0 {
                    samples.append(Sample(
                        startedAt: start,
                        completedAt: end,
                        firstOutputAt: firstGeneratedAt,
                        model: model,
                        input: usage.int64("input_tokens"),
                        cachedInput: usage.int64("cached_input_tokens"),
                        output: output,
                        reasoning: reasoning,
                        total: usage.int64("total_tokens")
                    ))
                    turnOutput += output
                    turnGenSeconds += elapsed
                }
            }
            samplingStart = ts
            generatedEnd = nil
            firstGeneratedAt = nil
        default:
            break
        }
        inFlightStart = (generatedEnd == nil && firstGeneratedAt == nil) ? samplingStart : nil
    }

    private func beginTurn(at ts: Date) {
        turnOpen = true
        turnStart = ts
        turnOutput = 0
        turnGenSeconds = 0
    }

    private func isGenerated(_ payload: [String: Any]) -> Bool {
        let type = (payload["type"] as? String) ?? ""
        if type == "reasoning" { return true }
        let role = (payload["role"] as? String) ?? ""
        if type == "message" && role == "assistant" { return true }
        return type.hasSuffix("_call")
    }

    private func isInput(_ payload: [String: Any]) -> Bool {
        let type = (payload["type"] as? String) ?? ""
        if type == "function_call_output" || type == "custom_tool_call_output" || type == "agent_message" { return true }
        let role = (payload["role"] as? String) ?? ""
        return type == "message" && (role == "user" || role == "developer" || role == "system")
    }

    var medianTPS: Double {
        let values = samples.map(\.effectiveTPS).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    var totalOutput: Int64 { samples.reduce(0) { $0 + $1.output } }
}

extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64 {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let i = self[key] as? Int64 { return i }
        if let i = self[key] as? Int { return Int64(i) }
        return 0
    }
}

extension ISO8601DateFormatter {
    static let codex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - OpenCode reader

struct OCSample {
    var messageID: String
    var model: String
    var input: Int64
    var output: Int64
    var reasoning: Int64
    var createdAt: Date
    var completedAt: Date
    var ttft: Double?
    let elapsed: Double
    let streamSeconds: Double?

    var measurementSeconds: Double { streamSeconds ?? elapsed }
    var effectiveTPS: Double { Double(output) / measurementSeconds }
    var basisLabel: String { L10n.text(streamSeconds == nil ? "E2E fallback" : "Streaming") }
}

final class OpenCodeReader {
    private var db: OpaquePointer?
    private var isV2 = false
    private let databasePath: String
    private(set) var samples: [OCSample] = []
    private(set) var sessionID = ""
    private(set) var directory = ""
    private(set) var inFlightStart: Date?
    private(set) var turnStart: Date?
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0

    /// This turn uses the same per-call durations as history, without gaps between calls.
    func liveTPS() -> Double? {
        guard inFlightStart != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
        return Double(turnOutput) / turnGenSeconds
    }

    static let dbPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/share/opencode/opencode.db")

    init(dbPath: String = OpenCodeReader.dbPath) { databasePath = dbPath }

    deinit { if db != nil { sqlite3_close_v2(db) } }

    func poll() {
        if db == nil { open() }
        guard db != nil else { return }
        guard let sid = latestSession() else { return }
        load(sid)
    }

    private func open() {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil)
        if rc != SQLITE_OK || handle == nil {
            if handle != nil { sqlite3_close_v2(handle) }
            return
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
    }

    private func query(_ sql: String, bind: String?) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, stmt != nil else { return nil }
        if let bind = bind {
            sqlite3_bind_text(stmt, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return stmt
    }

    private func latestSession() -> String? {
        // An empty/failed latest session must not hide an older usable history.
        // V2 stores sessions separately from the legacy V1 tables.
        var candidates: [(id: String, directory: String, updated: Int64, v2: Bool)] = []
        for v2 in [true, false] {
            let sessions = v2 ? "session_v2" : "session"
            let messages = v2 ? "session_message" : "message"
            let role = v2 ? "m.type = 'assistant'" : "json_extract(m.data,'$.role') = 'assistant'"
            let sql = """
                SELECT s.id, s.directory, s.time_updated FROM
                  (SELECT id, directory, time_updated FROM \(sessions) ORDER BY time_updated DESC LIMIT 50) s
                WHERE EXISTS (SELECT 1 FROM \(messages) m WHERE m.session_id = s.id AND \(role)
                  AND (coalesce(json_extract(m.data,'$.tokens.output'),0) > 0
                    OR (json_extract(m.data,'$.time.completed') IS NULL
                      AND m.time_created > (strftime('%s','now') - 900) * 1000)))
                ORDER BY s.time_updated DESC LIMIT 1
                """
            guard let stmt = query(sql, bind: nil) else { continue }
            if sqlite3_step(stmt) == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0) {
                candidates.append((String(cString: id), sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "", sqlite3_column_int64(stmt, 2), v2))
            }
            sqlite3_finalize(stmt)
        }
        guard let selected = candidates.max(by: { $0.updated < $1.updated }) else {
            sessionID = ""; directory = ""; samples = []; inFlightStart = nil
            turnStart = nil; turnOutput = 0; turnGenSeconds = 0
            return nil
        }
        if selected.id != sessionID || selected.v2 != isV2 {
            samples = []
        }
        sessionID = selected.id
        directory = selected.directory
        isV2 = selected.v2
        return selected.id
    }

    private func load(_ sid: String) {
        let messageTable = isV2 ? "session_message" : "message"
        let role = isV2 ? "type = 'assistant'" : "json_extract(data,'$.role') = 'assistant'"
        // SQLite also coerces JSON strings and booleans to numbers on read. They are
        // not valid timestamps. Read all V2 bounds from the same message, not parts.
        func timestamp(_ key: String) -> String {
            let path = "'$.time.\(key)'"
            return "CASE WHEN json_type(data,\(path)) IN ('integer','real') THEN json_extract(data,\(path)) END"
        }
        let sql = """
            SELECT id,
                   json_extract(data,'$.tokens.output'),
                   json_extract(data,'$.tokens.reasoning'),
                   json_extract(data,'$.tokens.input'),
                   coalesce(json_extract(data,'$.model.id'),json_extract(data,'$.modelID')),
                   \(timestamp("created")),
                   \(timestamp("completed")),
                   \(isV2 ? timestamp("firstToken") : "NULL"),
                   \(isV2 ? timestamp("streamed") : "NULL"),
                   json_extract(data,'$.time.completed') IS NULL
            FROM \(messageTable)
            WHERE session_id = ? AND \(role)
            ORDER BY time_created DESC LIMIT 300
            """
        guard let stmt = query(sql, bind: sid) else { closeOnError(); return }
        var collected: [OCSample] = []
        var inflight: Date?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_double(stmt, 5)
            guard created.isFinite, created > 0 else { continue }
            let createdAt = Date(timeIntervalSince1970: created / 1000)
            if sqlite3_column_int(stmt, 9) != 0 {
                let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let age = Date().timeIntervalSince(createdAt)
                if !model.isEmpty && age >= 0 && age < 900 && inflight == nil { inflight = createdAt }
                continue
            }
            let completed = sqlite3_column_double(stmt, 6)
            let output = sqlite3_column_int64(stmt, 1)
            guard output > 0, completed.isFinite, completed > created else { continue }
            let first = sqlite3_column_double(stmt, 7)
            let streamed = sqlite3_column_double(stmt, 8)
            let stream = (streamed - first) / 1000
            // Match Antigravity's minimum duration and plausible rate limits.
            let streamTPS = stream > 0 ? Double(output) / stream : 0
            let validStream = created <= first && streamed <= completed
                && stream >= 0.12 && streamTPS > 0 && streamTPS <= 3000
            var sample = OCSample(
                messageID: String(cString: sqlite3_column_text(stmt, 0)),
                model: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                input: sqlite3_column_int64(stmt, 3),
                output: output,
                reasoning: sqlite3_column_int64(stmt, 2),
                createdAt: createdAt,
                completedAt: Date(timeIntervalSince1970: completed / 1000),
                ttft: created <= first && first <= completed ? (first - created) / 1000 : nil,
                elapsed: (completed - created) / 1000,
                streamSeconds: validStream ? stream : nil
            )
            if !isV2, let first = firstOutputTime(sample.messageID) {
                sample.ttft = first.timeIntervalSince(createdAt)
            }
            collected.append(sample)
        }
        sqlite3_finalize(stmt)
        collected.reverse()
        samples = collected
        inFlightStart = inflight
        computeCurrentTurn()
    }

    /// 以最近一条 user 消息为界，统计本次回复已完成的调用
    private func computeCurrentTurn() {
        let sql = isV2
            ? "SELECT MAX(time_created) FROM session_message WHERE session_id = ? AND type = 'user'"
            : "SELECT MAX(time_created) FROM message WHERE session_id = ? AND json_extract(data,'$.role') = 'user'"
        guard let stmt = query(sql, bind: sessionID) else { return }
        var lastUser = 0.0
        if sqlite3_step(stmt) == SQLITE_ROW {
            lastUser = Double(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)

        let boundary = lastUser > 0 ? Date(timeIntervalSince1970: lastUser / 1000) : Date.distantPast
        if let inflight = inFlightStart,
           inflight < boundary || samples.contains(where: { $0.createdAt > inflight }) {
            inFlightStart = nil
        }
        var total: Int64 = 0
        var gen: Double = 0
        var start: Date?
        for s in samples where s.createdAt > boundary {
            if start == nil { start = s.createdAt }
            total += s.output
            gen += s.measurementSeconds
        }
        turnStart = start
        turnOutput = total
        turnGenSeconds = gen
    }

    private func firstOutputTime(_ messageID: String) -> Date? {
        let sql = """
            SELECT MIN(json_extract(data,'$.time.start')) FROM part
            WHERE message_id = ? AND json_extract(data,'$.type') IN ('text','reasoning')
            """
        guard let stmt = query(sql, bind: messageID) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let ms = sqlite3_column_int64(stmt, 0)
        return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil
    }

    private func closeOnError() {
        sqlite3_close_v2(db)
        db = nil
    }

    var medianTPS: Double {
        let values = samples.map(\.effectiveTPS).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    var totalOutput: Int64 { samples.reduce(0) { $0 + $1.output } }

    var summary: SpeedSummary {
        SpeedSummary(name: SourceMode.opencode.label, active: inFlightStart != nil,
            live: liveTPS(), last: samples.last?.effectiveTPS, completedAt: samples.last?.completedAt,
            history: samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: $0.effectiveTPS) }, model: samples.last?.model ?? "",
            measurement: L10n.text("Completed calls: streaming speed when available, otherwise end to end. This turn combines those calls without the time between them."))
    }

    var onceLines: [String] {
        var lines = ["session:   \(sessionID)", "responses: \(samples.count)"]
        if let sample = samples.last {
            lines.append("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s  (\(sample.basisLabel))")
        }
        lines.append("live:      \(liveTPS().map { Fmt.tps($0) } ?? "-") tok/s  turn output \(turnOutput)")
        return lines
    }
}

// MARK: - Antigravity reader

// Minimal, bounds-checked protobuf reader. Only fields used below are decoded;
// prompts, tool arguments and other conversation content are never interpreted.
private struct ProtoFields {
    struct Field { let number: Int; let integer: UInt64?; let bytes: Data? }
    let fields: [Field]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                if shift == 63 && byte > 1 { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        var result: [Field] = []
        while index < bytes.count {
            guard let tag = varint(), tag >> 3 > 0, tag >> 3 <= UInt64(Int.max) else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                result.append(Field(number: number, integer: value, bytes: nil))
            case 2:
                guard let size = varint(), size <= UInt64(bytes.count - index) else { return nil }
                let end = index + Int(size)
                result.append(Field(number: number, integer: nil, bytes: Data(bytes[index..<end])))
                index = end
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard size <= bytes.count - index else { return nil }
                index += size
            default: return nil
            }
        }
        fields = result
    }

    func integer(_ n: Int) -> UInt64? { fields.first { $0.number == n }?.integer }
    func bytes(_ n: Int) -> Data? { fields.first { $0.number == n }?.bytes }
    func message(_ n: Int) -> ProtoFields? { bytes(n).flatMap(ProtoFields.init) }
    func duration(_ n: Int) -> Double? {
        guard let value = message(n) else { return nil }
        let rawSeconds = value.integer(1) ?? 0
        let nanos = Double(value.integer(2) ?? 0)
        guard rawSeconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        return Double(rawSeconds) + nanos / 1_000_000_000
    }

    func generationDuration(_ n: Int) -> Double? {
        // Protobuf writers may omit a zero-valued duration.
        fields.contains { $0.number == n } ? duration(n) : 0
    }
}

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

// The writer can commit repeatedly into a preallocated WAL without changing the
// main database or WAL size. Check timestamps and identity for both files.
private struct SQLiteDatabaseStamp: Equatable {
    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private let database: FileStamp
    private let wal: FileStamp?

    var lastWrite: Date {
        func modified(_ file: FileStamp) -> Date {
            Date(timeIntervalSince1970: Double(file.modifiedSeconds) + Double(file.modifiedNanos) / 1e9)
        }
        // Opening a read-only SQLite handle can create an empty WAL. Only
        // count a WAL with frames as evidence for which databases to inspect.
        return max(modified(database), wal.flatMap { $0.size > 32 ? modified($0) : nil } ?? .distantPast)
    }

    init?(_ path: String) {
        guard let database = FileStamp(path) else { return nil }
        self.database = database
        wal = FileStamp(path + "-wal")
    }
}

struct SQLiteDatabaseCache<Value> {
    private var entry: (stamp: SQLiteDatabaseStamp, value: Value)?

    mutating func read(_ path: String, load: (String) -> Value?) -> Value? {
        let before = SQLiteDatabaseStamp(path)
        if let entry, entry.stamp == before { return entry.value }
        entry = nil
        guard let before, let value = load(path) else { return nil }
        // If a writer raced the read, revisit it next tick rather than caching
        // a snapshot under the newer stamp. Failed reads are also retried.
        if before == SQLiteDatabaseStamp(path) { entry = (before, value) }
        return value
    }
}

final class AntigravityReader {
    private struct Candidate { let id: String; let running: Bool }
    private struct Step {
        let index: Int
        let type: Int32
        let status: Int32
        let start: Date?
        let end: Date?
        var date: Date? { end ?? start }
        var pending: Bool { [1, 2, 8, 9, 11].contains(status) }
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
    var available: Bool { !samples.isEmpty }
    var activityDate: Date { inFlightActivity ?? samples.last?.completedAt ?? .distantPast }
    var currentTPS: Double? { inFlightMeasurement?.measurement.tps }

    private let roots: [String]
    private var summaryCaches: [String: SQLiteDatabaseCache<[Candidate]>] = [:]
    private var conversationCaches: [String: SQLiteDatabaseCache<Conversation>] = [:]

    var summary: SpeedSummary {
        SpeedSummary(name: SourceMode.antigravity.label, active: inFlightStart != nil, live: currentTPS,
            last: samples.last?.measurement.tps, completedAt: samples.last?.completedAt,
            history: samples.compactMap { sample in
                sample.recordedCompletion.map { CallHistoryPoint(completedAt: $0, speed: sample.measurement.tps) }
            }, model: samples.last?.model ?? "",
            measurement: L10n.text("Latest recorded model-call speed, not live per-token speed."))
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

    convenience init() {
        let gemini = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
        self.init(roots: ["antigravity", "antigravity-cli", "antigravity-ide"].map { "\(gemini)/\($0)" })
    }

    convenience init(root: String) { self.init(roots: [root]) }

    init(roots: [String]) {
        var seen = Set<String>()
        self.roots = roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
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

    func poll(now: Date = Date()) {
        inFlightStart = nil
        inFlightMeasurement = nil
        inFlightActivity = nil
        var active: Selection?
        var history: Selection?
        var visited = Set<String>()
        var hasCompleted = Set<String>()
        var readFailed = false
        func recent(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= -2 && age < 900
        }
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
            func inspect(_ id: String, running: Bool) -> Bool {
                let path = "\(directory)/\(id).db"
                guard visited.insert(path).inserted else { return false }
                guard let conversation = conversationCaches[path, default: .init()].read(path, load: loadConversation) else {
                    // Summary rows can outlive the conversation DB.
                    if path == selectedPath || SQLiteDatabaseStamp(path) != nil { readFailed = true }
                    return false
                }
                if let latest = conversation.latestStep, recent(latest), running || conversation.pendingStep != nil,
                   latest > (active?.conversation.latestStep ?? .distantPast) {
                    let start = conversation.userStep?.start ?? conversation.pendingStep?.start ?? latest
                    active = Selection(id: id, path: path, conversation: conversation, start: min(now, start))
                }
                if let last = conversation.generations.last(where: { !$0.pending }) {
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
                where index < 4 || candidate.running || recentIDs.contains(candidate.id) {
                _ = inspect(candidate.id, running: candidate.running)
            }
            for id in recentIDs.subtracting(listedIDs).sorted() {
                _ = inspect(id, running: false)
            }
            // Check ordered historical summaries only as far as the first one
            // with usable samples (or one already inspected).
            for candidate in candidates {
                let path = "\(directory)/\(candidate.id).db"
                if visited.contains(path) {
                    if hasCompleted.contains(path) { break }
                } else if inspect(candidate.id, running: candidate.running) { break }
            }
        }
        conversationCaches = conversationCaches.filter { visited.contains($0.key) }
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
        }
    }

    private func loadCandidates(_ path: String) -> [Candidate]? {
        guard let summary = open(path) else { return nil }
        defer { sqlite3_close_v2(summary) }
        var statement: OpaquePointer?
        let sql = """
            SELECT conversation_id, status FROM conversation_summaries
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
                    candidates.append(Candidate(id: id, running: status == "CASCADE_RUN_STATUS_RUNNING"))
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

        var steps: [Int: Step] = [:]
        var stepQuery: OpaquePointer?
        let sql = "SELECT idx, metadata, step_type, status FROM steps ORDER BY idx DESC LIMIT 1000"
        let legacySQL = "SELECT idx, metadata, 0, 0 FROM steps ORDER BY idx DESC LIMIT 1000"
        guard sqlite3_prepare_v2(db, sql, -1, &stepQuery, nil) == SQLITE_OK
                || sqlite3_prepare_v2(db, legacySQL, -1, &stepQuery, nil) == SQLITE_OK else { return nil }
        func timestamp(_ seconds: Double?) -> Date? {
            seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        }
        var result = sqlite3_step(stepQuery)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(stepQuery) }
            let index = Int(sqlite3_column_int64(stepQuery, 0))
            let proto = blob(stepQuery, 1).flatMap(ProtoFields.init)
            steps[index] = Step(index: index, type: sqlite3_column_int(stepQuery, 2), status: sqlite3_column_int(stepQuery, 3),
                start: timestamp(proto?.duration(1)), end: timestamp(proto?.duration(7)))
        }
        sqlite3_finalize(stepQuery)
        guard result == SQLITE_DONE else { return nil }

        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 300", -1, &query, nil) == SQLITE_OK else { return nil }
        var found: [Generation] = []
        result = sqlite3_step(query)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(query) }
            guard let data = blob(query, 0), let entry = ProtoFields(data),
                  let chat = entry.message(1), let usage = chat.message(4),
                  let output = usage.integer(3), output > 0, output <= UInt64(Int64.max),
                  let first = chat.generationDuration(11), let stream = chat.generationDuration(12), first + stream > 0,
                  let packed = entry.bytes(2), let indices = Self.packedIndices(packed),
                  let lastIndex = indices.max(), let step = steps[lastIndex], let end = step.date else { continue }
            let modelStep = indices.compactMap { steps[$0] }.filter { $0.type == 15 }.max { $0.index < $1.index } ?? step
            let model = chat.bytes(21).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // The start-only fallback remains useful for session selection, but is not a history timestamp.
            let sample = AntigravitySample(completedAt: end, recordedCompletion: modelStep.end,
                model: model, output: Int64(output), ttft: first, stream: stream)
            found.append(Generation(sample: sample, stepIndex: modelStep.index, pending: modelStep.pending))
        }
        sqlite3_finalize(query)
        guard result == SQLITE_DONE else { return nil }
        let userStep = steps.values.filter { $0.type == 14 }.max { $0.index < $1.index }
        let lastClosedModel = steps.values.filter { $0.type == 15 && !$0.pending }.map(\.index).max() ?? -1
        // Ignore open rows left behind before the current user/model step.
        let pending = steps.values.filter { $0.type != 14 && $0.pending
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

// MARK: - Formatting

// Claude Code records API request start times and one or more blocks per response.
// Only the first block is used: subsequent blocks repeat the same usage and may
// be written after tool execution has already started.
final class ClaudeReader {
    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var inFlightStart: Date?
    private(set) var path = ""
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0

    // Completed calls within the current user turn, excluding tool execution.
    func liveTPS() -> Double? {
        guard inFlightStart != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
        return Double(turnOutput) / turnGenSeconds
    }

    static var home: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        return (env?.isEmpty == false ? env! : (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
    }

    func poll() {
        let root = (Self.home as NSString).appendingPathComponent("projects")
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return }
        var newest: (String, Date)?
        for case let rel as String in enumerator where rel.hasSuffix(".jsonl") && !rel.contains("/subagents/") {
            let file = (root as NSString).appendingPathComponent(rel)
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date else { continue }
            if newest == nil || date > newest!.1 { newest = (file, date) }
        }
        guard let file = newest?.0, let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return }
        path = file
        var starts: [String: Date] = [:]
        var seen = Set<String>()
        var found: [Sample] = []
        var pending: Date?
        var id = ""
        var turnStarted = false
        var turnOutput: Int64 = 0
        var turnSeconds = 0.0
        for line in data.split(separator: 10) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let text = row["timestamp"] as? String,
                  let ts = ISO8601DateFormatter.codex.date(from: text) else { continue }
            if let value = row["sessionId"] as? String { id = value }
            if row["isSidechain"] as? Bool == true { continue }
            switch row["type"] as? String {
            case "user":
                let message = row["message"] as? [String: Any] ?? [:]
                let content = message["content"]
                let blocks = content as? [[String: Any]]
                let toolResult = blocks?.contains { ($0["type"] as? String) == "tool_result" } ?? false
                if !toolResult && (content is String || blocks != nil), row["isMeta"] as? Bool != true {
                    turnStarted = true
                    turnOutput = 0
                    turnSeconds = 0
                    pending = nil
                }
            case "api-request":
                if let request = row["id"] as? String { starts[request] = ts; pending = ts }
            case "assistant":
                guard let message = row["message"] as? [String: Any],
                      let messageID = message["id"] as? String,
                      !seen.contains(messageID),
                      let ref = row["requestRef"] as? String, let start = starts[ref],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let output = usage.int64("output_tokens")
                guard output > 0, ts > start else { continue }
                seen.insert(messageID)
                if pending == start { pending = nil }
                let details = usage["output_tokens_details"] as? [String: Any] ?? [:]
                let input = usage.int64("input_tokens")
                found.append(Sample(startedAt: start, completedAt: ts, firstOutputAt: nil,
                    model: message["model"] as? String ?? "", input: input,
                    cachedInput: usage.int64("cache_read_input_tokens"), output: output,
                    reasoning: details.int64("thinking_tokens"), total: input + output))
                if turnStarted {
                    turnOutput += output
                    turnSeconds += ts.timeIntervalSince(start)
                }
            default: break
            }
        }
        sessionID = id
        samples = found.sorted { $0.completedAt < $1.completedAt }
        inFlightStart = pending.flatMap { Date().timeIntervalSince($0) < 900 ? $0 : nil }
        self.turnOutput = turnOutput
        turnGenSeconds = turnSeconds
    }

    var medianTPS: Double {
        let values = samples.map(\.effectiveTPS).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }
}

enum Fmt {
    static func tps(_ v: Double) -> String { String(format: v > 10 ? "%.0f" : "%.1f", v) }
    static func secs(_ v: Double) -> String { String(format: "%.2fs", v) }
    static func int(_ v: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
    static func statusTitle(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        if text.isEmpty { return NSAttributedString(string: "") }
        return NSAttributedString(string: " " + text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

// MARK: - App

enum SourceMode: String {
    case auto, codex, opencode, claude, antigravity, hermes, cursor, t3code

    var label: String {
        switch self {
        case .auto: return L10n.text("Automatic")
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .hermes: return "Hermes"
        case .cursor: return "Cursor"
        case .t3code: return "T3 Code"
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
        case .t3code: return "square.stack.3d.up"
        }
    }
}

enum ToolOrder {
    // A static popularity-oriented default, not a measured or network-fetched ranking.
    static let popular: [SourceMode] = [.claude, .codex, .opencode, .antigravity, .hermes, .cursor, .t3code]

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

enum ProviderLogo {
    private static var cache: [SourceMode: NSImage] = [:]

    static func image(_ source: SourceMode) -> NSImage? {
        if source == .auto { return nil }
        if let image = cache[source] { return image }
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("Logos")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Logos")
        let urls = [bundle, development].compactMap { $0?.appendingPathComponent("\(source.rawValue).svg") }
        guard let svg = urls.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first,
              let path = path(svg) else { return nil }
        let bounds = path.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 16 / max(bounds.width, bounds.height)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = AffineTransform(
                m11: scale, m12: 0, m21: 0, m22: -scale,
                tX: (18 - bounds.width * scale) / 2 - bounds.minX * scale,
                tY: (18 - bounds.height * scale) / 2 + bounds.maxY * scale)
            let rendered = path.copy() as! NSBezierPath
            rendered.transform(using: transform)
            NSColor.black.setFill()
            rendered.fill()
            return true
        }
        image.isTemplate = true
        cache[source] = image
        return image
    }

    // These bundled monochrome marks use one path and absolute M/L/H/V/C/Z
    // commands only. Decode that known subset without a web view or dependency.
    private static func path(_ svg: String) -> NSBezierPath? {
        guard let range = svg.range(of: #"\bd="([^"]+)""#, options: .regularExpression) else { return nil }
        let attribute = String(svg[range])
        let data = String(attribute.dropFirst(3).dropLast())
        let pattern = #"[MLHVCZ]|[-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(data.startIndex..., in: data)
        let residue = regex.stringByReplacingMatches(in: data, range: fullRange, withTemplate: "")
        guard residue.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).isEmpty else { return nil }
        let tokens = regex.matches(in: data, range: fullRange).map { String(data[Range($0.range, in: data)!]) }
        let path = NSBezierPath()
        path.windingRule = svg.contains("evenodd") ? .evenOdd : .nonZero
        var i = 0
        func number() -> CGFloat? {
            guard i < tokens.count, let value = Double(tokens[i]), value.isFinite else { return nil }
            i += 1
            return CGFloat(value)
        }
        func point() -> NSPoint? {
            guard let x = number(), let y = number() else { return nil }
            return NSPoint(x: x, y: y)
        }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": guard let p = point() else { return nil }; path.move(to: p)
            case "L": guard let p = point() else { return nil }; path.line(to: p)
            case "H": guard let x = number() else { return nil }; path.line(to: NSPoint(x: x, y: path.currentPoint.y))
            case "V": guard let y = number() else { return nil }; path.line(to: NSPoint(x: path.currentPoint.x, y: y))
            case "C":
                guard let a = point(), let b = point(), let end = point() else { return nil }
                path.curve(to: end, controlPoint1: a, controlPoint2: b)
            case "Z": path.close()
            default: return nil
            }
        }
        return path.isEmpty ? nil : path
    }
}

// MARK: - Compact speed panel

struct CallHistoryPoint: Equatable {
    let completedAt: Date
    let speed: Double

    var isValid: Bool { completedAt.timeIntervalSinceReferenceDate.isFinite && speed.isFinite && speed > 0 }
}

struct SpeedSummary {
    static let historyLimit = 60
    let name: String
    let active: Bool
    let live: Double?
    let last: Double?
    let completedAt: Date?
    let history: [CallHistoryPoint]
    let model: String
    let measurement: String

    var current: Double? { active ? StatusDisplay.validSpeed(live) : nil }
    var value: String { (current ?? StatusDisplay.validSpeed(last)).map(Fmt.tps) ?? "—" }
    var recent: [CallHistoryPoint] {
        Array(history.filter(\.isValid).sorted { $0.completedAt < $1.completedAt }.suffix(Self.historyLimit))
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

    var tooltip: String {
        let identity = model.isEmpty ? name : "\(name) · \(model)"
        return "\(identity)\n\(measurement)"
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

        var strokeWidth: CGFloat { active ? 3.6 : 2.8 }
        var ink: NSColor {
            let color = PanelStyle.color(active: true)
            return active ? color : color.withAlphaComponent(0.28)
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
    var onHover: ((Reading?) -> Void)?
    private var hoverLocation: NSPoint?
    private var hoverTracking: NSTrackingArea?
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

    func update(_ series: [Series]) {
        let populated = Self.windowed(series)
        guard self.series != populated else { return }
        self.series = populated
        emptyLabel.isHidden = !populated.isEmpty
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let readings = populated.map { entry in
            let history = entry.samples.map { "\(formatter.string(from: $0.completedAt)): \(Fmt.tps($0.speed))" }
            let state = entry.active ? L10n.text("Active") : L10n.text("Idle")
            return "\(entry.source.label) (\(state)): \(history.joined(separator: ", "))"
        }
        setAccessibilityValue(readings.isEmpty ? L10n.text("No completed calls yet") : readings.joined(separator: "; "))
        track(at: hoverLocation)
        needsDisplay = true
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
        let reading = location.flatMap { Self.nearestReading(to: $0, series: series, in: bounds) }
        guard reading != hoveredReading else { return }
        hoveredReading = reading
        onHover?(reading)
    }

    static func nearestReading(to location: NSPoint, series: [Series], in bounds: NSRect) -> Reading? {
        guard bounds.contains(location) else { return nil }
        var best: Reading?
        var distance: CGFloat = 16
        // At equal distances prefer the foreground (drawn last) and then the newer point.
        for (_, segments) in zip(series, visibleReadings(series, in: bounds)).reversed().sorted(by: { $0.0.active && !$1.0.active }) {
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
        let plots = Self.visibleReadings(series, in: bounds).map { $0.map { $0.map(\.position) } }
        let layers = zip(series, plots)
        for isActive in [false, true] {
            let group = layers.filter { $0.0.active == isActive }
            for (entry, segments) in group {
                drawTrace(entry, segments: segments)
            }
        }
    }

    private func drawTrace(_ entry: Series, segments: [[NSPoint]]) {
        let path = Self.linePath(segments)
        path.lineWidth = entry.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        entry.ink.set()
        path.stroke()
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

// Custom views keep live values aligned without treating summaries as commands.
// Their slots stay fixed while NSMenu tracks; a drop rebinds the sources in place.
final class SummaryMenuView: NSView {
    private(set) var source: SourceMode
    var onDrag: ((SummaryMenuView, NSEvent) -> Void)? {
        didSet {
            setAccessibilityHelp(onDrag == nil ? nil : L10n.text("Drag to reorder"))
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var isDragging = false {
        didSet { subviews.forEach { $0.alphaValue = isDragging ? 0.35 : 1 }; needsDisplay = true }
    }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private let valueLabel = NSTextField(labelWithString: "—")
    private let icon = NSImageView()
    private let classicName: NSTextField?
    private let classicTrend: ClassicTrendView?
    override var allowsVibrancy: Bool { false }

    init(source: SourceMode, frame: NSRect, layout: PanelLayout = .chart) {
        self.source = source
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
            icon.frame.origin = NSPoint(x: 0, y: 17)
            classicName.frame = NSRect(x: 26, y: 16, width: 124, height: 20)
            classicName.font = .systemFont(ofSize: 13, weight: .medium)
            classicName.lineBreakMode = .byTruncatingTail
            classicName.setAccessibilityElement(false)
            addSubview(classicName)
            addSubview(classicTrend)
            valueLabel.frame = NSRect(x: 258, y: 15, width: bounds.width - 258, height: 22)
            valueLabel.alignment = .right
        }
        icon.setAccessibilityElement(false)
        bind(source)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func bind(_ source: SourceMode) {
        self.source = source
        classicName?.stringValue = source.label
        icon.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and the logo must behave like the rest of the card.
        let hit = super.hitTest(point)
        return onDrag != nil && hit != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) { onDrag?(self, event) }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDrag != nil { addCursorRect(bounds, cursor: .openHand) }
    }

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
        isDragging = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered && onDrag != nil && !isDragging {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                xRadius: 7, yRadius: 7).fill()
        }
    }

    private(set) var summary: SpeedSummary?

    func update(_ summary: SpeedSummary) {
        self.summary = summary
        let color = PanelStyle.color(active: summary.active)
        icon.contentTintColor = color
        valueLabel.textColor = color
        classicName?.textColor = color
        classicTrend?.update(summary.recent, active: summary.active)
        valueLabel.stringValue = summary.value
        let state = summary.active ? L10n.text("Active") : L10n.text("Idle")
        let caption = source == .antigravity && summary.current != nil ? L10n.text("Recorded") : summary.caption()
        setAccessibilityLabel(summary.value == "—"
            ? L10n.text("%@, %@, %@", summary.name, state, caption)
            : L10n.text("%@, %@, %@, %@ tokens per second", summary.name, state, caption, summary.value))
    }
}

final class ClassicTrendView: NSView {
    private var speeds: [Double] = []
    private var active = false
    override var allowsVibrancy: Bool { false }

    func update(_ points: [CallHistoryPoint], active: Bool) {
        let speeds = CallHistoryView.withoutIsolatedSpikes(points).suffix(12).map(\.speed)
        guard self.speeds != speeds || self.active != active else { return }
        self.speeds = speeds
        self.active = active
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
        let style = CallHistoryView.Series(source: .auto, active: active, samples: [])
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
    private let number = NumberFormatter()

    init(locale: Locale) {
        time.locale = locale
        time.setLocalizedDateFormatFromTemplate("jm")
        dateTime.locale = locale
        dateTime.setLocalizedDateFormatFromTemplate("MMMdjm")
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
        let full = DateFormatter()
        full.locale = time.locale
        full.setLocalizedDateFormatFromTemplate("yMMMdjm")
        return full.string(from: date)
    }

    func speed(_ speed: Double) -> String {
        let digits = speed > 10 ? 0 : 1
        number.minimumFractionDigits = digits
        number.maximumFractionDigits = digits
        return number.string(from: NSNumber(value: speed)) ?? Fmt.tps(speed)
    }
}

final class SpeedPanelView: NSView {
    static let legendHeight: CGFloat = 52
    static let chartY = legendHeight + 8
    static let height = chartY + PanelStyle.plotHeight + 28

    let chart: CallHistoryView
    let cards: [SummaryMenuView]
    let layout: PanelLayout
    private let readout = NSTextField(labelWithString: "")
    private let readoutFormatter = ChartReadoutFormatter(locale: Locale(identifier: L10n.language))
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
        cards.forEach { addSubview($0) }
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
        chart.onHover = { [weak self] reading in
            guard let self else { return }
            guard let reading else { self.readout.stringValue = ""; return }
            self.readout.stringValue = L10n.text("%@ · %@ · %@ tok/s", reading.source.label,
                self.readoutFormatter.timestamp(reading.sample.completedAt),
                self.readoutFormatter.speed(reading.sample.speed))
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(_ summaries: [SourceMode: SpeedSummary]) {
        let series: [CallHistoryView.Series] = cards.compactMap { card in
            guard let summary = summaries[card.source] else { return nil }
            card.update(summary)
            return CallHistoryView.Series(source: card.source, active: summary.active, samples: summary.recent)
        }
        if layout == .chart { chart.update(series) }
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
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 2
    static let height = PanelActionButton.side + topPadding + bottomPadding
    override var allowsVibrancy: Bool { false }

    init(settings: NSMenuItem, quit: NSMenuItem) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: Self.height))
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults: UserDefaults
    private let detectInstalledTools: () -> Set<SourceMode>
    private var installedSources: Set<SourceMode>
    private let reader = RolloutReader()
    private let oc = OpenCodeReader()
    private let claude = ClaudeReader()
    private let antigravity = AntigravityReader()
    private let hermes = HermesReader()
    private let cursor = CursorReader()
    private let t3 = T3CodeReader()
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var lastScan = Date.distantPast
    private var lastOpenCodePoll = Date.distantPast
    private var lastCursorHookAttempt = Date.distantPast
    private var cursorHookReady = false
    var selftest = false
    private var currentSymbol = "-"
    private weak var speedPanel: SpeedPanelView?
    private var settingsController: SettingsWindowController?

    private var settingsState: SettingsState {
        SettingsState(sources: toolOrder, source: effectiveMode, display: display, layout: panelLayout)
    }

    init(defaults: UserDefaults = .standard, detectInstalledTools: @escaping () -> Set<SourceMode> = { InstalledTools.detect() }) {
        self.defaults = defaults
        self.detectInstalledTools = detectInstalledTools
        self.installedSources = detectInstalledTools()
        super.init()
    }

    private var mode: SourceMode {
        get { SourceMode(rawValue: defaults.string(forKey: "sourceMode") ?? "auto") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "sourceMode") }
    }

    private var display: StatusDisplay {
        get { StatusDisplay(rawValue: defaults.string(forKey: "statusDisplay") ?? "") ?? .speedAndUnit }
        set { defaults.set(newValue.rawValue, forKey: "statusDisplay") }
    }

    private var panelLayout: PanelLayout {
        get { PanelLayout(rawValue: defaults.string(forKey: "panelLayout") ?? "") ?? .chart }
        set { defaults.set(newValue.rawValue, forKey: "panelLayout") }
    }

    private var savedToolOrder: [SourceMode] {
        ToolOrder.normalized(defaults.stringArray(forKey: "toolOrder") ?? [])
    }

    private var toolOrder: [SourceMode] { savedToolOrder.filter { installedSources.contains($0) } }
    private var effectiveMode: SourceMode { installedSources.contains(mode) ? mode : .auto }

    static func preferredSource(mode: SourceMode, activity: [(source: SourceMode, active: Bool, date: Date)]) -> SourceMode {
        guard mode == .auto else { return mode }
        let active = activity.filter(\.active)
        return (active.isEmpty ? activity : active).max { $0.date < $1.date }?.source ?? .auto
    }

    private var activeSource: SourceMode {
        let activity: [(source: SourceMode, active: Bool, date: Date)] = [
            (.codex, isCodexGenerating, max(reader.samples.last?.completedAt ?? .distantPast, reader.turnActive ? (reader.turnStart ?? .distantPast) : .distantPast)),
            (.opencode, isOpenCodeGenerating, max(oc.samples.last?.completedAt ?? .distantPast, oc.inFlightStart ?? .distantPast)),
            (.claude, claude.inFlightStart != nil, max(claude.samples.last?.completedAt ?? .distantPast, claude.inFlightStart ?? .distantPast)),
            (.antigravity, antigravity.inFlightStart != nil, antigravity.activityDate),
            (.hermes, false, hermes.samples.last?.completedAt ?? .distantPast),
            (.cursor, cursor.inFlightStart != nil, max(cursor.samples.last?.completedAt ?? .distantPast, cursor.inFlightStart ?? .distantPast)),
            (.t3code, t3.inFlightStart() != nil, t3.activityDate)
        ]
        return Self.preferredSource(mode: effectiveMode, activity: activity.filter { installedSources.contains($0.source) })
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        if selftest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.report() }
        }
    }

    private func report() {
        let button = statusItem.button
        print("selftest: visible=\(statusItem.isVisible)")
        print("selftest: title=\(button?.title ?? "<nil>") icon=\(currentSymbol)")
        print("selftest: source=\(activeSource.label)")
        print("selftest: codex=\(reader.samples.count) last=\(reader.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-")")
        print("selftest: opencode=\(oc.samples.count) last=\(oc.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") session=\(oc.sessionID)")
        print("selftest: claude=\(claude.samples.count) last=\(claude.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") session=\(claude.sessionID)")
        print("selftest: claude live=\(claude.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(claude.turnOutput)")
        print("selftest: antigravity=\(antigravity.samples.count) last=\(antigravity.samples.last.map { Fmt.tps($0.measurement.tps) } ?? "-") session=\(antigravity.sessionID)")
        print("selftest: hermes=\(hermes.samples.count) last=\(hermes.samples.last.map { Fmt.tps(HermesReader.speed($0)) } ?? "-")")
        print("selftest: cursor=\(cursor.samples.count) last=\(cursor.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") active=\(cursor.inFlightStart != nil)")
        print("selftest: t3code=\(t3.samples.count) last=\(t3.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") active=\(t3.inFlightStart() != nil)")
        print("selftest: generating codex=\(isCodexGenerating) opencode=\(isOpenCodeGenerating)")
        print("selftest: live codex=\(reader.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(reader.turnOutput) opencode=\(oc.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(oc.turnOutput)")
        if let menu = statusItem.menu {
            menuWillOpen(menu)
            for source in ToolOrder.popular {
                let summary = speedPanel?.cards.first { $0.source == source }?.summary
                print("selftest: menu \(summary.map { "\($0.name) · \($0.caption()) · \($0.value) tok/s" } ?? "missing")")
            }
        }
        NSApp.terminate(nil)
    }

    func refresh() {
        if Date().timeIntervalSince(lastScan) > 5 {
            lastScan = Date()
            installedSources = detectInstalledTools()
            if installedSources.contains(.codex), let url = CodexHome.newestRollout() { reader.read(url) }
            if installedSources.contains(.claude) { claude.poll() }
            if installedSources.contains(.hermes) { hermes.poll() }
        } else if installedSources.contains(.codex), !reader.path.isEmpty {
            reader.read(URL(fileURLWithPath: reader.path))
        }
        if installedSources.contains(.antigravity) { antigravity.poll() }
        if installedSources.contains(.t3code) { t3.poll() }
        if installedSources.contains(.cursor) {
            if !cursorHookReady, Date().timeIntervalSince(lastCursorHookAttempt) > 60 {
                lastCursorHookAttempt = Date()
                let status = CursorHookInstaller.install()
                cursorHookReady = status.error == nil
                if let error = status.error { fputs("Cursor hook: \(error)\n", stderr) }
            }
            cursor.poll()
        }
        if Date().timeIntervalSince(lastOpenCodePoll) > 2 {
            lastOpenCodePoll = Date()
            if installedSources.contains(.opencode) { oc.poll() }
        }
        updateTitle()
        updateSpeedPanel()
        settingsController?.update(settingsState)
    }

    private var isCodexGenerating: Bool {
        installedSources.contains(.codex) && reader.turnActive && reader.turnStart != nil
    }

    private var isOpenCodeGenerating: Bool {
        installedSources.contains(.opencode) && oc.inFlightStart != nil
    }

    private var generating: Bool {
        switch activeSource {
        case .opencode: return isOpenCodeGenerating
        case .codex: return isCodexGenerating
        case .auto: return false
        case .claude: return claude.inFlightStart != nil
        case .antigravity: return antigravity.inFlightStart != nil
        case .cursor: return cursor.inFlightStart != nil
        case .t3code: return t3.inFlightStart() != nil
        case .hermes: return false
        }
    }

    private func liveSpeed() -> Double? {
        switch activeSource {
        case .opencode: return oc.liveTPS()
        case .codex: return reader.liveTPS()
        case .auto: return nil
        case .claude: return claude.liveTPS()
        case .antigravity: return antigravity.currentTPS
        case .cursor, .t3code: return nil
        case .hermes: return nil
        }
    }

    private func turnElapsed() -> Double? {
        switch activeSource {
        case .opencode:
            guard let start = oc.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .auto: return nil
        case .codex:
            guard let start = reader.turnStart, reader.turnActive else { return nil }
            return Date().timeIntervalSince(start)
        case .claude:
            guard let start = claude.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .antigravity:
            guard let start = antigravity.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .cursor:
            guard let start = cursor.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .t3code:
            guard let start = t3.inFlightStart() else { return nil }
            return Date().timeIntervalSince(start)
        case .hermes: return nil
        }
    }

    private func updateTitle() {
        renderStatus(source: activeSource, active: generating, speed: liveSpeed(), elapsed: max(0, turnElapsed() ?? 0))
    }

    private func renderStatus(source: SourceMode, active: Bool, speed: Double?, elapsed: Double) {
        guard let button = statusItem.button else { return }
        let lightning = display.usesLightning(active: active)
        currentSymbol = lightning ? "bolt.fill" : "logo-\(source.rawValue)"
        button.image = lightning
            ? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "TokSpeed")
            : ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: source.label)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.imageHugsTitle = false
        button.attributedTitle = Fmt.statusTitle(display.title(active: active, speed: speed, elapsed: elapsed))
        if source == .auto {
            button.toolTip = L10n.text("No tools installed")
        } else if !active {
            button.toolTip = L10n.text("%@ is idle. Open the menu for speed history.", source.label)
        } else if source == .antigravity, let speed = StatusDisplay.validSpeed(speed) {
            button.toolTip = L10n.text("%@: latest recorded model call, %@ tok/s", source.label, Fmt.tps(speed))
        } else if let speed = StatusDisplay.validSpeed(speed) {
            button.toolTip = L10n.text("%@: %@ tok/s this turn (%d s elapsed)", source.label, Fmt.tps(speed), Int(elapsed))
        } else {
            button.toolTip = L10n.text("%@ is generating (%d s elapsed)", source.label, Int(elapsed))
        }
        button.setAccessibilityLabel(button.toolTip)
    }

    func menuWillOpen(_ menu: NSMenu) {
        installedSources = detectInstalledTools()
        refresh()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let item = header(L10n.text("Recent completed calls"))
        let panel = SpeedPanelView(sources: toolOrder, layout: panelLayout)
        item.view = panel
        menu.addItem(item)
        speedPanel = panel
        if toolOrder.isEmpty { menu.addItem(header(L10n.text("No tools installed"))) }
        configureReordering(in: menu)
        updateSpeedPanel()
        let settings = NSMenuItem(title: L10n.text("Settings") + "…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: L10n.text("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        // Keep native menu shortcut dispatch without adding visible text rows.
        for action in [settings, quit] {
            action.isHidden = true
            action.allowsKeyEquivalentWhenHidden = true
            menu.addItem(action)
        }
        let footer = header("")
        footer.view = PanelFooterView(settings: settings, quit: quit)
        menu.addItem(footer)
    }

    private func prepareSettings() -> SettingsWindowController {
        if let controller = settingsController {
            controller.update(settingsState)
            return controller
        }
        let controller = SettingsWindowController()
        controller.onSource = { [weak self] source in
            self?.mode = source
            self?.settingsChanged()
        }
        controller.onDisplay = { [weak self] display in
            self?.display = display
            self?.settingsChanged()
        }
        controller.onLayout = { [weak self] layout in
            self?.panelLayout = layout
            self?.settingsChanged()
        }
        settingsController = controller
        controller.update(settingsState)
        return controller
    }

    @objc private func showSettings(_ sender: Any?) {
        installedSources = detectInstalledTools()
        let controller = prepareSettings()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    private func settingsChanged() {
        updateTitle()
        settingsController?.update(settingsState)
    }

    @discardableResult
    private func moveTool(_ source: SourceMode, to destination: Int, in menu: NSMenu? = nil) -> Bool {
        let order = ToolOrder.moving(source, to: destination, in: toolOrder)
        guard order != toolOrder else { return false }
        var visible = order.makeIterator()
        let saved = savedToolOrder.map { installedSources.contains($0) ? visible.next()! : $0 }
        defaults.set(saved.map(\.rawValue), forKey: "toolOrder")
        if let menu, let panel = menu.items.first?.view as? SpeedPanelView {
            // Rebind fixed slots rather than removing/inserting items in an open NSMenu.
            if panel.cards.count == order.count {
                for (card, source) in zip(panel.cards, order) {
                    card.bind(source)
                }
                configureReordering(in: menu)
                updateSpeedPanel()
            }
        }
        settingsChanged()
        return true
    }

    private func configureReordering(in menu: NSMenu) {
        guard let panel = menu.items.first?.view as? SpeedPanelView else { return }
        let cards = panel.cards
        let sources = cards.map(\.source)
        for (index, card) in cards.enumerated() {
            card.onDrag = cards.count > 1 ? { [weak self, weak menu, weak panel] card, event in
                guard let self, let menu, let panel else { return }
                MenuCardReorder.track(card, event: event, cards: panel.cards, vertical: panel.layout == .classic) { destination in
                    // Installation detection can refresh during tracking. Do not commit a stale list.
                    guard self.toolOrder == sources else { return }
                    self.moveTool(card.source, to: destination, in: menu)
                }
            } : nil
            var actions: [NSAccessibilityCustomAction] = []
            let labels = panel.layout == .classic ? ("Move up", "Move down") : ("Move left", "Move right")
            for (title, destination) in [(labels.0, index - 1), (labels.1, index + 1)] where cards.indices.contains(destination) {
                actions.append(NSAccessibilityCustomAction(name: L10n.text(title), handler: { [weak self, weak menu, weak card] in
                    guard let self, let menu, let card, self.toolOrder == sources else { return false }
                    return self.moveTool(card.source, to: destination, in: menu)
                }))
            }
            card.setAccessibilityCustomActions(actions)
        }
    }

    private func updateSpeedPanel() {
        guard let panel = speedPanel, !panel.cards.isEmpty else { return }
        var summaries: [SourceMode: SpeedSummary] = [:]
        func update(_ source: SourceMode, active: Bool, live: Double?, last: Double?,
                     completed: Date?, history: [CallHistoryPoint], model: String, measurement: String) {
            summaries[source] = SpeedSummary(name: source.label, active: active, live: live, last: last,
                completedAt: completed, history: history, model: model, measurement: measurement)
        }
        let cumulative = L10n.text("This turn: output tokens / total completed-call duration, excluding tool execution; not instantaneous per-token speed.")
        func history(_ samples: [Sample], speed: (Sample) -> Double = { $0.effectiveTPS }) -> [CallHistoryPoint] {
            samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: speed($0)) }
        }
        update(.codex, active: isCodexGenerating, live: reader.liveTPS(), last: reader.samples.last?.effectiveTPS,
             completed: reader.samples.last?.completedAt, history: history(reader.samples), model: reader.model, measurement: cumulative)
        summaries[.opencode] = oc.summary
        update(.claude, active: claude.inFlightStart != nil, live: claude.liveTPS(), last: claude.samples.last?.effectiveTPS,
             completed: claude.samples.last?.completedAt, history: history(claude.samples), model: claude.samples.last?.model ?? "", measurement: cumulative + "\n" + L10n.text("Claude measures from request start to the first complete output block, including time to first token."))
        summaries[.antigravity] = antigravity.summary
        update(.hermes, active: false, live: nil, last: hermes.samples.last.map(HermesReader.speed),
             completed: hermes.samples.last?.completedAt, history: history(hermes.samples, speed: HermesReader.speed),
            model: hermes.samples.last?.model ?? "",
            measurement: hermes.latestBasis == .stream
                ? L10n.text("Last call: estimated stream speed (first chunk to API completion).")
                : L10n.text("Last call: output tokens / full API time."))
        update(.cursor, active: cursor.inFlightStart != nil, live: nil, last: cursor.samples.last?.effectiveTPS,
             completed: cursor.samples.last?.completedAt, history: history(cursor.samples),
            model: cursor.samples.last?.model ?? cursor.inFlightModel,
            measurement: L10n.text("Cursor hook: last completed turn. Recorded output tokens / whole-turn time from prompt submit to loop stop, including thinking, tools and waiting; not pure model generation speed. While a turn runs, the menu bar shows elapsed time only."))
        update(.t3code, active: t3.inFlightStart() != nil, live: nil, last: t3.samples.last?.effectiveTPS,
             completed: t3.samples.last?.completedAt, history: history(t3.samples), model: t3.samples.last?.model ?? "",
            measurement: L10n.text("T3 Code: last completed turn. Output tokens / full turn duration, including tools and waiting."))
        panel.update(summaries)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Exercise real menu actions using an isolated defaults suite, never source logs.
    func testMenuPreferences() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        func openMenu() { rebuildMenu(menu) }
        func verifyQuitPlacement() -> [NSButton] {
            let quit = menu.items.first { $0.title == L10n.text("Quit") }!
            precondition(quit.action == #selector(NSApplication.terminate(_:)) && quit.submenu == nil)
            precondition(quit.target === NSApp && quit.keyEquivalent == "q" && quit.isHidden && quit.allowsKeyEquivalentWhenHidden)
            precondition(!menu.items.contains(where: \.isSeparatorItem))
            let footer = menu.items.last!.view as! PanelFooterView
            let buttons = footer.subviews.compactMap { $0 as? NSButton }
            precondition(buttons.count == 2 && buttons.allSatisfy { $0.title.isEmpty && $0.image != nil && $0.imagePosition == .imageOnly })
            precondition(buttons[0].frame.minX > footer.bounds.midX &&
                buttons[0].frame.maxX < buttons[1].frame.minX &&
                buttons[1].frame.maxX == footer.bounds.maxX - PanelStyle.inset)
            precondition(buttons.allSatisfy { footer.bounds.maxY - $0.frame.maxY == 14 })
            return buttons
        }
        func send(_ control: NSControl) {
            precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
        }
        openMenu()
        let buttons = verifyQuitPlacement()
        precondition(menu.items.allSatisfy { $0.submenu == nil })
        let settings = menu.items.first { $0.action == #selector(showSettings(_:)) }!
        precondition(settings.title == L10n.text("Settings") + "…" && settings.keyEquivalent == "," &&
            settings.isHidden && settings.allowsKeyEquivalentWhenHidden)
        send(buttons[0])
        let controller = settingsController!
        precondition(controller.window?.isVisible == true)
        let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        precondition(controller.window!.performKeyEquivalent(with: closeEvent))
        precondition(controller.window?.isVisible == false, "Command-W closes Settings, not the app")
        let settingsEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
        precondition(menu.performKeyEquivalent(with: settingsEvent))
        precondition(settingsController === controller && controller.window?.isVisible == true, "Reuse the settings window")
        defer { controller.window?.close() }
        let panel = menu.items.first!.view as! SpeedPanelView
        precondition(panel.cards.map { $0.summary?.name } == toolOrder.map(\.label))
        precondition(panel.cards.allSatisfy { $0.summary?.caption() == L10n.text("No data") })
        precondition(display == .speedAndUnit)
        controller.displayPopup.selectItem(at: 2)
        send(controller.displayPopup)
        precondition(display == .iconOnly)
        precondition(statusItem.button?.title == "" && currentSymbol == "bolt.fill")
        controller.sourcePopup.selectItem(at: ([SourceMode.auto] + toolOrder).firstIndex(of: .opencode)!)
        send(controller.sourcePopup)
        precondition(mode == .opencode)
        let grid = controller.window!.contentView!.subviews.first as? NSGridView
        precondition(grid?.numberOfRows == 3)
        let originalItems = menu.items
        let originalFrames = panel.cards.map(\.frame)
        precondition(moveTool(.claude, to: 2, in: menu))
        precondition(toolOrder == [.codex, .opencode, .claude, .antigravity, .hermes, .cursor, .t3code])
        precondition(menu.items.count == originalItems.count &&
            zip(originalItems, menu.items).allSatisfy { $0 === $1 }, "Reordering preserves NSMenu slots")
        precondition(menu.items.first?.view === panel && panel.cards.map(\.frame) == originalFrames,
            "Reordering leaves the attached chart and legend slots in place")
        precondition(panel.cards.map(\.source) == toolOrder)
        precondition(controller.state?.sources == toolOrder && controller.state?.source == .opencode)
        let restored = AppDelegate(defaults: defaults, detectInstalledTools: { Set(ToolOrder.popular) })
        precondition(restored.toolOrder == toolOrder && restored.mode == mode && restored.display == display)
        precondition(controller.displayPopup.indexOfSelectedItem == 2)
        let firstCard = panel.cards[0]
        precondition(firstCard.accessibilityCustomActions()?.count == 1)
        let moveRight = firstCard.accessibilityCustomActions()!.first!
        precondition(moveRight.name == L10n.text("Move right") && moveRight.handler?() == true)
        precondition(toolOrder == [.opencode, .codex, .claude, .antigravity, .hermes, .cursor, .t3code], "VoiceOver can reorder without dragging")
        precondition(moveTool(.claude, to: 0, in: menu))
        precondition(moveTool(.codex, to: 1, in: menu))
        openMenu()
        precondition(toolOrder == ToolOrder.popular)
        for (index, choice) in StatusDisplay.allCases.enumerated() {
            controller.displayPopup.selectItem(at: index)
            send(controller.displayPopup)
            precondition(currentSymbol == "bolt.fill" && statusItem.button?.title == "", "Idle must always show only lightning")
            renderStatus(source: .opencode, active: true, speed: 46.1, elapsed: 8)
            let expected = choice.title(active: true, speed: 46.1, elapsed: 8)
            precondition(statusItem.button?.attributedTitle.string == (expected.isEmpty ? "" : " " + expected))
            precondition(currentSymbol == (choice == .iconOnly ? "bolt.fill" : "logo-opencode"))
            precondition(statusItem.button?.image?.isTemplate == true)
            renderStatus(source: .opencode, active: true, speed: nil, elapsed: 8)
            let waiting = choice == .iconOnly ? "" : L10n.text("%d s", 8)
            precondition(statusItem.button?.attributedTitle.string == (waiting.isEmpty ? "" : " " + waiting))
            renderStatus(source: .antigravity, active: true, speed: 200, elapsed: 8)
            let recorded = choice.title(active: true, speed: 200, elapsed: 8)
            precondition(statusItem.button?.attributedTitle.string == (recorded.isEmpty ? "" : " " + recorded))
            precondition(statusItem.button?.toolTip == L10n.text("%@: latest recorded model call, %@ tok/s", SourceMode.antigravity.label, "200"))
            renderStatus(source: .opencode, active: false, speed: nil, elapsed: 0)
            precondition(statusItem.button?.title == "" && currentSymbol == "bolt.fill")
        }
        precondition(panelLayout == .chart && controller.layoutPopup.indexOfSelectedItem == 0)
        controller.layoutPopup.selectItem(at: 1)
        send(controller.layoutPopup)
        openMenu()
        let classic = menu.items.first!.view as! SpeedPanelView
        precondition(classic.layout == .classic && classic.chart.superview == nil)
        precondition(classic.cards.map(\.source) == ToolOrder.popular)
        precondition(classic.cards.allSatisfy { $0.subviews.contains { $0 is ClassicTrendView } })
        precondition(zip(classic.cards, classic.cards.dropFirst()).allSatisfy { $0.0.frame.minY == $0.1.frame.maxY })
        let frames = classic.cards.map(\.frame)
        let below = NSPoint(x: frames.last!.midX, y: frames.last!.minY + 1)
        precondition(MenuCardReorder.destination(at: below, frames: frames, from: 0, vertical: true)?.index == frames.count - 1)
        let moveDown = classic.cards[0].accessibilityCustomActions()!.first!
        precondition(moveDown.name == L10n.text("Move down") && moveDown.handler?() == true)
        precondition(classic.cards.map(\.frame) == frames && classic.cards.map(\.source) == toolOrder)
        precondition(moveTool(.claude, to: 0, in: menu))
        _ = verifyQuitPlacement()
        precondition(AppDelegate(defaults: defaults, detectInstalledTools: { Set(ToolOrder.popular) }).panelLayout == .classic)
        controller.layoutPopup.selectItem(at: 0)
        send(controller.layoutPopup)
        openMenu()
        let combined = menu.items.first!.view as! SpeedPanelView
        precondition(combined.layout == .chart && combined.chart.superview === combined)
        _ = verifyQuitPlacement()
        print("settings smoke: passed (source, status display, both panel views, persistence, action footer)")
        print("menu reorder tests: passed (fixed slots/source rebinding/VoiceOver actions/persistence)")
    }

    func testInstalledVisibility(setInstalled: (Set<SourceMode>) -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        mode = .claude
        defaults.set(["opencode", "claude", "codex", "antigravity"], forKey: "toolOrder")
        for available: Set<SourceMode> in [[.codex, .opencode], [.claude], [.hermes], [.cursor], [.t3code], []] {
            setInstalled(available)
            installedSources = detectInstalledTools()
            rebuildMenu(menu)
            updateTitle()
            let panel = menu.items.first!.view as! SpeedPanelView
            precondition(Set(panel.cards.map(\.source)) == available)
            let controller = prepareSettings()
            let choices = controller.sourcePopup.itemArray.compactMap { ($0.representedObject as? String).flatMap(SourceMode.init(rawValue:)) }
            precondition(choices == [.auto] + toolOrder)
            precondition(controller.sourcePopup.selectedItem?.representedObject as? String == effectiveMode.rawValue)
            let cards = panel.cards
            precondition(cards.count == available.count)
            precondition(cards.allSatisfy { ($0.onDrag != nil) == (available.count > 1) })
            precondition(mode == .claude, "Temporarily missing apps must not erase a pinned preference")
            if available.isEmpty {
                precondition(activeSource == .auto && currentSymbol == "bolt.fill" && statusItem.button?.title == "")
                precondition(menu.items.contains { $0.title == L10n.text("No tools installed") })
            } else {
                precondition(available.contains(activeSource))
            }
        }
        setInstalled([.codex, .opencode])
        installedSources = detectInstalledTools()
        moveTool(.codex, to: 0)
        precondition(savedToolOrder == [.codex, .claude, .opencode, .antigravity, .hermes, .cursor, .t3code], "Hidden tools retain their saved positions")
        setInstalled(Set(ToolOrder.popular))
        installedSources = detectInstalledTools()
        precondition(effectiveMode == .claude && toolOrder == savedToolOrder)
        print("installation menu tests: passed (partial/all/none, hidden choices, pin fallback, restored order)")
    }

}

// MARK: - Headless verification mode

func runOnce() -> Int32 {
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == SourceMode.t3code.rawValue {
        let dbIndex = CommandLine.arguments.firstIndex(of: "--db")
        let path = dbIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            ?? T3CodeReader.dbPath
        let reader = T3CodeReader(dbPath: path)
        reader.poll()
        print("database:  \(path)")
        guard reader.available else {
            print("No readable T3 Code V2 database.")
            return 1
        }
        print("samples:   \(reader.samples.count)")
        print("generating:\(reader.inFlightStart() != nil)")
        if let sample = reader.samples.last {
            print("model:     \(sample.model)")
            print("output:    \(sample.output)")
            print("elapsed:   \(Fmt.secs(sample.elapsed))")
            print("speed:     \(Fmt.tps(sample.effectiveTPS)) tok/s (whole turn, including tools/waits)")
        }
        return 0
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "cursor" {
        let logIndex = CommandLine.arguments.firstIndex(of: "--log")
        let path = logIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? CursorReader.logPath()
        let reader = CursorReader(logPath: path)
        reader.poll()
        print("log:       \(path)")
        guard reader.readable else {
            print("No Cursor hook log yet. Complete a local Agents Window turn after the integration is installed.")
            return 1
        }
        print("samples:   \(reader.samples.count)")
        print("generating:\(reader.inFlightStart != nil)")
        if let sample = reader.samples.last {
            print("model:     \(sample.model)")
            print("output:    \(sample.output)")
            print("elapsed:   \(Fmt.secs(sample.elapsed))")
            print("speed:     \(Fmt.tps(sample.effectiveTPS)) tok/s (whole turn, including tools/waits)")
        } else {
            print("no completed Cursor turn with recorded output usage and a hook start/stop pair")
        }
        return 0
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "hermes" {
        let reader = HermesReader()
        reader.poll()
        print("samples:   \(reader.samples.count)")
        if let sample = reader.samples.last, let basis = reader.latestBasis {
            print("model:     \(sample.model)")
            print("output:    \(sample.output)")
            print("basis:     \(basis.rawValue)")
            print("elapsed:   \(Fmt.secs(sample.elapsed))")
            if let first = sample.firstOutputAt, let wait = sample.ttft {
                print("TTFC:      \(Fmt.secs(wait))")
                print("stream:    \(Fmt.secs(sample.completedAt.timeIntervalSince(first)))")
                print("E2E speed: \(Fmt.tps(sample.effectiveTPS)) tok/s")
            }
            print("speed:     \(Fmt.tps(HermesReader.speed(sample))) tok/s")
        }
        return 0
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "opencode" {
        let dbIndex = CommandLine.arguments.firstIndex(of: "--db")
        let dbPath = dbIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? OpenCodeReader.dbPath
        let reader = OpenCodeReader(dbPath: dbPath)
        reader.poll()
        reader.onceLines.forEach { print($0) }
        return reader.sessionID.isEmpty ? 1 : 0
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "antigravity" {
        let reader = AntigravityReader()
        reader.poll()
        reader.onceLines.forEach { print($0) }
        return reader.available || reader.inFlightStart != nil ? 0 : 1
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "claude" {
        let reader = ClaudeReader()
        reader.poll()
        print("session:   \(reader.sessionID)")
        print("responses: \(reader.samples.count)")
        if let sample = reader.samples.last {
            print("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s  elapsed \(Fmt.secs(sample.elapsed))  output \(sample.output)")
        }
        print("median:    \(Fmt.tps(reader.medianTPS)) tok/s")
        print("live:      \(reader.liveTPS().map { Fmt.tps($0) } ?? "-") tok/s  turn output \(reader.turnOutput)")
        return 0
    }
    var url: URL?
    if let idx = CommandLine.arguments.firstIndex(of: "--file"), idx + 1 < CommandLine.arguments.count {
        url = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    } else {
        url = CodexHome.newestRollout()
    }
    guard let url = url else {
        print("no rollout found under \(CodexHome.path)")
        return 1
    }
    let reader = RolloutReader()
    reader.read(url)
    print("rollout:   \(url.path)")
    print("session:   \(reader.sessionID)")
    print("model:     \(reader.model)")
    print("responses: \(reader.samples.count)")
    if let s = reader.samples.last {
        print("last:      \(Fmt.tps(s.effectiveTPS)) tok/s effective, \(Fmt.tps(s.visibleTPS)) tok/s visible")
        print("last ttft: \(s.ttft.map { Fmt.secs($0) } ?? "-")  elapsed \(Fmt.secs(s.elapsed))  output \(s.output)")
    }
    print("median:    \(Fmt.tps(reader.medianTPS)) tok/s")
    return 0
}

// Deterministic presentation checks; no provider access or preference changes.
func testRolloutIncrementalRead() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("tokspeed-rollout-test-\(UUID().uuidString)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-test.jsonl")
    let prefix = Data("""
    {"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
    {"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant"}}

    """.utf8)
    let usage = Data("""
    {"timestamp":"2026-01-01T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":100}}}}

    """.utf8)
    let split = usage.count / 2
    try (prefix + usage.prefix(split)).write(to: file)
    let reader = RolloutReader()
    reader.read(file)
    precondition(reader.samples.isEmpty)
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.seekToEnd()
    try writer.write(contentsOf: usage.suffix(usage.count - split))
    reader.read(file)
    precondition(reader.samples.count == 1, "A completed partial record must appear on the next poll")
    precondition(reader.samples[0].effectiveTPS == 50)
    reader.read(file)
    precondition(reader.samples.count == 1, "Repeated polling must not duplicate samples")
    let clock = Date(timeIntervalSince1970: 1767225604)
    precondition(reader.liveTPS(now: clock) == 50)
    precondition(!reader.isActive(at: clock.addingTimeInterval(901)))
    try writer.write(contentsOf: Data("{\"timestamp\":\"2026-01-01T00:00:04.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n".utf8))
    reader.read(file)
    precondition(reader.liveTPS(now: clock) == nil && !reader.isActive(at: clock) && reader.samples.count == 1)
    print("rollout tests: passed (partial writes, repeat poll, stale and aborted turns)")
}

func testPanel(previewDirectory: String?) throws {
    try testRolloutIncrementalRead()
    try testHermesReader()
    try testCursorReader()
    try testT3CodeReader()
    try testAntigravityReader()
    try testOpenCodeReader()
    try testInstalledTools()
    testPresentationPreferences()
    if Bundle.main.bundleURL.pathExtension == "app" {
        precondition(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon")
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        precondition(icon?.isValid == true, "Missing or invalid bundled app icon")
        print("app icon tests: passed (bundle declaration and ICNS loading)")
    }
    let now = Date()
    func point(_ secondsAgo: TimeInterval, _ speed: Double) -> CallHistoryPoint {
        CallHistoryPoint(completedAt: now.addingTimeInterval(-secondsAgo), speed: speed)
    }
    func summary(active: Bool = true, live: Double? = 46.1, last: Double? = 31.7,
                 history: [CallHistoryPoint] = []) -> SpeedSummary {
        SpeedSummary(name: "Codex", active: active, live: live, last: last,
            completedAt: now.addingTimeInterval(-8), history: history, model: "test", measurement: "test")
    }
    precondition(summary().value == "46" && Fmt.tps(10) == "10.0" && Fmt.tps(8.24) == "8.2")
    let panel = SpeedPanelView(sources: ToolOrder.popular)
    precondition(abs(panel.chart.frame.height / panel.chart.frame.width - 3.0 / 5.0) < 0.001)
    precondition(panel.chart.frame.minY > panel.cards[0].frame.maxY)
    precondition(panel.cards.first!.frame.minX == panel.chart.frame.minX &&
        abs(panel.cards.last!.frame.maxX - panel.chart.frame.maxX) < 0.001)
    for card in panel.cards {
        let source = card.source
        if Bundle.main.bundleURL.pathExtension == "app" {
            precondition(Bundle.main.url(forResource: source.rawValue, withExtension: "svg", subdirectory: "Logos") != nil,
                "Missing bundled provider artwork: \(source.rawValue)")
        }
        precondition(ProviderLogo.image(source)?.isTemplate == true, "Missing template logo: \(source.rawValue)")
        card.update(summary())
        precondition(card.toolTip == nil, "Hovering a tool card must not show detail text")
        let logo = card.subviews.compactMap { $0 as? NSImageView }.first!
        let labels = card.subviews.compactMap { $0 as? NSTextField }
        precondition(labels.map(\.stringValue) == ["46"], "Only the speed is visible")
        let speed = labels[0]
        precondition(speed.frame.minX < logo.frame.midX && logo.frame.midX < speed.frame.maxX &&
            logo.frame.midX == card.bounds.midX && logo.frame.minY > speed.frame.maxY,
            "The logo and number must share a centered column without overlapping")
        precondition(logo.contentTintColor == PanelStyle.color(active: true) && speed.textColor == logo.contentTintColor)
        card.update(summary(active: false))
        precondition(logo.contentTintColor == PanelStyle.color(active: false) && speed.textColor == logo.contentTintColor)
    }
    precondition(summary().caption(now: now) == L10n.text("This turn"))
    precondition(summary(active: false).value == "32")
    precondition(summary(live: nil).caption(now: now) == L10n.text("Last · %@", L10n.text("%d s ago", 8)))
    precondition(summary(live: nil, last: nil).value == "—")
    precondition(summary(live: nil, last: nil).caption(now: now) == L10n.text("Waiting for data"))
    precondition(summary(active: false, live: nil, last: nil).caption(now: now) == L10n.text("No data"))
    precondition(summary(live: .nan, last: .infinity).value == "—")
    let many = (1...75).map { point(Double(76 - $0) * 5, Double($0)) }
    let invalid = [Double.nan, .infinity, 0, -1].map { point(0, $0) }
    precondition(summary(history: Array(many.reversed()) + invalid).recent == Array(many.suffix(60)))
    let stale = 24.0 * 3600
    let oldHistory = [point(stale + 7 * 3600, 900), point(stale + 1800, 90), point(stale + 600, 70), point(stale, 30)]
    var histories: [SourceMode: SpeedSummary] = [
        .claude: summary(live: 9999, history: many),
        .codex: summary(last: 30, history: [point(60, 30), point(30, 30)]),
        .opencode: summary(live: nil, last: 30, history: [point(60, 30)]),
        .hermes: summary(active: false, last: 30, history: oldHistory),
        .cursor: summary(active: false, history: [point(0, 50)])
    ]
    panel.update(histories)
    precondition(panel.chart.series.map(\.source) == [.claude, .codex, .opencode, .hermes, .cursor])
    precondition(panel.chart.series[3].samples == Array(oldHistory.suffix(3)), "An idle source keeps its own recent history")
    precondition(panel.chart.series.map(\.active) == [true, true, true, false, false])
    let bounds = panel.chart.bounds
    func plotted(_ series: [CallHistoryView.Series]) -> [[NSPoint]] {
        CallHistoryView.project(series, in: bounds).map { $0.flatMap { $0 } }
    }
    let points = plotted(panel.chart.series)
    precondition(points.map(\.count) == [60, 2, 1, 3, 1])
    precondition(points[0][60 - 12].x == points[1][0].x && points[1][0] == points[2][0], "Same time means same X even across sources")
    precondition(points[0][30 - 16].y == points[1][0].y && points[1][0].y == points[3][2].y,
        "Active and idle speeds share one scale")
    precondition(points[2][0].x < points[1][1].x && points[1][1].x < points[0][59].x,
        "Each series ends at its own last observation")
    precondition(panel.hoverText.isEmpty)
    let visible = CallHistoryView.visibleReadings(panel.chart.series, in: bounds)
    let latestVisible = visible[0].last!.last!
    panel.chart.track(at: latestVisible.position)
    let hoverFormatter = ChartReadoutFormatter(locale: Locale(identifier: L10n.language))
    precondition(panel.chart.hoveredReading?.source == .claude &&
        panel.chart.hoveredReading?.sample == many.last &&
        panel.hoverText == L10n.text("%@ · %@ · %@ tok/s", SourceMode.claude.label,
            hoverFormatter.timestamp(latestVisible.sample.completedAt), hoverFormatter.speed(75)),
        "Hover must report the real sample rather than an interpolated speed")
    panel.chart.track(at: visible[3][0][0].position)
    precondition(panel.chart.hoveredReading?.source == .hermes &&
        panel.chart.hoveredReading?.sample == oldHistory[1],
        "An idle reading shows its own recorded timestamp")
    panel.chart.track(at: NSPoint(x: -1, y: -1))
    precondition(panel.hoverText.isEmpty && panel.chart.hoveredReading == nil)
    let activeOnly = plotted(panel.chart.series.filter(\.active))
    precondition(zip(points.prefix(3), activeOnly).allSatisfy { mixed, only in mixed.map(\.x) == only.map(\.x) },
        "Neither older nor newer idle data may change the active time scale")
    precondition(abs((points[3][1].x - points[3][0].x) / (points[3][2].x - points[3][1].x) - 2) < 0.001 &&
        points[4][0].x == bounds.midX, "Idle samples preserve relative timing, including a centered singleton")
    let strokeSafe = bounds.insetBy(dx: 2, dy: 2)
    precondition(points.flatMap { $0 }.allSatisfy { strokeSafe.contains($0) })
    func project(_ samples: [CallHistoryPoint]) -> [[NSPoint]] {
        CallHistoryView.project([.init(source: .cursor, active: false, samples: samples)], in: bounds)[0]
    }
    let flat = project([point(100, 3000), point(0, 3000)])
    precondition(flat[0].allSatisfy { $0.y == bounds.midY })
    let crowded = [point(300, 40), point(159, 45), point(158, 5000), point(157, 55),
        point(157, 50), point(0, 60)]
    let sparse = CallHistoryView.visibleReadings([.init(source: .claude, active: true, samples: crowded)], in: bounds)[0][0]
    precondition(sparse.map(\.sample) == [crowded[0], crowded[4], crowded[5]],
        "Dense samples use a real representative point, including for duplicate timestamps")
    precondition(sparse[1].position.y == bounds.midY, "Unshown peaks must not compress the visible speed scale")
    let single = project([point(3600 * 24 * 400, Double.greatestFiniteMagnitude)])
    precondition(single == [[NSPoint(x: bounds.midX, y: bounds.midY)]], "An old singleton is not replaced or stretched to the present")
    let high = project([point(220, 100), point(200, 3000), point(0, 5000)])[0]
    precondition(high[0].y < high[1].y && high[1].y < high[2].y, "High speeds must not clip or plateau")
    let spike = point(60, 5000)
    let clean = [point(120, 40), point(0, 50)]
    let spikedHistory = [clean[0], spike, clean[1]]
    let spikedPanel = SpeedPanelView(sources: [.claude])
    spikedPanel.update([.claude: summary(history: spikedHistory)])
    precondition(spikedPanel.cards[0].summary?.history == spikedHistory &&
        spikedPanel.chart.series[0].samples == clean &&
        plotted(spikedPanel.chart.series)[0] == project(clean).flatMap { $0 },
        "An isolated spike must not distort the chart or mutate the original history")
    for legitimate in [[point(120, 40), spike, point(30, 4800), point(0, 50)],
                       [clean[0], spike], [point(2400, 40), spike, clean[1]],
                       [clean[0], point(60, 125), clean[1]]] {
        precondition(CallHistoryView.withoutIsolatedSpikes(legitimate) == legitimate)
    }
    precondition(abs((high[2].x - high[1].x) / (high[1].x - high[0].x) - 10) < 0.001, "Time gaps must scale linearly")
    let spaced = project([point(4000, 50), point(3900, 60), point(2600, 55), point(1210, 90), point(10, 100), point(10, 120)])
    precondition(spaced.map(\.count) == [2, 1, 3] && spaced[2][1].x == spaced[2][2].x)
    let path = CallHistoryView.linePath(spaced)
    precondition(path.elementCount == 5 && path.element(at: 1, associatedPoints: nil) == .curveTo &&
        path.element(at: 2, associatedPoints: nil) == .moveTo &&
        path.element(at: 4, associatedPoints: nil) == .lineTo,
        "Distinct timestamps produce curves, gaps break the path, and duplicate timestamps stay vertical")
    let uneven = [NSPoint(x: 0, y: 0), NSPoint(x: 1, y: 200),
                  NSPoint(x: 180, y: 201), NSPoint(x: 182, y: 0)]
    let smooth = CallHistoryView.linePath([uneven])
    for (index, end) in uneven.dropFirst().enumerated() {
        let start = uneven[index]
        var controls = [NSPoint](repeating: .zero, count: 3)
        let kind = controls.withUnsafeMutableBufferPointer {
            smooth.element(at: index + 1, associatedPoints: $0.baseAddress)
        }
        precondition(kind == .curveTo && controls[2] == end)
        precondition(controls.allSatisfy {
            (start.x...end.x).contains($0.x) &&
            (min(start.y, end.y)...max(start.y, end.y)).contains($0.y)
        }, "Smoothing must not overshoot even with uneven timestamps")
    }
    let limited = SpeedPanelView(sources: [.codex])
    limited.update(histories)
    precondition(limited.chart.series.map(\.source) == [.codex], "Hidden tools must not affect the chart")
    let calls = [point(10, 6), point(0, 12)]
    limited.update([.codex: summary(live: 241, history: calls)])
    precondition(limited.cards[0].summary?.value == "241" && limited.chart.series[0].samples == calls,
        "Changing the live number must not change the completed-call curve")
    let activeTrace = CallHistoryView.Series(source: .claude, active: true, samples: [])
    let idleTrace = CallHistoryView.Series(source: .codex, active: false, samples: [])
    precondition(activeTrace.strokeWidth == 3.6 && idleTrace.strokeWidth == 2.8)
    for (appearance, white) in [(NSAppearance.Name.darkAqua, CGFloat(1)), (.aqua, CGFloat(0))] {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            for active in [true, false] {
                let color = PanelStyle.color(active: active).usingColorSpace(.sRGB)!
                precondition(color.redComponent == white && color.greenComponent == white && color.blueComponent == white)
                precondition(active ? color.alphaComponent == 1 : (0.4..<0.9).contains(color.alphaComponent))
            }
            let idleInk = idleTrace.ink.usingColorSpace(.sRGB)!
            precondition(idleInk.redComponent == white && idleInk.alphaComponent < 0.3)
        }
    }
    let plotBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: plotBitmap)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(bounds)
    panel.chart.draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    precondition(plotBitmap.colorAt(x: 20, y: 20)?.alphaComponent == 0 &&
        plotBitmap.colorAt(x: Int(latestVisible.position.x), y: Int(bounds.height - latestVisible.position.y))?.alphaComponent ?? 0 > 0,
        "The chart must paint the data but not the background")
    let singleTrace = CallHistoryView(frame: bounds)
    singleTrace.update([.init(source: .claude, active: true, samples: [point(0, 50)])])
    singleTrace.track(at: NSPoint(x: bounds.midX, y: bounds.midY))
    precondition(singleTrace.hoveredReading != nil, "Removing markers does not disable hover")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(bounds)
    singleTrace.draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    for dx in -7...7 {
        for dy in -7...7 {
            precondition(plotBitmap.colorAt(x: Int(bounds.midX) + dx, y: Int(bounds.midY) + dy)?.alphaComponent == 0,
                "Do not draw single-point or hover markers")
        }
    }
    histories[.hermes] = summary(active: true, last: 30, history: oldHistory)
    panel.update(histories)
    precondition(!panel.chart.series.contains { $0.source == .hermes }, "An active series outside the active window must not be reanchored")
    histories[.hermes] = summary(active: false, last: 30, history: oldHistory)
    let idleCalls = histories.mapValues { summary(active: false, last: $0.last, history: $0.history) }
    panel.update(idleCalls)
    let idlePoints = plotted(panel.chart.series)
    precondition(panel.chart.series.count == 5 && panel.chart.series.allSatisfy { !$0.active } &&
        idlePoints[3] == points[3] && idlePoints[2][0].x == bounds.midX,
        "All-idle mode keeps each history, and switching state moves observations to their own timeline")
    var idleWithWaiting = idleCalls
    idleWithWaiting[.antigravity] = summary(active: true, live: 250, history: [])
    panel.update(idleWithWaiting)
    precondition(plotted(panel.chart.series) == idlePoints, "An active source without completed calls must not suppress or reshape idle history")
    limited.update([.codex: summary(history: invalid)])
    precondition(limited.chart.series.isEmpty && CallHistoryView.project([], in: bounds).isEmpty)
    print("panel tests: passed (active time alignment, independent idle history, shared speeds, spikes, hover, transparency and gaps)")

    guard let directory = previewDirectory else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "PanelPreview", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PanelPreview", code: 2) }
        let path = (directory as NSString).appendingPathComponent(name)
        try png.write(to: URL(fileURLWithPath: path))
        print("preview: \(path)")
    }
    for dark in [true, false] {
        let height = SpeedPanelView.height + PanelFooterView.height + 12
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelStyle.width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.96, alpha: 1).cgColor
        let panel = SpeedPanelView(sources: ToolOrder.popular)
        panel.frame.origin.y = PanelFooterView.height + 6
        root.addSubview(panel)
        let examples: [(SourceMode, Bool, Double?, [(TimeInterval, Double)])] = [
            (.claude, true, 113, [(68, 65), (64, 79), (62, 74), (35, 91), (31, 109), (29, 94),
                (24, 121), (22, 105), (17, 124), (14, 118), (11, 130), (8, 113), (6, 116), (3, 101), (1, 99)]),
            (.codex, true, 46.1, [(56, 22), (52, 25), (48, 23), (43, 40), (41, 32), (27, 52), (23, 36),
                (20, 42), (17, 35), (14, 45), (10, 32)]),
            (.opencode, false, nil, [(63, 9), (58, 14), (51, 11), (42, 15), (37, 13), (31, 18), (25, 16)]),
            (.antigravity, true, 56, [(53, 50), (46, 65), (42, 56), (36, 58), (32, 54), (26, 64), (21, 58), (16, 71), (10, 55), (4, 60)]),
            (.hermes, false, nil, [(1507, 34), (1498, 41), (1489, 34), (1484, 42), (1477, 36)]),
            (.cursor, false, nil, [(3180, 8.4)]),
            (.t3code, false, nil, [(180, 24.5), (90, 31.2)])
        ]
        panel.update(Dictionary(uniqueKeysWithValues: examples.map { entry in
            let (source, active, live, readings) = entry
            let history = readings.map { point($0.0 * 60, $0.1) }
            return (source, SpeedSummary(name: source.label, active: active, live: live, last: history.last?.speed,
                completedAt: history.last?.completedAt, history: history, model: "test", measurement: "test"))
        }))
        let footer = PanelFooterView(
            settings: NSMenuItem(title: L10n.text("Settings") + "…", action: nil, keyEquivalent: ","),
            quit: NSMenuItem(title: L10n.text("Quit"), action: nil, keyEquivalent: "q"))
        footer.frame.origin.y = 6
        root.addSubview(footer)
        try capture(root, name: dark ? "panel-dark.png" : "panel-light.png")
        panel.chart.track(at: CallHistoryView.visibleReadings(panel.chart.series, in: panel.chart.bounds).first?.last?.last?.position)
        try capture(root, name: dark ? "panel-hover-dark.png" : "panel-hover-light.png")
        panel.chart.track(at: nil)
        let allIdle = examples.map { source, _, _, readings in
            let history = readings.map { point($0.0 * 60, $0.1) }
            return (source, SpeedSummary(name: source.label, active: false, live: nil, last: history.last?.speed,
                completedAt: history.last?.completedAt, history: history, model: "test", measurement: "test"))
        }
        panel.update(Dictionary(uniqueKeysWithValues: allIdle))
        try capture(root, name: dark ? "panel-idle-dark.png" : "panel-idle-light.png")
        let settings = SettingsWindowController()
        settings.window?.appearance = window.appearance
        settings.update(SettingsState(sources: ToolOrder.popular, source: .auto, display: .speedAndUnit))
        try capture(settings.window!.contentView!.superview!, name: dark ? "settings-dark.png" : "settings-light.png")
    }
}

func testPresentationPreferences() {
    for (preferences, expected) in [
        (["en-GB"], "en"), (["zh-CN"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
        (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["zh-Hans-TW"], "zh-Hans"),
        (["ja-JP"], "ja"), (["ko-KR"], "ko"), (["de-DE"], "de"),
        (["fr-CA"], "fr"), (["es-MX"], "es"), (["it-IT"], "en"),
        (["it-IT", "de-DE"], "de"), ([], "en")
    ] {
        precondition(L10n.resolve(preferences) == expected)
    }
    let english = L10n.table("en")
    precondition(!english.isEmpty)
    let placeholders = try! NSRegularExpression(pattern: "%[@d]")
    func formats(_ text: String) -> [String] {
        placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
        }
    }
    for language in L10n.languages {
        let table = L10n.table(language)
        precondition(Set(table.keys) == Set(english.keys), "Incomplete localization: \(language)")
        for (key, value) in table {
            precondition(!value.isEmpty && formats(key) == formats(value), "Invalid translation: \(language) \(key)")
        }
        let locale = Locale(identifier: language)
        let formatter = ChartReadoutFormatter(locale: locale)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 37, second: 51))!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        let minuteTime = formatter.timestamp(date, now: date)
        let earlierTime = formatter.timestamp(date, now: tomorrow)
        precondition(minuteTime.contains("37") && !minuteTime.contains("51") &&
            earlierTime != minuteTime && !earlierTime.contains("51"))
        precondition(formatter.speed(7.5) == "7\(locale.decimalSeparator ?? ".")5")
    }
    precondition(L10n.text("Missing translation falls back to English") == "Missing translation falls back to English")
    print("localization tests: passed (8 languages, matching/fallback/completeness/format arguments); selected=\(L10n.language)")

    precondition(ToolOrder.normalized([]) == ToolOrder.popular)
    precondition(ToolOrder.normalized(["auto", "unknown", "opencode", "opencode"]) == [.opencode, .claude, .codex, .antigravity, .hermes, .cursor, .t3code])
    precondition(ToolOrder.normalized(["claude", "codex", "opencode", "antigravity", "hermes", "cursor"]) == ToolOrder.popular, "Existing preferences gain T3 Code without reordering tools")
    precondition(ToolOrder.moving(.claude, to: -1, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.antigravity, to: ToolOrder.popular.count, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.auto, to: 0, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.claude, to: 3, in: ToolOrder.popular) == [.codex, .opencode, .antigravity, .claude, .hermes, .cursor, .t3code])
    precondition(ToolOrder.moving(.antigravity, to: 0, in: ToolOrder.popular) == [.antigravity, .claude, .codex, .opencode, .hermes, .cursor, .t3code])
    let frames = (0..<4).map { NSRect(x: $0 * 56, y: 0, width: 56, height: 72) }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 4, y: 36), frames: frames, from: 3) == .init(index: 0, slot: 0))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 220, y: 36), frames: frames, from: 0) == .init(index: 3, slot: 4))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 164, y: 36), frames: frames, from: 0) == .init(index: 2, slot: 3))
    for point in [NSPoint(x: -1, y: 36), NSPoint(x: 225, y: 36), NSPoint(x: 100, y: -1), NSPoint(x: 100, y: 73)] {
        precondition(MenuCardReorder.destination(at: point, frames: frames, from: 0) == nil)
    }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 36, y: 36), frames: frames, from: 0) == nil)
    precondition(MenuCardReorder.destination(at: .zero, frames: [], from: 0) == nil)
    precondition(MenuCardReorder.destination(at: NSPoint(x: 36, y: 36), frames: [frames[0]], from: 0) == nil)
    for active in [false, true] {
        for display in StatusDisplay.allCases {
            let hidden = !active || display == .iconOnly
            precondition(display.usesLightning(active: active) == hidden)
            precondition(display.title(active: active, speed: 46.1, elapsed: 8) == (hidden ? "" : display == .speedAndUnit ? "46 tok/s" : "46"))
            precondition(display.title(active: active, speed: nil, elapsed: 8) == (hidden ? "" : L10n.text("%d s", 8)))
        }
    }
    let now = Date()
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, true, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .opencode)
    precondition(AppDelegate.preferredSource(mode: .claude, activity: [(.codex, true, now)]) == .claude)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.hermes, false, now)]) == .hermes)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.cursor, false, now), (.codex, true, now.addingTimeInterval(-30))]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.cursor, false, now), (.codex, false, now.addingTimeInterval(-30))]) == .cursor)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.t3code, false, now), (.codex, true, now.addingTimeInterval(-30))]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.t3code, false, now), (.codex, false, now.addingTimeInterval(-30))]) == .t3code)

    print("presentation tests: passed (ordering/status modes/active-source priority)")

    let suite = "io.github.thinkofuture.tokspeed.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var installed = Set(ToolOrder.popular)
    let delegate = AppDelegate(defaults: defaults, detectInstalledTools: { installed })
    withExtendedLifetime(delegate) {
        delegate.testMenuPreferences()
        delegate.testInstalledVisibility { installed = $0 }
    }
}

func testInstalledTools() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-installs-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func write(_ relative: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture, never executed".utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    func detect(path: String = "", app: URL? = nil) -> Set<SourceMode> {
        InstalledTools.detect(environment: ["PATH": path], home: root.path,
            systemBinDirectories: [], applicationDirectories: [root.appendingPathComponent("Applications").path],
            applicationURL: { _ in app })
    }
    try write(".codex/sessions/rollout-old.jsonl")
    try write(".claude/projects/old.jsonl")
    try write(".local/share/opencode/opencode.db")
    try write(".gemini/antigravity/conversation_summaries.db")
    try write(".hermes/logs/agent.log")
    try write("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    try write(".t3/userdata/statev2.sqlite")
    precondition(detect().isEmpty, "Leftover data is not an installation")
    try write(".local/bin/codex", executable: true)
    try write(".opencode/bin/opencode", executable: true)
    try write(".nvm/versions/node/v22/bin/claude", executable: true)
    try write("custom/bin/antigravity")
    let path = root.appendingPathComponent("custom/bin").path
    precondition(detect(path: path) == [.codex, .opencode, .claude], "A non-executable file is not a CLI")
    try write(".local/bin/hermes", executable: true)
    try write(".local/bin/cursor", executable: true)
    try write(".local/bin/t3code", executable: true)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("custom/bin/antigravity").path)
    precondition(detect(path: path) == Set(ToolOrder.popular))
    try fm.removeItem(at: root.appendingPathComponent(".local/bin/t3code"))
    try write("Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)", executable: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "T3 Code (Beta)",
        "CFBundleIdentifier": "com.t3tools.t3code", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Applications/T3 Code (Beta).app/Contents/Info.plist"))
    precondition(detect(path: path).contains(.t3code), "T3 Code desktop-only installations must be visible")
    try fm.removeItem(at: root.appendingPathComponent(".local/bin/cursor"))
    try write("Applications/Cursor.app/Contents/MacOS/Cursor", executable: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Cursor",
        "CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Applications/Cursor.app/Contents/Info.plist"))
    precondition(detect(path: path).contains(.cursor), "Cursor desktop-only installations must be visible")
    let app = root.appendingPathComponent("Applications/Antigravity.app")
    try write("Applications/Antigravity.app/Contents/MacOS/Antigravity", executable: true)
    let info: [String: String] = ["CFBundleExecutable": "Antigravity", "CFBundleIdentifier": "com.google.antigravity", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    precondition(detect() == Set(ToolOrder.popular), "Desktop-only installs must be visible")
    let moved = root.appendingPathComponent("Elsewhere/Antigravity.app")
    try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: app, to: moved)
    precondition(!detect().contains(.antigravity))
    precondition(detect(app: moved).contains(.antigravity), "Launch Services can locate nonstandard app installs")
    let trashed = root.appendingPathComponent(".Trash/Antigravity.app")
    try fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: moved, to: trashed)
    precondition(!detect(app: trashed).contains(.antigravity))
    try write(".local/bin/agy", executable: true)
    precondition(detect().contains(.antigravity), "Finder-launched TokSpeed must detect an agy CLI-only install")
    print("installation detection tests: passed (CLI/PATH/Finder/NVM/desktop/Launch Services/trash/stale logs)")
}

let args = CommandLine.arguments
if args.contains("--install-hermes-plugin") {
    do {
        let destination = try HermesPluginInstaller.install()
        print("Hermes plugin files: \(destination.path)")
        print("Enable in the same Hermes profile: hermes plugins enable \(HermesReader.pluginName)")
        print("If Hermes did not reload plugins, start a new process or reload the gateway before collecting data.")
        print("Log: \(HermesReader.logURL(home: HermesReader.home()).path)")
        exit(0)
    } catch {
        fputs("Hermes plugin: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
if args.contains("--install-cursor-hook") || args.contains("--uninstall-cursor-hook") {
    let status = args.contains("--uninstall-cursor-hook")
        ? CursorHookInstaller.remove()
        : CursorHookInstaller.install()
    if let error = status.error {
        fputs("Cursor hook: \(error)\n", stderr)
        exit(1)
    }
    print("Cursor hook \(args.contains("--uninstall-cursor-hook") ? "removed" : (status.changed ? "installed" : "already installed")).")
    print("Config: \(status.config)")
    if let backup = status.backup { print("Backup: \(backup)") }
    print("Log:    \(CursorReader.logPath())")
    exit(0)
}
if args.contains("--once") { exit(runOnce()) }
if args.contains("--test-panel") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let index = args.firstIndex(of: "--preview-directory")
    let directory = index.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    do { try testPanel(previewDirectory: directory); exit(0) }
    catch { fputs("panel tests: \(error)\n", stderr); exit(1) }
}

if let idx = args.firstIndex(of: "--source"), idx + 1 < args.count, let m = SourceMode(rawValue: args[idx + 1]) {
    UserDefaults.standard.set(m.rawValue, forKey: "sourceMode")
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.selftest = args.contains("--selftest")
app.delegate = delegate
app.run()
