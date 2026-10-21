// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SettingsKeys {
    /// Pre-list single language choice. Read once by `migrateSelectedLanguageIfNeeded()`
    /// and never again; kept in `portable` so the migration still has its source after a
    /// bundle-identifier change.
    static let selectedLanguage = "selectedLanguage"
    /// The languages the user says they speak, as ISO-639-1 codes joined by commas
    /// ("uk,en"). Empty means none stated, which is what leaves an engine to detect one.
    /// A list rather than a single value because a model is only *forced* onto one
    /// language when exactly one is named — see `resolveLocale`.
    public static let spokenLanguages = "spokenLanguages"

    // STT Provider
    public static let sttProvider = "sttProvider"
    static let groqAPIKey = "groqAPIKey"
    public static let groqModel = "groqModel"
    static let elevenLabsAPIKey = "elevenLabsAPIKey"
    public static let elevenLabsModel = "elevenLabsModel"
    /// The transcription model the OpenAI engine uses. Deliberately *not*
    /// `openAIModel`, which is the chat model for the rewrite pass — the two tiers
    /// pick independently and share only `openAIAPIKey`.
    public static let openAISTTModel = "openAISTTModel"
    /// `LocalSTTModel.id` (a WhisperKit variant or Parakeet) the local engine transcribes with.
    public static let localSTTModel = "localSTTModel"
    /// The chat model AI Rewrite runs on this Mac — a `LocalChatModel` id, normalised
    /// against `localChatModels`.
    public static let localLLMModel = "localLLMModel"
    /// Whether "е-е-е", "тооо" and trailing "..." are cleaned out of transcripts.
    public static let removeDisfluencies = "removeDisfluencies"
    /// `DashStyle.rawValue`: how em dashes in transcripts and AI output are drawn.
    public static let dashStyle = "dashStyle"
    /// The Settings › Speech › Vocabulary list an earlier release shipped (JSON `[VocabularyTerm]`).
    /// Read once by `CustomVocabulary.migrateLegacyStoreIfNeeded`, which moves it into
    /// `vocabulary` and deletes it.
    static let customVocabulary = "customVocabulary"
    /// Whether the Dictionary's words are sent to the speech engine — the switch on the
    /// Dictionary page. On when absent; the Dictionary starts empty, so that sends nothing.
    public static let sendVocabularyToEngine = "sendVocabularyToEngine"
    /// The Dictionary page's Replacements table: JSON-encoded `[TextReplacementPair]`.
    /// Written only by that page.
    static let textReplacements = "textReplacements"

    // Hotkey (inline recording)
    public static let hotkeyKeyCode = "hotkeyKeyCode"
    public static let hotkeyModifierFlags = "hotkeyModifierFlags"

    // Hotkey (record window)
    public static let recordWindowHotkeyKeyCode = "recordWindowHotkeyKeyCode"
    public static let recordWindowHotkeyModifierFlags = "recordWindowHotkeyModifierFlags"

    // Hotkey (AI recording — transcription is post-processed by an LLM)
    public static let aiHotkeyKeyCode = "aiHotkeyKeyCode"
    public static let aiHotkeyModifierFlags = "aiHotkeyModifierFlags"

    // Hotkey (edit the selection with AI)
    public static let editHotkeyKeyCode = "editHotkeyKeyCode"
    public static let editHotkeyModifierFlags = "editHotkeyModifierFlags"

    // LLM post-processing
    public static let llmProvider = "llmProvider"
    public static let groqLLMModel = "groqLLMModel"
    static let anthropicAPIKey = "anthropicAPIKey"
    public static let anthropicModel = "anthropicModel"
    static let openAIAPIKey = "openAIAPIKey"
    public static let openAIModel = "openAIModel"
    /// JSON-encoded `[PromptPreset]`.
    public static let promptPresets = "promptPresets"
    /// UUID string of the preset used when no other preset matches.
    public static let defaultPresetID = "defaultPresetID"
    /// Whether the Record Window's ✨ toggle is on.
    public static let aiModeInRecordWindow = "aiModeInRecordWindow"

    // Launch at Login
    public static let hasRegisteredLaunchAtLogin = "hasRegisteredLaunchAtLogin"

    /// Whether holding a dictation shortcut records until it is let go. A lone tap then
    /// cancels and a double tap locks the dictation on. Off by default.
    public static let holdToTalk = "holdToTalk"

    /// ⎋ cancels a dictation or an edit while its overlay is up. Off by default: the
    /// shortcut is global for that time, so ⎋ reaches no other app.
    public static let escapeCancelsDictation = "escapeCancelsDictation"

    /// Bumped when the built-in hotkey layout changes, so stored shortcuts can be
    /// migrated once instead of silently keeping the old assignment.
    public static let hotkeyLayoutVersion = "hotkeyLayoutVersion"

    // Appearance
    /// `AppSkin.rawValue`.
    public static let appSkin = "appSkin"
    /// `#RRGGBB` — only the minimal skin uses it.
    public static let accentColor = "accentColor"
    /// The techno display's colour: a `TechnoPhosphor.rawValue`, or any colour as `#RRGGBB`.
    public static let technoPhosphor = "technoPhosphor"
    /// `DockIconMode.rawValue`: never, while a window is open, or always.
    public static let dockIconMode = "dockIconMode"
    /// Where the user dragged the inline overlay: its bottom-left corner as `"x,y"` in
    /// screen coordinates (UserDefaults has no point type). Empty means the default
    /// corner. Monitor geometry, so machine-local and not in `portable`.
    public static let overlayOrigin = "overlayOrigin"
    /// Hold recordings in which the hold tip was followed (⌃⇧ let go, the letter still
    /// down), plus one once its switch hint has been shown — `HoldTip.stage` reads it.
    /// Machine-local, like the overlay's spot: a new Mac is a fresh start, so not in
    /// `portable`.
    public static let holdTipFollowedCount = "holdTipFollowedCount"
    /// The main window's Home has its intro card — the shortcut to learn — hidden, from
    /// Settings › Appearance. A lesson taken on this Mac, so not in `portable`.
    public static let homeIntroHidden = "homeIntroHidden"
    /// The Prompts page has its card on how AI Rewrite picks a prompt hidden, from
    /// Settings › Appearance. Machine-local, like Home's.
    public static let promptsIntroHidden = "promptsIntroHidden"
    /// How long History keeps dictations, `HistoryRetention.rawValue`; absent — or the
    /// "300" / "1000" of the count it once was — means forever, so an update deletes
    /// nothing. Machine-local like History itself, so not in `portable`.
    public static let historyRetention = "historyRetention"
    /// How long a failed dictation's audio is kept for a retry, `HistoryRetention.rawValue`;
    /// absent means 7 days, as it always was. Machine-local.
    public static let failedAudioRetention = "failedAudioRetention"
    /// The main window's Dictionary: JSON-encoded `[VocabularyEntry]`. In `portable`, like
    /// every setting the user builds up; written only by the page and by the one-time
    /// move of `customVocabulary`.
    static let vocabulary = "vocabulary"
    /// The user's typing speed in words a minute, which Usage and Home weigh dictation
    /// against; absent means the average, `HomeWeek.typingWordsPerMinute`.
    public static let typingWordsPerMinute = "typingWordsPerMinute"
    /// The microphone a dictation records from, `MicrophoneChoice.stored`: empty for
    /// Automatic, `"system"` for the system's input, otherwise a Core Audio device UID.
    /// A device of this Mac, so machine-local and not in `portable`.
    public static let microphone = "microphone"
    /// The picked device's name when it was picked, so the picker can name it while it
    /// is not connected. Machine-local, like `microphone`.
    public static let microphoneName = "microphoneName"
    /// The one-time notice that Automatic recorded from the Mac's microphone instead of
    /// Bluetooth headphones has been shown. Machine-local.
    public static let microphoneNoticeShown = "microphoneNoticeShown"
    /// Stored model choices the launch moved or cleared because their vendor is retiring
    /// the model: JSON-encoded `[ModelMigration]`, newest last, for the notice the next
    /// dictation shows. Describes this Mac's history, so machine-local.
    static let modelMigrations = "modelMigrations"
    /// The model IDs whose lifecycle notice has been shown, so each is shown once.
    /// Machine-local.
    public static let modelNoticesShown = "modelNoticesShown"

    // Debug
    /// Whether inline dictations are written to `Traces/` for `DictationReplay`. Machine-
    /// local, like the traces themselves, so not in `portable`.
    public static let recordDictationTraces = "recordDictationTraces"

    /// Marks that settings were carried over from the pre-rename preference domain.
    static let didAdoptPreRenameDefaults = "didAdoptPreRenameDefaults"

    // Setup
    /// Whether the setup window was finished (or the install predates it). Absent on a
    /// new install. Not in `portable`: it describes this identity's permission grants,
    /// which a rename asks for again.
    public static let onboardingCompleted = "onboardingCompleted"
    /// `OnboardingStep.rawValue` the setup window was left on, so it reopens there.
    public static let onboardingStep = "onboardingStep"

    /// Everything worth carrying across a rename.
    ///
    /// Deliberately not the whole domain: `hasRegisteredLaunchAtLogin` describes a
    /// registration made under the *old* bundle identifier, and copying it would leave
    /// the new app convinced it is a login item when it is not.
    ///
    /// Sparkle's own keys (`SUEnableAutomaticChecks`, `SULastCheckTime`,
    /// `SUSkippedVersion`) are missing for the same reason, and should stay missing: a
    /// new identity re-defaults to checking for updates, whereas a carried-over
    /// `SUSkippedVersion` would suppress an update the new install never saw offered.
    ///
    /// The API keys are missing too, but not left behind: `APIKeyStore.open` walks the
    /// same chain of domains for them, moves them into the keychain and deletes every
    /// plain-text copy — which a copy made here would only multiply.
    ///
    /// Each provider's model keys are added from its `ProviderDescriptor`, so a new
    /// provider's pick survives a rename without a line here.
    public static let portable: [String] = [
        selectedLanguage, spokenLanguages,
        sttProvider,
        removeDisfluencies, dashStyle,
        vocabulary, sendVocabularyToEngine, textReplacements,
        hotkeyKeyCode, hotkeyModifierFlags,
        recordWindowHotkeyKeyCode, recordWindowHotkeyModifierFlags,
        aiHotkeyKeyCode, aiHotkeyModifierFlags,
        editHotkeyKeyCode, editHotkeyModifierFlags,
        holdToTalk, escapeCancelsDictation,
        llmProvider,
        promptPresets, defaultPresetID, aiModeInRecordWindow,
        appSkin, accentColor, technoPhosphor, dockIconMode,
        hotkeyLayoutVersion,
    ] + Provider.allCases.flatMap { provider in
        [provider.descriptor.speechModel, provider.descriptor.chatModel].compactMap { $0?.settingsKey }
    }
}

