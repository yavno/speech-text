// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The language the package's words are shown in: the first of the user's languages its
/// String Catalog has, so a language name or a date reads in the same language as the
/// sentence around it — English until the catalog has another.
let uiLocale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")

/// The locale numbers are written in: the app's language, never the Mac's region, so a
/// size, a price and a count on one page agree — "483.3 MB" and "$0.01" in English (as in
/// the US), "483,3 MB" and "$0,01" in Spanish.
let numberLocale = uiLocale.language.languageCode == .english ? Locale(identifier: "en_US") : uiLocale

/// A word or sentence the package hands to the interface, from its String Catalog. The
/// compiler extracts the literal passed here as a key, as it does for `String(localized:)`.
/// A number in it is written the app's way ("1,234" in English), not the Mac's region's.
func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module, locale: uiLocale)
}

/// A language's name in the app's language. In English, the name the catalogue gives
/// (`english`), else Foundation's; in another language, Foundation's for that language.
func languageName(_ code: String, english: String?) -> String {
    let named = uiLocale.localizedString(forLanguageCode: code)
    if uiLocale.language.languageCode == .english { return english ?? named ?? code }
    return named ?? english ?? code
}

/// The language of the app's own windows, when the user has chosen one. It is the system's
/// per-app setting, `AppleLanguages` in the app's own preferences, the key System Settings ›
/// Language & Region › Applications writes too, so the two always agree. Foundation reads it
/// once at launch, so a change takes a restart.
public enum AppLanguage {
    private static let key = SettingsKeys.appLanguage

    /// The languages the app has, as their codes, in the order of their own names.
    public static func choices(localizations: [String]) -> [String] {
        Array(Set(localizations).subtracting(["Base"]))
            .sorted { name(of: $0).compare(name(of: $1), locale: Locale(identifier: "en")) == .orderedAscending }
    }

    public static var available: [String] { choices(localizations: Bundle.main.localizations) }

    /// A language's name in itself: "Español", "Українська". Every language reads its own
    /// name, so someone who cannot read the current one can still find theirs.
    public static func name(of code: String) -> String {
        let own = Locale(identifier: code)
        return own.localizedString(forLanguageCode: code)?.capitalized(with: own) ?? code
    }

    /// The language the windows would show under `choice` (nil follows the system's order).
    public static func effective(choice: String?, localizations: [String], system: [String]) -> String {
        Bundle.preferredLocalizations(from: localizations, forPreferences: choice.map { [$0] } ?? system).first ?? "en"
    }

    /// The language chosen here, or nil to follow the system. Read from the app's own
    /// preferences: `UserDefaults.standard` would also answer with the system's list.
    public static var choice: String? {
        get { storedPreference.flatMap { match($0, in: available) } }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.synchronize()
        }
    }

    /// What the app's preferences hold when no language of the app answers to it: a
    /// language since removed. It is neither a language to offer nor the system's, so a
    /// picker shows it as it is and either can still be chosen over it.
    public static var unavailablePreference: String? {
        storedPreference.flatMap { match($0, in: available) == nil ? $0 : nil }
    }

    /// The app's language for a stored preference ("uk-UA" is "uk"), or nil when it has
    /// none in that language. Foundation alone would answer with the development language.
    static func match(_ preference: String, in localizations: [String]) -> String? {
        guard let found = Bundle.preferredLocalizations(from: localizations, forPreferences: [preference]).first,
              Locale(identifier: found).language.languageCode == Locale(identifier: preference).language.languageCode
        else { return nil }
        return found
    }

    private static var storedPreference: String? {
        guard let domain = Bundle.main.bundleIdentifier,
              let stored = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String] else { return nil }
        return stored.first
    }

    /// The language the windows are showing now.
    public static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Whether `candidate` (nil is the system's) needs a restart to show.
    public static func needsRestart(for candidate: String?) -> Bool {
        effective(choice: candidate, localizations: available, system: systemLanguages) != running
    }

    private static var systemLanguages: [String] {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String] ?? []
    }
}

/// `AppleLocale`, the system's own, as "fr-FR". `Locale.current` takes its language from the
/// app's language, which says what the windows show and nothing about what the user speaks.
func speechLocale(fromSystem appleLocale: String?, fallback: String) -> String {
    (appleLocale?.prefix { $0 != "@" }).map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        .map { $0.replacingOccurrences(of: "_", with: "-") } ?? fallback.replacingOccurrences(of: "_", with: "-")
}
