import AppKit
import Foundation
import SQLite3
@testable import TokSpeedApp
import XCTest

func testRolloutIncrementalRead() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("tokspeed-rollout-test-\(UUID().uuidString)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-test.jsonl")
    let prefix = Data("""
    {"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
    {"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant"}}

    """.utf8)
    let usage = Data("""
    {"timestamp":"2026-01-01T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":100}}}}

    """.utf8)
    let split = usage.count / 2
    try (prefix + usage.prefix(split)).write(to: file)
    let reader = RolloutReader()
    reader.read(file)
    precondition(reader.samples.isEmpty)
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.seekToEnd()
    try writer.write(contentsOf: usage.suffix(usage.count - split))
    reader.read(file)
    precondition(reader.samples.count == 1, "A completed partial record must appear on the next poll")
    precondition(reader.samples[0].effectiveTPS == 50)
    reader.read(file)
    precondition(reader.samples.count == 1, "Repeated polling must not duplicate samples")
    let clock = Date(timeIntervalSince1970: 1767225604)
    precondition(reader.liveTPS(now: clock) == 50)
    precondition(!reader.isActive(at: clock.addingTimeInterval(901)))
    try writer.write(contentsOf: Data("{\"timestamp\":\"2026-01-01T00:00:04.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n".utf8))
    reader.read(file)
    precondition(reader.liveTPS(now: clock) == nil && !reader.isActive(at: clock) && reader.samples.count == 1)

    // Sample cap (300) and large >8MB tail read preserving header metadata.
    let big = directory.appendingPathComponent("rollout-2026-01-01T00-00-00-44444444-4444-4444-8444-444444444444.jsonl")
    var bigText = [
        "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"44444444-4444-4444-8444-444444444444\"}}",
        "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5-codex\"}}",
        "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Huge rollout title\"}}"
    ].joined(separator: "\n") + "\n"
    let filler = "{\"timestamp\":\"2026-01-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"padding\",\"data\":\"" + String(repeating: "a", count: 900) + "\"}}\n"
    bigText += String(repeating: filler, count: 9500) // > 8.5 MB
    for idx in 1...320 {
        let baseSec = idx * 3
        let start = ISO8601DateFormatter.codex.string(from: Date(timeIntervalSince1970: 1767225600 + Double(baseSec)))
        let mid = ISO8601DateFormatter.codex.string(from: Date(timeIntervalSince1970: 1767225600 + Double(baseSec + 1)))
        let end = ISO8601DateFormatter.codex.string(from: Date(timeIntervalSince1970: 1767225600 + Double(baseSec + 2)))
        bigText += "{\"timestamp\":\"\(start)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        bigText += "{\"timestamp\":\"\(mid)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}\n"
        bigText += "{\"timestamp\":\"\(end)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"output_tokens\":100}}}}\n"
    }
    try bigText.write(to: big, atomically: true, encoding: .utf8)
    let bigReader = RolloutReader()
    bigReader.read(big)
    precondition(bigReader.sessionID == "44444444-4444-4444-8444-444444444444")
    precondition(bigReader.model == "gpt-5-codex", "Large rollout tail read must retain model from header")
    precondition(bigReader.firstUserMessage == "Huge rollout title", "Large rollout tail read must retain title from header")
    precondition(bigReader.samples.count == 300, "RolloutReader must bound samples to 300")

    print("rollout tests: passed (partial writes, repeat poll, stale/aborted turns, 300-cap, >8MB header preservation)")
}

func testISO8601DateParser() {
    let withFrac = ISO8601DateParser.parse("2026-11-24T10:00:00.250Z")
    let withoutFrac = ISO8601DateParser.parse("2026-11-24T10:00:00Z")
    precondition(withFrac != nil && withoutFrac != nil)
    precondition(abs(withFrac!.timeIntervalSince(withoutFrac!) - 0.25) < 0.0001)
    precondition(ISO8601DateParser.parse("not-a-timestamp") == nil)
    print("date parser tests: passed (fractional and whole-second ISO8601)")
}

func testClaudeIncrementalAndErrors() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-claude-inc-\(UUID().uuidString)")
    let proj = root.appendingPathComponent("projects/demo")
    let subagents = proj.appendingPathComponent("subagents")
    try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let fmt = ISO8601DateFormatter.codex
    let now = Date()
    let sessionFile = proj.appendingPathComponent("s1.jsonl")
    let subagentFile = subagents.appendingPathComponent("sub.jsonl")

    try [
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-3)))\",\"type\":\"api-request\",\"id\":\"sub-req\",\"sessionId\":\"sub\"}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-1)))\",\"type\":\"assistant\",\"requestRef\":\"sub-req\",\"sessionId\":\"sub\",\"message\":{\"id\":\"sub-m\",\"model\":\"sub-model\",\"usage\":{\"input_tokens\":5,\"output_tokens\":999}}}"
    ].joined(separator: "\n").appending("\n").write(to: subagentFile, atomically: true, encoding: .utf8)

    let line1 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-20)))\",\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"Incremental test\"}}\n"
    let line2 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-18)))\",\"type\":\"api-request\",\"id\":\"r1\",\"sessionId\":\"s1\"}\n"
    let line3 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-16)))\",\"type\":\"assistant\",\"requestRef\":\"r1\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus\",\"usage\":{\"input_tokens\":10,\"output_tokens\":200}}}\n"
    let line4 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-10)))\",\"type\":\"api-request\",\"id\":\"r2\",\"sessionId\":\"s1\"}\n"

    try (line1 + line2 + line3 + line4).write(to: sessionFile, atomically: true, encoding: .utf8)

    let reader = ClaudeReader(home: root.path)
    reader.poll(now: now)
    precondition(reader.sessionID == "s1" && reader.samples.count == 1 && reader.inFlightStart != nil)

    // Appending an API error clears active pending state immediately instead of lingering 15m.
    let errLine = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-9)))\",\"type\":\"system\",\"subtype\":\"api_error\",\"isApiErrorMessage\":true,\"requestRef\":\"r2\",\"sessionId\":\"s1\"}\n"
    let handle = try FileHandle(forWritingTo: sessionFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(errLine.utf8))
    try handle.close()

    reader.poll(now: now)
    precondition(reader.inFlightStart == nil && reader.samples.count == 1, "API error must clear pending Claude request")

    // Append another valid call incrementally.
    let line5 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-5)))\",\"type\":\"api-request\",\"id\":\"r3\",\"sessionId\":\"s1\"}\n"
    let line6 = "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-3)))\",\"type\":\"assistant\",\"requestRef\":\"r3\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m2\",\"model\":\"claude-opus\",\"usage\":{\"input_tokens\":10,\"output_tokens\":300}}}\n"
    let h2 = try FileHandle(forWritingTo: sessionFile)
    try h2.seekToEnd()
    try h2.write(contentsOf: Data((line5 + line6).utf8))
    try h2.close()
    reader.poll(now: now)
    precondition(reader.samples.count == 2 && reader.samples.last?.effectiveTPS == 150)
    print("claude incremental tests: passed (incremental tail, subagent dir skip, error cleanup)")
}

func testProviderLogoEnhancedSVG() {
    let svg = """
    <svg viewBox="0 0 24 24">
      <path d="M 2 2 l 8 0 v 8 h -8 z"/>
      <path d="M 12 12 q 4 -4 8 0 t 4 0"/>
    </svg>
    """
    let parsed = ProviderLogo.parsePath(svg)
    precondition(parsed != nil && !parsed!.isEmpty && parsed!.bounds.width > 10 && parsed!.bounds.height > 6,
        "ProviderLogo must support multiple <path> elements and relative SVG commands")
    print("provider logo SVG tests: passed (multi-path, relative commands, quadratic curves)")
}