/// Preference domains this app has run under before, newest first.
///
/// `com.voicepeter.app` is the original name; `com.speachtext.app` is the rename that
/// shipped the typo the product name no longer has; `com.speechtext.app` fixed the typo
/// but named a domain the project does not own, and gave way to `app.speech-text.SpeechText`
/// (the speech-text.app domain, reversed) before the first public release. Newest first
/// matters: a machine that saw several should take the *latest* value, and the loop below
/// never overwrites a key it has already adopted.
/// An end-to-end build (`E2EMode`) has none: its domain starts empty on purpose.
public var preRenameDefaultsDomains: [String] {
    E2EMode.isActive ? [] : ["com.speechtext.app", "com.speachtext.app", "com.voicepeter.app"]
}

/// Preferences are keyed by bundle identifier, so each rename leaves every setting —
/// shortcuts and prompt presets included — reading as empty, which looks exactly like a
/// factory reset. Copy them across once. The API keys are `APIKeyStore.open`'s to carry.
///
/// Runs before `normalizeStoredProviders()` so anything stale that comes over is
/// still checked against the current catalogues.
public func adoptPreRenameDefaults() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: SettingsKeys.didAdoptPreRenameDefaults) else { return }
    defaults.set(true, forKey: SettingsKeys.didAdoptPreRenameDefaults)

    for domain in preRenameDefaultsDomains {
        guard let legacy = UserDefaults(suiteName: domain) else { continue }
        var adopted = 0
        for key in SettingsKeys.portable {
            // Never clobber a value already set under the new name, or adopted from a
            // newer domain on an earlier pass.
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            adopted += 1
        }
        if adopted > 0 {
            dlog("Settings", "carried \(adopted) setting(s) over from the \(domain) preferences")
        }
    }
}

