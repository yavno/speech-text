// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// The audio corpus: what a clip is expected to produce, how an engine's answer is
// judged, and the run's report. Pure logic, shared by `LiveProviderTests` (the cloud
// engines) and the `SpeechTextEvaluation` command-line tool (the local ones), so both
// halves of a run are judged by the same rules and land in the same table.
//
// The clips' descriptions are committed in `SpeechTextTests/Audio/<name>.json`; the audio
// is not. It is the maintainer's voice and the repository is public, so the WAVs live
// outside it and a run finds them through `SPEECHTEXT_CORPUS=<dir>` (`<dir>/<name>.wav`).
// One description may have several recordings — `<name>@<variant>.wav`, another
// microphone (`@builtin`) or another way of saying it (`@casual`) — each its own row.

// MARK: - Clips

struct CorpusClip: Codable, Equatable {
    /// The description's name — the file's without `.json` — and, for a recording of it
    /// other than `<name>.wav`, `@` and the variant: the row's name.
    var name = ""
    /// The recording's variant (`builtin` for `uk-pause@builtin.wav`); nil for `<name>.wav`.
    var variant: String?
    /// What was said. Empty for a clip that should produce nothing: silence, or a
    /// press-and-release too short to be speech.
    var expected: String
    /// `uk`, `en`, or `mixed` — what the output's alphabet is checked against.
    var language: String
    var tags: [String]?
    /// The word error rate above which the clip fails. Nil reports the rate without
    /// judging it: a bound is set from a baseline run on the real recording, not guessed.
    var maxWER: Double?
    /// Languages to force on the engines as extra passes, beside the Auto pass every
    /// clip gets (`["uk"]`: Ukrainian named, and English forced to it).
    var forcedLanguages: [String]?
    var note: String?
    /// Another recording this clip is cut from, and how much of its start — so the
    /// silence clips come out of one `room-tone.wav` rather than a 0.2 s recording that
    /// would hold nothing but the click of stopping it.
    var source: String?
    var seconds: Double?
    /// The words a user would put in the Dictionary for this clip. A clip that has them
    /// gets one more pass with them as the Dictionary (does Groq's `prompt` help or
    /// echo?).
    var vocabulary: [String]?
    /// "Languages I speak", stated with nothing forced (two or more, as the owner runs the
    /// app): one more pass, Auto with these stated — what the script rule in
    /// `HallucinationFilter` is judged against.
    var spokenLanguages: [String]?

    /// The description this row comes from.
    var descriptionName: String { variant.map { name.dropLast($0.count + 1) }.map(String.init) ?? name }

    /// The WAV this clip is played from.
    var audioFile: String { source.map { $0 + ".wav" } ?? name + ".wav" }

    var expectsNothing: Bool { expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private enum CodingKeys: String, CodingKey {
        case expected, language, tags, maxWER, forcedLanguages, note, source, seconds, vocabulary, spokenLanguages
    }

    /// Every clip description in `directory`, by name.
    static func load(from directory: URL) throws -> [CorpusClip] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { url in
            var clip = try JSONDecoder().decode(CorpusClip.self, from: Data(contentsOf: url))
            clip.name = url.deletingPathExtension().lastPathComponent
            return clip
        }
    }