func testMultiSessionReaders() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-multisession-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 1. Codex multi-session + title lookup (session_index.jsonl > dynamic state_*.sqlite > user message)
    let codexHome = root.appendingPathComponent("codex")
    let codexSessions = codexHome.appendingPathComponent("sessions/2026/11/24")
    try fm.createDirectory(at: codexSessions, withIntermediateDirectories: true)
    let now = Date()
    let fmt = ISO8601DateFormatter.codex
    let id1 = "11111111-1111-4111-8111-111111111111"
    let id2 = "22222222-2222-4222-8222-222222222222"
    let id3 = "33333333-3333-4333-8333-333333333333"
    func rollout(_ id: String, startOffset: TimeInterval, out: Int, complete: Bool, userMsg: String) -> String {
        let t0 = fmt.string(from: now.addingTimeInterval(startOffset))
        let t1 = fmt.string(from: now.addingTimeInterval(startOffset + 2))
        let t2 = fmt.string(from: now.addingTimeInterval(startOffset + 3))
        var lines = [
            "{\"timestamp\":\"\(t0)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}",
            "{\"timestamp\":\"\(t0)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}",
            "{\"timestamp\":\"\(t0)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(userMsg)\"}}",
            "{\"timestamp\":\"\(t1)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}",
            "{\"timestamp\":\"\(t2)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"output_tokens\":\(out)}}}}"
        ]
        if complete {
            let t3 = fmt.string(from: now.addingTimeInterval(startOffset + 4))
            lines.append("{\"timestamp\":\"\(t3)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}")
        }
        return lines.joined(separator: "\n") + "\n"
    }
    try rollout(id1, startOffset: -10, out: 120, complete: false, userMsg: "Fallback 1")
        .write(to: codexSessions.appendingPathComponent("rollout-2026-11-24T10-00-00-\(id1).jsonl"), atomically: true, encoding: .utf8)
    try rollout(id2, startOffset: -20, out: 80, complete: false, userMsg: "Fallback 2")
        .write(to: codexSessions.appendingPathComponent("rollout-2026-11-24T09-59-50-\(id2).jsonl"), atomically: true, encoding: .utf8)
    try rollout(id3, startOffset: -30, out: 60, complete: true, userMsg: "Refactor parser")
        .write(to: codexSessions.appendingPathComponent("rollout-2026-11-24T09-59-40-\(id3).jsonl"), atomically: true, encoding: .utf8)
    try "{\"id\":\"\(id1)\",\"thread_name\":\"Fix payment retry\"}\n"
        .write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

    var db5: OpaquePointer?
    guard sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &db5) == SQLITE_OK else {
        throw NSError(domain: "MultiSessionFixture", code: 1)
    }
    defer { sqlite3_close_v2(db5) }
    guard sqlite3_exec(db5, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(id2)', '', 'Stale v5 title', 50);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "MultiSessionFixture", code: 2)
    }
    // Dynamic version resolution: state_6.sqlite must win over state_5.sqlite.
    var db6: OpaquePointer?
    guard sqlite3_open(codexHome.appendingPathComponent("state_6.sqlite").path, &db6) == SQLITE_OK else {
        throw NSError(domain: "MultiSessionFixture", code: 3)
    }
    defer { sqlite3_close_v2(db6) }
    guard sqlite3_exec(db6, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(id2)', '', 'Optimize SQLite WAL', 100);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "MultiSessionFixture", code: 4)
    }

    let codex = CodexMultiReader(home: codexHome.path)
    codex.poll(forceScan: true, now: now)
    let codexSummary = SpeedSummary(name: "Codex", active: codex.isActive(at: now), live: codex.liveTPS(now: now),
        last: codex.samples.last?.effectiveTPS, completedAt: codex.samples.last?.completedAt, history: [],
        model: codex.model, measurement: "test", sessions: codex.sessions)
    let codexVisible = codexSummary.visibleSessions(now: now)
    precondition(codexVisible.count == 3, "Expected 3 concurrent Codex sessions, got \(codexVisible.count)")
    precondition(codexVisible.map(\.title) == ["Fix payment retry", "Optimize SQLite WAL", "Refactor parser"],
        "Unexpected Codex titles: \(codexVisible.map(\.title))")
    precondition(codexVisible.map { $0.speedText(now: now) } == ["60", "40", "30"])
    precondition(codexVisible.map(\.active) == [true, true, false])

    // 2. Claude multi-session + custom-title / user fallback
    let claudeHome = root.appendingPathComponent("claude")
    let claudeProj = claudeHome.appendingPathComponent("projects/demo")
    try fm.createDirectory(at: claudeProj, withIntermediateDirectories: true)
    let c1 = [
        "{\"type\":\"custom-title\",\"customTitle\":\"Design review\",\"sessionId\":\"claude-1\"}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-12)))\",\"type\":\"user\",\"sessionId\":\"claude-1\",\"message\":{\"content\":\"Review PR\"}}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-10)))\",\"type\":\"api-request\",\"id\":\"req1\",\"sessionId\":\"claude-1\"}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-8)))\",\"type\":\"assistant\",\"requestRef\":\"req1\",\"sessionId\":\"claude-1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus\",\"usage\":{\"input_tokens\":10,\"output_tokens\":200}}}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-6)))\",\"type\":\"api-request\",\"id\":\"req2\",\"sessionId\":\"claude-1\"}"
    ].joined(separator: "\n") + "\n"
    let c2 = [
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-20)))\",\"type\":\"user\",\"sessionId\":\"claude-2\",\"message\":{\"content\":\"Fix login flow\\nsecond line\"}}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-18)))\",\"type\":\"api-request\",\"id\":\"req3\",\"sessionId\":\"claude-2\"}",
        "{\"timestamp\":\"\(fmt.string(from: now.addingTimeInterval(-16)))\",\"type\":\"assistant\",\"requestRef\":\"req3\",\"sessionId\":\"claude-2\",\"message\":{\"id\":\"m2\",\"model\":\"claude-sonnet\",\"usage\":{\"input_tokens\":10,\"output_tokens\":100}}}"
    ].joined(separator: "\n") + "\n"
    try c1.write(to: claudeProj.appendingPathComponent("claude-1.jsonl"), atomically: true, encoding: .utf8)
    try c2.write(to: claudeProj.appendingPathComponent("claude-2.jsonl"), atomically: true, encoding: .utf8)
    let claude = ClaudeReader(home: claudeHome.path)
    claude.poll(now: now)
    let claudeSummary = SpeedSummary(name: "Claude Code", active: claude.inFlightStart != nil, live: claude.liveTPS(),
        last: claude.samples.last?.effectiveTPS, completedAt: claude.samples.last?.completedAt, history: [],
        model: "", measurement: "test", sessions: claude.sessions)
    let claudeVisible = claudeSummary.visibleSessions(now: now)
    precondition(claudeVisible.count == 2 && claudeVisible.map(\.title) == ["Design review", "Fix login flow"])
    precondition(claudeVisible.map { $0.speedText(now: now) } == ["100", "50"])
    print("multi-session reader tests: passed (Codex index/dynamic state_N.sqlite/fallback titles, Claude custom-title/fallback)")
}

