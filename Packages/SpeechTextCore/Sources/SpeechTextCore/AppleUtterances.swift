// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Apple's on-device recogniser has said during one request, kept across the two
/// ways its results lose words (found by the e2e harness):
///
/// - **A reset after a pause.** Once the speaker pauses, the recogniser starts a new
///   utterance, and the partials that follow hold only the new words ("Завтра ми поїдемо
///   до моря" → "Якщо"). Taken as a revision, the earlier sentence is gone. A partial that
///   does not continue the one before it is therefore a new utterance, and the earlier one
///   moves into `settled` (`isNewUtterance` says what "continue" means).
/// - **An empty final.** At `endAudio()` the recogniser can answer `isFinal` with no text
///   at all, after partials that had plenty. An empty result never erases words already
///   heard.
///
/// Pure logic, so the rules are tested without `Speech`.
public struct AppleUtterances: Equatable, Sendable {
    /// Utterances the recogniser has moved past.
    public private(set) var settled = ""
    /// The utterance in progress, as the latest partial spells it.
    public private(set) var current = ""

    public init() {}

    public var text: String { joinedTranscript(settled, current) }

    /// Takes one result's `formattedString`.
    public mutating func receive(_ result: String) {
        let incoming = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        if let rest = Self.continuation(of: settled, in: incoming) {
            // A result that spells the earlier utterances again: only what it adds is the
            // current one. `settled` is never shortened — it is committed text, and the
            // span layer only ever extends that.
            current = rest
            return
        }
        if Self.isNewUtterance(incoming, after: current) {
            settled = joinedTranscript(settled, current)
        }
        current = incoming
    }

    /// What `incoming` adds when it begins with every word of `settled`; nil otherwise.
    static func continuation(of settled: String, in incoming: String) -> String? {
        let held = transcriptWords(settled).map(\.text), new = transcriptWords(incoming)
        guard !held.isEmpty, new.count > held.count,
              new.prefix(held.count).map(\.text) == held else { return nil }
        return String(incoming[new[held.count].start...])
    }

    /// A revision keeps the utterance's first word, or a word it grows from or into
    /// ("Кова" → "Коваленко"), and a reset starts shorter than the utterance it follows.
    /// Both must fail before words are kept as a separate utterance: taking a revision for
    /// a reset would paste its words twice.
    ///
    /// A word that begins like the first word is not enough on its own, since a short one
    /// begins half the language: after "I went to the store" and a pause, "It" is a new
    /// sentence, and so is "Але" after "А ми вже вдома". So a word grown or shrunk counts as
    /// the same only while the result spells at least half as many letters as the one it
    /// would replace: the same audio heard again ("За ми" → "Завтра", "I am" → "I'm")
    /// spells about as much, a new utterance starts with a word or two.
    static func isNewUtterance(_ incoming: String, after current: String) -> Bool {
        let old = transcriptWords(current), new = transcriptWords(incoming)
        guard old.count >= 2, let first = old.first?.text, let next = new.first?.text,
              new.count < old.count, first != next else { return false }
        guard first.hasPrefix(next) || next.hasPrefix(first) else { return true }
        return letters(in: new) * 2 < letters(in: old)
    }

    private static func letters(in words: [TranscriptWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count }
    }
}

/// When a chunk whose recognition task failed after the segment already had words is
/// replaced. A task that reported an error takes no more audio, so every word said until
/// the next chunk starts is lost — up to the whole 50 s rotation
/// (`AppleRecognitionSession.rotate`). The session therefore starts a fresh chunk at once,
/// within two bounds, because a fresh chunk can fail again straight away (its assets
/// gone, a recogniser in a bad state) and a rotation must never become a loop of new tasks:
///
/// - **No chunk is replaced before it has lived `minimumChunkSeconds` (1 s).** A failure
///   sooner than that is rotated once the second is up — deferred, not refused — so the
///   session asks for at most one new task a second however fast its chunks fail, and a
///   chunk that heard words and then failed early costs a second of speech, not the rest
///   of its 50 s.
/// - **`barrenRotationLimit` (3) error rotations in a row whose failed chunk heard no words
///   of its own are allowed; the next such failure is left to the 50 s rotation already
///   armed** — the behaviour from before — until a chunk hears words again, which resets
///   the count (`heardWords`). Three fresh tasks a second apart that each died without a
///   word mean the recogniser is not recovering by itself; more would only churn, while
///   the 50 s rotation still gives it a fresh try every 50 s.
///
/// Pure logic: the session hands in its clock (`systemUptime`), the tests
/// a fake one.
public struct AppleErrorRotation: Equatable, Sendable {
    static let minimumChunkSeconds: TimeInterval = 1
    public static let barrenRotationLimit = 3

    public enum Decision: Equatable, Sendable {
        /// Start a fresh chunk this many seconds from now; 0 is at once.
        case rotate(after: TimeInterval)
        /// Leave the dead chunk to the 50 s rotation.
        case leaveToTimer
        /// Paused, finishing or cancelled: nothing is fed any more, so there is nothing to
        /// rotate to.
        case notFeeding
    }

    /// Error rotations in a row whose failed chunk had heard no words of its own.
    public private(set) var barrenRotations = 0
    /// When the current chunk started; nil before the first.
    private var chunkStart: TimeInterval?
    private var chunkHasWords = false
    /// An error rotation was decided and its chunk has not started yet.
    private var errorRotationPending = false
    /// The current chunk was started by an error rotation.
    private var chunkFollowsError = false

    public init() {}

    /// Every chunk's start: the session's first, and every rotation's, the timer's too.
    public mutating func chunkStarted(at now: TimeInterval) {
        chunkStart = now
        chunkHasWords = false
        chunkFollowsError = errorRotationPending
        errorRotationPending = false
    }

    /// The current chunk has heard words: the recogniser works, so the run of barren
    /// rotations is over. True only for the first words of a chunk an error rotation
    /// started — the proof that the rotation brought the dictation back.
    @discardableResult
    public mutating func heardWords() -> Bool {
        let first = chunkFollowsError && !chunkHasWords
        chunkHasWords = true
        barrenRotations = 0
        return first
    }

    /// The current chunk's task failed while the segment had words.
    public mutating func decide(at now: TimeInterval, isFeeding: Bool) -> Decision {
        guard isFeeding else { return .notFeeding }
        if !chunkHasWords {
            guard barrenRotations < Self.barrenRotationLimit else { return .leaveToTimer }
            barrenRotations += 1
        }
        errorRotationPending = true
        let age = chunkStart.map { now - $0 } ?? Self.minimumChunkSeconds
        return .rotate(after: max(0, Self.minimumChunkSeconds - age))
    }
}
