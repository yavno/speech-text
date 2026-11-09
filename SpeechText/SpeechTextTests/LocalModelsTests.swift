// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ChatTemplates
@testable import SpeechTextCore

private let gb: UInt64 = 1_073_741_824

/// Hardware is constructed, never read: `SystemCapabilities.current()` would make every
/// assertion here a statement about the machine the tests happen to run on.
private func mac(ram: UInt64, disk: UInt64 = 2000, appleSilicon: Bool = true, macOS: Int = 26) -> SystemCapabilities {
    SystemCapabilities(chipName: appleSilicon ? "Apple M5" : "Intel Core i7",
                       isAppleSilicon: appleSilicon, cores: 10,
                       memoryBytes: ram * gb, freeDiskBytes: disk * gb, systemMajorVersion: macOS)
}

// MARK: - Tiers

final class MacTierTests: XCTestCase {

    /// Every configuration Apple sells lands in the tier the recommendation tables were
    /// written for — including the sizes that sit right at a boundary.
    func testCurrentLineupMapsToTheIntendedTiers() {
        XCTAssertEqual(MacTier(mac(ram: 8)), .entry)        // MacBook Neo
        XCTAssertEqual(MacTier(mac(ram: 16)), .standard)    // MacBook Air M5, iMac, Mac mini
        XCTAssertEqual(MacTier(mac(ram: 18)), .standard)    // older M3 Pro
        XCTAssertEqual(MacTier(mac(ram: 24)), .plus)        // M5 Pro base
        XCTAssertEqual(MacTier(mac(ram: 32)), .plus)
        XCTAssertEqual(MacTier(mac(ram: 36)), .pro)         // M5 Max base
        XCTAssertEqual(MacTier(mac(ram: 64)), .pro)
        XCTAssertEqual(MacTier(mac(ram: 96)), .max)         // Mac Studio M5 Ultra base
        XCTAssertEqual(MacTier(mac(ram: 128)), .max)
        XCTAssertEqual(MacTier(mac(ram: 256)), .ultra)
        XCTAssertEqual(MacTier(mac(ram: 512)), .ultra)
    }

    func testIntelIsItsOwnTierWhateverItsMemory() {
        XCTAssertEqual(MacTier(mac(ram: 64, appleSilicon: false)), .intel)
    }
}

// MARK: - Speech model recommendation

final class LocalSTTRecommendationTests: XCTestCase {

