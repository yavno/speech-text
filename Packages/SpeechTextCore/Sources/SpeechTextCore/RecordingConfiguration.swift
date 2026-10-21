// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Everything the engine and the provider factories need for one recording session,
/// read from UserDefaults exactly once (`current()`) and carried through the session.
/// Settings changed mid-recording must not affect the running session — a picker
/// change while the mic was live used to switch the provider between pause and stop.
public struct RecordingConfiguration: Sendable {
    public let provider: STTProviderType
    /// The recognition locale, always a concrete identifier. `var` because
    /// `SpeechEngine.resumeRecording(locale:)` follows the keyboard layout across
    /// segments; everything else is fixed for the session.
    public var locale: String
    /// The languages the user says they speak, as ISO-639-1 codes, in their own order.
    /// Empty when none were named.
    ///
    /// Kept whole alongside `cloudLanguage` because one API takes a *set*: OpenAI's
    /// `gpt-live-transcribe` narrows detection to a list of candidates, where every
    /// other engine here takes a single value or nothing. Defaulted so a configuration
    /// built by hand still describes a valid session.
    public var languages: [String] = []
    /// True when no single language was named, so `locale` is a guess — read off the
    /// keyboard layout, or picked from the several languages the user listed — rather
    /// than the one language they said they were speaking. Only a *single* stated
    /// language is ever forced on an engine that can detect one itself.
    let localeIsAutomatic: Bool
    /// Each provider's API key as `APIKeyStore` held it at the start; a provider with
    /// none stored is absent. One key per provider, whichever step it serves.
    var apiKeys: [Provider: String] = [:]
    /// The speech model stored for each provider; an absent one means its default
    /// (`ProviderDescriptor.speechModel`).
    var models: [Provider: String] = [:]

    /// Drop hesitation sounds, stretched words and trailing-off dots from what the
    /// recogniser returns — see `cleanedTranscript`. `var` with a default so a value
    /// built by hand (the tests) gets the setting's default.
    public var removesDisfluencies = true
    /// How the recogniser's em dashes are drawn — see `DashStyle`. Independent of
    /// `removesDisfluencies`: a user who wants every "е-е-е" kept may still not want "—".
    public var dashStyle: DashStyle = .default
    /// The microphone choice; which device it comes to is looked up each time the audio
    /// engine is built, so a headset that leaves mid-recording falls back on its own.
    public var microphone: MicrophoneChoice = .automatic
    /// The Dictionary's words in the order they are sent to the speech engine
    /// (`CustomVocabulary.ranked`), or empty when the page's switch is off. Each model
    /// takes what its limits allow (`vocabulary(for:)`), and Groq's Whisper a prompt
    /// (`whisperPrompt`). Defaulted so a configuration built by hand sends nothing.
    public var vocabulary: [String] = []

    /// The terms the selected model is sent — the stream, or Apple's recogniser.
    public var liveVocabulary: [String] { vocabulary(for: model) }
    /// The terms a file upload is sent: the batch tier, the stream's fallback, a retry.
    var batchVocabulary: [String] { vocabulary(for: batchDescriptor) }

    /// Who a realtime socket is billed by: the selected model, with the terms it is sent.
    public var streamMeter: UsageMeter {
        UsageMeter(vendor: model.vendor, model: model.id, keyterms: liveVocabulary.count)
    }

    func vocabulary(for descriptor: STTModelDescriptor) -> [String] {
        CustomVocabulary.selected(vocabulary, limits: descriptor.vocabulary.limits)
    }

    /// `cleanedTranscript(text)` when the setting is on, `text` untouched otherwise, with
    /// its dashes in the chosen style either way.
    ///
    /// What is left with no letter or digit in it is nothing: hesitations alone («Um, um,»)
    /// pass `HallucinationFilter` as letters and come out of the cleanup as «, ,» (Scribe
    /// on a cough). Safe on cumulative text — an empty view is a prefix of
    /// whatever real words follow.
    public func cleaned(_ text: String) -> String {
        let cleaned = dashStyle.applied(to: removesDisfluencies ? cleanedTranscript(text) : text)
        return cleaned.contains(where: { $0.isLetter || $0.isNumber }) ? cleaned : ""
    }

    /// Groq Whisper's `prompt`: the ranked words as one line, within its limit — on
    /// trial, and nil when the switch is off or the Dictionary is empty.
    var whisperPrompt: String? { Vocabulary.whisperPrompt(vocabulary) }

