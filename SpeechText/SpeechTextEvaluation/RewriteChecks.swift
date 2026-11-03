// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// The rewrite evaluation's scenarios and the checks a reply is held to. Pure: nothing here
// knows how a reply was obtained, so the same checks can judge any prompt — today's, a
// cleaned one, two steps — and, later, the Playground's runs (#121).
//
// Two kinds of expectation, kept apart on purpose:
//
// - **Text checks** hold whatever the prompt: the language, whether rich Markdown or a
//   bracketed placeholder may appear, what must survive and what must not, the length,
//   no preamble, no leaked marker. They are what compares one prompt with another.
// - **Mode expectations** name the presets of one prompt variant (`modes` for `current`,
//   `variantModes` for any other), because a variant may rename or merge them.
//
// A check must almost never fail a good answer — a noisy one makes every comparison
// meaningless — so the strict ones are opt-in per fixture, and anything fuzzy is left to
// the judge. Each fixture can carry `examples` of replies that must pass or fail, which
// `--self-check` runs before any model is asked.

/// One scenario: what was dictated (or selected), where, and what a right reply looks like.
struct RewriteFixture: Codable, Sendable {
    struct Context: Codable, Sendable {
        var appName: String?
        var bundleID: String?
        var windowTitle: String?
        var fieldLabel: String?
    }

    /// A reply written by hand, with whether the text checks must pass it.
    struct Example: Codable, Sendable {
        var reply: String
        var passes: Bool
        var note: String?
    }

    var id: String
    var note: String?
    /// `edit` for the Edit shortcut; a dictation otherwise.
    var kind: String?
    var transcript: String?
    var selection: String?
    var instruction: String?
    var context: Context?
    var vocabulary: [String]?
    /// A prompt of the user's own, as the Prompts page stores one.
    struct Preset: Codable, Sendable {
        var name: String
        var whenToUse: String
        var instructions: String
    }

    /// The modes a right answer may report under today's prompt; the first is the expected one.
    var modes: [String]
    /// The same for another set of modes, by its name. `2026-11` is the three of
    /// docs/specs/2026-11-03-rewrite-modes-and-router.md — Clean-up, Message, Document — and
    /// the names of the fixture's own `presets`; every variant built on them looks there.
    var variantModes: [String: [String]]?
    /// What the first step should find, for the variants that route (2026-11). The language
    /// asked for, as an ISO 639-1 code; absent when none was, which is most dictations.
    var askedLanguage: String?
    /// The formats a right answer may pick: `plain`, `list` or `markdown`. Absent: plain.
    var format: [String]?
    /// Prompts of the user's own beside the built-ins, for a variant that sends them; `current`
    /// sends the built-ins alone.
    var presets: [Preset]?
    /// The reply's language: `uk`, `any`, or a language written in Latin script (`en`, `pl`, …).
    var language: String
    var mustKeep: [String]?
    var mustNotAppear: [String]?
    /// Headings, bold, tables or code fences may appear. Lists always may.
    var markdown: Bool?
    /// A bracketed `[placeholder]` may appear — an email whose sender is not named.
    var placeholders: Bool?
    /// The reply must not be code: an instruction dictated into an editor is written down.
    var noCode: Bool?
    /// Bounds on the reply's length as a share of the input's, in characters.
    var minLengthRatio: Double?
    var maxLengthRatio: Double?
    /// `dirty` for a transcript written the way a speech engine really writes one — misheard
    /// and transliterated words, a language the engine misdetected, no punctuation, a word cut
    /// in two; `clean` (the default) for text as a person would type it.
    var noise: String?
    /// Nothing is a right answer: hesitations alone, which the app then pastes as they came.
    var allowsEmpty: Bool?
    var examples: [Example]?

    var isEdit: Bool { kind == "edit" }
    var isDirty: Bool { noise == "dirty" }

    /// What the reply is measured against: the transcript, or the selection.
    var input: String { (isEdit ? selection : transcript) ?? "" }

    /// The modes a right answer may report under `variant`, or nil when the fixture says nothing.
    func expectedModes(for variant: String) -> [String]? {
        if let modes = variantModes?[variant] { return modes }
        return variant == "current" ? modes : nil
    }
}

