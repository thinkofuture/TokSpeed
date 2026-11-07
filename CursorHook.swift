import Foundation

// Cursor invokes this executable as a hook, so the collector runs even while
// TokSpeed itself is not open. Only allowlisted numeric usage/timing fields and
// opaque correlation ids are retained; prompts, replies, tool data, workspace
// paths, email addresses and credentials are never written.
enum CursorHook {
    static let marker = "--cursor-hook"
    static let events = ["beforeSubmitPrompt", "afterAgentResponse", "stop"]
    static let maxLogBytes: Int64 = 4 * 1024 * 1024
    private static let maxInputBytes = 2 * 1024 * 1024
    private static let maxValueBytes = 160

    private static let numericFields: Set<String> = [
        "input_tokens", "inputTokens", "output_tokens", "outputTokens",
        "prompt_tokens", "promptTokens", "completion_tokens", "completionTokens",
        "total_tokens", "totalTokens", "reasoning_tokens", "reasoningTokens",
        "cache_read_tokens", "cacheReadTokens", "cache_write_tokens", "cacheWriteTokens",
        "cache_read_input_tokens", "cache_creation_input_tokens", "cached_tokens", "cachedTokens",
        "duration", "duration_ms", "durationMs", "total_duration_ms", "totalDurationMs",
        "elapsed_ms", "elapsedMs", "ttft_ms", "time_to_first_token_ms",
        "streaming_duration_ms", "request_duration_ms", "outputTokensPerSecond",
        "startedAtMs", "completedAtMs", "clientRpcSendTime", "clientEndTime",
        "loop_count", "loopCount", "message_count", "tool_call_count",
    ]
    private static let containerFields: Set<String> = [
        "usage", "token_usage", "tokenUsage", "metrics", "timing", "timingInfo", "usage_metadata",
    ]
    private static let idFields = [
        "conversation_id", "conversationId", "generation_id", "generationId",
        "session_id", "sessionId",
    ]

    static func logPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: String = NSHomeDirectory()) -> String {
        if let override = environment["TOKSPEED_CURSOR_HOOK_LOG"], !override.isEmpty {
            return override
        }
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/TokSpeed/cursor-hook/events.jsonl")
    }

    /// Handles `TokSpeed --cursor-hook <event>` before AppKit starts.
    @discardableResult
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: marker) else { return false }
        let event = index + 1 < arguments.count ? arguments[index + 1] : ""
        guard events.contains(event) else {
            writeResponse(Data("{}".utf8))
            return true
        }
        let wall = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let monotonic = Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        let (payload, status) = readPayload()
        let record = self.record(event: event, payload: payload, inputStatus: status,
                                 wallNs: wall, monotonicNs: monotonic)
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            append(data, to: logPath())
        }
        writeResponse(Data((event == "beforeSubmitPrompt" ? "{\"continue\":true}" : "{}").utf8))
        return true
    }

    /// The record format shared by the temporary Python probe and this collector.
    static func record(event: String, payload: [String: Any], inputStatus: String = "ok",
                       wallNs: Int64, monotonicNs: Int64) -> [String: Any] {
        var record: [String: Any] = [
            "collector_version": 1,
            "event": event,
            "input_status": inputStatus,
            "received_unix_ns": wallNs,
            "received_monotonic_ns": monotonicNs,
            "ids": [String: String](),
            "measurements": [String: Any](),
        ]
        var ids = record["ids"] as! [String: String]
        for key in idFields {
            if let value = safeString(payload[key]) { ids[key] = value }
        }
        record["ids"] = ids
        for key in ["cursor_version", "model_id", "modelId", "model"] {
            if let value = safeString(payload[key]) { record[key] = value }
        }
        if let status = payload["status"] as? String, ["completed", "aborted", "error"].contains(status) {
            record["status"] = status
        }
        var measurements: [String: Any] = [:]
        collect(payload, prefix: "", depth: 0, into: &measurements)
        record["measurements"] = measurements
        return record
    }

    private static func collect(_ object: [String: Any], prefix: String, depth: Int,
                                into measurements: inout [String: Any]) {
        for (key, value) in object {
            guard isSafeName(key) else { continue }
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            if numericFields.contains(key) {
                if let normalized = normalizedNumber(value) { measurements[name] = normalized }
            } else if containerFields.contains(key), depth < 2, let nested = value as? [String: Any] {
                collect(nested, prefix: name, depth: depth + 1, into: &measurements)
            }
        }
    }

    private static func normalizedNumber(_ value: Any) -> Any? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int64.max) else { return nil }
        if double.rounded(.towardZero) == double { return number.int64Value }
        return double
    }

    private static func isSafeName(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let first = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = first.union(CharacterSet(charactersIn: "0123456789"))
        guard let scalar = value.unicodeScalars.first, first.contains(scalar) else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy { rest.contains($0) }
    }

    private static func safeString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maxValueBytes else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:/@+-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static func readPayload() -> ([String: Any], String) {
        var data = Data()
        while data.count <= maxInputBytes {
            let remaining = maxInputBytes + 1 - data.count
            let chunk: Data?
            do {
                chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, remaining))
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maxInputBytes else { return ([:], "oversized") }
        guard !data.isEmpty else { return ([:], "invalid_json") }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return ([:], "invalid_json") }
        guard let payload = object as? [String: Any] else { return ([:], "not_object") }
        return (payload, "ok")
    }

    private static func append(_ data: Data, to path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }
        _ = fchmod(descriptor, 0o600)

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        if info.st_size > maxLogBytes {
            _ = ftruncate(descriptor, 0)
        } else if info.st_size > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, info.st_size - 1) == 1, last != 0x0A {
                writeAll(Data([0x0A]), to: descriptor)
            }
        }
        var line = data
        line.append(0x0A)
        writeAll(line, to: descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func writeResponse(_ data: Data) {
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}
