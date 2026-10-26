// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import Foundation
import FluidAudio
import SpeechTextCore

/// **The only file in the app that runs Parakeet through FluidAudio** (the voice activity
/// detector has its own, `VoiceActivityRuntime.swift`), as `LocalWhisperRuntime.swift`
/// is the only one that imports WhisperKit.
///
/// Parakeet TDT 0.6B v3 is NVIDIA's multilingual speech model; FluidAudio is the Swift
/// package that runs its Core ML conversion on the Neural Engine. It joined the
/// catalogue because it beat the local Whisper tier on the thing this app is for —
/// measured 2026-09-21 on an M1 Pro against a real 12.4 s Ukrainian dictation, it
/// produced the same text as ElevenLabs Scribe v2 where cloud Whisper Large v3 Turbo
/// misread the first word, in 0.34–0.61 s from a cold process, out of a 483 MB download
/// rather than Turbo's 645 MB.
///
/// Everything around it is Foundation, exactly as for WhisperKit: the catalogue, the
/// recommendation, the install bookkeeping and the Settings rows do not know this
/// framework exists. That is what keeps the standalone test bundle building, and it
/// means a third engine later is one more conforming type.
///
/// One runtime runs the whole v3 family (`ParakeetVersion`): v3 and its five
/// re-trainings share the tokenizer, the 15 s window and the decoder contract, and differ
/// only in their weights and which repo they come from.
///
/// Weights, each CC-BY-4.0 and credited in README:
/// - v3: `FluidInference/parakeet-tdt-0.6b-v3-coreml`, from `nvidia/parakeet-tdt-0.6b-v3`;
/// - Ultra: `FluidInference/parakeet-ultra-coreml`, from `moondream/parakeet-ultra`;
/// - Redux: `FluidInference/parakeet-redux-coreml`, from `moondream/parakeet-redux`;
/// - Phonon-2: `FluidInference/phonon-2-coreml`, from `FermionResearch/Phonon-2`;
/// - Bark 3.0 and Bark 3.0 Clean: the two folders of `FluidInference/bark-3.0-coreml`, from
///   `ConwayResearch/Underdog-Bark-3.0` and `-Clean` (credited in ThirdPartyNotices too).
struct ParakeetRuntime: LocalSTTRuntime {
    /// FluidAudio writes into `<parent of the directory you pass>/<its own folder name>`
    /// and hands back the path you gave it, so passing a folder named anything else
    /// returns a URL with nothing in it. Verified on 2026-09-21: `--model-dir /tmp/x`
    /// put the model in `/tmp/parakeet-tdt-0.6b-v3`. So the staging folder is named for
    /// the repo, and `LocalModelStore` renames it to the catalogue ID on the way in —
    /// which here are the same string, but the store's move is what guarantees it.
    func download(variant: String, into base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let build = try ParakeetBuild(modelID: variant)
        let folder: URL
        switch build.source {
        case .hub(let repo):
            folder = try await Self.downloadFromHub(repo, variant: build.downloadVariant, into: base, progress: progress)
        case .pinned(let fetch):
            folder = try await fetch.run(into: base, progress: progress)
        }
        // Nothing to move on to unless every bundle the loader opens arrived.
        guard isParakeetFolderComplete(folder) else {
            throw LocalModelError.downloadFailed("the download of \(variant) is incomplete")
        }
        return folder
    }