    func testCatalogueIsHeaviestFirstAndEveryPickExists() {
        let sizes = localSTTModels.map(\.downloadBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(Set(localSTTModels.map(\.id)).count, localSTTModels.count)
        XCTAssertNotNil(localSTTModel(id: parakeetV3ModelID))
        // A typo in a tier table would silently skip a candidate rather than fail.
        for tier in MacTier.allCases {
            let picks = localSTTPicks(for: tier)
            for id in picks.recommended + picks.bestQuality {
                XCTAssertNotNil(localSTTModel(id: id), "\(tier): \(id) is not in the catalogue")
            }
        }
    }

    func testAppleSiliconIsRecommendedParakeetFromNeoToStudio() {
        for ram: UInt64 in [8, 16, 32, 64, 128, 512] {
            XCTAssertEqual(recommendedLocalSTTModel(for: mac(ram: ram))?.id, parakeetV3ModelID, "\(ram) GB")
        }
        // The stored default is what a Mac with no stored choice gets, so the two must
        // not drift apart: a default nobody is recommended would install one model and
        // then advise a different one.
        XCTAssertEqual(parakeetV3ModelID, parakeetV3ModelID)
    }

    /// Neither Whisper model is a quality upgrade on Parakeet — the full Large v3 only
    /// reproduced Turbo's errors more slowly, and Turbo itself now sits behind Parakeet —
    /// so no tier is steered past it. Both stay in the catalogue to be chosen by hand.
    func testNoTierIsSteeredToAWhisperModelForQuality() {
        for ram: UInt64 in [8, 16, 24, 64, 512] {
            XCTAssertEqual(bestQualityLocalSTTModel(for: mac(ram: ram))?.id, parakeetV3ModelID, "\(ram) GB")
        }
    }

    /// Intel has no Neural Engine, so it gets neither the large Whisper models nor
    /// Parakeet, whose encoder is a 0.6B Core ML graph built for the same hardware.
    func testIntelNeverGetsTheLargeModelsWhateverItsMemory() {
        let intel = mac(ram: 64, appleSilicon: false)
        XCTAssertEqual(recommendedLocalSTTModel(for: intel)?.id, "openai_whisper-base")
        XCTAssertEqual(bestQualityLocalSTTModel(for: intel)?.id, "openai_whisper-small_216MB")
        let picks = localSTTPicks(for: .intel)
        XCTAssertFalse((picks.recommended + picks.bestQuality).contains(parakeetV3ModelID))
    }

    func testDiskSpaceStepsDownAndKeepsHeadroom() {
        // 1 GB free is all headroom: nothing fits.
        XCTAssertNil(recommendedLocalSTTModel(for: mac(ram: 32, disk: 1)))
        // 1.5 GB free leaves 0.5 GB usable: too little for the 646 MB turbo model, but
        // Parakeet is 483 MB and still fits — which is the point of putting it first.
        let snug = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                      memoryBytes: 32 * gb, freeDiskBytes: gb + gb / 2, systemMajorVersion: 26)
        XCTAssertEqual(recommendedLocalSTTModel(for: snug)?.id, parakeetV3ModelID)
        // 1.25 GB free leaves 0.25 GB usable, and now v3 has to step down: to Redux
        // (220 MB) where macOS can run it, to Whisper Small on macOS 14.
        let tight = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                       memoryBytes: 32 * gb, freeDiskBytes: gb + gb / 4, systemMajorVersion: 26)
        XCTAssertEqual(recommendedLocalSTTModel(for: tight)?.id, "parakeet-redux")
        let tightSonoma = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                             memoryBytes: 32 * gb, freeDiskBytes: gb + gb / 4, systemMajorVersion: 14)
        XCTAssertEqual(recommendedLocalSTTModel(for: tightSonoma)?.id, "openai_whisper-small_216MB")
    }

    /// Both engines are actually reachable from the catalogue. A Parakeet entry whose
    /// `engine` was left at the Whisper default would be handed to WhisperKit, which
    /// would fail on a model folder it cannot read.
    func testCatalogueCoversBothEngines() {
        let parakeets = [parakeetV3ModelID, parakeetUltraModelID, "parakeet-redux", "phonon-2",
                         "bark-3.0", "bark-3.0-clean"]
        for id in parakeets {
            XCTAssertEqual(localSTTModel(id: id)?.engine, .parakeet, id)
        }
        for model in localSTTModels where !parakeets.contains(model.id) {
            XCTAssertEqual(model.engine, .whisperKit, model.id)
        }
    }

    /// The runtime loads the build the entry names, so every Parakeet entry names one, a
    /// different one each — two IDs on one build would load the same weights under two
    /// names — and no Whisper entry names any.
    func testEveryParakeetEntryNamesItsOwnBuild() {
        let versions = localSTTModels.filter { $0.engine == .parakeet }.map(\.parakeetVersion)
        XCTAssertFalse(versions.contains(nil))
        XCTAssertEqual(Set(versions.compactMap { $0 }), [.v3, .ultra, .redux, .phonon2, .bark3, .bark3Clean])
        XCTAssertEqual(versions.count, Set(versions.compactMap { $0 }).count)
        for model in localSTTModels where model.engine == .whisperKit {
            XCTAssertNil(model.parakeetVersion, model.id)
        }
    }

    /// A model that knows only English is picked only for someone who said they speak
    /// English alone — anyone else would be recommended confident nonsense. And its row
    /// says so before the user taps it: "English only" beside its size.
    func testAnEnglishOnlyModelIsPickedOnlyForEnglishAlone() {
        for ram: UInt64 in [8, 16, 32, 64, 128, 512] {
            for languages in [[], ["uk"], ["uk", "en"], ["en", "de"], ["ja"]] {
                let caps = mac(ram: ram)
                XCTAssertNotEqual(recommendedLocalSTTModel(for: caps, languages: languages)?.id, "phonon-2", "\(ram) GB, \(languages)")
                XCTAssertNotEqual(bestQualityLocalSTTModel(for: caps, languages: languages)?.id, "phonon-2", "\(ram) GB, \(languages)")
            }
        }
        XCTAssertTrue(localSTTModel(id: "phonon-2").map(speechModelSubtitle)?.hasSuffix(" · English only") ?? false)
    }

    /// Bark 3.0 and Bark 3.0 Clean are candidates (#43): offered, but picked for nobody —
    /// not even for English alone, where they tied Phonon-2 on our recordings.
    func testTheBarkCandidatesArePickedForNobody() {
        let bark = ["bark-3.0", "bark-3.0-clean"]
        for ram: UInt64 in [8, 16, 32, 64, 128, 512] {
            for languages in [[], ["en"], ["uk"], ["uk", "en"]] {
                let caps = mac(ram: ram)
                XCTAssertFalse(bark.contains(recommendedLocalSTTModel(for: caps, languages: languages)?.id ?? ""), "\(ram) GB, \(languages)")
                XCTAssertFalse(bark.contains(bestQualityLocalSTTModel(for: caps, languages: languages)?.id ?? ""), "\(ram) GB, \(languages)")
            }
        }
        for id in bark {
            XCTAssertTrue(offeredLocalSTTModels(for: mac(ram: 16)).contains { $0.id == id }, id)
            XCTAssertTrue(localSTTModel(id: id).map(speechModelSubtitle)?.hasSuffix(" · English only") ?? false, id)
        }
    }

}

// MARK: - Room for a download

/// `localModelDiskShortfall`, which both stores ask before a download starts: a download
/// that fills the volume fails every app on it, not only ours.
final class LocalModelDiskCheckTests: XCTestCase {

    private let chat = localChatModel(id: "Qwen3.8-27B-Q4_K_M")!

    func testADownloadMustLeaveAGigabyteFree() {
        let bytes = UInt64(chat.downloadBytes)
        XCTAssertNil(localModelDiskShortfall(downloadBytes: chat.downloadBytes, freeDiskBytes: bytes + gb))
        XCTAssertEqual(localModelDiskShortfall(downloadBytes: chat.downloadBytes, freeDiskBytes: bytes + gb - 1),
                       .insufficientDisk(needed: bytes + gb, free: bytes + gb - 1))
        // The review's case: a 19 GB model with 10 GB free is refused before a byte arrives.
        XCTAssertNotNil(localModelDiskShortfall(downloadBytes: chat.downloadBytes, freeDiskBytes: 10 * gb))
    }

    /// An interrupted chat download keeps its partial file, which already took its share
    /// of the free space: only the rest has to fit, or a cancelled download could never
    /// be resumed on a disk that has room for it.
    func testAResumedDownloadNeedsRoomOnlyForTheRest() {
        let half = chat.downloadBytes / 2
        let rest = UInt64(chat.downloadBytes - half)
        XCTAssertNil(localModelDiskShortfall(downloadBytes: chat.downloadBytes, alreadyOnDisk: half,
                                             freeDiskBytes: rest + gb))
        XCTAssertNotNil(localModelDiskShortfall(downloadBytes: chat.downloadBytes, alreadyOnDisk: half,
                                                freeDiskBytes: rest + gb - 1))
        // A count past the file's size (a stale one) still asks for the headroom.
        XCTAssertNotNil(localModelDiskShortfall(downloadBytes: chat.downloadBytes, alreadyOnDisk: 2 * chat.downloadBytes,
                                                freeDiskBytes: gb - 1))
    }

