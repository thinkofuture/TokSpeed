import AppKit
import XCTest

final class TokSpeedTests: XCTestCase {
    func testJSONLReaders() throws {
        try testRolloutIncrementalRead()
        testISO8601DateParser()
        try testClaudeIncrementalAndErrors()
        try testMultiSessionReaders()
        try testCodexPartitionScan()
    }

    func testSQLiteReaders() throws {
        try testAntigravityReader()
        try testOpenCodeReader()
    }

    func testLocalIntegrations() throws {
        try testHermesReader()
        try testHermesActivity()
        let helper = ProcessInfo.processInfo.environment["TOKSPEED_TEST_CURSOR_HELPER"]
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tokspeed-cursor-hook").path
        try testCursorReader(helper: helper)
        try testInstalledTools()
    }

    @MainActor
    func testAppKitPanel() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        testProviderLogoEnhancedSVG()
        testPresentationPreferences()
        try testPanel(previewDirectory: ProcessInfo.processInfo.environment["TOKSPEED_TEST_PREVIEW_DIRECTORY"])
    }
}
