import Foundation
import SQLite3

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

final class OpenCodeReader: SpeedSourceReader {
    let source: SourceMode = .opencode

    private struct SessionCandidate {
        let id: String
        let directory: String
        let title: String
        let updated: Int64
        let v2: Bool
    }

    private struct LoadedSession {
        let candidate: SessionCandidate
        let samples: [OCSample]
        let rawInFlightStart: Date?
        let lastUserBoundary: Date
        let turnStart: Date?
        let turnOutput: Int64
        let turnGenSeconds: Double

        func activeStart(at now: Date) -> Date? {
            guard let start = rawInFlightStart else { return nil }
            let age = now.timeIntervalSince(start)
            guard age >= -2 && age < 900,
                  start >= lastUserBoundary,
                  !samples.contains(where: { $0.createdAt > start }) else { return nil }
            return start
        }

        func liveTPS(at now: Date) -> Double? {
            guard activeStart(at: now) != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
            return Double(turnOutput) / turnGenSeconds
        }
    }

    private let databasePath: String
    private var dbCache = SQLiteDatabaseCache<[LoadedSession]>()
    private(set) var databaseReadCount = 0
    private(set) var samples: [OCSample] = []
    private(set) var sessionID = ""
    private(set) var directory = ""
    private(set) var inFlightStart: Date?
    private(set) var turnStart: Date?
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0
    private(set) var sessions: [SessionSummary] = []
    private var isV2 = false

    /// This turn uses the same per-call durations as history, without gaps between calls.
    func liveTPS() -> Double? {
        guard inFlightStart != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
        return Double(turnOutput) / turnGenSeconds
    }

    static let dbPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/share/opencode/opencode.db")

    init(dbPath: String = OpenCodeReader.dbPath) { databasePath = dbPath }

    var hasOnceData: Bool { !sessionID.isEmpty }

    func poll(forceScan: Bool, now: Date) {
        poll(now: now)
    }

    func poll(now: Date = Date()) {
        guard let loaded = dbCache.read(databasePath, load: { path in
            loadAllSessions(path: path, now: now)
        }) else {
            if SQLiteDatabaseStamp(databasePath) == nil {
                dbCache.invalidate()
                clear()
            }
            return
        }
        guard !loaded.isEmpty else {
            clear()
            return
        }

        let primary = loaded.filter { $0.activeStart(at: now) != nil }.max(by: { $0.candidate.updated < $1.candidate.updated })
            ?? loaded.max(by: { $0.candidate.updated < $1.candidate.updated })!
        sessionID = primary.candidate.id
        directory = primary.candidate.directory
        isV2 = primary.candidate.v2
        samples = primary.samples
        inFlightStart = primary.activeStart(at: now)
        turnStart = primary.turnStart
        turnOutput = primary.turnOutput
        turnGenSeconds = primary.turnGenSeconds

        let cutoff = now.addingTimeInterval(-SpeedSummary.multiSessionWindow)
        sessions = loaded.compactMap { entry -> SessionSummary? in
            let activeStart = entry.activeStart(at: now)
            let isActive = activeStart != nil
            let lastCompleted = entry.samples.last?.completedAt
            let updatedAt = Date(timeIntervalSince1970: Double(entry.candidate.updated) / 1000)
            let activityAt = max(isActive ? max(activeStart ?? .distantPast, updatedAt) : .distantPast,
                                 lastCompleted ?? .distantPast)
            guard isActive || (lastCompleted != nil && activityAt >= cutoff) else { return nil }
            let dirName = (entry.candidate.directory as NSString).lastPathComponent
            let fallback = dirName.isEmpty || dirName == "/" ? entry.candidate.id : dirName
            return SessionSummary(
                id: entry.candidate.id,
                title: SessionSummary.cleanTitle(entry.candidate.title, fallback: fallback),
                active: isActive,
                live: entry.liveTPS(at: now),
                last: entry.samples.last?.effectiveTPS,
                activityAt: activityAt,
                inFlightStart: activeStart
            )
        }
    }

    private func clear() {
        sessionID = ""
        directory = ""
        samples = []
        inFlightStart = nil
        turnStart = nil
        turnOutput = 0
        turnGenSeconds = 0
        sessions = []
    }

