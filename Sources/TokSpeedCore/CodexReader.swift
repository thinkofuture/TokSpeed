import Foundation
import SQLite3

enum CodexHome {
    static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return env }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static func newestRollout(in rootPath: String = CodexHome.path) -> URL? {
        recentRollouts(in: rootPath, within: 0, limit: 1).first
    }

    static func recentRollouts(in rootPath: String = CodexHome.path,
                                within window: TimeInterval = SpeedSummary.multiSessionWindow,
                                now: Date = Date(), limit: Int = 8,
                                recentPartitionsOnly: Bool = false, keeping tracked: [URL] = []) -> [URL] {
        let fm = FileManager.default
        let cutoff = window > 0 ? now.addingTimeInterval(-window) : Date.distantFuture
        let home = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath()
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let roots: [URL]
        if recentPartitionsOnly {
            // Codex puts new rollouts in date directories. Check adjacent days
            // too so local time, UTC and midnight do not delay discovery.
            let calendar = Calendar(identifier: .gregorian)
            roots = (-1...1).compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day, to: now) else { return nil }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
                return sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day))
            }
        } else {
            roots = [sessions, home.appendingPathComponent("archived_sessions", isDirectory: true)]
        }

        var latest: (url: URL, date: Date)?
        var recent: [(url: URL, date: Date)] = []
        var seen = Set<URL>()
        func consider(_ url: URL) {
            guard seen.insert(url).inserted,
                  let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  attrs.isRegularFile == true, let mod = attrs.contentModificationDate else { return }
            if latest == nil || mod > latest!.date { latest = (url, mod) }
            if mod >= cutoff { recent.append((url, mod)) }
        }
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                consider(url)
            }
        }
        // Fresh URL instances avoid using metadata cached by an earlier scan.
        if recentPartitionsOnly { tracked.forEach { consider(URL(fileURLWithPath: $0.path)) } }
        recent.sort { $0.date > $1.date }
        var urls = recent.prefix(limit).map(\.url)
        if let best = latest?.url, !urls.contains(best) {
            urls.insert(best, at: 0)
        }
        return urls
    }

    static func sessionID(fromRolloutPath path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // rollout-YYYY-MM-DDTHH-MM-SS-<uuid>
        guard name.count >= 36 else { return nil }
        let suffix = String(name.suffix(36))
        return UUID(uuidString: suffix) != nil ? suffix : nil
    }
}

final class CodexTitleStore {
    private let home: String
    private var indexStamp = ""
    private var indexTitles: [String: String] = [:]
    private var dbCache = SQLiteDatabaseCache<[String: String]>()
    private var dbTitles: [String: String] = [:]

    init(home: String = CodexHome.path) { self.home = home }

    func refresh() {
        loadIndex()
        let dbPath = resolveStateDatabasePath()
        if let loaded = dbCache.read(dbPath, load: Self.readStateDB) {
            dbTitles = loaded
        } else if SQLiteDatabaseStamp(dbPath) == nil {
            dbTitles.removeAll()
        }
    }

    func title(for sessionID: String) -> String? {
        guard !sessionID.isEmpty else { return nil }
        if let name = indexTitles[sessionID], !name.isEmpty { return name }
        if let name = dbTitles[sessionID], !name.isEmpty { return name }
        return nil
    }

    private func resolveStateDatabasePath() -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        var candidates: [(version: Int, name: String)] = []
        for name in entries where name.hasPrefix("state_") && name.hasSuffix(".sqlite") {
            let middle = String(name.dropFirst(6).dropLast(7))
            if let version = Int(middle), !middle.isEmpty {
                candidates.append((version, name))
            }
        }
        if let newest = candidates.max(by: { $0.version < $1.version }) {
            return (home as NSString).appendingPathComponent(newest.name)
        }
        return (home as NSString).appendingPathComponent("state_5.sqlite")
    }

    private func loadIndex() {
        let path = (home as NSString).appendingPathComponent("session_index.jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            indexStamp = ""
            indexTitles.removeAll()
            return
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(attrs[.systemFileNumber] ?? 0):\(attrs[.size] ?? 0):\(mtime)"
        guard stamp != indexStamp else { return }
        indexStamp = stamp
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        var parsed: [String: String] = [:]
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = row["id"] as? String, !id.isEmpty,
                  let name = row["thread_name"] as? String, !name.isEmpty else { continue }
            parsed[id] = name
        }
        indexTitles = parsed
    }

    private static func readStateDB(_ path: String) -> [String: String]? {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 100)
        var stmt: OpaquePointer?
        let sql = "SELECT id, COALESCE(NULLIF(name, ''), title) FROM threads WHERE COALESCE(NULLIF(name, ''), title) != '' ORDER BY updated_at DESC LIMIT 500"
        let legacySQL = "SELECT id, title FROM threads WHERE title != '' ORDER BY updated_at DESC LIMIT 500"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
                || sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idPtr = sqlite3_column_text(stmt, 0), let titlePtr = sqlite3_column_text(stmt, 1) {
                result[String(cString: idPtr)] = String(cString: titlePtr)
            }
        }
        return result
    }
}

