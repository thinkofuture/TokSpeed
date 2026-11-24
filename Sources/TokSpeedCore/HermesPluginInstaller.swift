import Foundation

enum HermesPluginInstaller {
    enum PluginStatus: Equatable {
        case notInstalled
        case installed
        case outdated
        case conflict(String)
        case missingResources
    }

    private static let files = ["plugin.yaml", "__init__.py"]

    static func status(home: String = HermesReader.home(),
                       resources: URL? = Bundle.main.resourceURL) -> PluginStatus {
        let fm = FileManager.default
        let pluginName = HermesReader.pluginName
        guard let source = bundledSource(resources: resources, fileManager: fm) else {
            return .missingResources
        }
        let destination = URL(fileURLWithPath: home)
            .appendingPathComponent("plugins")
            .appendingPathComponent(pluginName)
        guard fm.fileExists(atPath: destination.path) else {
            return .notInstalled
        }
        if matchesBundled(destination: destination, source: source) {
            return .installed
        }
        if isTokSpeedOwned(destination: destination) {
            return .outdated
        }
        return .conflict(destination.path)
    }

    static func install(home: String = HermesReader.home(),
                        resources: URL? = Bundle.main.resourceURL,
                        force: Bool = false) throws -> URL {
        let fm = FileManager.default
        let pluginName = HermesReader.pluginName
        guard let source = bundledSource(resources: resources, fileManager: fm) else {
            throw InstallError.missingResources
        }
        let plugins = URL(fileURLWithPath: home).appendingPathComponent("plugins")
        let destination = plugins.appendingPathComponent(pluginName)
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            if matchesBundled(destination: destination, source: source) {
                return destination
            }
            guard force, isTokSpeedOwned(destination: destination) else {
                throw InstallError.conflict(destination.path)
            }
            let staging = plugins.appendingPathComponent(".tokspeed-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            for name in files {
                try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
            return destination
        }

        // Stage both files together. Never overwrite a user plugin or config.
        let staging = plugins.appendingPathComponent(".tokspeed-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for name in files {
            try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    @discardableResult
    static func uninstall(home: String = HermesReader.home()) throws -> Bool {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: home)
            .appendingPathComponent("plugins")
            .appendingPathComponent(HermesReader.pluginName)
        guard fm.fileExists(atPath: destination.path) else { return false }
        guard isTokSpeedOwned(destination: destination) else {
            throw InstallError.conflict(destination.path)
        }
        try fm.removeItem(at: destination)
        return true
    }

    private static func bundledSource(resources: URL?, fileManager fm: FileManager) -> URL? {
        var roots = [resources].compactMap { $0 }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        roots.append(development)
        #endif
        for root in roots {
            let source = root.appendingPathComponent("HermesPlugin")
            if files.allSatisfy({ fm.fileExists(atPath: source.appendingPathComponent($0).path) }) {
                return source
            }
        }
        return nil
    }

    private static func matchesBundled(destination: URL, source: URL) -> Bool {
        files.allSatisfy { name in
            guard let existing = try? Data(contentsOf: destination.appendingPathComponent(name)),
                  let bundled = try? Data(contentsOf: source.appendingPathComponent(name)) else { return false }
            return existing == bundled
        }
    }

    private static func isTokSpeedOwned(destination: URL) -> Bool {
        let manifestURL = destination.appendingPathComponent("plugin.yaml")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "name: \(HermesReader.pluginName)" || trimmed == "name: \"\(HermesReader.pluginName)\""
        }
    }

    private enum InstallError: LocalizedError {
        case missingResources
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: return "Run the TokSpeed executable from the built app bundle; Hermes plugin files are missing."
            case .conflict(let path): return "A different plugin already exists at \(path). Nothing was overwritten."
            }
        }
    }
}