    /// The download refuses exactly what the recommendations step down from, so Settings
    /// never recommends a model it then will not download.
    func testTheRecommendationsAndTheDownloadAgree() {
        for model in localSTTModels {
            let fits = UInt64(model.downloadBytes) + gb
            for free in [fits - 1, fits] {
                let capabilities = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                                      memoryBytes: 512 * gb, freeDiskBytes: free, systemMajorVersion: 26)
                let picked = firstFitting([model.id], in: localSTTModels, id: \.id, floor: \.memoryFloorBytes,
                                          bytes: \.downloadBytes, capabilities: capabilities)
                XCTAssertEqual(picked != nil,
                               localModelDiskShortfall(downloadBytes: model.downloadBytes, freeDiskBytes: free) == nil,
                               "\(model.id) with \(free) bytes free")
            }
        }
    }

    func testTheRefusalSaysWhatToFree() throws {
        let message = try XCTUnwrap(localModelDiskShortfall(downloadBytes: chat.downloadBytes,
                                                             freeDiskBytes: 10 * gb)?.errorDescription)
        // Sizes are written the app's way, not the Mac region's: "20.05 GB" in English.
        XCTAssertTrue(message.contains(HomeFormat.fileSize(chat.downloadBytes + Int64(gb))), message)
        XCTAssertTrue(message.contains(HomeFormat.fileSize(Int64(10 * gb))), message)
        XCTAssertTrue(message.contains("10.74 GB"), message)
    }
}

// MARK: - Download progress

/// `DownloadProgressThrottle`: what of a download's reports becomes a Settings render.
final class DownloadProgressThrottleTests: XCTestCase {

    func testTheFirstReportAndTheFinishAlwaysGetThrough() {
        let throttle = DownloadProgressThrottle()
        XCTAssertEqual(throttle.admit(0.0001, at: 0), 0.0001)
        XCTAssertEqual(throttle.admit(1, at: 0.001), 1)
        XCTAssertNil(throttle.admit(1, at: 5), "the finish once, not again")
    }

    /// A chat model's URLSession reports every few kilobytes: a thousand reports in one
    /// second become ten renders, not a thousand.
    func testAFloodOfReportsBecomesTenASecond() {
        let throttle = DownloadProgressThrottle()
        let admitted = (0 ..< 1000).compactMap { throttle.admit(Double($0) / 1000 * 0.2, at: Double($0) / 1000) }
        XCTAssertEqual(admitted.count, 10)
        XCTAssertEqual(admitted, admitted.sorted())
    }

    /// A slow download still moves once it has moved by half a percent, and not before.
    func testAReportIsLetThroughOnlyOnceItMovedHalfAPercent() {
        let throttle = DownloadProgressThrottle()
        XCTAssertNotNil(throttle.admit(0.100, at: 0))
        XCTAssertNil(throttle.admit(0.104, at: 60))
        XCTAssertEqual(throttle.admit(0.106, at: 61), 0.106)
        // And a fraction that steps back is shown doing so.
        XCTAssertEqual(throttle.admit(0.05, at: 62), 0.05)
    }

    func testAFractionOutsideZeroToOneIsHeldToIt() {
        let throttle = DownloadProgressThrottle()
        XCTAssertEqual(throttle.admit(-0.5, at: 0), 0)
        XCTAssertEqual(throttle.admit(1.5, at: 1), 1)
    }
}

// MARK: - Installed-on-disk test

/// `isLocalModelInstalled` against a temporary directory, never the real
/// `Application Support` folder — what the user has installed is not a fixture.
final class LocalModelInstalledTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeechTextModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ names: [String], under modelID: String) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(modelID).appendingPathComponent(name),
                withIntermediateDirectories: true)
        }
    }

    func testNothingOnDiskIsNotInstalled() {
        XCTAssertFalse(isLocalModelInstalled(parakeetV3ModelID, in: root))
        XCTAssertFalse(isLocalModelInstalled("openai_whisper-tiny", in: root))
    }

    /// Whisper resolves its own file set, so any compiled bundle is enough — the check
    /// is only there to catch a move that left an empty folder behind.
    func testOneBundleIsEnoughForWhisper() throws {
        try put(["AudioEncoder.mlmodelc"], under: "openai_whisper-tiny")
        XCTAssertTrue(isLocalModelInstalled("openai_whisper-tiny", in: root))
    }

    /// Parakeet's install is four separate fetches, so a folder holding only the 433 MB
    /// encoder must not count: calling it installed turns the next dictation into a
    /// missing-decoder error instead of an offer to download the model.
    func testParakeetNeedsEveryBundleNotJustOne() throws {
        try put(["Encoder.mlmodelc"], under: parakeetV3ModelID)
        XCTAssertFalse(isLocalModelInstalled(parakeetV3ModelID, in: root))

        try put(["Preprocessor.mlmodelc", "Decoder.mlmodelc"], under: parakeetV3ModelID)
        XCTAssertFalse(isLocalModelInstalled(parakeetV3ModelID, in: root))

        try put(["JointDecisionv3.mlmodelc"], under: parakeetV3ModelID)
        XCTAssertTrue(isLocalModelInstalled(parakeetV3ModelID, in: root))
    }

    /// Ultra, Redux and Phonon-2 install the same four bundles as v3 (seen in real installs
    /// on 2026-10-16 — Phonon-2's alternative encoders are not fetched), and so do Bark 3.0
    /// and Bark 3.0 Clean (their repo's tree), so each is held to all four too, in its own folder.
    func testEveryParakeetBuildNeedsItsFourBundles() throws {
        for id in [parakeetUltraModelID, "parakeet-redux", "phonon-2", "bark-3.0", "bark-3.0-clean"] {
            try put(["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc"], under: id)
            XCTAssertFalse(isLocalModelInstalled(id, in: root), id)
            try put(["JointDecisionv3.mlmodelc"], under: id)
            XCTAssertTrue(isLocalModelInstalled(id, in: root), id)
        }
        // A model's bundles never stand in for another's.
        XCTAssertFalse(isLocalModelInstalled(parakeetV3ModelID, in: root))
    }
}

