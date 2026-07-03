import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case vietnamese = "vi"

    static let preferenceKey = "settings.general.appLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .simplifiedChinese: return "Chinese (Simplified)"
        case .traditionalChinese: return "Chinese (Traditional)"
        case .vietnamese: return "Vietnamese"
        }
    }

    static var current: AppLanguage {
        if let selectedLanguage = UserDefaults.standard.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: selectedLanguage) {
            return language
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let appDefaults = UserDefaults.standard.persistentDomain(forName: bundleIdentifier),
              let preferredLanguages = appDefaults["AppleLanguages"] as? [String],
              let preferredLanguage = preferredLanguages.first else {
            return .system
        }

        let normalized = preferredLanguage.replacingOccurrences(of: "_", with: "-")
        return allCases.first { $0.rawValue == normalized } ?? .system
    }
}

enum AppLanguagePreferences {
    static func apply(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}
