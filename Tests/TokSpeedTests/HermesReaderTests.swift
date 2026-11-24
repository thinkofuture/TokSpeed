import Foundation
import XCTest
@testable import TokSpeedApp

func testHermesReader() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-hermes-\(UUID().uuidString)")
    let logs = root.appendingPathComponent("logs")
    try fm.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let file = logs.appendingPathComponent("agent.log")
    func line(_ time: String = "12:00:02", session: String = "session-a", call: Int = 1,
              output: String = "100", latency: String = "2.0", model: String = "model=test provider=local ") -> String {
        "2026-11-07 \(time),000 INFO\(session.isEmpty ? "" : " [\(session)]") agent.conversation_loop: API call #\(call): \(model)in=20 out=\(output) total=120 latency=\(latency)s\n"
    }
    func write(_ text: String, to url: URL? = nil) throws {
        try Data(text.utf8).write(to: url ?? file)
    }
    let reader = HermesReader(home: root.path)
    reader.poll()
    precondition(reader.samples.isEmpty && reader.sessionID.isEmpty)
    let first = line()
    try write(first)
    reader.poll()
    precondition(reader.sessionID == HermesReader.digest("session-a") && reader.samples.count == 1)
    precondition(reader.samples[0].effectiveTPS == 50 && reader.samples[0].model == "test")
    let readsAfterFirst = reader.fileReadCount
    reader.poll()
    precondition(reader.samples.count == 1, "Unchanged logs must not duplicate calls")
    precondition(reader.fileReadCount == readsAfterFirst, "Unchanged Hermes files must not be reread")
    try write(line(output: "200"))
    reader.poll()
    precondition(reader.samples.count == 1 && reader.samples[0].output == 200, "Same-size replacement must refresh")

    let second = line("12:00:04", call: 2, output: "200")
    try write(first + String(second.dropLast()))
    reader.poll()
    precondition(reader.samples.count == 1, "Do not parse partially written lines")
    try write(first + second)
    reader.poll()
    precondition(reader.samples.count == 2 && reader.samples.last?.effectiveTPS == 100)

    // Ignore unrelated messages, missing usage, zero/invalid duration and integer overflow.
    try write(first + second + "unrelated content\n" + line(output: "?", latency: "3.0")
        + line(output: "0") + line(latency: "0.0") + line(output: "99999999999999999999999999"))
    reader.poll()
    precondition(reader.samples.count == 2)

    // Rotation may briefly leave the same record in both files. Never count it twice.
    try write(first + second, to: logs.appendingPathComponent("agent.log.1"))
    try write(second + line("12:00:06", call: 3, output: "300"))
    reader.poll()
    precondition(reader.samples.count == 3)

    // Per-file cache: updating only agent.log must not reread agent.log.1.
    let readsBeforeSingleUpdate = reader.fileReadCount
    try write(second + line("12:00:06", call: 3, output: "300") + line("12:00:07", call: 4, output: "400"))
    reader.poll()
    precondition(reader.fileReadCount == readsBeforeSingleUpdate + 1, "Only modified file should be re-read")

    try write(line("12:00:08", session: "session-b", output: "80", latency: "4.0"))
    reader.poll()
    precondition(reader.sessionID == HermesReader.digest("session-b") && reader.samples.count == 1 && reader.samples[0].effectiveTPS == 20,
        "Concurrent sessions must not blend their histories")

    // Multi-session summary support within window.
    var comps = DateComponents()
    comps.year = 2026; comps.month = 11; comps.day = 7; comps.hour = 12; comps.minute = 1; comps.second = 0
    let pollTime = Calendar(identifier: .gregorian).date(from: comps)!
    reader.poll(now: pollTime)
    precondition(reader.sessions.count == 2, "Expected 2 concurrent Hermes sessions in window")

    try write("")
    reader.poll()
    precondition(reader.sessionID == HermesReader.digest("session-a") && reader.samples.count == 2, "Retain rotated history when the active log is empty")
    try fm.removeItem(at: logs.appendingPathComponent("agent.log.1"))
    try write(line(session: "", model: ""))
    reader.poll()
    precondition(reader.samples.count == 1 && reader.samples[0].model.isEmpty, "Support older lines without model or session tags")

    // Tail reads discard the initial partial line and remain bounded for large logs.
    try write(String(repeating: "x", count: 2 * 1024 * 1024 + 10) + "\n" + first)
    reader.poll()
    precondition(reader.samples.count == 1)
    try write((1...350).map { line(call: $0) }.joined())
    reader.poll()
    precondition(reader.samples.count == 300, "Retained history must remain bounded")
    try fm.removeItem(at: file)
    reader.poll()
    precondition(reader.samples.isEmpty && reader.sessionID.isEmpty, "Deleted logs must clear stale data")
    precondition(!fm.fileExists(atPath: root.appendingPathComponent("state.db").path), "Reading must not create a database")
    precondition(HermesReader.home(environment: [:], userHome: "/fixture") == "/fixture/.hermes")
    precondition(HermesReader.home(environment: ["HERMES_HOME": ""], userHome: "/fixture") == "/fixture/.hermes")
    precondition(HermesReader.home(environment: ["HERMES_HOME": root.path]) == root.path)

    // Plugin installer status, upgrade, conflict protection, and uninstall.
    let fakeResources = root.appendingPathComponent("resources")
    let pluginSrc = fakeResources.appendingPathComponent("HermesPlugin")
    try fm.createDirectory(at: pluginSrc, withIntermediateDirectories: true)
    try Data("name: tokspeed-metrics\nversion: \"1.0.0\"\n".utf8).write(to: pluginSrc.appendingPathComponent("plugin.yaml"))
    try Data("# bundled v1\n".utf8).write(to: pluginSrc.appendingPathComponent("__init__.py"))

    precondition(HermesPluginInstaller.status(home: root.path, resources: fakeResources) == .notInstalled)
    _ = try HermesPluginInstaller.install(home: root.path, resources: fakeResources)
    precondition(HermesPluginInstaller.status(home: root.path, resources: fakeResources) == .installed)

    let installedInit = root.appendingPathComponent("plugins/tokspeed-metrics/__init__.py")
    try Data("# old version\n".utf8).write(to: installedInit)
    precondition(HermesPluginInstaller.status(home: root.path, resources: fakeResources) == .outdated)
    var threw = false
    do { _ = try HermesPluginInstaller.install(home: root.path, resources: fakeResources) } catch { threw = true }
    precondition(threw, "Install without force must not overwrite modified plugin")
    _ = try HermesPluginInstaller.install(home: root.path, resources: fakeResources, force: true)
    precondition(HermesPluginInstaller.status(home: root.path, resources: fakeResources) == .installed)
    let uninstalled = try HermesPluginInstaller.uninstall(home: root.path)
    precondition(uninstalled)
    precondition(HermesPluginInstaller.status(home: root.path, resources: fakeResources) == .notInstalled)

    let foreignDir = root.appendingPathComponent("plugins/tokspeed-metrics")
    try fm.createDirectory(at: foreignDir, withIntermediateDirectories: true)
    try Data("name: custom-user-plugin\n".utf8).write(to: foreignDir.appendingPathComponent("plugin.yaml"))
    if case .conflict = HermesPluginInstaller.status(home: root.path, resources: fakeResources) {
    } else {
        preconditionFailure("Foreign plugin must report conflict")
    }
    var refusedForce = false
    do { _ = try HermesPluginInstaller.install(home: root.path, resources: fakeResources, force: true) } catch { refusedForce = true }
    precondition(refusedForce, "Force install must still refuse foreign plugin conflict")

    print("hermes tests: passed (tokens/latency/per-file cache/multi-session/partial writes/rotation/invalid records/bounded tail/custom home/plugin lifecycle)")
}