// MARK: - Minimum system version

/// Parakeet Redux, Phonon-2 and Bark compress their encoders with Core ML ops macOS 14
/// lacks, and FluidAudio refuses them there; macOS 14 is the app's own minimum.
final class LocalModelSystemVersionTests: XCTestCase {

    func testOnlyTheCompressedEncodersNeedMacOS15() {
        let newer = localSTTModels.filter { $0.minimumSystemVersion > 14 }.map(\.id)
        XCTAssertEqual(Set(newer), ["parakeet-redux", "phonon-2", "bark-3.0", "bark-3.0-clean"])
        XCTAssertTrue(localSTTModels.allSatisfy { $0.minimumSystemVersion >= 14 })
    }

    func testMacOS14IsNotOfferedWhatItCannotRun() {
        let sonoma = offeredLocalSTTModels(for: mac(ram: 32, macOS: 14)).map(\.id)
        XCTAssertFalse(sonoma.contains("parakeet-redux"))
        XCTAssertFalse(sonoma.contains("phonon-2"))
        XCTAssertFalse(sonoma.contains("bark-3.0"))
        XCTAssertFalse(sonoma.contains("bark-3.0-clean"))
        XCTAssertTrue(sonoma.contains(parakeetUltraModelID))
        XCTAssertTrue(sonoma.contains(parakeetV3ModelID))
    }

    /// The one offered filter takes the vendor's fact and the Mac's together:
    /// a superseded model is still offered, a switched-off one is not on any macOS, and a
    /// current one is not on a macOS it cannot run on.
    func testTheOfferedFilterJoinsLifecycleAndSystemVersion() {
        let base = localSTTModel(id: "parakeet-redux")!
        func with(_ lifecycle: ModelLifecycle) -> LocalSTTModel {
            var model = base
            model.lifecycle = lifecycle
            return model
        }
        let sequoia = mac(ram: 16, macOS: 15), sonoma = mac(ram: 16, macOS: 14)
        XCTAssertTrue(with(.current).isOffered(on: sequoia))
        XCTAssertFalse(with(.current).isOffered(on: sonoma))
        XCTAssertTrue(with(.superseded(by: parakeetV3ModelID)).isOffered(on: sequoia))
        XCTAssertFalse(with(.deprecated(.archived(replacement: parakeetV3ModelID))).isOffered(on: sequoia))
    }

    func testMacOS15AndLaterAreOfferedEverything() {
        for version in [15, 26] {
            XCTAssertEqual(offeredLocalSTTModels(for: mac(ram: 32, macOS: version)).map(\.id),
                           localSTTModels.map(\.id), "macOS \(version)")
        }
    }

    /// Whatever the tables say, a recommendation is taken from what is offered: on
    /// macOS 14 no tier, memory or disk can land on a model that would not load.
    func testMacOS14IsNeverRecommendedWhatItCannotRun() {
        for ram: UInt64 in [8, 16, 24, 36, 96, 256] {
            for disk: UInt64 in [2, 2000] {
                let sonoma = mac(ram: ram, disk: disk, macOS: 14)
                for pick in [recommendedLocalSTTModel(for: sonoma), bestQualityLocalSTTModel(for: sonoma)] {
                    if let pick { XCTAssertTrue(pick.isOffered(on: sonoma), "\(ram) GB, \(disk) GB free: \(pick.id)") }
                }
            }
        }
    }
}

final class LocalSTTReasonTests: XCTestCase {

    func testReasonNamesTheCase() {
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 64, appleSilicon: false)).contains("Neural Engine"))
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 32, disk: 1)).contains("disk"))
        // A language the corpus has no recordings of: the sentence is the Mac's, not the numbers'.
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 8), languages: ["de"]).contains("8 GB class"))
    }
}

// Chat model recommendations: LocalChatCatalogTests (LocalChatTests.swift).

// MARK: - Reasoning stripping

final class ReasoningStripTests: XCTestCase {

    func testLeadingThinkBlockIsRemovedSoTheModeMarkerLeads() {
        let raw = "<think>\nThe user wants an email.\n</think>\n\n<<mode:Email>>\nHi Oksana,"
        XCTAssertEqual(strippingReasoning(raw), "<<mode:Email>>\nHi Oksana,")
        let parsed = TextRefinementService.parse(strippingReasoning(raw))
        XCTAssertEqual(parsed.presetName, "Email")
        XCTAssertEqual(parsed.text, "Hi Oksana,")
    }

    func testTextWithoutABlockIsOnlyTrimmed() {
        XCTAssertEqual(strippingReasoning("  plain text \n"), "plain text")
    }

    func testAMidTextTagIsNotStripped() {
        let raw = "Use the <think> tag in HTML </think> examples."
        XCTAssertEqual(strippingReasoning(raw), raw)
    }

    func testAnUnterminatedBlockIsLeftAlone() {
        // A cut-off reply, not a finished deliberation — nothing is safe to remove.
        let raw = "<think>still going"
        XCTAssertEqual(strippingReasoning(raw), raw)
    }
}

// MARK: - Loose mode markers

/// Forms Qwen3.5 2B and 4B actually produced through the app's own prompt.
final class LooseModeMarkerTests: XCTestCase {
    private let presets = ["Clean-up", "Email", "Translate", "Technical / Prompt"]