/// Scribe's streaming model. Picking it switches ElevenLabs from a file upload after
/// the recording to a WebSocket that returns text while the user is still speaking.
public let elevenLabsRealtimeModel = "scribe_v2_realtime"

/// OpenAI's streaming transcription model. Picking it switches the engine from a file
/// upload after the recording to the realtime WebSocket — see `OpenAIRealtimeTranscriber`.
/// It exists only there: the upload endpoint rejects it, so `batchModel` maps it to
/// `gpt-transcribe` for the stream's fallback and for History retries.
public let openAIRealtimeSTTModel = "gpt-live-transcribe"

/// One language the user can say they speak. `id` is the ISO-639-1 code the stored
/// list holds and the cloud providers are sent; `localeIdentifier` is the regional
/// locale Apple's recogniser needs, since it takes nothing else.
public struct SpokenLanguage: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let localeIdentifier: String
    /// What the language is written in — what `HallucinationFilter` lets through once the
    /// user has stated it (Latin is let through for every language).
    let scripts: [WritingScript]
}

/// Special value meaning "no language was requested" — what History records when the
/// model was left to detect one.
let autoLanguageID = "auto"

/// The languages offerable in Settings: supported by Whisper and Scribe, and each with
/// a locale `SFSpeechRecognizer` knows, so a selection means the same thing on every
/// engine. One entry per language rather than per region — the regional identifier only
/// exists because Apple demands one, and the cloud tiers are sent the ISO code alone.
public let spokenLanguageCatalog: [SpokenLanguage] = [
    SpokenLanguage(id: "en", displayName: "English", localeIdentifier: "en-US", scripts: [.latin]),
    SpokenLanguage(id: "uk", displayName: "Ukrainian", localeIdentifier: "uk-UA", scripts: [.cyrillic]),
    SpokenLanguage(id: "ar", displayName: "Arabic", localeIdentifier: "ar-SA", scripts: [.arabic]),
    SpokenLanguage(id: "zh", displayName: "Chinese", localeIdentifier: "zh-CN", scripts: [.han]),
    SpokenLanguage(id: "hr", displayName: "Croatian", localeIdentifier: "hr-HR", scripts: [.latin]),
    SpokenLanguage(id: "cs", displayName: "Czech", localeIdentifier: "cs-CZ", scripts: [.latin]),
    SpokenLanguage(id: "da", displayName: "Danish", localeIdentifier: "da-DK", scripts: [.latin]),
    SpokenLanguage(id: "nl", displayName: "Dutch", localeIdentifier: "nl-NL", scripts: [.latin]),
    SpokenLanguage(id: "fi", displayName: "Finnish", localeIdentifier: "fi-FI", scripts: [.latin]),
    SpokenLanguage(id: "fr", displayName: "French", localeIdentifier: "fr-FR", scripts: [.latin]),
    SpokenLanguage(id: "de", displayName: "German", localeIdentifier: "de-DE", scripts: [.latin]),
    SpokenLanguage(id: "el", displayName: "Greek", localeIdentifier: "el-GR", scripts: [.greek]),
    SpokenLanguage(id: "he", displayName: "Hebrew", localeIdentifier: "he-IL", scripts: [.hebrew]),
    SpokenLanguage(id: "hi", displayName: "Hindi", localeIdentifier: "hi-IN", scripts: [.devanagari]),
    SpokenLanguage(id: "hu", displayName: "Hungarian", localeIdentifier: "hu-HU", scripts: [.latin]),
    SpokenLanguage(id: "id", displayName: "Indonesian", localeIdentifier: "id-ID", scripts: [.latin]),
    SpokenLanguage(id: "it", displayName: "Italian", localeIdentifier: "it-IT", scripts: [.latin]),
    SpokenLanguage(id: "ja", displayName: "Japanese", localeIdentifier: "ja-JP",
                   scripts: [.han, .hiragana, .katakana]),
    SpokenLanguage(id: "ko", displayName: "Korean", localeIdentifier: "ko-KR", scripts: [.hangul, .han]),
    SpokenLanguage(id: "ms", displayName: "Malay", localeIdentifier: "ms-MY", scripts: [.latin]),
    SpokenLanguage(id: "no", displayName: "Norwegian", localeIdentifier: "nb-NO", scripts: [.latin]),
    SpokenLanguage(id: "pl", displayName: "Polish", localeIdentifier: "pl-PL", scripts: [.latin]),
    SpokenLanguage(id: "pt", displayName: "Portuguese", localeIdentifier: "pt-BR", scripts: [.latin]),
    SpokenLanguage(id: "ro", displayName: "Romanian", localeIdentifier: "ro-RO", scripts: [.latin]),
    SpokenLanguage(id: "ru", displayName: "Russian", localeIdentifier: "ru-RU", scripts: [.cyrillic]),
    SpokenLanguage(id: "sk", displayName: "Slovak", localeIdentifier: "sk-SK", scripts: [.latin]),
    SpokenLanguage(id: "es", displayName: "Spanish", localeIdentifier: "es-ES", scripts: [.latin]),
    SpokenLanguage(id: "sv", displayName: "Swedish", localeIdentifier: "sv-SE", scripts: [.latin]),
    SpokenLanguage(id: "th", displayName: "Thai", localeIdentifier: "th-TH", scripts: [.thai]),
    SpokenLanguage(id: "tr", displayName: "Turkish", localeIdentifier: "tr-TR", scripts: [.latin]),
    SpokenLanguage(id: "vi", displayName: "Vietnamese", localeIdentifier: "vi-VN", scripts: [.latin]),
]

