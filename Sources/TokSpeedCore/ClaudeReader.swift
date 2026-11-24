import Foundation

// Claude Code records API request start times and one or more blocks per response.
// Only the first block is used: subsequent blocks repeat the same usage and may
// be written after tool execution has already started.
final class ClaudeReader: SpeedSourceReader {
    let source: SourceMode = .claude

    private final class SessionFileState {
        let path: String
        var stamp = ""
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var remainder = Data()
        var skipPartialLeadingLine = false

        var sessionID = ""
        var customTitle = ""
        var agentName = ""
        var firstUser = ""
        var starts: [String: Date] = [:]
        var startsOrder: [String] = []
        var activeRequests: [String: Date] = [:]
        var seen: Set<String> = []
        var seenOrder: [String] = []
        var samples: [Sample] = []
        var turnStarted = false
        var turnOutput: Int64 = 0
        var turnGenSeconds = 0.0
        var lastEventAt = Date.distantPast

        private let tailBytes: UInt64 = 8 * 1024 * 1024
        private let fullReadLimit: UInt64 = 16 * 1024 * 1024
        private let headerBytes = 64 * 1024
        private let maxSamples = 300
        private let maxLineBytes = 4 * 1024 * 1024

        init(path: String) { self.path = path }

        var title: String {
            !customTitle.isEmpty ? customTitle : (!agentName.isEmpty ? agentName : firstUser)
        }

        func inFlightStart(at now: Date) -> Date? {
            activeRequests.values.filter {
                let age = now.timeIntervalSince($0)
                return age >= -2 && age < 900
            }.max()
        }

        func liveTPS(at now: Date) -> Double? {
            guard inFlightStart(at: now) != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
            return Double(turnOutput) / turnGenSeconds
        }

        func update(stamp: String, inode: UInt64, size: UInt64) {
            if stamp == self.stamp { return }
            if inode != self.inode || size < offset {
                reset(inode: inode)
            }
            self.inode = inode
            if size == offset {
                self.stamp = stamp
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
            defer { try? handle.close() }
            do {
                var from = offset
                if from == 0 && size > fullReadLimit {
                    readHeaderMetadata(handle: handle, limit: headerBytes)
                    from = size - tailBytes
                    skipPartialLeadingLine = true
                }
                try handle.seek(toOffset: from)
                offset = from
                while true {
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                    offset += UInt64(chunk.count)
                    consume(chunk)
                }
                self.stamp = stamp
            } catch {
                return
            }
        }

        private func reset(inode: UInt64) {
            self.inode = inode
            offset = 0
            remainder.removeAll()
            skipPartialLeadingLine = false
            sessionID = ""
            customTitle = ""
            agentName = ""
            firstUser = ""
            starts.removeAll()
            startsOrder.removeAll()
            activeRequests.removeAll()
            seen.removeAll()
            seenOrder.removeAll()
            samples.removeAll()
            turnStarted = false
            turnOutput = 0
            turnGenSeconds = 0
            lastEventAt = .distantPast
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
                          let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    extractHeaderMetadata(from: row)
                }
            } catch {
                return
            }
        }

        private func extractHeaderMetadata(from row: [String: Any]) {
            if let value = row["sessionId"] as? String, !value.isEmpty { sessionID = value }
            let rowType = row["type"] as? String
            if rowType == "custom-title", let value = row["customTitle"] as? String, !value.isEmpty {
                customTitle = value
                return
            }
            if rowType == "agent-name", let value = row["agentName"] as? String, !value.isEmpty {
                agentName = value
                return
            }
            if rowType == "user", firstUser.isEmpty, row["isSidechain"] as? Bool != true, row["isMeta"] as? Bool != true {
                let message = row["message"] as? [String: Any] ?? [:]
                let content = message["content"]
                let blocks = content as? [[String: Any]]
                let toolResult = blocks?.contains { ($0["type"] as? String) == "tool_result" } ?? false
                if !toolResult {
                    if let text = content as? String {
                        firstUser = text
                    } else if let blocks,
                              let text = blocks.compactMap({ ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }).first {
                        firstUser = text
                    }
                }
            }
        }

