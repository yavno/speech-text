// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The main window's Dictionary: the words a dictation keeps getting wrong — names, product
// terms, code identifiers — and how they are spelled. The field calls this a *custom
// vocabulary*; Apple's Speech framework, *contextual strings*; the UI says Dictionary,
// which is the design's name for the page. (`Dictionary` itself is Swift's, hence
// `Vocabulary` here.)
//
// Each word does three things, as far as each step allows:
// - the speech engine is told it, where its API takes one, unless the page's switch is
//   off: a term list for Apple (`contextualStrings`), OpenAI (`keywords`) and ElevenLabs
//   (`keyterms`) — which words, and how many, is `CustomVocabulary`'s — and Groq's
//   Whisper a `prompt` (`whisperPrompt`), on trial, with what to watch recorded;
// - the wrong spellings the user lists are replaced in what comes back, whatever the
//   engine — `corrected`;
// - AI Rewrite is handed the words and told to keep them as written — `promptBlock`.
//
// Pure. The page is DictionaryView.swift.

/// One word the user taught: how it is spelled, and how it has come out wrong.
public struct VocabularyEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var term: String
    /// Spellings that are replaced by `term` — what the engine wrote instead.
    public var misheard: [String]
    var added: Date

    public init(id: UUID = UUID(), term: String, misheard: [String] = [], added: Date = Date()) {
        self.id = id
        self.term = term
        self.misheard = misheard
        self.added = added
    }

    public var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The listed spellings, trimmed, without blanks or the term itself.
    public var replacements: [String] {
        var seen = Set<String>()
        return misheard
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != trimmedTerm && seen.insert($0.lowercased()).inserted }
    }

    /// A word whose capitals are the point — "iPhone", "SpeechText", "JSON", "macOS" — is
    /// put back the way it is written when it comes out in other capitals, even with no
    /// wrong spelling listed. A plain word or a name ("Sarah", "Apple") is not: lower case
    /// may be another word, and a capital may only be the start of a sentence.
    public var fixesCapitals: Bool {
        let letters = trimmedTerm.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let rest = letters.dropFirst()
        return rest.contains(where: \.isUppercase)
    }
}

public enum Vocabulary {
    // MARK: Replacing

    /// `text` with every listed wrong spelling replaced by its word, and the Replacements
    /// table's pairs written in — one pass under `TextReplacementRules`' rules: whole
    /// words with Unicode edges, ignoring case, the longest source first, no chaining. A
    /// word already right changes nothing, so running it twice is the same as once.
    public static func corrected(_ text: String, entries: [VocabularyEntry],
                          replacements: [TextReplacementPair] = []) -> String {
        TextReplacementRules(entries: entries, replacements: replacements).applied(to: text)
    }

    // MARK: Telling the speech engine

    /// The words for a recogniser that takes a list — Apple's `contextualStrings`, which
    /// Apple advises keeping to about a hundred.
    public static func hints(_ entries: [VocabularyEntry], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        return Array(entries.map(\.trimmedTerm).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(limit))
    }

    /// The longest prompt `whisperPrompt` writes. Groq's Whisper reads at most 224 tokens
    /// of prompt and refuses more; Cyrillic runs to a token every two or three characters,
    /// so 300 characters stays well inside it whatever the words.
    static let whisperPromptLimit = 300

    /// Whisper's `prompt` is read as the text before the recording, so the words go in as
    /// a plain list — enough for it to spell them that way when it hears them. `terms` is
    /// the ranked list (`RecordingConfiguration.vocabulary`), so the words most worth
    /// sending come first. Nil when there are none; words past the limit are left out
    /// whole, never cut.
    static func whisperPrompt(_ terms: [String]) -> String? {
        let fitting = whisperPromptTerms(terms)
        return fitting.isEmpty ? nil : fitting.joined(separator: ", ") + "."
    }

    /// The words `whisperPrompt` holds — the Dictionary page counts them.
    public static func whisperPromptTerms(_ terms: [String]) -> [String] {
        var fitting: [String] = []
        var length = 0
        for term in terms where !term.isEmpty {
            let next = fitting.isEmpty ? term.count : length + 2 + term.count
            guard next + 1 <= whisperPromptLimit else { break }
            fitting.append(term)
            length = next
        }
        return fitting
    }

