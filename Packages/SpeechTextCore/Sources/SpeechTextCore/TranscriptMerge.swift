// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Stitching

/// `head + " " + tail`, skipping the space when either side is empty. Both tiers stitch
/// their committed and in-progress text the same way.
public func joinedTranscript(_ head: String, _ tail: String) -> String {
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return head + " " + tail
}

// MARK: - Joining segments

/// The dictionary a segment boundary is checked against. Pure logic cannot reach
/// `NSSpellChecker`, so the app registers it at launch; unregistered (the test target's
/// state, or a Mac with no dictionary for the language) nothing is a word and every
/// boundary keeps its space — exactly the behaviour before this existed.
enum TranscriptJoin {
    /// Set once at launch, before the first dictation reads it (and by the tests, between
    /// their cases), which is what makes the unchecked access safe.
    nonisolated(unsafe) static var isWord: (String) -> Bool = { _ in false }

    /// One-letter words, which a spell checker accepts for *every* letter — so "х" would
    /// otherwise pass as a word and a cut "дани|х" would never be glued back. Ukrainian,
    /// the Russian ones a model slips into mid-dictation, and English. "я" was missing on
    /// the first run over History, which would have glued "Чи | я" into "Чия".
    static let oneLetterWords: Set<String> = [
        "а", "б", "в", "ж", "з", "і", "й", "о", "у", "я",
        "и", "к", "с",
        "a", "i", "o",
    ]
}

