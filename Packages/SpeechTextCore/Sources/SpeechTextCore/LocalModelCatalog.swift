// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which inference engine a local model runs on.
///
/// Two families live in one catalogue rather than behind two engine pickers: from the
/// user's side "a model on my Mac" is one choice, and everything downstream — the
/// recognition tier, the History archive, retry, onboarding — already keys off
/// `sttProvider == .local` plus a model ID. Splitting them into two `STTProviderType`
/// cases would have doubled all of that to describe a difference the user never makes.
///
/// The app pairs each case with a runtime at launch (`registerLocalSTT()`); this enum is
/// plain data, so the test target sees it without either framework.
public enum LocalSTTEngine: String, Hashable, Sendable {
    /// Whisper through WhisperKit (`LocalWhisperRuntime.swift`).
    case whisperKit
    /// Parakeet TDT through FluidAudio (`LocalParakeetRuntime.swift`).
    case parakeet
}

/// One installable open-source speech model.
///
/// `id` is both the identifier in the engine's own repo — a WhisperKit variant name, or
/// FluidAudio's folder name for a Parakeet repo — and the folder name on disk. One
/// string, so an installed model is recognised by directory listing alone and the
/// catalogue can grow without a migration.
public struct LocalSTTModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let engine: LocalSTTEngine
    public let displayName: String
    /// Measured from the HuggingFace tree API, not estimated from the variant's name:
    /// the "_632MB" suffix names the weights, while the folder also carries the mel
    /// filterbank and configs, so the real download is ~2% larger.
    public let downloadBytes: Int64
    /// Below this much installed RAM the model still loads but pages, and a dictation
    /// that takes longer than it did to speak is not usable. Settings still lets the user
    /// install a heavier model — it only says so.
    public let memoryFloorBytes: UInt64
    /// What a row says for an ID `speechModelLine` has no words of its own for. Names no
    /// language: a row names only the user's own, through `languageNotes`.
    public let summary: String
    /// The languages the model was trained to transcribe — what it *knows*, not how well;
    /// how well is `languageNotes`. Required, as every speech catalogue entry's is.
    public let languages: LanguageCoverage
    /// Weaknesses we measured, by language code, shown only to someone who speaks it.
    public let languageNotes: [String: LanguageNote]
    /// Superseded at most, never deprecated: a launch that moved a stored choice to a
    /// local model would point it at files nobody downloaded. A newer local model is
    /// offered, and only downloaded once the user takes it.
    public var lifecycle: ModelLifecycle = .current
    /// Which Parakeet build FluidAudio loads for it — nil for a Whisper model. Mirrors
    /// FluidAudio's own `AsrModelVersion` cases; `LocalParakeetRuntime.swift` maps one onto
    /// the other, so this file stays free of the framework.
    public var parakeetVersion: ParakeetVersion? = nil
    /// The oldest macOS (major version) the model runs on — what Apple calls a *minimum
    /// system version*. A property of the Mac, not of the vendor: Parakeet Redux and
    /// Phonon-2 compress their encoders with Core ML ops macOS 14 does not have, and
    /// FluidAudio refuses them there before downloading anything. A model above the
    /// running macOS is not offered (`isOffered(on:)`).
    var minimumSystemVersion = 14

    /// Whether the model knows every language the user said they speak. With none stated
    /// the app does not know what will be dictated, so a model that knows only some
    /// languages is not picked for them. Exact codes, as the stated list holds them (every
    /// one of `spokenLanguageCatalog` is in Whisper's lists); a coverage that is not a list
    /// counts as knowing every language.
    func knows(_ stated: [String]) -> Bool {
        guard case .listed(let list) = languages else { return true }
        let codes = Set(list.codes)
        return stated.isEmpty ? codes.count > 1 : Set(stated).isSubset(of: codes)
    }

    public var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }

    /// Whether Settings and setup list the model and the recommendations may pick it: the
    /// one *offered* filter, fed by two separate facts — the vendor's (`lifecycle`)
    /// and this Mac's (`minimumSystemVersion`). Only the offering: the catalogue itself —
    /// normalisation, pricing, History's names — keeps every entry whatever the Mac.
    func isOffered(on capabilities: SystemCapabilities) -> Bool {
        lifecycle.isOffered && capabilities.systemMajorVersion >= minimumSystemVersion
    }
}