public func spokenLanguage(id: String) -> SpokenLanguage? {
    spokenLanguageCatalog.first { $0.id == id }
}

// MARK: - The spoken-language list

/// Reads the stored `"uk,en"` form. Unknown codes are dropped and duplicates collapsed,
/// so a list hand-edited in defaults — or carried over from an older catalogue — cannot
/// put a code into a request that no engine would accept. Order is the user's.
public func parseSpokenLanguages(_ raw: String) -> [String] {
    var seen = Set<String>()
    return raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { spokenLanguage(id: $0) != nil && seen.insert($0).inserted }
}

public func encodeSpokenLanguages(_ codes: [String]) -> String {
    parseSpokenLanguages(codes.joined(separator: ",")).joined(separator: ",")
}

/// What the old single-value `selectedLanguage` becomes: "auto" (or anything unknown)
/// means nothing was stated, and a locale identifier keeps its language.
func spokenLanguagesMigrating(from selectedLanguage: String?) -> [String] {
    guard let selectedLanguage, selectedLanguage != autoLanguageID else { return [] }
    return parseSpokenLanguages(String(selectedLanguage.prefix(2)))
}

/// The locale to hand a recogniser, given the languages the user says they speak.
///
/// Three cases, and only the first one forces anything on an engine that can detect a
/// language itself (see `RecordingConfiguration.cloudLanguage`):
///
/// - **one language** — that language, on every tier. The user named it, so it is not a
///   guess, and forcing it is the accuracy win the setting exists for.
/// - **several** — the engine detects; this answer is only for Apple, which cannot. The
///   keyboard layout decides *among the stated languages*, so a Russian layout no longer
///   selects Russian for someone who never listed it; with no match, the first stated
///   language beats a layout the user did not claim to speak.
/// - **none stated** — the pre-existing behaviour: the layout's language, else the
///   system's.
func resolveLocale(spoken: [String], keyboardLanguage: String?, systemLocale: String) -> String {
    if spoken.count == 1, let only = spokenLanguage(id: spoken[0]) {
        return only.localeIdentifier
    }
    if spoken.count > 1 {
        if let keyboardLanguage, spoken.contains(keyboardLanguage),
           let match = spokenLanguage(id: keyboardLanguage) {
            return match.localeIdentifier
        }
        return spokenLanguage(id: spoken[0])?.localeIdentifier ?? systemLocale
    }
    return keyboardLanguage ?? systemLocale
}

