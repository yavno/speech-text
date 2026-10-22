// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates

/// A chat model AI Rewrite can run on this Mac: one GGUF file, downloaded from HuggingFace
/// into `Models/llm/<id>/` and run by llama.cpp in the SpeechTextLLM service.
public struct LocalChatModel: Identifiable, Hashable, Sendable {
    /// The file name without `.gguf` — stable, and what `localLLMModel` stores.
    public let id: String
    public let displayName: String
    public let family: ChatTemplateFamily
    /// Where it is downloaded from: an ungated repository (the app downloads with no
    /// account), pinned to a commit so the bytes cannot change under the hash.
    public let repository: String
    let revision: String
    public let file: String
    /// The file's SHA-256 — HuggingFace's LFS object id, which is exactly that.
    public let sha256: String
    public let downloadBytes: Int64
    /// Memory the Mac needs for it to be offered as a pick: the weights, the 8K context's
    /// cache, macOS and whatever the user has open — a model that only just fits pages as
    /// soon as a browser tab loads, and a rewrite that stalls reads as the app hanging.
    public let memoryFloorBytes: UInt64
    /// Names no language: a row names only the user's own, through `languageNotes`.
    public let summary: String
    /// Weaknesses the rewrite evaluation measured, by language code, shown only to someone
    /// who speaks it. None today: on llama.cpp no model drifted out of the dictated language
    /// (docs/specs/2026-10-16-built-in-local-llm.md). Required, so a model added later is
    /// asked the question.
    public let languageNotes: [String: LanguageNote]

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!
    }

    public var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

private let gigabyte: UInt64 = 1_073_741_824

/// Every chat model on offer, **heaviest first**, as `localSTTModels` is. Sizes and hashes
/// are HuggingFace's tree API, read 2026-10-16; every repository is Apache-2.0 and
/// ungated. Q4_K_M where the family publishes it; Gemma 4 12B is Google's own
/// quantisation-aware Q4_0, which keeps more of the model than a post-hoc Q4 of the same
/// size, and gpt-oss ships in MXFP4 only.
///
/// Only what the pinned llama.cpp build loads is listed (the rewrite evaluation loads
/// each). Larger models — Gemma 4 26B/31B, Qwen3.6 35B, gpt-oss 120B — are for later.
public let localChatModels: [LocalChatModel] = [
    LocalChatModel(
        id: "Qwen3.8-27B-Q4_K_M", displayName: "Qwen3.8 27B", family: .qwen,
        repository: "ggml-org/Qwen3.8-27B-GGUF", revision: "71bc7b627595dc8a91039addd9c791ae548d6747",
        file: "Qwen3.8-27B-Q4_K_M.gguf",
        sha256: "c600de0300ae8a0eb3a6c0b8b5561b8b96f16bd2c863c2a66c42de29d391a747",
        downloadBytes: 18_973_870_528, memoryFloorBytes: 32 * gigabyte,
        summary: "The largest here. About 8 seconds a dictation on an M1 Pro, three times Gemma 4 12B's.",
        languageNotes: [:]
    ),
    LocalChatModel(
        id: "gpt-oss-20b-MXFP4", displayName: "gpt-oss 20B", family: .harmony,
        repository: "ggml-org/gpt-oss-20b-GGUF", revision: "ef9b12f2ff56c69cf32153a02784e7a3c88bf524",
        file: "gpt-oss-20b-MXFP4.gguf",
        sha256: "27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901",
        downloadBytes: 12_109_566_624, memoryFloorBytes: 24 * gigabyte,
        summary: "OpenAI's open model. Mixture-of-experts with 3.6B active; it always reasons a little before answering.",
        languageNotes: [:]
    ),
    LocalChatModel(
        id: "gemma-4-12b-it-qat-q4_0", displayName: "Gemma 4 12B", family: .gemma4,
        repository: "google/gemma-4-12B-it-qat-q4_0-gguf", revision: "29d097773436b69ff9feafd636ab4cf873786537",
        file: "gemma-4-12b-it-qat-q4_0.gguf",
        sha256: "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b",
        downloadBytes: 6_975_879_296, memoryFloorBytes: 16 * gigabyte,
        summary: "The best in our rewrite test: 40 of 42 rewrites right, about 2.4 s each on an M1 Pro.",
        languageNotes: [:]
    ),
    LocalChatModel(
        id: "Qwen3.5-9B-Q4_K_M", displayName: "Qwen3.5 9B", family: .qwen,
        repository: "lmstudio-community/Qwen3.5-9B-GGUF", revision: "1379f25c6b505a3fc737bd7818cb09389cf807c1",
        file: "Qwen3.5-9B-Q4_K_M.gguf",
        sha256: "cd76ec205963b3b33350093e6904d9de16c4e666fd104e1f632d25c7f15f2a13",
        downloadBytes: 5_627_044_256, memoryFloorBytes: 16 * gigabyte,
        summary: "A step behind Gemma 4 12B, and a little lighter.",
        languageNotes: [:]
    ),
    LocalChatModel(
        id: "Qwen3.5-4B-Q4_K_M", displayName: "Qwen3.5 4B", family: .qwen,
        repository: "lmstudio-community/Qwen3.5-4B-GGUF", revision: "f9f88ac3e234be915e23811a6d28ea287bdb927e",
        file: "Qwen3.5-4B-Q4_K_M.gguf",
        sha256: "25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c",
        downloadBytes: 2_707_513_696, memoryFloorBytes: 8 * gigabyte,
        summary: "The one that fits 8 GB, with limits: it sometimes picks the wrong prompt. An online service rewrites better.",
        languageNotes: [:]
    ),
]