    private func loadAllSessions(path: String, now: Date) -> [LoadedSession]? {
        databaseReadCount += 1
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close_v2(handle) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        var titleColumns: [String: Bool] = [:]
        let candidates = recentSessions(db: db, now: now, titleColumns: &titleColumns)
        if candidates.isEmpty { return [] }
        var loaded: [LoadedSession] = []
        for candidate in candidates {
            if let data = load(db: db, candidate: candidate) {
                loaded.append(data)
            }
        }
        return loaded
    }

    private func query(db: OpaquePointer, _ sql: String, bind: String? = nil) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, stmt != nil else { return nil }
        if let bind {
            sqlite3_bind_text(stmt, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return stmt
    }

    private func hasTitleColumn(db: OpaquePointer, table: String, cache: inout [String: Bool]) -> Bool {
        if let cached = cache[table] { return cached }
        guard let stmt = query(db: db, "PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(stmt) }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == "title" {
                found = true
                break
            }
        }
        cache[table] = found
        return found
    }

    private func recentSessions(db: OpaquePointer, now: Date, titleColumns: inout [String: Bool]) -> [SessionCandidate] {
        // An empty/failed latest session must not hide an older usable history.
        // V2 stores sessions separately from the legacy V1 tables.
        var all: [SessionCandidate] = []
        let nowSec = Int64(now.timeIntervalSince1970)
        for v2 in [true, false] {
            let sessionsTable = v2 ? "session_v2" : "session"
            let messages = v2 ? "session_message" : "message"
            let role = v2 ? "m.type = 'assistant'" : "json_extract(m.data,'$.role') = 'assistant'"
            let hasTitle = hasTitleColumn(db: db, table: sessionsTable, cache: &titleColumns)
            let titleSelect = hasTitle ? "coalesce(s.title, '')" : "''"
            let titleInner = hasTitle ? ", title" : ""
            let sql = """
                SELECT s.id, s.directory, s.time_updated, \(titleSelect) FROM
                  (SELECT id, directory, time_updated\(titleInner) FROM \(sessionsTable) ORDER BY time_updated DESC LIMIT 50) s
                WHERE EXISTS (SELECT 1 FROM \(messages) m WHERE m.session_id = s.id AND \(role)
                  AND (coalesce(json_extract(m.data,'$.tokens.output'),0) > 0
                    OR (json_extract(m.data,'$.time.completed') IS NULL
                      AND m.time_created > (\(nowSec) - 900) * 1000)))
                ORDER BY s.time_updated DESC LIMIT 8
                """
            guard let stmt = query(db: db, sql) else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                all.append(SessionCandidate(
                    id: String(cString: idPtr),
                    directory: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    title: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    updated: sqlite3_column_int64(stmt, 2),
                    v2: v2
                ))
            }
        }
        all.sort { $0.updated > $1.updated }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.id).inserted }
        guard let newest = unique.first else { return [] }
        let cutoffMs = Int64((now.timeIntervalSince1970 - SpeedSummary.multiSessionWindow) * 1000)
        var selected: [SessionCandidate] = [newest]
        for candidate in unique.dropFirst() where candidate.updated >= cutoffMs && selected.count < SpeedSummary.maxVisibleSessions {
            selected.append(candidate)
        }
        return selected
    }

    private func load(db: OpaquePointer, candidate: SessionCandidate) -> LoadedSession? {
        let sid = candidate.id
        let v2 = candidate.v2
        let messageTable = v2 ? "session_message" : "message"
        let role = v2 ? "type = 'assistant'" : "json_extract(data,'$.role') = 'assistant'"
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
                   \(v2 ? timestamp("firstToken") : "NULL"),
                   \(v2 ? timestamp("streamed") : "NULL"),
                   json_extract(data,'$.time.completed') IS NULL
            FROM \(messageTable)
            WHERE session_id = ? AND \(role)
            ORDER BY time_created DESC LIMIT 300
            """
        guard let stmt = query(db: db, sql, bind: sid) else { return nil }
        defer { sqlite3_finalize(stmt) }
        var collected: [OCSample] = []
        var inflight: Date?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_double(stmt, 5)
            guard created.isFinite, created > 0 else { continue }
            let createdAt = Date(timeIntervalSince1970: created / 1000)
            if sqlite3_column_int(stmt, 9) != 0 {
                let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                if !model.isEmpty && inflight == nil { inflight = createdAt }
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
            let sample = OCSample(
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
            collected.append(sample)
        }
        if !v2 && !collected.isEmpty {
            let firstTimes = firstOutputTimes(db: db, messageIDs: collected.map(\.messageID))
            for index in collected.indices {
                if let first = firstTimes[collected[index].messageID] {
                    collected[index].ttft = first.timeIntervalSince(collected[index].createdAt)
                }
            }
        }
        collected.reverse()
        let turn = computeCurrentTurn(db: db, sessionID: sid, v2: v2, samples: collected)
        return LoadedSession(
            candidate: candidate,
            samples: collected,
            rawInFlightStart: inflight,
            lastUserBoundary: turn.boundary,
            turnStart: turn.turnStart,
            turnOutput: turn.turnOutput,
            turnGenSeconds: turn.turnGenSeconds
        )
    }

    /// 以最近一条 user 消息为界，统计本次回复已完成的调用
    private func computeCurrentTurn(db: OpaquePointer, sessionID: String, v2: Bool, samples: [OCSample])
        -> (boundary: Date, turnStart: Date?, turnOutput: Int64, turnGenSeconds: Double) {
        let sql = v2
            ? "SELECT MAX(time_created) FROM session_message WHERE session_id = ? AND type = 'user'"
            : "SELECT MAX(time_created) FROM message WHERE session_id = ? AND json_extract(data,'$.role') = 'user'"
        var lastUser = 0.0
        if let stmt = query(db: db, sql, bind: sessionID) {
            if sqlite3_step(stmt) == SQLITE_ROW {
                lastUser = Double(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        let boundary = lastUser > 0 ? Date(timeIntervalSince1970: lastUser / 1000) : Date.distantPast
        var total: Int64 = 0
        var gen: Double = 0
        var start: Date?
        for s in samples where s.createdAt > boundary {
            if start == nil { start = s.createdAt }
            total += s.output
            gen += s.measurementSeconds
        }
        return (boundary, start, total, gen)
    }

    private func firstOutputTimes(db: OpaquePointer, messageIDs: [String]) -> [String: Date] {
        guard !messageIDs.isEmpty else { return [:] }
        var result: [String: Date] = [:]
        let chunkSize = 200
        var offset = 0
        while offset < messageIDs.count {
            let chunk = Array(messageIDs[offset..<min(offset + chunkSize, messageIDs.count)])
            offset += chunkSize
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT message_id, MIN(json_extract(data,'$.time.start')) FROM part
                WHERE message_id IN (\(placeholders))
                  AND json_extract(data,'$.type') IN ('text','reasoning')
                GROUP BY message_id
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }
            for (index, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                let ms = sqlite3_column_int64(stmt, 1)
                if ms > 0 {
                    result[String(cString: idPtr)] = Date(timeIntervalSince1970: Double(ms) / 1000)
                }
            }
        }
        return result
    }

    var medianTPS: Double {
        let values = samples.map(\.effectiveTPS).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    var totalOutput: Int64 { samples.reduce(0) { $0 + $1.output } }

    var summary: SpeedSummary {
        SpeedSummary(name: source.label, active: inFlightStart != nil,
            live: liveTPS(), last: samples.last?.effectiveTPS, completedAt: samples.last?.completedAt,
            history: samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: $0.effectiveTPS) }, model: samples.last?.model ?? "",
            measurement: L10n.text("Completed calls: streaming speed when available, otherwise end to end. This turn combines those calls without the time between them."),
            sessions: sessions,
            metrics: samples.last.map { CallMetrics(input: $0.input, output: $0.output, firstToken: $0.ttft) })
    }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let currentSummary = summary
        let activityDate = max(samples.last?.completedAt ?? .distantPast, inFlightStart ?? .distantPast)
        let status = inFlightStart != nil ? "active" : (samples.isEmpty ? "no data" : "ready")
        return SourceSnapshot(
            source: source,
            summary: currentSummary,
            activityDate: activityDate,
            inFlightStart: inFlightStart,
            liveSpeed: liveTPS(),
            hasData: !samples.isEmpty || inFlightStart != nil,
            diagnostic: SourceDiagnostic(source: source, path: databasePath, status: status, sampleCount: samples.count)
        )
    }

    func onceLines(now: Date = Date()) -> [String] { onceLines }

    var onceLines: [String] {
        var lines = ["session:   \(sessionID)", "responses: \(samples.count)"]
        if let sample = samples.last {
            lines.append("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s  (\(sample.basisLabel))")
        }
        lines.append("live:      \(liveTPS().map { Fmt.tps($0) } ?? "-") tok/s  turn output \(turnOutput)")
        return lines
    }
}