func testCodexPartitionScan() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("tokspeed-codex-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    let now = Date()
    let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
    let partition = String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!)
    let daily = home.appendingPathComponent("sessions/\(partition)/rollout-today.jsonl")
    let archived = home.appendingPathComponent("archived_sessions/rollout-old.jsonl")
    for (url, date) in [(daily, now), (archived, now.addingTimeInterval(-3600))] {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    XCTAssertEqual(CodexHome.recentRollouts(in: home.path, now: now, recentPartitionsOnly: true).map(\.lastPathComponent),
        [daily.lastPathComponent])
    try fm.removeItem(at: daily)
    XCTAssertTrue(CodexHome.recentRollouts(in: home.path, now: now, recentPartitionsOnly: true).isEmpty)
    XCTAssertEqual(CodexHome.recentRollouts(in: home.path, now: now, recentPartitionsOnly: true, keeping: [archived]).map(\.lastPathComponent),
        [archived.lastPathComponent])
    XCTAssertEqual(CodexHome.newestRollout(in: home.path)?.lastPathComponent, archived.lastPathComponent)
}

func testMenuPreferences(delegate: AppDelegate, defaults: UserDefaults) {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    delegate.setStatusItemForTesting(statusItem)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }
    let menu = NSMenu()
    func openMenu() { delegate.rebuildMenu(menu) }
    func verifyQuitPlacement() -> [NSButton] {
        let quit = menu.items.first { $0.title == L10n.text("Quit") }!
        precondition(quit.action == #selector(NSApplication.terminate(_:)) && quit.submenu == nil)
        precondition(quit.target === NSApp && quit.keyEquivalent == "q" && quit.isHidden && quit.allowsKeyEquivalentWhenHidden)
        precondition(!menu.items.contains(where: \.isSeparatorItem))
        let footer = menu.items.last!.view as! PanelFooterView
        let buttons = footer.subviews.compactMap { $0 as? NSButton }
        precondition(buttons.count == 2 && buttons.allSatisfy { $0.title.isEmpty && $0.image != nil && $0.imagePosition == .imageOnly })
        precondition(buttons[0].frame.minX > footer.bounds.midX &&
            buttons[0].frame.maxX < buttons[1].frame.minX &&
            buttons[1].frame.maxX == footer.bounds.maxX - PanelStyle.inset)
        let expectedTopPadding = PanelFooterView.topPadding(for: delegate.panelLayout)
        precondition(buttons.allSatisfy { footer.bounds.maxY - $0.frame.maxY == expectedTopPadding })
        return buttons
    }
    func send(_ control: NSControl) {
        precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
    }
    openMenu()
    let buttons = verifyQuitPlacement()
    precondition(menu.items.allSatisfy { $0.submenu == nil })
    let settings = menu.items.first { $0.title == L10n.text("Settings") + "…" }!
    precondition(settings.keyEquivalent == "," && settings.isHidden && settings.allowsKeyEquivalentWhenHidden)
    send(buttons[0])
    let controller = delegate.testSettingsController!
    precondition(controller.window?.isVisible == true)
    let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
        characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
    precondition(controller.window!.performKeyEquivalent(with: closeEvent))
    precondition(controller.window?.isVisible == false, "Command-W closes Settings, not the app")
    let settingsEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil,
        characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
    precondition(menu.performKeyEquivalent(with: settingsEvent))
    precondition(delegate.testSettingsController === controller && controller.window?.isVisible == true, "Reuse the settings window")
    defer { controller.window?.close() }
    let panel = menu.items.first!.view as! SpeedPanelView
    precondition(panel.cards.map { $0.summary?.name } == delegate.toolOrder.map(\.label))
    precondition(panel.cards.allSatisfy { $0.summary?.caption() == L10n.text("No data") })
    precondition(delegate.display == .speedAndUnit)
    controller.displayPopup.selectItem(at: 2)
    send(controller.displayPopup)
    precondition(delegate.display == .iconOnly)
    precondition(statusItem.button?.title == "" && delegate.currentSymbol == "bolt.fill")
    controller.sourcePopup.selectItem(at: ([SourceMode.auto] + delegate.toolOrder).firstIndex(of: .opencode)!)
    send(controller.sourcePopup)
    precondition(delegate.mode == .opencode)
    precondition(controller.generalGrid.numberOfRows == 3)
    precondition(controller.toolCheckboxes.count == ToolOrder.popular.count)

    // Toggle tool visibility & reset order from Settings.
    delegate.setToolVisible(.hermes, visible: false)
    precondition(!delegate.toolOrder.contains(.hermes) && delegate.installedToolOrder.contains(.hermes))
    precondition(controller.toolCheckboxes[.hermes]?.state == .off)
    delegate.setToolVisible(.hermes, visible: true)
    precondition(delegate.toolOrder.contains(.hermes))
    precondition(controller.toolCheckboxes[.hermes]?.state == .on)

    // Click card pin/unpin behavior.
    delegate.togglePin(.codex)
    precondition(delegate.mode == .codex)
    delegate.togglePin(.codex)
    precondition(delegate.mode == .auto)

    // Sleep/wake lifecycle.
    delegate.handleSleep()
    precondition(!delegate.testTimerIsActive)
    delegate.handleWake()
    precondition(delegate.testTimerIsActive)

    // Diagnostics output includes installed sources.
    precondition(!delegate.diagnosticsReportLines().isEmpty)

    let originalItems = menu.items
    let originalFrames = panel.cards.map(\.frame)
    precondition(delegate.moveTool(.claude, to: 2, in: menu))
    precondition(delegate.toolOrder == [.codex, .opencode, .claude, .antigravity, .hermes, .cursor])
    precondition(menu.items.count == originalItems.count &&
        zip(originalItems, menu.items).allSatisfy { $0 === $1 }, "Reordering preserves NSMenu slots")
    precondition(menu.items.first?.view === panel && panel.cards.map(\.frame) == originalFrames,
        "Reordering leaves the attached chart and legend slots in place")
    precondition(panel.cards.map(\.source) == delegate.toolOrder)
    precondition(controller.state?.sources == delegate.installedToolOrder && controller.state?.source == .auto)
    let restored = AppDelegate(defaults: defaults, detectInstalledTools: { Set(ToolOrder.popular) })
    precondition(restored.toolOrder == delegate.toolOrder && restored.mode == delegate.mode && restored.display == delegate.display)
    precondition(controller.displayPopup.indexOfSelectedItem == 2)
    let firstCard = panel.cards[0]
    precondition(firstCard.accessibilityCustomActions()?.count == 1)
    let moveRight = firstCard.accessibilityCustomActions()!.first!
    precondition(moveRight.name == L10n.text("Move right") && moveRight.handler?() == true)
    precondition(delegate.toolOrder == [.opencode, .codex, .claude, .antigravity, .hermes, .cursor], "VoiceOver can reorder without dragging")
    delegate.resetToolOrder()
    openMenu()
    precondition(delegate.toolOrder == ToolOrder.popular)
    for (index, choice) in StatusDisplay.allCases.enumerated() {
        controller.displayPopup.selectItem(at: index)
        send(controller.displayPopup)
        precondition(delegate.currentSymbol == "bolt.fill" && statusItem.button?.title == "", "Idle must always show only lightning")
        delegate.renderStatus(source: .opencode, active: true, speed: 46.1, elapsed: 8)
        let expected = choice.title(active: true, speed: 46.1, elapsed: 8)
        precondition(statusItem.button?.attributedTitle.string == (expected.isEmpty ? "" : " " + expected))
        precondition(delegate.currentSymbol == (choice == .iconOnly ? "bolt.fill" : "logo-opencode"))
        precondition(statusItem.button?.image?.isTemplate == true)
        delegate.renderStatus(source: .opencode, active: true, speed: nil, elapsed: 8)
        let waiting = choice == .iconOnly ? "" : L10n.text("%d s", 8)
        precondition(statusItem.button?.attributedTitle.string == (waiting.isEmpty ? "" : " " + waiting))
        delegate.renderStatus(source: .antigravity, active: true, speed: 200, elapsed: 8)
        let recorded = choice.title(active: true, speed: 200, elapsed: 8)
        precondition(statusItem.button?.attributedTitle.string == (recorded.isEmpty ? "" : " " + recorded))
        precondition(statusItem.button?.toolTip == L10n.text("%@: latest recorded model call, %@ tok/s", SourceMode.antigravity.label, "200"))
        delegate.renderStatus(source: .opencode, active: false, speed: nil, elapsed: 0)
        precondition(statusItem.button?.title == "" && delegate.currentSymbol == "bolt.fill")
    }
    precondition(delegate.panelLayout == .chart && controller.layoutPopup.indexOfSelectedItem == 0)
    controller.layoutPopup.selectItem(at: 1)
    send(controller.layoutPopup)
    openMenu()
    let classic = menu.items.first!.view as! SpeedPanelView
    precondition(classic.layout == .classic && classic.chart.superview == nil)
    precondition(classic.cards.map(\.source) == ToolOrder.popular)
    precondition(classic.cards.allSatisfy { $0.subviews.contains { $0 is ClassicTrendView } })
    precondition(zip(classic.cards, classic.cards.dropFirst()).allSatisfy { $0.0.frame.minY == $0.1.frame.maxY })
    let frames = classic.cards.map(\.frame)
    let below = NSPoint(x: frames.last!.midX, y: frames.last!.minY + 1)
    precondition(MenuCardReorder.destination(at: below, frames: frames, from: 0, vertical: true)?.index == frames.count - 1)
    let moveDown = classic.cards[0].accessibilityCustomActions()!.first!
    precondition(moveDown.name == L10n.text("Move down") && moveDown.handler?() == true)
    precondition(classic.cards.map(\.frame) == frames && classic.cards.map(\.source) == delegate.toolOrder)
    precondition(delegate.moveTool(.claude, to: 0, in: menu))
    _ = verifyQuitPlacement()
    precondition(AppDelegate(defaults: defaults, detectInstalledTools: { Set(ToolOrder.popular) }).panelLayout == .classic)
    controller.layoutPopup.selectItem(at: 0)
    send(controller.layoutPopup)
    openMenu()
    let combined = menu.items.first!.view as! SpeedPanelView
    precondition(combined.layout == .chart && combined.chart.superview === combined)
    _ = verifyQuitPlacement()
    print("settings smoke: passed (source, status display, both panel views, visibility/reset, pin/sleep/wake, persistence, action footer)")
    print("menu reorder tests: passed (fixed slots/source rebinding/VoiceOver actions/persistence)")
}

