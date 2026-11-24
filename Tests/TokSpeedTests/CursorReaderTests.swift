import Foundation
import XCTest
@testable import TokSpeedApp
@testable import TokSpeedHookCore

func testCursorReader(helper: String) throws {
    precondition(CursorHook.events == ["beforeSubmitPrompt", "stop"], "Unused afterAgentResponse hook should not be registered")
    try testCursorHookRecord()
    try testCursorHookProcess(helper: helper)
    try testCursorReaderFile()
    try testCursorHookInstaller()
    print("cursor tests: passed (hook lifecycle/dedupe/active/rotation/redaction/installer/status)")
}

private func testCursorHookRecord() throws {
    let secret = "PRIVATE_PROMPT_REPLY_OR_CREDENTIAL"
    let payload: [String: Any] = [
        "conversation_id": "fixture-chat", "generation_id": "fixture-generation",
        "status": "completed", "model": "grok-4.7",
        "output_tokens": 123, "duration_ms": 4000,
        "usage": ["input_tokens": 50, "cache_read_tokens": 20, "text": secret],
        "text": secret, "prompt": secret, "tool_input": ["command": secret],
        "user_email": secret, "workspace_roots": [secret], "unknown_number": 99,
    ]
    let record = CursorHook.record(event: "stop", payload: payload,
        wallNs: 100, monotonicNs: 200)
    let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    let json = String(decoding: encoded, as: UTF8.self)
    precondition(!json.contains(secret), "Hook records must not retain content")
    let measurements = record["measurements"] as! [String: Any]
    precondition((measurements["output_tokens"] as? Int64) == 123)
    precondition((measurements["duration_ms"] as? Int64) == 4000)
    precondition((measurements["usage.input_tokens"] as? Int64) == 50)
    precondition((measurements["usage.cache_read_tokens"] as? Int64) == 20)
    precondition(measurements["unknown_number"] == nil)
    let ids = record["ids"] as! [String: String]
    precondition(ids["conversation_id"] == "fixture-chat" && ids["generation_id"] == "fixture-generation")

    for value: Any in [true, -1, Double.infinity, Double.nan, "123", [String: Any](), 1e30] {
        let invalid = CursorHook.record(event: "stop", payload: ["output_tokens": value],
            wallNs: 1, monotonicNs: 2)
        precondition((invalid["measurements"] as! [String: Any]).isEmpty,
            "Invalid numeric measurements must be omitted")
    }
    let missing = CursorHook.record(event: "stop", payload: [:], wallNs: 1, monotonicNs: 2)
    precondition((missing["measurements"] as! [String: Any]).isEmpty)
    precondition(missing["input_status"] as? String == "ok")
    precondition(CursorHook.record(event: "stop", payload: [:], inputStatus: "invalid_json",
        wallNs: 1, monotonicNs: 2)["input_status"] as? String == "invalid_json")
}

