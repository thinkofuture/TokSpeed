import AppKit
import Foundation
import TokSpeedHookCore

// Cursor launches this executable directly as a hook when legacy config points
// to TokSpeed. Handle that before AppKit starts.
if CursorHook.runIfRequested() { exit(0) }
if let exitCode = CLI.runIfRequested(arguments: CommandLine.arguments) { exit(exitCode) }

let args = CommandLine.arguments
let selftest = args.contains("--selftest")
if !selftest && !SingleInstanceGuard.ensureSingleInstance() {
    exit(0)
}

if let idx = args.firstIndex(of: "--source"), idx + 1 < args.count, let m = SourceMode(rawValue: args[idx + 1]) {
    UserDefaults.standard.set(m.rawValue, forKey: "sourceMode")
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.selftest = selftest
app.delegate = delegate
app.run()
