import AppKit
import Foundation
import SQLite3

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
    private(set) var turnActive = false
    private(set) var turnStart: Date?
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0

    /// 本次回复的实时速度 = 已完成调用的输出 token ÷ 这些调用的实际生成时间（不含工具执行）
    func liveTPS(now: Date = Date()) -> Double? {
        guard turnActive, turnOutput > 0, turnGenSeconds > 0 else { return nil }
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
        turnActive = false
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

        switch (type, payloadType) {
        case ("session_meta", _):
            if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty {
                sessionID = id
            }
        case ("turn_context", _):
            if let m = payload["model"] as? String { model = m }
            if generatedEnd == nil { samplingStart = ts }
            if !turnActive { beginTurn(at: ts) }
        case ("event_msg", "task_started"):
            samplingStart = ts
            generatedEnd = nil
            firstGeneratedAt = nil
            beginTurn(at: ts)
        case ("event_msg", "user_message"):
            if generatedEnd == nil { samplingStart = ts }
            if !turnActive { beginTurn(at: ts) }
        case ("event_msg", "task_complete"):
            turnActive = false
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
        turnActive = true
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

    var elapsed: Double { completedAt.timeIntervalSince(createdAt) }
    var effectiveTPS: Double { elapsed > 0 ? Double(output) / elapsed : 0 }
    var visibleTPS: Double { elapsed > 0 ? Double(max(0, output - reasoning)) / elapsed : 0 }
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

    /// 本次回复的实时速度 = 已完成调用的输出 token ÷ 这些调用的实际生成时间（不含工具执行）
    func liveTPS(now: Date = Date()) -> Double? {
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
        let sql = """
            SELECT id,
                   json_extract(data,'$.tokens.output'),
                   json_extract(data,'$.tokens.reasoning'),
                   json_extract(data,'$.tokens.input'),
                   coalesce(json_extract(data,'$.model.id'),json_extract(data,'$.modelID')),
                   json_extract(data,'$.time.created'),
                   json_extract(data,'$.time.completed')
            FROM \(messageTable)
            WHERE session_id = ? AND \(role)
            ORDER BY time_created DESC LIMIT 300
            """
        guard let stmt = query(sql, bind: sid) else { closeOnError(); return }
        var collected: [OCSample] = []
        var inflight: Date?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_int64(stmt, 5)
            let completed = sqlite3_column_int64(stmt, 6)
            guard created > 0 else { continue }
            let createdAt = Date(timeIntervalSince1970: Double(created) / 1000)
            if completed <= 0 {
                let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let age = Date().timeIntervalSince(createdAt)
                if !model.isEmpty && age >= 0 && age < 900 && inflight == nil { inflight = createdAt }
                continue
            }
            let output = sqlite3_column_int64(stmt, 1)
            guard output > 0 else { continue }
            var sample = OCSample(
                messageID: String(cString: sqlite3_column_text(stmt, 0)),
                model: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                input: sqlite3_column_int64(stmt, 3),
                output: output,
                reasoning: sqlite3_column_int64(stmt, 2),
                createdAt: createdAt,
                completedAt: Date(timeIntervalSince1970: Double(completed) / 1000),
                ttft: nil
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
            gen += s.elapsed
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
        let seconds = Double(value.integer(1) ?? 0)
        let nanos = Double(value.integer(2) ?? 0)
        guard nanos < 1_000_000_000 else { return nil }
        return seconds + nanos / 1_000_000_000
    }
}

final class AntigravityReader {
    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var inFlightStart: Date?
    private(set) var available = false
    private let root = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity")

    private func open(_ path: String) -> OpaquePointer? {
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

    func poll() {
        available = false
        inFlightStart = nil
        guard let summary = open((root as NSString).appendingPathComponent("conversation_summaries.db")) else { return }
        defer { sqlite3_close_v2(summary) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(summary, "SELECT conversation_id, status FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let idText = sqlite3_column_text(statement, 0) else { return }
        let id = String(cString: idText)
        guard UUID(uuidString: id) != nil else { return }
        let status = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let path = (root as NSString).appendingPathComponent("conversations/\(id).db")
        guard let db = open(path) else { return }
        defer { sqlite3_close_v2(db) }

        var steps: [Int: Date] = [:]
        var stepQuery: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT idx, metadata FROM steps ORDER BY idx DESC LIMIT 1000", -1, &stepQuery, nil) == SQLITE_OK else { return }
        while sqlite3_step(stepQuery) == SQLITE_ROW {
            guard let data = blob(stepQuery, 1), let proto = ProtoFields(data),
                  let time = proto.duration(7) ?? proto.duration(1), time > 0 else { continue }
            steps[Int(sqlite3_column_int64(stepQuery, 0))] = Date(timeIntervalSince1970: time)
        }
        sqlite3_finalize(stepQuery)

        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 300", -1, &query, nil) == SQLITE_OK else { return }
        var found: [Sample] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let data = blob(query, 0), let entry = ProtoFields(data),
                  let chat = entry.message(1), let usage = chat.message(4),
                  let output = usage.integer(3), output > 0, output <= UInt64(Int64.max),
                  let first = chat.duration(11), let stream = chat.duration(12), first + stream > 0,
                  let indices = entry.bytes(2), let lastIndex = Self.lastPackedIndex(indices),
                  let end = steps[lastIndex] else { continue }
            let elapsed = first + stream
            let reasoning = min(usage.integer(9) ?? 0, output)
            let input = min(usage.integer(2) ?? 0, UInt64(Int64.max))
            let cached = min(usage.integer(5) ?? 0, UInt64(Int64.max))
            let model = chat.bytes(21).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            found.append(Sample(startedAt: end.addingTimeInterval(-elapsed), completedAt: end,
                firstOutputAt: end.addingTimeInterval(-stream), model: model, input: Int64(input),
                cachedInput: Int64(cached), output: Int64(output), reasoning: Int64(reasoning), total: Int64(output)))
        }
        sqlite3_finalize(query)
        sessionID = id
        samples = found.sorted { $0.completedAt < $1.completedAt }
        let latest = steps.values.max()
        inFlightStart = status == "CASCADE_RUN_STATUS_RUNNING" ? latest.flatMap {
            Date().timeIntervalSince($0) < 900 ? $0 : nil
        } : nil
        available = true
    }

    private static func lastPackedIndex(_ data: Data) -> Int? {
        var value: UInt64 = 0, shift = 0
        var last: Int?
        for byte in data {
            guard shift <= 63, !(shift == 63 && byte > 1) else { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                guard value <= UInt64(Int.max) else { return nil }
                last = Int(value); value = 0; shift = 0
            } else { shift += 7 }
        }
        return shift == 0 ? last : nil
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
    static func tps(_ v: Double) -> String { String(format: "%.1f", v) }
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
    case auto, codex, opencode, claude, antigravity

    var label: String {
        switch self {
        case .auto: return "跟随最近活动"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }

    var symbol: String {
        switch self {
        case .codex, .auto: return "bolt.fill"
        case .opencode: return "terminal.fill"
        case .claude: return "sparkles"
        case .antigravity: return "moon.stars.fill"
        }
    }
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

struct SpeedSummary {
    let name: String
    let active: Bool
    let live: Double?
    let last: Double?
    let completedAt: Date?
    let history: [Double]
    let model: String
    let measurement: String

    private func valid(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var current: Double? { active ? valid(live) : nil }
    var value: String { (current ?? valid(last)).map(Fmt.tps) ?? "—" }
    var recent: [Double] { Array(history.filter { $0.isFinite && $0 > 0 }.suffix(12)) }

    func caption(now: Date = Date()) -> String {
        if current != nil { return "本轮" }
        guard valid(last) != nil else { return active ? "等待数据" : "暂无数据" }
        guard let date = completedAt else { return "上次" }
        let age = max(0, now.timeIntervalSince(date))
        let time: String
        if age < 5 { time = "刚刚" }
        else if age < 60 { time = "\(Int(age)) 秒前" }
        else if age < 3600 { time = "\(Int(age / 60)) 分钟前" }
        else if age < 86400 { time = "\(Int(age / 3600)) 小时前" }
        else { time = "\(Int(age / 86400)) 天前" }
        return "上次 · \(time)"
    }

    var tooltip: String {
        let identity = model.isEmpty ? name : "\(name) · \(model)"
        return "\(identity)\n\(measurement)\n趋势：最近 \(recent.count) 次调用，独立纵轴；非逐秒数据。"
    }
}

enum PanelStyle {
    static let activeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.black.withAlphaComponent(0.9)
    }
}

final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var color = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !values.isEmpty, let peak = values.max(), peak > 0 else { return }
        let area = bounds.insetBy(dx: 3, dy: 3)
        // Fixed 12 slots: absent samples aren't invented or filled with zeroes.
        let points = values.enumerated().map { index, value in
            NSPoint(x: area.minX + CGFloat(12 - values.count + index) * area.width / 11,
                    y: area.minY + CGFloat(value / peak) * area.height)
        }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.stroke()
        if let last = points.last {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)).fill()
        }
    }
}

// Custom, read-only views avoid disabled NSMenu text dimming and keep live
// values aligned without treating the summaries as clickable commands.
final class SummaryMenuView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let icon = NSImageView()
    private let sparkline = SparklineView()
    override var allowsVibrancy: Bool { false }

    init(source: SourceMode) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        icon.frame = NSRect(x: 15, y: 26, width: 18, height: 18)
        icon.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        nameLabel.frame = NSRect(x: 40, y: 26, width: 126, height: 18)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captionLabel.frame = NSRect(x: 40, y: 9, width: 126, height: 15)
        captionLabel.font = .systemFont(ofSize: 11)
        sparkline.frame = NSRect(x: 174, y: 18, width: 78, height: 24)
        valueLabel.frame = NSRect(x: 260, y: 17, width: 84, height: 24)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        valueLabel.alignment = .right
        for label in [nameLabel, captionLabel, valueLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(sparkline)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ summary: SpeedSummary) {
        nameLabel.stringValue = summary.name
        captionLabel.stringValue = summary.caption()
        valueLabel.stringValue = summary.value
        let color = summary.active ? PanelStyle.activeColor : NSColor.secondaryLabelColor
        nameLabel.textColor = color
        valueLabel.textColor = color
        captionLabel.textColor = .secondaryLabelColor
        icon.contentTintColor = color
        sparkline.color = color
        sparkline.values = summary.recent
        toolTip = summary.tooltip
        let state = summary.active ? "活跃" : "空闲"
        setAccessibilityLabel("\(summary.name)，\(state)，\(summary.caption())，\(summary.value) tokens 每秒")
    }
}

final class PanelHeaderView: NSView {
    override var allowsVibrancy: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        let title = NSTextField(labelWithString: "Token 速度")
        title.frame = NSRect(x: 16, y: 8, width: 180, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        let unit = NSTextField(labelWithString: "tok/s")
        unit.frame = NSRect(x: 280, y: 8, width: 64, height: 18)
        unit.font = .systemFont(ofSize: 11)
        unit.alignment = .right
        unit.textColor = .secondaryLabelColor
        addSubview(title)
        addSubview(unit)
    }
    required init?(coder: NSCoder) { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = RolloutReader()
    private let oc = OpenCodeReader()
    private let claude = ClaudeReader()
    private let antigravity = AntigravityReader()
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var lastScan = Date.distantPast
    private var lastOpenCodePoll = Date.distantPast
    var selftest = false
    private var currentSymbol = "-"
    private var summaryItems: [SourceMode: NSMenuItem] = [:]

    private var mode: SourceMode {
        get { SourceMode(rawValue: UserDefaults.standard.string(forKey: "sourceMode") ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sourceMode") }
    }

    private var activeSource: SourceMode {
        switch mode {
        case .codex: return .codex
        case .opencode: return .opencode
        case .claude: return .claude
        case .antigravity: return .antigravity
        case .auto:
            let sources: [(SourceMode, Date)] = [
                (.codex, max(reader.samples.last?.completedAt ?? .distantPast, reader.turnActive ? (reader.turnStart ?? .distantPast) : .distantPast)),
                (.opencode, max(oc.samples.last?.completedAt ?? .distantPast, oc.inFlightStart ?? .distantPast)),
                (.claude, max(claude.samples.last?.completedAt ?? .distantPast, claude.inFlightStart ?? .distantPast)),
                (.antigravity, antigravity.available ? max(antigravity.samples.last?.completedAt ?? .distantPast, antigravity.inFlightStart ?? .distantPast) : .distantPast)
            ]
            return sources.max { $0.1 < $1.1 }?.0 ?? .codex
        }
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
        print("selftest: antigravity=\(antigravity.samples.count) last=\(antigravity.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") session=\(antigravity.sessionID)")
        print("selftest: generating codex=\(isCodexGenerating) opencode=\(isOpenCodeGenerating)")
        print("selftest: live codex=\(reader.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(reader.turnOutput) opencode=\(oc.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(oc.turnOutput)")
        if let menu = statusItem.menu {
            menuWillOpen(menu)
            for source in [SourceMode.codex, .opencode, .claude, .antigravity] {
                print("selftest: menu \(summaryItems[source]?.title ?? "missing")")
            }
        }
        NSApp.terminate(nil)
    }

    func refresh() {
        if Date().timeIntervalSince(lastScan) > 5 {
            lastScan = Date()
            if let url = CodexHome.newestRollout() { reader.read(url) }
            claude.poll()
            antigravity.poll()
        } else if !reader.path.isEmpty {
            reader.read(URL(fileURLWithPath: reader.path))
        }
        if Date().timeIntervalSince(lastOpenCodePoll) > 2 {
            lastOpenCodePoll = Date()
            oc.poll()
        }
        updateTitle()
        updateSummaryItems()
    }

    private var isCodexGenerating: Bool {
        reader.turnActive && reader.turnStart != nil
    }

    private var isOpenCodeGenerating: Bool {
        oc.inFlightStart != nil
    }

    private let codexSymbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    private let opencodeSymbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

    private var generating: Bool {
        switch activeSource {
        case .opencode: return isOpenCodeGenerating
        case .codex, .auto: return isCodexGenerating
        case .claude: return claude.inFlightStart != nil
        case .antigravity: return antigravity.inFlightStart != nil
        }
    }

    private func liveSpeed() -> Double? {
        switch activeSource {
        case .opencode: return oc.liveTPS()
        case .codex, .auto: return reader.liveTPS()
        case .claude: return claude.liveTPS()
        case .antigravity: return nil
        }
    }

    private func turnElapsed() -> Double? {
        switch activeSource {
        case .opencode:
            guard let start = oc.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .codex, .auto:
            guard let start = reader.turnStart, reader.turnActive else { return nil }
            return Date().timeIntervalSince(start)
        case .claude:
            guard let start = claude.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        case .antigravity:
            guard let start = antigravity.inFlightStart else { return nil }
            return Date().timeIntervalSince(start)
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let source = activeSource
        currentSymbol = "logo-\(source.rawValue)"
        button.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: source.label)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = false
        button.attributedTitle = Fmt.statusTitle(titleText)
    }

    private var titleText: String {
        let button = statusItem.button
        let source = activeSource
        let name = source.label
        guard generating else {
            button?.toolTip = "\(name) 空闲（点开菜单查看历史速度）"
            return ""
        }
        if let live = liveSpeed() {
            let elapsed = Int(turnElapsed() ?? 0)
            button?.toolTip = "\(name) 本次回复实时速度 \(Fmt.tps(live)) tok/s（已用 \(elapsed) 秒）"
            return Fmt.tps(live)
        }
        let secs = Int(turnElapsed() ?? 0)
        button?.toolTip = "\(name) 正在生成，已用 \(secs) 秒"
        return "\(secs)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.autoenablesItems = false
        summaryItems.removeAll()
        let panelHeader = header("Token 速度 · tok/s")
        panelHeader.view = PanelHeaderView(frame: .zero)
        menu.addItem(panelHeader)
        for source in [SourceMode.codex, .opencode, .claude, .antigravity] {
            let item = section(source.label, symbol: source.symbol, highlight: false)
            item.view = SummaryMenuView(source: source)
            summaryItems[source] = item
            menu.addItem(item)
        }
        updateSummaryItems()
        menu.addItem(.separator())

        let sourceItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu(title: "菜单栏显示")
        sourceMenu.autoenablesItems = false
        for candidate in [SourceMode.auto, .codex, .opencode, .claude, .antigravity] {
            let item = NSMenuItem(title: candidate.label, action: #selector(setSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.image = ProviderLogo.image(candidate)
            item.state = (candidate == mode) ? .on : .off
            sourceMenu.addItem(item)
        }
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        menu.addItem(NSMenuItem(title: "退出 TokSpeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func updateSummaryItems() {
        func update(_ source: SourceMode, active: Bool, live: Double?, last: Double?,
                    completed: Date?, history: [Double], model: String, measurement: String) {
            guard let item = summaryItems[source] else { return }
            let summary = SpeedSummary(name: source.label, active: active, live: live, last: last,
                completedAt: completed, history: history, model: model, measurement: measurement)
            item.title = "\(summary.name) · \(summary.caption()) · \(summary.value) tok/s"
            (item.view as? SummaryMenuView)?.update(summary)
        }
        let cumulative = "本轮：已完成调用的输出 token ÷ 调用耗时之和，不含工具执行；非逐 token 瞬时速度。"
        update(.codex, active: isCodexGenerating, live: reader.liveTPS(), last: reader.samples.last?.effectiveTPS,
            completed: reader.samples.last?.completedAt, history: reader.samples.map(\.effectiveTPS), model: reader.model, measurement: cumulative)
        update(.opencode, active: isOpenCodeGenerating, live: oc.liveTPS(), last: oc.samples.last?.effectiveTPS,
            completed: oc.samples.last?.completedAt, history: oc.samples.map(\.effectiveTPS), model: oc.samples.last?.model ?? "", measurement: cumulative)
        update(.claude, active: claude.inFlightStart != nil, live: claude.liveTPS(), last: claude.samples.last?.effectiveTPS,
            completed: claude.samples.last?.completedAt, history: claude.samples.map(\.effectiveTPS), model: claude.samples.last?.model ?? "", measurement: cumulative + "\nClaude 按请求开始到首个完整输出块计时，含首字延迟。")
        update(.antigravity, active: antigravity.inFlightStart != nil, live: nil,
            last: antigravity.available ? antigravity.samples.last?.effectiveTPS : nil,
            completed: antigravity.samples.last?.completedAt,
            history: antigravity.available ? antigravity.samples.map(\.effectiveTPS) : [],
            model: antigravity.samples.last?.model ?? "",
            measurement: "上次调用：输出 token ÷（首 token 延迟 + 流式生成时长）；调用完成后更新。")
    }

    @objc private func setSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let next = SourceMode(rawValue: raw) else { return }
        mode = next
        refresh()
    }

    private func section(_ title: String, symbol: String, highlight: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        if highlight { item.title = "▸ \(title)（菜单栏显示中）" }
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func row(_ key: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(key)：\(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

}

// MARK: - Headless verification mode

func runOnce() -> Int32 {
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "opencode" {
        let dbIndex = CommandLine.arguments.firstIndex(of: "--db")
        let dbPath = dbIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? OpenCodeReader.dbPath
        let reader = OpenCodeReader(dbPath: dbPath)
        reader.poll()
        print("session:   \(reader.sessionID)")
        print("responses: \(reader.samples.count)")
        if let sample = reader.samples.last { print("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s") }
        print("live:      \(reader.liveTPS().map { Fmt.tps($0) } ?? "-") tok/s  turn output \(reader.turnOutput)")
        return reader.sessionID.isEmpty ? 1 : 0
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "antigravity" {
        let reader = AntigravityReader()
        reader.poll()
        print("session:   \(reader.sessionID)")
        print("responses: \(reader.samples.count)")
        if let sample = reader.samples.last {
            print("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s  elapsed \(Fmt.secs(sample.elapsed))  output \(sample.output)")
        }
        return reader.available ? 0 : 1
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
    print("rollout tests: passed (partial-line writes and repeat poll)")
}

func testPanel(previewDirectory: String?) throws {
    try testRolloutIncrementalRead()
    if Bundle.main.bundleURL.pathExtension == "app" {
        precondition(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon")
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        precondition(icon?.isValid == true, "Missing or invalid bundled app icon")
        print("app icon tests: passed (bundle declaration and ICNS loading)")
    }
    let now = Date()
    func summary(active: Bool = true, live: Double? = 46.1, last: Double? = 31.7,
                 history: [Double] = []) -> SpeedSummary {
        SpeedSummary(name: "Codex", active: active, live: live, last: last,
            completedAt: now.addingTimeInterval(-8), history: history, model: "test", measurement: "test")
    }
    precondition(summary().value == "46.1")
    for source in [SourceMode.codex, .opencode, .claude, .antigravity] {
        precondition(ProviderLogo.image(source)?.isTemplate == true, "Missing template logo: \(source.rawValue)")
    }
    precondition(summary().caption(now: now) == "本轮")
    precondition(summary(active: false).value == "31.7")
    precondition(summary(live: nil).caption(now: now) == "上次 · 8 秒前")
    precondition(summary(live: nil, last: nil).value == "—")
    precondition(summary(live: nil, last: nil).caption(now: now) == "等待数据")
    precondition(summary(active: false, live: nil, last: nil).caption(now: now) == "暂无数据")
    precondition(summary(live: .nan, last: .infinity).value == "—")
    precondition(summary(history: Array(1...20).map(Double.init) + [.nan, .infinity, 0, -1]).recent == Array(9...20).map(Double.init))
    for (appearance, expected) in [(NSAppearance.Name.darkAqua, 1.0), (.aqua, 0.0)] {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let color = PanelStyle.activeColor.usingColorSpace(.deviceRGB)!
            precondition(abs(Double(color.redComponent) - expected) < 0.001)
            precondition(abs(Double(color.alphaComponent) - 0.9) < 0.001)
        }
    }
    print("panel tests: passed (current/history/waiting/invalid values/12 samples/light & dark colors)")

    guard let directory = previewDirectory else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for dark in [true, false] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 322), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.96, alpha: 1).cgColor
        let header = PanelHeaderView(frame: .zero)
        header.frame.origin.y = 288
        root.addSubview(header)
        let examples: [(SourceMode, Bool, Double?, Double?, [Double])] = [
            (.codex, true, 46.1, 31.7, [22, 28, 24, 40, 32, 39, 51, 36, 42, 35, 49, 46]),
            (.claude, true, 113, 99, [65, 80, 75, 110, 98, 125, 104, 115, 106, 131, 120, 113]),
            (.opencode, false, nil, 16.2, [8, 14, 11, 13, 19, 15, 20, 16, 14, 18, 17, 16.2]),
            (.antigravity, true, nil, 30.8, [22, 28, 31, 20, 34, 24, 29, 32, 26, 33, 29, 30.8])
        ]
        for (index, entry) in examples.enumerated() {
            let (source, active, live, last, history) = entry
            let view = SummaryMenuView(source: source)
            view.frame.origin.y = 232 - CGFloat(index) * 56
            view.update(SpeedSummary(name: source.label, active: active, live: live, last: last,
                completedAt: now.addingTimeInterval(-8), history: history, model: "test", measurement: "test"))
            root.addSubview(view)
        }
        for (index, title) in ["菜单栏显示                                      ›", "退出 TokSpeed"].enumerated() {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 16, y: 34 - index * 24, width: 328, height: 20)
            label.font = .systemFont(ofSize: 13)
            root.addSubview(label)
        }
        root.display()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "PanelPreview", code: 1) }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PanelPreview", code: 2) }
        let path = (directory as NSString).appendingPathComponent(dark ? "panel-dark.png" : "panel-light.png")
        try png.write(to: URL(fileURLWithPath: path))
        print("preview: \(path)")
    }
}

let args = CommandLine.arguments
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
