// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension STTProviderType {
    /// The provider that serves the engine.
    public var vendor: Provider {
        switch self {
        case .apple: .apple
        case .groq: .groq
        case .elevenlabs: .elevenLabs
        case .openai: .openAI
        case .local: .local
        }
    }
}

/// One speech model and what it can do, as data.
///
/// Capabilities belong to the *model*, not the provider: Scribe v2 and Scribe v2 Realtime
/// share a vendor, a key and an enum case, and differ on whether text appears while the
/// user speaks. Modelled on `LocalSTTModel`, which already worked this way; every field
/// below used to be a switch branch, a global constant or a comment.
///
/// Vendor-protocol quirks — OpenAI's deltas, Scribe's echo, the pre-session buffer, the
/// commit padding — stay inside each provider. A descriptor says *what* a model does,
/// never how its socket is spoken to.
public struct STTModelDescriptor: Identifiable, Hashable, Sendable {
    /// The ID the vendor's API takes and the settings store. Unique within a vendor only:
    /// a model is always looked up by vendor *and* ID (`sttModel(vendor:id:)`), because a
    /// realtime ID stored for one engine must not make another engine stream.
    public let id: String
    public let vendor: Provider
    public let displayName: String
    public let delivery: Delivery
    let language: LanguageSupport
    /// Where a file of this session's audio is transcribed: the stream's fallback, and
    /// History retries.
    public let batchUpload: BatchUpload
    /// What must be in place before the model can run.
    public let requirement: Requirement
    /// The vendor's list price, checked on `UsagePrices.checked`. Required, so a model
    /// added without one fails to build rather than showing as free.
    public let price: ListPrice<SpeechRates>
    /// Which languages the model knows (`LanguageCoverage`): the vendor's list with its
    /// source and date, `.unpublished`, or `.decidedBySystem` for Apple. Required, so a
    /// model added without it fails to build; the rows' count and "No …" badge read it.
    public let languages: LanguageCoverage
    /// Weaknesses we measured, by language code, shown only to someone who speaks it.
    public let languageNotes: [String: LanguageNote]
    /// Whether the model takes the user's vocabulary, and within what limits. `var` with
    /// a default so a descriptor built without it — every model that takes none, and an
    /// unlisted ID — sends nothing.
    public var vocabulary: Vocabulary = .none
    /// What Settings says under the speech model picker while this model is selected;
    /// every realtime model explains its stream. Nil says nothing.
    public var settingsNote: String? = nil
    /// Where the model is in its vendor's life (`ModelLifecycle`). Only an offered one
    /// reaches a picker, setup or a recommendation; every one is still known to History.
    public var lifecycle: ModelLifecycle = .current

    public enum Delivery: Hashable, Sendable {
        /// A file POSTed after the segment ends.
        case upload
        /// A WebSocket that returns text while the user speaks.
        case realtime(RealtimeShape)
        /// A model downloaded to the Mac and run by one of the local engines.
        case onDevice(LocalSTTEngine)
        /// Apple's `SFSpeechRecognizer`: on-device, with partials while the user speaks,
        /// and nothing behind an upload endpoint.
        case systemRecognizer
    }

    /// How a realtime model's socket behaves, as far as the rest of the app can tell.
    public struct RealtimeShape: Hashable, Sendable {
        /// The only rate the socket takes — 16 kHz for Scribe, exactly 24 kHz for
        /// OpenAI (which calls 16 kHz "below minimum").
        let sampleRate: Double
        let transcripts: TranscriptForm
        /// Whether the server commits a segment on a pause by itself. OpenAI's rejects
        /// `turn_detection` outright, so one item grows until `finish()` commits it.
        let serverVAD: Bool
    }

    enum TranscriptForm: Hashable {
        /// Each message restates the segment so far — what `TranscriptMerge` is written
        /// against.
        case cumulative
        /// Each message carries only newly decoded text; the provider accumulates it
        /// before anything leaves it.
        case incremental
    }

    enum LanguageSupport: Hashable {
        /// Must be handed a locale and cannot detect one: Apple's recogniser. History
        /// records the locale it was given even when that locale was a guess.
        case localeRequired
        /// Takes one language or none, detecting it when none is sent.
        case single
        /// Takes a set of candidate languages and detects within it — only
        /// `gpt-live-transcribe` (checked 2026-09-21).
        case set
    }

    public enum BatchUpload: Hashable, Sendable {
        /// The model is its own upload model.
        case itself
        /// A realtime model: the same vendor's upload model with this ID, since the
        /// realtime ID exists only behind the WebSocket.
        case model(String)
        /// No upload of its own: whatever model the user picked for that vendor. Apple's
        /// recogniser has no batch API, so its uploads go to the stored Groq model.
        case selectedModel(of: Provider)
    }