    private static func downloadFromHub(_ repo: Repo, variant: String?, into base: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // `ModelHub.download`, not `AsrModels.download`: the latter also *loads* every
        // bundle on the Neural Engine as it fetches it, whatever compute units the model
        // will run on — for Redux on an M1 Pro that was a 12-minute compile that failed
        // (2026-10-16). Fetching the files alone leaves the one-time load to `prewarm`,
        // where the store shows it as "optimizing" and it uses the build's own units.
        // The fetch reports 0…0.5 (FluidAudio keeps the other half for a compile it does
        // not do here), hence the doubling.
        try await ModelHub.download(repo, to: base, variant: variant,
                                    progressHandler: { progress(min($0.fractionCompleted * 2, 1)) })
        return base.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    func transcribe(audioFileURL: URL, modelFolder: URL, language: String?) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        dlog("LocalParakeet", "transcribe: model=\(modelFolder.lastPathComponent), language=\(language ?? "auto")")

        let text = try await ParakeetPipelineCache.shared.transcribe(
            audioFileURL: audioFileURL, modelFolder: modelFolder, language: Self.hint(for: language)
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        dlog("LocalParakeet", "transcribe: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }

    func prewarm(modelFolder: URL) async throws {
        try await ParakeetPipelineCache.shared.load(modelFolder)
    }

    /// The encoder build to fetch and load, and it has to be the same on both sides — the
    /// loader opens the file this names, so a download of one and a load of the other is
    /// a missing-file error. `.int8` is FluidAudio's default and is what was measured;
    /// `.int8V2` is a 577 MB rebuild that avoids a token-corruption bug
    /// (FluidInference/FluidAudio#760) we have not seen, and `.int4` a 298 MB one we have
    /// not tested. It names a file for v3 only: Ultra, Redux, Phonon-2 and Bark each ship one
    /// encoder the loader opens (`Encoder.mlmodelc`), whatever this says.
    fileprivate static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// Turns our stored language into Parakeet's hint, which on v3 filters the decoder's
    /// top-K candidates down to the language's *script*.
    ///
    /// nil on Auto — `RecordingConfiguration.cloudLanguage` already encodes "let the
    /// model decide", and v3 detects the language from the audio, which the keyboard
    /// layout cannot. Note what the hint does and does not buy: Ukrainian and Russian are
    /// both Cyrillic, so it keeps Latin letters out of a Ukrainian dictation and does
    /// nothing at all about the two being confused for each other.
    private static func hint(for language: String?) -> Language? {
        guard let language else { return nil }
        return Language(rawValue: String(language.prefix(2)).lowercased())
    }
}

/// What FluidAudio needs to know about one of our Parakeet models: its `AsrModelVersion`,
/// where its files come from (for most, the repo whose folder name `ModelHub.download(to:)`
/// writes into — the version's own `repo` is not public, so it is named here) and where its
/// encoder runs. Built from the catalogue entry; an ID that is not a Parakeet one throws
/// rather than quietly loading v3 from a folder that holds something else.
struct ParakeetBuild {
    /// FluidAudio's own download, for a repo its `Repo` names; or a pinned folder fetched
    /// file by file, for one the pinned FluidAudio does not know.
    enum Source {
        case hub(Repo)
        case pinned(PinnedFolderFetch)
    }

    let version: AsrModelVersion
    let source: Source
    /// nil keeps FluidAudio's default, the Neural Engine. See `init`.
    let encoderComputeUnits: MLComputeUnits?
    /// Whether the transcript has `<unk>` taken out of it. See `init`.
    var dropsUnknownToken = false

    /// The repo variant FluidAudio picks files by: v3's encoder precision, nothing for the
    /// builds that ship a single encoder.
    var downloadVariant: String? {
        version == .v3 ? ParakeetRuntime.encoderPrecision.rawValue : nil
    }

    init(modelID: String) throws {
        guard let model = localSTTModel(id: modelID), let parakeet = model.parakeetVersion else {
            throw LocalModelError.notInstalled(modelID)
        }
        switch parakeet {
        case .v3:
            (version, source, encoderComputeUnits) = (.v3, .hub(.parakeetV3), nil)
        case .ultra:
            (version, source, encoderComputeUnits) = (.ultra, .hub(.parakeetUltra), nil)
        case .redux:
            // The GPU, measured on 2026-10-16 (M1 Pro, macOS 26): on the Neural Engine its
            // 2-bit encoder failed to compile (`ANECCompile() FAILED`) after 652 s — on
            // every launch, since a failed compile is not cached — and then ran on the
            // fallback anyway. On the GPU it loaded in 0.6–1.2 s. The price is speed: on the
            // corpus it answered in 0.97 s at the median (p90 2.0 s) against v3's 0.25 s on
            // the Neural Engine. A Mac whose ANE does compile it (FluidAudio measured
            // 45–52 ms a window there, M-series) might do better — not measured here.
            (version, source, encoderComputeUnits) = (.redux, .hub(.parakeetRedux), .cpuAndGPU)
        case .phonon2:
            // The Neural Engine, never the GPU: there Phonon-2's sparse encoder is expanded
            // on every load (~150 s of CPU, FluidAudio measured), and Core ML never caches it.
            (version, source, encoderComputeUnits) = (.phonon2, .hub(.phonon2), nil)
        case .bark3, .bark3Clean:
            // FluidAudio 0.17.7 has no `AsrModelVersion` for Bark: `.bark3` / `.bark3Clean`
            // come with FluidInference/FluidAudio#1054, open and in no release on 2026-10-26.
            // They have v3's contract (tokenizer, blank ID, window, JointDecisionv3) and
            // Ultra's single `Encoder.mlmodelc`, so `.ultra` loads them — the repo's own README
            // says to on a FluidAudio without #1054, and both loaded and transcribed English
            // that way on an M1 Pro (2026-10-26). `.ultra` is never platform-gated, where
            // #1054 gates Bark to macOS 15 for its iOS 18 palette ops: the catalogue's
            // `minimumSystemVersion` is the only guard. Once a release with #1054 is pinned,
            // this becomes `.hub(.bark3)` and the pinned fetch goes.
            //
            // The Neural Engine, never the GPU: like Phonon-2's, its sparse encoder is rebuilt
            // on every GPU load (the repo's README), and the GPU's `Encoder_lut3` is not fetched.
            // And `<unk>` is dropped: Bark emits it where its training text had a quotation
            // mark, which #1054 drops inside FluidAudio and 0.17.7 leaves in the text.
            let folder = parakeet == .bark3 ? "bark-3.0" : "bark-3.0-clean"
            (version, encoderComputeUnits) = (.ultra, nil)
            source = .pinned(PinnedFolderFetch(repository: "FluidInference/bark-3.0-coreml",
                                               revision: "73b0c0da665d29ea0332e9f0d32da8e26a4cdb38",
                                               folder: folder, leaving: ["Encoder_lut3.mlmodelc", "NOTICE"]))
            dropsUnknownToken = true
        }
    }

    /// The transcript as it is pasted: without the `<unk>` a Bark build writes for a
    /// quotation mark, and without the doubled space that would leave behind.
    func cleaned(_ text: String) -> String {
        guard dropsUnknownToken else { return text }
        return text.replacingOccurrences(of: "<unk>", with: "")
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }
}

/// One folder of a HuggingFace repository at a pinned commit, fetched file by file into
/// `<base>/<folder>` — for a build the pinned FluidAudio's `ModelHub` cannot name, since its
/// downloads take only a case of its own `Repo`. Lists the folder through the tree API,
/// skips what `leaving` names (a path under the folder, or a bundle and everything in it),
/// keeps a file already there at its listed size, and checks every size after the fetch.
/// Cancelled with the task that runs it: URLSession's async download stops with it.
struct PinnedFolderFetch: Sendable {
    let repository: String
    let revision: String
    let folder: String
    let leaving: [String]

    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    func run(into base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let listURL = URL(string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)/\(folder)?recursive=1")!
        let (listing, response) = try await URLSession.shared.data(from: listURL)
        try Self.check(response, for: listURL)
        let files = try JSONDecoder().decode([Entry].self, from: listing).filter { entry in
            entry.type == "file" && !leaving.contains { skip in
                let skipped = "\(folder)/\(skip)"
                return entry.path == skipped || entry.path.hasPrefix(skipped + "/")
            }
        }
        guard !files.isEmpty else { throw LocalModelError.downloadFailed("\(repository)/\(folder) lists no files") }

        let total = max(files.reduce(0) { $0 + $1.size }, 1)
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = base.appendingPathComponent(file.path)
            if Self.size(of: destination) != file.size {
                let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
                let before = done
                let watcher = FetchProgress { received in progress(Double(before + received) / Double(total)) }
                let (location, response) = try await URLSession.shared.download(from: url, delegate: watcher)
                try Self.check(response, for: url)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                guard Self.size(of: destination) == file.size else {
                    throw LocalModelError.downloadFailed("\(file.path) arrived at the wrong size")
                }
            }
            done += file.size
            progress(Double(done) / Double(total))
        }
        return base.appendingPathComponent(folder, isDirectory: true)
    }

    private static func check(_ response: URLResponse, for url: URL) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LocalModelError.downloadFailed("HTTP \(status) from \(url.host() ?? "huggingface.co")")
        }
    }

