import Foundation

enum CLI {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        if arguments.contains("--install-hermes-plugin") {
            let force = arguments.contains("--force")
            do {
                let destination = try HermesPluginInstaller.install(force: force)
                print("Hermes plugin files: \(destination.path)")
                print("Enable in the same Hermes profile: hermes plugins enable \(HermesReader.pluginName)")
                print("If Hermes did not reload plugins, start a new process or reload the gateway before collecting data.")
                print("Log: \(HermesReader.logURL(home: HermesReader.home()).path)")
                return 0
            } catch {
                fputs("Hermes plugin: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if arguments.contains("--uninstall-hermes-plugin") {
            do {
                let removed = try HermesPluginInstaller.uninstall()
                print(removed ? "Hermes plugin removed." : "Hermes plugin was not installed.")
                return 0
            } catch {
                fputs("Hermes plugin: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if arguments.contains("--install-cursor-hook") || arguments.contains("--uninstall-cursor-hook") {
            let status = arguments.contains("--uninstall-cursor-hook")
                ? CursorHookInstaller.remove()
                : CursorHookInstaller.install()
            if let error = status.error {
                fputs("Cursor hook: \(error)\n", stderr)
                return 1
            }
            print("Cursor hook \(arguments.contains("--uninstall-cursor-hook") ? "removed" : (status.changed ? "installed" : "already installed")).")
            print("Config: \(status.config)")
            if let backup = status.backup { print("Backup: \(backup)") }
            print("Log:    \(CursorReader.logPath())")
            return 0
        }
        if arguments.contains("--diagnostics") {
            return runDiagnostics()
        }
        if arguments.contains("--once") {
            return runOnce(arguments: arguments)
        }
        return nil
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
        return arguments[idx + 1]
    }

    private static func runDiagnostics() -> Int32 {
        let installed = InstalledTools.detect()
        let now = Date()
        let readers: [SourceMode: any SpeedSourceReader] = [
            .codex: CodexMultiReader(),
            .opencode: OpenCodeReader(),
            .claude: ClaudeReader(),
            .antigravity: AntigravityReader(),
            .hermes: HermesReader(),
            .cursor: CursorReader()
        ]
        print("installed: \(ToolOrder.popular.filter { installed.contains($0) }.map(\.rawValue).joined(separator: ", "))")
        for source in ToolOrder.popular {
            guard let reader = readers[source] else { continue }
            reader.poll(forceScan: true, now: now)
            let snap = reader.snapshot(now: now)
            let tag = installed.contains(source) ? "installed" : "not-installed"
            print("\(source.rawValue) [\(tag)]: \(snap.diagnostic.status)  samples=\(snap.diagnostic.sampleCount)  path=\(snap.diagnostic.path)")
        }
        print("cursor-hook:   \(CursorHookInstaller.status())")
        print("hermes-plugin: \(HermesPluginInstaller.status())")
        return 0
    }

    private static func runOnce(arguments: [String]) -> Int32 {
        let now = Date()
        if let sourceName = value(after: "--source", in: arguments) {
            switch sourceName {
            case "cursor":
                let path = value(after: "--log", in: arguments) ?? CursorReader.logPath()
                let reader = CursorReader(logPath: path)
                reader.poll(now: now)
                reader.onceLines(now: now).forEach { print($0) }
                return reader.hasOnceData ? 0 : 1
            case "hermes":
                let reader = HermesReader()
                reader.poll(now: now)
                reader.onceLines(now: now).forEach { print($0) }
                return 0
            case "opencode":
                let dbPath = value(after: "--db", in: arguments) ?? OpenCodeReader.dbPath
                let reader = OpenCodeReader(dbPath: dbPath)
                reader.poll(now: now)
                reader.onceLines(now: now).forEach { print($0) }
                return reader.hasOnceData ? 0 : 1
            case "antigravity":
                let reader = AntigravityReader()
                reader.poll(now: now)
                reader.onceLines(now: now).forEach { print($0) }
                return reader.hasOnceData ? 0 : 1
            case "claude":
                let reader = ClaudeReader()
                reader.poll(now: now)
                reader.onceLines(now: now).forEach { print($0) }
                return 0
            case "codex":
                if let file = value(after: "--file", in: arguments) {
                    return printRollout(URL(fileURLWithPath: file))
                }
                let reader = CodexMultiReader()
                reader.poll(forceScan: true, now: now)
                guard reader.hasOnceData || !reader.sessionID.isEmpty else {
                    print("no rollout found under \(CodexHome.path)")
                    return 1
                }
                reader.onceLines(now: now).forEach { print($0) }
                return 0
            default:
                break
            }
        }
        if let file = value(after: "--file", in: arguments) {
            return printRollout(URL(fileURLWithPath: file))
        }
        guard let url = CodexHome.newestRollout() else {
            print("no rollout found under \(CodexHome.path)")
            return 1
        }
        return printRollout(url)
    }

    private static func printRollout(_ url: URL) -> Int32 {
        let reader = RolloutReader()
        reader.read(url)
        print("rollout:   \(url.path)")
        print("session:   \(reader.sessionID)")
        print("model:     \(reader.model)")
        print("responses: \(reader.samples.count)")
        if let s = reader.samples.last {
            print("last:      \(Fmt.tps(s.effectiveTPS)) tok/s effective, \(Fmt.tps(s.visibleTPS)) tok/s visible")
            print("last ttft: \(s.ttft.map { Fmt.secs($0) } ?? "-")  elapsed \(Fmt.secs(s.elapsed))  output \(s.output)")
        }
        print("median:    \(Fmt.tps(reader.medianTPS)) tok/s")
        return 0
    }
}