/// The Parakeet TDT 0.6B v3 family FluidAudio runs: v3 itself and three re-trainings of
/// it with the same tokenizer, window and decoder contract, so one runtime runs them all.
/// Named as FluidAudio names them (`AsrModelVersion`).
public enum ParakeetVersion: Hashable, Sendable {
    /// NVIDIA's `parakeet-tdt-0.6b-v3`.
    case v3
    /// moondream's post-training of v3: the same 25 languages, more accurate on FLEURS by
    /// FluidAudio's measure (level with v3 on our own corpus).
    case ultra
    /// moondream's ternary re-training of v3: the same 25 languages in half the download.
    case redux
    /// Fermion Research's quantisation-aware re-training of v3, English only.
    case phonon2
}

/// The local models a Mac is offered, in catalogue order.
public func offeredLocalSTTModels(for capabilities: SystemCapabilities) -> [LocalSTTModel] {
    localSTTModels.filter { $0.isOffered(on: capabilities) }
}

private let gigabyte: UInt64 = 1_073_741_824

/// The Parakeet v3 catalogue ID, which is also FluidAudio's own folder name for
/// `FluidInference/parakeet-tdt-0.6b-v3-coreml`. Named once here because the runtime has
/// to pass a folder of exactly this name to `AsrModels.download(to:)` — see
/// `LocalParakeetRuntime.swift`.
public let parakeetV3ModelID = "parakeet-tdt-0.6b-v3"

/// Parakeet Ultra's catalogue ID — FluidAudio's folder name for
/// `FluidInference/parakeet-ultra-coreml`, as v3's is for its repo.
public let parakeetUltraModelID = "parakeet-ultra"