    public enum Requirement: Hashable, Sendable {
        case none
        /// An API key stored under this `SettingsKeys` name.
        case apiKey(String)
        /// The model's files on disk (`isLocalModelInstalled`).
        case installedModel
    }

    /// Whether a model is handed the user's vocabulary (`CustomVocabulary`). Only a
    /// *list* parameter counts: a free-text prompt (Groq's `prompt`, WhisperKit's prompt
    /// tokens) is reported to be echoed back on silence, and waits for the audio corpus.
    public enum Vocabulary: Hashable, Sendable {
        case none
        case termList(TermListLimits)

        public var limits: TermListLimits? {
            if case .termList(let limits) = self { limits } else { nil }
        }
    }

    public var isRealtime: Bool {
        if case .realtime = delivery { true } else { false }
    }
}

extension TermListLimits {
    private static let scribeForbidden: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]

    /// Scribe v2's `keyterms` form field. The API takes 1000 terms of under 50
    /// characters and at most five words — but bills a request carrying more than 100
    /// as at least 20 seconds, which a five-second dictation would pay four times over.
    /// So 100 is ours, not the vendor's (checked 2026-09-30).
    static let scribeUpload = TermListLimits(maxTerms: 100, maxCharacters: 49, maxWords: 5,
                                             forbidden: scribeForbidden)
    /// Scribe v2 Realtime's `keyterms` query parameter: 50 terms of 20 characters.
    static let scribeRealtime = TermListLimits(maxTerms: 50, maxCharacters: 20, maxWords: 5,
                                               forbidden: scribeForbidden)
    /// OpenAI's `keywords` (gpt-transcribe, gpt-live-transcribe). The vendor states no
    /// count or length, only that `<`, `>` and line breaks fail the request; 100 terms is
    /// our unmeasured choice, as is keeping each to the page's own entry limit.
    static let openAIKeywords = TermListLimits(maxTerms: 100, maxCharacters: CustomVocabulary.maxEntryCharacters,
                                               maxWords: nil, forbidden: ["<", ">"])
    /// `SFSpeechRecognitionRequest.contextualStrings`, which Apple asks to keep to 100
    /// phrases.
    static let appleContextualStrings = TermListLimits(maxTerms: 100, maxCharacters: CustomVocabulary.maxEntryCharacters,
                                                       maxWords: nil, forbidden: [])
}

// MARK: - List prices

/// A model's list price: free (it runs on the Mac), the vendor's rates, or explicitly
/// not priced — a vendor that publishes none, which Usage names instead of guessing.
public enum ListPrice<Rates: Hashable & Sendable>: Hashable, Sendable {
    case free
    case listed(Rates)
    case notPriced
}

/// What a vendor charges for speech, a minute of audio at a time.
public struct SpeechRates: Hashable, Sendable {
    public let perMinute: Double
    /// Added for a request that carried the user's words (`UsageEvent.keyterms`) — Scribe's
    /// keyterm prompting. Zero where sending them costs nothing extra.
    public var keytermSurchargePerMinute: Double = 0

    init(perMinute: Double, keytermSurchargePerMinute: Double = 0) {
        self.perMinute = perMinute
        self.keytermSurchargePerMinute = keytermSurchargePerMinute
    }

    /// Groq and ElevenLabs list their speech prices by the hour.
    init(perHour: Double, keytermSurchargePerHour: Double = 0) {
        self.init(perMinute: perHour / 60, keytermSurchargePerMinute: keytermSurchargePerHour / 60)
    }
}

/// Apple's recogniser in the catalogue. Never stored — `sttProvider == "apple"` selects
/// it — so it only has to be unique among Apple's entries, of which it is the one.
public let appleSpeechModelID = "apple-speech"

