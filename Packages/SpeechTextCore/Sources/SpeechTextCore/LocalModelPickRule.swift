// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One row of the corpus summary (`LocalModelMeasurements.swift`): how a local model did
/// on the speech clips of one language. Numbers only, so the summary can be committed
/// where the run it comes from cannot — no words, no clip names.
public struct LocalSTTMeasurement: Hashable, Sendable {
    public let model: String
    /// `uk`, `en`, or `mixed` for the clips that hold both. `mixed` is kept for a reader
    /// of the summary; it is not a language someone speaks, so no pick reads it.
    public let language: String
    public let clips: Int
    /// Mean word error rate over the clips.
    public let wer: Double
    /// Median seconds from the stop to the text, on a model already loaded.
    public let seconds: Double
    /// The date of the run the row comes from: a model the latest run did not have keeps
    /// the row of the run that did.
    public let run: String
    public let mac: String

    public init(model: String, language: String, clips: Int, wer: Double, seconds: Double, run: String, mac: String) {
        self.model = model
        self.language = language
        self.clips = clips
        self.wer = wer
        self.seconds = seconds
        self.run = run
        self.mac = mac
    }
}

/// The corpus's verdict on a model for one set of languages.
struct LocalSTTScore: Equatable {
    /// The highest WER over the languages, and the language it was in.
    let wer: Double
    let werLanguage: String
    /// The highest latency over the languages.
    let seconds: Double
    /// Clips per language, in the order of the languages, and the Mac each was run on: two
    /// models are compared only on the same clips on the same Mac, so a row kept from a
    /// smaller corpus or someone's faster Mac is not set against this one.
    let clips: [Int]
    let macs: [String]
}

enum LocalSTTPickKind {
    case recommended, bestQuality
}

/// A pick and the numbers behind it. `score` is nil when the pick stands for want of
/// numbers: the reason the Settings sentence then gives is the Mac, not the corpus.
struct LocalSTTPick: Equatable {
    let model: LocalSTTModel
    let score: LocalSTTScore?
}

/// A model's numbers for `languages`, or nil unless it was measured in every one.
/// With no languages stated it is judged on every language the corpus has.
func localSTTScore(_ modelID: String, languages: [String],
                   measurements: [LocalSTTMeasurement]) -> LocalSTTScore? {
    let judged = languages.isEmpty
        ? Set(measurements.map(\.language)).subtracting(["mixed"]).sorted()
        : languages
    let rows = judged.compactMap { language in measurements.first { $0.model == modelID && $0.language == language } }
    guard !rows.isEmpty, rows.count == judged.count,
          let worst = rows.max(by: { $0.wer < $1.wer }),
          let slowest = rows.map(\.seconds).max() else { return nil }
    return LocalSTTScore(wer: worst.wer, werLanguage: worst.language, seconds: slowest, clips: rows.map(\.clips), macs: rows.map(\.mac))
}

/// The rule of #5, as one function so the picks and their explanation cannot disagree.
///
/// The tier's list (`localSTTPicks`) names the standing pick: the first candidate this
/// Mac and these languages allow. The computed pick — *best quality* the lowest
/// worst-language WER, *recommended* the fastest whose WER is within
/// `localPickWERTolerance` of that — takes its place only when it is clearly better than
/// the standing one, so a corpus run's small differences do not move a pick and back.
/// Models are compared only on numbers of the same kind and the same clips: a pick with
/// no numbers stands, and a model with none cannot take a pick. So a Whisper model that
/// was never measured is not displaced by a smaller one that was, and a language the
/// corpus has no recordings of leaves the list as it is.
///
/// A pick only labels a row and pre-selects the model in setup; nothing here writes
/// the stored choice, so someone with a model installed is never moved off it.
func localSTTPick(_ kind: LocalSTTPickKind, for capabilities: SystemCapabilities, languages: [String] = [],
                  measurements: [LocalSTTMeasurement] = localSTTMeasurements) -> LocalSTTPick? {
    let tier = MacTier(capabilities)
    let picks = localSTTPicks(for: tier)
    let list = kind == .recommended ? picks.recommended : picks.bestQuality
    let allowed = pickable(for: capabilities, languages: languages)
    func firstFit(_ ids: [String], in models: [LocalSTTModel]) -> LocalSTTModel? {
        firstFitting(ids, in: models, id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
    }
    guard let standing = firstFit(list, in: allowed) else { return nil }
    // The corpus runs on Apple Silicon: its numbers say nothing about an Intel Mac, whose
    // list is what the hardware allows at all.
    guard tier != .intel,
          let standingScore = localSTTScore(standing.id, languages: languages, measurements: measurements)
    else { return LocalSTTPick(model: standing, score: nil) }

    // The standing pick comes first, and `min(by:)` keeps the first of equals: a tie is
    // not a reason to move.
    let contenders: [(model: LocalSTTModel, score: LocalSTTScore)] = ([standing] + allowed.filter { $0.id != standing.id })
        .filter { firstFit([$0.id], in: [$0]) != nil }
        .compactMap { model in
            localSTTScore(model.id, languages: languages, measurements: measurements).map { (model, $0) }
        }
        .filter { $0.score.clips == standingScore.clips && $0.score.macs == standingScore.macs }
    guard let best = contenders.min(by: { $0.score.wer < $1.score.wer }) else {
        return LocalSTTPick(model: standing, score: standingScore)
    }
    let computed = kind == .bestQuality ? best
        : contenders.filter { $0.score.wer <= best.score.wer * (1 + STTTuning.localPickWERTolerance) }
            .min { $0.score.seconds < $1.score.seconds } ?? best
    let clearlyBetter = computed.score.wer <= standingScore.wer * (1 - STTTuning.localPickWERImprovement)
        || computed.score.seconds <= standingScore.seconds * (1 - STTTuning.localPickLatencyImprovement)
    return clearlyBetter ? LocalSTTPick(model: computed.model, score: computed.score)
                         : LocalSTTPick(model: standing, score: standingScore)
}

/// Why the recommendation landed where it did, in one sentence, for the Settings page.
/// A recommendation the user cannot interrogate is one they have to take on faith.
public func localSTTRecommendationReason(for capabilities: SystemCapabilities, languages: [String] = []) -> String {
    localSTTRecommendationReason(for: capabilities, languages: languages, measurements: localSTTMeasurements)
}

func localSTTRecommendationReason(for capabilities: SystemCapabilities, languages: [String],
                                  measurements: [LocalSTTMeasurement]) -> String {
    guard let pick = localSTTPick(.recommended, for: capabilities, languages: languages, measurements: measurements) else {
        return localized("Not enough free disk space to install any local model.")
    }
    let model = pick.model
    let tier = MacTier(capabilities)
    if tier == .intel {
        return localized("\(model.displayName) — Intel Macs have no Neural Engine, so the larger models run too slowly for dictation.")
    }
    if model.engine == .whisperKit, localSTTModel(id: parakeetV3ModelID)?.knows(languages) == false, !languages.isEmpty {
        return localized("\(model.displayName) — Parakeet does not know every language you speak.")
    }
    // Not with nothing stated: "wrong in Ukrainian" would tell someone who named no language
    // that one of them is the default.
    if let score = pick.score, !languages.isEmpty {
        let percent = Int((score.wer * 100).rounded())
        let language = languageDisplayName(score.werLanguage)
        let seconds = score.seconds.formatted(.number.precision(.fractionLength(1)).locale(numberLocale))
        return localized("\(model.displayName): on our test recordings it got about \(percent)% of the words wrong in \(language) and answered in \(seconds) s.")
    }
    return localized("\(model.displayName) for a \(tier.displayName) Mac.")
}