func testInstalledVisibility(delegate: AppDelegate, defaults: UserDefaults, setInstalled: (Set<SourceMode>) -> Void) {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    delegate.setStatusItemForTesting(statusItem)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }
    let menu = NSMenu()
    delegate.mode = .claude
    defaults.set(["opencode", "claude", "codex", "antigravity"], forKey: "toolOrder")
    for available: Set<SourceMode> in [[.codex, .opencode], [.claude], [.hermes], [.cursor], []] {
        setInstalled(available)
        delegate.applySnapshot(.empty(installedSources: available))
        delegate.rebuildMenu(menu)
        delegate.updateTitle()
        let panel = menu.items.first!.view as! SpeedPanelView
        precondition(Set(panel.cards.map(\.source)) == available)
        let controller = delegate.prepareSettings()
        let choices = controller.sourcePopup.itemArray.compactMap { ($0.representedObject as? String).flatMap(SourceMode.init(rawValue:)) }
        precondition(choices == [.auto] + delegate.toolOrder)
        precondition(controller.sourcePopup.selectedItem?.representedObject as? String == delegate.effectiveMode.rawValue)
        let cards = panel.cards
        precondition(cards.count == available.count)
        precondition(cards.allSatisfy { ($0.onDrag != nil) == (available.count > 1) })
        precondition(delegate.mode == .claude, "Temporarily missing apps must not erase a pinned preference")
        if available.isEmpty {
            precondition(delegate.activeSource == .auto && delegate.currentSymbol == "bolt.fill" && statusItem.button?.title == "")
            precondition(menu.items.contains { $0.title == L10n.text("No tools installed") })
        } else {
            precondition(available.contains(delegate.activeSource))
        }
    }
    setInstalled([.codex, .opencode])
    delegate.applySnapshot(.empty(installedSources: [.codex, .opencode]))
    delegate.moveTool(.codex, to: 0)
    precondition(delegate.savedToolOrder == [.codex, .claude, .opencode, .antigravity, .hermes, .cursor], "Hidden tools retain their saved positions")
    setInstalled(Set(ToolOrder.popular))
    delegate.applySnapshot(.empty(installedSources: Set(ToolOrder.popular)))
    precondition(delegate.effectiveMode == .claude && delegate.toolOrder == delegate.savedToolOrder)
    print("installation menu tests: passed (partial/all/none, hidden choices, pin fallback, restored order)")
}

