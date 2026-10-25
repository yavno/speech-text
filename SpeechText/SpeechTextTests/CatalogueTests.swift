// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

// MARK: - RecordingConfiguration derivations

final class RecordingConfigurationTests: XCTestCase {

    /// Constructed directly — never via `current()`, which reads the real defaults.
    private func config(provider: STTProviderType, elevenLabsModel: String = "scribe_v2",
                        groqModel: String = "whisper-large-v3-turbo",
                        localeIsAutomatic: Bool = false) -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "en-US",
                               localeIsAutomatic: localeIsAutomatic,
                               apiKeys: [.groq: "gk", .elevenLabs: "ek"],
                               models: [.groq: groqModel, .elevenLabs: elevenLabsModel])
    }

    func testStreamsOnlyForElevenLabsRealtimeModel() {
        XCTAssertTrue(config(provider: .elevenlabs, elevenLabsModel: elevenLabsRealtimeModel).streams)
        XCTAssertFalse(config(provider: .elevenlabs, elevenLabsModel: "scribe_v2").streams)
        // The model string alone must not be enough: the provider has to match too.
        XCTAssertFalse(config(provider: .groq, elevenLabsModel: elevenLabsRealtimeModel).streams)
        XCTAssertFalse(config(provider: .apple).streams)
    }

    /// The overlay shows what the tier says while the user speaks: a stream's text, and
    /// Apple's on-device partials. An upload tier has nothing to show until the stop.
    func testLiveTextForAStreamAndForApple() {
        XCTAssertTrue(config(provider: .elevenlabs, elevenLabsModel: elevenLabsRealtimeModel).hasLiveText)
        XCTAssertTrue(config(provider: .apple).hasLiveText)
        XCTAssertFalse(config(provider: .elevenlabs, elevenLabsModel: "scribe_v2").hasLiveText)
        XCTAssertFalse(config(provider: .groq).hasLiveText)
        XCTAssertFalse(config(provider: .local).hasLiveText)
    }

    /// scribe_v1 is deprecated, so the stream's fallback — and History retries of a
    /// realtime recording — upload to scribe_v2.
    func testBatchModelMapsRealtimeToScribeV2() {
        XCTAssertEqual(config(provider: .elevenlabs, elevenLabsModel: elevenLabsRealtimeModel).batchModel,
                       "scribe_v2")
        XCTAssertEqual(config(provider: .elevenlabs, elevenLabsModel: "scribe_v2").batchModel,
                       "scribe_v2")
    }

    func testBatchModelForAppleAndGroqIsGroqModel() {
        XCTAssertEqual(config(provider: .apple, groqModel: "whisper-large-v3").batchModel,
                       "whisper-large-v3")
        XCTAssertEqual(config(provider: .groq, groqModel: "whisper-large-v3-turbo").batchModel,
                       "whisper-large-v3-turbo")
    }

    /// The bug this guards: "Auto" resolved the keyboard layout to a locale and then
    /// *forced* it on the cloud model. Dictating Ukrainian with a US layout sent
    /// `language_code=en`, and Scribe answered with a translated fragment of the
    /// recording instead of what was said.
    func testAutomaticLocaleSendsNoLanguageToACloudModel() {
        XCTAssertNil(config(provider: .elevenlabs, localeIsAutomatic: true).cloudLanguage)
        XCTAssertNil(config(provider: .groq, localeIsAutomatic: true).cloudLanguage)
    }

    func testAChosenLanguageIsStillSent() {
        XCTAssertEqual(config(provider: .elevenlabs).cloudLanguage, "en-US")
    }

    // MARK: - Spoken languages

    func testParseDropsUnknownCodesAndDuplicates() {
        XCTAssertEqual(parseSpokenLanguages("uk,en"), ["uk", "en"])
        XCTAssertEqual(parseSpokenLanguages(" UK , en "), ["uk", "en"])
        XCTAssertEqual(parseSpokenLanguages("uk,uk,en"), ["uk", "en"])
        // A code no engine in the catalogue speaks must never reach a request.
        XCTAssertEqual(parseSpokenLanguages("uk,klingon,en"), ["uk", "en"])
        XCTAssertEqual(parseSpokenLanguages(""), [])
    }

    func testMigrationFromTheSingleLanguageSetting() {
        XCTAssertEqual(spokenLanguagesMigrating(from: "uk-UA"), ["uk"])
        XCTAssertEqual(spokenLanguagesMigrating(from: "en-US"), ["en"])
        // "Auto" stated nothing, and neither does a fresh install.
        XCTAssertEqual(spokenLanguagesMigrating(from: autoLanguageID), [])
        XCTAssertEqual(spokenLanguagesMigrating(from: nil), [])
    }

    /// One named language is the only case that forces anything on an engine that can
    /// detect a language itself.
    func testOneLanguageIsForcedOnEveryTier() {
        XCTAssertEqual(resolveLocale(spoken: ["uk"], keyboardLanguage: "en", systemLocale: "fr-FR"),
                       "uk-UA")
    }

    /// Several languages cannot be sent anywhere — no provider API takes a set — so the
    /// answer exists only for Apple, and the layout chooses *among* them.
    func testSeveralLanguagesLetTheLayoutChooseAmongThem() {
        XCTAssertEqual(resolveLocale(spoken: ["uk", "en"], keyboardLanguage: "en", systemLocale: "fr-FR"),
                       "en-US")
        // A layout the user never listed does not get to pick the language: the bug this
        // guards is a Russian layout selecting Russian for a Ukrainian speaker.
        XCTAssertEqual(resolveLocale(spoken: ["uk", "en"], keyboardLanguage: "ru", systemLocale: "fr-FR"),
                       "uk-UA")
        XCTAssertEqual(resolveLocale(spoken: ["uk", "en"], keyboardLanguage: nil, systemLocale: "fr-FR"),
                       "uk-UA")
    }

    func testNoLanguageStatedKeepsTheOldLayoutBehaviour() {
        XCTAssertEqual(resolveLocale(spoken: [], keyboardLanguage: "uk", systemLocale: "fr-FR"), "uk")
        XCTAssertEqual(resolveLocale(spoken: [], keyboardLanguage: nil, systemLocale: "fr-FR"), "fr-FR")
    }

    /// Every catalogue entry has to be usable by both halves: an ISO-639-1 code for the
    /// cloud tiers, and a regional locale for Apple, which takes nothing else.
    func testCatalogueEntriesAreWellFormed() {
        XCTAssertFalse(spokenLanguageCatalog.isEmpty)
        for language in spokenLanguageCatalog {
            XCTAssertEqual(language.id.count, 2, "\(language.id) is not an ISO-639-1 code")
            XCTAssertTrue(language.localeIdentifier.hasPrefix("\(language.id)-")
                          // Norwegian's locale is nb-NO, whose language subtag is not "no".
                          || language.id == "no",
                          "\(language.id) does not match \(language.localeIdentifier)")
        }
        XCTAssertEqual(Set(spokenLanguageCatalog.map(\.id)).count, spokenLanguageCatalog.count)
    }

    /// Apple's recogniser has no auto mode, so the keyboard-layout guess is all it can
    /// be given — and History records what was actually requested of each tier.
    func testHistoryLocaleRecordsWhatWasRequested() {
        XCTAssertEqual(config(provider: .apple, localeIsAutomatic: true).historyLocale, "en-US")
        XCTAssertEqual(config(provider: .elevenlabs, localeIsAutomatic: true).historyLocale, autoLanguageID)
        XCTAssertEqual(config(provider: .elevenlabs).historyLocale, "en-US")
    }
}

