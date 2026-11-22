import Foundation

enum HermesPluginInstaller {
    static func install(home: String = HermesReader.home(), resources: URL? = Bundle.main.resourceURL) throws -> URL {
        let fm = FileManager.default
        let pluginName = HermesReader.pluginName
        let files = ["plugin.yaml", "__init__.py"]
        guard let source = resources?.appendingPathComponent("HermesPlugin"),
              files.allSatisfy({ fm.fileExists(atPath: source.appendingPathComponent($0).path) }) else {
            throw InstallError.missingResources
        }
        let plugins = URL(fileURLWithPath: home).appendingPathComponent("plugins")
        let destination = plugins.appendingPathComponent(pluginName)
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            guard files.allSatisfy({ name in
                guard let existing = try? Data(contentsOf: destination.appendingPathComponent(name)),
                      let bundled = try? Data(contentsOf: source.appendingPathComponent(name)) else { return false }
                return existing == bundled
            }) else { throw InstallError.conflict(destination.path) }
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
