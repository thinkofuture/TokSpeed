import AppKit
import Foundation
import SQLite3

func testAntigravityReader() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tokspeed-antigravity-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let summary = root.appendingPathComponent("conversation_summaries.db")
    let old = "11111111-1111-4111-8111-111111111111"
    let new = "22222222-2222-4222-8222-222222222222"
    let missing = "33333333-3333-4333-8333-333333333333"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func exec(_ db: OpaquePointer?, _ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AntigravityFixture", code: 2) }
    }
    func sql(_ url: URL, _ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "AntigravityFixture", code: 1) }
        defer { sqlite3_close_v2(db) }
        try exec(db, text)
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
    func step(_ end: UInt64) -> String { "X'\(hex(message(7, integer(1, end))))'" }
    func generation(_ output: UInt64, step: UInt64 = 0, ttft: UInt64 = 1, streamNanos: UInt64? = 1_000_000_000) -> String {
        let stream = streamNanos.map { message(12, integer(1, $0 / 1_000_000_000) + integer(2, $0 % 1_000_000_000)) } ?? Data()
        let chat = message(4, integer(3, output)) + message(11, integer(1, ttft)) + stream
            + message(21, Data("fixture-model".utf8))
        return "X'\(hex(message(1, chat) + message(2, varint(step))))'"
    }
    func conversation(_ id: String, end: UInt64, output: UInt64? = nil) throws {
        let file = root.appendingPathComponent("conversations/\(id).db")
        try sql(file, "CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, metadata BLOB); CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB); DELETE FROM steps; DELETE FROM gen_metadata; INSERT INTO steps VALUES (0, \(step(end)));")
        if let output {
            try sql(file, "INSERT INTO gen_metadata VALUES (0, \(generation(output))); INSERT INTO gen_metadata VALUES (1, X'ff');")
        }
    }

    let reader = AntigravityReader(root: root.path)
    reader.poll(now: now)
    precondition(!reader.available && !fm.fileExists(atPath: summary.path), "Read-only polling must not create missing databases")
    try sql(summary, "CREATE TABLE conversation_summaries (conversation_id TEXT, status TEXT, last_modified_time INTEGER); INSERT INTO conversation_summaries VALUES ('\(old)', 'CASCADE_RUN_STATUS_RUNNING', 1), ('\(new)', 'CASCADE_RUN_STATUS_IDLE', 2), ('../invalid-path', '', 3), ('\(missing)', '', 4);")
    try conversation(old, end: 1_799_999_099, output: 100)
    try conversation(new, end: 1_799_999_995)
    reader.poll(now: now)
    precondition(reader.available && reader.sessionID == old && reader.samples.count == 1)
    precondition(reader.samples[0].measurement.tps == 100 && reader.samples[0].endToEndTPS == 50 && reader.samples[0].model == "fixture-model")
    precondition(reader.inFlightStart == nil, "A historical running session must not appear active")

    try sql(summary, "DELETE FROM conversation_summaries WHERE conversation_id = '\(missing)'; UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_RUNNING' WHERE conversation_id = '\(new)';")
    reader.poll(now: now)
    precondition(reader.sessionID == new && reader.inFlightStart == now.addingTimeInterval(-5))
    precondition(reader.activityDate == reader.inFlightStart)
    precondition(reader.summary.current == nil && reader.summary.value == "—" && reader.summary.recent.isEmpty,
        "An active session must not inherit another session's measurements")
    precondition(reader.summary.caption() == L10n.text("Waiting for data"))
    let unchangedReads = reader.databaseReadCount
    reader.poll(now: now.addingTimeInterval(1))
    precondition(reader.databaseReadCount == unchangedReads, "Unchanged databases must not reopen or decode")
    reader.poll(now: now.addingTimeInterval(895))
    precondition(reader.inFlightStart == nil && reader.databaseReadCount == unchangedReads, "Cached running state must expire at 900 s")
    let moved = root.appendingPathComponent("summary-unavailable.db")
    try fm.moveItem(at: summary, to: moved)
    reader.poll(now: now)
    precondition(reader.available && reader.samples.last?.measurement.tps == 100 && reader.inFlightStart == nil, "Transient summary failure must preserve history, not a stale running state")
    try fm.moveItem(at: moved, to: summary)
    try conversation(new, end: 1_799_999_999, output: 200)
    reader.poll(now: now)
    precondition(reader.sessionID == new && reader.samples.last?.measurement.tps == 200)

    // A missing newest database must not regress to an older cached measurement.
    let newestDB = root.appendingPathComponent("conversations/\(new).db")
    let unavailableDB = root.appendingPathComponent("newest-unavailable.db")
    try fm.moveItem(at: newestDB, to: unavailableDB)
    reader.poll(now: now)
    precondition(reader.available && reader.sessionID == new && reader.samples.last?.measurement.tps == 200)
    try fm.moveItem(at: unavailableDB, to: newestDB)
    try sql(summary, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE';")
    let freshReader = AntigravityReader(root: root.path)
    freshReader.poll(now: now)
    precondition(freshReader.sessionID == new && freshReader.samples.last?.measurement.tps == 200 && freshReader.inFlightStart == nil,
        "History must work on cold startup without live generation")
    try sql(summary, "DELETE FROM conversation_summaries;")
    reader.poll(now: now)
    precondition(!reader.available && reader.samples.isEmpty && reader.sessionID.isEmpty && reader.inFlightStart == nil, "A successfully read empty source clears history")

    // Keep both writers connected so commits stay in WAL. First populate the
    // cache, then modify the two databases independently.
    var summaryWriter: OpaquePointer?, conversationWriter: OpaquePointer?
    defer { sqlite3_close_v2(summaryWriter); sqlite3_close_v2(conversationWriter) }
    guard sqlite3_open(summary.path, &summaryWriter) == SQLITE_OK,
          sqlite3_open(newestDB.path, &conversationWriter) == SQLITE_OK else {
        throw NSError(domain: "AntigravityFixture", code: 3)
    }
    try exec(summaryWriter, "PRAGMA journal_mode=WAL; INSERT INTO conversation_summaries VALUES ('\(new)', 'CASCADE_RUN_STATUS_IDLE', 1);")
    try exec(conversationWriter, "PRAGMA journal_mode=WAL; DELETE FROM gen_metadata; INSERT INTO gen_metadata VALUES (0, \(generation(100)));")
    reader.poll(now: now)
    precondition(reader.summary.value == "100.0" && reader.inFlightStart == nil)
    let walReads = reader.databaseReadCount
    reader.poll(now: now)
    precondition(reader.databaseReadCount == walReads)
    let summaryMain = try Data(contentsOf: summary)
    try exec(summaryWriter, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_RUNNING';")
    reader.poll(now: now)
    let summaryMainAfter = try Data(contentsOf: summary)
    precondition(summaryMainAfter == summaryMain)
    precondition(reader.inFlightStart == now.addingTimeInterval(-1) && reader.databaseReadCount == walReads + 1,
        "A summary WAL commit must not reload an unchanged conversation")

    let conversationMain = try Data(contentsOf: newestDB)
    try exec(conversationWriter, """
        BEGIN;
        INSERT INTO steps VALUES (1, \(step(1_800_000_000)));
        INSERT INTO gen_metadata VALUES (1, \(generation(360, step: 1, streamNanos: 120_000_000)));
        INSERT INTO gen_metadata VALUES (2, \(generation(361, step: 1, streamNanos: 120_000_000)));
        INSERT INTO gen_metadata VALUES (3, \(generation(50, step: 1, streamNanos: 119_999_999)));
        INSERT INTO gen_metadata VALUES (4, \(generation(25, step: 1, streamNanos: nil)));
        INSERT INTO gen_metadata VALUES (5, \(generation(0, step: 1)));
        COMMIT;
        """)
    reader.poll(now: now.addingTimeInterval(1))
    let conversationMainAfter = try Data(contentsOf: newestDB)
    precondition(conversationMainAfter == conversationMain)
    precondition(reader.inFlightStart == now && reader.databaseReadCount == walReads + 2)
    precondition(reader.samples.map(\.output) == [100, 360, 361, 50, 25])
    precondition(reader.samples.map { $0.measurement.basis } == [.stream, .stream, .endToEnd, .endToEnd, .endToEnd])
    precondition(reader.summary.recent == [100, 3000, 361 / 1.12, 50 / 1.119999999, 25])
    precondition(reader.onceLines.contains { $0.contains("25.0 tok/s") && $0.contains(L10n.text("E2E fallback")) })
    let detail = L10n.text("End to end: %@ tok/s (%@) · TTFT: %@", "25.0", "1.00s", "1.00s")
    precondition(reader.onceLines.last == "details:   \(detail)")

    // A restart checkpoint lets the next transaction overwrite WAL frames
    // without growing the WAL. An mtime/identity check must still catch it.
    try exec(conversationWriter, "PRAGMA wal_checkpoint(RESTART);")
    reader.poll(now: now)
    let sameSizeReads = reader.databaseReadCount
    let walPath = newestDB.path + "-wal"
    let walSize = try fm.attributesOfItem(atPath: walPath)[.size] as? NSNumber
    try exec(conversationWriter, "UPDATE gen_metadata SET data = \(generation(125, step: 1, streamNanos: nil)) WHERE idx = 4;")
    let currentWALSize = try fm.attributesOfItem(atPath: walPath)[.size] as? NSNumber
    precondition(walSize != nil && walSize == currentWALSize)
    reader.poll(now: now)
    precondition(reader.summary.value == "125.0" && reader.databaseReadCount == sameSizeReads + 1)
    for speed: Double? in [nil, 0, -1, .nan, .infinity] {
        precondition(StatusDisplay.numbersOnly.title(active: true, speed: speed, elapsed: 8) == L10n.text("%d s", 8))
    }

    // CLI and desktop use separate roots. A real current model step in a
    // non-newest / IDLE summary must win over both roots' idle history.
    let desktop = root.appendingPathComponent("desktop")
    let cli = root.appendingPathComponent("cli")
    for dataRoot in [desktop, cli] {
        try fm.createDirectory(at: dataRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try sql(dataRoot.appendingPathComponent("conversation_summaries.db"), """
            CREATE TABLE conversation_summaries (conversation_id TEXT, status TEXT, last_modified_time INTEGER);
            INSERT INTO conversation_summaries VALUES ('\(new)', 'CASCADE_RUN_STATUS_IDLE', 200);
            """)
    }
    let clock = Date()
    let second = UInt64(clock.timeIntervalSince1970)
    func started(_ age: UInt64) -> String { "X'\(hex(message(1, integer(1, second - age))))'" }
    let schema = """
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, metadata BLOB);
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        """
    func file(_ dataRoot: URL, _ id: String) -> URL { dataRoot.appendingPathComponent("conversations/\(id).db") }
    try sql(file(desktop, new), schema + """
        INSERT INTO steps VALUES (0, 15, 3, \(started(1)));
        INSERT INTO gen_metadata VALUES (0, \(generation(700)));
        """)
    try sql(file(cli, new), schema + """
        INSERT INTO steps VALUES (0, 15, 3, \(started(2)));
        INSERT INTO gen_metadata VALUES (0, \(generation(800)));
        """)
    let cliSummary = cli.appendingPathComponent("conversation_summaries.db")
    try sql(cliSummary, "INSERT INTO conversation_summaries VALUES ('\(old)', 'CASCADE_RUN_STATUS_IDLE', 100);")
    let cliDB = file(cli, old)
    // Leave an open-looking row from an older turn and a new pending model.
    try sql(cliDB, schema + """
        INSERT INTO steps VALUES (0, 132, 2, \(started(400)));
        INSERT INTO steps VALUES (1, 15, 3, \(started(300)));
        INSERT INTO steps VALUES (2, 14, 3, \(started(8)));
        INSERT INTO steps VALUES (3, 15, 2, \(started(7)));
        INSERT INTO gen_metadata VALUES (0, \(generation(90, step: 1)));
        """)
    var cliWriter: OpaquePointer?
    defer { sqlite3_close_v2(cliWriter) }
    guard sqlite3_open(cliDB.path, &cliWriter) == SQLITE_OK else {
        throw NSError(domain: "AntigravityFixture", code: 4)
    }
    try exec(cliWriter, "PRAGMA journal_mode=WAL; UPDATE steps SET status = 2 WHERE idx = 3;")
    let mixed = AntigravityReader(roots: [desktop.path, cli.path])
    mixed.poll(now: clock)
    precondition(mixed.sessionID == old && mixed.summary.active && mixed.currentTPS == nil,
        "Expected CLI pending step to win; selected=\(mixed.sessionID), active=\(mixed.summary.active), reads=\(mixed.databaseReadCount)")
    precondition(mixed.inFlightStart == Date(timeIntervalSince1970: Double(second - 8)))
    precondition(mixed.summary.recent == [90] && mixed.summary.caption(now: clock) != L10n.text("This turn"))
    try exec(cliWriter, "INSERT INTO gen_metadata VALUES (1, \(generation(150, step: 3)));")
    mixed.poll(now: clock)
    precondition(mixed.summary.active && mixed.summary.current == 150 && mixed.summary.caption() == L10n.text("This turn"))
    let card = SummaryMenuView(source: .antigravity)
    card.update(mixed.summary)
    let labels = card.subviews.compactMap { $0 as? NSTextField }
    precondition(labels.count == 3 && card.toolTip == nil, "Antigravity uses the same three labels as every other card")
    let speedLabel = labels.first { $0.stringValue == "150.0" }!
    precondition(speedLabel.textColor == PanelStyle.activeColor)
    precondition(mixed.summary.recent == [90], "An in-progress reading must not be put in completed history")
    precondition(mixed.onceLines.contains { $0.hasPrefix("recorded:") && $0.contains("150.0 tok/s") })
    try exec(cliWriter, "UPDATE gen_metadata SET data = \(generation(200, step: 3)) WHERE idx = 1;")
    mixed.poll(now: clock)
    precondition(mixed.summary.current == 200, "A WAL update to the same gen_metadata row must advance the visible speed")
    card.update(mixed.summary)
    precondition(speedLabel.stringValue == "200.0" && speedLabel.textColor == PanelStyle.activeColor)

    // A different, more recent desktop run appears without a summary row.
    try sql(file(desktop, missing), schema + """
        INSERT INTO steps VALUES (0, 14, 3, \(started(2)));
        INSERT INTO steps VALUES (1, 15, 2, \(started(1)));
        """)
    mixed.poll(now: clock)
    precondition(mixed.sessionID == missing && mixed.summary.active && mixed.summary.value == "—")
    try sql(file(desktop, missing), "UPDATE steps SET status = 3 WHERE idx = 1;")
    mixed.poll(now: clock)
    precondition(mixed.sessionID == old && mixed.summary.current == 200)
    try exec(cliWriter, "UPDATE steps SET status = 3 WHERE idx = 3;")
    mixed.poll(now: clock)
    precondition(!mixed.summary.active && mixed.currentTPS == nil, "Closed runs and stale pending rows must not keep the card highlighted")
    card.update(mixed.summary)
    precondition(speedLabel.textColor == .secondaryLabelColor)
    print("antigravity tests: passed (thresholds/CLI + desktop/non-newest or missing summary/pending steps/in-place WAL speed updates/session isolation/expiry)")
}