func testHermesActivity() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-hermes-activity-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let calls = HermesReader.logURL(home: root.path)
    let activity = calls.deletingLastPathComponent().appendingPathComponent("activity.jsonl")
    let previous = activity.appendingPathExtension("1")
    try fm.createDirectory(at: activity.deletingLastPathComponent(), withIntermediateDirectories: true)
    let base = 1_794_000_000.0
    let now = Date(timeIntervalSince1970: base + 3)
    let sessionA = HermesReader.digest("a"), sessionB = HermesReader.digest("b")
    let request = HermesReader.digest("request")
    func record(_ event: String, _ session: String, _ start: Double) -> String {
        "{\"v\":1,\"event\":\"\(event)\",\"session\":\"\(session)\",\"request\":\"\(request)\",\"started_at\":\(start)}\n"
    }
    let oldStart = record("start", sessionA, base)
    try oldStart.write(to: previous, atomically: true, encoding: .utf8)
    let startB = record("start", sessionB, base + 1)
    let retryA = record("start", sessionA, base + 2)
    let lateStopA = record("stop", sessionA, base)
    try (startB + retryA + lateStopA).write(to: activity, atomically: true, encoding: .utf8)

    let reader = HermesReader(home: root.path)
    reader.poll(now: now)
    XCTAssertEqual(reader.sessionID, sessionA, "Old errors must not clear a newer retry using the same request ID")
    XCTAssertEqual(reader.sessions.filter(\.active).count, 2)
    XCTAssertNil(reader.snapshot(now: now).liveSpeed, "Pending Hermes calls have elapsed time but no live token feed")

    let stopA = record("stop", sessionA, base + 2)
    try (startB + retryA + lateStopA + stopA).write(to: activity, atomically: true, encoding: .utf8)
    reader.poll(now: now)
    XCTAssertEqual(reader.sessionID, sessionB)
    XCTAssertEqual(reader.snapshot(now: now).inFlightStart, Date(timeIntervalSince1970: base + 1))

    reader.poll(now: now.addingTimeInterval(SpeedSummary.multiSessionWindow))
    XCTAssertFalse(reader.snapshot(now: now).summary.active, "A crashed or interrupted request expires")
}