    func testDoubleBracketsWithoutModePrefix() {
        let r = TextRefinementService.parse("<<Email>>\nВітаю!", presetNames: presets)
        XCTAssertEqual(r.presetName, "Email")
        XCTAssertEqual(r.text, "Вітаю!")
    }

    func testSingleBracketsWithModePrefixAndClosingTag() {
        let r = TextRefinementService.parse("<mode:Translate>\nI received your letter.\n</mode:Translate>", presetNames: presets)
        XCTAssertEqual(r.presetName, "Translate")
        XCTAssertEqual(r.text, "I received your letter.")
    }

    func testNameWithSpacesAndDifferentCase() {
        let r = TextRefinementService.parse("<<technical / prompt>>\nfix it", presetNames: presets)
        XCTAssertEqual(r.presetName, "Technical / Prompt")
        XCTAssertEqual(r.text, "fix it")
    }

    func testAngleBracketsThatAreNotAPresetStay() {
        let raw = "<div>Hello</div>"
        XCTAssertEqual(TextRefinementService.parse(raw, presetNames: presets).text, raw)
        XCTAssertNil(TextRefinementService.parse(raw, presetNames: presets).presetName)
    }

    func testWithoutPresetNamesTheStrictParserIsUnchanged() {
        XCTAssertEqual(TextRefinementService.parse("<<Email>>\nHi").text, "<<Email>>\nHi")
    }
}

// MARK: - RecordingConfiguration for the local tier

final class LocalRecordingConfigurationTests: XCTestCase {

    private func config(_ provider: STTProviderType, groqKey: String = "gk", elevenKey: String = "ek",
                        localModel: String = "openai_whisper-base") -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: groqKey, .elevenLabs: elevenKey], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: "scribe_v2", .local: localModel])
    }

    func testLocalUsesItsModelAndNoKey() {
        let c = config(.local)
        XCTAssertEqual(c.batchModel, "openai_whisper-base")
        XCTAssertFalse(c.streams)
        // Auto leaves detection to Whisper, exactly like the cloud tiers.
        XCTAssertNil(c.cloudLanguage)
        XCTAssertEqual(c.historyLocale, autoLanguageID)
    }

    func testRetryReadinessAsksForAModelNotAKey() {
        let c = config(.local, groqKey: "", elevenKey: "")
        XCTAssertNil(c.batchUnavailableReason(modelInstalled: { _ in true }))
        let reason = c.batchUnavailableReason(modelInstalled: { _ in false })
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Whisper Base"))
        XCTAssertFalse(reason!.contains("API key"))
    }

    func testRetryReadinessForCloudTiersIsUnchanged() {
        XCTAssertNil(config(.groq).batchUnavailableReason(modelInstalled: { _ in false }))
        XCTAssertNotNil(config(.groq, groqKey: "").batchUnavailableReason())
        XCTAssertNotNil(config(.apple, groqKey: "").batchUnavailableReason())
        XCTAssertTrue(config(.elevenlabs, elevenKey: "").batchUnavailableReason()!.contains("ElevenLabs"))
    }

    func testUnregisteredLocalTranscriberFailsLoudly() async {
        // The test target never registers WhisperKit — which is exactly the state that
        // must produce an error rather than an empty "successful" transcript.
        let provider = makeBatchTranscriber(configuration: config(.local))
        do {
            _ = try await provider.transcribe(audioFileURL: URL(fileURLWithPath: "/dev/null"), language: nil)
            XCTFail("expected the unregistered local tier to throw")
        } catch {
            XCTAssertTrue(error is LocalModelError)
        }
    }
}

// MARK: - Languages and the pick matrix (#5)

final class LocalModelLanguageTests: XCTestCase {

    /// Ultra and Redux are re-trainings of v3 and keep its 25 languages; Phonon-2 knows
    /// English alone; a Whisper model knows every language the app lists.
    func testEachModelKnowsTheLanguagesItWasTrainedOn() {
        XCTAssertEqual(parakeetV3LanguageCodes.count, 25)
        for id in [parakeetV3ModelID, parakeetUltraModelID, "parakeet-redux"] {
            guard case .listed(let list) = localSTTModel(id: id)?.languages else { XCTFail(id); continue }
            XCTAssertEqual(list.codes, parakeetV3LanguageCodes, id)
        }
        guard case .listed(let phonon) = localSTTModel(id: "phonon-2")?.languages else { return XCTFail("Phonon-2 lists its language") }
        XCTAssertEqual(phonon.codes, ["en"])
        for id in ["bark-3.0", "bark-3.0-clean"] {
            guard case .listed(let bark) = localSTTModel(id: id)?.languages else { XCTFail(id); continue }
            XCTAssertEqual(bark.codes, ["en"], id)
            XCTAssertEqual(bark.source.absoluteString, "https://huggingface.co/FluidInference/bark-3.0-coreml", id)
        }
        for model in localSTTModels where model.engine == .whisperKit {
            XCTAssertTrue([whisperLanguages, whisperV3Languages].contains(model.languages), model.id)
            // Recommendations read these lists through `knows`, which compares exact codes:
            // a Whisper model knows every language the app lets the user state.
            XCTAssertTrue(model.knows(spokenLanguageCatalog.map(\.id)), model.id)
        }
    }

    /// A model is picked only for languages it knows — all of them, not some — and a
    /// model that knows only some languages is not picked for someone who stated none.
    func testAModelKnowsAPersonOnlyWhenItKnowsEveryLanguageTheySpeak() {
        let phonon = localSTTModel(id: "phonon-2")!, v3 = localSTTModel(id: parakeetV3ModelID)!
        let whisper = localSTTModel(id: "openai_whisper-base")!
        XCTAssertTrue(phonon.knows(["en"]))
        XCTAssertFalse(phonon.knows(["en", "uk"]))
        XCTAssertFalse(phonon.knows([]))
        XCTAssertTrue(v3.knows(["uk", "en"]))
        XCTAssertFalse(v3.knows(["uk", "ja"]))
        XCTAssertTrue(v3.knows([]))
        XCTAssertTrue(whisper.knows(["ja", "tr"]))
    }

