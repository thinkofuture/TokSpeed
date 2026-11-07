import Foundation

// Cursor's local Composer database records reliable tokens but not model-call
// timing; the verified source is Cursor's hook stream. A completed turn uses
// the output tokens reported at `stop` divided by the wall-clock interval from
// `beforeSubmitPrompt` to `stop`. That interval includes thinking, tools and
// waiting, so it is a whole-turn average, never pure model generation speed.
final class CursorReader {
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
    private var finished: Set<String> = []
    private var finishedOrder: [String] = []
    private var offset: UInt64 = 0
    private var fileID: UInt64 = 0
    private var remainder = Data()
    private let maxLineBytes = 1024 * 1024
    private let maxSamples = 200
    private let pendingLifetime: TimeInterval = 60 * 60

    static func logPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: String = NSHomeDirectory()) -> String {
        CursorHook.logPath(environment: environment, home: home)
    }

    init(logPath: String = CursorReader.logPath()) { path = logPath }

    func poll(now: Date = Date()) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            clear()
            return
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if inode != fileID || size < offset {
            // Rotation reuses the path; truncation leaves old samples intact.
            offset = 0
            fileID = inode
            remainder = Data()
            pending.removeAll()
        }
        if size > offset {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                readable = false
                updateActive(now: now)
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                while offset < size {
                    let count = Int(min(UInt64(1 << 20), size - offset))
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                    offset += UInt64(chunk.count)
                    consume(chunk)
                }
            } catch {
                readable = false
                updateActive(now: now)
                return
            }
        }
        readable = true
        updateActive(now: now)
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
            samples.append(Sample(startedAt: start.start, completedAt: date, firstOutputAt: nil,
                                  model: start.model.isEmpty ? model : start.model,
                                  input: input, cachedInput: cached, output: output,
                                  reasoning: reasoning, total: input + output))
            samples.sort { $0.completedAt < $1.completedAt }
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            sessionID = conversation
        default:
            break
        }
    }

    private func updateActive(now: Date) {
        let cutoff = now.addingTimeInterval(-pendingLifetime)
        for key in pending.keys where (pending[key]?.start ?? .distantPast) < cutoff {
            pending.removeValue(forKey: key)
        }
        let active = pending.values.max { $0.start < $1.start }
        inFlightStart = active?.start
        inFlightModel = active?.model ?? ""
        if let active { sessionID = active.conversation }
    }

    private func clear() {
        samples = []
        sessionID = ""
        readable = false
        inFlightStart = nil
        inFlightModel = ""
        pending.removeAll()
        finished.removeAll()
        finishedOrder.removeAll()
        offset = 0
        fileID = 0
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
