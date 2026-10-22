// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import WhisperKit
import SpeechTextCore

/// **The only file in the app that imports a third-party framework.**
///
/// Everything else in the local-model feature — the catalogue, the hardware read, the
/// recommendation, the download bookkeeping, the Settings UI, the provider the engine
/// actually calls — is Foundation. That is deliberate: it keeps the standalone test
/// bundle building (it cannot resolve SPM packages), and it means replacing the
/// inference engine is one conforming type rather than a rewrite.
///
/// Models come from `argmaxinc/whisperkit-coreml` on HuggingFace: Core ML conversions
/// of OpenAI's Whisper weights, MIT-licensed like the originals.
struct WhisperKitRuntime: LocalSTTRuntime {
    func download(variant: String, into base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(
            variant: variant,
            downloadBase: base,
            useBackgroundSession: false,
            progressCallback: { progress($0.fractionCompleted) }
        )
    }

    func transcribe(audioFileURL: URL, modelFolder: URL, language: String?) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        dlog("LocalWhisper", "transcribe: model=\(modelFolder.lastPathComponent), language=\(language ?? "auto")")

        var options = DecodingOptions()
        // nil means "detect", which is what `RecordingConfiguration.cloudLanguage` already
        // encodes on Auto. A keyboard layout is a worse guess than the audio itself.
        if let language {
            options.language = String(language.prefix(2))
            options.usePrefillPrompt = true
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }
        // Dictation, not subtitles: nothing to strip out of the paste afterwards.
        options.withoutTimestamps = true
        options.skipSpecialTokens = true

        let text = try await WhisperKitPipelineCache.shared.transcribe(
            audioPath: audioFileURL.path, modelFolder: modelFolder, options: options
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        dlog("LocalWhisper", "transcribe: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars")
        return text
    }

    func prewarm(modelFolder: URL) async throws {
        try await WhisperKitPipelineCache.shared.load(modelFolder)
    }
}

/// Keeps one loaded pipeline alive between dictations, and is the only thing that
/// touches it.
///
/// Loading is the expensive part, not decoding: the first load of a Core ML model on a
/// given Mac *specialises* it for the Neural Engine, which for the turbo model takes tens
/// of seconds, and even a warm load reads hundreds of megabytes. Rebuilding the pipeline
/// per segment would put that in front of every paste. Only one model is held — switching
/// models in Settings releases the old one rather than keeping two resident.
///
/// `WhisperKit` is not `Sendable`, so the pipeline never leaves this actor: callers hand
/// in a path and get text back. Work is also chained one job at a time — an actor alone
/// does not guarantee that, since it re-enters at every `await`, and a pause followed
/// quickly by a stop can finish two segments at once on the same decoder state.
actor WhisperKitPipelineCache {
    static let shared = WhisperKitPipelineCache()

    private var folder: URL?
    private var pipe: WhisperKit?
    private var tail: Task<Void, Never>?

    /// Runs `job` after every job queued before it, success or failure. The job is handed
    /// the cache isolated, so it runs on the actor as the task that calls it does.
    private func serialized<T: Sendable>(_ job: @escaping @Sendable (isolated WhisperKitPipelineCache) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await job(self)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func load(_ modelFolder: URL) async throws {
        try await serialized { cache in try await cache.ensureLoaded(modelFolder) }
    }

    func transcribe(audioPath: String, modelFolder: URL, options: DecodingOptions) async throws -> String {
        try await serialized { cache in
            try await cache.ensureLoaded(modelFolder)
            return try await cache.decode(audioPath: audioPath, options: options)
        }
    }

    private func ensureLoaded(_ modelFolder: URL) async throws {
        if folder == modelFolder, pipe != nil { return }
        pipe = nil
        folder = nil
        let start = CFAbsoluteTimeGetCurrent()
        // `download: false` — the model is already on disk, and a dictation must never
        // turn into a model fetch because a file went missing.
        //
        // `tokenizerFolder` is the model's own folder, and that is not cosmetic. The
        // tokenizer is not part of the Core ML download; WhisperKit fetches it on first
        // load, and left to its default it writes to `~/Documents/huggingface` — which
        // clutters the user's Documents, raises the macOS "access your Documents folder"
        // prompt, and leaves the tokenizer outside anything Remove would delete. Inside
        // the model folder it is also one of WhisperKit's own search paths, so the load
        // that `LocalModelStore` runs straight after install (while still online) fetches
        // it once, and every later load — offline included — finds it there.
        let config = WhisperKitConfig(modelFolder: modelFolder.path, tokenizerFolder: modelFolder,
                                      verbose: false, prewarm: true, load: true, download: false)
        pipe = try await WhisperKit(config)
        folder = modelFolder
        dlog("LocalWhisper", "loaded \(modelFolder.lastPathComponent) in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s")
    }

    private func decode(audioPath: String, options: DecodingOptions) async throws -> String {
        guard let pipe else { throw LocalModelError.notInstalled(folder?.lastPathComponent ?? "model") }
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Releases the model if it is the one loaded. Called when a model is removed from
    /// disk, so the memory goes with it, and with no folder by `LocalSTT.prewarm` of the
    /// other engine, so only one local model is ever resident.
    func unload(ifLoaded modelFolder: URL? = nil) async {
        _ = try? await serialized { cache in
            guard modelFolder == nil || cache.folder == modelFolder else { return }
            cache.pipe = nil
            cache.folder = nil
        }
    }
}

/// The batch provider the recognition tier actually calls. Thin on purpose — it exists
/// so `makeBatchTranscriber` gets the same `BatchTranscriber` shape the cloud tiers have.
struct WhisperKitLocalTranscriber: BatchTranscriber {
    let modelID: String

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        guard isLocalModelInstalled(modelID) else {
            throw LocalModelError.notInstalled(localSTTModel(id: modelID)?.displayName ?? modelID)
        }
        return try await WhisperKitRuntime().transcribe(
            audioFileURL: audioFileURL, modelFolder: localModelFolder(for: modelID), language: language
        )
    }
}

// `registerLocalSTT()` used to live here, when WhisperKit was the only local engine.
// It now wires two of them and so belongs to neither — see `LocalSTTRuntime.swift`.