/// Every local speech model on offer, **heaviest first**. Sizes were read from the
/// HuggingFace tree API on 2026-09-16 (each Parakeet measured from an install: v3 on
/// 2026-09-21, Ultra, Redux and Phonon-2 on 2026-10-16).
///
/// A model may know only some languages — Phonon-2 knows English alone — as long as the
/// user can see it before choosing: dictating Ukrainian into an English model produces
/// confident nonsense (the owner's call, 2026-10-16, which dropped the rule that every
/// entry be multilingual). The row's subtitle gives the count ("English only") and a "No …"
/// badge names each of the user's languages it lacks. Such a model is picked only
/// for someone whose stated languages it knows (`knows`).
///
/// The ladder stops at 1.6 GB, and that is not an oversight. Speech models do not scale
/// with the Mac the way chat models do: there is no larger open model with Ukrainian and a
/// Core ML runtime, so a Mac Studio with 512 GB transcribes with the same model a 16 GB
/// MacBook Air does — only faster. Size is not the ranking either. The 483 MB Parakeet
/// beat the 645 MB Turbo and the 1.6 GB full model on the one thing that matters here,
/// which is why the order below is download size and the *picks* are a separate table.
public let localSTTModels: [LocalSTTModel] = [
    LocalSTTModel(
        id: "openai_whisper-large-v3-v20240930",
        engine: .whisperKit,
        displayName: "Whisper Large v3",
        downloadBytes: 1_619_531_263,
        memoryFloorBytes: 24 * gigabyte,
        summary: "The full model, unquantised. In our test it made exactly the same mistakes as Turbo and answered ~30% slower.",
        languages: whisperV3Languages, languageNotes: [:]
    ),
    LocalSTTModel(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        engine: .whisperKit,
        displayName: "Whisper Large v3 Turbo",
        downloadBytes: 645_668_913,
        memoryFloorBytes: 8 * gigabyte,
        summary: "Near-full accuracy at a fraction of the wait.",
        languages: whisperV3Languages, languageNotes: [:]
    ),
    LocalSTTModel(
        id: parakeetUltraModelID,
        engine: .parakeet,
        displayName: "Parakeet Ultra",
        // Measured from an install on 2026-10-16, as v3 was: its four bundles and the
        // vocabulary.
        downloadBytes: 632_314_500,
        memoryFloorBytes: 8 * gigabyte,
        summary: "Parakeet v3 trained further by moondream: the same languages, at the same speed. On our recordings it was as accurate as v3 overall — better on whispered speech and technical terms, once worse on a single word.",
        languages: parakeetLanguages(repository: "FluidInference/parakeet-ultra-coreml"), languageNotes: [:],
        parakeetVersion: .ultra
    ),
    LocalSTTModel(
        id: parakeetV3ModelID,
        engine: .parakeet,
        displayName: "Parakeet v3",
        // Measured from an install on 2026-09-21: the four `.mlmodelc` bundles the int8
        // set needs plus the vocabulary. The repo also carries an int4 encoder and an
        // int8 rebuild, neither of which is downloaded.
        downloadBytes: 483_257_242,
        memoryFloorBytes: 8 * gigabyte,
        summary: "NVIDIA's Parakeet. On our test it matched the best cloud engine word for word, in a third of a second — and it is smaller than Turbo.",
        languages: parakeetV3Languages, languageNotes: [:],
        parakeetVersion: .v3
    ),
    LocalSTTModel(
        id: "phonon-2",
        engine: .parakeet,
        displayName: "Phonon-2",
        // Measured from an install on 2026-10-16. Only `Encoder.mlmodelc` is fetched — the
        // repo's alternative encoders (`Encoder_lut3` and others) are for the GPU, where
        // this one is expanded again on every load.
        downloadBytes: 378_228_114,
        memoryFloorBytes: 8 * gigabyte,
        summary: "Fermion Research's compressed Parakeet v3, as accurate as v3 on its own language and the quickest to load.",
        // English only, as FluidAudio's Documentation/ASR/Phonon2.md says too. Its subtitle says
        // so, and every other language gets the row's "No …" badge.
        languages: parakeetLanguages(repository: "FluidInference/phonon-2-coreml", codes: ["en"]),
        languageNotes: [:],
        parakeetVersion: .phonon2,
        minimumSystemVersion: 15
    ),
    LocalSTTModel(
        id: "parakeet-redux",
        engine: .parakeet,
        displayName: "Parakeet Redux",
        // Measured from an install on 2026-10-16.
        downloadBytes: 220_455_773,
        memoryFloorBytes: 8 * gigabyte,
        summary: "Parakeet v3 in less than half the download, from moondream: the same languages, but it took about a second to answer where v3 takes a quarter. For a full disk.",
        languages: parakeetLanguages(repository: "FluidInference/parakeet-redux-coreml"),
        languageNotes: ["uk": LanguageNote(text: "More mistakes in Ukrainian than Parakeet v3.",
                                           measured: "audio corpus, 2026-10-16, M1 Pro: mean WER 0.226 against v3's 0.180")],
        parakeetVersion: .redux,
        minimumSystemVersion: 15
    ),
    LocalSTTModel(
        id: "openai_whisper-small_216MB",
        engine: .whisperKit,
        displayName: "Whisper Small",
        downloadBytes: 217_350_763,
        memoryFloorBytes: 4 * gigabyte,
        summary: "Small and quick.",
        languages: whisperLanguages,
        languageNotes: ["uk": LanguageNote(text: "Makes mistakes in Ukrainian.",
                                           measured: "2026-09-17, M1 Pro: answered Ukrainian in Russian spelling, 38–100% WER")]
    ),
    LocalSTTModel(
        id: "openai_whisper-base",
        engine: .whisperKit,
        displayName: "Whisper Base",
        downloadBytes: 146_719_453,
        memoryFloorBytes: 2 * gigabyte,
        summary: "Smaller still. The default on Intel Macs, which have no Neural Engine.",
        languages: whisperLanguages,
        languageNotes: ["uk": LanguageNote(text: "Makes mistakes in Ukrainian.",
                                           measured: "2026-09-17, M1 Pro: answered Ukrainian in Russian spelling, 38–100% WER")]
    ),
    LocalSTTModel(
        id: "openai_whisper-tiny",
        engine: .whisperKit,
        displayName: "Whisper Tiny",
        downloadBytes: 76_635_397,
        memoryFloorBytes: 1 * gigabyte,
        summary: "Fast everywhere and accurate nowhere. Useful to prove the pipeline works before a real download.",
        languages: whisperLanguages, languageNotes: [:]
    ),
]

