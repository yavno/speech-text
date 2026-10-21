// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Hesitation sounds, stretched words and trailing-off dots

/// Scribe writes down how something was *said*: "Ой, е-е-е, ні, не привіт", "перше
/// питанняяя", "вона казала... Цей". `no_verbatim=true` is sent and echoed back by the
/// server, and the hesitations still arrive — the flag does not know Ukrainian ones. So
/// the transcript is cleaned on our side, before it becomes a span:
///
/// - a hesitation sound is dropped (`е-е-е`, `а-а`, `еее`, `эм`, `м-м`, `хм`, `uh`, `um`),
///   recognised by its *shape* — one vowel repeated — rather
///   than from a list of spellings. Words that merely sound hesitant ("ну", "типу") are
///   left alone: "типу" is also the genitive of "тип", and removing it rewrites speech;
/// - a word stretched out while thinking is un-stretched: three or more of the same
///   lowercase Cyrillic letter collapse to one ("тооо" → "то"). Ukrainian and Russian
///   spell no word with a tripled letter, and "знання" keeps its double;
/// - a trailing-off `...` / `…` is dropped, whether it ends a word or stands alone
///   between two. No full stop takes its place and the next word keeps its case: Scribe
///   ends a segment its VAD closed on a short pause with one, mid-sentence, and turning
///   it into a full stop cut the sentence in two ("що ми. Зробили").
///
/// The function is applied to the *cumulative* strings the sessions report, and the
/// overlay draws committed spans as they arrive. So it must be **monotone**: when one
/// input extends another by whole words, the cleaned result must extend the cleaned
/// shorter one by whole words too — the span layer takes the difference as a new span
/// and joins spans with a space. Otherwise text already drawn stops being a prefix of
/// the cleaned transcript and is redrawn as a revision. That is why every rule rewrites a word only from the
/// word itself and what came *before* it, and never touches a word already written:
/// a filler's full stop is dropped rather than moved back onto the previous word.
///
/// Growth *inside* a word is outside that contract — "Ой, е" keeps its "е", "Ой, е-е"
/// loses it. It holds because committed text only ever grows by whole segments: the
/// stream merges each VAD-closed `committed_transcript`, and Apple commits at chunk
/// rotation. Partials do grow mid-word, but a partial is issued to no one.
func cleanedTranscript(_ text: String) -> String {
    var output = ""
    /// Set when the next kept word starts a sentence that a removed word began.
    var capitalizeNext = false

    for token in text.split(whereSeparator: { $0.isWhitespace }) {
        var word = String(token)

        // A bare "..." standing between two words goes; any other lone mark ("—") stays.
        if TranscriptCleanupRules.isEllipsis(word) { continue }

        let core = word.trimmingCharacters(in: TranscriptCleanupRules.edgePunctuation)
        if !core.isEmpty, TranscriptCleanupRules.isHesitation(core) {
            // Its punctuation goes with it: "Ой, е-е-е, ні" → "Ой, ні". A full stop it
            // carried is not moved onto the word before — see the monotonicity note.
            // A filler that opened a sentence hands its capital on: "А-а-а, ну" → "Ну".
            if core.first?.isUppercase == true { capitalizeNext = true }
            continue
        }

        word = TranscriptCleanupRules.collapsingStretchedLetters(word)
        if capitalizeNext {
            word = capitalizingFirstLetter(word)
            capitalizeNext = false
        }
        if let trimmed = TranscriptCleanupRules.droppingTrailingEllipsis(word) {
            word = trimmed
        }
        append(word, to: &output)
    }
    return output
}

private func append(_ word: String, to output: inout String) {
    if !output.isEmpty { output += " " }
    output += word
}

private func capitalizingFirstLetter(_ word: String) -> String {
    guard let index = word.firstIndex(where: { $0.isLetter }), word[index].isLowercase else { return word }
    return word.replacingCharacters(in: index...index, with: word[index].uppercased())
}

enum TranscriptCleanupRules {
    /// Punctuation a transcriber hangs on either side of a word, quotes and brackets
    /// included. Hyphens are not in it: "е-е" is one hesitation, not "е" twice.
    static let edgePunctuation: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.remove(charactersIn: "-‐‑")
        return set
    }()

    /// A hesitation's shape, case-insensitive, on a word with its edge punctuation off:
    /// one vowel repeated with hyphens (`е-е`, `а-а-а`) or three times without (`еее`),
    /// optionally trailing into an "m" (`е-м`, `эм`), a hummed `м-м` / `ммм` / `хм`, or an
    /// English `uh` / `um` / `uhm` / `erm` / `hmm`. A single vowel is never one — "а", "у"
    /// are words — and neither is a doubled one: Russian writes "её" as "ее". "ем" (Russian
    /// "I eat") is left alone for the same reason, and so are `мм` / `mm`: millimetres.
    private static let hesitation = try! NSRegularExpression(
        pattern: "^(?:(?:([еэаыу])(?:[-‐‑]\\1)+|([еэаыу])\\2{2,})(?:[-‐‑]?м+)?|е[-‐‑]м+|эм+|х?м(?:[-‐‑]м)+|хм+|м{3,}|u+h+|u+h*m+|e+r+m+|h+m+|m{3,})$",
        options: [.caseInsensitive])

    static func isHesitation(_ core: String) -> Bool {
        let range = NSRange(core.startIndex..., in: core)
        return hesitation.firstMatch(in: core, range: range) != nil
    }

    /// Three or more of the same lowercase Cyrillic letter.
    private static let stretched = try! NSRegularExpression(pattern: "([а-яёіїєґ])\\1{2,}")

    static func collapsingStretchedLetters(_ word: String) -> String {
        let range = NSRange(word.startIndex..., in: word)
        return stretched.stringByReplacingMatches(in: word, range: range, withTemplate: "$1")
    }

    static func isEllipsis(_ word: String) -> Bool {
        word == "…" || (word.count >= 3 && word.allSatisfy { $0 == "." })
    }

    /// An ellipsis ending a word — before any closing quote or bracket — is dropped, and
    /// nothing is put in its place: "?" or "!" before it stays, a full stop is never added.
    /// `1...5` (not at the end) is untouched. nil when there was nothing to drop.
    private static let trailingEllipsis = try! NSRegularExpression(pattern: "(?:\\.{3,}|…)([\"»”’)\\]]*)$")

    static func droppingTrailingEllipsis(_ word: String) -> String? {
        let range = NSRange(word.startIndex..., in: word)
        guard let match = trailingEllipsis.firstMatch(in: word, range: range),
              let whole = Range(match.range, in: word),
              let closers = Range(match.range(at: 1), in: word),
              whole.lowerBound > word.startIndex else { return nil }
        return String(word[..<whole.lowerBound]) + word[closers]
    }
}