public func localChatModel(id: String) -> LocalChatModel? {
    localChatModels.first { $0.id == id }
}

/// What each tier is offered (`TierPicks`: the fastest good-enough model, and the
/// strongest the tier holds; both step down when memory or disk run short).
///
/// Measured 2026-10-16 on llama.cpp (M1 Pro 32 GB, 21 fixtures × 2, the app's own prompt
/// and parser — docs/specs/2026-10-16-built-in-local-llm.md): Gemma 4 12B 40/42 at 2.4 s,
/// gpt-oss 20B 38/42 at 2.1 s, Qwen3.5 9B and Qwen3.8 27B 36/42 (the 27B at 7.9 s),
/// Qwen3.5 4B 30/42 with poor routing. So gpt-oss 20B leads "best quality" from 24 GB, not
/// Qwen3.8 27B, which stays listed (the owner's interim call, 2026-10-17, pending the
/// model work of the MB session). Intel runs on the processor alone, so it is offered the small model first.
func localChatPicks(for tier: MacTier) -> TierPicks {
    let floor = ["Qwen3.5-4B-Q4_K_M"]
    let balanced = ["gemma-4-12b-it-qat-q4_0", "Qwen3.5-9B-Q4_K_M"] + floor
    switch tier {
    case .intel:
        return TierPicks(recommended: floor, bestQuality: balanced)
    case .entry:
        return TierPicks(recommended: floor, bestQuality: floor)
    case .standard:
        return TierPicks(recommended: balanced, bestQuality: balanced)
    case .plus, .pro, .max, .ultra:
        return TierPicks(recommended: balanced,
                         bestQuality: ["gpt-oss-20b-MXFP4", "Qwen3.8-27B-Q4_K_M"] + balanced)
    }
}

public func recommendedLocalChatModel(for capabilities: SystemCapabilities) -> LocalChatModel? {
    firstFitting(localChatPicks(for: MacTier(capabilities)).recommended, in: localChatModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

public func bestQualityLocalChatModel(for capabilities: SystemCapabilities) -> LocalChatModel? {
    firstFitting(localChatPicks(for: MacTier(capabilities)).bestQuality, in: localChatModels,
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

/// Where a chat model's file lives: `Models/llm/<id>/<file>`, beside the speech models
/// and inside the folder the rename migration moves.
public func localChatModelFile(for model: LocalChatModel) -> URL {
    localModelsDirectory()
        .appendingPathComponent("llm", isDirectory: true)
        .appendingPathComponent(model.id, isDirectory: true)
        .appendingPathComponent(model.file)
}

/// Installed means the whole file is there under its final name — the download writes
/// to a staging folder and moves the file only after its hash matched.
public func isLocalChatModelInstalled(_ model: LocalChatModel) -> Bool {
    FileManager.default.fileExists(atPath: localChatModelFile(for: model).path)
}

// MARK: - Registration

/// The local chat runtime, reached through a box as the speech engines are (`LocalSTT`):
/// `ChatClients.swift` is in SpeechTextCore and cannot name the XPC client, which is
/// app-only. `registerLocalChat()` (LocalChatClient.swift) fills it at launch; unfilled —
/// the test bundle — every client throws rather than answering with nothing. Written
/// once, on main, at launch, before anything reads it, as `LocalSTT`'s boxes are.
public enum LocalChat {
    public nonisolated(unsafe) static var clientFactory: (LocalChatModel) -> ChatClient = { _ in UnavailableLocalChatClient() }
    /// Loads the model in the service ahead of the first rewrite — after a download, and
    /// when the user picks an installed one.
    public nonisolated(unsafe) static var prewarm: (LocalChatModel) -> Void = { _ in }
    /// Drops a removed download from the service's memory, if it is the model loaded
    /// there — removing another one must not cost the model in use a cold load.
    public nonisolated(unsafe) static var release: (LocalChatModel) -> Void = { _ in }
}

struct UnavailableLocalChatClient: ChatClient {
    func complete(system: String, user: String) async throws -> ChatReply {
        throw LLMError.noLocalModel
    }
}