        private func consume(_ chunk: Data) {
            remainder.append(chunk)
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
                ingest(Data(remainder[cursor..<nl]))
                cursor = nl + 1
            }
            if cursor > remainder.startIndex {
                remainder.removeSubrange(remainder.startIndex..<cursor)
            }
            if remainder.count > maxLineBytes {
                remainder.removeAll()
            }
        }

        private func recordStart(_ request: String, at ts: Date) {
            if starts[request] == nil {
                startsOrder.append(request)
                if startsOrder.count > 500 {
                    let evicted = startsOrder.removeFirst()
                    starts.removeValue(forKey: evicted)
                    activeRequests.removeValue(forKey: evicted)
                }
            }
            starts[request] = ts
            activeRequests[request] = ts
        }

        private func ingest(_ line: Data) {
            guard !line.isEmpty,
                  let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            if let value = row["sessionId"] as? String, !value.isEmpty { sessionID = value }
            let rowType = row["type"] as? String
            if rowType == "custom-title", let value = row["customTitle"] as? String, !value.isEmpty {
                customTitle = value
                return
            }
            if rowType == "agent-name", let value = row["agentName"] as? String, !value.isEmpty {
                agentName = value
                return
            }
            guard let text = row["timestamp"] as? String,
                  let ts = ISO8601DateParser.parse(text) else { return }
            if ts > lastEventAt { lastEventAt = ts }
            if row["isSidechain"] as? Bool == true { return }

            if row["isApiErrorMessage"] as? Bool == true {
                if let ref = row["requestRef"] as? String {
                    activeRequests.removeValue(forKey: ref)
                } else {
                    activeRequests.removeAll()
                }
                return
            }

            switch rowType {
            case "user":
                let message = row["message"] as? [String: Any] ?? [:]
                let content = message["content"]
                let blocks = content as? [[String: Any]]
                let toolResult = blocks?.contains { ($0["type"] as? String) == "tool_result" } ?? false
                if !toolResult && (content is String || blocks != nil), row["isMeta"] as? Bool != true {
                    if firstUser.isEmpty {
                        if let text = content as? String {
                            firstUser = text
                        } else if let blocks,
                                  let text = blocks.compactMap({ ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }).first {
                            firstUser = text
                        }
                    }
                    turnStarted = true
                    turnOutput = 0
                    turnGenSeconds = 0
                    activeRequests.removeAll()
                }
            case "system":
                if let subtype = row["subtype"] as? String,
                   ["turn_duration", "api_error", "stop_hook_summary"].contains(subtype) {
                    activeRequests.removeAll()
                }
            case "api-request":
                if let request = row["id"] as? String {
                    recordStart(request, at: ts)
                }
            case "assistant":
                let ref = row["requestRef"] as? String
                if row["error"] != nil, let ref {
                    activeRequests.removeValue(forKey: ref)
                    return
                }
                guard let message = row["message"] as? [String: Any],
                      let messageID = message["id"] as? String else { return }
                if let ref, message["stop_reason"] != nil {
                    activeRequests.removeValue(forKey: ref)
                }
                guard !seen.contains(messageID),
                      let ref, let start = starts[ref],
                      let usage = message["usage"] as? [String: Any] else { return }
                let output = usage.int64("output_tokens")
                guard output > 0, ts > start else { return }
                seen.insert(messageID)
                seenOrder.append(messageID)
                if seenOrder.count > 2000 {
                    seen.remove(seenOrder.removeFirst())
                }
                activeRequests.removeValue(forKey: ref)
                let details = usage["output_tokens_details"] as? [String: Any] ?? [:]
                let input = usage.int64("input_tokens")
                samples.append(Sample(startedAt: start, completedAt: ts, firstOutputAt: nil,
                    model: message["model"] as? String ?? "", input: input,
                    cachedInput: usage.int64("cache_read_input_tokens"), output: output,
                    reasoning: details.int64("thinking_tokens"), total: input + output))
                samples.sort { $0.completedAt < $1.completedAt }
                if samples.count > maxSamples {
                    samples.removeFirst(samples.count - maxSamples)
                }
                if turnStarted {
                    turnOutput += output
                    turnGenSeconds += ts.timeIntervalSince(start)
                }
            default:
                break
            }
        }
    }

    private let homePath: String
    private var fileStates: [String: SessionFileState] = [:]
    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var inFlightStart: Date?
    private(set) var path = ""
    private(set) var turnOutput: Int64 = 0
    private(set) var turnGenSeconds: Double = 0
    private(set) var sessions: [SessionSummary] = []

    init(home: String = ClaudeReader.home) { homePath = home }

    // Completed calls within the current user turn, excluding tool execution.
    func liveTPS() -> Double? {
        guard inFlightStart != nil, turnOutput > 0, turnGenSeconds > 0 else { return nil }
        return Double(turnOutput) / turnGenSeconds
    }

    static var home: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        return (env?.isEmpty == false ? env! : (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
    }

    var hasOnceData: Bool { !sessionID.isEmpty || !samples.isEmpty || inFlightStart != nil }

    func poll(forceScan: Bool, now: Date) {
        poll(now: now)
    }

    func poll(now: Date = Date()) {
        let root = (homePath as NSString).appendingPathComponent("projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            clear()
            return
        }
        let cutoff = now.addingTimeInterval(-SpeedSummary.multiSessionWindow)
        var newest: (path: String, date: Date, stamp: String, inode: UInt64, size: UInt64)?
        var recent: [(path: String, date: Date, stamp: String, inode: UInt64, size: UInt64)] = []
        while let rel = enumerator.nextObject() as? String {
            if rel == "subagents" || rel.hasSuffix("/subagents") {
                enumerator.skipDescendants()
                continue
            }
            guard rel.hasSuffix(".jsonl") && !rel.contains("/subagents/") else { continue }
            let file = (root as NSString).appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: file),
                  let date = attrs[.modificationDate] as? Date else { continue }
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let stamp = "\(inode):\(size):\(date.timeIntervalSince1970)"
            if newest == nil || date > newest!.date { newest = (file, date, stamp, inode, size) }
            if date >= cutoff { recent.append((file, date, stamp, inode, size)) }
        }
        recent.sort { $0.date > $1.date }
        var candidates = Array(recent.prefix(8))
        if let newest, !candidates.contains(where: { $0.path == newest.path }) {
            candidates.insert(newest, at: 0)
        }
        guard !candidates.isEmpty else {
            clear()
            return
        }
        let keep = Set(candidates.map(\.path))
        fileStates = fileStates.filter { keep.contains($0.key) }

        var parsed: [SessionFileState] = []
        for candidate in candidates {
            let state = fileStates[candidate.path] ?? SessionFileState(path: candidate.path)
            state.update(stamp: candidate.stamp, inode: candidate.inode, size: candidate.size)
            fileStates[candidate.path] = state
            parsed.append(state)
        }
        guard !parsed.isEmpty else { return }
        let primary = parsed.filter { $0.inFlightStart(at: now) != nil }.max(by: { $0.lastEventAt < $1.lastEventAt })
            ?? parsed.filter { !$0.samples.isEmpty }.max(by: {
                ($0.samples.last?.completedAt ?? .distantPast) < ($1.samples.last?.completedAt ?? .distantPast)
            })
            ?? parsed[0]
        path = primary.path
        sessionID = primary.sessionID
        samples = primary.samples
        inFlightStart = primary.inFlightStart(at: now)
        turnOutput = primary.turnOutput
        turnGenSeconds = primary.turnGenSeconds

        var seen = Set<String>()
        sessions = parsed.compactMap { entry -> SessionSummary? in
            let sid = entry.sessionID.isEmpty ? ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension : entry.sessionID
            guard seen.insert(sid).inserted else { return nil }
            let activeStart = entry.inFlightStart(at: now)
            let isActive = activeStart != nil
            let lastSample = entry.samples.last
            let activityAt = max(isActive ? max(activeStart ?? .distantPast, entry.lastEventAt) : .distantPast,
                                 lastSample?.completedAt ?? .distantPast)
            guard isActive || (lastSample != nil && activityAt >= cutoff) else { return nil }
            return SessionSummary(
                id: sid,
                title: SessionSummary.cleanTitle(entry.title, fallback: sid),
                active: isActive,
                live: entry.liveTPS(at: now),
                last: lastSample?.effectiveTPS,
                activityAt: activityAt,
                inFlightStart: activeStart
            )
        }
    }

    private func clear() {
        sessionID = ""
        path = ""
        samples = []
        inFlightStart = nil
        turnOutput = 0
        turnGenSeconds = 0
        sessions = []
        fileStates.removeAll()
    }

    var medianTPS: Double {
        let values = samples.map(\.effectiveTPS).sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let active = inFlightStart != nil
        let live = liveTPS()
        let last = samples.last?.effectiveTPS
        let completed = samples.last?.completedAt
        let cumulative = L10n.text("This turn: output tokens / total completed-call duration, excluding tool execution; not instantaneous per-token speed.")
        let measurement = cumulative + "\n" + L10n.text("Claude measures from request start to the first complete output block, including time to first token.")
        let summary = SpeedSummary(name: source.label, active: active, live: live, last: last,
            completedAt: completed,
            history: samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: $0.effectiveTPS) },
            model: samples.last?.model ?? "", measurement: measurement, sessions: sessions,
            metrics: samples.last?.metrics)
        let status = active ? "active" : (samples.isEmpty ? "no data" : "ready")
        let diagPath = path.isEmpty ? (homePath as NSString).appendingPathComponent("projects") : path
        return SourceSnapshot(
            source: source,
            summary: summary,
            activityDate: max(completed ?? .distantPast, inFlightStart ?? .distantPast),
            inFlightStart: inFlightStart,
            liveSpeed: live,
            hasData: !samples.isEmpty || active,
            diagnostic: SourceDiagnostic(source: source, path: diagPath, status: status, sampleCount: samples.count)
        )
    }

    func onceLines(now: Date = Date()) -> [String] {
        var lines = ["session:   \(sessionID)", "responses: \(samples.count)"]
        if let sample = samples.last {
            lines.append("last:      \(Fmt.tps(sample.effectiveTPS)) tok/s  elapsed \(Fmt.secs(sample.elapsed))  output \(sample.output)")
        }
        lines.append("median:    \(Fmt.tps(medianTPS)) tok/s")
        lines.append("live:      \(liveTPS().map { Fmt.tps($0) } ?? "-") tok/s  turn output \(turnOutput)")
        return lines
    }
}