// MARK: - Dash style

/// Scribe punctuates like an editor: "Перше — там, де людина…". An em dash in a chat
/// message reads as text a model wrote, not as something typed, so it is redrawn in
/// the style the user picked — the same dash, in the same place, never removed and never
/// guessed at from the words around it: "Книга — це" is a choice, and so is "Книга – це".
///
/// A character swap is safe on cumulative text: the spacing it adds depends only on the
/// characters either side of the dash, and a dash that ends the text gets no space after
/// it until a word follows — which the span layer joins with a space anyway.
public enum DashStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// "–", what the Mac's own keyboard types with ⌥-.
    case enDash
    /// "-", what a keyboard without substitutions produces.
    case hyphen
    /// Leave the transcriber's "—" as it is.
    case emDash

    public static let `default`: DashStyle = .enDash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .enDash: "Short dash ( – )"
        case .hyphen: "Hyphen ( - )"
        case .emDash: "Long dash ( — ), unchanged"
        }
    }

    public static var current: DashStyle {
        UserDefaults.standard.string(forKey: SettingsKeys.dashStyle).flatMap(DashStyle.init(rawValue:)) ?? .default
    }

    /// `text` with every em dash drawn in this style. An em dash glued to a word on
    /// either side ("1914—1918", "word—word") is given spaces, because a short dash
    /// or a hyphen without them reads as a range or a compound. For `.hyphen`, an en
    /// dash standing alone between spaces goes too; one inside "2–5" is a range and stays.
    public func applied(to text: String) -> String {
        guard self != .emDash, text.contains(where: { $0 == "—" || $0 == "–" }) else { return text }
        let dash: Character = self == .enDash ? "–" : "-"
        var output = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "—":
                if let before, !before.isWhitespace { output.append(" ") }
                output.append(dash)
                if let after, !after.isWhitespace { output.append(" ") }
            case "–" where self == .hyphen && (before?.isWhitespace ?? true) && (after?.isWhitespace ?? true):
                output.append(dash)
            default:
                output.append(character)
            }
        }
        return output
    }
}

// MARK: - Characters that disguise themselves

/// Characters a language model writes where the user's keyboard would have written an
/// ordinary one — and which nothing on screen tells apart from it.
///
/// Measured on 2026-09-21: asked to tidy a Ukrainian dictation, a hosted model returned
/// "по‑перше" with **U+2011 NON-BREAKING HYPHEN** in place of the ASCII hyphen it was
/// given, and the reply looked identical to its input. The same dictation carried a
/// shell command; the same substitution inside `git commit -m` or an identifier is a
/// command that fails for no reason the user can see.
///
/// This is therefore a correctness guard and is always applied, unlike `DashStyle`,
/// which offers a choice between three dashes the user can all recognise. The two jobs
/// are kept apart on that line: a dash that reads as a dash belongs to `DashStyle`, and
/// what is handled here is only what passes itself off as an ASCII character, or as
/// nothing at all.
///
/// Deliberately left out:
/// - curly quotes and "…" — visible, ordinary typography, and the user may want them;
/// - U+200D ZERO WIDTH JOINER, which is what holds 👨‍👩‍👧 together as one emoji rather
///   than three people, and U+200C, which separates letters in the scripts that need it;
/// - the en, em and figure dashes, which are visibly dashes and are `DashStyle`'s.
private let confusablePunctuation: [Unicode.Scalar: String] = [
    "\u{2010}": "-",   // HYPHEN — the typographic one, indistinguishable from ASCII
    "\u{2011}": "-",   // NON-BREAKING HYPHEN — measured, see above
    "\u{00A0}": " ",   // NO-BREAK SPACE
    "\u{202F}": " ",   // NARROW NO-BREAK SPACE
    "\u{00AD}": "",    // SOFT HYPHEN — invisible until a line wraps on it
    "\u{200B}": "",    // ZERO WIDTH SPACE
    "\u{FEFF}": "",    // ZERO WIDTH NO-BREAK SPACE, a byte-order mark inside the text
]

/// `text` with every disguised character redrawn as the one it imitates. Each mapping is
/// one scalar to one scalar or to nothing, so no word is joined to its neighbour and none
/// is split.
public func replacingConfusablePunctuation(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { confusablePunctuation[$0] != nil }) else { return text }
    var output = ""
    output.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        if let replacement = confusablePunctuation[scalar] {
            output += replacement
        } else {
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}