/// Map of macOS keyboard layout names → ISO 639-1 language codes.
/// Layout names come from `com.apple.HIToolbox` AppleSelectedInputSources.
private let layoutToLanguage: [String: String] = [
    "US": "en", "USInternational-PC": "en", "ABC": "en",
    "British": "en", "Australian": "en", "Canadian": "en",
    "Ukrainian": "uk", "Ukrainian-PC": "uk",
    "Russian": "ru", "Russian-Phonetic": "ru", "RussianWin": "ru",
    "Spanish": "es", "Spanish - ISO": "es",
    "French": "fr", "French-PC": "fr", "Canadian-CSA": "fr",
    "German": "de", "German-DIN-2137": "de",
    "Italian": "it",
    "Portuguese": "pt", "Brazilian": "pt",
    "Dutch": "nl",
    "Polish": "pl", "PolishPro": "pl",
    "Czech": "cs", "Czech-QWERTY": "cs",
    "Japanese": "ja", "Turkish": "tr", "Korean": "ko",
    "Swedish": "sv", "Norwegian": "no", "Danish": "da", "Finnish": "fi",
    "Colemak": "en", "Dvorak": "en", "DVORAK-QWERTYCMD": "en",
]

/// Returns the language of the currently active keyboard input source.
/// Reads from `com.apple.HIToolbox` preferences (pure Foundation, no Carbon).
private func currentInputSourceLanguage() -> String? {
    guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else { return nil }
    defaults.synchronize()

    if let sourceID = defaults.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID") {
        let layoutName = sourceID.replacingOccurrences(of: "com.apple.keylayout.", with: "")
        if let lang = layoutToLanguage[layoutName] { return lang }
    }

    if let sources = defaults.object(forKey: "AppleSelectedInputSources") as? [[String: Any]] {
        for source in sources {
            if let name = source["KeyboardLayout Name"] as? String,
               let lang = layoutToLanguage[name] {
                return lang
            }
        }
    }

    return nil
}