    /// One row per recording of each description in `corpus`: `<name>.wav` and every
    /// `<name>@<variant>.wav`. A description with no recording at all keeps its one row,
    /// which reports `no audio`; one cut from another recording (`source`) has no variants.
    static func recordings(of clips: [CorpusClip], in corpus: URL) -> [CorpusClip] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? []
        let stems = Set(files.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) })
        return clips.flatMap { clip -> [CorpusClip] in
            guard clip.source == nil else { return [clip] }
            let variants = stems.filter { $0.hasPrefix(clip.name + "@") }.sorted()
            var rows = stems.contains(clip.name) ? [clip] : []
            for stem in variants {
                var row = clip
                row.name = stem
                row.variant = String(stem.dropFirst(clip.name.count + 1))
                rows.append(row)
            }
            return rows.isEmpty ? [clip] : rows
        }
    }

    /// Whether a run's list of names (`SPEECHTEXT_CLIPS`, `--clips`) takes this row: by its
    /// own name (`uk-pause@builtin`) or its description's (`uk-pause`, every recording).
    func isSelected(by names: [String]) -> Bool {
        names.isEmpty || names.contains(name) || names.contains(descriptionName)
    }

    /// The Auto pass first, then each forced language, then — for a clip with a
    /// vocabulary — Auto again with it as the Dictionary, then Auto with the clip's
    /// spoken languages stated.
    var passes: [CorpusPass] {
        [CorpusPass(language: nil)] + (forcedLanguages ?? []).map { CorpusPass(language: $0) }
            + (vocabulary?.isEmpty == false ? [CorpusPass(language: nil, dictionary: true)] : [])
            + (spokenLanguages?.isEmpty == false ? [CorpusPass(language: nil, stated: spokenLanguages ?? [])] : [])
    }

    /// The clip's vocabulary as Dictionary entries, as a user would add them: the word,
    /// nothing it replaces.
    var dictionaryEntries: [VocabularyEntry] {
        (vocabulary ?? []).map { VocabularyEntry(term: $0) }
    }
}

/// One way a clip is run: Auto or a forced language, with or without its Dictionary, or
/// Auto with several languages stated.
struct CorpusPass: Equatable {
    var language: String?
    var dictionary = false
    /// The languages stated, none of them forced; empty for every other pass.
    var stated: [String] = []

    /// The results' and the summary's name for it: `auto`, `uk`, `auto + dictionary`,
    /// `uk+en`.
    var label: String {
        stated.isEmpty ? (language ?? "auto") + (dictionary ? " + dictionary" : "") : stated.joined(separator: "+")
    }
}

// MARK: - Measures

