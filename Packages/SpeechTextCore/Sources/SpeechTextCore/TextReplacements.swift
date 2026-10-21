// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Replacements

/// One Replace / With pair from the Dictionary page's Replacements table, as macOS's own
/// Text Replacements names them: whenever `replace` is recognised, `with` is written
/// instead ("кома" → ","). Unlike a Dictionary word it is never sent to an engine or to
/// AI Rewrite — it only corrects text. `replace` is matched as whole words, ignoring
/// case; `with` is written exactly as typed.
public struct TextReplacementPair: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var replace: String
    public var with: String

    init(id: UUID = UUID(), replace: String, with: String) {
        self.id = id
        self.replace = replace
        self.with = with
    }
}

/// Every correction the user asked for, compiled into one pass: the Replacements table,
/// then each Dictionary word's wrong spellings (and, for a word whose capitals matter, the
/// word itself in any capitals).
///
/// - Whole words, Unicode-aware: no letter, mark, digit, apostrophe or hyphen may touch
///   a match, so "бот" is not replaced inside "чат-бот", nor "об" inside "об'єкт".
/// - Ukrainian's three apostrophes (`'`, `’`, `ʼ`) are one: a rule typed with one fires
///   on text an engine wrote with another.
/// - The longest source wins where two overlap, and a source of several words matches
///   across any run of whitespace.
/// - One pass: a replacement's own output is never matched again, so "A → B" and
///   "B → C" do not chain into "A → C".
///
/// Applied to final text only — a segment's result, and the LLM's reply — never to the
/// live text on the overlay (see **The Dictionary corrects final text, never live
/// text**), so a source may have any number of words. Pure logic.
struct TextReplacementRules {
    private let withByKey: [String: String]
    private let expression: NSRegularExpression?

    /// `pairs` in order of precedence: of two with the same source, the first is kept.
    init(_ pairs: [TextReplacementPair]) {
        var withByKey: [String: String] = [:]
        for pair in pairs {
            let key = Self.key(pair.replace)
            let with = pair.with.trimmingCharacters(in: .whitespacesAndNewlines)
            // Stored JSON may come from anywhere; a rule the page would refuse is skipped.
            guard !key.isEmpty, !with.isEmpty, withByKey[key] == nil else { continue }
            withByKey[key] = with
        }
        self.withByKey = withByKey
        expression = Self.expression(for: Array(withByKey.keys))
    }

    /// The table's pairs first — each is a rule the user wrote out whole — then every
    /// Dictionary word's spellings, and its own spelling when its capitals matter.
    init(entries: [VocabularyEntry], replacements: [TextReplacementPair]) {
        var pairs = replacements
        for entry in entries {
            let term = entry.trimmedTerm
            guard !term.isEmpty else { continue }
            pairs += entry.replacements.map { TextReplacementPair(replace: $0, with: term) }
            if entry.fixesCapitals { pairs.append(TextReplacementPair(replace: term, with: term)) }
        }
        self.init(pairs)
    }

    var isEmpty: Bool { withByKey.isEmpty }

    /// `text` with every replacement written in.
    func applied(to text: String) -> String {
        guard let expression, !text.isEmpty else { return text }
        var result = ""
        var last = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let with = withByKey[Self.key(String(text[range]))] else { continue }
            result += text[last..<range.lowerBound]
            result += with
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    /// Lowercased, one space between words, one apostrophe — the form a rule and a match
    /// are compared in.
    static func key(_ text: String) -> String {
        String(text.lowercased().map { $0 == "’" || $0 == "ʼ" ? "'" : $0 })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// One alternation of every source, the most words first, then the longest.
    private static func expression(for keys: [String]) -> NSRegularExpression? {
        guard !keys.isEmpty else { return nil }
        let sorted = keys.sorted {
            let (a, b) = ($0.split(separator: " ").count, $1.split(separator: " ").count)
            return a != b ? a > b : ($0.count != $1.count ? $0.count > $1.count : $0 < $1)
        }
        let alternatives = sorted.map { key in
            key.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)).replacingOccurrences(of: "'", with: "['’ʼ]") }
                .joined(separator: "\\s+")
        }
        let edge = "[\\p{L}\\p{M}\\p{N}_'’ʼ\\-]"
        let pattern = "(?<!\(edge))(?:\(alternatives.joined(separator: "|")))(?!\(edge))"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

/// The Replacements table's store, and what it may hold. Only the Dictionary page writes
/// it: a stored setting is evidence of an earlier install to `OnboardingGate`.
public enum TextReplacements {
    public enum EntryProblem: Equatable, Sendable {
        case emptyReplace
        case emptyWith
        case noWord
        case duplicate
    }

    /// Why a pair cannot be added to `existing`, or nil when it can.
    public static func entryProblem(replace: String, with: String, existing: [TextReplacementPair]) -> EntryProblem? {
        let key = TextReplacementRules.key(replace)
        if key.isEmpty { return .emptyReplace }
        if with.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyWith }
        if !key.contains(where: { $0.isLetter || $0.isNumber }) { return .noWord }
        if existing.contains(where: { TextReplacementRules.key($0.replace) == key }) { return .duplicate }
        return nil
    }

    /// The pair as it is stored: `replace` on one line with single spaces, `with` trimmed.
    public static func normalized(replace: String, with: String) -> TextReplacementPair {
        TextReplacementPair(replace: replace.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
                            with: with.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func decode(_ data: Data?) -> [TextReplacementPair] {
        guard let data, let pairs = try? JSONDecoder().decode([TextReplacementPair].self, from: data) else {
            return []
        }
        return pairs
    }

    static func encode(_ pairs: [TextReplacementPair]) -> Data? {
        try? JSONEncoder().encode(pairs)
    }

    /// The stored pairs. Read once per recording by `RecordingConfiguration` and once per
    /// LLM reply, never by the tests.
    public static func load() -> [TextReplacementPair] {
        decode(UserDefaults.standard.data(forKey: SettingsKeys.textReplacements))
    }

    public static func save(_ pairs: [TextReplacementPair]) {
        UserDefaults.standard.set(encode(pairs), forKey: SettingsKeys.textReplacements)
    }
}