/// Drops provider settings whose stored value no longer maps to a known case, moves
/// stored models their vendor is retiring to their replacements, and pins the model an
/// untouched install runs (`ModelLifecycle`).
///
/// A stale identifier is worse than a missing one: the picker in Settings finds no
/// matching tag and renders blank, while the engine quietly falls back to its
/// default — so the UI shows nothing and the app runs something the user did not pick.
public func normalizeStoredProviders() {
    normalizeStoredProviders(in: .standard)
}

/// `normalizeStoredProviders()` against any store, so the tests run it on an isolated
/// suite. The local model is looked for on disk only through `localModelOnDisk`.
func normalizeStoredProviders(in defaults: UserDefaults,
                              localModelOnDisk: (String) -> Bool = { isLocalModelInstalled($0) }) {

    // Settings for removed features: the webhook (whose bearer token should not outlive
    // it) and the switch that used to keep the focus context out of AI dictations.
    for key in ["webhookURL", "authToken", "aiFocusContextEnabled"] {
        defaults.removeObject(forKey: key)
    }
    migrateOllamaPick(defaults)

    if let raw = defaults.string(forKey: SettingsKeys.sttProvider),
       STTProviderType(rawValue: raw) == nil {
        dlog("Settings", "sttProvider=\"\(raw)\" is not a known engine — resetting to Apple", level: .notice)
        defaults.set(STTProviderType.apple.rawValue, forKey: SettingsKeys.sttProvider)
    }

    if let raw = defaults.string(forKey: SettingsKeys.llmProvider),
       LLMProviderType(rawValue: raw) == nil {
        dlog("Settings", "llmProvider=\"\(raw)\" is not a known provider — resetting to Groq", level: .notice)
        defaults.set(LLMProviderType.groq.rawValue, forKey: SettingsKeys.llmProvider)
    }

    // A vendor retires models; a stored one it is retiring is moved to the model's own
    // replacement — never to the default, which may be another kind of model — and the
    // move is recorded for the notice. One that leads nowhere is cleared for the user
    // to pick. Then whatever is still unset is pinned, so a later change of our default
    // reaches only new installs. The local model is written down first if it was never
    // set (see below).
    preserveInstalledLocalModel(in: defaults, onDisk: localModelOnDisk)
    migrateStoredModels(in: defaults)
    // A choice cleared just now holds `clearedModelChoice`, which pinning leaves alone:
    // the user is asked to pick.
    pinUntouchedModelChoices(in: defaults)
}