public func localSTTModel(id: String) -> LocalSTTModel? {
    localSTTModels.first { $0.id == id }
}

// MARK: - Tier picks

/// What a tier is offered: the model to install by default and the one to pick for the
/// best result the hardware allows. Each is a list of candidates, not one ID — the first
/// that clears the RAM floor and fits on disk wins — so a tier's pick degrades gracefully
/// on a Mac at the bottom of its memory range, or with a nearly full disk.
///
/// "Recommended" is the fastest model of good enough quality, not the best one: the user
/// is waiting for the paste, and latency is the thing a dictation app is judged on.
struct TierPicks {
    let recommended: [String]
    let bestQuality: [String]
}

/// The step-down floor both lists end on, so a pick always exists if anything fits.
private let sttFallback = ["openai_whisper-small_216MB", "openai_whisper-base", "openai_whisper-tiny"]

func localSTTPicks(for tier: MacTier) -> TierPicks {
    let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    switch tier {
    case .intel:
        // No Neural Engine: the large models run on the CPU, slower than speaking again.
        // Parakeet is excluded for the same reason Whisper's large models are — its
        // encoder is a 0.6B Core ML graph built for the ANE, not for an Intel CPU.
        return TierPicks(recommended: ["openai_whisper-base", "openai_whisper-tiny"],
                         bestQuality: sttFallback)
    case .entry, .standard, .plus, .pro, .max, .ultra:
        // Parakeet leads every Apple Silicon tier, on both counts. Measured 2026-09-21
        // (M1 Pro 32 GB, a real 12.4 s Ukrainian dictation): it returned the same text as
        // ElevenLabs Scribe v2, where cloud Whisper Large v3 Turbo — the same weights as
        // the local Turbo variant, unquantised — misread the first word. Load and decode
        // together took 0.34–0.61 s from a cold process, against Turbo's *nine minutes*
        // of first-load Neural Engine specialisation on this same Mac. It is also 483 MB
        // to Turbo's 645 MB, so there is no tier where it does not fit and Turbo does.
        //
        // Best quality is the same model, and that is not laziness: the full Whisper
        // Large v3 reproduced Turbo's errors word for word ~30% slower (2026-09-17), and
        // Turbo now sits behind Parakeet — so promoting either would recommend worse text.
        // Both lists fall back through Whisper, so a Mac that cannot fit Parakeet or has
        // the ladder half-installed still gets an answer.
        //
        // Since 2026-10-17 (#5) the lists are read through the filters in
        // `pickable(for:languages:)`: the languages the user speaks, macOS, memory and disk. So
        // a list names every model that may be picked here, best first, and the filters
        // decide which of them a particular Mac and person gets — Phonon-2 first only for
        // someone who speaks English alone (as accurate as v3 on our English recordings,
        // smaller and quicker), Redux after v3 for a disk v3 no longer fits on (it is far
        // better in Ukrainian than Whisper Small, the next step down), and Whisper Turbo
        // for a language Parakeet does not know. `LocalModelPickMatrixTests` writes out
        // who gets what.
        return TierPicks(recommended: ["phonon-2", parakeetV3ModelID, "parakeet-redux", turbo] + sttFallback,
                         bestQuality: [parakeetV3ModelID, "parakeet-redux", turbo] + sttFallback)
    }
}

