import AppKit

enum InstalledTools {
    private static let applications: [SourceMode: (names: [String], id: String)] = [
        .codex: (["Codex"], "com.openai.codex"),
        .opencode: (["OpenCode"], "ai.opencode.desktop"),
        .claude: (["Claude"], "com.anthropic.claudefordesktop"),
        .antigravity: (["Antigravity"], "com.google.antigravity"),
        .cursor: (["Cursor"], "com.todesktop.230313mzl4w4u92"),
        .t3code: (["T3 Code", "T3 Code (Beta)", "T3 Code (Alpha)"], "com.t3tools.t3code")
    ]

    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory(), fileManager: FileManager = .default,
                       systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
                       applicationDirectories: [String]? = nil,
                       applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> Set<SourceMode> {
        // Finder does not inherit shell PATH. Include common CLI installation roots
        // without launching a shell, invoking agents, or treating old logs as installs.
        var directories = (environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        directories += systemBinDirectories
        directories += [".local/bin", ".opencode/bin", ".bun/bin", ".npm-global/bin", ".volta/bin", ".asdf/shims", ".local/share/mise/shims"].map {
            (home as NSString).appendingPathComponent($0)
        }
        for root in [".nvm/versions/node", ".local/share/fnm/node-versions", "Library/Application Support/fnm/node-versions"] {
            let path = (home as NSString).appendingPathComponent(root)
            for version in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
                directories.append((path as NSString).appendingPathComponent(version + (root.contains("fnm") ? "/installation/bin" : "/bin")))
            }
        }
        func executable(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && fileManager.isExecutableFile(atPath: path)
        }
        func installedApp(_ url: URL) -> Bool {
            guard !url.pathComponents.contains(".Trash"),
                  let path = Bundle(url: url)?.executableURL?.path else { return false }
            return executable(path)
        }
        return Set(ToolOrder.popular.filter { source in
            let command = source == .claude ? "claude" : source.rawValue
            if Set(directories).contains(where: { executable(($0 as NSString).appendingPathComponent(command)) }) { return true }
            if source == .antigravity && Set(directories).contains(where: { executable(($0 as NSString).appendingPathComponent("agy")) }) { return true }
            guard let app = applications[source] else { return false }
            if let url = applicationURL(app.id), installedApp(url) { return true }
            return (applicationDirectories ?? ["/Applications", (home as NSString).appendingPathComponent("Applications")]).contains { root in
                app.names.contains { name in
                    installedApp(URL(fileURLWithPath: root).appendingPathComponent("\(name).app"))
                }
            }
        })
    }
}