// MARK: - Speech model catalogue (STTModelCatalog.swift)

final class STTModelCatalogTests: XCTestCase {

    private func config(_ provider: STTProviderType, groqModel: String = "whisper-large-v3-turbo",
                        groqKey: String = "gk", elevenLabsModel: String = "scribe_v2",
                        openAISTTModel: String = "gpt-transcribe",
                        localModel: String = parakeetV3ModelID,
                        localeIsAutomatic: Bool = true) -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: localeIsAutomatic, apiKeys: [.groq: groqKey, .elevenLabs: "ek", .openAI: "ok"], models: [.groq: groqModel, .elevenLabs: elevenLabsModel, .openAI: openAISTTModel, .local: localModel])
    }

    // Invariants

    func testEveryRealtimeModelFallsBackToAnUploadModelOfItsOwnVendor() {
        let realtime = sttModelCatalog.filter(\.isRealtime)
        XCTAssertFalse(realtime.isEmpty)
        for model in realtime {
            guard case .model(let id) = model.batchUpload else {
                return XCTFail("\(model.id) names no upload model")
            }
            let fallback = sttModelCatalog.first { $0.vendor == model.vendor && $0.id == id }
            XCTAssertEqual(fallback?.delivery, .upload, "\(model.id) → \(id)")
        }
    }

    func testOnlyAppleBorrowsAnotherVendorsSelection() {
        for model in sttModelCatalog {
            guard case .selectedModel(let vendor) = model.batchUpload else { continue }
            XCTAssertEqual(model.delivery, .systemRecognizer, model.id)
            XCTAssertTrue(knownSTTModels(of: vendor).allSatisfy { $0.delivery == .upload }, model.id)
        }
    }

    func testEveryKeyIsAStoredSettingAndEveryCloudModelNeedsOne() {
        for model in sttModelCatalog {
            switch model.delivery {
            case .upload, .realtime:
                guard case .apiKey(let key) = model.requirement else {
                    XCTFail("\(model.id) is served from the cloud but needs no key"); continue
                }
                XCTAssertTrue(APIKeyStore.keys.contains(key), "\(model.id): \(key)")
            case .onDevice:
                XCTAssertEqual(model.requirement, .installedModel, model.id)
            case .systemRecognizer:
                XCTAssertEqual(model.requirement, .none, model.id)
            }
        }
        // One vendor, one key — its own.
        for vendor in Provider.allCases {
            for model in knownSTTModels(of: vendor) {
                guard case .apiKey(let key) = model.requirement else { continue }
                XCTAssertEqual(key, vendor.descriptor.apiKey?.settingsKey, model.id)
            }
            XCTAssertLessThanOrEqual(Set(knownSTTModels(of: vendor).map(\.requirement)).count, 1, vendor.rawValue)
        }
    }

    func testNoModelClaimsACapabilityItsTransportLacks() {
        for model in sttModelCatalog {
            if model.language == .set { XCTAssertTrue(model.isRealtime, model.id) }
            if model.language == .localeRequired { XCTAssertEqual(model.delivery, .systemRecognizer, model.id) }
            if !model.isRealtime, case .model = model.batchUpload { XCTFail("\(model.id) maps an upload away") }
        }
    }

    func testEveryModelBelongsToOneVendorAndIsListedOnce() {
        for vendor in Provider.allCases where vendor.descriptor.roles.contains(.speech) {
            let ids = knownSTTModels(of: vendor).map(\.id)
            XCTAssertFalse(ids.isEmpty, vendor.rawValue)
            XCTAssertEqual(ids.count, Set(ids).count, vendor.rawValue)
        }
        for provider in STTProviderType.allCases {
            XCTAssertFalse(knownSTTModels(of: provider.vendor).isEmpty, provider.rawValue)
        }
    }

    /// The descriptor's rate is the one the provider really declares.
    func testRealtimeShapesMatchTheirProviders() throws {
        for model in sttModelCatalog {
            guard case .realtime(let shape) = model.delivery else { continue }
            let provider = try XCTUnwrap(STTProviderType.allCases.first { $0.vendor == model.vendor }, model.id)
            let streaming = try XCTUnwrap(makeStreamingTranscriber(configuration: config(
                provider, groqModel: model.id, elevenLabsModel: model.id, openAISTTModel: model.id)), model.id)
            XCTAssertEqual(streaming.sampleRate, shape.sampleRate, model.id)
        }
    }

    /// The pickers read the catalogue, in the order and with the names they had.
    func testPickersKeepTheirOrderAndNames() {
        XCTAssertEqual(offeredSTTModels(of: .groq).map(\.id), ["whisper-large-v3-turbo", "whisper-large-v3"])
        XCTAssertEqual(offeredSTTModels(of: .elevenLabs).map(\.displayName), ["Scribe v2", "Scribe v2 Realtime — live text"])
        XCTAssertEqual(offeredSTTModels(of: .openAI).map(\.id), ["gpt-transcribe", openAIRealtimeSTTModel])
        // Deprecated by OpenAI, so no longer offered, but still known to History.
        XCTAssertEqual(knownSTTModels(of: .openAI).map(\.id), ["gpt-transcribe", "gpt-4o-mini-transcribe", openAIRealtimeSTTModel])
        XCTAssertEqual(offeredSTTModels(of: .local).map(\.id), localSTTModels.map(\.id))
        for local in localSTTModels {
            XCTAssertEqual(sttModel(vendor: .local, id: local.id).delivery, .onDevice(local.engine))
        }
    }

    // Behaviour the descriptor must not change

    /// Apple's upload goes to the Groq model the user picked, not to a fixed one.
    func testAppleUploadsToTheStoredGroqModel() {
        XCTAssertEqual(config(.apple, groqModel: "whisper-large-v3").batchModel, "whisper-large-v3")
        XCTAssertEqual(config(.apple, groqKey: "").batchUnavailableReason(),
                       "Retry needs a Groq API key — add one in Settings.")
    }

    func testAppleRecordsItsLocaleAndTheCloudRecordsAuto() {
        XCTAssertEqual(config(.apple).historyLocale, "uk-UA")
        XCTAssertEqual(config(.groq).historyLocale, autoLanguageID)
        XCTAssertEqual(config(.groq, localeIsAutomatic: false).historyLocale, "uk-UA")
        XCTAssertTrue(config(.apple).hasLiveText)
        XCTAssertFalse(config(.groq).hasLiveText)
    }

    /// An ID the catalogue does not list behaves as it did before there was one.
    func testAnUnlistedModelUploadsUnderItsOwnID() {
        let groq = config(.groq, groqModel: "whisper-next")
        XCTAssertFalse(groq.streams)
        XCTAssertEqual(groq.batchModel, "whisper-next")
        XCTAssertNil(groq.batchUnavailableReason())
        XCTAssertEqual(config(.groq, groqModel: "whisper-next", groqKey: "").batchUnavailableReason(),
                       "Retry needs a Groq API key — add one in Settings.")

        let local = config(.local, localModel: "openai_whisper-gone")
        XCTAssertEqual(local.batchModel, "openai_whisper-gone")
        XCTAssertEqual(local.batchUnavailableReason(modelInstalled: { _ in false }),
                       "openai_whisper-gone isn't installed — download it in Settings.")
    }

    func testEachVendorsRetryNoticeNamesItsKey() {
        let elevenLabs = RecordingConfiguration(provider: .elevenlabs, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "gk", .elevenLabs: ""], models: [.groq: "", .elevenLabs: elevenLabsRealtimeModel])
        XCTAssertEqual(elevenLabs.batchUnavailableReason(), "Retry needs an ElevenLabs API key — add one in Settings.")
        let openAI = RecordingConfiguration(provider: .openai, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "gk", .elevenLabs: "ek", .openAI: ""], models: [.groq: "", .elevenLabs: "", .openAI: openAIRealtimeSTTModel])
        XCTAssertEqual(openAI.batchUnavailableReason(), "Retry needs an OpenAI API key — add one in Settings.")
        XCTAssertEqual(config(.local).batchUnavailableReason(modelInstalled: { _ in false }),
                       "Parakeet v3 isn't installed — download it in Settings.")
    }
}

