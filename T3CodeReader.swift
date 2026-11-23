import Foundation
import SQLite3

final class T3CodeReader {
    static var dbPath: String {
        let home = ProcessInfo.processInfo.environment["T3CODE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".t3")
        return ((home as NSString).expandingTildeInPath as NSString).appendingPathComponent("userdata/statev2.sqlite")
    }

    private struct ActiveTurn {
        let startedAt: Date
        let lastActivity: Date
    }

    private struct Snapshot {
        let samples: [Sample]
        let activeTurns: [ActiveTurn]
    }

    let databasePath: String
    private var cache = SQLiteDatabaseCache<Snapshot>()
    private var snapshot: Snapshot?
    private static let dateWithoutFractions = ISO8601DateFormatter()

    init(dbPath: String = T3CodeReader.dbPath) {
        databasePath = dbPath
    }

    var available: Bool { snapshot != nil }
    var samples: [Sample] { snapshot?.samples ?? [] }

    private func activeTurn(at now: Date) -> ActiveTurn? {
        snapshot?.activeTurns.first { abs(now.timeIntervalSince($0.lastActivity)) < 15 * 60 }
    }

    func inFlightStart(at now: Date = Date()) -> Date? { activeTurn(at: now)?.startedAt }

    var activityDate: Date {
        max(activeTurn(at: Date())?.lastActivity ?? .distantPast, samples.last?.completedAt ?? .distantPast)
    }

    func poll() {
        snapshot = cache.read(databasePath, load: Self.read)
    }

    private static func read(_ path: String) -> Snapshot? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 100)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        // Both reads use one snapshot while T3 commits new turns to its WAL.
        guard let samples = readSamples(db),
              let active = readActiveTurns(db) else { return nil }
        return Snapshot(samples: samples, activeTurns: active)
    }

    private static func readSamples(_ db: OpaquePointer?) -> [Sample]? {
        let sql = """
        SELECT t.started_at, t.completed_at,
               COALESCE(NULLIF(json_extract(r.payload_json, '$.modelSelection.model'), ''), p.provider, ''),
               json_extract(t.payload_json, '$.turnTokenUsage.inputTokens'),
               json_extract(t.payload_json, '$.turnTokenUsage.cachedInputTokens'),
               json_extract(t.payload_json, '$.turnTokenUsage.outputTokens'),
               json_extract(t.payload_json, '$.turnTokenUsage.reasoningTokens')
        FROM orchestration_v2_projection_provider_turns AS t
        LEFT JOIN orchestration_v2_projection_provider_threads AS p ON p.provider_thread_id = t.provider_thread_id
        LEFT JOIN orchestration_v2_projection_run_attempts AS a ON a.attempt_id = t.run_attempt_id
        LEFT JOIN orchestration_v2_projection_runs AS r ON r.run_id = a.run_id
        WHERE t.status = 'completed' AND t.started_at IS NOT NULL AND t.completed_at > t.started_at
          AND json_extract(t.payload_json, '$.turnTokenUsage.usageStatus') = 'complete'
          AND json_type(t.payload_json, '$.turnTokenUsage.outputTokens') = 'integer'
          AND json_extract(t.payload_json, '$.turnTokenUsage.outputTokens') > 0
        ORDER BY t.completed_at DESC, t.provider_turn_id DESC
        LIMIT \(SpeedSummary.historyLimit)
        """
        return query(db, sql) { row -> Sample? in
            guard let start = date(row, 0), let end = date(row, 1), end > start else { return nil }
            let input = sqlite3_column_int64(row, 3)
            let output = sqlite3_column_int64(row, 5)
            let (total, overflow) = input.addingReportingOverflow(output)
            guard input >= 0, output > 0, !overflow else { return nil }
            return Sample(startedAt: start, completedAt: end, model: string(row, 2) ?? "",
                          input: input, cachedInput: sqlite3_column_int64(row, 4), output: output,
                          reasoning: sqlite3_column_int64(row, 6), total: total)
        }.map { $0.reversed() }
    }

    private static func readActiveTurns(_ db: OpaquePointer?) -> [ActiveTurn]? {
        let sql = """
        SELECT t.started_at,
               MAX(t.started_at, COALESCE((
                   SELECT MAX(i.updated_at) FROM orchestration_v2_projection_turn_items AS i
                   WHERE i.provider_turn_id = t.provider_turn_id
               ), t.started_at)) AS last_activity
        FROM orchestration_v2_projection_provider_turns AS t
        LEFT JOIN orchestration_v2_projection_run_attempts AS a ON a.attempt_id = t.run_attempt_id
        LEFT JOIN orchestration_v2_projection_runs AS r ON r.run_id = a.run_id
        WHERE t.status = 'running' AND t.started_at IS NOT NULL AND t.completed_at IS NULL
          AND (r.run_id IS NULL OR r.status IN ('running', 'waiting'))
        ORDER BY t.started_at DESC, t.provider_turn_id DESC
        """
        return query(db, sql) { row in
            guard let start = date(row, 0), let lastActivity = date(row, 1) else { return nil }
            return ActiveTurn(startedAt: start, lastActivity: lastActivity)
        }
    }

    private static func query<Row>(_ db: OpaquePointer?, _ sql: String, decode: (OpaquePointer?) -> Row?) -> [Row]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = decode(statement) { rows.append(value) }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? rows : nil
    }

    private static func string(_ row: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private static func date(_ row: OpaquePointer?, _ column: Int32) -> Date? {
        string(row, column).flatMap { ISO8601DateFormatter.codex.date(from: $0) ?? dateWithoutFractions.date(from: $0) }
    }
}
