// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Terms to the engine

/// A term from the Settings › Speech › Vocabulary list an earlier release shipped, before the
/// Dictionary (`Vocabulary`) became the one store. Decoded only by
/// `CustomVocabulary.migrateLegacyStoreIfNeeded`, which moves the list into the
/// Dictionary once.
struct VocabularyTerm: Codable, Hashable, Identifiable {
    var id: UUID
    var text: String
    var added: Date

    init(id: UUID = UUID(), text: String, added: Date = Date()) {
        self.id = id
        self.text = text
        self.added = added
    }
}

/// How many terms a model takes, and what shape each must have. Every limit is the
/// vendor's documented one unless its comment in the catalogue says it is ours.
public struct TermListLimits: Hashable, Sendable {
    let maxTerms: Int
    /// Inclusive.
    let maxCharacters: Int
    /// Inclusive; nil when the vendor sets none.
    let maxWords: Int?
    /// Characters the vendor refuses the *whole request* for — so a term holding one is
    /// skipped rather than sent.
    let forbidden: Set<Character>

    func accepts(_ term: String) -> Bool {
        guard !term.isEmpty, term.count <= maxCharacters else { return false }
        if term.contains(where: { forbidden.contains($0) || $0.isNewline }) { return false }
        if let maxWords, CustomVocabulary.wordCount(term) > maxWords { return false }
        return true
    }
}

/// Which of the Dictionary's words a speech model is sent, and in what order. The words
/// are `Vocabulary`'s; this decides only what reaches an engine through a parameter that
/// is a term list (`STTModelDescriptor.vocabulary`). Pure logic; its
/// only reader of History is `historyUses`, which the app points at
/// `TranscriptionHistory` at launch.
public enum CustomVocabulary {
    /// Words added this recently go first when a model cannot take them all.
    static let recentDays: Double = 7

    /// The longest term sent to an engine with no limit of its own: Scribe's upload takes
    /// under 50 characters, and no engine here is sent longer.
    static let maxEntryCharacters = 49

    /// Replaced at launch by History's count of each needle asked for (`searchable` of a
    /// term), kept between dictations by a `HistoryTermCounts`. No counts until then, which
    /// is the test bundle's state: nothing is ranked by use there. Written once, on main,
    /// before the first dictation reads it, which is what makes the unchecked access safe.
    public nonisolated(unsafe) static var historyUses: (Set<String>) -> [String: Int] = { _ in [:] }

