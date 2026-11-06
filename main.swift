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
    case auto, codex, opencode, claude, antigravity, hermes

    var label: String {
        switch self {
        case .auto: return L10n.text("Automatic")
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .hermes: return "Hermes"
        }
    }

    var symbol: String {
        switch self {
        case .codex, .auto: return "bolt.fill"
        case .opencode: return "terminal.fill"
        case .claude: return "sparkles"
        case .antigravity: return "moon.stars.fill"
        case .hermes: return "paperplane.fill"
        }
    }
}

enum ToolOrder {
    // A static popularity-oriented default, not a measured or network-fetched ranking.
    static let popular: [SourceMode] = [.claude, .codex, .opencode, .antigravity, .hermes]

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
        if let speed, speed.isFinite, speed > 0 {
            return Fmt.tps(speed) + (self == .speedAndUnit ? " tok/s" : "")
        }
        return "\(Int(max(0, elapsed)))" + (self == .speedAndUnit ? " s" : "")
    }

    func usesLightning(active: Bool) -> Bool { !active || self == .iconOnly }
}

enum ProviderLogo {
    private static var cache: [SourceMode: NSImage] = [:]

    static func image(_ source: SourceMode) -> NSImage? {
        if source == .auto { return nil }
        if let image = cache[source] { return image }
        // A system symbol identifies Hermes until a licensed monochrome mark is bundled.
        if source == .hermes {
            let image = NSImage(systemSymbolName: source.symbol, accessibilityDescription: source.label)
            image?.isTemplate = true
            cache[source] = image
            return image
        }
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
        if current != nil { return L10n.text("This turn") }
        guard valid(last) != nil else { return active ? L10n.text("Waiting for data") : L10n.text("No data") }
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
        return "\(identity)\n\(measurement)\n" + L10n.text("Trend: last %d calls, independent scale; not per-second data.", recent.count)
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
        let path = Self.smoothPath(points)
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
        if let last = points.last {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)).fill()
        }
    }

    // Monotone cubic Hermite interpolation: smooth joins without inventing peaks
    // or dipping below zero. One sample remains a dot; missing slots stay empty.
    static func smoothPath(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let slopes = zip(points, points.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        var tangents = [slopes[0]]
        for index in 1..<(points.count - 1) {
            let left = slopes[index - 1], right = slopes[index]
            tangents.append(left * right <= 0 ? 0 : 2 * left * right / (left + right))
        }
        tangents.append(slopes.last!)
        for index in 0..<(points.count - 1) {
            let start = points[index], end = points[index + 1]
            let dx = (end.x - start.x) / 3
            path.curve(to: end,
                controlPoint1: NSPoint(x: start.x + dx, y: start.y + dx * tangents[index]),
                controlPoint2: NSPoint(x: end.x - dx, y: end.y - dx * tangents[index + 1]))
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
    var insertionEdge: MenuCardReorder.Edge? { didSet { needsDisplay = true } }
    var isDragging = false {
        didSet { subviews.forEach { $0.alphaValue = isDragging ? 0.35 : 1 }; needsDisplay = true }
    }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private let nameLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let icon = NSImageView()
    private let sparkline = SparklineView()
    override var allowsVibrancy: Bool { false }

    init(source: SourceMode) {
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        icon.frame = NSRect(x: 15, y: 0, width: 18, height: 18)
        icon.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        nameLabel.frame = NSRect(x: 40, y: 26, width: 126, height: 18)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captionLabel.frame = NSRect(x: 40, y: 9, width: 126, height: 15)
        captionLabel.font = .systemFont(ofSize: 11)
        // Align the logo with the whole two-line text block, not just the name.
        icon.frame.origin.y = nameLabel.frame.union(captionLabel.frame).midY - icon.frame.height / 2
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

    func bind(_ source: SourceMode) {
        self.source = source
        icon.image = ProviderLogo.image(source) ?? NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and the sparkline must behave like the rest of the card.
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
        insertionEdge = nil
        isDragging = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered && onDrag != nil && !isDragging {
            NSColor.tertiaryLabelColor.setFill()
            for x: CGFloat in [4, 8] {
                for y: CGFloat in [22, 27, 32] {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
                }
            }
        }
        if let edge = insertionEdge {
            NSColor.controlAccentColor.setFill()
            let y: CGFloat = edge == .top ? bounds.maxY - 2 : bounds.minY
            NSBezierPath(roundedRect: NSRect(x: 12, y: y, width: bounds.width - 24, height: 2),
                xRadius: 1, yRadius: 1).fill()
        }
    }

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
        toolTip = nil
        let state = summary.active ? L10n.text("Active") : L10n.text("Idle")
        setAccessibilityLabel(L10n.text("%@, %@, %@, %@ tokens per second", summary.name, state, summary.caption(), summary.value))
    }
}

final class PanelActionButton: NSButton {
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    override var allowsVibrancy: Bool { false }

    init(title: String, shortcut: String) {
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        autoresizingMask = [.width]
        titleLabel.frame = NSRect(x: 16, y: 5, width: 250, height: 18)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.frame = NSRect(x: 280, y: 5, width: 64, height: 18)
        shortcutLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.alignment = .right
        shortcutLabel.autoresizingMask = [.minXMargin]
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        target = self
        action = #selector(activateItem(_:))
        setAccessibilityLabel(title)
        setAccessibilityRole(.menuItem)
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
        let highlighted = hovered || isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        titleLabel.textColor = highlighted ? .alternateSelectedControlTextColor : .labelColor
        shortcutLabel.textColor = highlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    @objc private func activateItem(_ sender: Any?) {
        guard let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

final class PanelSeparatorView: NSView {
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 9))
        autoresizingMask = [.width]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSRect(x: 16, y: bounds.midY, width: bounds.width - 32, height: 0.5).fill()
    }
}

final class PanelHeaderView: NSView {
    override var allowsVibrancy: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        let title = NSTextField(labelWithString: L10n.text("Token speed"))
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
    private let defaults: UserDefaults
    private let detectInstalledTools: () -> Set<SourceMode>
    private var installedSources: Set<SourceMode>
    private let reader = RolloutReader()
    private let oc = OpenCodeReader()
    private let claude = ClaudeReader()
    private let antigravity = AntigravityReader()
    private let hermes = HermesReader()
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var lastScan = Date.distantPast
    private var lastOpenCodePoll = Date.distantPast
    var selftest = false
    private var currentSymbol = "-"
    private var summaryItems: [SourceMode: NSMenuItem] = [:]
    private var settingsController: SettingsWindowController?

    private var settingsState: SettingsState {
        SettingsState(sources: toolOrder, source: effectiveMode, display: display)
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
            (.antigravity, antigravity.inFlightStart != nil, antigravity.available ? max(antigravity.samples.last?.completedAt ?? .distantPast, antigravity.inFlightStart ?? .distantPast) : .distantPast),
            (.hermes, false, hermes.samples.last?.completedAt ?? .distantPast)
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
        print("selftest: antigravity=\(antigravity.samples.count) last=\(antigravity.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-") session=\(antigravity.sessionID)")
        print("selftest: hermes=\(hermes.samples.count) last=\(hermes.samples.last.map { Fmt.tps($0.effectiveTPS) } ?? "-")")
        print("selftest: generating codex=\(isCodexGenerating) opencode=\(isOpenCodeGenerating)")
        print("selftest: live codex=\(reader.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(reader.turnOutput) opencode=\(oc.liveTPS().map { Fmt.tps($0) } ?? "-") turnOut=\(oc.turnOutput)")
        if let menu = statusItem.menu {
            menuWillOpen(menu)
            for source in ToolOrder.popular {
                print("selftest: menu \(summaryItems[source]?.title ?? "missing")")
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
            if installedSources.contains(.antigravity) { antigravity.poll() }
            if installedSources.contains(.hermes) { hermes.poll() }
        } else if installedSources.contains(.codex), !reader.path.isEmpty {
            reader.read(URL(fileURLWithPath: reader.path))
        }
        if Date().timeIntervalSince(lastOpenCodePoll) > 2 {
            lastOpenCodePoll = Date()
            if installedSources.contains(.opencode) { oc.poll() }
        }
        updateTitle()
        updateSummaryItems()
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
        case .hermes: return false
        }
    }

    private func liveSpeed() -> Double? {
        switch activeSource {
        case .opencode: return oc.liveTPS()
        case .codex: return reader.liveTPS()
        case .auto: return nil
        case .claude: return claude.liveTPS()
        case .antigravity: return nil
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
        } else if let speed {
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
        summaryItems.removeAll()
        let panelHeader = header(L10n.text("Token speed") + " · tok/s")
        panelHeader.view = PanelHeaderView(frame: .zero)
        menu.addItem(panelHeader)
        if toolOrder.isEmpty { menu.addItem(header(L10n.text("No tools installed"))) }
        for source in toolOrder {
            let item = section(source.label, symbol: source.symbol, highlight: false)
            item.view = SummaryMenuView(source: source)
            summaryItems[source] = item
            menu.addItem(item)
        }
        configureReordering(in: menu)
        updateSummaryItems()
        menu.addItem(panelSeparator())

        let settings = NSMenuItem(title: L10n.text("Settings") + "…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.view = PanelActionButton(title: settings.title, shortcut: "⌘,")
        menu.addItem(settings)

        menu.addItem(panelSeparator())
        let quit = NSMenuItem(title: L10n.text("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.view = PanelActionButton(title: quit.title, shortcut: "⌘Q")
        menu.addItem(quit)
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
        if let menu {
            let items = menu.items.filter { $0.view is SummaryMenuView }
            // Rebind fixed slots rather than removing/inserting items in an open NSMenu.
            if items.count == order.count {
                summaryItems.removeAll()
                for (item, source) in zip(items, order) {
                    (item.view as? SummaryMenuView)?.bind(source)
                    item.title = source.label
                    summaryItems[source] = item
                }
                configureReordering(in: menu)
                updateSummaryItems()
            }
        }
        settingsChanged()
        return true
    }

    private func configureReordering(in menu: NSMenu) {
        let rows = menu.items.compactMap { $0.view as? SummaryMenuView }
        let sources = rows.map(\.source)
        for (index, row) in rows.enumerated() {
            row.onDrag = rows.count > 1 ? { [weak self, weak menu] card, event in
                guard let self, let menu else { return }
                let currentRows = menu.items.compactMap { $0.view as? SummaryMenuView }
                MenuCardReorder.track(card, event: event, rows: currentRows) { destination in
                    // Installation detection can refresh during tracking. Do not commit a stale list.
                    guard self.toolOrder == sources else { return }
                    self.moveTool(card.source, to: destination, in: menu)
                }
            } : nil
            var actions: [NSAccessibilityCustomAction] = []
            for (title, destination) in [("Move up", index - 1), ("Move down", index + 1)] where rows.indices.contains(destination) {
                actions.append(NSAccessibilityCustomAction(name: L10n.text(title), handler: { [weak self, weak menu, weak row] in
                    guard let self, let menu, let row, self.toolOrder == sources else { return false }
                    return self.moveTool(row.source, to: destination, in: menu)
                }))
            }
            row.setAccessibilityCustomActions(actions)
        }
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
        let cumulative = L10n.text("This turn: output tokens / total completed-call duration, excluding tool execution; not instantaneous per-token speed.")
        update(.codex, active: isCodexGenerating, live: reader.liveTPS(), last: reader.samples.last?.effectiveTPS,
            completed: reader.samples.last?.completedAt, history: reader.samples.map(\.effectiveTPS), model: reader.model, measurement: cumulative)
        update(.opencode, active: isOpenCodeGenerating, live: oc.liveTPS(), last: oc.samples.last?.effectiveTPS,
            completed: oc.samples.last?.completedAt, history: oc.samples.map(\.effectiveTPS), model: oc.samples.last?.model ?? "", measurement: cumulative)
        update(.claude, active: claude.inFlightStart != nil, live: claude.liveTPS(), last: claude.samples.last?.effectiveTPS,
            completed: claude.samples.last?.completedAt, history: claude.samples.map(\.effectiveTPS), model: claude.samples.last?.model ?? "", measurement: cumulative + "\n" + L10n.text("Claude measures from request start to the first complete output block, including time to first token."))
        update(.antigravity, active: antigravity.inFlightStart != nil, live: nil,
            last: antigravity.available ? antigravity.samples.last?.effectiveTPS : nil,
            completed: antigravity.samples.last?.completedAt,
            history: antigravity.available ? antigravity.samples.map(\.effectiveTPS) : [],
            model: antigravity.samples.last?.model ?? "",
            measurement: L10n.text("Last call: output tokens / (time to first token + streaming duration); updated after completion."))
        update(.hermes, active: false, live: nil, last: hermes.samples.last?.effectiveTPS,
            completed: hermes.samples.last?.completedAt, history: hermes.samples.map(\.effectiveTPS),
            model: hermes.samples.last?.model ?? "",
            measurement: L10n.text("Last call: output tokens / logged API latency (rounded to 0.1 s); updated after completion. No live generation state."))
    }

    private func section(_ title: String, symbol: String, highlight: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        if highlight { item.title = "▸ \(title)" }
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func panelSeparator() -> NSMenuItem {
        // Native separator items ignore custom views and keep the system's stroke.
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = PanelSeparatorView(frame: .zero)
        return item
    }

    // Exercise real menu actions using an isolated defaults suite, never source logs.
    func testMenuPreferences() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        func openMenu() { rebuildMenu(menu) }
        func verifyQuitPlacement() {
            let quit = menu.items.last!
            precondition(quit.action == #selector(NSApplication.terminate(_:)) && quit.submenu == nil)
            precondition(quit.target === NSApp && quit.keyEquivalent == "q")
            precondition(menu.items[menu.items.count - 2].view is PanelSeparatorView)
            func containsQuit(_ submenu: NSMenu) -> Bool {
                submenu.items.contains { $0.action == #selector(NSApplication.terminate(_:)) || ($0.submenu.map(containsQuit) ?? false) }
            }
            precondition(!menu.items.compactMap(\.submenu).contains(where: containsQuit), "Quit must only appear as the last top-level item")
        }
        func send(_ control: NSControl) {
            precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
        }
        openMenu()
        verifyQuitPlacement()
        precondition(menu.items.last?.title == L10n.text("Quit"))
        precondition(menu.items.allSatisfy { $0.submenu == nil })
        let settings = menu.items.first { $0.action == #selector(showSettings(_:)) }!
        precondition(settings.title == L10n.text("Settings") + "…" && settings.keyEquivalent == ",")
        precondition(NSApp.sendAction(settings.action!, to: settings.target, from: settings))
        let controller = settingsController!
        precondition(controller.window?.isVisible == true)
        let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        precondition(controller.window!.performKeyEquivalent(with: closeEvent))
        precondition(controller.window?.isVisible == false, "Command-W closes Settings, not the app")
        precondition(NSApp.sendAction(settings.action!, to: settings.target, from: settings))
        precondition(settingsController === controller && controller.window?.isVisible == true, "Reuse the settings window")
        defer { controller.window?.close() }
        precondition(menu.items.compactMap { $0.view is SummaryMenuView ? $0.title : nil } == toolOrder.map {
            "\($0.label) · \(L10n.text("No data")) · — tok/s"
        })
        precondition(display == .speedAndUnit)
        controller.displayPopup.selectItem(at: 2)
        send(controller.displayPopup)
        precondition(display == .iconOnly)
        precondition(statusItem.button?.title == "" && currentSymbol == "bolt.fill")
        controller.sourcePopup.selectItem(at: ([SourceMode.auto] + toolOrder).firstIndex(of: .opencode)!)
        send(controller.sourcePopup)
        precondition(mode == .opencode)
        precondition(controller.window!.contentView!.subviews.count == 1, "Settings only contains the two-row grid")
        let originalItems = menu.items.filter { $0.view is SummaryMenuView }
        let originalViews = originalItems.map { $0.view! }
        precondition(moveTool(.claude, to: 2, in: menu))
        precondition(toolOrder == [.codex, .opencode, .claude, .antigravity, .hermes])
        let reorderedItems = menu.items.filter { $0.view is SummaryMenuView }
        precondition(zip(originalItems, reorderedItems).allSatisfy { $0 === $1 }, "Reordering preserves NSMenu slots")
        precondition(zip(originalViews, reorderedItems.map { $0.view! }).allSatisfy { $0 === $1 }, "Reordering preserves attached views")
        precondition(menu.items.compactMap { ($0.view as? SummaryMenuView)?.source } == toolOrder)
        precondition(toolOrder.allSatisfy { (summaryItems[$0]?.view as? SummaryMenuView)?.source == $0 })
        precondition(controller.state?.sources == toolOrder && controller.state?.source == .opencode)
        let restored = AppDelegate(defaults: defaults, detectInstalledTools: { Set(ToolOrder.popular) })
        precondition(restored.toolOrder == toolOrder && restored.mode == mode && restored.display == display)
        precondition(controller.displayPopup.indexOfSelectedItem == 2)
        let firstCard = menu.items[1].view as! SummaryMenuView
        precondition(firstCard.accessibilityCustomActions()?.count == 1)
        let moveDown = firstCard.accessibilityCustomActions()!.first!
        precondition(moveDown.name == L10n.text("Move down") && moveDown.handler?() == true)
        precondition(toolOrder == [.opencode, .codex, .claude, .antigravity, .hermes], "VoiceOver can reorder without dragging")
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
            let waiting = choice.title(active: true, speed: nil, elapsed: 8)
            precondition(statusItem.button?.attributedTitle.string == (waiting.isEmpty ? "" : " " + waiting))
            renderStatus(source: .opencode, active: false, speed: nil, elapsed: 0)
            precondition(statusItem.button?.title == "" && currentSymbol == "bolt.fill")
        }
        print("settings smoke: passed (two-row window/reopen/source/display/persistence/status modes/top-level quit)")
        print("menu reorder tests: passed (fixed slots/source rebinding/VoiceOver actions/persistence)")
    }

    func testInstalledVisibility(setInstalled: (Set<SourceMode>) -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        mode = .claude
        defaults.set(["opencode", "claude", "codex", "antigravity"], forKey: "toolOrder")
        for available: Set<SourceMode> in [[.codex, .opencode], [.claude], [.hermes], []] {
            setInstalled(available)
            installedSources = detectInstalledTools()
            rebuildMenu(menu)
            updateTitle()
            precondition(Set(summaryItems.keys) == available)
            let controller = prepareSettings()
            let choices = controller.sourcePopup.itemArray.compactMap { ($0.representedObject as? String).flatMap(SourceMode.init(rawValue:)) }
            precondition(choices == [.auto] + toolOrder)
            precondition(controller.sourcePopup.selectedItem?.representedObject as? String == effectiveMode.rawValue)
            let cards = menu.items.compactMap { $0.view as? SummaryMenuView }
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
        precondition(savedToolOrder == [.codex, .claude, .opencode, .antigravity, .hermes], "Hidden tools retain their saved positions")
        setInstalled(Set(ToolOrder.popular))
        installedSources = detectInstalledTools()
        precondition(effectiveMode == .claude && toolOrder == savedToolOrder)
        print("installation menu tests: passed (partial/all/none, hidden choices, pin fallback, restored order)")
    }

}

// MARK: - Headless verification mode

func runOnce() -> Int32 {
    if let idx = CommandLine.arguments.firstIndex(of: "--source"), idx + 1 < CommandLine.arguments.count,
       CommandLine.arguments[idx + 1] == "hermes" {
        let reader = HermesReader()
        reader.poll()
        print("samples:   \(reader.samples.count)")
        if let sample = reader.samples.last {
            print("model:     \(sample.model)")
            print("output:    \(sample.output)")
            print("elapsed:   \(Fmt.secs(sample.elapsed))")
            print("speed:     \(Fmt.tps(sample.effectiveTPS)) tok/s")
        }
        return 0
    }
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
    try testHermesReader()
    try testInstalledTools()
    testPresentationPreferences()
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
    for source in ToolOrder.popular {
        precondition(ProviderLogo.image(source)?.isTemplate == true, "Missing template logo: \(source.rawValue)")
        let card = SummaryMenuView(source: source)
        card.toolTip = "stale detail"
        card.update(summary())
        precondition(card.toolTip == nil, "Hovering a tool card must not show detail text")
        let logo = card.subviews.compactMap { $0 as? NSImageView }.first!
        let text = card.subviews.compactMap { $0 as? NSTextField }.filter { $0.frame.minX == 40 }
        precondition(text.count == 2)
        let textBounds = text[0].frame.union(text[1].frame)
        precondition(abs(logo.frame.midY - textBounds.midY) < 0.001, "Logo must center on both text lines")
    }
    precondition(summary().caption(now: now) == L10n.text("This turn"))
    precondition(summary(active: false).value == "31.7")
    precondition(summary(live: nil).caption(now: now) == L10n.text("Last · %@", L10n.text("%d s ago", 8)))
    precondition(summary(live: nil, last: nil).value == "—")
    precondition(summary(live: nil, last: nil).caption(now: now) == L10n.text("Waiting for data"))
    precondition(summary(active: false, live: nil, last: nil).caption(now: now) == L10n.text("No data"))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 388), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.96, alpha: 1).cgColor
        let header = PanelHeaderView(frame: .zero)
        header.frame.origin.y = 354
        root.addSubview(header)
        let examples: [(SourceMode, Bool, Double?, Double?, [Double])] = [
            (.claude, true, 113, 99, [65, 80, 75, 110, 98, 125, 104, 115, 106, 131, 120, 113]),
            (.codex, true, 46.1, 31.7, [22, 28, 24, 40, 32, 39, 51, 36, 42, 35, 49, 46]),
            (.opencode, false, nil, 16.2, [8, 14, 11, 13, 19, 15, 20, 16, 14, 18, 17, 16.2]),
            (.antigravity, true, nil, 30.8, [22, 28, 31, 20, 34, 24, 29, 32, 26, 33, 29, 30.8]),
            (.hermes, false, nil, 34.8, [18, 25, 22, 31, 28, 36, 30, 33, 29, 38, 32, 34.8])
        ]
        for (index, entry) in examples.enumerated() {
            let (source, active, live, last, history) = entry
            let view = SummaryMenuView(source: source)
            view.frame.origin.y = 298 - CGFloat(index) * 56
            view.update(SpeedSummary(name: source.label, active: active, live: live, last: last,
                completedAt: now.addingTimeInterval(-8), history: history, model: "test", measurement: "test"))
            root.addSubview(view)
        }
        for (index, title) in [L10n.text("Settings") + "…", L10n.text("Quit")].enumerated() {
            let action = PanelActionButton(title: title, shortcut: index == 0 ? "⌘," : "⌘Q")
            action.frame.origin.y = index == 0 ? 40 : 6
            root.addSubview(action)
        }
        let separator = PanelSeparatorView(frame: .zero)
        separator.frame.origin.y = 32
        root.addSubview(separator)
        try capture(root, name: dark ? "panel-dark.png" : "panel-light.png")
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
    }
    precondition(L10n.text("Missing translation falls back to English") == "Missing translation falls back to English")
    print("localization tests: passed (8 languages, matching/fallback/completeness/format arguments); selected=\(L10n.language)")

    precondition(ToolOrder.normalized([]) == ToolOrder.popular)
    precondition(ToolOrder.normalized(["auto", "unknown", "opencode", "opencode"]) == [.opencode, .claude, .codex, .antigravity, .hermes])
    precondition(ToolOrder.normalized(["claude", "codex", "opencode", "antigravity"]) == ToolOrder.popular, "Existing preferences gain Hermes without reordering tools")
    precondition(ToolOrder.moving(.claude, to: -1, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.antigravity, to: ToolOrder.popular.count, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.auto, to: 0, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.claude, to: 3, in: ToolOrder.popular) == [.codex, .opencode, .antigravity, .claude, .hermes])
    precondition(ToolOrder.moving(.antigravity, to: 0, in: ToolOrder.popular) == [.antigravity, .claude, .codex, .opencode, .hermes])
    let frames = (0..<4).map { NSRect(x: 0, y: 168 - $0 * 56, width: 360, height: 56) }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 100, y: 220), frames: frames, from: 3) == .init(index: 0, slot: 0))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 100, y: 4), frames: frames, from: 0) == .init(index: 3, slot: 4))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 100, y: 60), frames: frames, from: 0) == .init(index: 2, slot: 3))
    for point in [NSPoint(x: -1, y: 100), NSPoint(x: 361, y: 100), NSPoint(x: 100, y: -1), NSPoint(x: 100, y: 225)] {
        precondition(MenuCardReorder.destination(at: point, frames: frames, from: 0) == nil)
    }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 100, y: 200), frames: frames, from: 0) == nil)
    precondition(MenuCardReorder.destination(at: .zero, frames: [], from: 0) == nil)
    precondition(MenuCardReorder.destination(at: NSPoint(x: 100, y: 200), frames: [frames[0]], from: 0) == nil)
    for active in [false, true] {
        for display in StatusDisplay.allCases {
            let hidden = !active || display == .iconOnly
            precondition(display.usesLightning(active: active) == hidden)
            precondition(display.title(active: active, speed: 46.1, elapsed: 8) == (hidden ? "" : display == .speedAndUnit ? "46.1 tok/s" : "46.1"))
            precondition(display.title(active: active, speed: nil, elapsed: 8) == (hidden ? "" : display == .speedAndUnit ? "8 s" : "8"))
        }
    }
    let now = Date()
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, true, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .opencode)
    precondition(AppDelegate.preferredSource(mode: .claude, activity: [(.codex, true, now)]) == .claude)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.hermes, false, now)]) == .hermes)

    for values: [Double] in [[], [12], [12, 24], [0, 100, 0, 100, 1], [50, 50, 50], [1, 2, 4, 100]] {
        let points = values.enumerated().map { NSPoint(x: Double($0.offset) * 10, y: $0.element) }
        let path = SparklineView.smoothPath(points)
        precondition(path.elementCount == points.count)
        var previous = points.first ?? .zero
        for index in 1..<max(1, path.elementCount) {
            var controls = [NSPoint](repeating: .zero, count: 3)
            precondition(path.element(at: index, associatedPoints: &controls) == .curveTo)
            let start = previous, end = controls[2]
            for step in 0...100 {
                let t = Double(step) / 100, u = 1 - t
                let y = u*u*u*start.y + 3*u*u*t*controls[0].y + 3*u*t*t*controls[1].y + t*t*t*end.y
                precondition(y >= min(start.y, end.y) - 0.0001 && y <= max(start.y, end.y) + 0.0001, "Smooth curves must not overshoot")
            }
            previous = end
        }
    }
    print("presentation tests: passed (ordering/status modes/active-source priority/smooth curves without overshoot)")

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
    precondition(detect().isEmpty, "Leftover data is not an installation")
    try write(".local/bin/codex", executable: true)
    try write(".opencode/bin/opencode", executable: true)
    try write(".nvm/versions/node/v22/bin/claude", executable: true)
    try write("custom/bin/antigravity")
    let path = root.appendingPathComponent("custom/bin").path
    precondition(detect(path: path) == [.codex, .opencode, .claude], "A non-executable file is not a CLI")
    try write(".local/bin/hermes", executable: true)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("custom/bin/antigravity").path)
    precondition(detect(path: path) == Set(ToolOrder.popular))
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
    print("installation detection tests: passed (CLI/PATH/Finder/NVM/desktop/Launch Services/trash/stale logs)")
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