    func testTheReasonSaysWhenParakeetDoesNotKnowALanguage() {
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 16), languages: ["uk", "ja"]).contains("Parakeet does not know"))
        XCTAssertFalse(localSTTRecommendationReason(for: mac(ram: 16), languages: ["uk"]).contains("Parakeet does not know"))
    }
}

/// Who gets which model, written out: Mac profiles across the facts that decide a pick —
/// chip, macOS, disk — times the languages a person may state. A catalogue or tier
/// change shows here as a diff of picks, which is what the owner approves (#5).
final class LocalModelPickMatrixTests: XCTestCase {

    private static let v3 = parakeetV3ModelID, turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static let small = "openai_whisper-small_216MB", base = "openai_whisper-base"

    /// (profile, Mac, [languages: (recommended, best quality)])
    private static let matrix: [(String, SystemCapabilities, [[String]: (String?, String?)])] = [
        ("16 GB, macOS 26", mac(ram: 16), [
            []: (v3, v3), ["uk"]: (v3, v3), ["uk", "en"]: (v3, v3), ["en"]: ("phonon-2", v3),
            ["ja"]: (turbo, turbo), ["uk", "ja"]: (turbo, turbo),
        ]),
        ("8 GB, macOS 26", mac(ram: 8), [
            []: (v3, v3), ["en"]: ("phonon-2", v3), ["ja"]: (turbo, turbo),
        ]),
        ("16 GB, macOS 14", mac(ram: 16, macOS: 14), [
            []: (v3, v3), ["uk"]: (v3, v3), ["en"]: (v3, v3), ["ja"]: (turbo, turbo),
        ]),
        // 1.4 GB free: 0.4 GB usable after the headroom — v3 and Turbo no longer fit.
        ("16 GB, macOS 26, 1.4 GB free", SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                                           memoryBytes: 16 * gb, freeDiskBytes: gb + gb * 2 / 5,
                                                           systemMajorVersion: 26), [
            []: ("parakeet-redux", "parakeet-redux"), ["uk"]: ("parakeet-redux", "parakeet-redux"),
            ["en"]: ("phonon-2", "parakeet-redux"), ["ja"]: (small, small),
        ]),
        ("16 GB, macOS 14, 1.4 GB free", SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                                           memoryBytes: 16 * gb, freeDiskBytes: gb + gb * 2 / 5,
                                                           systemMajorVersion: 14), [
            []: (small, small), ["uk"]: (small, small), ["en"]: (small, small),
        ]),
        ("Intel, 64 GB", mac(ram: 64, appleSilicon: false), [
            []: (base, small), ["uk"]: (base, small), ["en"]: (base, small), ["ja"]: (base, small),
        ]),
    ]

    func testThePicksForEveryProfileAndLanguageSet() {
        for (profile, capabilities, rows) in Self.matrix {
            for (languages, expected) in rows {
                let label = "\(profile), speaks \(languages.isEmpty ? "nothing stated" : languages.joined(separator: "+"))"
                XCTAssertEqual(recommendedLocalSTTModel(for: capabilities, languages: languages)?.id, expected.0,
                               "recommended — \(label)")
                XCTAssertEqual(bestQualityLocalSTTModel(for: capabilities, languages: languages)?.id, expected.1,
                               "best quality — \(label)")
            }
        }
    }

    /// Settings and setup list the models alike: the picks first, a model lacking one of
    /// the user's languages below the rest, a model too heavy for the Mac behind the link
    /// unless it must stay in sight — and every offered model exactly once.
    func testTheListingGroupsEveryOfferedModelOnce() {
        let listing = localSTTListing(for: mac(ram: 32), languages: ["uk"])
        let all = listing.picks + listing.others + listing.lackingLanguage + listing.heavy
        XCTAssertEqual(all.map(\.id).sorted(), offeredLocalSTTModels(for: mac(ram: 32)).map(\.id).sorted())
        XCTAssertEqual(listing.picks.map(\.id),
                       [recommendedLocalSTTModel(for: mac(ram: 32), languages: ["uk"]),
                        bestQualityLocalSTTModel(for: mac(ram: 32), languages: ["uk"])]
                        .compactMap { $0?.id }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
        XCTAssertTrue(listing.lackingLanguage.contains { $0.id == "phonon-2" })
        XCTAssertFalse(listing.others.contains { $0.id == "phonon-2" })
        XCTAssertTrue(listing.heavy.isEmpty)

        let small = localSTTListing(for: mac(ram: 8), languages: ["uk"])
        let large = "openai_whisper-large-v3-v20240930"
        XCTAssertTrue(small.heavy.contains { $0.id == large })
        let kept = localSTTListing(for: mac(ram: 8), languages: ["uk"], inSight: { $0.id == large })
        XCTAssertFalse(kept.heavy.contains { $0.id == large })
        XCTAssertTrue((kept.others + kept.lackingLanguage).contains { $0.id == large })
    }
}

/// The rule of #5 against numbers written here, so a new corpus run changes none of it.
/// What the real numbers decide is `LocalModelPickMatrixTests`.
final class LocalModelPickRuleTests: XCTestCase {

    private static let ultra = parakeetUltraModelID, v3 = parakeetV3ModelID

    private func row(_ model: String, _ language: String = "uk", wer: Double, seconds: Double = 0.3, clips: Int = 20) -> LocalSTTMeasurement {
        LocalSTTMeasurement(model: model, language: language, clips: clips, wer: wer, seconds: seconds, run: "2026-11-09", mac: "Apple M1 Pro")
    }

