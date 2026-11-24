import Foundation
import SQLite3
@testable import TokSpeedApp

func testOpenCodeReader() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-opencode-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let epoch = now - 120_000
    func sql(_ url: URL, _ text: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK,
              sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw NSError(domain: "OpenCodeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    let v2 = root.appendingPathComponent("v2.db")
    try sql(v2, """
        CREATE TABLE session_v2 (id TEXT, directory TEXT, time_updated INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('v2', '/fixture', \(now));
        """)
    // Optional streaming values must come from this assistant row. Tests can supply
    // raw JSON values to exercise SQLite's numeric coercion and non-finite numbers.
    func insert(_ id: String, _ offset: Int64, _ output: Int,
                first: Int64? = nil, streamed: Int64? = nil, completed: Int64? = 4000,
                extraTime: String = "") throws {
        let start = epoch + offset
        var time = "\"created\":\(start)"
        if let first { time += ",\"firstToken\":\(start + first)" }
        if let streamed { time += ",\"streamed\":\(start + streamed)" }
        if let completed { time += ",\"completed\":\(start + completed)" }
        try sql(v2, """
            INSERT INTO session_message VALUES ('\(id)', 'v2', 'assistant', \(start),
                '{"model":{"id":"fixture"},"tokens":{"output":\(output)},"time":{\(time)\(extraTime)}}');
            """)
    }
    try insert("no-first", 0, 100, streamed: 2000)
    try insert("no-streamed", 5000, 100, first: 1000)
    try insert("before-created", 10000, 100, first: -1, streamed: 2000)
    try insert("after-completed", 15000, 100, first: 1000, streamed: 4001)
    try insert("reverse", 20000, 100, first: 2000, streamed: 1000)
    try insert("zero", 25000, 100, first: 1000, streamed: 1000)
    try insert("too-short", 30000, 100, first: 1000, streamed: 1119)
    try insert("too-fast", 35000, 361, first: 1000, streamed: 1120)
    try insert("wrong-type", 40000, 100, streamed: 2000, extraTime: ",\"firstToken\":\"\(epoch + 41000)\"")
    try insert("non-finite", 45000, 100, first: 1000, extraTime: ",\"streamed\":1e999")
    try insert("invalid-completion", 50000, 100, first: 0, streamed: 1000, completed: 0)
    try insert("at-limits", 55000, 360, first: 0, streamed: 120, completed: 120)
    try sql(v2, "INSERT INTO session_message VALUES ('user', 'v2', 'user', \(epoch + 60000), '{}');")
    try insert("stream-and-cleanup", 61000, 100, first: 1000, streamed: 2000, completed: 6000)
    try insert("fallback", 91000, 200, first: 1000)
    try insert("awaiting-completion", 101000, 900, first: 1000, streamed: 2000, completed: nil)

    let reader = OpenCodeReader(dbPath: v2.path)
    reader.poll()
    precondition(reader.sessionID == "v2" && reader.samples.count == 13)
    let cachedReads = reader.databaseReadCount
    reader.poll()
    precondition(reader.databaseReadCount == cachedReads, "Unchanged OpenCode database must use SQLite cache without reopening")

    let samples = Dictionary(uniqueKeysWithValues: reader.samples.map { ($0.messageID, $0) })
    for id in ["no-first", "no-streamed", "before-created", "after-completed", "reverse", "zero",
               "too-short", "too-fast", "wrong-type", "non-finite", "fallback"] {
        let sample = samples[id]!
        precondition(sample.streamSeconds == nil && sample.measurementSeconds == 4
            && sample.effectiveTPS == Double(sample.output) / 4, "Expected end-to-end fallback for \(id)")
    }
    precondition(samples["at-limits"]!.streamSeconds == 0.12 && samples["at-limits"]!.effectiveTPS == 3000)
    let cleaned = samples["stream-and-cleanup"]!
    precondition(cleaned.elapsed == 6 && cleaned.ttft == 1 && cleaned.effectiveTPS == 100)
    precondition(samples["awaiting-completion"] == nil && reader.inFlightStart != nil)
    precondition(reader.turnOutput == 300 && reader.turnGenSeconds == 5 && reader.liveTPS() == 60,
        "This turn must divide total tokens by summed measured durations, without inter-call time")
    precondition(reader.summary.current == 60 && reader.summary.recent.suffix(2).map(\.speed) == [100, 50])
    precondition(reader.summary.recent.map(\.completedAt) == reader.samples.map(\.completedAt))
    precondition(reader.onceLines.contains("last:      50 tok/s  (\(L10n.text("E2E fallback")))"))
    precondition(reader.onceLines.contains("live:      60 tok/s  turn output 300"))

    // Active state must expire after 900s even on a cache hit.
    reader.poll(now: Date(timeIntervalSince1970: Double(epoch + 101000) / 1000 + 901))
    precondition(reader.inFlightStart == nil && reader.databaseReadCount == cachedReads)

    try sql(v2, """
        UPDATE session_message SET data = json_set(data, '$.time.completed', \(epoch + 106000))
        WHERE id = 'awaiting-completion';
        """)
    reader.poll()
    precondition(reader.inFlightStart == nil && reader.liveTPS() == nil && reader.summary.current == nil)
    precondition(reader.samples.last?.effectiveTPS == 900 && reader.summary.recent.last?.speed == 900)
    precondition(reader.onceLines.contains("last:      900 tok/s  (\(L10n.text("Streaming")))"))

    // Deleting and recreating the DB file (new inode) must recover without holding a stale fd.
    try fm.removeItem(at: v2)
    reader.poll()
    precondition(reader.sessionID.isEmpty && reader.samples.isEmpty)
    try sql(v2, """
        CREATE TABLE session_v2 (id TEXT, directory TEXT, time_updated INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('v2-recreated', '/fixture', \(now + 5000));
        INSERT INTO session_message VALUES ('m-new', 'v2-recreated', 'assistant', \(epoch + 110000),
            '{"model":{"id":"fixture"},"tokens":{"output":240},"time":{"created":\(epoch + 110000),"firstToken":\(epoch + 111000),"streamed":\(epoch + 113000),"completed":\(epoch + 114000)}}');
        """)
    reader.poll()
    precondition(reader.sessionID == "v2-recreated" && reader.samples.count == 1 && reader.samples[0].effectiveTPS == 120,
        "Recreated database must be detected and read")

    let v1 = root.appendingPathComponent("v1.db")
    try sql(v1, """
        CREATE TABLE session (id TEXT, directory TEXT, time_updated INTEGER);
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (message_id TEXT, data TEXT);
        INSERT INTO session VALUES ('v1', '/fixture', \(now));
        INSERT INTO message VALUES ('old', 'v1', \(epoch),
            '{"role":"assistant","modelID":"legacy","tokens":{"output":120},
              "time":{"created":\(epoch),"completed":\(epoch + 3000)}}');
        INSERT INTO part VALUES ('old', '{"type":"reasoning","time":{"start":\(epoch + 1000)}}');
        """)
    let legacy = OpenCodeReader(dbPath: v1.path)
    legacy.poll()
    precondition(legacy.sessionID == "v1" && legacy.samples.count == 1)
    let old = legacy.samples[0]
    precondition(old.model == "legacy" && old.streamSeconds == nil && old.effectiveTPS == 40)
    precondition(abs((old.ttft ?? 0) - 1) < 0.000_001, "Keep legacy TTFT without using it for speed")
    precondition(legacy.summary.recent.map(\.speed) == [40] && legacy.turnGenSeconds == 3)

    // Multi-session V2 with titles
    let multi = root.appendingPathComponent("multi.db")
    try sql(multi, """
        CREATE TABLE session_v2 (id TEXT, directory TEXT, title TEXT, time_updated INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('s1', '/repo/a', 'Fix sidebar layout', \(now));
        INSERT INTO session_v2 VALUES ('s2', '/repo/b', 'Add caching layer', \(now - 30_000));
        INSERT INTO session_message VALUES ('u1', 's1', 'user', \(now - 10_000), '{}');
        INSERT INTO session_message VALUES ('a1', 's1', 'assistant', \(now - 9_000),
            '{"model":{"id":"m"},"tokens":{"output":120},"time":{"created":\(now - 9_000),"firstToken":\(now - 8_000),"streamed":\(now - 7_000),"completed":\(now - 6_000)}}');
        INSERT INTO session_message VALUES ('a1-live', 's1', 'assistant', \(now - 2_000),
            '{"model":{"id":"m"},"tokens":{"output":0},"time":{"created":\(now - 2_000)}}');
        INSERT INTO session_message VALUES ('a2', 's2', 'assistant', \(now - 40_000),
            '{"model":{"id":"m"},"tokens":{"output":80},"time":{"created":\(now - 40_000),"firstToken":\(now - 39_000),"streamed":\(now - 37_000),"completed":\(now - 36_000)}}');
        """)
    let multiReader = OpenCodeReader(dbPath: multi.path)
    let pollNow = Date(timeIntervalSince1970: Double(now) / 1000)
    multiReader.poll(now: pollNow)
    let visible = multiReader.summary.visibleSessions(now: pollNow)
    precondition(visible.count == 2 && visible.map(\.title) == ["Fix sidebar layout", "Add caching layer"])
    precondition(visible.map { $0.speedText(now: pollNow) } == ["120", "40"])
    print("OpenCode tests: passed (same-row timing, cache/recreate recovery, fallback, cleanup, weighted turn, V1, multi-session titles)")
}