private func testCursorHookProcess(helper: String) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-hook-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let log = root.appendingPathComponent("events.jsonl").path
    let secret = "PRIVATE_HOOK_PAYLOAD"

    XCTAssertTrue(fm.isExecutableFile(atPath: helper), "Cursor hook helper missing: \(helper)")
    let first = try runHook("beforeSubmitPrompt",
        payload: ["conversation_id": "process-chat", "generation_id": "process-generation",
                  "model": "grok-4.7", "prompt": secret], log: log, executable: helper)
    precondition(first.trimmingCharacters(in: .whitespacesAndNewlines) == "{\"continue\":true}")
    let second = try runHook("stop",
        payload: ["conversation_id": "process-chat", "generation_id": "process-generation",
                  "model": "grok-4.7", "status": "completed", "output_tokens": 36,
                   "input_tokens": 17852, "cache_read_tokens": 6016, "text": secret], log: log, executable: helper)
    precondition(second.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    let text = try String(contentsOfFile: log, encoding: .utf8)
    precondition(!text.contains(secret), "Hook process must not retain prompt or reply text")
    let attributes = try fm.attributesOfItem(atPath: log)
    precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let reader = CursorReader(logPath: log)
    reader.poll()
    precondition(reader.readable && reader.samples.count == 1)
    precondition(reader.samples[0].output == 36 && reader.samples[0].input == 17852)
    precondition(reader.samples[0].cachedInput == 6016)
    precondition(reader.inFlightStart == nil)

    // Force exactly one rotation, between r2's start and stop.
    let rotLog = root.appendingPathComponent("rotate.jsonl").path
    let baseNs: Int64 = 1_790_000_000_000_000_000
    let rStart = CursorHook.record(event: "beforeSubmitPrompt",
        payload: ["conversation_id": "rot", "generation_id": "r1"], wallNs: baseNs, monotonicNs: 1)
    let rStop = CursorHook.record(event: "stop",
        payload: ["conversation_id": "rot", "generation_id": "r1", "status": "completed", "output_tokens": 50],
        wallNs: baseNs + 2_000_000_000, monotonicNs: 2)
    let r2Start = CursorHook.record(event: "beforeSubmitPrompt",
        payload: ["conversation_id": "rot", "generation_id": "r2"], wallNs: baseNs + 5_000_000_000, monotonicNs: 3)
    let r2Stop = CursorHook.record(event: "stop",
        payload: ["conversation_id": "rot", "generation_id": "r2", "status": "completed", "output_tokens": 80],
        wallNs: baseNs + 7_000_000_000, monotonicNs: 4)
    let records = try [rStart, rStop, r2Start, r2Stop].map {
        try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
    }
    let limit = Int64(records.prefix(3).reduce(0) { $0 + $1.count + 1 })
    let now = Date(timeIntervalSince1970: Double(baseNs) / 1_000_000_000 + 20)
    let cachedReader = CursorReader(logPath: rotLog)
    CursorHook.append(records[0], to: rotLog, maxBytes: limit)
    cachedReader.poll(now: now)
    XCTAssertNotNil(cachedReader.inFlightStart)
    for record in records.dropFirst() {
        CursorHook.append(record, to: rotLog, maxBytes: limit)
    }
    let backup = try Data(contentsOf: URL(fileURLWithPath: rotLog + ".1"))
    XCTAssertEqual(backup, records.prefix(3).reduce(into: Data()) { $0.append($1); $0.append(0x0A) })
    for reader in [cachedReader, CursorReader(logPath: rotLog)] {
        reader.poll(now: now)
        reader.poll(now: now)
        XCTAssertEqual(reader.samples.map(\.output), [50, 80])
        XCTAssertNil(reader.inFlightStart)
    }

    let partialLog = root.appendingPathComponent("partial.jsonl")
    try Data("partial".utf8).write(to: partialLog)
    CursorHook.append(records[0], to: partialLog.path)
    let repaired = try Data(contentsOf: partialLog)
    XCTAssertEqual(repaired, Data("partial\n".utf8) + records[0] + Data([0x0A]))
}

private func runHook(_ event: String, payload: [String: Any], log: String,
                     executable: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [CursorHook.marker, event]
    var environment = ProcessInfo.processInfo.environment
    environment["TOKSPEED_CURSOR_HOOK_LOG"] = log
    process.environment = environment
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0,
                 "Hook process failed: \(String(decoding: errorData, as: UTF8.self))")
    return String(decoding: data, as: UTF8.self)
}