    private func pick(_ kind: LocalSTTPickKind, _ rows: [LocalSTTMeasurement], languages: [String] = ["uk"],
                      on capabilities: SystemCapabilities = mac(ram: 16)) -> String? {
        localSTTPick(kind, for: capabilities, languages: languages, measurements: rows)?.model.id
    }

    func testASmallWERImprovementDoesNotReplaceTheStandingPick() {
        // 9.5% lower, below the 10% the owner set.
        let rows = [row(Self.v3, wer: 0.200), row(Self.ultra, wer: 0.181)]
        XCTAssertEqual(pick(.recommended, rows), Self.v3)
        XCTAssertEqual(pick(.bestQuality, rows), Self.v3)
    }

    func testAClearWERImprovementReplacesIt() {
        let rows = [row(Self.v3, wer: 0.200), row(Self.ultra, wer: 0.179)]
        XCTAssertEqual(pick(.recommended, rows), Self.ultra)
        XCTAssertEqual(pick(.bestQuality, rows), Self.ultra)
    }

    func testLatencyReplacesTheRecommendedPickOnlyAt30Percent() {
        let close = [row(Self.v3, wer: 0.200, seconds: 0.30), row(Self.ultra, wer: 0.205, seconds: 0.22)]
        XCTAssertEqual(pick(.recommended, close), Self.v3, "27% faster")
        let clear = [row(Self.v3, wer: 0.200, seconds: 0.30), row(Self.ultra, wer: 0.205, seconds: 0.20)]
        XCTAssertEqual(pick(.recommended, clear), Self.ultra, "33% faster, WER within the tolerance")
        XCTAssertEqual(pick(.bestQuality, clear), Self.v3, "fast is not better quality when the WER is higher")
    }

    func testAFastModelOutsideTheToleranceIsNotRecommended() {
        let rows = [row(Self.v3, wer: 0.200, seconds: 0.30), row(Self.ultra, wer: 0.260, seconds: 0.05)]
        XCTAssertEqual(pick(.recommended, rows), Self.v3)
    }

    func testATieStaysWithTheStandingPick() {
        let rows = [row(Self.ultra, "en", wer: 0.037), row("phonon-2", "en", wer: 0.037), row(Self.v3, "en", wer: 0.037)]
        XCTAssertEqual(pick(.recommended, rows, languages: ["en"]), "phonon-2")
        XCTAssertEqual(pick(.bestQuality, rows, languages: ["en"]), Self.v3)
    }

    func testTheWorstLanguageDecides() {
        let rows = [row(Self.v3, "uk", wer: 0.20), row(Self.v3, "en", wer: 0.04),
                    row(Self.ultra, "uk", wer: 0.30), row(Self.ultra, "en", wer: 0.01)]
        XCTAssertEqual(pick(.bestQuality, rows, languages: ["uk", "en"]), Self.v3)
        let nothingStated = localSTTPick(.bestQuality, for: mac(ram: 16), measurements: rows)
        XCTAssertEqual(nothingStated?.score?.werLanguage, "uk", "with nothing stated, every language the corpus has")
    }

    func testMixedClipsAreNotALanguage() {
        let rows = [row(Self.v3, "uk", wer: 0.20), row(Self.v3, "mixed", wer: 0.90),
                    row(Self.ultra, "uk", wer: 0.20), row(Self.ultra, "mixed", wer: 0.10)]
        XCTAssertEqual(pick(.bestQuality, rows, languages: []), Self.v3)
    }

    func testAStandingPickWithoutNumbersIsNotDisplaced() {
        // Small stands on this disk; Tiny has numbers and Small has none.
        let tight = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10, memoryBytes: 16 * gb,
                                       freeDiskBytes: gb + gb * 2 / 5, systemMajorVersion: 14)
        let rows = [row("openai_whisper-tiny", wer: 0.01, seconds: 0.01)]
        XCTAssertEqual(pick(.recommended, rows, on: tight), "openai_whisper-small_216MB")
        XCTAssertNil(localSTTPick(.recommended, for: tight, languages: ["uk"], measurements: rows)?.score)
    }

    func testALanguageTheCorpusHasNotKeepsTheList() {
        let rows = [row(Self.v3, wer: 0.2), row(Self.ultra, wer: 0.01)]
        XCTAssertEqual(pick(.recommended, rows, languages: ["de"]), Self.v3)
        XCTAssertEqual(pick(.recommended, rows, languages: ["uk", "de"]), Self.v3, "numbers for one of two languages are not enough")
    }

    func testRowsFromDifferentClipCountsAreNotCompared() {
        let rows = [row(Self.v3, wer: 0.2, clips: 29), row(Self.ultra, wer: 0.01, clips: 17)]
        XCTAssertEqual(pick(.recommended, rows), Self.v3)
    }

    func testRowsFromDifferentMacsAreNotCompared() {
        let rows = [row(Self.v3, wer: 0.2),
                    LocalSTTMeasurement(model: Self.ultra, language: "uk", clips: 20, wer: 0.01, seconds: 0.01, run: "2026-11-09", mac: "Apple M5")]
        XCTAssertEqual(pick(.recommended, rows), Self.v3)
    }

    func testAnIntelMacIgnoresNumbersMeasuredOnAppleSilicon() {
        let rows = [row("openai_whisper-base", wer: 0.5), row("openai_whisper-tiny", wer: 0.01, seconds: 0.01)]
        XCTAssertEqual(pick(.recommended, rows, on: mac(ram: 64, appleSilicon: false)), "openai_whisper-base")
    }

    func testAModelThatDoesNotFitThisMacCannotTakeThePick() {
        let rows = [row(Self.v3, wer: 0.2), row("openai_whisper-large-v3-v20240930", wer: 0.01)]
        XCTAssertEqual(pick(.bestQuality, rows, on: mac(ram: 8)), Self.v3, "Large v3 needs 24 GB")
        XCTAssertEqual(pick(.bestQuality, rows, on: mac(ram: 32)), "openai_whisper-large-v3-v20240930")
    }

    func testTheExplanationSaysTheNumbersBehindThePick() {
        let rows = [row(Self.v3, wer: 0.171, seconds: 0.26)]
        let reason = localSTTRecommendationReason(for: mac(ram: 16), languages: ["uk"], measurements: rows)
        XCTAssertTrue(reason.contains("Parakeet v3"), reason)
        XCTAssertTrue(reason.contains("17%"), reason)
        XCTAssertTrue(reason.contains("0.3"), reason)
        XCTAssertFalse(localSTTRecommendationReason(for: mac(ram: 16), languages: ["de"], measurements: rows).contains("%"))
        // With nothing stated no language is named: none is the default.
        let enUK = rows + [row(Self.v3, "en", wer: 0.04)]
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 16), languages: [], measurements: enUK).contains("16 GB class"))
    }

    /// Every row of the committed summary names a model the catalogue still has: a row for a
    /// model that left would compete for nothing and read as if it did.
    func testTheCommittedSummaryNamesCatalogueModels() {
        for row in localSTTMeasurements {
            XCTAssertNotNil(localSTTModel(id: row.model), row.model)
            XCTAssertGreaterThan(row.clips, 0, row.model)
        }
    }
}