/// AI Rewrite through Ollama became AI Rewrite on this Mac (2026-10-16): the pick moves
/// to the built-in path, on the same model where the catalogue has it, and the Ollama
/// settings go. The model is a GGUF file of our own now, not Ollama's store, so it has to
/// be downloaded again — until it is, each AI dictation pastes the transcript and says
/// so (`LocalChatError.notInstalled`). A remote Ollama has no replacement.
func migrateOllamaPick(_ defaults: UserDefaults) {
    let tag = defaults.string(forKey: "ollamaModel") ?? ""
    if defaults.string(forKey: SettingsKeys.llmProvider) == "ollama" {
        let same: [String: String] = [
            "gemma4:12b": "gemma-4-12b-it-qat-q4_0", "qwen3.5:9b": "Qwen3.5-9B-Q4_K_M",
            "qwen3.5:4b": "Qwen3.5-4B-Q4_K_M", "qwen3.8:27b": "Qwen3.8-27B-Q4_K_M", "gpt-oss:20b": "gpt-oss-20b-MXFP4",
        ]
        let model = same[tag] ?? same[tag.replacingOccurrences(of: ":latest", with: "")]
            ?? recommendedLocalChatModel(for: .current())?.id ?? Provider.local.defaultChatModel
        dlog("Settings", "llmProvider=ollama (\(tag)) moved to the built-in path with \(model)")
        defaults.set(LLMProviderType.local.rawValue, forKey: SettingsKeys.llmProvider)
        defaults.set(model, forKey: SettingsKeys.localLLMModel)
    }
    for key in ["ollamaModel", "ollamaBaseURL"] { defaults.removeObject(forKey: key) }
}

