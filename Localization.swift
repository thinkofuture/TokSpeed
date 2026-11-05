import Foundation

enum L10n {
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es"]
    static let language = resolve(Locale.preferredLanguages)

    static func resolve(_ preferences: [String]) -> String {
        for preference in preferences {
            let tag = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = tag.components(separatedBy: "-")[0]
            if base == "zh" {
                let parts = tag.components(separatedBy: "-")
                if parts.contains("hant") { return "zh-Hant" }
                if parts.contains("hans") { return "zh-Hans" }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
            }
            if languages.contains(base) { return base }
        }
        return "en"
    }

    static func table(_ language: String) -> [String: String] {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("\(language).lproj/Localizable.strings")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        for url in [bundled, development].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] {
                return table
            }
        }
        return [:]
    }

    private static let english = table("en")
    private static let localized = table(language)

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized[key] ?? english[key] ?? key,
               locale: Locale(identifier: language), arguments: arguments)
    }
}
