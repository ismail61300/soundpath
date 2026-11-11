import Foundation
import Observation
import SwiftUI

/// Supported UI languages: Turkish, English and the world's most spoken languages.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case en, tr
    case zhHans = "zh-Hans"
    case hi, es, fr, ar, bn
    case ptBR = "pt-BR"
    case ru, ur

    var id: String { rawValue }

    /// Name shown in the picker, always in the language itself.
    var nativeName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .tr: return "Türkçe"
        case .zhHans: return "简体中文"
        case .hi: return "हिन्दी"
        case .es: return "Español"
        case .fr: return "Français"
        case .ar: return "العربية"
        case .bn: return "বাংলা"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        case .ur: return "اردو"
        }
    }
}

/// Resolves localized strings from the `.lproj` bundle of the selected language,
/// allowing the language to change at runtime without relaunching.
@MainActor @Observable
final class Localizer {
    static let shared = Localizer()
    private static let defaultsKey = "appLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            resolve()
        }
    }

    private(set) var bundle: Bundle = .main
    private(set) var resolvedCode: String = "en"

    private init() {
        language = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init) ?? .system
        resolve()
    }

    private func resolve() {
        let code: String
        if language == .system {
            // Bundle.main.preferredLocalizations already matches the user's system languages.
            code = Bundle.main.preferredLocalizations.first ?? "en"
        } else {
            code = language.rawValue
        }
        resolvedCode = code
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    var locale: Locale { Locale(identifier: resolvedCode) }

    var layoutDirection: LayoutDirection {
        Locale.Language(identifier: resolvedCode).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    func string(_ key: String) -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        if value != key { return value }
        // Fall back to English when a translation is missing.
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"), let en = Bundle(path: path) {
            return en.localizedString(forKey: key, value: key, table: nil)
        }
        return key
    }
}

/// Shorthand: `L("key")`, `L("key", arg1, …)` for format strings.
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.shared.string(key)
    guard !args.isEmpty else { return format }
    return String(format: format, locale: Localizer.shared.locale, arguments: args)
}