// MARK: - Names that are stored (ProviderRegistry.swift)

/// Literal values that live outside the code — in UserDefaults, the keychain and History —
/// so a list derived from the provider registry must keep producing exactly these.
final class StoredProviderNameTests: XCTestCase {

    /// `APIKeyStore.open` moves and deletes exactly these names, which are also the
    /// keychain accounts; a key that left the list would be stranded in a plist.
    /// The model lifecycle's two machine-local keys.
    func testTheModelLifecycleKeysKeepTheirStoredNames() {
        XCTAssertEqual(SettingsKeys.modelMigrations, "modelMigrations")
        XCTAssertEqual(SettingsKeys.modelNoticesShown, "modelNoticesShown")
    }

    func testTheAPIKeysKeepTheirStoredNames() {
        XCTAssertEqual(APIKeyStore.keys, ["groqAPIKey", "elevenLabsAPIKey", "anthropicAPIKey", "openAIAPIKey"])
    }

    /// Each provider serves exactly the steps a pick maps to it for.
    func testEveryProvidersRolesAreTheOnesItsPicksGiveIt() {
        for provider in Provider.allCases {
            let roles = provider.descriptor.roles
            XCTAssertEqual(roles.contains(.speech), STTProviderType.allCases.contains { $0.vendor == provider }, provider.rawValue)
            XCTAssertEqual(roles.contains(.chat), LLMProviderType.allCases.contains { $0.vendor == provider }, provider.rawValue)
        }
    }