/// Every speech model the app offers, grouped by vendor, each vendor's in picker order.
/// The Settings pickers read it (`offeredSTTModels(of:)`), so a model and its capabilities are
/// written down once.
///
/// Prices are the vendors' pay-as-you-go list prices as of `UsagePrices.checked`
/// (docs/prices.md says how to refresh them): Groq's models page (by the hour, at least
/// 10 s a request — the ledger already bills that minimum), ElevenLabs' API pricing page
/// (by the hour; keyterm prompting is a separate line per model, $0.05/h on Scribe v2 and
/// $0.08/h on Realtime — the page's figures, not the API reference's "+20 %"), and
/// OpenAI's pricing page (its per-minute estimate, the only figure it gives for all three).
public let sttModelCatalog: [STTModelDescriptor] = {
    let groqKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.groqAPIKey)
    let elevenLabsKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.elevenLabsAPIKey)
    let openAIKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.openAIAPIKey)

    let cloud: [STTModelDescriptor] = [
        STTModelDescriptor(
            id: appleSpeechModelID, vendor: .apple, displayName: "Apple on-device",
            delivery: .systemRecognizer, language: .localeRequired,
            batchUpload: .selectedModel(of: .groq), requirement: .none,
            price: .free, languages: .decidedBySystem, languageNotes: [:],
            vocabulary: .termList(.appleContextualStrings)
        ),

        STTModelDescriptor(
            id: "whisper-large-v3-turbo", vendor: .groq, displayName: "Whisper Large V3 Turbo",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: groqKey,
            price: .listed(SpeechRates(perHour: 0.04)),
            // Groq serves OpenAI's weights, so Whisper's own list.
            languages: whisperV3Languages, languageNotes: [:]
        ),
        STTModelDescriptor(
            id: "whisper-large-v3", vendor: .groq, displayName: "Whisper Large V3",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: groqKey,
            price: .listed(SpeechRates(perHour: 0.111)),
            languages: whisperV3Languages, languageNotes: [:]
        ),

        // The batch (upload) model IDs are exactly what the API's `unsupported_model`
        // error lists, minus the two that are gone: scribe_v1 is deprecated in favour of
        // scribe_v2 and scribe_v1_experimental no longer appears in the documentation
        // (checked 2026-09-16). Both were deleted from this list before models had a
        // lifecycle, so a stored value for either is cleared at launch; the API still
        // answered both on 2026-10-16.
        STTModelDescriptor(
            id: "scribe_v2", vendor: .elevenLabs, displayName: "Scribe v2",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: elevenLabsKey,
            price: .listed(SpeechRates(perHour: 0.22, keytermSurchargePerHour: 0.05)),
            languages: scribeLanguages, languageNotes: [:],
            vocabulary: .termList(.scribeUpload)
        ),
        // Scribe's `language_code` is one value, so the realtime query string carries it
        // only when the user named exactly one language.
        STTModelDescriptor(
            id: elevenLabsRealtimeModel, vendor: .elevenLabs, displayName: "Scribe v2 Realtime — live text",
            delivery: .realtime(.init(sampleRate: 16_000, transcripts: .cumulative, serverVAD: true)),
            language: .single, batchUpload: .model("scribe_v2"), requirement: elevenLabsKey,
            price: .listed(SpeechRates(perHour: 0.39, keytermSurchargePerHour: 0.08)),
            // UNVERIFIED: ElevenLabs gives the realtime model "90+ languages" and no list of
            // its own (checked 2026-10-17), so Scribe v2's list stands in for it.
            languages: scribeLanguages, languageNotes: [:],
            vocabulary: .termList(.scribeRealtime),
            settingsNote: "Words appear on the overlay as you speak and are pasted when you stop. If the stream drops, Scribe v2 transcribes the recording instead. Billed per streamed minute."
        ),

        // Checked against `GET /v1/models` on 2026-09-21 rather than against the docs.
        //
        // Two of the models the account can see are deliberately left out.
        // `gpt-4o-transcribe-diarize` answers in `diarized_json`, a different shape from
        // the `{text}` this app decodes, and dictation has one speaker. `whisper-1` is
        // the one that matters: handed two seconds of near-silence it answered
        // "MBC 뉴스 이덕영입니다." — the classic Whisper silence hallucination, which would
        // be pasted into the user's document. `gpt-transcribe` answered `{"text":""}` to
        // the same audio, which is why it is the default. `AudioBufferWriter`'s silence
        // floor catches most of this, but a model that invents sentences from room noise
        // should not be offered at all.
        STTModelDescriptor(
            id: "gpt-transcribe", vendor: .openAI, displayName: "GPT Transcribe",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: openAIKey,
            price: .listed(SpeechRates(perMinute: 0.0045)),
            // OpenAI publishes no language list for its gpt transcription models.
            languages: .unpublished, languageNotes: [:],
            vocabulary: .termList(.openAIKeywords)
        ),
        // No vocabulary: `keywords` is documented for gpt-transcribe, and this model
        // takes only a free-text prompt. Deprecated on 2026-08-26 with whisper-1 and the
        // other gpt-4o transcription models; OpenAI names gpt-transcribe as the
        // replacement (checked 2026-10-16).
        STTModelDescriptor(
            id: "gpt-4o-mini-transcribe", vendor: .openAI, displayName: "GPT-4o mini Transcribe",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: openAIKey,
            price: .listed(SpeechRates(perMinute: 0.003)),
            languages: .unpublished, languageNotes: [:],
            lifecycle: .deprecated(Deprecation(
                announced: ModelRetirement.day(2026, 8, 26), shutdown: ModelRetirement.day(2027, 2, 26),
                replacement: "gpt-transcribe",
                source: URL(string: "https://developers.openai.com/api/docs/deprecations")!))
        ),
        STTModelDescriptor(
            id: openAIRealtimeSTTModel, vendor: .openAI, displayName: "GPT Live Transcribe — live text",
            delivery: .realtime(.init(sampleRate: 24_000, transcripts: .incremental, serverVAD: false)),
            language: .set, batchUpload: .model("gpt-transcribe"), requirement: openAIKey,
            price: .listed(SpeechRates(perMinute: 0.017)),
            languages: .unpublished, languageNotes: [:],
            vocabulary: .termList(.openAIKeywords),
            settingsNote: "Words appear on the overlay as you speak and are pasted when you stop. If the stream drops, GPT Transcribe transcribes the recording instead. Billed per streamed minute."
        ),
    ]

    // Derived, not retyped: `localSTTModels` stays the one list of local models, with
    // their sizes and memory floors. WhisperKit takes `language` or detects; Parakeet
    // takes a script hint or none.
    let local = localSTTModels.map { model in
        STTModelDescriptor(
            id: model.id, vendor: .local, displayName: model.displayName,
            delivery: .onDevice(model.engine), language: .single,
            batchUpload: .itself, requirement: .installedModel, price: .free,
            languages: model.languages, languageNotes: model.languageNotes,
            lifecycle: model.lifecycle
        )
    }
    return cloud + local
}()

