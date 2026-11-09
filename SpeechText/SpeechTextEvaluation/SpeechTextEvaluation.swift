// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import SpeechTextCore

/// The audio corpus through the local engines — the half of a corpus run that the
/// standalone test bundle cannot do, because it may not import WhisperKit or FluidAudio.
/// The same clips, the same `LiveDictation` run and the same checks as
/// `LiveProviderTests`, written into the same run folder, so `summary.md` holds one table.
///
///     SpeechTextEvaluation --corpus <dir> --runs <dir> [--run-dir <dir>] [--engines a,b] [--clips a,b] [--cloud] [--no-local] [--install]
///
/// With `--rewrite` it measures AI Rewrite instead, on cloud and local chat models, and
/// `--self-check` holds the rewrite checks to their fixtures' examples — see
/// `RewriteEvaluation`.
///
/// `--cloud` adds the cloud engines, with keys from the environment only; `--no-local`
/// leaves the local ones out. A model that is not on this Mac is a `not installed` row —
/// unless `--install` is given, which downloads every selected local model that is
/// missing into the app's own Models folder first, as Settings would.
/// The cloud rows go to `results-cloud.json` and the local ones to `results-local.json`,
/// whichever way they were run. It is what `scripts/evaluate.sh` runs: unlike the test
/// bundle it can load the voice activity detector (FluidAudio), so its cloud rows are
/// judged as the app judges them.
///
///     SpeechTextEvaluation --summarize-run <run-dir>
///
/// writes a run's WER and latency per local model and language into the committed
/// `LocalModelMeasurements.swift`, and nothing else (`CorpusMeasurementSummary`).
///
///     SpeechTextEvaluation --export-catalogue [<file>]
///
/// writes the speech and chat catalogues as JSON (`CatalogueExport`) to the file, or to
/// standard output, and does nothing else — `scripts/check-vendor-models.sh` compares
/// them with what each vendor serves.
@main
struct SpeechTextEvaluation {
    @MainActor
    static func main() async {
        // A line at a time, so a run's progress shows in a log it is piped to.
        setlinebuf(stdout)
        do {
            let arguments = CommandLine.arguments.dropFirst()
            if let flag = arguments.firstIndex(of: "--self-check") {
                guard arguments.index(after: flag) < arguments.endIndex else { throw UsageError("--self-check needs a fixtures file") }
                let url = URL(fileURLWithPath: arguments[arguments.index(after: flag)])
                exit(try RewriteEvaluation.selfCheck(url) == 0 ? 0 : 1)
            }
            if let flag = arguments.firstIndex(of: "--summarize-run") {
                guard arguments.index(after: flag) < arguments.endIndex else { throw UsageError("--summarize-run needs a run folder") }
                try summarize(URL(fileURLWithPath: arguments[arguments.index(after: flag)], isDirectory: true))
                return
            }
            if arguments.contains("--recheck") {
                try await RewriteEvaluation.recheck(arguments)
                return
            }
            if arguments.contains("--rewrite") {
                try await RewriteEvaluation.run(arguments)
                return
            }
            try await run(Options(arguments))
        } catch {
            FileHandle.standardError.write(Data("SpeechTextEvaluation: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    struct Options {
        var corpus: URL?
        var runDirectory: URL?
        var runs: URL?
        var engines: [String] = []
        var clips: [String] = []
        var cloud = false
        var local = true
        var install = false
        /// `--export-catalogue`: nil when not asked; "" for standard output.
        var exportCatalogue: String?

        init(_ arguments: ArraySlice<String>) throws {
            var arguments = arguments
            func value(_ flag: String) throws -> String {
                guard let value = arguments.popFirst() else { throw UsageError("\(flag) needs a value") }
                return value
            }
            while let argument = arguments.popFirst() {
                switch argument {
                case "--corpus": corpus = URL(fileURLWithPath: try value(argument))
                case "--run-dir": runDirectory = URL(fileURLWithPath: try value(argument))
                case "--runs": runs = URL(fileURLWithPath: try value(argument))
                case "--engines": engines = try value(argument).split(separator: ",").map(String.init)
                case "--clips": clips = try value(argument).split(separator: ",").map(String.init)
                case "--cloud": cloud = true
                case "--no-local": local = false
                case "--install": install = true
                case "--export-catalogue":
                    exportCatalogue = arguments.first.flatMap { $0.hasPrefix("--") ? nil : arguments.popFirst() } ?? ""
                default: throw UsageError("unknown argument \(argument)")
                }
            }
        }
    }

    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? {
            message + "\nusage: SpeechTextEvaluation --corpus <dir> --runs <dir> [--run-dir <dir>] [--engines vendor/model,…] [--clips a,…] [--cloud] [--no-local] [--install]"
                + "\n       SpeechTextEvaluation --summarize-run <run-dir>"
                + "\n       SpeechTextEvaluation --export-catalogue [<file>]"
        }
    }

    /// The checkout this tool was built from: the clip descriptions are committed there.
    /// Runs are not: they go under `--runs`, outside the repository.
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @MainActor
    static func run(_ options: Options) async throws {
        if let path = options.exportCatalogue {
            let json = try CatalogueExport.current().json() + Data("\n".utf8)
            if path.isEmpty {
                FileHandle.standardOutput.write(json)
            } else {
                try json.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return
        }
        guard let corpus = options.corpus else { throw UsageError("--corpus is required") }
        registerLocalSTT()
        registerSpellCheckedJoins()
        // The app's own copy of the voice activity model, from the checkout.
        let loading = Date()
        await registerVoiceActivity(modelURL: repository.appendingPathComponent(
            "SpeechText/SpeechText/Resources/\(sileroVoiceActivityModel).mlmodelc"))?.value
        print(VoiceActivity.detector == nil ? "voice activity detector: not loaded — segments are not judged"
              : String(format: "voice activity detector loaded in %.0f ms", Date().timeIntervalSince(loading) * 1000))
        let descriptions = try CorpusClip.load(from: repository.appendingPathComponent("SpeechText/SpeechTextTests/Audio"))
        let clips = CorpusClip.recordings(of: descriptions, in: corpus)
            .filter { $0.isSelected(by: options.clips) }
        let engines = CorpusEngine.all
            .filter { ($0.isLocal ? options.local : options.cloud) && (options.engines.isEmpty || options.engines.contains($0.id)) }
        guard let runs = options.runs ?? options.runDirectory?.deletingLastPathComponent() else {
            throw UsageError("--runs is required: the folder runs are kept in, outside the repository")
        }
        if options.install {
            for engine in engines where engine.isLocal && !isLocalModelInstalled(engine.model.id) {
                try await install(engine)
            }
        }
        var folder = options.runDirectory.map { CorpusRunFolder(url: $0) } ?? CorpusRunFolder.new(in: runs)
        folder.baseline = CorpusRunFolder.previous(in: runs, before: folder.url)?.url
        let keys = ProviderKeys.fromEnvironment()
        // One results file per kind of engine, whichever of them ran: a folder never holds
        // the same cell twice under two runners' names.
        func runner(_ engine: CorpusEngine) -> String { engine.isLocal ? "local" : "cloud" }
        var results: [String: [CorpusResult]] = [:]
        for name in Set(engines.map(runner)) {
            results[name] = folder.earlierResults(runner: name, except: clips)
        }
        var loaded: Set<String> = []
        for clip in clips {
            let audio = try? TapAudio(clip: clip, in: corpus)
            for engine in engines {
                for pass in clip.passes {
                    var result = CorpusResult(clip: clip.name, engine: engine.id, engineName: engine.name,
                                              language: pass.label, status: .noAudio)
                    if let audio {
                        if let missing = engine.unavailable(keys: keys) {
                            result.status = missing
                        } else {
                            // The load goes in its own column: a first load specialises the model
                            // for this Mac (nine minutes for Whisper Turbo) and is not the stop's.
                            var loadSeconds: Double?
                            if engine.isLocal, !loaded.contains(engine.id) {
                                print("loading \(engine.model.displayName)…")
                                let start = Date()
                                try await prewarm(engine)
                                loadSeconds = Date().timeIntervalSince(start)
                                loaded.insert(engine.id)
                            }
                            result = await LiveDictation.run(clip: clip, audio: audio, engine: engine, pass: pass,
                                                             keys: keys, traceDirectory: folder.traces)
                            result.loadSeconds = loadSeconds
                        }
                    }
                    print("\(clip.name) · \(engine.id) · \(result.language): \(result.status.rawValue)"
                          + (result.failures.isEmpty ? "" : " ❌ " + result.failures.joined(separator: "; ")))
                    results[runner(engine), default: []].append(result)
                    try folder.write(results[runner(engine)] ?? [], runner: runner(engine))
                }
            }
        }
        print("\(folder.url.path)/summary.md")
        if results.values.joined().contains(where: { !$0.passed }) { exit(1) }
    }

    /// The run's date is its folder's name (`CorpusRunFolder.new`). The table this tool
    /// was built with supplies the rows of the models the run did not have.
    private static func summarize(_ run: URL) throws {
        let descriptions = try CorpusClip.load(from: repository.appendingPathComponent("SpeechText/SpeechTextTests/Audio"))
        let rows = CorpusMeasurementSummary.rows(from: try CorpusRunFolder(url: run).allResults(), descriptions: descriptions,
                                                 run: String(run.lastPathComponent.prefix(10)),
                                                 mac: SystemCapabilities.current().chipName)
        guard !rows.isEmpty else { throw UsageError("\(run.path) has no local results to summarize") }
        let source = CorpusMeasurementSummary.source(CorpusMeasurementSummary.merged(rows, into: localSTTMeasurements))
        let file = repository.appendingPathComponent(CorpusMeasurementSummary.file)
        try source.write(to: file, atomically: true, encoding: .utf8)
        print("\(file.path): \(Set(rows.map(\.model)).count) models from \(run.lastPathComponent)")
    }

    private static func runtime(_ engine: CorpusEngine) -> LocalSTTRuntime? {
        guard case .onDevice(let kind) = engine.model.delivery else { return nil }
        return switch kind {
        case .whisperKit: WhisperKitRuntime()
        case .parakeet: ParakeetRuntime()
        }
    }

    private static func prewarm(_ engine: CorpusEngine) async throws {
        try await runtime(engine)?.prewarm(modelFolder: localModelFolder(for: engine.model.id))
    }

    /// `LocalModelStore.install` without the store, which this tool does not compile:
    /// a per-model staging folder, then a move into `Models/<id>/`. The prewarm is left to
    /// the run, which reports the first load in its own column.
    private static func install(_ engine: CorpusEngine) async throws {
        guard let runtime = runtime(engine) else { return }
        let id = engine.model.id
        let destination = localModelFolder(for: id)
        let staging = localModelsDirectory().appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let files = FileManager.default
        try? files.removeItem(at: staging)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        print("installing \(engine.model.displayName)…")
        let start = Date()
        // Progress arrives on the downloader's own thread, so the last tenth printed is held
        // under a lock rather than in a captured `var`.
        let reported = OSAllocatedUnfairLock(initialState: -1)
        let downloaded = try await runtime.download(variant: id, into: staging) { fraction in
            let percent = Int(fraction * 10) * 10
            reported.withLock { last in
                if percent != last { last = percent; print("  \(percent)%") }
            }
        }
        try? files.removeItem(at: destination)
        try files.moveItem(at: downloaded, to: destination)
        try? files.removeItem(at: staging)
        print(String(format: "installed \(id) in %.0f s", Date().timeIntervalSince(start)))
    }
}
