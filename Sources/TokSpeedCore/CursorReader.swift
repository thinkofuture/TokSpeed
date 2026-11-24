import Foundation
import TokSpeedHookCore

// Cursor's local Composer database records reliable tokens but not model-call
// timing; the verified source is Cursor's hook stream. A completed turn uses
// the output tokens reported at `stop` divided by the wall-clock interval from
// `beforeSubmitPrompt` to `stop`. That interval includes thinking, tools and
// waiting, so it is a whole-turn average, never pure model generation speed.
final class CursorReader: SpeedSourceReader {
    let source: SourceMode = .cursor

    private(set) var samples: [Sample] = []
    private(set) var sessionID = ""
    private(set) var readable = false
    private(set) var inFlightStart: Date?
    private(set) var inFlightModel = ""
    private let path: String

    private struct Pending {
        let start: Date
        let model: String
        let conversation: String
    }

    private var pending: [String: Pending] = [:]
    private var conversationSamples: [String: Sample] = [:]
    private var finished: Set<String> = []
    private var finishedOrder: [String] = []
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var remainder = Data()
    private let maxLineBytes = 1024 * 1024
    private let maxSamples = 200
    private let pendingLifetime: TimeInterval = 60 * 60

    static func logPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: String = NSHomeDirectory()) -> String {
        CursorHook.logPath(environment: environment, home: home)
    }

    init(logPath: String = CursorReader.logPath()) { path = logPath }

    var hasOnceData: Bool { readable }

    func poll(forceScan: Bool, now: Date) {
        poll(now: now)
    }

    func poll(now: Date = Date()) {
        let rotatedPath = path + ".1"
        // Keep the inode and byte count from the open descriptor, not the path:
        // the collector can rotate the log between opening and reading it.
        let active = LogFile(path)
        defer { try? active?.handle.close() }
        var followedRotation = false
        if active == nil || active?.id != fileID, let backup = LogFile(rotatedPath) {
            defer { try? backup.handle.close() }
            if backup.id != active?.id && (fileID == nil || fileID == backup.id) {
                read(backup)
                followedRotation = true
            }
            if active == nil {
                // If a writer has just renamed the active file, it might not
                // have created its replacement yet.
                updateActive(now: now)
                return
            }
        }
        guard let active else {
            clear()
            return
        }
        if fileID != nil && active.id != fileID && !followedRotation {
            pending.removeAll()
        }
        read(active)
        updateActive(now: now)
    }

    private struct LogFile {
        let handle: FileHandle
        let id: UInt64
        let size: UInt64

        init?(_ path: String) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                try? handle.close()
                return nil
            }
            self.handle = handle
            self.id = info.st_ino
            self.size = UInt64(info.st_size)
        }
    }

    private func read(_ file: LogFile) {
        if file.id != fileID || file.size < offset {
            if file.id == fileID { pending.removeAll() }
            // A turn can start in the backup and finish in the active log.
            offset = 0
            remainder = Data()
        }
        fileID = file.id
        guard offset < file.size else { readable = true; return }
        do {
            try file.handle.seek(toOffset: offset)
            while offset < file.size {
                let count = Int(min(UInt64(1 << 20), file.size - offset))
                guard let chunk = try file.handle.read(upToCount: count), !chunk.isEmpty else { break }
                consume(chunk)
                offset += UInt64(chunk.count)
            }
            readable = true
        } catch {
            readable = false
        }
    }

    private func consume(_ chunk: Data) {
        remainder.append(chunk)
        var cursor = remainder.startIndex
        while let newline = remainder[cursor...].firstIndex(of: 0x0A) {
            ingest(Data(remainder[cursor..<newline]))
            cursor = newline + 1
        }
        if cursor > remainder.startIndex {
            remainder.removeSubrange(remainder.startIndex..<cursor)
        }
        if remainder.count > maxLineBytes { remainder.removeAll() }
    }

    private func ingest(_ line: Data) {
        guard line.count > 2, line.count <= maxLineBytes,
              let decoded = try? JSONSerialization.jsonObject(with: line),
              let object = decoded as? [String: Any] else { return }
        let event = (object["event"] as? String) ?? (object["hook_event_name"] as? String) ?? ""
        let ids = object["ids"] as? [String: Any] ?? [:]
        guard let conversation = safeString(ids["conversation_id"]) ?? safeString(ids["conversationId"])
                ?? safeString(ids["session_id"]) ?? safeString(ids["sessionId"])
                ?? safeString(object["conversation_id"]) ?? safeString(object["session_id"]) else { return }
        let generation = safeString(ids["generation_id"]) ?? safeString(ids["generationId"])
            ?? safeString(object["generation_id"]) ?? ""
        let key = generation.isEmpty ? conversation : conversation + "|" + generation
        let model = safeString(object["model"]) ?? safeString(object["model_id"])
            ?? safeString(object["modelId"]) ?? ""
        guard let nanoseconds = integer(object["received_unix_ns"]), nanoseconds > 0,
              let date = timestamp(nanoseconds) else { return }

        switch event {
        case "beforeSubmitPrompt":
            // Only the newest generation in a conversation can be active.
            for existing in pending.keys where existing != key && pending[existing]?.conversation == conversation {
                pending.removeValue(forKey: existing)
            }
            pending[key] = Pending(start: date, model: model, conversation: conversation)
        case "stop":
            guard let start = pending.removeValue(forKey: key) else { return }
            guard object["status"] as? String == "completed" else { return }
            let measurements = object["measurements"] as? [String: Any] ?? [:]
            guard let output = integer(measurements["output_tokens"] ?? measurements["outputTokens"]),
                  output > 0 else { return }
            let input = integer(measurements["input_tokens"] ?? measurements["inputTokens"]) ?? 0
            let cached = integer(measurements["cache_read_tokens"] ?? measurements["cacheReadTokens"]) ?? 0
            let reasoning = integer(measurements["reasoning_tokens"] ?? measurements["reasoningTokens"]) ?? 0
            guard date > start.start, input <= Int64.max - output else { return }
            let identity = generation.isEmpty
                ? conversation + "|stop|" + String(nanoseconds)
                : key
            guard finished.insert(identity).inserted else { return }
            finishedOrder.append(identity)
            if finishedOrder.count > 500 { finished.remove(finishedOrder.removeFirst()) }
            let sample = Sample(startedAt: start.start, completedAt: date, firstOutputAt: nil,
                                model: start.model.isEmpty ? model : start.model,
                                input: input, cachedInput: cached, output: output,
                                reasoning: reasoning, total: input + output)
            samples.append(sample)
            conversationSamples[conversation] = sample
            samples.sort { $0.completedAt < $1.completedAt }
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            sessionID = conversation
        default:
            break
        }
    }

    private func updateActive(now: Date) {
        let cutoff = now.addingTimeInterval(-pendingLifetime)
        pending = pending.filter { $0.value.start >= cutoff }
        let sessionCutoff = now.addingTimeInterval(-SpeedSummary.multiSessionWindow)
        conversationSamples = conversationSamples.filter { $0.value.completedAt >= sessionCutoff }
        let active = pending.values.max { $0.start < $1.start }
        inFlightStart = active?.start
        inFlightModel = active?.model ?? ""
        if let active { sessionID = active.conversation }
    }

    func sessions(now: Date = Date()) -> [SessionSummary] {
        let cutoff = now.addingTimeInterval(-SpeedSummary.multiSessionWindow)
        var ids = Set(pending.values.map(\.conversation))
        for (conversation, sample) in conversationSamples where sample.completedAt >= cutoff {
            ids.insert(conversation)
        }
        return ids.compactMap { conversation -> SessionSummary? in
            let activePending = pending.values.filter { $0.conversation == conversation }.max { $0.start < $1.start }
            let lastSample = conversationSamples[conversation]
            let isActive = activePending != nil
            let activityAt = max(activePending?.start ?? .distantPast, lastSample?.completedAt ?? .distantPast)
            guard isActive || lastSample != nil else { return nil }
            return SessionSummary(
                id: conversation,
                title: SessionSummary.cleanTitle("", fallback: conversation),
                active: isActive,
                live: nil,
                last: lastSample?.effectiveTPS,
                activityAt: activityAt,
                inFlightStart: activePending?.start
            )
        }
    }

    func snapshot(now: Date = Date()) -> SourceSnapshot {
        let active = inFlightStart != nil
        let last = samples.last?.effectiveTPS
        let completed = samples.last?.completedAt
        let history = samples.map { CallHistoryPoint(completedAt: $0.completedAt, speed: $0.effectiveTPS) }
        let measurement = L10n.text("Cursor hook: last completed turn. Recorded output tokens / whole-turn time from prompt submit to loop stop, including thinking, tools and waiting; not pure model generation speed. While a turn runs, the menu bar shows elapsed time only.")
        let summary = SpeedSummary(name: source.label, active: active, live: nil, last: last,
            completedAt: completed, history: history,
            model: samples.last?.model ?? inFlightModel, measurement: measurement,
            sessions: sessions(now: now), metrics: samples.last?.metrics)
        let status: String
        if !readable {
            status = "no hook log"
        } else if active {
            status = "active"
        } else {
            status = samples.isEmpty ? "no completed turns" : "ready"
        }
        return SourceSnapshot(
            source: source,
            summary: summary,
            activityDate: max(completed ?? .distantPast, inFlightStart ?? .distantPast),
            inFlightStart: inFlightStart,
            liveSpeed: nil,
            hasData: !samples.isEmpty || active,
            diagnostic: SourceDiagnostic(source: source, path: path, status: status, sampleCount: samples.count)
        )
    }

    func onceLines(now: Date = Date()) -> [String] {
        var lines = ["log:       \(path)"]
        guard readable else {
            lines.append("No Cursor hook log yet. Complete a local Agents Window turn after the integration is installed.")
            return lines
        }
        lines.append("samples:   \(samples.count)")
        lines.append("generating:\(inFlightStart != nil)")
        if let sample = samples.last {
            lines.append("model:     \(sample.model)")
            lines.append("output:    \(sample.output)")
            lines.append("elapsed:   \(Fmt.secs(sample.elapsed))")
            lines.append("speed:     \(Fmt.tps(sample.effectiveTPS)) tok/s (whole turn, including tools/waits)")
        } else {
            lines.append("no completed Cursor turn with recorded output usage and a hook start/stop pair")
        }
        return lines
    }

    private func clear() {
        samples = []
        sessionID = ""
        readable = false
        inFlightStart = nil
        inFlightModel = ""
        pending.removeAll()
        conversationSamples.removeAll()
        finished.removeAll()
        finishedOrder.removeAll()
        offset = 0
        fileID = nil
        remainder = Data()
    }

    private func safeString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 160 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:/@+-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int64.max),
              double.rounded(.towardZero) == double else { return nil }
        return number.int64Value
    }

    private func timestamp(_ nanoseconds: Int64) -> Date? {
        let seconds = Double(nanoseconds) / 1_000_000_000
        guard seconds.isFinite, seconds > 0, seconds < 100_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