/// What goes between two committed segments: a space, or nothing when the provider cut
/// a word in two.
///
/// Scribe's realtime VAD closes a segment on a moment's silence, and a speaker who
/// stumbles inside a word ("дани… х") gets it split — 17.09, "база дани" | "х, звідки".
/// Every boundary used to get a space, so the document and History read "дани х". A
/// boundary is glued only when all of it points that way: the first segment ends in a
/// letter (no punctuation closed it), the next opens with a lowercase letter, the two
/// halves together make a word, and the second half alone does not.
func segmentSeparator(_ previous: String, _ next: String,
                      isWord: (String) -> Bool = TranscriptJoin.isWord) -> String {
    guard let last = previous.last, last.isLetter,
          let first = next.first, first.isLetter, first.isLowercase else { return " " }

    let fragment = String(next.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
    let stem = String(previous.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
    guard !fragment.isEmpty, !stem.isEmpty else { return " " }

    let fragmentIsWord = fragment.count == 1
        ? TranscriptJoin.oneLetterWords.contains(fragment.lowercased())
        : isWord(fragment)
    guard !fragmentIsWord, isWord(stem + fragment) else { return " " }
    return ""
}

/// `head` and the next segment `tail`, joined by `segmentSeparator`.
///
/// One boundary is read past what the provider wrote: a segment that trails off into
/// `...` / `…` straight after a letter. Scribe ends a segment its VAD closed on a pause
/// that way, and opens the next with a capital whether or not a sentence starts there —
/// so a word cut by the pause arrived as "перфо..." | "Ратор." and was pasted in two.
/// There the boundary is judged as if the capital were lowercase, and when the
/// halves glue, the dots go and the second half is written in lowercase: "перфоратор.".
/// Nothing else changes — a capital that continues no cut word keeps its case
/// ("нова... | Версія."), as `cleanedTranscript` keeps the case after the dots it drops.
///
/// Dropping the dots rewrites `head`, which the stream reported before. That is safe for
/// the span layer when hesitations are cleaned, since `cleanedTranscript` drops a
/// trailing `...` anyway and the cleaned text still only grows; with cleaning off the
/// layer sees its committed text rewritten and redraws the segment once.
public func joinedSegments(_ head: String, _ tail: String) -> String {
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    if let stem = trailingOffStem(head) {
        let continuation = lowercasingFirstLetter(tail)
        if segmentSeparator(stem, continuation).isEmpty { return stem + continuation }
    }
    return head + segmentSeparator(head, tail) + tail
}

/// `text` without the `...` / `…` it trails off into, when a letter comes right before
/// the dots — nil otherwise ("так?..", "1...", a bare "...").
private func trailingOffStem(_ text: String) -> String? {
    let stem: Substring
    if text.hasSuffix("…") {
        stem = text.dropLast()
    } else if text.hasSuffix("...") {
        stem = text.dropLast(3)
    } else {
        return nil
    }
    guard let last = stem.last, last.isLetter else { return nil }
    return String(stem)
}

private func lowercasingFirstLetter(_ text: String) -> String {
    guard let first = text.first, first.isUppercase else { return text }
    return first.lowercased() + text.dropFirst()
}

// MARK: - Merging a realtime transcript onto what is already committed

/// Scribe's realtime stream does not always start a clean slate after a commit: the
/// partials that follow — and the next `committed_transcript` itself — can restate the
/// whole accumulated transcript, with its tail extended and its last words revised
/// ("… Що там узагалі нового? Це…" → "… Що там узагалі нового? Це нові задачі?").
/// Joining that onto what was already committed pastes the dictation twice, which is
/// exactly what the user sees. An exact-echo test does not catch it, because the
/// restatement has grown by the time it arrives.
///
/// So text arriving from a stream is *merged* rather than appended: whatever prefix of
/// it repeats what we already hold is dropped, and a restatement of everything replaces
/// it (the server's later version is the better one — it saw more audio).

/// One word of a transcript, normalised for comparison and anchored in its source.
/// Lowercased with the punctuation trimmed off both ends, so "Це…" and "Це" — the same
/// word before and after the server revised the sentence around it — compare equal.
public struct TranscriptWord: Equatable, Sendable {
    /// Lowercased, punctuation-stripped. Never empty.
    let text: String
    /// Where the word starts in the string it was read from.
    let start: String.Index
}

public func transcriptWords(_ text: String) -> [TranscriptWord] {
    text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
        let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard !normalized.isEmpty else { return nil }
        return TranscriptWord(text: normalized, start: token.startIndex)
    }
}

/// How much of `head` the start of `tail` repeats.
///
/// `words` is the number of *`tail`'s* words the repeat takes up — what to drop from
/// `tail` to be left with what it adds. A restatement that revised a word into several
/// (or several into one) takes up a different number of words than `head` holds.
/// `restatesHead` says the repeat covers all of `head`, through its last word, so `tail`
/// is a fuller version of it rather than a continuation that happens to open with the
/// same words.
func transcriptOverlap(head: [TranscriptWord], tail: [TranscriptWord]) -> (words: Int, restatesHead: Bool) {
    guard !head.isEmpty, !tail.isEmpty else { return (0, false) }

    // A restatement of everything, allowing for the odd revised word: the server hears
    // the audio again with more context after it and rewrites a word or two, so an exact
    // prefix test would miss precisely the case that duplicates the dictation.
    if tail.count >= head.count, head[0].text == tail[0].text {
        let matches = zip(head, tail.prefix(head.count)).filter { $0.text == $1.text }.count
        if Double(matches) >= Double(head.count) * TranscriptMergeTuning.restatementAgreement {
            return (head.count, true)
        }
    }

    // The same, when the revision changed the word count. Compared position by position,
    // every word after "FN+Q" → "FN плюс Q" (one word become three) is shifted by two, and
    // a restatement with a single revision reads as 8 matches out of 12 — new speech,
    // joined on, the dictation pasted twice. Held to the unmistakable-repeat floor,
    // because in-order words are far easier to find than words in place: "Так, так"
    // would otherwise be restated by "Так, я сказав так".
    if head.count >= TranscriptMergeTuning.minimumRepeatedWords, head[0].text == tail[0].text,
       let restatement = revisedRestatement(of: head, in: tail) {
        return (restatement.end, restatement.reachesEnd)
    }

    // Otherwise only an unmistakable repeat counts: a run long enough that the user
    // cannot plausibly have said those words twice across a segment boundary.
    let maximum = min(head.count, tail.count)
    guard maximum >= TranscriptMergeTuning.minimumRepeatedWords else { return (0, false) }
    for k in stride(from: maximum, through: TranscriptMergeTuning.minimumRepeatedWords, by: -1)
    where head.suffix(k).map(\.text) == tail.prefix(k).map(\.text) {
        return (k, false)
    }
    return (0, false)
}

/// Where a re-worded restatement of `head` ends inside `tail` — or nil when `tail` is
/// not one.
///
/// Judged by the words' longest common subsequence rather than position by position, so
/// a word revised into three, or three into one, costs only the words it changed. It
/// counts when the subsequence keeps `restatementAgreement` of `head`'s words in order.
///
/// `end` is the number of `tail`'s words the restatement takes up: the shortest prefix
/// holding every match, plus one word for each of `head`'s words after its last match,
/// which were revised into the words that follow rather than dropped. `reachesEnd` is
/// false when `tail` ran out first — a partial that has not caught up with the commit
/// yet, whose words are an echo but must not replace the words it has not reached.
func revisedRestatement(of head: [TranscriptWord], in tail: [TranscriptWord]) -> (end: Int, reachesEnd: Bool)? {
    guard !head.isEmpty, !tail.isEmpty else { return nil }
    let rows = head.count, columns = tail.count

    // lcs[i, j]: common subsequence of head[..<i] and tail[..<j], in one flat buffer.
    let width = columns + 1
    var lcs = [Int](repeating: 0, count: (rows + 1) * width)
    for i in 1...rows {
        for j in 1...columns {
            lcs[i * width + j] = head[i - 1].text == tail[j - 1].text
                ? lcs[(i - 1) * width + (j - 1)] + 1
                : max(lcs[(i - 1) * width + j], lcs[i * width + (j - 1)])
        }
    }

    let best = lcs[rows * width + columns]
    guard best > 0,
          Double(best) >= Double(rows) * TranscriptMergeTuning.restatementAgreement else { return nil }

    let matchedEnd = (0...columns).first { lcs[rows * width + $0] == best } ?? columns
    var i = rows, j = matchedEnd
    var lastMatchedHead = -1
    while i > 0, j > 0 {
        if head[i - 1].text == tail[j - 1].text {
            lastMatchedHead = i - 1
            break
        } else if lcs[(i - 1) * width + j] >= lcs[i * width + (j - 1)] {
            i -= 1
        } else {
            j -= 1
        }
    }
    let end = matchedEnd + (rows - 1 - lastMatchedHead)
    return (min(end, columns), end <= columns)
}

enum TranscriptMergeTuning {
    /// Fraction of `head`'s words a restatement has to reproduce. Below 1.0 because the
    /// server revises words as it gains context; high enough that a genuinely new
    /// sentence opening with the same word is not mistaken for one.
    static let restatementAgreement = 0.8
    /// Shortest repeated run treated as an overlap rather than as speech. Four words of
    /// a partial repeating the tail of the committed text is the server re-sending;
    /// one or two is a person saying "так, так".
    static let minimumRepeatedWords = 4
}

/// `head` with `tail` merged onto it: the repeated opening of `tail` is dropped, and a
/// `tail` that restates all of `head` replaces it.
public func mergedTranscript(_ head: String, _ tail: String) -> String {
    let headWords = transcriptWords(head)
    let tailWords = transcriptWords(tail)
    let overlap = transcriptOverlap(head: headWords, tail: tailWords)
    if overlap.restatesHead { return tail }
    return joinedSegments(head, dropping(overlap.words, from: tail, words: tailWords))
}

/// The part of `text` that is not already in `committed` — what a partial adds to the
/// text the stream has committed so far. Empty when the partial is nothing but an echo.
public func transcriptContinuation(of committed: String, in text: String) -> String {
    transcriptContinuation(of: committed, committedWords: transcriptWords(committed), in: text)
}

/// `transcriptContinuation` with `committed` already tokenised, for a caller that holds
/// the same committed text across many partials.
public func transcriptContinuation(of committed: String, committedWords: [TranscriptWord], in text: String) -> String {
    let textWords = transcriptWords(text)
    let overlap = transcriptOverlap(head: committedWords, tail: textWords)
    return dropping(overlap.words, from: text, words: textWords)
}

private func dropping(_ count: Int, from text: String, words: [TranscriptWord]) -> String {
    guard count > 0 else { return text }
    guard count < words.count else { return "" }
    return String(text[words[count].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