final class CodexMultiReader: SpeedSourceReader {
    let source: SourceMode = .codex
    private let home: String
    private let titleStore: CodexTitleStore
    private var readers: [String: RolloutReader] = [:]
    private var trackedURLs: [URL] = []
    private var primaryPath = ""
    private var lastScan = Date.distantPast
    private var lastFullScan = Date.distantPast
    private(set) var sessions: [SessionSummary] = []

    init(home: String = CodexHome.path) {
        self.home = home
        self.titleStore = CodexTitleStore(home: home)
    }

    private var primary: RolloutReader? { readers[primaryPath] }
    var samples: [Sample] { primary?.samples ?? [] }
    var model: String { primary?.model ?? "" }
    var sessionID: String { primary?.sessionID ?? "" }
    var turnStart: Date? { primary?.turnStart }
    var turnOutput: Int64 { primary?.turnOutput ?? 0 }
    var turnGenSeconds: Double { primary?.turnGenSeconds ?? 0 }
    func isActive(at now: Date = Date()) -> Bool { primary?.isActive(at: now) ?? false }
    var turnActive: Bool { isActive(at: Date()) }
    func liveTPS(now: Date = Date()) -> Double? { primary?.liveTPS(now: now) }

    var activityDate: Date {
        guard let primary else { return .distantPast }
        return max(primary.samples.last?.completedAt ?? .distantPast,
                   primary.turnActive ? (primary.turnStart ?? .distantPast) : .distantPast)
    }

    var hasOnceData: Bool { !samples.isEmpty || isActive(at: Date()) }

    func poll(forceScan: Bool = false, now: Date = Date()) {
        let fullScan = forceScan || now.timeIntervalSince(lastFullScan) >= 60
        if fullScan || now.timeIntervalSince(lastScan) >= 5 {
            lastScan = now
            if fullScan { lastFullScan = now }
            let urls = CodexHome.recentRollouts(in: home, now: now,
                recentPartitionsOnly: !fullScan, keeping: trackedURLs)
            trackedURLs = urls
            let keep = Set(urls.map(\.path))
            readers = readers.filter { keep.contains($0.key) }
            titleStore.refresh()
        }
        for url in trackedURLs {
            let reader = readers[url.path] ?? RolloutReader()
            reader.read(url)
            readers[url.path] = reader
        }
        let all = trackedURLs.compactMap { readers[$0.path] }
        let activeReaders = all.filter { $0.isActive(at: now) }
        let chosen: RolloutReader?
        if let bestActive = activeReaders.max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
            chosen = bestActive
        } else if let bestCompleted = all.filter({ !$0.samples.isEmpty }).max(by: {
            ($0.samples.last?.completedAt ?? .distantPast) < ($1.samples.last?.completedAt ?? .distantPast)
        }) {
            chosen = bestCompleted
        } else {
            chosen = all.first
        }
        primaryPath = chosen?.path ?? ""

        var built: [SessionSummary] = []
        var seen = Set<String>()
        for reader in all {
            let sid = reader.sessionID.isEmpty ? (CodexHome.sessionID(fromRolloutPath: reader.path) ?? reader.path) : reader.sessionID
            guard seen.insert(sid).inserted else { continue }
            let active = reader.isActive(at: now)
            let lastSample = reader.samples.last
            let activityAt = max(active ? reader.lastActivityAt : .distantPast, lastSample?.completedAt ?? .distantPast)
            guard active || (lastSample != nil && now.timeIntervalSince(activityAt) <= SpeedSummary.multiSessionWindow) else { continue }
            let rawTitle = titleStore.title(for: sid) ?? reader.firstUserMessage
            built.append(SessionSummary(
                id: sid,
                title: SessionSummary.cleanTitle(rawTitle, fallback: sid),
                active: active,
                live: reader.liveTPS(now: now),
                last: lastSample?.effectiveTPS,
                activityAt: activityAt,
                inFlightStart: active ? (reader.turnStart ?? reader.inFlightStart) : nil
            ))
        }
        sessions = built
    }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let active = isActive(at: now)
        let live = liveTPS(now: now)
        let last = samples.last?.effectiveTPS
        let completed = samples.last?.completedAt
        let history = samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: $0.effectiveTPS) }
        let measurement = L10n.text("This turn: output tokens / total completed-call duration, excluding tool execution; not instantaneous per-token speed.")
        let summary = SpeedSummary(name: source.label, active: active, live: live, last: last,
            completedAt: completed, history: history, model: model, measurement: measurement,
            sessions: sessions, metrics: samples.last?.metrics)
        let status = active ? "active" : (samples.isEmpty ? "no data" : "ready")
        let diagPath = primaryPath.isEmpty ? (home as NSString).appendingPathComponent("sessions") : primaryPath
        return SourceSnapshot(
            source: source,
            summary: summary,
            activityDate: max(completed ?? .distantPast, active ? (turnStart ?? .distantPast) : .distantPast),
            inFlightStart: active ? (turnStart ?? primary?.inFlightStart) : nil,
            liveSpeed: live,
            hasData: !samples.isEmpty || active,
            diagnostic: SourceDiagnostic(source: source, path: diagPath, status: status, sampleCount: samples.count)
        )
    }

    func onceLines(now: Date = Date()) -> [String] {
        var lines = [
            "rollout:   \(primaryPath.isEmpty ? "-" : primaryPath)",
            "session:   \(sessionID)",
            "model:     \(model)",
            "responses: \(samples.count)"
        ]
        if let s = samples.last {
            lines.append("last:      \(Fmt.tps(s.effectiveTPS)) tok/s effective, \(Fmt.tps(s.visibleTPS)) tok/s visible")
            lines.append("last ttft: \(s.ttft.map { Fmt.secs($0) } ?? "-")  elapsed \(Fmt.secs(s.elapsed))  output \(s.output)")
        }
        if let live = liveTPS(now: now) {
            lines.append("live:      \(Fmt.tps(live)) tok/s  turn output \(turnOutput)")
        }
        if let primary {
            lines.append("median:    \(Fmt.tps(primary.medianTPS)) tok/s")
        }
        return lines
    }
}