func testPanel(previewDirectory: String?) throws {
    let appBundle = ProcessInfo.processInfo.environment["TOKSPEED_TEST_APP_BUNDLE"].flatMap { Bundle(path: $0) }
    if let appBundle {
        precondition(appBundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon")
        let icon = appBundle.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        precondition(icon?.isValid == true, "Missing or invalid bundled app icon")
        print("app icon tests: passed (bundle declaration and ICNS loading)")
    }
    let now = Date()
    func point(_ secondsAgo: TimeInterval, _ speed: Double) -> CallHistoryPoint {
        CallHistoryPoint(completedAt: now.addingTimeInterval(-secondsAgo), speed: speed)
    }
    func summary(active: Bool = true, live: Double? = 46.1, last: Double? = 31.7,
                 history: [CallHistoryPoint] = []) -> SpeedSummary {
        SpeedSummary(name: "Codex", active: active, live: live, last: last,
            completedAt: now.addingTimeInterval(-8), history: history, model: "test", measurement: "test")
    }
    precondition(summary().value == "46" && Fmt.tps(10) == "10.0" && Fmt.tps(8.24) == "8.2")
    let panel = SpeedPanelView(sources: ToolOrder.popular)
    precondition(abs(panel.chart.frame.height / panel.chart.frame.width - 3.0 / 5.0) < 0.001)
    precondition(panel.chart.frame.minY > panel.cards[0].frame.maxY)
    precondition(panel.cards.first!.frame.minX == panel.chart.frame.minX &&
        abs(panel.cards.last!.frame.maxX - panel.chart.frame.maxX) < 0.001)
    for card in panel.cards {
        let source = card.source
        if let appBundle {
            precondition(appBundle.url(forResource: source.rawValue, withExtension: "svg", subdirectory: "Logos") != nil,
                "Missing bundled provider artwork: \(source.rawValue)")
        }
        precondition(ProviderLogo.image(source)?.isTemplate == true, "Missing template logo: \(source.rawValue)")
        card.update(summary())
        XCTAssertEqual(card.toolTip, "Codex · test\ntest")
        let logo = card.subviews.compactMap { $0 as? NSImageView }.first!
        let labels = card.subviews.compactMap { $0 as? NSTextField }
        precondition(labels.map(\.stringValue) == ["46"], "Only the speed is visible")
        let speed = labels[0]
        precondition(speed.frame.minX < logo.frame.midX && logo.frame.midX < speed.frame.maxX &&
            logo.frame.midX == card.bounds.midX && logo.frame.minY > speed.frame.maxY,
            "The logo and number must share a centered column without overlapping")
        precondition(logo.contentTintColor == PanelStyle.color(active: true) && speed.textColor == logo.contentTintColor)
        card.update(summary(active: false))
        precondition(logo.contentTintColor == PanelStyle.color(active: false) && speed.textColor == logo.contentTintColor)
    }
    precondition(summary().caption(now: now) == L10n.text("This turn"))
    precondition(summary(active: false).value == "32")
    precondition(summary(live: nil).caption(now: now) == L10n.text("Last · %@", L10n.text("%d s ago", 8)))
    precondition(summary(live: nil, last: nil).value == "—")
    precondition(summary(live: nil, last: nil).caption(now: now) == L10n.text("Waiting for data"))
    precondition(summary(active: false, live: nil, last: nil).caption(now: now) == L10n.text("No data"))
    precondition(summary(live: .nan, last: .infinity).value == "—")
    let many = (1...75).map { point(Double(76 - $0) * 5, Double($0)) }
    let invalid = [Double.nan, .infinity, 0, -1].map { point(0, $0) }
    precondition(summary(history: Array(many.reversed()) + invalid).recent == Array(many.suffix(60)))
    let stale = 24.0 * 3600
    let oldHistory = [point(stale + 7 * 3600, 900), point(stale + 1800, 90), point(stale + 600, 70), point(stale, 30)]
    var histories: [SourceMode: SpeedSummary] = [
        .claude: summary(live: 9999, history: many),
        .codex: summary(last: 30, history: [point(60, 30), point(30, 30)]),
        .opencode: summary(live: nil, last: 30, history: [point(60, 30)]),
        .hermes: summary(active: false, last: 30, history: oldHistory),
        .cursor: summary(active: false, history: [point(0, 50)])
    ]
    panel.update(histories)
    precondition(panel.chart.series.map(\.source) == [.claude, .codex, .opencode, .hermes, .cursor])
    precondition(panel.chart.series[3].samples == Array(oldHistory.suffix(3)), "An idle source keeps its own recent history")
    precondition(panel.chart.series.map(\.active) == [true, true, true, false, false])
    let bounds = panel.chart.bounds
    func plotted(_ series: [CallHistoryView.Series]) -> [[NSPoint]] {
        CallHistoryView.project(series, in: bounds).map { $0.flatMap { $0 } }
    }
    let points = plotted(panel.chart.series)
    precondition(points.map(\.count) == [60, 2, 1, 3, 1])
    precondition(points[0][60 - 12].x == points[1][0].x && points[1][0] == points[2][0], "Same time means same X even across sources")
    precondition(points[0][30 - 16].y == points[1][0].y && points[1][0].y == points[3][2].y,
        "Active and idle speeds share one scale")
    precondition(points[2][0].x < points[1][1].x && points[1][1].x < points[0][59].x,
        "Each series ends at its own last observation")
    precondition(panel.hoverText.isEmpty)
    let visible = CallHistoryView.visibleReadings(panel.chart.series, in: bounds)
    let latestVisible = visible[0].last!.last!
    panel.chart.track(at: latestVisible.position)
    let hoverFormatter = ChartReadoutFormatter(locale: Locale(identifier: L10n.language))
    precondition(panel.chart.hoveredReading?.source == .claude &&
        panel.chart.hoveredReading?.sample == many.last &&
        panel.hoverText == L10n.text("%@ · %@ · %@ tok/s", SourceMode.claude.label,
            hoverFormatter.timestamp(latestVisible.sample.completedAt), hoverFormatter.speed(75)),
        "Hover must report the real sample rather than an interpolated speed")
    panel.chart.track(at: visible[3][0][0].position)
    precondition(panel.chart.hoveredReading?.source == .hermes &&
        panel.chart.hoveredReading?.sample == oldHistory[1],
        "An idle reading shows its own recorded timestamp")
    panel.chart.track(at: NSPoint(x: -1, y: -1))
    precondition(panel.hoverText.isEmpty && panel.chart.hoveredReading == nil)

    // Hovering a legend card highlights its trace and shows summary text in readout.
    panel.cards[0].onHoverChange?(.claude, true)
    precondition(panel.chart.highlightedSource == .claude && !panel.hoverText.isEmpty)
    panel.cards[0].onHoverChange?(.claude, false)
    precondition(panel.chart.highlightedSource == nil && panel.hoverText.isEmpty)

    let activeOnly = plotted(panel.chart.series.filter(\.active))
    precondition(zip(points.prefix(3), activeOnly).allSatisfy { mixed, only in mixed.map(\.x) == only.map(\.x) },
        "Neither older nor newer idle data may change the active time scale")
    precondition(abs((points[3][1].x - points[3][0].x) / (points[3][2].x - points[3][1].x) - 2) < 0.001 &&
        points[4][0].x == bounds.midX, "Idle samples preserve relative timing, including a centered singleton")
    let strokeSafe = bounds.insetBy(dx: 2, dy: 2)
    precondition(points.flatMap { $0 }.allSatisfy { strokeSafe.contains($0) })
    func project(_ samples: [CallHistoryPoint]) -> [[NSPoint]] {
        CallHistoryView.project([.init(source: .cursor, active: false, samples: samples)], in: bounds)[0]
    }
    let flat = project([point(100, 3000), point(0, 3000)])
    precondition(flat[0].allSatisfy { $0.y == bounds.midY })
    let crowded = [point(300, 40), point(159, 45), point(158, 5000), point(157, 55),
        point(157, 50), point(0, 60)]
    let sparse = CallHistoryView.visibleReadings([.init(source: .claude, active: true, samples: crowded)], in: bounds)[0][0]
    precondition(sparse.map(\.sample) == [crowded[0], crowded[4], crowded[5]],
        "Dense samples use a real representative point, including for duplicate timestamps")
    precondition(sparse[1].position.y == bounds.midY, "Unshown peaks must not compress the visible speed scale")
    let single = project([point(3600 * 24 * 400, Double.greatestFiniteMagnitude)])
    precondition(single == [[NSPoint(x: bounds.midX, y: bounds.midY)]], "An old singleton is not replaced or stretched to the present")
    let high = project([point(220, 100), point(200, 3000), point(0, 5000)])[0]
    precondition(high[0].y < high[1].y && high[1].y < high[2].y, "High speeds must not clip or plateau")
    let spike = point(60, 5000)
    let clean = [point(120, 40), point(0, 50)]
    let spikedHistory = [clean[0], spike, clean[1]]
    let spikedPanel = SpeedPanelView(sources: [.claude])
    spikedPanel.update([.claude: summary(history: spikedHistory)])
    precondition(spikedPanel.cards[0].summary?.history == spikedHistory &&
        spikedPanel.chart.series[0].samples == clean &&
        plotted(spikedPanel.chart.series)[0] == project(clean).flatMap { $0 },
        "An isolated spike must not distort the chart or mutate the original history")
    for legitimate in [[point(120, 40), spike, point(30, 4800), point(0, 50)],
                       [clean[0], spike], [point(2400, 40), spike, clean[1]],
                       [clean[0], point(60, 125), clean[1]]] {
        precondition(CallHistoryView.withoutIsolatedSpikes(legitimate) == legitimate)
    }
    precondition(abs((high[2].x - high[1].x) / (high[1].x - high[0].x) - 10) < 0.001, "Time gaps must scale linearly")
    let spaced = project([point(4000, 50), point(3900, 60), point(2600, 55), point(1210, 90), point(10, 100), point(10, 120)])
    precondition(spaced.map(\.count) == [2, 1, 3] && spaced[2][1].x == spaced[2][2].x)
    let path = CallHistoryView.linePath(spaced)
    let cubicCurve: NSBezierPath.ElementType
    if #available(macOS 14.0, *) { cubicCurve = .cubicCurveTo } else { cubicCurve = .curveTo }
    precondition(path.elementCount == 5 && path.element(at: 1, associatedPoints: nil) == cubicCurve &&
        path.element(at: 2, associatedPoints: nil) == .moveTo &&
        path.element(at: 4, associatedPoints: nil) == .lineTo,
        "Distinct timestamps produce curves, gaps break the path, and duplicate timestamps stay vertical")
    let uneven = [NSPoint(x: 0, y: 0), NSPoint(x: 1, y: 200),
                  NSPoint(x: 180, y: 201), NSPoint(x: 182, y: 0)]
    let smooth = CallHistoryView.linePath([uneven])
    for (index, end) in uneven.dropFirst().enumerated() {
        let start = uneven[index]
        var controls = [NSPoint](repeating: .zero, count: 3)
        let kind = controls.withUnsafeMutableBufferPointer {
            smooth.element(at: index + 1, associatedPoints: $0.baseAddress)
        }
        precondition(kind == cubicCurve && controls[2] == end)
        precondition(controls.allSatisfy {
            (start.x...end.x).contains($0.x) &&
            (min(start.y, end.y)...max(start.y, end.y)).contains($0.y)
        }, "Smoothing must not overshoot even with uneven timestamps")
    }
    let limited = SpeedPanelView(sources: [.codex])
    limited.update(histories)
    precondition(limited.chart.series.map(\.source) == [.codex], "Hidden tools must not affect the chart")
    let calls = [point(10, 6), point(0, 12)]
    limited.update([.codex: summary(live: 241, history: calls)])
    precondition(limited.cards[0].summary?.value == "241" && limited.chart.series[0].samples == calls,
        "Changing the live number must not change the completed-call curve")
    let activeTrace = CallHistoryView.Series(source: .claude, active: true, samples: [])
    let idleTrace = CallHistoryView.Series(source: .codex, active: false, samples: [])
    precondition(activeTrace.strokeWidth == 3.4 && idleTrace.strokeWidth == 2.6)
    for (appearance, white) in [(NSAppearance.Name.darkAqua, CGFloat(1)), (.aqua, CGFloat(0))] {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            for active in [true, false] {
                let color = PanelStyle.color(active: active).usingColorSpace(.sRGB)!
                precondition(color.redComponent == white && color.greenComponent == white && color.blueComponent == white)
                precondition(active ? color.alphaComponent == 1 : (0.4..<0.9).contains(color.alphaComponent))
            }
            let activeInk = activeTrace.ink.usingColorSpace(.sRGB)!
            precondition(activeInk.alphaComponent == 1 && activeInk != PanelStyle.color(active: true).usingColorSpace(.sRGB)!)
            let idleInk = idleTrace.ink.usingColorSpace(.sRGB)!
            precondition(idleInk.redComponent == white && idleInk.alphaComponent < 0.3)
        }
    }
    let plotBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: plotBitmap)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(bounds)
    panel.chart.draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    precondition(plotBitmap.colorAt(x: 20, y: 20)?.alphaComponent == 0 &&
        plotBitmap.colorAt(x: Int(latestVisible.position.x), y: Int(bounds.height - latestVisible.position.y))?.alphaComponent ?? 0 > 0,
        "The chart must paint the data but not the background")
    let singleTrace = CallHistoryView(frame: bounds)
    singleTrace.update([.init(source: .claude, active: true, samples: [point(0, 50)])])
    singleTrace.track(at: NSPoint(x: bounds.midX, y: bounds.midY))
    precondition(singleTrace.hoveredReading != nil, "Hover works on single-point series")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(bounds)
    singleTrace.draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    precondition(plotBitmap.colorAt(x: Int(bounds.midX), y: Int(bounds.height - bounds.midY))?.alphaComponent ?? 0 > 0,
        "Single-point series must draw a visible dot")
    histories[.hermes] = summary(active: true, last: 30, history: oldHistory)
    panel.update(histories)
    precondition(!panel.chart.series.contains { $0.source == .hermes }, "An active series outside the active window must not be reanchored")
    histories[.hermes] = summary(active: false, last: 30, history: oldHistory)
    let idleCalls = histories.mapValues { summary(active: false, last: $0.last, history: $0.history) }
    panel.update(idleCalls)
    let idlePoints = plotted(panel.chart.series)
    precondition(panel.chart.series.count == 5 && panel.chart.series.allSatisfy { !$0.active } &&
        idlePoints[3] == points[3] && idlePoints[2][0].x == bounds.midX,
        "All-idle mode keeps each history, and switching state moves observations to their own timeline")
    var idleWithWaiting = idleCalls
    idleWithWaiting[.antigravity] = summary(active: true, live: 250, history: [])
    panel.update(idleWithWaiting)
    precondition(plotted(panel.chart.series) == idlePoints, "An active source without completed calls must not suppress or reshape idle history")
    limited.update([.codex: summary(history: invalid)])
    precondition(limited.chart.series.isEmpty && CallHistoryView.project([], in: bounds).isEmpty)

    // Classic list multi-session indentation: expand only when >= 2 concurrent sessions exist.
    let singleSession = [SessionSummary(id: "s1", title: "Only task", active: true, live: 70, last: 50, activityAt: now, inFlightStart: now.addingTimeInterval(-10))]
    let multiSessions = [
        SessionSummary(id: "s1", title: "Fix payment retry", active: true, live: 88, last: 70, activityAt: now.addingTimeInterval(-2), inFlightStart: now.addingTimeInterval(-12)),
        SessionSummary(id: "s2", title: "Refactor SQLite cache", active: true, live: nil, last: nil, activityAt: now.addingTimeInterval(-5), inFlightStart: now.addingTimeInterval(-9)),
        SessionSummary(id: "s3", title: "Write release notes", active: false, live: nil, last: 42, activityAt: now.addingTimeInterval(-60), inFlightStart: nil),
        SessionSummary(id: "s-old", title: "Stale session", active: false, live: nil, last: 20, activityAt: now.addingTimeInterval(-600), inFlightStart: nil)
    ]
    let classicPanel = SpeedPanelView(sources: [.claude, .codex, .opencode], layout: .classic)
    let baselineHeight = classicPanel.frame.height
    let singleSummary = SpeedSummary(name: "Codex", active: true, live: 70, last: 50, completedAt: now, history: [], model: "gpt", measurement: "test", sessions: singleSession)
    let multiSummary = SpeedSummary(name: "Codex", active: true, live: 88, last: 70, completedAt: now, history: [], model: "gpt", measurement: "test", sessions: multiSessions)
    let idleSummary = SpeedSummary(name: "Idle", active: false, live: nil, last: 30, completedAt: now, history: [], model: "m", measurement: "test")
    classicPanel.update([.claude: idleSummary, .codex: singleSummary, .opencode: idleSummary], now: now)
    precondition(classicPanel.cards[1].sessionRows.isEmpty && classicPanel.frame.height == baselineHeight,
        "A single session must not expand sub-rows")
    classicPanel.update([.claude: idleSummary, .codex: multiSummary, .opencode: idleSummary], now: now)
    let codexCard = classicPanel.cards[1]
    precondition(codexCard.sessionRows.count == 3, "Expected 3 active/recent sub-rows, ignoring stale session")
    precondition(codexCard.sessionRows.map { $0.titleLabel.stringValue } == ["Fix payment retry", "Refactor SQLite cache", "Write release notes"])
    precondition(codexCard.sessionRows.map { $0.speedLabel.stringValue } == ["88", L10n.text("%d s", 9), "42"])
    precondition(codexCard.sessionRows.allSatisfy { $0.titleLabel.frame.minX > ClassicSessionRowView.indentX })
    let expectedGrowth = 3 * ClassicSessionRowView.height + SummaryMenuView.sessionsBottomPadding
    precondition(codexCard.frame.height == SpeedPanelView.legendHeight + expectedGrowth)
    precondition(classicPanel.frame.height == baselineHeight + expectedGrowth)
    precondition(classicPanel.cards[0].frame.minY == codexCard.frame.maxY && codexCard.frame.minY == classicPanel.cards[2].frame.maxY,
        "Expanded card must shift adjacent classic rows cleanly without overlap")
    for card in classicPanel.cards {
        let logo = card.subviews.compactMap { $0 as? NSImageView }.first!
        let name = card.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == card.source.label }!
        precondition(abs(logo.frame.midY - name.frame.midY) <= 0.5,
            "Classic row logo and name must be vertically centered")
    }
    // Chart layout never renders session sub-rows.
    let chartMulti = SpeedPanelView(sources: [.codex], layout: .chart)
    chartMulti.update([.codex: multiSummary], now: now)
    precondition(chartMulti.cards[0].sessionRows.isEmpty)
    print("panel tests: passed (active time alignment, independent idle history, shared speeds, distinct colors, single dot, Y scale, hover, gaps and classic multi-session rows)")

    guard let directory = previewDirectory else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "PanelPreview", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PanelPreview", code: 2) }
        let path = (directory as NSString).appendingPathComponent(name)
        try png.write(to: URL(fileURLWithPath: path))
        print("preview: \(path)")
    }
    for dark in [true, false] {
        let height = SpeedPanelView.height + PanelFooterView.height + 12
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelStyle.width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.96, alpha: 1).cgColor
        let panel = SpeedPanelView(sources: ToolOrder.popular)
        panel.frame.origin.y = PanelFooterView.height + 6
        root.addSubview(panel)
        let examples: [(SourceMode, Bool, Double?, [(TimeInterval, Double)])] = [
            (.claude, true, 113, [(68, 65), (64, 79), (62, 74), (35, 91), (31, 109), (29, 94),
                (24, 121), (22, 105), (17, 124), (14, 118), (11, 130), (8, 113), (6, 116), (3, 101), (1, 99)]),
            (.codex, true, 46.1, [(56, 22), (52, 25), (48, 23), (43, 40), (41, 32), (27, 52), (23, 36),
                (20, 42), (17, 35), (14, 45), (10, 32)]),
            (.opencode, false, nil, [(63, 9), (58, 14), (51, 11), (42, 15), (37, 13), (31, 18), (25, 16)]),
            (.antigravity, true, 56, [(53, 50), (46, 65), (42, 56), (36, 58), (32, 54), (26, 64), (21, 58), (16, 71), (10, 55), (4, 60)]),
            (.hermes, false, nil, [(1507, 34), (1498, 41), (1489, 34), (1484, 42), (1477, 36)]),
            (.cursor, false, nil, [(3180, 8.4)])
        ]
        let sampleSummaries = Dictionary(uniqueKeysWithValues: examples.map { entry -> (SourceMode, SpeedSummary) in
            let (source, active, live, readings) = entry
            let history = readings.map { point($0.0 * 60, $0.1) }
            let extraSessions: [SessionSummary] = source == .codex ? [
                SessionSummary(id: "c1", title: "多会话展示与 CLI 数据识别", active: true, live: 58, last: 49, activityAt: now.addingTimeInterval(-3), inFlightStart: now.addingTimeInterval(-18)),
                SessionSummary(id: "c2", title: "Optimize SQLite WAL cache", active: true, live: 41, last: 38, activityAt: now.addingTimeInterval(-12), inFlightStart: now.addingTimeInterval(-25)),
                SessionSummary(id: "c3", title: "Release checklist", active: false, live: nil, last: 32, activityAt: now.addingTimeInterval(-90), inFlightStart: nil)
            ] : []
            return (source, SpeedSummary(name: source.label, active: active, live: live, last: history.last?.speed,
                completedAt: history.last?.completedAt, history: history, model: "test", measurement: "test", sessions: extraSessions))
        })
        panel.update(sampleSummaries, pinnedSource: .claude)
        let footer = PanelFooterView(
            settings: NSMenuItem(title: L10n.text("Settings") + "…", action: nil, keyEquivalent: ","),
            quit: NSMenuItem(title: L10n.text("Quit"), action: nil, keyEquivalent: "q"))
        footer.frame.origin.y = 6
        root.addSubview(footer)
        try capture(root, name: dark ? "panel-dark.png" : "panel-light.png")
        panel.chart.track(at: CallHistoryView.visibleReadings(panel.chart.series, in: panel.chart.bounds).first?.last?.last?.position)
        try capture(root, name: dark ? "panel-hover-dark.png" : "panel-hover-light.png")
        panel.chart.track(at: nil)
        let allIdle = examples.map { source, _, _, readings in
            let history = readings.map { point($0.0 * 60, $0.1) }
            return (source, SpeedSummary(name: source.label, active: false, live: nil, last: history.last?.speed,
                completedAt: history.last?.completedAt, history: history, model: "test", measurement: "test"))
        }
        panel.update(Dictionary(uniqueKeysWithValues: allIdle))
        try capture(root, name: dark ? "panel-idle-dark.png" : "panel-idle-light.png")

        let classicPreview = SpeedPanelView(sources: ToolOrder.popular, layout: .classic)
        classicPreview.update(sampleSummaries, pinnedSource: .claude, now: now)
        let classicFooterHeight = PanelFooterView.height(for: .classic)
        let classicHeight = classicPreview.frame.height + classicFooterHeight + 12
        let classicWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelStyle.width, height: classicHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        classicWindow.appearance = window.appearance
        let classicRoot = classicWindow.contentView!
        classicRoot.wantsLayer = true
        classicRoot.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.96, alpha: 1).cgColor
        classicPreview.frame.origin.y = classicFooterHeight + 6
        classicRoot.addSubview(classicPreview)
        let classicFooter = PanelFooterView(
            settings: NSMenuItem(title: L10n.text("Settings") + "…", action: nil, keyEquivalent: ","),
            quit: NSMenuItem(title: L10n.text("Quit"), action: nil, keyEquivalent: "q"),
            layout: .classic)
        classicFooter.frame.origin.y = 6
        classicRoot.addSubview(classicFooter)
        try capture(classicRoot, name: dark ? "panel-classic-dark.png" : "panel-classic-light.png")

        let settings = SettingsWindowController()
        settings.window?.appearance = window.appearance
        settings.update(SettingsState(
            sources: ToolOrder.popular,
            hiddenSources: [.cursor],
            source: .auto,
            display: .speedAndUnit,
            layout: .chart,
            launchAtLogin: true,
            launchAtLoginAvailable: true,
            cursorInstalled: true,
            cursorHookStatus: .installed,
            hermesInstalled: true,
            hermesPluginStatus: .installed,
            versionText: L10n.text("Version %@", "0.1.0")
        ))
        try capture(settings.window!.contentView!.superview!, name: dark ? "settings-dark.png" : "settings-light.png")
    }
}