/// The first candidate that clears its RAM floor and fits on disk with a gigabyte to
/// spare. Shared by speech and chat, which differ only in their catalogues.
func firstFitting<Model>(_ candidates: [String], in catalog: [Model],
                         id: (Model) -> String, floor: (Model) -> UInt64, bytes: (Model) -> Int64,
                         capabilities: SystemCapabilities) -> Model? {
    for candidate in candidates {
        guard let model = catalog.first(where: { id($0) == candidate }) else { continue }
        if capabilities.memoryBytes >= floor(model),
           localModelDiskShortfall(downloadBytes: bytes(model), freeDiskBytes: capabilities.freeDiskBytes) == nil {
            return model
        }
    }
    return nil
}

/// What a download leaves free: Core ML's compiled copy, the hash check and every other
/// app on the volume need room after it. The same gigabyte the recommendations keep, so a
/// model they step down from for want of disk is not downloaded either.
let localModelDiskHeadroomBytes: UInt64 = gigabyte

/// Why a download may not start, or nil when it fits: the bytes still to come — the whole
/// file, less what an interrupted download of it already holds on disk — plus the headroom,
/// against the free space on the Application Support root (`SystemCapabilities.freeDiskBytes`).
/// Asked before every download, because one that fills the volume fails every app on it
/// long before URLSession gives up, and its resume data may keep the partial file.
public func localModelDiskShortfall(downloadBytes: Int64, alreadyOnDisk: Int64 = 0,
                             freeDiskBytes: UInt64) -> LocalModelError? {
    let remaining = UInt64(max(0, downloadBytes - max(0, alreadyOnDisk)))
    let needed = remaining + localModelDiskHeadroomBytes
    return freeDiskBytes >= needed ? nil : .insufficientDisk(needed: needed, free: freeDiskBytes)
}

/// The models a pick may land on: offered on this Mac, and knowing every language the
/// user speaks. Memory and disk are `firstFitting`'s.
private func pickable(for capabilities: SystemCapabilities, languages: [String]) -> [LocalSTTModel] {
    offeredLocalSTTModels(for: capabilities).filter { $0.knows(languages) }
}

