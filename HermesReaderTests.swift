import Foundation

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
    reader.poll()
    precondition(reader.samples.count == 1, "Unchanged logs must not duplicate calls")
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
    try write(line("12:00:08", session: "session-b", output: "80", latency: "4.0"))
    reader.poll()
    precondition(reader.sessionID == HermesReader.digest("session-b") && reader.samples.count == 1 && reader.samples[0].effectiveTPS == 20,
        "Concurrent sessions must not blend their histories")
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
    print("hermes tests: passed (tokens/latency/session isolation/partial writes/rotation/invalid records/bounded tail/custom home)")
}