    // MARK: Telling AI Rewrite

    /// The `<vocabulary>` block a dictation's user message carries: one word a line, made
    /// unable to close the block. Data, like `<context>` — the system prompt says what to
    /// do with it.
    public static func promptBlock(_ entries: [VocabularyEntry]) -> String? {
        let terms = hints(entries).map {
            $0.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
                .replacingOccurrences(of: "\n", with: " ")
        }
        guard !terms.isEmpty else { return nil }
        return "<vocabulary>\n" + terms.joined(separator: "\n") + "\n</vocabulary>"
    }

    // MARK: What History says

    /// How many of `texts` use the word, as written — the page's "in 12 dictations".
    static func uses(of entry: VocabularyEntry, in texts: [String]) -> Int {
        useMatcher(for: entry.trimmedTerm).map { uses(of: $0, in: texts) } ?? 0
    }

    /// The word as `uses` looks for it: whole, as written. Nil for a blank one.
    static func useMatcher(for term: String) -> NSRegularExpression? {
        guard !term.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
        return try? NSRegularExpression(pattern: pattern)
    }

    static func uses(of matcher: NSRegularExpression, in texts: [String]) -> Int {
        texts.filter { matcher.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count
    }

    /// Words from the user's own dictations that look like names or terms — capitals
    /// inside a word ("iPhone", "SpeechText", "JSON"), or a capital that does not start a
    /// sentence or a line ("Sarah", "Figma") and is never written in lower case — used at
    /// least `minimumCount` times and not taught yet, most used first.
    static func suggestions(from texts: [String], excluding entries: [VocabularyEntry],
                            minimumCount: Int = 2, limit: Int = 8) -> [(term: String, count: Int)] {
        suggestions(from: suggestionCandidates(from: texts, minimumCount: minimumCount),
                    excluding: entries, limit: limit)
    }

    /// `suggestions` of the candidates `suggestionCandidates` found: the first `limit` of
    /// them not taught yet. The cheap half — the Dictionary page runs it as words are typed.
    static func suggestions(from candidates: [(term: String, count: Int)], excluding entries: [VocabularyEntry],
                            limit: Int = 8) -> [(term: String, count: Int)] {
        let known = Set(entries.map { $0.trimmedTerm.lowercased() })
        return Array(candidates.lazy.filter { !known.contains($0.term.lowercased()) }.prefix(limit))
    }

    /// Every word `suggestions` may offer from `texts`, taught or not, most used first —
    /// the half that reads all of History. A taught word is left out afterwards rather than
    /// skipped here: it changes no other word's count or place, so the order is the same.
    static func suggestionCandidates(from texts: [String], minimumCount: Int = 2) -> [(term: String, count: Int)] {
        var counts: [String: Int] = [:]
        var named = Set<String>()
        var lowercase = Set<String>()
        var order: [String] = []

        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                // Each line starts a sentence: a list item, a paragraph.
                var sentenceStart = true
                var seenHere = Set<String>()
                for raw in line.split(whereSeparator: \.isWhitespace) {
                    let word = raw.trimmingCharacters(in: notWordCharacters)
                    let letters = word.filter(\.isLetter)
                    // A bullet or a dash between words leaves the sentence where it was.
                    guard !letters.isEmpty else { continue }
                    defer { sentenceStart = raw.last.map { ".!?…:".contains($0) } ?? false }
                    if letters.allSatisfy(\.isLowercase) { lowercase.insert(word.lowercased()); continue }
                    guard letters.count >= 2,
                          word.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
                          seenHere.insert(word).inserted else { continue }
                    // A capital inside the word makes it a term wherever it stands; a capital
                    // only at the front counts in the middle of a sentence, never at its start,
                    // where every word wears one.
                    guard letters.dropFirst().contains(where: \.isUppercase) || !sentenceStart else { continue }
                    named.insert(word)
                    if counts[word] == nil { order.append(word) }
                    counts[word, default: 0] += 1
                }
            }
        }
        // A word also written in lower case is an ordinary word that happened to take a
        // capital — "Коли", "All" — not a name.
        named = named.filter { !lowercase.contains($0.lowercased()) }
        // Most used first; a tie keeps the order the words were first said in.
        let found = order.enumerated().compactMap { index, word -> (term: String, count: Int, index: Int)? in
            guard named.contains(word), let count = counts[word], count >= minimumCount else { return nil }
            return (word, count, index)
        }
        return found.sorted { ($1.count, $0.index) < ($0.count, $1.index) }
            .map { ($0.term, $0.count) }
    }

    /// What `suggestions` trims off a word's ends — made once, not once a word.
    private static let notWordCharacters = CharacterSet.alphanumerics.inverted

    // MARK: Storage

    static func decode(_ data: Data?) -> [VocabularyEntry] {
        guard let data, let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) else { return [] }
        return entries
    }

    static func encode(_ entries: [VocabularyEntry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// The user's words, as stored. Read once per recording by `RecordingConfiguration`
    /// and once per rewrite, never by the tests.
    public static func load() -> [VocabularyEntry] {
        decode(UserDefaults.standard.data(forKey: SettingsKeys.vocabulary))
    }

    public static func save(_ entries: [VocabularyEntry]) {
        UserDefaults.standard.set(encode(entries), forKey: SettingsKeys.vocabulary)
    }
}

// MARK: - What History says, kept

/// The Dictionary page's reading of History — the suggestions and each word's uses — kept
/// until History changes. The page's body runs on every keystroke in its fields, and
/// worked out afresh each time that was every word of every dictation split and counted,
/// and a search of every dictation per word shown.
///
/// History is known to have changed by a fingerprint of the dictations a suggestion or a
/// count reads (their number, the first and last, and each one's status and the length of
/// what was delivered). One that changed without changing any of those — a rewrite
/// replaced by another of exactly the same length — goes unseen until the next change, and
/// a count or a suggestion is that much out of date meanwhile.
public final class VocabularyHistoryCache {
    private var fingerprint: Int?
    /// The delivered text of every successful dictation, newest first.
    private var texts: [String] = []
    private var candidates: [(term: String, count: Int)]?
    /// By the word exactly as written: `uses` minds capitals.
    private var useCounts: [String: Int] = [:]
    private var matchers: [String: NSRegularExpression] = [:]

    public init() {}

    /// Brought up to date with `records`; read in full only when they changed.
    public func refresh(from records: [TranscriptionRecord]) {
        var hasher = Hasher()
        hasher.combine(records.count)
        hasher.combine(records.first?.id)
        hasher.combine(records.last?.id)
        for record in records {
            hasher.combine(record.status == .success ? record.deliveredText.utf8.count : -1)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != self.fingerprint else { return }
        self.fingerprint = fingerprint
        texts = records.filter { $0.status == .success }.map(\.deliveredText)
        candidates = nil
        // A word's matcher outlives a change of History while the word is still asked
        // about; one that was not since the last change (a prefix typed into the editor,
        // a word deleted) is let go.
        matchers = matchers.filter { useCounts[$0.key] != nil }
        useCounts = [:]
    }

    /// `Vocabulary.suggestions` of the dictations last refreshed from.
    public func suggestions(excluding entries: [VocabularyEntry]) -> [(term: String, count: Int)] {
        let candidates = candidates ?? Vocabulary.suggestionCandidates(from: texts)
        self.candidates = candidates
        return Vocabulary.suggestions(from: candidates, excluding: entries)
    }

    /// `Vocabulary.uses` of the dictations last refreshed from.
    public func uses(of entry: VocabularyEntry) -> Int {
        let term = entry.trimmedTerm
        if let count = useCounts[term] { return count }
        let matcher = matchers[term] ?? Vocabulary.useMatcher(for: term)
        matchers[term] = matcher
        let count = matcher.map { Vocabulary.uses(of: $0, in: texts) } ?? 0
        useCounts[term] = count
        return count
    }
}