// MARK: - Incremental rollout reader

final class RolloutReader {
    private(set) var samples: [Sample] = []
    private(set) var model = ""
    private(set) var sessionID = ""
    private(set) var firstUserMessage = ""
    private(set) var path = ""
    private(set) var inFlightStart: Date?
    private var turnOpen = false
    private var lastEventAt: Date?
    var lastActivityAt: Date { max(samples.last?.completedAt ?? .distantPast, lastEventAt ?? .distantPast) }
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
    private var fileID: UInt64 = 0
    private var remainder = Data()
    private var skipPartialLeadingLine = false
    private var samplingStart: Date?
    private var firstGeneratedAt: Date?
    private var generatedEnd: Date?

    private let tailBytes: Int64 = 8 * 1024 * 1024
    private let headerBytes = 64 * 1024
    private let maxSamples = 300
    private let maxLineBytes = 4 * 1024 * 1024

    func read(_ url: URL) {
        if url.path != path { reset(url) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            if !path.isEmpty { reset(url) }
            return
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if inode != fileID || size < offset {
            reset(url)
        }
        fileID = inode
        if size == offset { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            var from = offset
            if from == 0 && size > tailBytes {
                readHeaderMetadata(handle: handle, limit: min(headerBytes, Int(size)))
                from = size - tailBytes
                skipPartialLeadingLine = true
            }
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
        skipPartialLeadingLine = false
        offset = 0
        fileID = 0
        samplingStart = nil
        firstGeneratedAt = nil
        generatedEnd = nil
        model = ""
        sessionID = CodexHome.sessionID(fromRolloutPath: url.path) ?? ""
        firstUserMessage = ""
        inFlightStart = nil
        turnOpen = false
        lastEventAt = nil
        turnStart = nil
        turnOutput = 0
        turnGenSeconds = 0
    }

    private func readHeaderMetadata(handle: FileHandle, limit: Int) {
        do {
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: limit), !data.isEmpty else { return }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            let completeCount = data.last == 10 ? lines.count : max(0, lines.count - 1)
            for index in 0..<completeCount {
                let line = Data(lines[index])
                guard !line.isEmpty,
                      let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let type = (row["type"] as? String) ?? ""
                let payload = (row["payload"] as? [String: Any]) ?? [:]
                let payloadType = (payload["type"] as? String) ?? ""
                switch (type, payloadType) {
                case ("session_meta", _):
                    if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty {
                        sessionID = id
                    }
                case ("turn_context", _):
                    if let m = payload["model"] as? String, !m.isEmpty { model = m }
                case ("event_msg", "user_message"):
                    if firstUserMessage.isEmpty, let msg = payload["message"] as? String {
                        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty { firstUserMessage = cleaned }
                    }
                default:
                    break
                }
            }
        } catch {
            return
        }
    }

    private func consume(_ chunk: Data) {
        remainder.append(chunk)
        // The file cursor includes buffered partial lines, not just parsed rows.
        offset += Int64(chunk.count)
        var cursor = remainder.startIndex
        if skipPartialLeadingLine {
            if let nl = remainder[cursor...].firstIndex(of: 0x0A) {
                cursor = nl + 1
                skipPartialLeadingLine = false
            } else {
                if remainder.count > maxLineBytes { remainder.removeAll() }
                return
            }
        }
        while let nl = remainder[cursor...].firstIndex(of: 0x0A) {
            ingest(remainder[cursor..<nl])
            cursor = nl + 1
        }
        let consumedUpTo = cursor - remainder.startIndex
        if consumedUpTo > 0 {
            remainder = Data(remainder[cursor...])
        }
        if remainder.count > maxLineBytes {
            remainder.removeAll()
        }
    }

    private func ingest(_ line: Data) {
        guard !line.isEmpty, let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let tsText = row["timestamp"] as? String,
              let ts = ISO8601DateParser.parse(tsText) else { return }
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
            if firstUserMessage.isEmpty, let msg = payload["message"] as? String {
                let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { firstUserMessage = cleaned }
            }
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
                    if samples.count > maxSamples {
                        samples.removeFirst(samples.count - maxSamples)
                    }
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