    private static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64
    }
}

/// Reports one download's bytes as they arrive. The async `download(from:delegate:)` hands
/// its task to the delegate when it creates it, and the task's own `Progress` is watched —
/// the download delegate's `didWriteData` is not sent for an async download.
/// `@unchecked Sendable`: URLSession calls it on its own queue, and the one thing it keeps,
/// the observation, is held under `lock`.
private final class FetchProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = report
        let observation = task.progress.observe(\.completedUnitCount) { progress, _ in
            report(progress.completedUnitCount)
        }
        lock.withLock { self.observation = observation }
    }
}

/// Keeps one loaded Parakeet alive between dictations, for the reasons
/// `WhisperKitPipelineCache` does: loading is the expensive half, and Core ML specialises
/// a model for this Mac the first time it is opened.
///
/// The cost is far smaller here — the whole first run, download included, took 83 s
/// against Whisper Turbo's nine minutes of specialisation alone — but "far smaller" is
/// not "free", and a load per segment would still be paid in front of every paste.
///
/// `AsrManager` is itself an actor, so this one exists for the caching and for the
/// serialisation: an actor re-enters at every `await`, and a pause followed quickly by a
/// stop can otherwise finish two segments at once.
actor ParakeetPipelineCache {
    static let shared = ParakeetPipelineCache()

    private var folder: URL?
    private var manager: AsrManager?
    private var tail: Task<Void, Never>?

    /// Runs `job` after every job queued before it, success or failure. The job is handed
    /// the cache isolated, so it runs on the actor as the task that calls it does.
    private func serialized<T: Sendable>(_ job: @escaping @Sendable (isolated ParakeetPipelineCache) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await job(self)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func load(_ modelFolder: URL) async throws {
        _ = try await serialized { cache in try await cache.ensureLoaded(modelFolder) }
    }

    func transcribe(audioFileURL: URL, modelFolder: URL, language: Language?) async throws -> String {
        try await serialized { cache in
            let manager = try await cache.ensureLoaded(modelFolder)
            // A fresh decoder state per segment. The TDT decoder carries its prediction
            // network's state forward, which is what a *continuing* stream wants; a
            // segment here is a finished recording, and seeding it with the tail of the
            // previous one would let a stale dictation colour the next one's first words.
            let build = try ParakeetBuild(modelID: modelFolder.lastPathComponent)
            var state = try TdtDecoderState(decoderLayers: build.version.decoderLayers)
            let result = try await manager.transcribe(audioFileURL, decoderState: &state, language: language)
            return build.cleaned(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    private func ensureLoaded(_ modelFolder: URL) async throws -> AsrManager {
        if folder == modelFolder, let manager { return manager }
        self.manager = nil
        folder = nil
        let start = CFAbsoluteTimeGetCurrent()
        // `loadLocal`, not `load`: it opens exactly the directory it is given, where
        // `load` re-derives a repo path from the parent and would not find a model in a
        // folder named after our catalogue ID. Nothing here reaches the network — a
        // dictation must never turn into a model fetch because a file went missing.
        // The folder is named for its catalogue ID, which says which build is in it.
        let build = try ParakeetBuild(modelID: modelFolder.lastPathComponent)
        let models = try AsrModels.loadLocal(from: modelFolder, version: build.version,
                                             encoderPrecision: ParakeetRuntime.encoderPrecision,
                                             encoderComputeUnits: build.encoderComputeUnits)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        folder = modelFolder
        dlog("LocalParakeet", "loaded \(modelFolder.lastPathComponent) in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s")
        return manager
    }

    /// Releases the model if it is the one loaded. Called when a model is removed from
    /// disk, so the memory goes with it — and only then, so removing another model does
    /// not cost this one a reload. With no folder, whatever is loaded: `LocalSTT.prewarm`
    /// of the other engine, so only one local model is ever resident.
    func unload(ifLoaded modelFolder: URL? = nil) async {
        _ = try? await serialized { cache in
            guard modelFolder == nil || cache.folder == modelFolder else { return }
            if let manager = cache.manager { await manager.cleanup() }
            cache.manager = nil
            cache.folder = nil
        }
    }
}

/// The batch provider the recognition tier calls. Thin, like `WhisperKitLocalTranscriber`:
/// it exists so `makeBatchTranscriber` gets the same `BatchTranscriber` shape.
struct ParakeetLocalTranscriber: BatchTranscriber {
    let modelID: String

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        guard isLocalModelInstalled(modelID) else {
            throw LocalModelError.notInstalled(localSTTModel(id: modelID)?.displayName ?? modelID)
        }
        return try await ParakeetRuntime().transcribe(
            audioFileURL: audioFileURL, modelFolder: localModelFolder(for: modelID), language: language
        )
    }
}