/// `languages` is "Languages I speak" (`storedSpokenLanguages()`), passed in so the
/// pick stays a pure function of the Mac and the person.
public func recommendedLocalSTTModel(for capabilities: SystemCapabilities, languages: [String] = []) -> LocalSTTModel? {
    firstFitting(localSTTPicks(for: MacTier(capabilities)).recommended, in: pickable(for: capabilities, languages: languages),
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

public func bestQualityLocalSTTModel(for capabilities: SystemCapabilities, languages: [String] = []) -> LocalSTTModel? {
    firstFitting(localSTTPicks(for: MacTier(capabilities)).bestQuality, in: pickable(for: capabilities, languages: languages),
                 id: \.id, floor: \.memoryFloorBytes, bytes: \.downloadBytes, capabilities: capabilities)
}

/// The local speech models as Settings and setup list them, in four runs: the two picks
/// (recommended, then best quality) — the views put Apple Dictation straight after them —
/// then every other model that knows the user's languages, then the ones that lack one,
/// and last the ones this Mac lacks the memory for, which the views keep behind a link.
/// `inSight` is a model that must not hide (the one in use, one on disk, one downloading):
/// a heavy one stays with the models that fit.
public struct LocalSTTListing: Equatable, Sendable {
    public let picks: [LocalSTTModel]
    public let others: [LocalSTTModel]
    public let lackingLanguage: [LocalSTTModel]
    public let heavy: [LocalSTTModel]
}

public func localSTTListing(for capabilities: SystemCapabilities, languages: [String],
                            inSight: (LocalSTTModel) -> Bool = { _ in false }) -> LocalSTTListing {
    let offered = offeredLocalSTTModels(for: capabilities)
    let pickIDs = [recommendedLocalSTTModel(for: capabilities, languages: languages),
                   bestQualityLocalSTTModel(for: capabilities, languages: languages)].compactMap { $0?.id }
    let picks = pickIDs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .compactMap { id in offered.first { $0.id == id } }
    let rest = offered.filter { !pickIDs.contains($0.id) }
    let heavy = rest.filter { !localModelFitsMemory($0.memoryFloorBytes, capabilities) && !inSight($0) }
    let fitting = rest.filter { model in !heavy.contains { $0.id == model.id } }
    return LocalSTTListing(picks: picks,
                           others: fitting.filter { $0.knows(languages) },
                           lackingLanguage: fitting.filter { !$0.knows(languages) },
                           heavy: heavy)
}

/// Whether the Mac has the memory for a model at all — Settings labels heavier ones
/// rather than hiding them, since the user may know better (a Mac that does nothing else).
public func localModelFitsMemory(_ floorBytes: UInt64, _ capabilities: SystemCapabilities) -> Bool {
    capabilities.memoryBytes >= floorBytes
}

/// Why the recommendation landed where it did, in one sentence, for the Settings row.
/// A recommendation the user cannot interrogate is one they have to take on faith.
func localSTTRecommendationReason(for capabilities: SystemCapabilities, languages: [String] = []) -> String {
    guard let model = recommendedLocalSTTModel(for: capabilities, languages: languages) else {
        return "Not enough free disk space to install any local model."
    }
    let tier = MacTier(capabilities)
    if tier == .intel {
        return "\(model.displayName) — Intel Macs have no Neural Engine, so the larger models run too slowly for dictation."
    }
    if model.engine == .whisperKit, localSTTModel(id: parakeetV3ModelID)?.knows(languages) == false, !languages.isEmpty {
        return "\(model.displayName) — Parakeet does not know every language you speak."
    }
    return "\(model.displayName) for a \(tier.displayName) Mac."
}

public enum LocalModelError: LocalizedError, Equatable, Sendable {
    case notInstalled(String)
    case downloadFailed(String)
    /// `needed` counts the headroom, so it is the free space to make, as the user reads it.
    case insufficientDisk(needed: UInt64, free: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "The local model \"\(name)\" is not installed yet"
        case .downloadFailed(let why): "Could not install the local model: \(why)"
        case .insufficientDisk(let needed, let free):
            "Not enough disk space: the download needs \(Self.size(needed)) free, and \(Self.size(free)) is."
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// Which of a download's progress reports reach the main actor. URLSession reports a chat
/// model's download every few kilobytes — hundreds of thousands of times — and the speech
/// engines' downloads are not much quieter; each report was a main-actor task and a new
/// render of both Settings pages. A report is let through once it moved by `step` and
/// `interval` has passed since the last one let through — at most ten a second, about two
/// hundred a download — and the first and the finish always are. One per download; the
/// reports come on whatever thread the downloader has, so it locks.
public final class DownloadProgressThrottle: @unchecked Sendable {
    static let step = 0.005
    static let interval: TimeInterval = 0.1

    private let lock = NSLock()
    private var published: Double?
    private var publishedAt: TimeInterval = 0

    public init() {}

    /// The fraction to publish, held to 0…1, or nil when this report is dropped. `time`
    /// is a parameter so the tests need no clock.
    public func admit(_ fraction: Double, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        let fraction = min(max(fraction, 0), 1)
        return lock.withLock {
            if let published {
                // `abs`: a downloader whose fraction steps back is still shown doing so.
                let moved = abs(fraction - published) >= Self.step && time - publishedAt >= Self.interval
                guard moved || (fraction == 1 && published != 1) else { return nil }
            }
            published = fraction
            publishedAt = time
            return fraction
        }
    }
}

// MARK: - Runtime registration

/// How `makeBatchTranscriber` reaches the local engines without naming either of them.
///
/// The test target compiles `Transcribers.swift`, so that file's switch has to cover
/// `.local` — but it must not drag WhisperKit or FluidAudio in, or the standalone test
/// bundle stops building (see **Tests** in CLAUDE.md). So the app registers a real
/// factory at launch (`registerLocalSTT()` in `LocalSTTRuntime.swift`, which dispatches
/// on the catalogue entry's `LocalSTTEngine`) and everything else talks to this box.
/// Unregistered — which is exactly the test target's state — the tier reports itself
/// unavailable instead of crashing.
///
/// Each box is written once, on main, at launch, before anything reads it: that is what
/// makes the unchecked access safe.
public enum LocalSTT {
    /// Builds a batch provider for an installed model ID. Replaced at launch.
    public nonisolated(unsafe) static var transcriberFactory: (String) -> BatchTranscriber = {
        UnavailableLocalTranscriber(modelID: $0)
    }

    /// Drops a model from memory if it is the one loaded — `LocalModelStore.remove` calls
    /// it, so deleting a model frees its RAM too instead of leaving it resident until the
    /// next switch. Only that model: removing another one must not cost the model in use a
    /// reload in front of the next paste.
    public nonisolated(unsafe) static var releaseModel: (String) -> Void = { _ in }

    /// Loads an installed model in the background, so its load lands before the dictation
    /// that needs it rather than in front of the paste. A no-op for a model already loaded
    /// or not on disk; it never downloads. Replaced at launch.
    public nonisolated(unsafe) static var prewarm: (String) -> Void = { _ in }
}

// MARK: - On-disk layout

/// Where installed models live.
///
/// Inside `Application Support/SpeechText/` on purpose: `TranscriptionHistory`'s
/// `adoptPreRenameStore()` moves that whole folder across a bundle-identifier change,
/// so models survive a rename without a migration of their own.
public func localModelsDirectory() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("SpeechText", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
}

public func localModelFolder(for modelID: String) -> URL {
    localModelsDirectory().appendingPathComponent(modelID, isDirectory: true)
}

/// The compiled bundles Parakeet's loader opens by name. Whisper has no equivalent list
/// — WhisperKit resolves its own file set from the variant — which is why the check
/// below asks for *these four* only when the model is a Parakeet one.
///
/// It matters because Parakeet's download is four separate fetches: an install
/// interrupted after the 433 MB encoder leaves a folder that a "contains a `.mlmodelc`"
/// test calls installed, and the first dictation then fails on a missing decoder
/// instead of the model simply not being there. Ultra, Redux and Phonon-2 install the
/// same four names (seen in real installs on 2026-10-16); Phonon-2's alternative encoders
/// in its repo are not fetched.
public let parakeetRequiredBundles = [
    "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
]

/// Whether a downloaded Parakeet folder holds every bundle the loader opens — the same
/// test as below, for a folder that is not in our layout yet (the runtime's staging).
/// The vocabulary is asked for too: `AsrModels.download` fetched it on its own
/// (FluidInference/FluidAudio#748), while the files-only fetch gets it only as one of the
/// repo's `.json` files, and without it the model fails at its first load rather than at the install.
public func isParakeetFolderComplete(_ folder: URL) -> Bool {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return (parakeetRequiredBundles + ["parakeet_vocab.json"]).allSatisfy(contents.contains)
}

/// Whether a model is ready to transcribe with.
///
/// A plain directory test, and free of both frameworks and the main actor — which is
/// why a finished download is *moved* into our own layout rather than left in the Hub
/// cache's nested `models/<org>/<repo>/` shape. Any thread, any target, can ask.
/// The `.mlmodelc` check matters: an interrupted move leaves the folder there but empty.
/// `in` is a parameter only so the rule above can be tested against a temporary
/// directory; nothing in the app passes it. Reading the real Application Support folder
/// in a test would make the assertion depend on what the user has installed.
public func isLocalModelInstalled(_ modelID: String, in directory: URL = localModelsDirectory()) -> Bool {
    let folder = directory.appendingPathComponent(modelID, isDirectory: true)
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return false }
    if localSTTModel(id: modelID)?.engine == .parakeet {
        return parakeetRequiredBundles.allSatisfy(contents.contains)
    }
    return contents.contains { $0.hasSuffix(".mlmodelc") }
}

/// Stands in for the local engine when none was registered. It never silently returns
/// empty text: a dictation that produced nothing has to surface as an error so the
/// existing failure paths (status overlay, History entry with the audio kept) run.
public struct UnavailableLocalTranscriber: BatchTranscriber, Sendable {
    let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }

    public func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        throw LocalModelError.notInstalled(localSTTModel(id: modelID)?.displayName ?? modelID)
    }
}