    func testTheRetryNoticeNamesTheKey() {
        XCTAssertEqual(Provider.groq.apiKeyPhrase, "a Groq API key")
        XCTAssertEqual(Provider.openAI.apiKeyPhrase, "an OpenAI API key")
        XCTAssertEqual(Provider.elevenLabs.apiKeyPhrase, "an ElevenLabs API key")
    }

    func testOnlyAFreePlanIsOfferedAsAFreeKey() {
        XCTAssertEqual(Provider.groq.linkTitle, "Get your free key ↗")
        XCTAssertEqual(Provider.openAI.linkTitle, "Get your key ↗")
    }

    /// What a rename carries over (`adoptPreRenameDefaults`). The model keys in it are
    /// derived from the registry; a key that left the list would be lost at the next
    /// rename. Order does not matter, membership does.
    func testThePortableSettingsKeepTheirStoredNames() {
        XCTAssertEqual(Set(SettingsKeys.portable), [
            "selectedLanguage", "spokenLanguages",
            "sttProvider", "groqModel", "elevenLabsModel", "openAISTTModel", "localSTTModel",
            "removeDisfluencies", "dashStyle",
            "vocabulary", "sendVocabularyToEngine", "textReplacements",
            "hotkeyKeyCode", "hotkeyModifierFlags",
            "recordWindowHotkeyKeyCode", "recordWindowHotkeyModifierFlags",
            "aiHotkeyKeyCode", "aiHotkeyModifierFlags",
            "editHotkeyKeyCode", "editHotkeyModifierFlags",
            "holdToTalk", "escapeCancelsDictation",
            "llmProvider", "groqLLMModel", "anthropicModel", "openAIModel", "localLLMModel",
            "promptPresets", "defaultPresetID", "aiModeInRecordWindow",
            "appSkin", "accentColor", "technoPhosphor", "glassTransparency", "dockIconMode",
            "hotkeyLayoutVersion",
        ])
        XCTAssertEqual(SettingsKeys.portable.count, Set(SettingsKeys.portable).count, "listed twice")
    }