    /// The user's Dictionary, read once at the start like everything else here — see
    /// `Vocabulary`. Empty for a value built by hand (the tests). Its words reach the
    /// engine through `vocabulary`; this is what corrects the final text, whatever the
    /// switch says.
    var dictionary: [VocabularyEntry] = []
    /// The Dictionary page's Replacements table — read once at the start, like the words.
    var replacements: [TextReplacementPair] = []

    public init(provider: STTProviderType, locale: String, languages: [String] = [], localeIsAutomatic: Bool,
                apiKeys: [Provider: String] = [:], models: [Provider: String] = [:], removesDisfluencies: Bool = true,
                dashStyle: DashStyle = .default, microphone: MicrophoneChoice = .automatic, vocabulary: [String] = [],
                dictionary: [VocabularyEntry] = [], replacements: [TextReplacementPair] = []) {
        self.provider = provider
        self.locale = locale
        self.languages = languages
        self.localeIsAutomatic = localeIsAutomatic
        self.apiKeys = apiKeys
        self.models = models
        self.removesDisfluencies = removesDisfluencies
        self.dashStyle = dashStyle
        self.microphone = microphone
        self.vocabulary = vocabulary
        self.dictionary = dictionary
        self.replacements = replacements
    }

    /// A segment's text once it is final: `cleaned`, then the Dictionary's wrong
    /// spellings replaced. Not applied to the live text while the user speaks, as
    /// `cleaned` is: a spelling of two words would rewrite a word already drawn on the
    /// overlay, which the span layer would have to draw as a revision. The segment result
    /// replaces the live spans anyway (`commitSegment`), so the stop pastes this.
    public func finished(_ text: String) -> String {
        Self.finished(text, removesDisfluencies: removesDisfluencies, dashStyle: dashStyle,
                      dictionary: dictionary, replacements: replacements)
    }

    /// `finished`, from its parts — `DictationReplay` calls it with a replay's setup. The
    /// dashes are drawn again last, so a replacement that writes "—" follows the style too.
    static func finished(_ text: String, removesDisfluencies: Bool, dashStyle: DashStyle,
                         dictionary: [VocabularyEntry], replacements: [TextReplacementPair]) -> String {
        let clean = dashStyle.applied(to: removesDisfluencies ? cleanedTranscript(text) : text)
        return dashStyle.applied(to: Vocabulary.corrected(clean, entries: dictionary, replacements: replacements))
    }

    /// The language to force on a cloud provider — nil unless the user named exactly one
    /// language, which leaves the model to detect it. Two languages named is still nil:
    /// no provider API takes a set (checked 2026-09-21 — Groq's `language` and
    /// ElevenLabs' `language_code` are single values), and picking one of the two to send
    /// would be the keyboard-layout guess wearing a different hat.
    ///
    /// Whisper and Scribe detect far better than a keyboard layout does:
    /// dictating Ukrainian while the layout was US used to send `language_code=en`, and
    /// a model told the wrong language does not merely mis-spell — it drops most of the
    /// recording and *translates* the rest. Apple is the exception (below): its
    /// recogniser has no auto mode and must be handed a locale.
    public var cloudLanguage: String? { localeIsAutomatic ? nil : locale }

    /// What History records as the segment's language: the locale Apple was given, or
    /// "auto" when a cloud model was left to detect it — so a record never claims a
    /// language that was never requested.
    public var historyLocale: String {
        model.language == .localeRequired ? locale : (cloudLanguage ?? autoLanguageID)
    }

    /// The selected model and what it can do — see `STTModelDescriptor`.
    public var model: STTModelDescriptor {
        sttModel(vendor: provider.vendor, id: modelID(for: provider.vendor))
    }

    /// True when the selected model is served over a realtime WebSocket rather than an
    /// upload endpoint. Two engines have one; whether live text appears is a function of
    /// the stored *model*, not of the engine.
    public var streams: Bool { model.isRealtime }

    /// True when the tier reports text while the user speaks — a realtime stream, or
    /// Apple's on-device recogniser, whose partials arrive as `.live` events too. An
    /// inline dictation shows that text on the overlay; the upload tiers have none to show.
    public var hasLiveText: Bool { model.delivery == .systemRecognizer || streams }

    /// The longest segment the stream's own text is trusted for
    /// (`STTTuning.streamLongestTrustedSegmentSeconds`): a model whose server closes
    /// segments on a pause. nil for one that keeps a single item open until the stop —
    /// OpenAI's, which invented nothing in that time on the corpus.
    public var longestTrustedStreamSegment: Double? {
        guard case .realtime(let shape) = model.delivery, shape.serverVAD else { return nil }
        return STTTuning.streamLongestTrustedSegmentSeconds
    }

