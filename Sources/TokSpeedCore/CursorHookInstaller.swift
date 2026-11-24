import Foundation
import TokSpeedHookCore

// Installs only TokSpeed-owned observer entries. Existing hooks, their relative
// order and unknown configuration keys are preserved. The temporary
// `tokspeed-cursor-probe.py` entries from earlier diagnostics are removed so
// only one collector writes measurements.
enum CursorHookInstaller {
    enum HookStatus: Equatable {
        case notInstalled
        case installed
        case outdatedPath
        case error(String)
    }

    struct Status {
        var changed = false
        var backup: String?
        var error: String?
        var config = ""
    }

    static func defaultExecutable(bundle: Bundle = .main, fallback: String? = CommandLine.arguments.first) -> String {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/tokspeed-cursor-hook").path
        if FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        return bundle.executablePath ?? fallback ?? ""
    }

    static func status(executable: String = CursorHookInstaller.defaultExecutable(),
                       home: String = NSHomeDirectory()) -> HookStatus {
        let fm = FileManager.default
        let root = (home as NSString).appendingPathComponent(".cursor")
        let config = (root as NSString).appendingPathComponent("hooks.json")
        if isSymlink(root) || isSymlink(config) {
            return .error("Refusing to follow a symlink at Cursor hooks.json")
        }
        guard fm.fileExists(atPath: config) else { return .notInstalled }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: config)) else {
            return .error("Cursor hook configuration could not be read")
        }
        guard let parsedObject = try? JSONSerialization.jsonObject(with: data),
              let object = parsedObject as? [String: Any] else {
            return .error("Cursor hooks.json is not a JSON object")
        }
        if let version = object["version"], !isOne(version) {
            return .error("Unsupported Cursor hook configuration version")
        }
        guard let hooks = object["hooks"] as? [String: Any] else {
            return object["hooks"] == nil ? .notInstalled : .error("Cursor hooks.json has an invalid hooks object")
        }

        var ownedCount = 0
        var hasLegacyOrUnexpected = false
        var matchedEvents = Set<String>()
        let expectedPrefix = executable.hasPrefix("/") && fm.isExecutableFile(atPath: executable)
            ? "\(shellQuote(executable)) \(CursorHook.marker)"
            : nil

        for (event, value) in hooks {
            guard let entries = value as? [Any] else {
                return .error("Cursor hooks.json has an invalid \(event) list")
            }
            for item in entries {
                guard let entry = item as? [String: Any],
                      let command = entry["command"] as? String,
                      isOwned(command) else { continue }
                ownedCount += 1
                if let expectedPrefix,
                   CursorHook.events.contains(event),
                   command == "\(expectedPrefix) \(event)" {
                    matchedEvents.insert(event)
                } else {
                    hasLegacyOrUnexpected = true
                }
            }
        }
        if ownedCount == 0 { return .notInstalled }
        if !hasLegacyOrUnexpected && matchedEvents == Set(CursorHook.events) && ownedCount == CursorHook.events.count {
            return .installed
        }
        return .outdatedPath
    }

    static func install(executable: String = CursorHookInstaller.defaultExecutable(),
                        home: String = NSHomeDirectory()) -> Status {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            var status = Status()
            status.error = "Cursor hook executable is not an absolute executable path"
            return status
        }
        let command = "\(shellQuote(executable)) \(CursorHook.marker)"
        return configure(home: home, adding: command)
    }

    static func remove(home: String = NSHomeDirectory()) -> Status {
        configure(home: home, adding: nil)
    }

    private static func configure(home: String, adding executableCommand: String?) -> Status {
        let fm = FileManager.default
        let root = (home as NSString).appendingPathComponent(".cursor")
        let config = (root as NSString).appendingPathComponent("hooks.json")
        var status = Status()
        status.config = config
        if isSymlink(root) || isSymlink(config) {
            status.error = "Refusing to replace a symlink; review Cursor hook configuration manually"
            return status
        }
        let original = fm.fileExists(atPath: config) ? try? Data(contentsOf: URL(fileURLWithPath: config)) : nil
        if fm.fileExists(atPath: config), original == nil {
            status.error = "Cursor hook configuration could not be read"
            return status
        }
        if original == nil, executableCommand == nil { return status }

        var object: [String: Any]
        if let original {
            guard let parsedObject = try? JSONSerialization.jsonObject(with: original),
                  let parsed = parsedObject as? [String: Any] else {
                status.error = "Cursor hooks.json is not a JSON object; no changes made"
                return status
            }
            object = parsed
        } else {
            object = ["version": 1, "hooks": [String: Any]()]
        }

        if let version = object["version"], !isOne(version) {
            status.error = "Unsupported Cursor hook configuration version; no changes made"
            return status
        }
        object["version"] = 1
        var hooks: [String: Any]
        if let stored = object["hooks"] {
            guard let dictionary = stored as? [String: Any] else {
                status.error = "Cursor hooks.json has an invalid hooks object; no changes made"
                return status
            }
            hooks = dictionary
        } else {
            hooks = [:]
        }

        for (event, value) in hooks {
            guard let entries = value as? [Any] else {
                status.error = "Cursor hooks.json has an invalid \(event) list; no changes made"
                return status
            }
            hooks[event] = entries.filter { entry in
                guard let entry = entry as? [String: Any], let command = entry["command"] as? String else {
                    return true
                }
                return !isOwned(command)
            }
        }

        if let executableCommand {
            for event in CursorHook.events {
                var entries = hooks[event] as? [Any] ?? []
                entries.insert(["command": "\(executableCommand) \(event)", "timeout": 5], at: 0)
                hooks[event] = entries
            }
        } else {
            for event in CursorHook.events where (hooks[event] as? [Any])?.isEmpty == true {
                hooks.removeValue(forKey: event)
            }
        }
        object["hooks"] = hooks

        guard JSONSerialization.isValidJSONObject(object) else {
            status.error = "Cursor hook configuration is not serializable; no changes made"
            return status
        }
        let after = (try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let original,
           let before = try? JSONSerialization.jsonObject(with: original),
           let beforeData = try? JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]),
           let afterData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           beforeData == afterData {
            return status
        }

        if let original {
            let stamp = String(Int(Date().timeIntervalSince1970))
            var backup = "\(config).tokspeed-backup-\(stamp)"
            if fm.fileExists(atPath: backup) { backup += "-\(UUID().uuidString.prefix(8))" }
            do {
                try original.write(to: URL(fileURLWithPath: backup), options: .withoutOverwriting)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
                status.backup = backup
            } catch {
                status.error = "Could not back up Cursor hooks.json; no changes made"
                return status
            }
        }

        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try atomicWrite(after, to: config)
        } catch {
            status.error = "Could not write Cursor hooks.json; review the file manually"
            return status
        }
        status.changed = true
        if executableCommand != nil { migrateLegacyLog(home: home) }
        return status
    }

    private static func atomicWrite(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let temporary = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".hooks.json.tokspeed-\(UUID().uuidString)")
        try data.write(to: URL(fileURLWithPath: temporary))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
        do {
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try fm.moveItem(atPath: temporary, toPath: path)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? fm.removeItem(atPath: temporary)
            throw error
        }
    }

    private static func isOne(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 1 && number.doubleValue == 1
    }

    private static func isOwned(_ command: String) -> Bool {
        command.contains(CursorHook.marker) || command.contains("tokspeed-cursor-probe.py")
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func shellQuote(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-")
        if !value.isEmpty && value.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func migrateLegacyLog(home: String) {
        let fm = FileManager.default
        let destination = CursorHook.logPath(environment: [:], home: home)
        let legacy = (home as NSString).appendingPathComponent(
            "Library/Application Support/TokSpeed/cursor-hook-probe/events.jsonl")
        guard !fm.fileExists(atPath: destination), fm.fileExists(atPath: legacy),
              let data = try? Data(contentsOf: URL(fileURLWithPath: legacy)) else { return }
        let directory = (destination as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        } catch {
            // Migration is only for continuity; a new turn recreates the log.
        }
    }
}