/// What the text checks found in one reply. `failures` names every check that failed.
struct RewriteVerdict: Codable, Equatable, Sendable {
    var empty = false
    var missing: [String] = []
    var unwanted: [String] = []
    var wrongLanguage = false
    var reasoningLeak = false
    var markerLeak = false
    var preamble: String?
    var wrappedInQuotes = false
    var markdown: [String] = []
    var placeholders: [String] = []
    var code = false
    var lengthRatio: Double?
    var tooShort = false
    var tooLong = false

    /// Every failed check as (kind, detail): the kind is what rows are counted by.
    var findings: [(kind: String, detail: String)] {
        var out: [(String, String)] = []
        if empty { out.append(("empty", "empty")) }
        if !missing.isEmpty { out.append(("missing", "missing \(missing.joined(separator: ", "))")) }
        if !unwanted.isEmpty { out.append(("unwanted", "unwanted \(unwanted.joined(separator: ", "))")) }
        if wrongLanguage { out.append(("wrong language", "wrong language")) }
        if reasoningLeak { out.append(("reasoning", "reasoning leaked")) }
        if markerLeak { out.append(("marker", "marker in the text")) }
        if let preamble { out.append(("preamble", "preamble “\(preamble)”")) }
        if wrappedInQuotes { out.append(("quotes", "wrapped in quotes")) }
        if !markdown.isEmpty { out.append(("markdown", "markdown \(markdown.joined(separator: ", "))")) }
        if !placeholders.isEmpty { out.append(("placeholder", "placeholder \(placeholders.joined(separator: ", "))")) }
        if code { out.append(("code", "code")) }
        if tooShort { out.append(("too short", String(format: "too short (%.2f)", lengthRatio ?? 0))) }
        if tooLong { out.append(("too long", String(format: "too long (%.2f)", lengthRatio ?? 0))) }
        return out
    }

    var failures: [String] { findings.map(\.detail) }

    var passed: Bool { failures.isEmpty }
}

enum RewriteChecks {

    // MARK: - The reply as the app reads it

    /// The reply through the app's parser and polish, with the fixture's Dictionary — the
    /// text the app would paste — and the marker as the model wrote it.
    static func read(_ raw: String, fixture: RewriteFixture, presetNames: [String]) -> (text: String, mode: String?, rawMode: String?) {
        let parsed = TextRefinementService.parse(raw, presetNames: presetNames)
        let dictionary = (fixture.vocabulary ?? []).map { VocabularyEntry(term: $0) }
        let text = TextRefinementService.polishedReply(parsed.text, dictionary: dictionary,
                                                      replacements: [], dashStyle: .enDash)
        return (text, parsed.presetName, rawMarkerName(raw))
    }

    /// The name inside a leading `<<mode:NAME>>` as written, before the parser matched it to
    /// a preset — so an abbreviated name (`Technical` for `Technical / Prompt`) is counted.
    static func rawMarkerName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<<mode:") else { return nil }
        let rest = trimmed.dropFirst("<<mode:".count)
        let name = rest.prefix { $0 != ">" && !$0.isNewline }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func modeMatches(_ fixture: RewriteFixture, variant: String, mode: String?) -> Bool? {
        guard let expected = fixture.expectedModes(for: variant), let mode else { return nil }
        return expected.contains { $0.caseInsensitiveCompare(mode) == .orderedSame }
    }

    // MARK: - Text checks

