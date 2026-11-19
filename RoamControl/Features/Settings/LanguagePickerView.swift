import SwiftUI

struct LanguagePickerView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section {
                Button { select("system") } label: {
                    row(Text("System Default"), code: "system")
                }
                ForEach(AppLanguage.supportedCodes.filter { $0 != "system" }, id: \.self) { code in
                    Button { select(code) } label: {
                        row(Text(verbatim: Self.nativeName(for: code)), code: code)
                    }
                }
            } footer: {
                Text("Choose the language used by this app.")
            }
        }
        .background { LocalizedNavigationDirection(direction: l10n.layoutDirection).frame(width: 0, height: 0) }
        .environment(\.layoutDirection, l10n.layoutDirection)
        .navigationTitle(Text(verbatim: l10n.text("Language")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: Text, code: String) -> some View {
        let selected = appModel.featurePreferences.languageCode == code
        return HStack {
            title
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func select(_ code: String) {
        appModel.featurePreferences.languageCode = code
    }

    static func nativeName(for code: String) -> String {
        switch code {
        case "en": "English"
        case "he": "עברית"
        case "ar": "العربية"
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁體中文"
        case "ja": "日本語"
        case "vi": "Tiếng Việt"
        case "fr": "Français"
        case "de": "Deutsch"
        case "es": "Español"
        default: code
        }
    }
}
