// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case russian = "ru", english = "en"
    public var title: String { self == .russian ? "Русский" : "English" }
    public var locale: Locale { Locale(identifier: self == .russian ? "ru_RU" : "en_US") }
}

/// Russian by default; the saved choice takes effect once at app launch.
public enum JotL10n {
    public static let language = SettingsStore().interfaceLanguage
    public static var locale: Locale { language.locale }
    private static let package: Bundle = {
        // Also support the CLT-built app: its package bundle lives in Resources.
        Bundle.main.url(forResource: "JotCore_JotCore", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
    }()
    private static let bundles: [InterfaceLanguage: Bundle] = Dictionary(uniqueKeysWithValues: InterfaceLanguage.allCases.map { language in
        let bundle = package.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap { Bundle(url: $0) } ?? package
        return (language, bundle)
    })
    public static func text(_ key: String, language: InterfaceLanguage = language) -> String {
        let bundle = bundles[language] ?? package
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    public static func format(_ key: String, _ arguments: String...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
    public static func wordCount(_ count: Int, language: InterfaceLanguage = language) -> String {
        if language == .english { return "\(count) \(count == 1 ? "word" : "words")" }
        let form: String
        if (11...14).contains(count % 100) { form = "слов" }
        else {
            switch count % 10 {
            case 1: form = "слово"
            case 2...4: form = "слова"
            default: form = "слов"
            }
        }
        return "\(count) \(form)"
    }
}
