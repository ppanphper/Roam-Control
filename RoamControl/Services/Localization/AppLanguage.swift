import Foundation

/// Presentation only: persisted language codes and model data remain unchanged.
struct AppLanguage: Equatable, Sendable {
    static let supportedCodes = ["system", "en", "he", "ar", "zh-Hans", "zh-Hant", "ja", "vi", "fr", "de", "es"]

    let code: String
    let locale: Locale

    init(preference: String, preferredLanguages: [String] = Locale.preferredLanguages) {
        if preference != "system", Self.supportedCodes.contains(preference) {
            code = preference
            locale = Locale(identifier: preference)
        } else if let match = preferredLanguages.lazy.compactMap({ tag in
            Self.supportedCode(for: tag).map { ($0, tag) }
        }).first {
            (code, locale) = (match.0, Locale(identifier: match.1))
        } else {
            (code, locale) = ("en", Locale(identifier: "en"))
        }
    }

    var isRightToLeft: Bool { code == "ar" || code == "he" }

    private static func supportedCode(for tag: String) -> String? {
        let language = Locale.Language(identifier: tag.replacingOccurrences(of: "_", with: "-"))
        guard let code = language.languageCode?.identifier.lowercased() else { return nil }
        if code == "zh" {
            if let script = language.script?.identifier.lowercased() {
                if script == "hant" { return "zh-Hant" }
                if script == "hans" { return "zh-Hans" }
            }
            let traditionalRegions = ["TW", "HK", "MO"]
            return traditionalRegions.contains(language.region?.identifier.uppercased() ?? "") ? "zh-Hant" : "zh-Hans"
        }
        let normalized = code == "iw" ? "he" : code
        return supportedCodes.contains(normalized) ? normalized : nil
    }
}

struct AppLocalization: Sendable {
    let language: AppLanguage

    var locale: Locale { language.locale }

    /// Translate app messages at presentation time. Unknown strings (e.g. OS errors) pass through.
    func text(_ key: String) -> String {
        // PairingError travels through the existing UI states as its rendered English description.
        // Match only the complete app-owned sentence with a canonical OSStatus argument.
        let prefix = "The pairing record could not be stored securely (Keychain error "
        let suffix = ")."
        if key.hasPrefix(prefix), key.hasSuffix(suffix) {
            let code = key.dropFirst(prefix.count).dropLast(suffix.count)
            if let status = Int32(code), String(status) == code {
                return format("The pairing record could not be stored securely (Keychain error %@).", technical(String(status)))
            }
        }
        return localizedTemplate(key)
    }

    private func localizedTemplate(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        let english = Self.bundles["en"]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return Self.bundles[language.code]?.localizedString(forKey: key, value: english, table: nil) ?? english
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localizedTemplate(key), locale: locale, arguments: arguments)
    }

    /// Unicode isolates keep technical tokens in order inside RTL paragraphs and labeled rows.
    func technical(_ value: String) -> String {
        guard language.isRightToLeft, !value.isEmpty else { return value }
        return "\u{2066}\(value)\u{2069}"
    }

    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.supportedCodes.compactMap { code in
            guard let url = Bundle.main.url(forResource: code, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (code, bundle)
        }
    )
}