/// A vendor's models a picker, setup or a recommendation may offer, in picker order. A
/// picker also shows the model selected now when it is not among them
/// (`pickerSTTModels(of:selected:)`), so it is never blank.
public func offeredSTTModels(of vendor: Provider) -> [STTModelDescriptor] {
    sttModelCatalog.filter { $0.vendor == vendor && $0.lifecycle.isOffered }
}

/// Every model of a vendor the catalogue still describes, offered or not — what prices,
/// names, History, Usage and normalisation look in. The archive (`archivedSpeechModels`)
/// is the rest of what is known.
public func knownSTTModels(of vendor: Provider) -> [STTModelDescriptor] {
    sttModelCatalog.filter { $0.vendor == vendor }
}

/// What a speech model picker lists: the offered models, and the selected one after them
/// when it is not offered — marked by its `ModelLifecycle.status(on:)` — so the picker
/// never renders blank.
public func pickerSTTModels(of vendor: Provider, selected: String) -> [STTModelDescriptor] {
    let offered = offeredSTTModels(of: vendor)
    // A cleared choice (`clearedModelChoice`) adds no row: nothing is selected until the user picks.
    if selected.isEmpty || offered.contains(where: { $0.id == selected }) { return offered }
    return offered + [sttModel(vendor: vendor, id: selected)]
}

/// The descriptor for a stored model ID. An ID the catalogue does not list — a
/// configuration built by hand, or a stored value normalisation has not reached yet —
/// is taken for its vendor's plain model: it uploads (or runs on the Mac) under its own
/// ID and needs what the vendor's models need. That is how every such ID behaved before
/// the catalogue existed: no stream, no mapping, the vendor's key.
public func sttModel(vendor: Provider, id: String) -> STTModelDescriptor {
    if let listed = sttModelCatalog.first(where: { $0.vendor == vendor && $0.id == id }) {
        return listed
    }
    let models = knownSTTModels(of: vendor)
    precondition(!models.isEmpty, "\(vendor) serves no speech")
    let template = models.first { !$0.isRealtime } ?? models[0]
    // An archived model keeps its name and price, so History still names and prices it.
    let archived = archivedSpeechModels.first { $0.vendor == vendor && $0.id == id }
    // No vocabulary, whatever the template takes: a parameter the model may not know
    // can fail the whole request. No price either, unless it runs on the Mac: an ID
    // nobody checked is named as unpriced, never charged at another model's rate.
    return STTModelDescriptor(
        id: id, vendor: vendor, displayName: archived?.displayName ?? id,
        delivery: template.delivery, language: template.language,
        batchUpload: template.batchUpload, requirement: template.requirement,
        price: archived?.price ?? (template.price == .free ? .free : .notPriced),
        // Like its price: an ID nobody checked never warns about a language.
        languages: .unpublished, languageNotes: [:],
        lifecycle: archived.map { .deprecated(.archived(replacement: $0.replacement)) } ?? .current
    )
}