    /// Whether the Dictionary's words are sent to the speech engine — the one switch, on
    /// the Dictionary page. On unless the user turned it off.
    static func isSent(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKeys.sendVocabularyToEngine) as? Bool ?? true
    }

    static func wordCount(_ term: String) -> Int {
        term.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: The list an earlier release shipped

    /// `entries` with every legacy term it does not already hold (ignoring case) added as
    /// a word of its own, with the date it was added.
    static func migrateLegacyTerms(_ legacy: [VocabularyTerm], into entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var known = Set(entries.map { $0.trimmedTerm.lowercased() })
        var merged = entries
        for term in legacy {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, known.insert(text.lowercased()).inserted else { continue }
            merged.append(VocabularyEntry(id: term.id, term: text, added: term.added))
        }
        return merged
    }

    /// Moves a stored `customVocabulary` into the Dictionary once, then deletes it. Writes
    /// nothing when there is nothing stored: a stored setting is evidence of an earlier
    /// install to `OnboardingGate` (this runs after it has decided, but a new install has
    /// no reason to gain a key).
    public static func migrateLegacyStoreIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: SettingsKeys.customVocabulary) else { return }
        let legacy = (try? JSONDecoder().decode([VocabularyTerm].self, from: data)) ?? []
        if !legacy.isEmpty {
            let entries = Vocabulary.decode(defaults.data(forKey: SettingsKeys.vocabulary))
            defaults.set(Vocabulary.encode(migrateLegacyTerms(legacy, into: entries)),
                         forKey: SettingsKeys.vocabulary)
        }
        defaults.removeObject(forKey: SettingsKeys.customVocabulary)
        dlog("Settings", "moved \(legacy.count) Speech vocabulary term(s) into the Dictionary")
    }

    // MARK: Selection

    /// The Dictionary's words in the order they are sent: those added in the last
    /// `recentDays` newest first, then the rest by how many times History uses them
    /// (whole words, ignoring case), ties going to the newer word. A blank word, and a
    /// second spelling of one already listed (ignoring case), are left out. `historyTexts`
    /// is read only when `rankByUse` — the order matters only when some engine cannot
    /// take them all.
    public static func ranked(_ entries: [VocabularyEntry], now: Date, rankByUse: Bool,
                       historyTexts: () -> [String]) -> [String] {
        ranked(entries, now: now, rankByUse: rankByUse) { uses(of: $0, in: historyTexts()) }
    }

    /// `ranked`, with History's counts from `uses`: given the needles (`searchable` of each
    /// older term), how many times each occurs across History — `historyUses` in the app,
    /// which keeps them between dictations. Asked only when `rankByUse`, as above.
    static func ranked(_ entries: [VocabularyEntry], now: Date, rankByUse: Bool,
                       uses countUses: (Set<String>) -> [String: Int]) -> [String] {
        var seen = Set<String>()
        let terms = entries.filter { !$0.trimmedTerm.isEmpty && seen.insert($0.trimmedTerm.lowercased()).inserted }
        let cutoff = now.addingTimeInterval(-recentDays * 86_400)
        let recent = terms.filter { $0.added > cutoff }.sorted { $0.added > $1.added }
        var older = terms.filter { $0.added <= cutoff }.sorted { $0.added > $1.added }
        if rankByUse, older.count > 1 {
            // A term with no letter or digit has no words to look for, and is used nowhere.
            let needles = older.map { searchable($0.trimmedTerm) }
            let counts = countUses(Set(needles.filter { $0.count > 2 }))
            let uses = Dictionary(zip(older, needles).map { entry, needle -> (UUID, Int) in
                (entry.id, needle.count > 2 ? counts[needle] ?? 0 : 0)
            }, uniquingKeysWith: { first, _ in first })
            // Stable on the date order above, so ties keep the newer word first.
            older = older.enumerated().sorted { lhs, rhs in
                let (a, b) = (uses[lhs.element.id] ?? 0, uses[rhs.element.id] ?? 0)
                return a != b ? a > b : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return (recent + older).map(\.trimmedTerm)
    }

    /// What a model with `limits` is sent from the `ranked` list: every term it accepts,
    /// in order, up to its count. A term it would refuse is skipped, never cut short —
    /// half a name is a different name. Nil limits send nothing.
    public static func selected(_ ranked: [String], limits: TermListLimits?) -> [String] {
        guard let limits else { return [] }
        return Array(ranked.lazy.filter { limits.accepts($0) }.prefix(limits.maxTerms))
    }

    /// Lowercased words of letters and digits, one space apart — the same text a term
    /// is looked for in, so "AC-42" finds "ac-42," and "API" does not find "rapid".
    static func words(_ text: String) -> String {
        wordList(text).joined(separator: " ")
    }

    fileprivate static func wordList(_ text: String) -> [Substring] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    /// How many times each needle (`searchable` of a term) occurs across `texts`, counted
    /// afresh — what `HistoryTermCounts` keeps.
    static func uses(of needles: Set<String>, in texts: [String]) -> [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: needles.map { ($0, 0) })
        let matcher = Needles(needles)
        for text in texts {
            matcher.count(in: wordList(text), into: &counts)
        }
        return counts
    }

    /// `words(text)` with a space at either end — the text a term is looked for in, and,
    /// made of the term, what is looked for: whole words only.
    static func searchable(_ text: String) -> String {
        " " + words(text) + " "
    }

    /// Needles by their first word, matched word by word: the occurrences a search of
    /// `searchable(text)` for each finds — whole words, compared as Swift compares strings
    /// (canonically equivalent spellings alike), the next occurrence of a needle starting
    /// no earlier than the last one ended — with each word of the text looked up once, not
    /// the whole text searched once per needle. That search, a Foundation `range(of:)`,
    /// cost seconds a dictation start once History held thousands of records.
    fileprivate struct Needles {
        private var byFirstWord: [Substring: [(needle: String, words: [Substring])]] = [:]

        init(_ needles: some Sequence<String>) {
            for needle in needles {
                let words = needle.split(separator: " ")
                guard let first = words.first else { continue }
                byFirstWord[first, default: []].append((needle, words))
            }
        }

        var isEmpty: Bool { byFirstWord.isEmpty }

        /// Adds `sign` to `counts` for each occurrence of a needle in `words`.
        func count(in words: [Substring], into counts: inout [String: Int], sign: Int = 1) {
            guard !byFirstWord.isEmpty else { return }
            // Where each needle may next begin: "a a" occurs twice in "a a a a", not three times.
            var resume: [String: Int] = [:]
            for (index, word) in words.enumerated() {
                guard let candidates = byFirstWord[word] else { continue }
                for candidate in candidates where index >= resume[candidate.needle, default: 0] {
                    let end = index + candidate.words.count
                    guard end <= words.count, words[index..<end].elementsEqual(candidate.words) else { continue }
                    counts[candidate.needle, default: 0] += sign
                    resume[candidate.needle] = end
                }
            }
        }
    }
}

