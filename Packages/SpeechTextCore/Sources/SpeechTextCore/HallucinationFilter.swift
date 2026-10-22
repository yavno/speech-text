// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Known hallucinations

/// What a speech model says when there was nothing to hear. Whisper was trained on
/// subtitled video, so silence or a breath comes back as a subtitle's sign-off ("Thank
/// you for watching", "Субтитры сделал DimaTorzok"); a stream opened on silence has
/// answered "Evet." and "Seyit." (pasted twice in the first manual test pass). No vendor
/// documents it, so the filter is ours.
///
/// Deliberately narrow: a phrase is dropped only when it is the *whole* result of a
/// short segment. The same words inside a real dictation are left alone, and so is a
/// short segment that says anything else — a filter that guesses would delete speech.
/// Phrases a person plausibly dictates on their own ("Thank you", "Дякую за увагу")
/// are not on the list, however often a model invents them.
///
/// Pure logic.
public enum HallucinationFilter {
    /// Compared after `normalized`: lowercase, letters and digits only, one space
    /// between words.
    public static let phrases: Set<String> = [
        // English
        "thank you for watching",
        "thanks for watching",
        "thank you for watching and see you next time",
        "thank you so much for watching",
        "please subscribe",
        "please like and subscribe",
        "like and subscribe",
        "subscribe to the channel",
        "see you in the next video",
        // Turkish — measured in this app's own streams
        "evet",
        "seyit",
        "abone olmayı unutmayın",
        // Ukrainian
        "дякую за перегляд",
        "дякуємо за перегляд",
        "дякую за перегляд до зустрічі",
        "продовження далі",
        "підписуйтесь на канал",
        "субтитрування dimatorzok",
        // Russian
        "спасибо за просмотр",
        "продолжение следует",
        "подписывайтесь на канал",
    ]

    /// Subtitle credits, which carry a name after them ("Субтитры сделал DimaTorzok",
    /// "Субтитри створено спільнотою Amara.org"): a whole result that *begins* with one of these is a
    /// credit line, not speech. Each is the credit's own wording, never a lone word or a
    /// loose pair — "Субтитры готовы" and "Subtitles by tomorrow" are things people say.
    public static let prefixes: [String] = [
        "subtitles by the amara org community",
        "субтитры сделал",
        "субтитры создавал",
        "субтитры подготовлены",
        "субтитры делал",
        "редактор субтитров",
        "субтитри створено",
        "субтитри зроблено",
        "altyazı m k",
    ]

    /// True when `text` is nothing but a known hallucination and the segment it came
    /// from was no longer than `STTTuning.hallucinationSegmentSeconds`. A duration of 0
    /// means "not measured" and counts as short: the phrase alone is the evidence then.
    static func isHallucination(_ text: String, segmentSeconds: TimeInterval) -> Bool {
        guard segmentSeconds <= STTTuning.hallucinationSegmentSeconds else { return false }
        let words = normalized(text)
        guard !words.isEmpty else { return false }
        if phrases.contains(words) { return true }
        return prefixes.contains { words == $0 || words.hasPrefix($0 + " ") }
    }

    /// Why a segment's whole result is not speech, or nil to keep it.
    public enum Rejection: Equatable, CustomStringConvertible, Sendable {
        /// A known phrase (`isHallucination`), the segment short enough to trust it.
        case knownPhrase
        /// Not one letter or digit: «.», «..», «…» — what a model makes of a breath.
        case noLettersOrDigits
        /// Every letter in a script none of the user's stated languages writes in, such as
        /// «うーん。» or «흠..» for someone who speaks Ukrainian and English.
        case foreignScript

        public var description: String {
            switch self {
            case .knownPhrase: "a known hallucination"
            case .noLettersOrDigits: "no letter or digit"
            case .foreignScript: "in a script none of the stated languages uses"
            }
        }
    }

    /// The filter's one entry point for a segment's whole result: a known phrase (on a
    /// short segment), a result with nothing to read, or — only when the user stated the
    /// languages they speak — a result written wholly in a script none of them uses. With
    /// no languages stated the script is never judged: the model may be right that the
    /// user spoke Korean.
    public static func rejection(_ text: String, segmentSeconds: TimeInterval, languages: [String]) -> Rejection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return .noLettersOrDigits }
        if isHallucination(trimmed, segmentSeconds: segmentSeconds) { return .knownPhrase }
        if isForeignScript(trimmed, languages: languages) { return .foreignScript }
        return nil
    }

    /// True when `languages` is not empty, the text has letters, every letter's script is
    /// one `WritingScript` knows, and none of them is Latin or a script of a stated
    /// language. Latin is always allowed: names, brands and code are written in it in
    /// every language. A letter of a script the map does not know keeps the text — the
    /// rule drops only what it can name.
    static func isForeignScript(_ text: String, languages: [String]) -> Bool {
        let stated = languages.compactMap { spokenLanguage(id: $0) }
        guard !stated.isEmpty else { return false }
        let allowed = Set(stated.flatMap(\.scripts)).union([.latin])
        var sawLetter = false
        for character in text where character.isLetter {
            guard let scalar = character.unicodeScalars.first, let script = WritingScript.of(scalar) else { return false }
            if allowed.contains(script) { return false }
            sawLetter = true
        }
        return sawLetter
    }

    /// Lowercased, punctuation and symbols dropped, words separated by one space.
    /// Apostrophes are dropped rather than split on, so "Don't" stays one word.
    public static func normalized(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" || character == "ʼ" {
                continue
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }
}


// MARK: - Scripts

/// A writing system, as Unicode's Script property (ISO 15924) names it — only the ones
/// `spokenLanguageCatalog` writes in, which is all the script rule needs to tell apart.
enum WritingScript: String, CaseIterable {
    case latin, cyrillic, greek, arabic, hebrew, devanagari, thai, hangul, hiragana, katakana, han

    /// The script a letter's first scalar belongs to, by its Unicode block; nil for a
    /// block the map does not cover.
    static func of(_ scalar: Unicode.Scalar) -> WritingScript? {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF5A: .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF: .greek
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: .cyrillic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: .arabic
        case 0x0900...0x097F, 0xA8E0...0xA8FF: .devanagari
        case 0x0E00...0x0E7F: .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xFFA0...0xFFDC: .hangul
        case 0x3040...0x309F: .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: .katakana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: .han
        default: nil
        }
    }
}
