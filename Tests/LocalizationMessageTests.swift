import Foundation

/// Compile with AppLanguage.swift and place the executable and localized resources in a macOS test bundle.
@main
struct LocalizationMessageTests {
    static func main() {
        let chinese = AppLocalization(language: .init(preference: "zh-Hans"))
        let japanese = AppLocalization(language: .init(preference: "ja"))
        let arabic = AppLocalization(language: .init(preference: "ar"))
        let english = AppLocalization(language: .init(preference: "en"))

        func message(_ status: String) -> String {
            "The pairing record could not be stored securely (Keychain error \(status))."
        }

        precondition(chinese.text(message("-25308")) == "无法安全保存配对记录（钥匙串错误 -25308）。")
        precondition(japanese.text(message("-2147483648")) == "ペアリング記録を安全に保存できませんでした（キーチェーンエラー -2147483648）。")
        precondition(english.text(message("0")) == message("0"))
        precondition(arabic.text(message("-25308")).contains("\u{2066}-25308\u{2069}"))
        precondition(chinese.text("Not paired") == "未配对")
        for nonAppMessage in [message("2147483648"), message("-01"), message("-12%lld"), message("42") + " Extra diagnostics.",
                              "Keychain error -25308", "OS error 42 (%@)", "", "Tokyo Tower"] {
            precondition(chinese.text(nonAppMessage) == nonAppMessage, "Unexpected translation of \(nonAppMessage)")
        }
        print("PASS: 13 localization message checks")
    }
}