private func testCursorReaderFile() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-cursor-reader-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("events.jsonl")
    let base: Int64 = 1_790_000_000_000_000_000
    let testNow = Date(timeIntervalSince1970: Double(base) / 1_000_000_000 + 120)
    let reader = CursorReader(logPath: url.path)
    reader.poll(now: testNow)
    precondition(!reader.readable && reader.samples.isEmpty)

    func record(_ event: String, _ generation: String, _ offset: Int64,
                output: Any? = nil, input: Any? = nil, cache: Any? = nil,
                status: String? = nil, conversation: String = "fixture-chat") -> [String: Any] {
        var measurements: [String: Any] = [:]
        if let output { measurements["output_tokens"] = output }
        if let input { measurements["input_tokens"] = input }
        if let cache { measurements["cache_read_tokens"] = cache }
        var value: [String: Any] = [
            "collector_version": 1, "event": event,
            "received_unix_ns": base + offset * 1_000_000,
            "received_monotonic_ns": offset * 1_000_000 + 1,
            "ids": ["conversation_id": conversation, "generation_id": generation],
            "measurements": measurements, "model": "fixture-model",
        ]
        if let status { value["status"] = status }
        return value
    }
    func lines(_ values: [[String: Any]]) throws -> Data {
        var data = Data()
        for value in values {
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }
    func append(_ values: [[String: Any]]) throws {
        let data = try lines(values)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }
    func replace(_ values: [[String: Any]]) throws {
        try lines(values).write(to: url)
    }
    func poll() { reader.poll(now: testNow) }

    try append([record("beforeSubmitPrompt", "g1", 0)])
    poll()
    precondition(reader.readable && reader.samples.isEmpty && reader.inFlightStart != nil)
    precondition(reader.sessionID == "fixture-chat")

    try append([record("stop", "g1", 2_000, output: 100, input: 20, cache: 5, status: "completed")])
    poll()
    precondition(reader.samples.count == 1 && reader.inFlightStart == nil)
    precondition(reader.samples[0].output == 100 && reader.samples[0].input == 20)
    precondition(reader.samples[0].cachedInput == 5)
    precondition(abs(reader.samples[0].elapsed - 2) < 0.001 && abs(reader.samples[0].effectiveTPS - 50) < 0.001)
    precondition(reader.samples[0].model == "fixture-model")

    try append([record("afterAgentResponse", "g1", 2_000, output: 100, input: 20, status: "completed")])
    poll()
    precondition(reader.samples.count == 1, "Response and stop usage must count once")
    try append([record("stop", "g1", 2_000, output: 100, input: 20, status: "completed")])
    poll()
    precondition(reader.samples.count == 1, "Replayed stop events must not duplicate samples")

    try append([record("beforeSubmitPrompt", "g2", 10_000),
                record("stop", "g2", 11_000, output: 0, status: "completed")])
    poll()
    precondition(reader.samples.count == 1 && reader.inFlightStart == nil, "Zero output is not a measurement")
    try append([record("beforeSubmitPrompt", "g3", 20_000),
                record("stop", "g3", 21_000, output: 50, status: "aborted")])
    poll()
    precondition(reader.samples.count == 1 && reader.inFlightStart == nil, "Aborted turns are not measurements")
    try append([record("stop", "g4", 25_000, output: 50, status: "completed")])
    poll()
    precondition(reader.samples.count == 1, "A stop without a start has no duration")
    for (generation, output) in [("g5", true), ("g6", "100"), ("g7", -1)] as [(String, Any)] {
        try append([record("beforeSubmitPrompt", generation, 30_000),
                    record("stop", generation, 31_000, output: output, status: "completed")])
        poll()
    }
    precondition(reader.samples.count == 1, "Invalid token counts are rejected")

    // A partial append is held until the newline arrives.
    let partial = try lines([record("beforeSubmitPrompt", "g8", 40_000)])
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: partial.prefix(partial.count / 2))
    try handle.close()
    poll()
    precondition(reader.inFlightStart == nil)
    let continuation = Data(partial.suffix(from: partial.count / 2))
    let secondHandle = try FileHandle(forWritingTo: url)
    try secondHandle.seekToEnd()
    try secondHandle.write(contentsOf: continuation)
    try secondHandle.close()
    poll()
    precondition(reader.inFlightStart != nil, "A complete line completes after a partial append")
    try append([record("stop", "g8", 42_000, output: 15, status: "completed")])
    poll()
    precondition(reader.samples.count == 2 && reader.samples.last?.output == 15)

    // Truncation keeps prior samples and parses the replacement file.
    try replace([record("beforeSubmitPrompt", "g9", 50_000),
                 record("stop", "g9", 52_000, output: 10, status: "completed")])
    poll()
    precondition(reader.samples.count == 3 && reader.samples.last?.output == 10)

    // Replacing the file changes its identity and must be re-read.
    try fm.removeItem(at: url)
    try replace([record("beforeSubmitPrompt", "g10", 60_000),
                 record("stop", "g10", 61_000, output: 20, status: "completed")])
    poll()
    precondition(reader.samples.count == 4 && reader.samples.last?.output == 20)

    // The temporary Python probe schema remains readable.
    try append([["probe_version": 1, "event": "beforeSubmitPrompt",
                 "received_unix_ns": base + 70_000 * 1_000_000, "ids": ["conversation_id": "legacy"],
                 "measurements": [:], "field_types": ["text": "str"]],
                ["probe_version": 1, "event": "stop", "received_unix_ns": base + 72_000 * 1_000_000,
                 "ids": ["conversation_id": "legacy"], "status": "completed",
                 "measurements": ["output_tokens": 30, "input_tokens": 10]]])
    poll()
    precondition(reader.samples.count == 5 && reader.samples.last?.output == 30)

    try append([[:], ["event": "unknown", "received_unix_ns": base + 80_000,
                      "ids": ["conversation_id": "ignored"]]])
    poll()
    precondition(reader.samples.count == 5, "Malformed or unknown events are ignored")

    try append([record("beforeSubmitPrompt", "g11", 200_000)])
    reader.poll(now: Date(timeIntervalSince1970: Double(base) / 1_000_000_000 + 7200))
    precondition(reader.inFlightStart == nil, "A start without a stop expires instead of showing live forever")

    try fm.removeItem(at: url)
    poll()
    precondition(!reader.readable && reader.samples.isEmpty && reader.sessionID.isEmpty)

    precondition(CursorReader.logPath(environment: ["TOKSPEED_CURSOR_HOOK_LOG": "/tmp/hook.jsonl"],
                                      home: "/fixture") == "/tmp/hook.jsonl")
    precondition(CursorReader.logPath(environment: [:], home: "/fixture")
        == "/fixture/Library/Application Support/TokSpeed/cursor-hook/events.jsonl")
}