func testPresentationPreferences() {
    for (preferences, expected) in [
        (["en-GB"], "en"), (["zh-CN"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
        (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["zh-Hans-TW"], "zh-Hans"),
        (["ja-JP"], "ja"), (["ko-KR"], "ko"), (["de-DE"], "de"),
        (["fr-CA"], "fr"), (["es-MX"], "es"), (["it-IT"], "en"),
        (["it-IT", "de-DE"], "de"), ([], "en")
    ] {
        precondition(L10n.resolve(preferences) == expected)
    }
    let english = L10n.table("en")
    precondition(!english.isEmpty)
    let placeholders = try! NSRegularExpression(pattern: "%[@d]")
    func formats(_ text: String) -> [String] {
        placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
        }
    }
    for language in L10n.languages {
        let table = L10n.table(language)
        precondition(Set(table.keys) == Set(english.keys), "Incomplete localization: \(language)")
        for (key, value) in table {
            precondition(!value.isEmpty && formats(key) == formats(value), "Invalid translation: \(language) \(key)")
        }
        let locale = Locale(identifier: language)
        let formatter = ChartReadoutFormatter(locale: locale)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 37, second: 51))!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        let minuteTime = formatter.timestamp(date, now: date)
        let earlierTime = formatter.timestamp(date, now: tomorrow)
        precondition(minuteTime.contains("37") && !minuteTime.contains("51") &&
            earlierTime != minuteTime && !earlierTime.contains("51"))
        precondition(formatter.speed(7.5) == "7\(locale.decimalSeparator ?? ".")5")
    }
    precondition(L10n.text("Missing translation falls back to English") == "Missing translation falls back to English")
    print("localization tests: passed (8 languages, matching/fallback/completeness/format arguments); selected=\(L10n.language)")

    precondition(ToolOrder.normalized([]) == ToolOrder.popular)
    precondition(ToolOrder.normalized(["auto", "unknown", "t3code", "opencode", "opencode"]) == [.opencode, .claude, .codex, .antigravity, .hermes, .cursor])
    precondition(ToolOrder.moving(.claude, to: -1, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.antigravity, to: ToolOrder.popular.count, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.auto, to: 0, in: ToolOrder.popular) == ToolOrder.popular)
    precondition(ToolOrder.moving(.claude, to: 3, in: ToolOrder.popular) == [.codex, .opencode, .antigravity, .claude, .hermes, .cursor])
    precondition(ToolOrder.moving(.antigravity, to: 0, in: ToolOrder.popular) == [.antigravity, .claude, .codex, .opencode, .hermes, .cursor])
    let frames = (0..<4).map { NSRect(x: $0 * 56, y: 0, width: 56, height: 72) }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 4, y: 36), frames: frames, from: 3) == .init(index: 0, slot: 0))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 220, y: 36), frames: frames, from: 0) == .init(index: 3, slot: 4))
    precondition(MenuCardReorder.destination(at: NSPoint(x: 164, y: 36), frames: frames, from: 0) == .init(index: 2, slot: 3))
    for point in [NSPoint(x: -1, y: 36), NSPoint(x: 225, y: 36), NSPoint(x: 100, y: -1), NSPoint(x: 100, y: 73)] {
        precondition(MenuCardReorder.destination(at: point, frames: frames, from: 0) == nil)
    }
    precondition(MenuCardReorder.destination(at: NSPoint(x: 36, y: 36), frames: frames, from: 0) == nil)
    precondition(MenuCardReorder.destination(at: .zero, frames: [], from: 0) == nil)
    precondition(MenuCardReorder.destination(at: NSPoint(x: 36, y: 36), frames: [frames[0]], from: 0) == nil)
    for active in [false, true] {
        for display in StatusDisplay.allCases {
            let hidden = !active || display == .iconOnly
            precondition(display.usesLightning(active: active) == hidden)
            precondition(display.title(active: active, speed: 46.1, elapsed: 8) == (hidden ? "" : display == .speedAndUnit ? "46 tok/s" : "46"))
            precondition(display.title(active: active, speed: nil, elapsed: 8) == (hidden ? "" : L10n.text("%d s", 8)))
        }
    }
    let now = Date()
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, true, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.opencode, false, now)]) == .opencode)
    precondition(AppDelegate.preferredSource(mode: .claude, activity: [(.codex, true, now)]) == .claude)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.codex, false, now.addingTimeInterval(-30)), (.hermes, false, now)]) == .hermes)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.cursor, false, now), (.codex, true, now.addingTimeInterval(-30))]) == .codex)
    precondition(AppDelegate.preferredSource(mode: .auto, activity: [(.cursor, false, now), (.codex, false, now.addingTimeInterval(-30))]) == .cursor)

    print("presentation tests: passed (ordering/status modes/active-source priority)")

    let suite = "io.github.thinkofuture.tokspeed.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var installed = Set(ToolOrder.popular)
    let delegate = AppDelegate(defaults: defaults, detectInstalledTools: { installed })
    withExtendedLifetime(delegate) {
        testMenuPreferences(delegate: delegate, defaults: defaults)
        testInstalledVisibility(delegate: delegate, defaults: defaults) { installed = $0 }
    }
}

