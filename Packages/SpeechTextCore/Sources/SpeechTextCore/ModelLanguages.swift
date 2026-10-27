// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Which languages a model knows, and what a row says about them (designed in
// docs/design/model-details/). A row names no language unless it is one of the user's own
// — Dictation › Languages I speak — so every sentence here is built from the user's list,
// never written for one language. Pure data and logic.

/// What a model knows, as against `STTModelDescriptor.LanguageSupport`, which says what its
/// API *takes*. Required on every speech catalogue entry, as `price` is: "not published" is
/// a value, never an absent field.
public enum LanguageCoverage: Hashable, Sendable {
    /// The vendor's list.
    case listed(PublishedLanguages)
    /// The vendor publishes no list (OpenAI). Never matched as "not supported".
    case unpublished
    /// Apple: asked of macOS while the app runs (`supportsOnDeviceRecognition` per locale),
    /// never written into the catalogue.
    case decidedBySystem
}

/// A vendor's published language list and where it was read.
public struct PublishedLanguages: Hashable, Sendable {
    /// BCP-47 language codes — ISO 639-1 where one exists, else 639-3 ("yue", "fil") —
    /// whatever the vendor lists, not only the languages the app offers to state.
    public let codes: [String]
    public let source: URL
    public let checked: DateComponents
    /// A vendor that says "90+ languages" rather than counting its list: the subtitle says
    /// what the vendor says. Nil shows the list's exact count.
    public var vendorSaysAtLeast: Int? = nil
}

/// A weakness in one language that we measured, shown only to someone who speaks it.
public struct LanguageNote: Hashable, Sendable {
    /// "Makes mistakes in Ukrainian." — the one sentence that may name a language, because
    /// it is shown only to someone who listed it.
    let text: String
    /// The corpus run or measurement it comes from ("2026-09-17, M1 Pro").
    let measured: String
}

enum LanguageMatch: Hashable {
    case supported, unsupported, unknown
}

/// The language subtag of a BCP-47 code, lowercased: "uk-UA" → "uk".
public func languageSubtag(_ code: String) -> String {
    String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
}

/// How each of the user's languages fares with a model. `onDevice` answers for Apple — nil
/// when macOS cannot say — and is passed in so the decision is testable.
func languageMatch(spoken: [String], coverage: LanguageCoverage,
                   onDevice: (String) -> Bool?) -> [String: LanguageMatch] {
    var result: [String: LanguageMatch] = [:]
    for code in spoken {
        switch coverage {
        case .listed(let list):
            let known = Set(list.codes.map(languageSubtag))
            result[code] = known.contains(languageSubtag(code)) ? .supported : .unsupported
        case .unpublished:
            result[code] = .unknown
        case .decidedBySystem:
            result[code] = onDevice(code).map { $0 ? .supported : .unsupported } ?? .unknown
        }
    }
    return result
}

/// The user's languages a model cannot take, in the user's order. Unknown is not among
/// them: an unpublished list never warns.
func missingLanguages(spoken: [String], coverage: LanguageCoverage,
                      onDevice: (String) -> Bool? = { _ in nil }) -> [String] {
    let match = languageMatch(spoken: spoken, coverage: coverage, onDevice: onDevice)
    return spoken.filter { match[$0] == .unsupported }
}

/// A language's name in English, the app's language: the catalogue's name for one the user
/// can state, else Foundation's, else the code itself.
func languageDisplayName(_ code: String) -> String {
    if let stated = spokenLanguageCatalog.first(where: { $0.id == languageSubtag(code) }) {
        return stated.displayName
    }
    return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
}

/// The row's subtitle count: "25 languages", "90+ languages", "English only" — nil when the
/// vendor publishes no list or macOS decides. One fact, the same for everyone.
public func languageCountLabel(_ coverage: LanguageCoverage) -> String? {
    guard case .listed(let list) = coverage else { return nil }
    let count = Set(list.codes.map(languageSubtag)).count
    if count == 1 { return "\(languageDisplayName(list.codes[0])) only" }
    if let floor = list.vendorSaysAtLeast { return "\(floor)+ languages" }
    return "\(count) languages"
}

/// The warning badge for a row whose model lacks one of the user's languages: "No Spanish",
/// "No Spanish +1", and for Apple "No Spanish on-device". Nil when nothing is missing.
public func missingLanguageBadgeText(spoken: [String], coverage: LanguageCoverage,
                              onDevice: (String) -> Bool? = { _ in nil }) -> String? {
    let missing = missingLanguages(spoken: spoken, coverage: coverage, onDevice: onDevice)
    guard let first = missing.first else { return nil }
    let onThisMac = coverage == .decidedBySystem ? " on-device" : ""
    let more = missing.count > 1 ? " +\(missing.count - 1)" : ""
    return "No \(languageDisplayName(first))\(onThisMac)\(more)"
}