enum CorpusMeasure {
    /// Lower-cased words with punctuation dropped and every apostrophe spelled one way,
    /// so "Прив'язка" and "Привʼязка," are the same word. Hyphens inside a word are kept.
    static func words(_ text: String) -> [String] {
        let apostrophes: Set<Character> = ["'", "’", "ʼ", "`", "‘"]
        var normalised = ""
        for character in text.lowercased() {
            if apostrophes.contains(character) {
                normalised.append("'")
            } else if character.isLetter || character.isNumber || character == "-" {
                normalised.append(character)
            } else {
                normalised.append(" ")
            }
        }
        return normalised.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty }
    }

    /// Word-level edit distance over the reference's length: 0 is exact, 1 is as many
    /// errors as there are words. Nil when there is no reference to measure against.
    static func wordErrorRate(expected: String, actual: String) -> Double? {
        let reference = words(expected)
        let hypothesis = words(actual)
        guard !reference.isEmpty else { return nil }
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, candidate) in hypothesis.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1,
                                     previous[j] + (word == candidate ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    /// The words the output got wrong in place, as `said → written`, from the same
    /// alignment as the error rate. The alphabet check only sees an answer written wholly
    /// in the wrong one; a single Russian-spelled word inside Ukrainian («привіт →
    /// привет») shows up here, for a reader of the run.
    static func substitutions(expected: String, actual: String) -> [String] {
        let reference = words(expected)
        let hypothesis = words(actual)
        guard !reference.isEmpty, !hypothesis.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: hypothesis.count + 1), count: reference.count + 1)
        for i in 0...reference.count { table[i][0] = i }
        for j in 0...hypothesis.count { table[0][j] = j }
        for i in 1...reference.count {
            for j in 1...hypothesis.count {
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1,
                                  table[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
            }
        }
        var pairs: [String] = []
        var (i, j) = (reference.count, hypothesis.count)
        while i > 0, j > 0 {
            let same = reference[i - 1] == hypothesis[j - 1]
            if table[i][j] == table[i - 1][j - 1] + (same ? 0 : 1) {
                if !same { pairs.append("\(reference[i - 1]) → \(hypothesis[j - 1])") }
                i -= 1
                j -= 1
            } else if table[i][j] == table[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Runs of `n` words that the output holds more often than the speaker said them —
    /// the shape of a restatement joined on as new speech. Counted against the
    /// expected text, so a phrase really said twice is not flagged.
    static func repeatedPhrases(expected: String, actual: String, n: Int = 4) -> [String] {
        func counts(_ words: [String]) -> [String: Int] {
            guard words.count >= n else { return [:] }
            var counts: [String: Int] = [:]
            for start in 0...(words.count - n) {
                counts[words[start..<start + n].joined(separator: " "), default: 0] += 1
            }
            return counts
        }
        let said = counts(words(expected))
        return counts(words(actual))
            .filter { $0.value > 1 && $0.value > said[$0.key, default: 0] }
            .map(\.key)
            .sorted()
    }

    /// Two sentences joined at a segment boundary with no space between them
    /// (`перевірка.Закінчую`): a letter straight after `.`, `!`, `?` or `,` that follows a
    /// letter. What the expected text itself holds that way (`Node.js`) is not counted.
    static func gluedSentences(expected: String, actual: String) -> [String] {
        func glued(_ text: String) -> [String] {
            let characters = Array(text)
            var found: [String] = []
            for index in characters.indices.dropFirst().dropLast()
            where ".!?,".contains(characters[index]) && characters[index - 1].isLetter && characters[index + 1].isLetter {
                var start = index - 1
                while start > 0, characters[start - 1].isLetter { start -= 1 }
                var end = index + 1
                while end + 1 < characters.count, characters[end + 1].isLetter { end += 1 }
                found.append(String(characters[start...end]))
            }
            return found
        }
        let said = Set(glued(expected))
        return glued(actual).filter { !said.contains($0) }
    }

    /// A phrase a model answers silence with (`HallucinationFilter`) anywhere in the
    /// output — the filter drops only a short segment that is *nothing but* one, so a
    /// sign-off after real words reaches the paste. Phrases the expected text holds are
    /// not counted.
    static func knownHallucinations(expected: String, actual: String) -> [String] {
        let said = " " + HallucinationFilter.normalized(expected) + " "
        let written = " " + HallucinationFilter.normalized(actual) + " "
        return (HallucinationFilter.phrases.sorted() + HallucinationFilter.prefixes)
            .filter { written.contains(" \($0) ") && !said.contains(" \($0) ") }
    }

    /// Whether the output is written in the clip's language, judged by its letters. On a
    /// short dictation that is more reliable than a statistical recogniser, and the
    /// failure seen in practice is exactly an alphabet one: Ukrainian answered in Russian
    /// spelling. Nil when there is nothing to judge (a mixed clip, or no text).
    static func languageProblem(language: String, actual: String) -> String? {
        let letters = actual.lowercased().filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        let cyrillic = letters.filter { $0.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
        switch language {
        case "uk":
            let russian = Set("ыэъё").intersection(letters)
            if !russian.isEmpty { return "Russian letters \(String(russian.sorted()))" }
            if cyrillic.count * 2 < letters.count { return "mostly not Cyrillic" }
            return nil
        case "en":
            return cyrillic.isEmpty ? nil : "Cyrillic in English"
        default:
            return nil
        }
    }
}

// MARK: - Results

/// One clip through one engine in one language.
struct CorpusResult: Codable, Equatable {
    enum Status: String, Codable {
        /// The engine answered (with text, nothing, or an error it reported).
        case ran
        /// The engine needs a key the environment did not supply.
        case noKey = "no key"
        /// A local model that is not on this Mac.
        case notInstalled = "not installed"
        /// The clip's WAV is not in the corpus directory.
        case noAudio = "no audio"
    }

    /// Which half of a streaming session answered.
    enum Path: String, Codable {
        case stream
        /// The stream broke or came back empty, and the upload answered.
        case fallback
        case upload
        case onDevice = "on device"
    }

    /// The row's name: the description's, with `@variant` for another recording of it.
    var clip: String
    /// `vendor/model`.
    var engine: String
    var engineName: String
    /// The pass: `auto`, the forced language, `auto + dictionary` (`CorpusPass.label`).
    var language: String
    var status: Status
    var path: Path?
    /// What the stop would have pasted — nil when it pasted nothing.
    var pasted: String?
    var error: String?
    var wordErrorRate: Double?
    /// From the first buffer to the first text on the overlay.
    var firstPartialSeconds: Double?
    /// From the stop to the text that would be pasted.
    var stopToTextSeconds: Double?
    /// A local model's load, kept out of `stopToTextSeconds`.
    var loadSeconds: Double?
    /// Words written in place of the ones said (`CorpusMeasure.substitutions`).
    var substitutions: [String] = []
    /// Every check the result failed. Empty is a pass.
    var failures: [String] = []
    /// The clip as it was run — what was said, and a digest of its recording — so a later
    /// run can tell a clip that changed from an engine that did. Nil in runs before runs were compared.
    var expected: String?
    var audioDigest: String?
    /// What the voice activity detector made of the clip: its highest window and
    /// how many windows were over `STTTuning.voiceProbabilityThreshold` — so a run shows
    /// the margin, not only whether the clip was sent. Nil where no detector ran (the test
    /// bundle, which cannot load it).
    var voiceProbability: Double?
    var voiceWindows: Int?

    var passed: Bool { status != .ran || failures.isEmpty }
}

enum CorpusChecks {
    /// What each failure message is a failure *of*, by how it begins: a run compared with
    /// an earlier one asks which checks newly fail, and the earlier run kept only the
    /// messages. A message no prefix matches is its own kind, so a check added later reads
    /// as newly failing rather than being missed.
    static let kinds: [(prefix: String, kind: String)] = [
        ("pasted ", "pasted for nothing"),
        ("nothing pasted", "nothing pasted"),
        ("repeated:", "repeated"),
        ("WER ", "WER over its bound"),
        ("Russian letters", "language"),
        ("mostly not Cyrillic", "language"),
        ("Cyrillic in English", "language"),
        ("glued:", "glued"),
        ("hallucination:", "hallucination"),
    ]

    static func kind(of failure: String) -> String {
        kinds.first { failure.hasPrefix($0.prefix) }?.kind ?? failure
    }

    /// The issue's checks: nothing pasted for silence or a press shorter than a word,
    /// something pasted for speech, no phrase doubled, the word error rate within the
    /// clip's bound, and the output in the clip's language.
    static func failures(clip: CorpusClip, clipSeconds: Double, pasted: String?, error: String?) -> [String] {
        var failures: [String] = []
        let text = pasted ?? ""
        if clip.expectsNothing || clipSeconds < STTTuning.minimumSegmentSeconds {
            if pasted != nil { failures.append("pasted “\(text)” for a clip that should produce nothing") }
            return failures
        }
        if pasted == nil {
            failures.append(error.map { "nothing pasted: \($0)" } ?? "nothing pasted")
            return failures
        }
        let repeated = CorpusMeasure.repeatedPhrases(expected: clip.expected, actual: text)
        if !repeated.isEmpty {
            failures.append("repeated: " + repeated.map { "“\($0)”" }.joined(separator: ", "))
        }
        if let bound = clip.maxWER, let rate = CorpusMeasure.wordErrorRate(expected: clip.expected, actual: text),
           rate > bound {
            failures.append(String(format: "WER %.2f over %.2f", rate, bound))
        }
        if let problem = CorpusMeasure.languageProblem(language: clip.language, actual: text) {
            failures.append(problem)
        }
        let glued = CorpusMeasure.gluedSentences(expected: clip.expected, actual: text)
        if !glued.isEmpty {
            failures.append("glued: " + glued.map { "“\($0)”" }.joined(separator: ", "))
        }
        let invented = CorpusMeasure.knownHallucinations(expected: clip.expected, actual: text)
        if !invented.isEmpty {
            failures.append("hallucination: " + invented.map { "“\($0)”" }.joined(separator: ", "))
        }
        return failures
    }
}

// MARK: - The run's files

/// A run's folder, outside the repository — under the folder `SPEECHTEXT_RUNS` names:
/// each runner's results as JSON, the traces the streaming engines produced, and
/// `summary.md` rendered from every result present — so the cloud half and the local
/// half of one run end in one table, whichever finished last. A run holds what the
/// engines heard in someone's voice, so it is never committed.
struct CorpusRunFolder {
    let url: URL
    /// The run this one is compared with (`previous(in:before:)`); nil compares nothing.
    var baseline: URL?

    init(url: URL, baseline: URL? = nil) {
        self.url = url
        self.baseline = baseline
    }

    var traces: URL { url.appendingPathComponent("traces", isDirectory: true) }

    /// Where runs are kept: `SPEECHTEXT_RUNS`, else the folder holding the run that
    /// `SPEECHTEXT_RUN_DIR` adds to; nil when neither is set.
    static func runs(environment: [String: String]) -> URL? {
        if let runs = environment["SPEECHTEXT_RUNS"], !runs.isEmpty {
            return URL(fileURLWithPath: runs, isDirectory: true)
        }
        if let run = environment["SPEECHTEXT_RUN_DIR"], !run.isEmpty {
            return URL(fileURLWithPath: run, isDirectory: true).deletingLastPathComponent()
        }
        return nil
    }

    /// A new folder named for now, under `runs`.
    static func new(in runs: URL, now: Date = Date()) -> CorpusRunFolder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return CorpusRunFolder(url: runs.appendingPathComponent(formatter.string(from: now), isDirectory: true))
    }

    /// Writes one runner's results (`results-cloud.json`, `results-local.json`) and
    /// re-renders the summary from every results file in the folder.
    func write(_ results: [CorpusResult], runner: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: resultsFile(runner), options: .atomic)
        let comparison = try baseline.map {
            CorpusComparison(try allResults(), previous: try CorpusRunFolder(url: $0).allResults(),
                             baseline: $0.lastPathComponent)
        }
        try CorpusSummary.render(allResults(), comparison: comparison)
            .write(to: url.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    /// The latest run in `runs` — a folder with results — other than `current`, and,
    /// when `current` is itself one of them (a run added to with `SPEECHTEXT_RUN_DIR`),
    /// one named before it: the run a new one is judged against.
    static func previous(in runs: URL, before current: URL) -> CorpusRunFolder? {
        let current = current.resolvingSymlinksInPath()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? [])
            .filter { name in
                let files = (try? FileManager.default.contentsOfDirectory(atPath: runs.appendingPathComponent(name).path)) ?? []
                return files.contains { $0.hasPrefix("results-") && $0.hasSuffix(".json") }
            }
        let inside = current.deletingLastPathComponent().path == runs.resolvingSymlinksInPath().path
        return names
            .filter { !inside || $0 < current.lastPathComponent }
            .sorted()
            .last
            .map { CorpusRunFolder(url: runs.appendingPathComponent($0, isDirectory: true)) }
    }

    /// What this runner already wrote here, less the rows of the clips about to run
    /// again — so a clip recorded after a run is added to it, or one re-recorded
    /// replaced, without running the whole corpus a second time.
    func earlierResults(runner: String, except clips: [CorpusClip]) -> [CorpusResult] {
        let running = Set(clips.map(\.name))
        guard let data = try? Data(contentsOf: resultsFile(runner)),
              let results = try? JSONDecoder().decode([CorpusResult].self, from: data) else { return [] }
        return results.filter { !running.contains($0.clip) }
    }

    private func resultsFile(_ runner: String) -> URL {
        url.appendingPathComponent("results-\(runner).json")
    }

    func allResults() throws -> [CorpusResult] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("results-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { try JSONDecoder().decode([CorpusResult].self, from: Data(contentsOf: $0)) }
    }
}

/// The part of a run that is committed: WER and latency per local model and language
/// (`LocalModelMeasurements.swift`), from which `localSTTPick` chooses. Only the numbers —
/// a run's words and clip names stay in the run. WER from the Auto pass, because every clip
/// has it and nobody's language list is assumed; latency from the pass after it, on the same
/// clip, because Auto is the first pass after the runner swaps models and carries a cold-model
/// cost someone with one model loaded never pays: on 2026-11-09 (M1 Pro, English) v3 took
/// 0.39 s and Phonon-2 0.60 s in Auto, and 0.24 s and 0.24 s in the warm pass. The speech
/// clips, because silence has no words to get wrong. A rerun for one model replaces that
/// model's rows and leaves the others'.
enum CorpusMeasurementSummary {
    static let werPass = "auto"
    static let latencyPass = "uk+en"
    static let file = "Packages/SpeechTextCore/Sources/SpeechTextCore/LocalModelMeasurements.swift"

    static func rows(from results: [CorpusResult], descriptions: [CorpusClip], run: String, mac: String) -> [LocalSTTMeasurement] {
        let language = Dictionary(uniqueKeysWithValues: descriptions.map { ($0.name, $0) })
        var cells: [String: [String: [(wer: Double, seconds: Double)]]] = [:]
        let local = results.filter { $0.status == .ran && $0.engine.hasPrefix("local/") }
        let warm = Dictionary(local.filter { $0.language == latencyPass }.map { ("\($0.engine) \($0.clip)", $0.stopToTextSeconds) },
                              uniquingKeysWith: { first, _ in first })
        for result in local where result.language == werPass {
            let name = String(result.clip.prefix { $0 != "@" })
            guard let clip = language[name], !clip.expectsNothing,
                  let wer = result.wordErrorRate, let seconds = warm["\(result.engine) \(result.clip)"] ?? nil else { continue }
            cells[String(result.engine.dropFirst("local/".count)), default: [:]][clip.language, default: []].append((wer, seconds))
        }
        return cells.flatMap { model, languages in
            languages.map { language, clips in
                let seconds = clips.map(\.seconds).sorted()
                let middle = seconds.count / 2
                let median = seconds.count % 2 == 1 ? seconds[middle] : (seconds[middle - 1] + seconds[middle]) / 2
                return LocalSTTMeasurement(model: model, language: language, clips: clips.count,
                                           wer: clips.map(\.wer).reduce(0, +) / Double(clips.count), seconds: median, run: run, mac: mac)
            }
        }
    }

    /// `new`, and the rows of every model `new` has nothing for.
    static func merged(_ new: [LocalSTTMeasurement], into earlier: [LocalSTTMeasurement]) -> [LocalSTTMeasurement] {
        let measured = Set(new.map(\.model))
        return (new + earlier.filter { !measured.contains($0.model) })
            .sorted { ($0.model, $0.language) < ($1.model, $1.language) }
    }

    static func source(_ rows: [LocalSTTMeasurement]) -> String {
        let lines = rows.map { row in
            String(format: "    LocalSTTMeasurement(model: \"%@\", language: \"%@\", clips: %d, wer: %.3f, seconds: %.3f, run: \"%@\", mac: \"%@\"),",
                   row.model, row.language, row.clips, row.wer, row.seconds, row.run, row.mac)
        }
        return """
        // SPDX-FileCopyrightText: 2026 Vladyslav Husakov
        // SPDX-License-Identifier: GPL-3.0-or-later

        // Written by `scripts/evaluate.sh`; do not edit by hand (docs/audio-corpus.md). Each row
        // is one local model on the speech clips of one language: mean word error rate (Auto
        // pass) and median seconds from the stop to the text (the warm pass after it).

        /// What `localSTTPick` chooses from. A model with no row is not compared at all.
        public let localSTTMeasurements: [LocalSTTMeasurement] = [
        \(lines.joined(separator: "\n"))
        ]

        """
    }
}

/// A run against the one before it: each cell — clip × engine × pass — judged
/// against the same cell's earlier result, so every engine is held to its own past and
/// no bound is set by hand. Worse is a word error rate up by more than 0.10, or a check
/// that newly fails; better is the reverse. A cell the earlier run did not have is new,
/// and one whose clip changed since — its text or its recording — is not compared.
struct CorpusComparison {
    struct Change: Equatable {
        var result: CorpusResult
        var previous: CorpusResult
        var reasons: [String]
    }

    /// The earlier run's folder name.
    var baseline: String
    var worse: [Change] = []
    var better: [Change] = []
    var new: [CorpusResult] = []
    /// Cells whose clip changed since the earlier run: compared, they would judge the clip.
    var changedClips: [CorpusResult] = []

    /// More than this much — in the two decimals the table shows — is a change.
    static let werStep = 10

    init(_ results: [CorpusResult], previous: [CorpusResult], baseline: String) {
        self.baseline = baseline
        var earlier: [String: CorpusResult] = [:]
        for result in previous { earlier[Self.key(result)] = result }
        for result in results where result.status == .ran {
            guard let before = earlier[Self.key(result)], before.status == .ran else {
                new.append(result)
                continue
            }
            if Self.clipChanged(result, since: before) {
                changedClips.append(result)
                continue
            }
            var worse: [String] = []
            var better: [String] = []
            if let now = result.wordErrorRate.map(Self.hundredths),
               let then = before.wordErrorRate.map(Self.hundredths) {
                let reason = String(format: "WER %.2f → %.2f", Double(then) / 100, Double(now) / 100)
                if now - then > Self.werStep { worse.append(reason) }
                if then - now > Self.werStep { better.append(reason) }
            }
            let failing = Self.kinds(result.failures)
            let failed = Self.kinds(before.failures)
            let newlyFailing = failing.filter { !failed.contains($0) }
            let newlyPassing = failed.filter { !failing.contains($0) }
            if !newlyFailing.isEmpty { worse.append("newly fails: " + newlyFailing.joined(separator: ", ")) }
            if !newlyPassing.isEmpty { better.append("passes again: " + newlyPassing.joined(separator: ", ")) }
            if !worse.isEmpty {
                self.worse.append(Change(result: result, previous: before, reasons: worse + better))
            } else if !better.isEmpty {
                self.better.append(Change(result: result, previous: before, reasons: better))
            }
        }
    }

    /// `▼` for a cell that got worse, `▲` for one that got better, nil otherwise.
    func mark(for result: CorpusResult) -> String? {
        let key = Self.key(result)
        if worse.contains(where: { Self.key($0.result) == key }) { return "▼" }
        if better.contains(where: { Self.key($0.result) == key }) { return "▲" }
        return nil
    }

    private static func key(_ result: CorpusResult) -> String {
        [result.clip, result.engine, result.language].joined(separator: "\u{1F}")
    }

    private static func hundredths(_ rate: Double) -> Int { Int((rate * 100).rounded()) }

    private static func kinds(_ failures: [String]) -> [String] {
        var kinds: [String] = []
        for kind in failures.map(CorpusChecks.kind(of:)) where !kinds.contains(kind) { kinds.append(kind) }
        return kinds
    }

    /// The clip's text or recording differs from the earlier run's. A run from before
    /// either was kept says nothing about its recording, but its text can still be told
    /// apart: the earlier answer measured against today's text gives another rate.
    static func clipChanged(_ result: CorpusResult, since before: CorpusResult) -> Bool {
        if let now = result.audioDigest, let then = before.audioDigest, now != then { return true }
        if let now = result.expected, let then = before.expected { return now != then }
        if let now = result.expected, let then = before.wordErrorRate,
           let remeasured = CorpusMeasure.wordErrorRate(expected: now, actual: before.pasted ?? "") {
            return hundredths(remeasured) != hundredths(then)
        }
        return false
    }
}

enum CorpusSummary {
    /// The engine × clip table (one per language pass), then every result in full —
    /// with, given a comparison, what changed since the earlier run ahead of the tables.
    static func render(_ results: [CorpusResult], comparison: CorpusComparison? = nil) -> String {
        var engines: [(id: String, name: String)] = []
        for result in results where !engines.contains(where: { $0.id == result.engine }) {
            engines.append((result.engine, result.engineName))
        }
        let clipNames = Set(results.map(\.clip)).sorted()
        var languages: [String] = []
        for result in results where !languages.contains(result.language) { languages.append(result.language) }

        var out = "# Corpus run\n\n"
        let ran = results.filter { $0.status == .ran }
        out += "\(ran.count) results, \(ran.filter { !$0.failures.isEmpty }.count) failed. "
        out += "Each cell: WER · first text on the overlay · stop to text. ❌ marks a failed check "
        out += "(listed below); ↩ a streaming engine whose upload answered instead.\n"
        if let comparison { out += render(comparison, engines: engines) }

        for language in languages {
            out += "\n## Language: \(language)\n\n"
            out += "| Clip | " + engines.map(\.name).joined(separator: " | ") + " |\n"
            out += "|---|" + engines.map { _ in "---|" }.joined() + "\n"
            for clip in clipNames {
                let cells = engines.map { engine -> String in
                    guard let result = results.first(where: {
                        $0.clip == clip && $0.engine == engine.id && $0.language == language
                    }) else { return "" }
                    return cell(result, mark: comparison?.mark(for: result))
                }
                out += "| \(clip) | " + cells.joined(separator: " | ") + " |\n"
            }
        }

        out += "\n## Every result\n\n"
        for result in results {
            out += "- **\(result.clip)** · \(result.engineName) · \(result.language) — \(result.status.rawValue)"
            if let path = result.path { out += ", \(path.rawValue)" }
            if let load = result.loadSeconds { out += String(format: ", load %.1f s", load) }
            out += "\n"
            if let pasted = result.pasted { out += "  - pasted: \(pasted)\n" }
            if !result.substitutions.isEmpty {
                out += "  - misheard: " + result.substitutions.joined(separator: ", ") + "\n"
            }
            if let error = result.error { out += "  - error: \(error)\n" }
            if let voice = result.voiceProbability, let windows = result.voiceWindows {
                out += String(format: "  - voice: max %.2f, %d windows over the threshold\n", voice, windows)
            }
            for failure in result.failures { out += "  - ❌ \(failure)\n" }
        }
        return out
    }

    private static func render(_ comparison: CorpusComparison,
                               engines: [(id: String, name: String)]) -> String {
        var out = "\n## Since \(comparison.baseline)\n\n"
        out += "\(comparison.worse.count) worse, \(comparison.better.count) better, \(comparison.new.count) new"
        if !comparison.changedClips.isEmpty { out += ", \(comparison.changedClips.count) not compared" }
        out += ". A cell is worse when its WER rose by more than 0.10 or it newly fails a check, "
        out += "better the other way round; ▼ and ▲ mark them in the tables. "
        out += "A cell the earlier run did not have is new, not a regression.\n"

        func byEngine(_ title: String, _ changes: [CorpusComparison.Change]) {
            guard !changes.isEmpty else { return }
            out += "\n### \(title)\n"
            for engine in engines {
                let mine = changes.filter { $0.result.engine == engine.id }
                guard !mine.isEmpty else { continue }
                out += "\n**\(engine.name)**\n\n"
                for change in mine {
                    out += "- \(change.result.clip) · \(change.result.language): " + change.reasons.joined(separator: "; ") + "\n"
                }
            }
        }
        byEngine("Worse", comparison.worse)
        byEngine("Better", comparison.better)

        func list(_ title: String, _ results: [CorpusResult]) {
            guard !results.isEmpty else { return }
            out += "\n### \(title)\n\n"
            for engine in engines {
                let mine = results.filter { $0.engine == engine.id }
                guard !mine.isEmpty else { continue }
                out += "- **\(engine.name)**: " + mine.map { "\($0.clip) · \($0.language)" }.joined(separator: ", ") + "\n"
            }
        }
        list("Not compared: the clip changed since", comparison.changedClips)
        list("New", comparison.new)
        return out
    }

    private static func cell(_ result: CorpusResult, mark: String? = nil) -> String {
        guard result.status == .ran else { return result.status.rawValue }
        var parts: [String] = []
        if let wer = result.wordErrorRate {
            parts.append(String(format: "%.2f", wer))
        } else {
            parts.append(result.pasted == nil ? "∅" : "—")
        }
        parts.append(result.firstPartialSeconds.map { String(format: "%.1fs", $0) } ?? "—")
        parts.append(result.stopToTextSeconds.map { String(format: "%.1fs", $0) } ?? "—")
        var cell = parts.joined(separator: " · ")
        if result.path == .fallback { cell += " ↩" }
        if !result.failures.isEmpty { cell += " ❌" }
        if let mark { cell += " " + mark }
        return cell
    }
}