// MARK: - History's counts, kept

/// How often each term occurs in History, kept between dictations for `ranked`, which a
/// dictation start asks for — twice — before the microphone opens. Counted afresh each
/// time, that was every record's text read again, for every start. Kept, each term is
/// counted over the whole of History once; after that a look only adds what came, takes
/// away what went, and recounts a record whose text changed (a retry).
///
/// Records are told apart by id, which History never repeats — a second record with an id
/// already seen is not counted. Not thread-safe: the app keeps one on the main thread,
/// where History lives.
public final class HistoryTermCounts {
    /// Each record's text as last counted — History's own string, so nothing is copied, and
    /// telling an unchanged one costs no more than comparing the two references.
    private var texts: [UUID: String] = [:]
    /// The count of each needle asked for last time, over `texts`.
    private var counts: [String: Int] = [:]

    public init() {}

    /// How many times each of `needles` occurs across `history` (every record's id and
    /// text) — what `CustomVocabulary.uses(of:in:)` gives, without redoing it.
    public func uses(of needles: Set<String>, in history: some Sequence<(id: UUID, text: String)>) -> [String: Int] {
        // A term no longer asked for stops being kept.
        counts = counts.filter { needles.contains($0.key) }
        let kept = CustomVocabulary.Needles(counts.keys)
        var present = Set<UUID>(minimumCapacity: texts.count)
        for (id, text) in history where present.insert(id).inserted {
            if let old = texts[id] {
                if old == text { continue }
                if !kept.isEmpty { kept.count(in: CustomVocabulary.wordList(old), into: &counts, sign: -1) }
            }
            texts[id] = text
            if !kept.isEmpty { kept.count(in: CustomVocabulary.wordList(text), into: &counts) }
        }
        if present.count < texts.count {
            for id in texts.keys.filter({ !present.contains($0) }) {
                guard let old = texts.removeValue(forKey: id), !kept.isEmpty else { continue }
                kept.count(in: CustomVocabulary.wordList(old), into: &counts, sign: -1)
            }
        }
        // A term asked for the first time is counted once, over everything.
        let added = needles.filter { counts[$0] == nil }
        if !added.isEmpty {
            for needle in added { counts[needle] = 0 }
            let fresh = CustomVocabulary.Needles(added)
            for text in texts.values {
                fresh.count(in: CustomVocabulary.wordList(text), into: &counts)
            }
        }
        return counts
    }
}