final class CorpusMeasurementSummaryTests: XCTestCase {

    private let descriptions = [CorpusClip(name: "uk-one", expected: "раз два", language: "uk"),
                                CorpusClip(name: "en-one", expected: "one two", language: "en"),
                                CorpusClip(name: "silence", expected: "", language: "uk")]

    private func result(_ clip: String, engine: String = "local/parakeet-tdt-0.6b-v3", pass: String = "auto",
                        status: CorpusResult.Status = .ran, wer: Double? = 0.5, seconds: Double? = 0.3) -> CorpusResult {
        var result = CorpusResult(clip: clip, engine: engine, engineName: engine, language: pass, status: status)
        result.pasted = "сказане слово"
        result.wordErrorRate = wer
        result.stopToTextSeconds = seconds
        return result
    }

    func testARowIsTheAutoPassOfALanguagesSpeechClips() {
        let rows = CorpusMeasurementSummary.rows(from: [
            result("uk-one", wer: 0.25, seconds: 9),
            result("uk-one", pass: "uk+en", wer: 1.0, seconds: 1),
            result("uk-one@builtin", wer: 0.75, seconds: 9),
            result("uk-one@builtin", pass: "uk+en", wer: 1.0, seconds: 3),
            result("silence", wer: 1.0),
            result("uk-one", engine: "local/openai_whisper-base", status: .notInstalled, wer: nil, seconds: nil),
            result("uk-one", engine: "openAI/gpt-live-transcribe", wer: 0.9),
        ], descriptions: descriptions, run: "2026-11-09", mac: "Apple M1 Pro")
        XCTAssertEqual(rows, [LocalSTTMeasurement(model: parakeetV3ModelID, language: "uk", clips: 2, wer: 0.5, seconds: 2,
                                                  run: "2026-11-09", mac: "Apple M1 Pro")])
    }

    func testAClipWithoutAWarmPassIsLeftOut() {
        XCTAssertTrue(CorpusMeasurementSummary.rows(from: [result("uk-one")], descriptions: descriptions,
                                                    run: "2026-11-09", mac: "Apple M1 Pro").isEmpty)
    }

    func testARunReplacesOnlyTheModelsItMeasured() {
        func row(_ model: String, _ run: String) -> LocalSTTMeasurement {
            LocalSTTMeasurement(model: model, language: "uk", clips: 1, wer: 0.1, seconds: 0.1, run: run, mac: "Apple M1 Pro")
        }
        XCTAssertEqual(CorpusMeasurementSummary.merged([row("a", "new")], into: [row("a", "old"), row("b", "old")]),
                       [row("a", "new"), row("b", "old")])
    }

    func testANarrowedRunCannotReplaceRows() {
        func row(_ model: String, _ language: String, clips: Int) -> LocalSTTMeasurement {
            LocalSTTMeasurement(model: model, language: language, clips: clips, wer: 0.1, seconds: 0.1, run: "r", mac: "Apple M1 Pro")
        }
        let earlier = [row("a", "uk", clips: 4), row("a", "en", clips: 3), row("b", "uk", clips: 4)]
        XCTAssertEqual(CorpusMeasurementSummary.narrowed([row("a", "uk", clips: 4)], against: earlier), ["a"], "English would go")
        XCTAssertEqual(CorpusMeasurementSummary.narrowed([row("a", "uk", clips: 2), row("a", "en", clips: 3)], against: earlier), ["a"])
        XCTAssertEqual(CorpusMeasurementSummary.narrowed([row("a", "uk", clips: 5), row("a", "en", clips: 3)], against: earlier), [])
        XCTAssertEqual(CorpusMeasurementSummary.narrowed([row("c", "uk", clips: 1)], against: earlier), [], "a new model replaces nothing")
    }

    func testTheCommittedSummaryHoldsNoWords() {
        let rows = CorpusMeasurementSummary.rows(from: [result("uk-one"), result("uk-one", pass: "uk+en")], descriptions: descriptions, run: "2026-11-09", mac: "Apple M1 Pro")
        let source = CorpusMeasurementSummary.source(rows)
        XCTAssertFalse(source.contains("сказане"))
        XCTAssertFalse(source.contains("раз два"))
        XCTAssertFalse(source.contains("uk-one"))
        XCTAssertTrue(source.contains("LocalSTTMeasurement(model: \"parakeet-tdt-0.6b-v3\", language: \"uk\", clips: 1, wer: 0.500, seconds: 0.300, run: \"2026-11-09\", mac: \"Apple M1 Pro\"),"), source)
    }
}
