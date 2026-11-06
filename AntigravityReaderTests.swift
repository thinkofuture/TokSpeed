import Foundation
import SQLite3

func testAntigravityReader() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-antigravity-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let summary = root.appendingPathComponent("conversation_summaries.db")
    let old = "11111111-1111-4111-8111-111111111111"
    let new = "22222222-2222-4222-8222-222222222222"
    let missing = "33333333-3333-4333-8333-333333333333"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func sql(_ url: URL, _ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "AntigravityFixture", code: 1) }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AntigravityFixture", code: 2) }
    }
    func varint(_ input: UInt64) -> Data {
        var value = input, bytes = Data()
        while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        bytes.append(UInt8(value))
        return bytes
    }
    func integer(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    func message(_ field: UInt64, _ value: Data) -> Data { varint(field << 3 | 2) + varint(UInt64(value.count)) + value }
    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func conversation(_ id: String, end: UInt64, output: UInt64? = nil) throws {
        let file = root.appendingPathComponent("conversations/\(id).db")
        let metadata = message(7, integer(1, end))
        try sql(file, "CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, metadata BLOB); CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB); DELETE FROM steps; DELETE FROM gen_metadata; INSERT INTO steps VALUES (0, X'\(hex(metadata))');")
        if let output {
            let chat = message(4, integer(3, output)) + message(11, integer(1, 1))
                + message(12, integer(1, 1)) + message(21, Data("fixture-model".utf8))
            let entry = message(1, chat) + message(2, varint(0))
            try sql(file, "INSERT INTO gen_metadata VALUES (0, X'\(hex(entry))'); INSERT INTO gen_metadata VALUES (1, X'ff');")
        }
    }

    let reader = AntigravityReader(root: root.path)
    reader.poll(now: now)
    precondition(!reader.available && !fm.fileExists(atPath: summary.path), "Read-only polling must not create missing databases")
    try sql(summary, "CREATE TABLE conversation_summaries (conversation_id TEXT, status TEXT, last_modified_time INTEGER); INSERT INTO conversation_summaries VALUES ('\(old)', 'CASCADE_RUN_STATUS_RUNNING', 1), ('\(new)', 'CASCADE_RUN_STATUS_IDLE', 2), ('../invalid-path', '', 3), ('\(missing)', '', 4);")
    try conversation(old, end: 1_799_999_900, output: 100)
    try conversation(new, end: 1_799_999_995)
    reader.poll(now: now)
    precondition(reader.available && reader.sessionID == old && reader.samples.count == 1)
    precondition(reader.samples[0].effectiveTPS == 50 && reader.samples[0].model == "fixture-model")
    precondition(reader.inFlightStart == nil, "A historical running session must not appear active")

    try sql(summary, "DELETE FROM conversation_summaries WHERE conversation_id = '\(missing)'; UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_RUNNING' WHERE conversation_id = '\(new)';")
    reader.poll(now: now)
    precondition(reader.sessionID == old && reader.inFlightStart == now.addingTimeInterval(-5), "New active conversations retain the last completed speed")
    let moved = root.appendingPathComponent("summary-unavailable.db")
    try fm.moveItem(at: summary, to: moved)
    reader.poll(now: now)
    precondition(reader.available && reader.samples.last?.effectiveTPS == 50 && reader.inFlightStart == nil, "Transient summary failure must preserve history, not a stale running state")
    try fm.moveItem(at: moved, to: summary)
    try conversation(new, end: 1_799_999_999, output: 200)
    reader.poll(now: now)
    precondition(reader.sessionID == new && reader.samples.last?.effectiveTPS == 100)

    // A missing newest database must not regress to an older cached measurement.
    let newestDB = root.appendingPathComponent("conversations/\(new).db")
    let unavailableDB = root.appendingPathComponent("newest-unavailable.db")
    try fm.moveItem(at: newestDB, to: unavailableDB)
    reader.poll(now: now)
    precondition(reader.available && reader.sessionID == new && reader.samples.last?.effectiveTPS == 100)
    try fm.moveItem(at: unavailableDB, to: newestDB)
    try sql(summary, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE';")
    let freshReader = AntigravityReader(root: root.path)
    freshReader.poll(now: now)
    precondition(freshReader.sessionID == new && freshReader.samples.last?.effectiveTPS == 100 && freshReader.inFlightStart == nil,
        "History must work on cold startup without live generation")
    try sql(summary, "DELETE FROM conversation_summaries;")
    reader.poll(now: now)
    precondition(!reader.available && reader.samples.isEmpty && reader.sessionID.isEmpty && reader.inFlightStart == nil, "A successfully read empty source clears history")
    print("antigravity tests: passed (cold history/empty-newest fallback/missing databases/transient failure/active-state isolation/malformed protobuf)")
}