private func testCursorHookInstaller() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-cursor-install-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let executable = root.appendingPathComponent("TokSpeed")
    try Data("fixture".utf8).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let otherExecutable = root.appendingPathComponent("OtherTokSpeed")
    try Data("fixture2".utf8).write(to: otherExecutable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: otherExecutable.path)

    let cursor = root.appendingPathComponent(".cursor")
    try fm.createDirectory(at: cursor, withIntermediateDirectories: true)
    let config = cursor.appendingPathComponent("hooks.json")
    precondition(CursorHookInstaller.status(executable: executable.path, home: root.path) == .notInstalled)

    let original: [String: Any] = [
        "custom": "keep",
        "hooks": [
            "stop": [["command": "existing-stop", "timeout": 10]],
            "beforeSubmitPrompt": [["command": "existing-policy"]],
            "preToolUse": [["command": "python3 /tmp/tokspeed-cursor-probe.py preToolUse"]],
        ],
    ]
    let originalData = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
    try originalData.write(to: config)
    precondition(CursorHookInstaller.status(executable: executable.path, home: root.path) == .outdatedPath)

    let legacy = root.appendingPathComponent(
        "Library/Application Support/TokSpeed/cursor-hook-probe/events.jsonl")
    try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"probe_version\":1}\n".utf8).write(to: legacy)

    let installed = CursorHookInstaller.install(executable: executable.path, home: root.path)
    precondition(installed.error == nil && installed.changed)
    precondition(installed.backup.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } == originalData)
    precondition(CursorHookInstaller.status(executable: executable.path, home: root.path) == .installed)
    precondition(CursorHookInstaller.status(executable: otherExecutable.path, home: root.path) == .outdatedPath)

    let installedData = try Data(contentsOf: config)
    precondition(installedData != originalData)
    let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    precondition(updated["custom"] as? String == "keep" && (updated["version"] as? NSNumber)?.intValue == 1)
    let hooks = updated["hooks"] as! [String: Any]
    for event in CursorHook.events {
        let entries = hooks[event] as! [[String: Any]]
        precondition(entries.count == 2)
        let command = entries[0]["command"] as! String
        precondition(command.hasPrefix(executable.path) && command.hasSuffix(event))
        precondition((entries[0]["timeout"] as? NSNumber)?.intValue == 5)
    }
    let stop = hooks["stop"] as! [[String: Any]]
    precondition(stop[1]["command"] as? String == "existing-stop")
    let before = hooks["beforeSubmitPrompt"] as! [[String: Any]]
    precondition(before[1]["command"] as? String == "existing-policy")
    precondition((hooks["preToolUse"] as! [[String: Any]]).isEmpty, "Legacy probe entries are removed")
    let configAttributes = try fm.attributesOfItem(atPath: config.path)
    precondition((configAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let migrated = root.appendingPathComponent("Library/Application Support/TokSpeed/cursor-hook/events.jsonl")
    let migratedData = try Data(contentsOf: migrated)
    precondition(migratedData == Data("{\"probe_version\":1}\n".utf8))

    let again = CursorHookInstaller.install(executable: executable.path, home: root.path)
    precondition(again.error == nil && !again.changed && again.backup == nil)

    let removed = CursorHookInstaller.remove(home: root.path)
    precondition(removed.error == nil && removed.changed)
    precondition(CursorHookInstaller.status(executable: executable.path, home: root.path) == .notInstalled)
    let afterRemoval = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    let remaining = afterRemoval["hooks"] as! [String: Any]
    precondition((remaining["stop"] as! [[String: Any]]).compactMap { $0["command"] as? String } == ["existing-stop"])
    precondition((remaining["beforeSubmitPrompt"] as! [[String: Any]]).compactMap { $0["command"] as? String } == ["existing-policy"])
    precondition((remaining["preToolUse"] as! [[String: Any]]).isEmpty)

    let invalid = root.appendingPathComponent("invalid")
    try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
    let invalidConfig = invalid.appendingPathComponent(".cursor/hooks.json")
    try fm.createDirectory(at: invalidConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: invalidConfig)
    let invalidStatus = CursorHookInstaller.install(executable: executable.path, home: invalid.path)
    let invalidData = try Data(contentsOf: invalidConfig)
    precondition(invalidStatus.error != nil && invalidData == Data("{".utf8))
    if case .error = CursorHookInstaller.status(executable: executable.path, home: invalid.path) {
    } else {
        preconditionFailure("Invalid JSON must report .error status")
    }

    let link = root.appendingPathComponent("link")
    try fm.createDirectory(at: link.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
    let target = link.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try fm.createSymbolicLink(atPath: link.appendingPathComponent(".cursor/hooks.json").path,
                              withDestinationPath: target.path)
    let linkStatus = CursorHookInstaller.install(executable: executable.path, home: link.path)
    let targetData = try Data(contentsOf: target)
    precondition(linkStatus.error != nil && targetData == Data("{}".utf8))

    precondition(CursorHookInstaller.install(executable: "TokSpeed", home: root.path).error != nil)
    let versioned = root.appendingPathComponent("versioned")
    try fm.createDirectory(at: versioned.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
    try Data("{\"version\":2,\"hooks\":{}}".utf8)
        .write(to: versioned.appendingPathComponent(".cursor/hooks.json"))
    precondition(CursorHookInstaller.install(executable: executable.path, home: versioned.path).error != nil)

    let absent = root.appendingPathComponent("absent")
    try fm.createDirectory(at: absent, withIntermediateDirectories: true)
    let absentRemoval = CursorHookInstaller.remove(home: absent.path)
    precondition(absentRemoval.error == nil && !absentRemoval.changed)
    precondition(!fm.fileExists(atPath: absent.appendingPathComponent(".cursor/hooks.json").path))
}
