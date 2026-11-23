import Foundation
import SQLite3

func testT3CodeReader() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-t3code-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let missing = T3CodeReader(dbPath: root.appendingPathComponent("missing.sqlite").path)
    missing.poll()
    precondition(!missing.available && missing.samples.isEmpty && missing.inFlightStart() == nil && missing.activityDate == .distantPast)

    let dbURL = root.appendingPathComponent("statev2.sqlite")
    func sql(_ text: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK,
              sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw NSError(domain: "T3CodeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    try sql("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE orchestration_v2_projection_provider_turns (
            provider_turn_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            provider_thread_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            run_attempt_id TEXT,
            ordinal INTEGER NOT NULL,
            status TEXT NOT NULL,
            started_at TEXT,
            completed_at TEXT,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_provider_threads (
            provider_thread_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_run_attempts (
            attempt_id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_runs (
            run_id TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_turn_items (
            turn_item_id TEXT PRIMARY KEY,
            provider_turn_id TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt1', 'codex');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt2', 'claude');
        INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 'completed', '{"modelSelection":{"model":"gpt-5.4"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES ('r2', 'completed', '{}');
        INSERT INTO orchestration_v2_projection_runs VALUES ('r3', 'running', '{"modelSelection":{"model":"claude-sonnet"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES ('r4', 'failed', '{"modelSelection":{"model":"claude-sonnet"}}');
        INSERT INTO orchestration_v2_projection_run_attempts VALUES ('a1', 'r1');
        INSERT INTO orchestration_v2_projection_run_attempts VALUES ('a2', 'r2');
        INSERT INTO orchestration_v2_projection_run_attempts VALUES ('a3', 'r3');
        INSERT INTO orchestration_v2_projection_run_attempts VALUES ('a4', 'r4');

        -- Valid turn with explicit model from run payload
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't1', 'th1', 'pt1', 'n1', 'a1', 1, 'completed',
            '2026-11-23T10:00:00.000Z', '2026-11-23T10:00:10.000Z',
            '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":1000,"cachedInputTokens":400,"outputTokens":500,"reasoningTokens":100}}'
        );
        -- Valid turn falling back to provider name, without fractional seconds
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't2', 'th1', 'pt2', 'n2', 'a2', 2, 'completed',
            '2026-11-23T10:01:00Z', '2026-11-23T10:01:04Z',
            '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":200,"outputTokens":400}}'
        );
        -- Ignored: incomplete usage, zero output, non-integer output, non-positive duration, missing started_at
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-bad-status', 'th1', 'pt1', 'n3', 'a1', 3, 'completed',
            '2026-11-23T10:02:00.000Z', '2026-11-23T10:02:05.000Z',
            '{"turnTokenUsage":{"usageStatus":"partial","inputTokens":100,"outputTokens":100}}'
        );
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-zero-out', 'th1', 'pt1', 'n4', 'a1', 4, 'completed',
            '2026-11-23T10:03:00.000Z', '2026-11-23T10:03:05.000Z',
            '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":100,"outputTokens":0}}'
        );
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-str-out', 'th1', 'pt1', 'n5', 'a1', 5, 'completed',
            '2026-11-23T10:04:00.000Z', '2026-11-23T10:04:05.000Z',
            '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":100,"outputTokens":"200"}}'
        );
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-bad-span', 'th1', 'pt1', 'n6', 'a1', 6, 'completed',
            '2026-11-23T10:05:05.000Z', '2026-11-23T10:05:05.000Z',
            '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":100,"outputTokens":200}}'
        );
        -- Orphaned running turn whose run already failed must be ignored
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-orphan', 'th1', 'pt2', 'n7', 'a4', 7, 'running',
            '2026-11-23T10:06:00.000Z', NULL, '{}'
        );
        -- Active running turn with newer item activity
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-active', 'th1', 'pt2', 'n8', 'a3', 8, 'running',
            '2026-11-23T10:05:00.000Z', NULL, '{}'
        );
        INSERT INTO orchestration_v2_projection_turn_items VALUES (
            'item-1', 't-active', '2026-11-23T10:15:00.000Z'
        );
        -- Newer concurrent running turn without newer item activity must still win by started_at DESC
        INSERT INTO orchestration_v2_projection_provider_turns VALUES (
            't-active-newer', 'th2', 'pt1', 'n9', 'a3', 9, 'running',
            '2026-11-23T10:10:00.000Z', NULL, '{}'
        );
        """)

    let reader = T3CodeReader(dbPath: dbURL.path)
    reader.poll()
    precondition(reader.available && reader.samples.count == 2)
    let first = reader.samples[0]
    let second = reader.samples[1]
    precondition(first.model == "gpt-5.4" && first.input == 1000 && first.cachedInput == 400 &&
        first.output == 500 && first.reasoning == 100 && first.total == 1500 && first.effectiveTPS == 50)
    precondition(second.model == "claude" && second.output == 400 && second.effectiveTPS == 100)
    precondition(first.completedAt < second.completedAt)

    let activeStart = ISO8601DateFormatter.codex.date(from: "2026-11-23T10:05:00.000Z")!
    let newerActiveStart = ISO8601DateFormatter.codex.date(from: "2026-11-23T10:10:00.000Z")!
    let activeItem = ISO8601DateFormatter.codex.date(from: "2026-11-23T10:15:00.000Z")!
    precondition(reader.inFlightStart(at: activeItem.addingTimeInterval(60)) == newerActiveStart,
        "Concurrent turns must track the most recently started active turn instead of jumping by item activity")
    precondition(reader.inFlightStart(at: newerActiveStart.addingTimeInterval(15 * 60 + 1)) == activeStart,
        "When the newest turn becomes stale, fall back to an older still-active turn")
    precondition(reader.inFlightStart(at: activeItem.addingTimeInterval(15 * 60 + 1)) == nil,
        "Stale running turns older than 15 minutes must expire")

    // Complete the active turns and ensure poll() picks up WAL updates.
    try sql("""
        UPDATE orchestration_v2_projection_provider_turns
        SET status = 'completed',
            completed_at = '2026-11-23T10:15:10.000Z',
            payload_json = '{"turnTokenUsage":{"usageStatus":"complete","inputTokens":500,"outputTokens":610}}'
        WHERE provider_turn_id = 't-active';
        UPDATE orchestration_v2_projection_provider_turns
        SET status = 'completed',
            completed_at = '2026-11-23T10:15:05.000Z',
            payload_json = '{}'
        WHERE provider_turn_id = 't-active-newer';
        UPDATE orchestration_v2_projection_runs SET status = 'completed' WHERE run_id = 'r3';
        """)
    reader.poll()
    precondition(reader.inFlightStart(at: activeItem.addingTimeInterval(60)) == nil)
    precondition(reader.samples.count == 3 && reader.samples.last?.model == "claude-sonnet" && reader.samples.last?.output == 610)
    print("T3 Code tests: passed (completed turns, model fallback, filters, active item window, WAL updates)")
}
