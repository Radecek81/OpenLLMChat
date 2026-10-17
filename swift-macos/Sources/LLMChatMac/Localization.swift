import Foundation

enum AppLanguage {
    case cs
    case en

    static var current: AppLanguage {
        if let preferred = Locale.preferredLanguages.first?.lowercased(),
           preferred.hasPrefix("cs") {
            return .cs
        }
        return .en
    }
}

enum L10n {
    static func choose(_ cs: String, _ en: String) -> String {
        AppLanguage.current == .cs ? cs : en
    }
}