    /// Model ID used for any file upload: the stream's fallback, and History retries.
    /// The realtime model only exists behind the WebSocket, so it maps to its vendor's
    /// upload model; Apple has no batch API, so an Apple session's upload goes to Groq.
    public var batchModel: String { batchDescriptor.id }

    /// The engine a file upload goes to — Groq for an Apple session, the selected one
    /// otherwise.
    public var batchProvider: STTProviderType {
        STTProviderType.allCases.first { $0.vendor == batchDescriptor.vendor } ?? provider
    }

    /// The model a file upload goes to, per the selected model's `batchUpload`.
    private var batchDescriptor: STTModelDescriptor {
        let selected = model
        switch selected.batchUpload {
        case .itself:
            return selected
        case .model(let id):
            return sttModel(vendor: selected.vendor, id: id)
        case .selectedModel(let vendor):
            return sttModel(vendor: vendor, id: modelID(for: vendor))
        }
    }

    /// Why a file transcription with these settings cannot start, or nil when it can.
    /// History retry asks this instead of testing the key itself: the local tier needs a
    /// model on disk rather than a key, and "add a Groq key" would be the wrong advice.
    /// `modelInstalled` is a parameter so the check stays testable without a filesystem.
    public func batchUnavailableReason(modelInstalled: (String) -> Bool = { isLocalModelInstalled($0) }) -> String? {
        let batch = batchDescriptor
        if models[batch.vendor] == clearedModelChoice {
            return "Choose a model for \(batch.vendor.modelChoiceTarget) in Settings."
        }
        switch batch.requirement {
        case .none:
            return nil
        case .installedModel:
            guard !modelInstalled(batch.id) else { return nil }
            return "\(batch.displayName) isn't installed — download it in Settings."
        case .apiKey:
            guard apiKey(for: batch.vendor).isEmpty else { return nil }
            return "Retry needs \(batch.vendor.apiKeyPhrase) — add one in Settings."
        }
    }

    /// The engine in use has no model chosen: the launch cleared one that leads to no
    /// model on offer (`clearedModelChoice`), and a dictation is refused until the user
    /// picks — never run on the default in its place (the owner's call, 2026-10-17).
    public var modelChoiceMissing: Bool { models[provider.vendor] == clearedModelChoice }

    /// The speech model stored for a provider, else its default; empty for a cleared choice.
    public func modelID(for vendor: Provider) -> String {
        models[vendor] ?? vendor.defaultSpeechModel
    }

    /// The API key stored for a provider; empty for one that needs none or has none.
    func apiKey(for vendor: Provider) -> String {
        apiKeys[vendor] ?? ""
    }

    /// One read of UserDefaults, and of the API keys `APIKeyStore` holds. `locale` defaults to `resolvedLocale()` (keyboard-layout
    /// aware) but callers that already resolved it pass it through.
    public static func current(locale: String = resolvedLocale()) -> RecordingConfiguration {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: SettingsKeys.sttProvider) ?? "apple"
        let spoken = storedSpokenLanguages()
        var configuration = RecordingConfiguration(
            provider: STTProviderType(rawValue: raw) ?? .apple,
            locale: locale,
            languages: spoken,
            localeIsAutomatic: spoken.count != 1,
            apiKeys: Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
                provider.descriptor.apiKey.map { (provider, APIKeyStore.shared.value(for: $0.settingsKey)) }
            }),
            models: Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
                provider.descriptor.speechModel?.settingsKey
                    .flatMap { defaults.string(forKey: $0) }
                    .map { (provider, $0) }
            }),
            removesDisfluencies: defaults.object(forKey: SettingsKeys.removeDisfluencies) as? Bool ?? true,
            dashStyle: .current,
            microphone: MicrophoneChoice(stored: defaults.string(forKey: SettingsKeys.microphone) ?? ""),
            dictionary: Vocabulary.load(),
            replacements: TextReplacements.load()
        )
        if CustomVocabulary.isSent(defaults) {
            let entries = configuration.dictionary
            // History is searched only when something this session may send cannot take
            // every word — this runs on every start, before the socket opens.
            let capacities = [configuration.model, configuration.batchDescriptor]
                .compactMap { $0.vocabulary.limits?.maxTerms }
            // Groq's prompt holds as many words as fit in `whisperPromptLimit` characters.
            let promptOverflows = configuration.batchDescriptor.vendor == .groq
                && entries.map(\.trimmedTerm).joined(separator: ", ").count + 1 > Vocabulary.whisperPromptLimit
            let rankByUse = promptOverflows || capacities.contains { $0 < entries.count }
            configuration.vocabulary = CustomVocabulary.ranked(entries, now: Date(), rankByUse: rankByUse,
                                                               uses: CustomVocabulary.historyUses)
        }
        return configuration
    }
}