/// Keeps a local-tier user on the model they actually downloaded when the *default*
/// moves under them.
///
/// Nothing writes `localSTTModel` until the user picks a model by hand: both
/// `@AppStorage` and `RecordingConfiguration.current()` fall back to
/// `Provider.local.defaultSpeechModel` on read, and normalisation leaves an absent key
/// alone. So when that default moved from Whisper Turbo to Parakeet, every install
/// running the local tier on the old default — key never written, Turbo on disk and
/// working — would have been pointed at a model it had not downloaded, and the next
/// dictation would have failed with "Parakeet v3 isn't installed". A working setup
/// broken by an update, silently, with no user action.
///
/// So an absent key plus a model on disk is read as "they meant this one", and it is
/// written down. A fresh install has nothing on disk and falls through to the new
/// default, which is the whole point of moving it. This is the local tier's half of
/// pinning (`pinUntouchedModelChoices`): it runs whichever engine is in use, because a
/// model on disk is a choice the user made by downloading it.
private func preserveInstalledLocalModel(in defaults: UserDefaults, onDisk: (String) -> Bool) {
    guard defaults.string(forKey: SettingsKeys.localSTTModel) == nil else { return }
    // The old default first, because that is what an untouched install was running; then
    // today's default; only then the heaviest installed, for someone who downloaded
    // something else by hand.
    let previousDefault = "openai_whisper-large-v3-v20240930_turbo_632MB"
    let keep = [previousDefault, Provider.local.defaultSpeechModel].first(where: onDisk)
        ?? localSTTModels.first { onDisk($0.id) }?.id
    guard let keep else { return }
    dlog("Settings", "localSTTModel was never set and \(keep) is installed — keeping it")
    defaults.set(keep, forKey: SettingsKeys.localSTTModel)
}

/// The languages the user says they speak, newest storage format.
public func storedSpokenLanguages() -> [String] {
    parseSpokenLanguages(UserDefaults.standard.string(forKey: SettingsKeys.spokenLanguages) ?? "")
}

func setStoredSpokenLanguages(_ codes: [String]) {
    UserDefaults.standard.set(encodeSpokenLanguages(codes), forKey: SettingsKeys.spokenLanguages)
}

/// Turns the pre-list `selectedLanguage` into `spokenLanguages`, once.
///
/// Guarded on the *absence* of the new key rather than on a marker of its own: an empty
/// list is a meaningful answer ("let the model detect"), so it has to be written and then
/// left alone, and a user who clears the list must not have their old single choice
/// restored on the next launch.
public func migrateSelectedLanguageIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: SettingsKeys.spokenLanguages) == nil else { return }
    let codes = spokenLanguagesMigrating(from: defaults.string(forKey: SettingsKeys.selectedLanguage))
    defaults.set(encodeSpokenLanguages(codes), forKey: SettingsKeys.spokenLanguages)
    dlog("Settings", "spoken languages initialised to [\(codes.joined(separator: ", "))]")
}

/// Resolves the effective locale identifier for speech recognition — see `resolveLocale`
/// for the three cases. The UserDefaults read lives here so the decision itself stays a
/// pure function the tests can drive without touching the user's real settings.
public func resolvedLocale() -> String {
    resolveLocale(
        spoken: storedSpokenLanguages(),
        keyboardLanguage: currentInputSourceLanguage(),
        systemLocale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    )
}

// MARK: - Keyboard Change Observer

/// Observes keyboard input source changes using .deliverImmediately so
/// notifications arrive even when the app is in the background. Main-actor: the
/// notification is delivered on the main thread, and every handler is a view's.
@MainActor
public final class KeyboardChangeObserver: NSObject {
    public static let shared = KeyboardChangeObserver()

    private var handlers: [(id: UUID, block: @MainActor () -> Void)] = []

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardDidChange),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func keyboardDidChange() {
        handlers.forEach { $0.block() }
    }

    public func addHandler(_ block: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        handlers.append((id: id, block: block))
        return id
    }

    public func removeHandler(id: UUID) {
        handlers.removeAll { $0.id == id }
    }
}