    /// A default is a pointer into the provider's own catalogue, and every model key is
    /// stored, carried across a rename, and named once.
    func testEveryDefaultModelIsOneTheProviderOffers() {
        for engine in STTProviderType.allCases {
            let setting = engine.vendor.descriptor.speechModel
            XCTAssertNotNil(setting, engine.rawValue)
            XCTAssertTrue(offeredSTTModels(of: engine.vendor).map(\.id).contains(engine.vendor.defaultSpeechModel), engine.rawValue)
        }
        for type in LLMProviderType.allCases {
            let setting = type.vendor.descriptor.chatModel
            XCTAssertNotNil(setting, type.rawValue)
            guard setting?.normalized == true else { continue }
            XCTAssertTrue(offeredChatModels(of: type).contains { $0.id == type.vendor.defaultChatModel }, type.rawValue)
        }
        let keys = Provider.allCases.flatMap { [$0.descriptor.speechModel?.settingsKey, $0.descriptor.chatModel?.settingsKey] }
            .compactMap { $0 }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertTrue(Set(keys).isSubset(of: SettingsKeys.portable))
    }

    /// The defaults today, literally: moving one is a decision, and the catalogue entries
    /// do not move with it.
    func testTheDefaultModelsAreTheChosenOnes() {
        XCTAssertEqual(Provider.groq.defaultSpeechModel, "whisper-large-v3-turbo")
        XCTAssertEqual(Provider.elevenLabs.defaultSpeechModel, "scribe_v2")
        XCTAssertEqual(Provider.openAI.defaultSpeechModel, "gpt-transcribe")
        XCTAssertEqual(Provider.local.defaultSpeechModel, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(Provider.groq.defaultChatModel, "openai/gpt-oss-120b")
        XCTAssertEqual(Provider.anthropic.defaultChatModel, "claude-sonnet-5")
        XCTAssertEqual(Provider.openAI.defaultChatModel, "gpt-5.6-luna")
        XCTAssertEqual(Provider.local.defaultChatModel, "gemma-4-12b-it-qat-q4_0")
        XCTAssertEqual(Provider.ollama.defaultChatModel, "")
    }

    /// A configuration with nothing stored runs every provider's default and no key.
    func testAnAbsentModelIsTheDefaultAndAnAbsentKeyIsEmpty() {
        let bare = RecordingConfiguration(provider: .openai, locale: "uk-UA", localeIsAutomatic: true)
        XCTAssertEqual(bare.model.id, "gpt-transcribe")
        XCTAssertEqual(bare.modelID(for: .elevenLabs), "scribe_v2")
        XCTAssertEqual(bare.apiKey(for: .openAI), "")
        let local = RecordingConfiguration(provider: .local, locale: "uk-UA", localeIsAutomatic: true)
        XCTAssertEqual(local.model.id, "parakeet-tdt-0.6b-v3")
    }

    /// `sttProvider` / `llmProvider` store these, and History records them as `provider`.
    func testTheEngineAndProviderPicksKeepTheirStoredNames() {
        XCTAssertEqual(STTProviderType.allCases.map(\.rawValue), ["apple", "groq", "elevenlabs", "openai", "local"])
        XCTAssertEqual(LLMProviderType.allCases.map(\.rawValue), ["groq", "anthropic", "openai", "local"])
    }

    /// AI Rewrite through Ollama moves to the built-in path on the same model where the
    /// catalogue has it, and Ollama's settings go (2026-10-16).
    func testAnOllamaPickMovesToTheBuiltInPath() {
        let suite = "ollama-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ollama", forKey: SettingsKeys.llmProvider)
        defaults.set("qwen3.5:9b", forKey: "ollamaModel")
        defaults.set("http://studio.local:11434", forKey: "ollamaBaseURL")
        migrateOllamaPick(defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "local")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.localLLMModel), "Qwen3.5-9B-Q4_K_M")
        XCTAssertNil(defaults.string(forKey: "ollamaModel"))
        XCTAssertNil(defaults.string(forKey: "ollamaBaseURL"))

        // Another provider is left alone; the leftover settings still go.
        defaults.set("groq", forKey: SettingsKeys.llmProvider)
        defaults.set("gemma4:12b", forKey: "ollamaModel")
        migrateOllamaPick(defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "groq")
        XCTAssertNil(defaults.string(forKey: "ollamaModel"))
    }
}
