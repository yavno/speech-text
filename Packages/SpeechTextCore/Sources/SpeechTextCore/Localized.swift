// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The language the package's words are shown in: the first of the user's languages its
/// String Catalog has, so a language name or a date reads in the same language as the
/// sentence around it — English until the catalog has another.
let uiLocale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")

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
