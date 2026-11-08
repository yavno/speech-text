# Settings keys

The `UserDefaults` keys the app reads: what each holds and its default. A setting that is
added, renamed, retired or given a new default changes its row here in the same pull
request (the `add-setting` skill walks it); CI's *Settings keys* step fails when a key and
the rows disagree. A key in `SettingsKeys.portable` is carried
across a bundle-identifier rename.

| Key | Purpose | Default |
|-----|---------|---------|
| `sttProvider` | STT backend (`"apple"`, `"groq"`, `"elevenlabs"`, `"openai"`, `"local"` — `local` covers both on-disk engines, chosen by `localSTTModel`) | `"apple"` |
| `groqAPIKey` | Groq API key — like every `…APIKey`, held by `APIKeyStore`: the keychain in a build with the profile, UserDefaults otherwise; never in `portable` | empty |
| `groqModel` | Groq Whisper model ID | `"whisper-large-v3-turbo"` |
| `localSTTModel` | Model ID for the local engine — a WhisperKit variant or a Parakeet build (`parakeet-tdt-0.6b-v3`, `parakeet-ultra`, `parakeet-redux`, `phonon-2`, `bark-3.0`, `bark-3.0-clean`), the catalogue entry's `engine` deciding which runtime gets it (an ID the catalogue does not know is cleared at launch) | `"parakeet-tdt-0.6b-v3"` |
| `elevenLabsAPIKey` / `elevenLabsModel` | ElevenLabs key and Scribe model (`scribe_v2`; `"scribe_v2_realtime"` streams) | empty / `"scribe_v2"` |
| `openAISTTModel` | OpenAI transcription model (`"gpt-live-transcribe"` streams). Separate from `openAIModel`, the chat model; the two tiers share only `openAIAPIKey` | `"gpt-transcribe"` |
| `removeDisfluencies` | Clean hesitation sounds, stretched letters and trailing `...` out of transcripts | `true` |
| `dashStyle` | How em dashes in transcripts and AI output are drawn (`"enDash"` `–`, `"hyphen"` `-`, `"emDash"` unchanged) | `"enDash"` |
| `customVocabulary` | The Settings › Speech › Vocabulary list an earlier release shipped (JSON `[VocabularyTerm]`). Read once at launch by `CustomVocabulary.migrateLegacyStoreIfNeeded`, moved into `vocabulary` and deleted | absent |
| `textReplacements` | The Dictionary page's Replacements table: JSON-encoded `[TextReplacementPair]`. In `portable`; written only by that page | absent |
| `sendVocabularyToEngine` | Send the Dictionary's words to the speech engine — every model that takes a word list, and Groq's prompt; the switch on the Dictionary page | `true` |
| `spokenLanguages` | The languages the user says they speak, ISO-639-1 joined by commas (`"uk,en"`). Empty means none stated. Exactly one is *forced* on every engine; two or more leave detection to the model and only narrow Apple's keyboard-layout guess | `""` (migrated from `selectedLanguage`) |
| `selectedLanguage` | Pre-list single choice. Read once by `migrateSelectedLanguageIfNeeded()`, then never again; stays in `portable` so the migration keeps its source across a rename | `"auto"` |
| `hotkeyKeyCode` / `hotkeyModifierFlags` | Inline recording hotkey | `12` (Q) / Control+Shift |
| `recordWindowHotkeyKeyCode` / `recordWindowHotkeyModifierFlags` | Record window hotkey | `13` (W) / Control+Shift |
| `aiHotkeyKeyCode` / `aiHotkeyModifierFlags` | AI recording hotkey | `0` (A) / Control+Shift |
| `holdToTalk` | Holding a dictation shortcut records until it is let go (a lone tap cancels, a double tap locks it on hands-free); for the Edit shortcut, a hold is the instruction and a double tap sends none. Setup stores `true` when the key is absent, so a new install starts on hold | `false` |
| `escapeCancelsDictation` | ⎋ cancels a dictation or an edit while the overlay is up; global for that time, so ⎋ reaches no other app | `false` |
| `editHotkeyKeyCode` / `editHotkeyModifierFlags` | Edit-selection-with-AI hotkey | `14` (E) / Control+Shift |
| `hotkeyLayoutVersion` | Shortcut-layout migration marker | `0` (unmigrated) |
| `llmProvider` | LLM backend (`"groq"`, `"anthropic"`, `"openai"`, `"local"`); a stored `"ollama"` moves to `"local"` at launch | `"groq"` |
| `groqLLMModel` | Groq chat model ID | `"openai/gpt-oss-120b"` |
| `serverChatAddress` | AI Rewrite through the user's own server: its base address, stored once a test has passed (`ServerEndpoint`). In `portable` | absent |
| `serverChatModel` | The model that server listed and the user picked. In `portable`; never normalized, since the server's list is the user's | absent |
| `serverChatAPIKey` | That server's key, only if it asks for one. Held by `APIKeyStore` in the keychain; never in `portable` | absent |
| `serverSpeechAddress` | Dictation through the user's own server, often another program than AI Rewrite's: its base address, stored once a test has passed. In `portable` | absent |
| `serverSpeechModel` | The model that server listed or the user typed. In `portable`; never normalized | absent |
| `serverSpeechAPIKey` | That server's key, only if it asks for one. Held by `APIKeyStore` in the keychain; never in `portable` | absent |
| `anthropicAPIKey` / `anthropicModel` | Anthropic key and model | empty / `"claude-sonnet-5-5"` |
| `openAIAPIKey` / `openAIModel` | OpenAI key and chat model. The key is shared with the speech engine, as Groq's is | empty / `"gpt-6-luna"` |
| `localLLMModel` | The chat model AI Rewrite runs on this Mac — a `LocalChatModel` id, normalised against `localChatModels` | `"gemma-4-12b-it-qat-q4_0"` |
| `promptPresets` | JSON-encoded `[PromptPreset]` | built-in defaults |
| `defaultPresetID` | UUID of the fallback preset | Clean-up |
| `promptPresetsVersion` | One-shot marker: the built-in prompts' version `promptPresets` was last moved to (`PromptPresetStore.migrateIfNeeded`; 1 = the three modes of 2026-11). Not in `portable`: the move is idempotent | `0` (unmigrated) |
| `aiModeInRecordWindow` | Record Window ✨ toggle state | `false` |
| `appSkin` | Appearance (`"techno"` or `"minimal"`) | `"techno"` |
| `dockIconMode` | When the app shows a Dock / ⌘Tab icon (`"never"`, `"whileWindowOpen"`, `"always"`) — an agent's Settings window is otherwise unfindable once covered | `"always"` |
| `accentColor` | Minimal skin's tint, `#RRGGBB`; empty means neutral | `""` |
| `glassTransparency` | The minimal skin's Transparency (`GlassTransparency`: `"most"`, `"more"`, `"standard"`, `"less"`, `"least"`); anything else reads as the default. In `portable` | `"standard"` |
| `technoPhosphor` | Techno skin's display colour: a recommended set (`"green"`, `"amber"`, `"cyan"`, `"white"`) or any colour as `#RRGGBB`; anything else reads as green | `"green"` |
| `holdTipFollowedCount` | Hold recordings in which the hold tip was followed (⌃⇧ let go, the letter still down), plus one once its switch hint was shown; `HoldTip.stage` reads it. Machine-local, not in `portable` | `0` |
| `homeIntroHidden` | The main window's Home has its intro card hidden, from Settings › Appearance. Machine-local, not in `portable` | `false` |
| `promptsIntroHidden` | The Prompts page has its card on how AI Rewrite picks a prompt hidden, from Settings › Appearance (it shows while AI Rewrite has no provider whatever this says). Machine-local, not in `portable` | `false` |
| `historyRetention` | How long History keeps dictations (`HistoryRetention`: `"none"` — this session only — `"7d"`, `"30d"`, `"3m"`, `"6m"`, `"1y"`, `"forever"`); anything else, the old `"300"` / `"1000"` included, reads as forever. Machine-local, not in `portable` | `"forever"` |
| `failedAudioRetention` | How long a failed dictation's audio is kept for a retry, on the same scale; never longer than its record. Machine-local | `"7d"` |
| `vocabulary` | The Dictionary: JSON-encoded `[VocabularyEntry]` (term, the spellings replaced by it). In `portable`; written only by the page and the one-time move of `customVocabulary` | absent |
| `typingWordsPerMinute` | The user's typing speed, which Usage's and Home's time saved weigh dictation against; below 10 or absent means 40 wpm, an average | absent |
| `microphone` | The microphone a dictation records from: empty for Automatic, `"system"` for System Default, otherwise a Core Audio device UID. Machine-local, not in `portable` | `""` |
| `microphoneName` | The picked device's name, so the picker can name it while it is not connected. Machine-local | absent |
| `modelMigrations` | Stored model choices the launch moved to a replacement or cleared (JSON `[ModelMigration]`, newest last, at most 20): a move is told once, at the next dictation; a cleared choice refuses each dictation with a notice until the user picks a model. Machine-local, not in `portable` | absent |
| `modelNoticesShown` | The IDs of lifecycle notices already shown (`ModelNotice.id`, such as `moved:<key>:<old model>`), so each is told once. Machine-local | absent |
| `microphoneNoticeShown` | The one-time notice that Automatic recorded with the Mac's microphone instead of Bluetooth headphones was shown. Machine-local | `false` |
| `overlayOrigin` | Where the user dragged the inline overlay: the strip's bottom-left corner as `"x,y"` in screen coordinates; empty means the bottom-right corner. Machine-local, not in `portable` | `""` |
| `recordDictationTraces` | Debug Log › Record traces: save each streamed inline dictation to `Traces/` (dictated text in plain text); machine-local, not in `portable` | `false` |
| `hasRegisteredLaunchAtLogin` | One-shot marker: on the launch it is not set, the app registers itself as a login item (default ON) and sets it, so a user who later switches it off is not re-registered. While setup is showing, its Permissions step does this instead | `false` |
| `onboardingCompleted` | Setup was finished, or the install predates it. Absent on a new install until its first launch decides: `false` while setup is unfinished; not in `portable` | absent |
| `onboardingStep` | `OnboardingStep.rawValue` an unfinished setup was left on | absent |
| `didAdoptPreRenameDefaults` | One-shot marker for `adoptPreRenameDefaults()`; stays out of `SettingsKeys.portable`, or the copy would mark itself done | `false` |