    static func check(_ fixture: RewriteFixture, text: String, raw: String) -> RewriteVerdict {
        var verdict = RewriteVerdict()
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        verdict.empty = reply.isEmpty && fixture.allowsEmpty != true
        let folded = fold(reply)
        verdict.missing = (fixture.mustKeep ?? []).filter { !folded.contains(fold($0)) }
        verdict.unwanted = (fixture.mustNotAppear ?? []).filter { folded.contains(fold($0)) }
        if !reply.isEmpty {
            switch fixture.language {
            case "any": break
            // Written in Cyrillic. Not "most of its letters": an instruction to a coding agent
            // keeps Settings, Control and a path in Latin, and still is Ukrainian.
            case "uk": verdict.wrongLanguage = cyrillicShare(reply) < 0.3
            // Every other language a fixture names is written in Latin script.
            default: verdict.wrongLanguage = cyrillicShare(reply) > 0.1
            }
        }
        verdict.reasoningLeak = leaksReasoning(raw) || leaksReasoning(reply)
        verdict.markerLeak = reply.range(of: #"(?i)<{1,2}\s*/?\s*mode\s*:"#, options: .regularExpression) != nil
        verdict.preamble = preamble(of: reply, input: fixture.input)
        verdict.wrappedInQuotes = isWrappedInQuotes(reply) && !isWrappedInQuotes(fixture.input)
        if fixture.markdown != true { verdict.markdown = richMarkdown(in: reply) }
        if fixture.placeholders != true { verdict.placeholders = placeholders(in: reply, input: fixture.input) }
        if fixture.noCode == true { verdict.code = looksLikeCode(reply) }
        let inputLength = fixture.input.trimmingCharacters(in: .whitespacesAndNewlines).count
        if inputLength > 0, !reply.isEmpty {
            let ratio = Double(reply.count) / Double(inputLength)
            verdict.lengthRatio = (ratio * 100).rounded() / 100
            if let minimum = fixture.minLengthRatio { verdict.tooShort = ratio < minimum }
            if let maximum = fixture.maxLengthRatio { verdict.tooLong = ratio > maximum }
        }
        return verdict
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
            // Ukrainian's three apostrophes are one, as the Dictionary treats them.
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
    }

    static func cyrillicShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }
        return Double(cyrillic.count) / Double(letters.count)
    }

    static func leaksReasoning(_ text: String) -> Bool {
        ["<think>", "</think>", "<|channel", "<channel|>", "<|message|>", "<|start|>", "<|end|>", "<|im_", "<turn|>", "<|turn>"]
            .contains { text.contains($0) }
    }

    /// Words a reply opens with when the model talks to the user instead of writing the
    /// text. Only when the input does not open with the same word: «Ось що я думаю» is a
    /// dictation, not a preamble.
    static let preambleOpenings = [
        "here is", "here's", "sure", "certainly", "of course", "okay, here", "below is",
        "ось", "звісно", "звичайно", "ось ваш", "ось текст",
    ]

    static func preamble(of reply: String, input: String) -> String? {
        let opening = fold(reply).prefix(40)
        let source = fold(input.trimmingCharacters(in: .whitespacesAndNewlines))
        for phrase in preambleOpenings.sorted(by: { $0.count > $1.count }) {
            guard opening.hasPrefix(phrase) else { continue }
            let next = opening.dropFirst(phrase.count).first
            guard next == nil || !(next!.isLetter) else { continue }
            if source.hasPrefix(phrase) { return nil }
            return phrase
        }
        return nil
    }

    static func isWrappedInQuotes(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return false }
        let pairs: [Character: Character] = ["\"": "\"", "«": "»", "“": "”", "„": "“", "'": "'"]
        return pairs[first] == last
    }

    /// Markdown that only renders where the app knows it does: headings, bold, tables, code
    /// fences. `- ` and numbered lists, and inline `code`, read the same either way.
    static func richMarkdown(in text: String) -> [String] {
        var found: [String] = []
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: { $0.range(of: #"^\s{0,3}#{1,6}\s+\S"#, options: .regularExpression) != nil }) {
            found.append("heading")
        }
        if text.range(of: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#, options: .regularExpression) != nil { found.append("bold") }
        if lines.contains(where: { $0.range(of: #"^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil }) {
            found.append("table")
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) { found.append("fence") }
        return found
    }

    /// `[Your name]`-style gaps the model left — not a Markdown link, and not anything the
    /// input itself had in brackets.
    static func placeholders(in text: String, input: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"\[[^\[\]\n]{2,60}\](?!\()"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }.filter { !input.contains($0) }
    }

    /// Lines that are code rather than prose: a fence, a declaration, an assignment, a line
    /// ending in `{` or `;`.
    static func looksLikeCode(_ text: String) -> Bool {
        let patterns = [
            #"^\s*```"#,
            #"^\s*(func|def|class|struct|enum|import|function|public|private|protocol|extension)\s+\w"#,
            #"^\s*(let|var|const)\s+\w+\s*[=:]"#,
            #"[{;]\s*$"#,
        ]
        return text.components(separatedBy: .newlines).contains { line in
            patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
        }
    }
}