/// A row's line with the measured notes for the user's own languages added, in their order.
/// Every row in Settings and setup goes through it, so a note is never shown to someone who
/// does not speak the language.
public func lineWithLanguageNotes(_ line: String, notes: [String: LanguageNote], spoken: [String]) -> String {
    let added = spoken.compactMap { code in
        notes[code] ?? notes.first(where: { languageSubtag($0.key) == languageSubtag(code) })?.value
    }
    .map(\.text)
    return ([line] + added).filter { !$0.isEmpty }.joined(separator: " ")
}

/// The *Languages I speak* caption's warning, while the selected model cannot take one of
/// the listed languages: "Phonon-2 can't take Ukrainian." Nil when it can, or nobody knows.
public func spokenLanguagesWarning(modelName: String, spoken: [String], coverage: LanguageCoverage,
                            onDevice: (String) -> Bool? = { _ in nil }) -> String? {
    let missing = missingLanguages(spoken: spoken, coverage: coverage, onDevice: onDevice)
    guard !missing.isEmpty else { return nil }
    let names = missing.map(languageDisplayName)
    let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names[0]
    return "\(modelName) can't take \(list)\(coverage == .decidedBySystem ? " on this Mac" : "")."
}

// MARK: - Published lists

/// OpenAI's Whisper: the `LANGUAGES` table in its tokenizer, which every Whisper model
/// shares — 99 languages, plus Cantonese ("yue") from Large v3 on. Read from
/// github.com/openai/whisper (whisper/tokenizer.py) on 2026-10-17. Whisper writes Javanese
/// "jw", which is not a BCP-47 code; it is "jv" here.
private let whisperLanguageCodes = [
    "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv",
    "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
    "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr",
    "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
    "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu",
    "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
    "mg", "as", "tt", "haw", "ln", "ha", "ba", "jv", "su",
]

private let whisperSource = URL(string: "https://github.com/openai/whisper/blob/main/whisper/tokenizer.py")!

/// Whisper before Large v3 (Tiny, Base, Small): 99 languages.
let whisperLanguages = LanguageCoverage.listed(PublishedLanguages(
    codes: whisperLanguageCodes, source: whisperSource, checked: ModelRetirement.day(2026, 10, 17)))

/// Whisper Large v3 and v3 Turbo, locally or on Groq (which serves OpenAI's weights): the
/// same 99 and Cantonese.
let whisperV3Languages = LanguageCoverage.listed(PublishedLanguages(
    codes: whisperLanguageCodes + ["yue"], source: whisperSource, checked: ModelRetirement.day(2026, 10, 17)))

/// NVIDIA's Parakeet TDT 0.6B v3: 25 European languages, which Ultra and Redux keep ("Languages
/// … are the original's", their model cards).
let parakeetV3LanguageCodes = [
    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
    "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
]

/// A Parakeet build's languages, read from the `language` list of the model card of the
/// FluidInference repository the app downloads it from — machine-readable, so
/// `scripts/check-vendor-models.sh` compares it every week. Read 2026-10-17 for the first four,
/// 2026-10-26 for Bark 3.0 and Bark 3.0 Clean.
func parakeetLanguages(repository: String, codes: [String] = parakeetV3LanguageCodes,
                       checked: DateComponents = ModelRetirement.day(2026, 10, 17)) -> LanguageCoverage {
    .listed(PublishedLanguages(codes: codes, source: URL(string: "https://huggingface.co/\(repository)")!,
                               checked: checked))
}

let parakeetV3Languages = parakeetLanguages(repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml")

/// ElevenLabs' Scribe v2: "90+ languages, including:" a list of ISO 639-3 codes, written
/// here as 639-1 where one exists (elevenlabs.io/docs/overview/capabilities/speech-to-text,
/// read 2026-10-17). Yoruba appears only in that page's accuracy table, not in the list, so
/// it is left out.
let scribeLanguages = LanguageCoverage.listed(PublishedLanguages(
    codes: [
        "af", "am", "ar", "hy", "as", "ast", "az", "be", "bn", "bs", "bg", "my", "yue", "ca",
        "ceb", "ny", "hr", "cs", "da", "nl", "en", "et", "fil", "fi", "fr", "ff", "gl", "lg",
        "ka", "de", "el", "gu", "ha", "he", "hi", "hu", "is", "ig", "id", "ga", "it", "ja",
        "jv", "kea", "kn", "kk", "km", "ko", "ku", "ky", "lo", "lv", "ln", "lt", "luo", "lb",
        "mk", "ms", "ml", "mt", "zh", "mi", "mr", "mn", "ne", "nso", "no", "oc", "or", "ps",
        "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sn", "sd", "si", "sk", "sl", "so", "es",
        "sw", "sv", "ta", "tg", "te", "th", "tr", "uk", "umb", "ur", "uz", "vi", "cy", "wo",
        "xh", "zu",
    ],
    source: URL(string: "https://elevenlabs.io/docs/overview/capabilities/speech-to-text")!,
    checked: ModelRetirement.day(2026, 10, 17), vendorSaysAtLeast: 90))