func testInstalledTools() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tokspeed-installs-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func write(_ relative: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture, never executed".utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    func detect(path: String = "", app: URL? = nil) -> Set<SourceMode> {
        InstalledTools.detect(environment: ["PATH": path], home: root.path,
            systemBinDirectories: [], applicationDirectories: [root.appendingPathComponent("Applications").path],
            applicationURL: { _ in app })
    }
    try write(".codex/sessions/rollout-old.jsonl")
    try write(".claude/projects/old.jsonl")
    try write(".local/share/opencode/opencode.db")
    try write(".gemini/antigravity/conversation_summaries.db")
    try write(".hermes/logs/agent.log")
    try write("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    try write(".t3/userdata/statev2.sqlite")
    precondition(detect().isEmpty, "Leftover data is not an installation")
    try write(".local/bin/codex", executable: true)
    try write(".opencode/bin/opencode", executable: true)
    try write(".nvm/versions/node/v22/bin/claude", executable: true)
    try write("custom/bin/antigravity")
    let path = root.appendingPathComponent("custom/bin").path
    precondition(detect(path: path) == [.codex, .opencode, .claude], "A non-executable file is not a CLI")
    try write(".local/bin/hermes", executable: true)
    try write(".local/bin/cursor", executable: true)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("custom/bin/antigravity").path)
    precondition(detect(path: path) == Set(ToolOrder.popular))
    try fm.removeItem(at: root.appendingPathComponent(".local/bin/cursor"))
    try write("Applications/Cursor.app/Contents/MacOS/Cursor", executable: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Cursor",
        "CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Applications/Cursor.app/Contents/Info.plist"))
    precondition(detect(path: path).contains(.cursor), "Cursor desktop-only installations must be visible")
    let app = root.appendingPathComponent("Applications/Antigravity.app")
    try write("Applications/Antigravity.app/Contents/MacOS/Antigravity", executable: true)
    let info: [String: String] = ["CFBundleExecutable": "Antigravity", "CFBundleIdentifier": "com.google.antigravity", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    precondition(detect() == Set(ToolOrder.popular), "Desktop-only installs must be visible")
    let moved = root.appendingPathComponent("Elsewhere/Antigravity.app")
    try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: app, to: moved)
    precondition(!detect().contains(.antigravity))
    precondition(detect(app: moved).contains(.antigravity), "Launch Services can locate nonstandard app installs")
    let trashed = root.appendingPathComponent(".Trash/Antigravity.app")
    try fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: moved, to: trashed)
    precondition(!detect(app: trashed).contains(.antigravity))
    try write(".t3/userdata/providers/antigravity/abc123/antigravity-acp/bin/agentapi", executable: true)
    precondition(detect().contains(.antigravity), "T3 Code managed Antigravity ACP binary must be detected as Antigravity")
    try fm.removeItem(at: root.appendingPathComponent(".t3/userdata/providers/antigravity/abc123/antigravity-acp/bin/agentapi"))
    precondition(!detect().contains(.antigravity))
    try write(".local/bin/agy", executable: true)
    precondition(detect().contains(.antigravity), "Finder-launched TokSpeed must detect an agy CLI-only install")
    print("installation detection tests: passed (CLI/PATH/Finder/NVM/desktop/T3 ACP/Launch Services/trash/stale logs)")
}
