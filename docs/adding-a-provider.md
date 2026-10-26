# Adding a provider

How to add a speech engine, an AI Rewrite provider or a model, and how to change what
providers can do. The `add-provider` skill (`.claude/skills/add-provider/`) follows this
guide.

Two rules before any code:

- **Open an issue first.** A new vendor is a new place user audio or text goes. The
  maintainer agrees to the vendor before the PR.
- **Measure, don't recall.** Every vendor fact in the code carries the date it was checked
  against the live API. Vendor docs have been wrong before.

## 1. Pick the shape

| The vendor offers | What you write |
|---|---|
| OpenAI's `/audio/transcriptions` shape (Bearer key, `file` / `model` / `language`) | the descriptor's `speechUpload: OpenAICompatibleUpload(url:…)`, no code |
| Its own upload endpoint | a `BatchTranscriber` struct (~80 lines), like `ElevenLabsTranscriber` |
| A WebSocket with live text | a `StreamingTranscriber` (~500 lines) **plus** an upload model from the same vendor |
| OpenAI-compatible `/chat/completions` | a case returning `OpenAICompatibleChatClient(baseURL:dialect:)` |
| Its own chat API | a `ChatClient` struct, like `AnthropicChatClient` |
| A new model for a vendor already here | a catalogue entry (section 3) |
| A model that runs on the Mac | **stop**: that is a new dependency, the maintainer's decision |

Capabilities belong to the **model**, not the provider: Scribe v2 and Scribe v2 Realtime
are one provider, one key, two catalogue entries. All capability values:

| Field | Value | Meaning |
|---|---|---|
| `Delivery` | `.upload` | file sent after the segment ends |
| | `.realtime(RealtimeShape)` | WebSocket, text while speaking |
| | `.onDevice(LocalSTTEngine)` | model on the Mac |
| | `.systemRecognizer` | Apple's recogniser |
| `TranscriptForm` | `.cumulative` | each message restates the segment |
| | `.incremental` | each message has only new words |
| `LanguageSupport` | `.localeRequired` | needs a locale, cannot detect (Apple) |
| | `.single` | one language or none |
| | `.set` | a list of candidates (`gpt-live-transcribe`) |
| `LanguageCoverage` (speech: the descriptor's `languages`, with `languageNotes` beside it) | `.listed(PublishedLanguages)` | the vendor's list as BCP-47 codes (639-1 where one exists, else 639-3), its `source` page and the date it was `checked`; `vendorSaysAtLeast` for a vendor that says "90+" |
| | `.unpublished` | the vendor publishes no list (OpenAI); never warns |
| | `.decidedBySystem` | asked of macOS while the app runs (Apple) |
| `BatchUpload` | `.itself` | uploads under its own ID |
| | `.model(id)` | realtime model's upload twin, same vendor |
| | `.selectedModel(of:)` | borrows another vendor's pick (Apple → Groq) |
| `Requirement` | `.none` / `.apiKey(key)` / `.installedModel` | what must exist before it runs |
| `Vocabulary` | `.none` / `.termList(TermListLimits)` | takes the user's term list, and its limits |
| `ListPrice` (speech and chat: the descriptor's `price`) | `.free` | runs on the Mac (local models, Apple) |
| | `.listed(rates)` | the vendor's list price: `SpeechRates` (a minute, plus a keyterm surcharge) or `ChatRates` (input, cached input, output per token) |
| | `.notPriced` | the vendor publishes no price; Usage names the model rather than guessing |
| `ModelLifecycle` (speech and chat: the descriptor's `lifecycle`) | `.current` | offered, nothing better to suggest |
| | `.superseded(by: id)` | still works and offered; whoever has it is offered the switch to `id` (same vendor) |
| | `.deprecated(Deprecation)` | the vendor is switching it off: not offered, stored choices move to its `replacement` at launch |
| `VocabularyField` (OpenAI-compatible upload) | `.prompt` | the words as Whisper's free-text `prompt` (Groq) |
| | `.keywords` | a `keywords[]` field per term (OpenAI) |
| `Dialect` (chat) | `.classic` | `max_tokens` + `temperature` (Groq) |
| | `.reasoning` | `max_completion_tokens` + measured `reasoning_effort` (OpenAI) |
| `ReasoningOutput` (chat) | `.unchanged` | nothing sent |
| | `.excluded` | `include_reasoning: false` (Groq gpt-oss) |
| | `.hidden` | `reasoning_format: hidden` (Groq Qwen) |

A vendor that fits none of these is a change to this table (section 9), not a special
case in a `switch`.

## 2. Measure first

With a real key; write the date next to each answer. `scripts/provider-test-clips.sh`
makes the audio clips.

**Speech**
- Silence (`silence-2s.flac`): a model that invents text from silence is not offered.
- Shortest clip (`short-0.3s.wav`): text or empty, not an error.
- FLAC (`speech-en.flac`) accepted, whatever the docs say.
- Language: parameter name; single, list or none; what happens when it is omitted
  (detects, or assumes English?).
- Defaults that leak into text (audio tags, speaker labels): switch them off explicitly.
- Term list: is there a *list* parameter (not a free-text prompt), its count and length
  limits, forbidden characters, and any price change.
- Error body shape for a bad key, bad model, bad file.
- Quality on **real** speech. `say` output tells you nothing about quality.

**Realtime, also:** exact sample rate · cumulative or incremental text · server VAD or
client commit · which message means "ready" · minimum commit size · echoes of committed text.

**Chat:** which parameters each model rejects (HTTP 400 loses the rewrite) · how to turn
reasoning off, and the latency with and without · how a refusal arrives · how a reply the
output cap cut off says so · whether the `<<mode:NAME>>` marker comes back intact on real
dictations.

**Key:** its prefix (must not match another vendor's; `sk-` is shared, so if it collides,
no clipboard pick-up) · a free authenticated request for the key check (usually `GET /models`).

## 3. A new model for a vendor already here

- Speech: one `STTModelDescriptor` in `sttModelCatalog`, with a dated comment and its
  `price` from the vendor's page (docs/prices.md). Update `testPickersKeepTheirOrderAndNames`
  and add its row to `ListPriceTests`.
- Languages (required, for every speech model, on this Mac too): its `languages`, read from
  the vendor's page with the URL and the date (ModelLanguages.swift keeps the shared lists), or
  `.unpublished` when the vendor gives none; and a `languageNotes` entry for any language our
  corpus run found weak, with what measured it. The row's count, its "No …" badge and the
  *Languages I speak* warning follow from them. A row's line (ModelRowWords.swift) names no
  language — `ModelLanguageTests` fails if it does; a weakness is a note, shown only to
  someone who speaks the language.
- Chat: one `ChatModelDescriptor` in `chatModelCatalog`, with its measured switches
  (`reasoningEffort`, `reasoningOutput`, `refusalFallbacks`), its `price` and a dated
  comment, its whole body in `ChatRequestBodyTests` and its row in `ListPriceTests`. A model on this Mac is a `LocalChatModel`
  (a pinned GGUF file, its SHA-256 and its `ChatTemplateFamily`), loaded by the rewrite evaluation first;
  its descriptor is derived and free.
- Changing a default: the `defaultID` of the provider's `ModelSetting` in
  `ProviderDescriptor`, and `testTheDefaultModelsAreTheChosenOnes`; then mark the old
  default `.superseded(by: <new>)`. Nobody is moved: every launch pins the model an
  untouched install runs (`pinUntouchedModelChoices` for the engine and AI provider in
  use, `preserveInstalledLocalModel` for a local model on disk), so only new installs get
  the new default and everyone else is offered it. Pinning only protects installs that
  launched a release with it before the default moved. A realtime model's fallback
  (`batchUpload: .model(id)`) is its own decision.
- A better model, same vendor, the old one still working: mark the old one
  `.superseded(by:)`. It stays offered; nothing moves by itself. Its picker row says
  "Newer model available" with Switch to it, and whoever has it is told once at a
  dictation (`pendingModelNotice`) — for a local model, that the new version is
  recommended, never downloaded for them.
- Retiring a model (the vendor announced a shutdown): **never delete the entry.** Set
  `lifecycle: .deprecated(Deprecation(announced:shutdown:replacement:source:))` with the
  vendor's dates, its recommended replacement *of the same vendor* and its page. The model
  leaves the pickers and setup; the first launch of the release moves every stored choice
  to the replacement (`migrateStoredModels`, chains followed) and records the move in
  `modelMigrations`, which the first dictation after the update tells once, with the
  shutdown date and the list-price difference (`pendingModelNotice`); History keeps its
  name and price. A stored ID that leads to no offered model is cleared to
  `clearedModelChoice` (an empty string, never pinned over): a dictation is refused, and AI
  Rewrite pastes the text as dictated, until the user picks. A local model is never deprecated,
  only superseded — a launch must not point anyone at files they never downloaded.
  `ModelRetirement.termMonths` (6) after the shutdown date `testNoDeprecatedEntryHasOutlivedItsTerm`
  fails: move the entry to `archivedSpeechModels` / `archivedChatModels` (ID, vendor, name,
  price, replacement — one line, never deleted). `ModelLifecycleTests` checks that every
  chain ends on an offered model of the same vendor and every upload target is offered.
- Ollama's models are the user's and have no lifecycle.
- The vendor's name is already everywhere, so `check-provider-guide.sh` cannot help here.

## 4. Upload speech engine

1. Add the `Provider` case with its `ProviderDescriptor` (section 7) and the
   `STTProviderType` case, build, and fill every `switch` the compiler reports.
2. OpenAI-compatible: fill the descriptor's `speechUpload` (`OpenAICompatibleUpload`: the
   URL, any fixed fields such as Groq's `response_format=json`, and whether the
   vocabulary goes as a `prompt` or as `keywords[]`, and `minimumBilledSeconds` where the
   vendor documents a per-request minimum), add the engine to
   `makeBatchTranscriber`'s `OpenAICompatibleTranscriber` case, and pin its form in
   `UploadBodyTests`. Otherwise write the transcriber in `Transcribers.swift`, copying
   `ElevenLabsTranscriber`:
   - own `URLSession` with the `STTTuning` batch timeouts;
   - the form built by a pure `multipartBody`, pinned in `UploadBodyTests`;
   - `multipartAudioPart(for:)` for filename and MIME type (FLAC or WAV);
   - `language == nil` means "let the model detect": send nothing, or the vendor's
     detect switch if it otherwise assumes English. Never send a guess;
   - `validatedHTTPResponse` throwing `TranscriptionError` with the `Provider`, so the
     message names it (`providerErrorMessage`);
   - let `URLError` through unwrapped (offline detection reads it);
   - a term-list parameter: take `keyterms` in `init` from `configuration.batchVocabulary`
     (realtime: `liveVocabulary`), and set the entry's `vocabulary` limits;
   - metering: implement `transcribeMetered` (with `transcribe` calling it) returning
     the reply's billed seconds or tokens as `SpeechBilling` — extend `SpeechBilling.decode`
     for a new shape and pin it with a literal reply in `UsageLedgerTests` — and `meter`
     (`UsageMeter`: the vendor, the model, the terms sent). A transcriber without them
     leaves no entry in History's ledger and is counted as free;
   - log sizes, timings and counts, never text, terms or keys; Foundation only, no SDK;
   - `BatchTranscriber` is `Sendable`: the upload runs off main, in the session's
     `finish()`. A struct of `let`s is; a class is `@unchecked Sendable` with a line
     saying which lock guards each mutable field. A closure handed to URLSession is
     `@Sendable` (docs/development.md › Concurrency).
3. Catalogue entries, each with its `price` (docs/prices.md) and `languages` (section 3), a model key in `SettingsKeys`, and the descriptor's `speechModel`
   (`ModelSetting`: that key and the default). `portable`, normalisation and
   `RecordingConfiguration`'s `apiKeys` / `models` and the Settings picker follow
   from the descriptor. A realtime model's ID gets a constant in Settings.swift, beside
   `elevenLabsRealtimeModel`.
4. `makeBatchTranscriber` and `makeRecognitionSession`.

## 5. Realtime speech engine

Read CLAUDE.md's streaming sections first. The rules:

- **An upload twin is required**: `batchUpload: .model(id)` from the same vendor. A failed
  or dropped stream is finished by uploading the same audio.
- Follow the `StreamingTranscriber` protocol comments: `send` never blocks, `finish()` pads
  the tail with silence and waits a bounded time, `connect` once per instance.
- Events are **cumulative per segment**; accumulate deltas inside the transcriber.
  `.committed` means the segment ended at a pause.
- Hold audio until the session is ready (bounded buffer); if it fills, emit `.failed`,
  never drop audio.
- Keep the lock order: `sendLock` before `lock`, and never hold `lock` across `task.send`.
- Open the socket through the injected `RealtimeSocketOpener` and time every wait with the
  injected `RealtimeSleep` (both defaulted in `init`), never `URLSession` or `Task.sleep`
  directly, and add the transcriber as a `Vendor` case in
  `RealtimeTranscriberContractTests.swift`: the lock order, the pre-session buffer, the
  padded commit, the bounded `finish()` and `no_session` are held there against a fake socket.
- The protocol is `Sendable` (the audio thread, main and the stop all use one transcriber):
  declare the class `@unchecked Sendable` and keep every mutable field under `lock`.
- Report a server that never started a session as `TranscriptionError.realtime(provider,
  "no_session", …)`: that is the code `StreamReconnectPolicy.isReconnectable` reopens.
- `RealtimeShape.serverVAD` decides more than segmentation: a server-VAD model's stream is
  trusted only while no segment stays open past `STTTuning.streamLongestTrustedSegmentSeconds`
  (`RecordingConfiguration.longestTrustedStreamSegment`); past it the stop takes the upload.
  Measure the new model on the corpus's `uk-continuous-long` before relying on that limit.
- If the vendor uses one model name on both endpoints, coin a realtime ID
  (`<model>-realtime`) and map it back in the transcriber.
- Start from the closer existing transcriber: ElevenLabs (cumulative, server VAD) or OpenAI
  (incremental, client commit).

## 6. AI Rewrite provider

- OpenAI-compatible: a case in `LLMConfiguration.makeChatClient` with `baseURL` and a
  `Dialect`. Parameters that fit neither dialect → a new `Dialect` or a descriptor field,
  never a check on the model's name.
- Own API: a struct like `AnthropicChatClient`; build the request body in a pure
  function so it can be tested.
- Either way: `LLMProviderType` case, `chatModelCatalog` entries (fastest good model
  first, each with its `price` — docs/prices.md), a `SettingsKeys` model key and the
  descriptor's `chatModel` (`ModelSetting`); `portable` and normalisation follow.
- Return a `ChatReply`: the text and the reply's token counts as a `ChatUsage` — every
  input token in `inputTokens` (cache reads and writes added in where the API reports them
  apart, as Anthropic's does) and every output token, reasoning included, in
  `outputTokens`. Usage prices these; nil, for an API that reports none, falls back to an
  estimate from the words. Pin the decode with a literal reply in `ChatUsageTests`.
- Read how the reply ended before its text, in a `replyText()` on the decoded reply: a
  refusal throws `LLMError.refused`, and a reply the output cap or the context window
  ended throws `LLMError.cutOff` — it is only the start of a rewrite, and pasted it would
  end a dictation mid-sentence or replace a whole selection. Pin it with literal bodies in
  `ChatReplyEndingTests`.
- Throw on any failure; the app falls back to the raw transcript.

## 7. The key

- A `Provider` case and its `ProviderDescriptor` (ProviderRegistry.swift): the name, the
  roles it serves, and an `APIKeyDescriptor` — its `SettingsKeys.<vendor>APIKey` (**never**
  in `portable`), key page, create button and note, prefix, a sample key, and the
  verification request. `APIKeyStore.keys`, the key check, the clipboard pick-up and the
  AI step's reuse of a speech key all follow from it; `ProviderKeyTests` checks the
  prefix against every other provider's.
- The Settings › API Keys row follows from the descriptor (`APIKeyPage.order`, its `roles`
  as tags); nothing to add.
- A vendor with speech and chat has **one** key.

## 8. UI, tests, docs

- UI: Settings › Speech to text and AI Rewrite list every cloud engine and keyed pick
  with its models and its key (`SettingsEngines.swift`), and the API Keys page follows
  from the descriptors; give the service and its models their one-line descriptions
  there. Add the vendor to `SetupCards` if it gets a setup card — the maintainer's call;
  a card also lends Settings its title and plan ("Free plan", "Paid").
- Tests: a new transcriber or client file goes beside the others in
  `Packages/SpeechTextCore/Sources/SpeechTextCore/`, which needs no `project.pbxproj`
  edit; the test bundle compiles no app file, so anything a test needs goes there too. Test
  request builders and parsers as pure functions; realtime vendors get a
  `DictationReplay` script with a drop and a `Vendor` case in the realtime contract tests.
- Docs: README (engine table and **privacy list**), SECURITY.md, CLAUDE.md (component
  bullet, Settings Keys table), CHANGELOG. What only a person can check — a live socket
  from a microphone, a real key against the service — goes under *Needs a real-app run*
  in the pull request.

## 9. Keeping this guide true

A PR that changes the provider abstractions updates this guide:

- a new value or field in the capability table;
- a new place a provider must be registered (add a row below);
- a changed realtime rule, a new `Dialect`, a step towards one vendor type.

CI runs `scripts/check-provider-guide.sh`. It fails when a place named below no longer
exists, or when the code has a capability value the table in section 1 does not list. It
cannot notice a new place that nobody added below; that is for the reviewer.

## Touchpoints

Places the compiler does not point to. `scripts/check-provider-guide.sh KINDS VENDOR`
(e.g. `stt,key,docs deepgram`) shows which ones do not mention the new vendor yet.
Kinds: `stt`, `realtime`, `llm`, `key` (a new API key), `docs`. Check: `compiler` = a
`switch` the build reports; `manual` = the block at the anchor must name the vendor;
`manual:file` = the file must (coarse); `review` = check by hand.

```touchpoints
# kind   | file                                                                       | anchor (must exist in the file)        | check       | what to do
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/Transcribers.swift          | enum STTProviderType                   | compiler    | case, displayName
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/Transcribers.swift          | protocol BatchTranscriber              | manual:file | an own-API transcriber struct, if it is not OpenAI-compatible
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/Transcribers.swift          | func makeBatchTranscriber              | compiler    | a case returning the transcriber with configuration.batchModel
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/Transcribers.swift          | func providerErrorReason               | review      | a candidate for a new error JSON shape, and a ProviderErrorMessageTests case
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/ModelLifecycle.swift        | enum ModelUnavailableReply             | review      | the vendor's "no such model" reply, measured with a real key, and its literal body in ModelUnavailableReplyTests
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/STTModelCatalog.swift       | var vendor: Provider                   | compiler    | STTProviderType.vendor: the engine's provider
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/STTModelCatalog.swift       | let sttModelCatalog                    | manual      | one descriptor per model, with a dated comment on why it is offered
stt      | SpeechText/SpeechText/RecognitionSessionFactory.swift                      | func makeRecognitionSession            | compiler    | add the case to the cloud list
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/Settings.swift              | enum SettingsKeys                      | manual      | the model key, named in the descriptor's speechModel (never the API key)
stt      | Packages/SpeechTextCore/Sources/SpeechTextCore/ModelRowWords.swift         | func onlineSpeechServiceLine           | review      | Settings › Speech to text lists every cloud engine by itself; add its line here, and each model's in onlineSpeechModelLine (the descriptor's caption and a realtime model's settingsNote are shown under its models)
stt      | SpeechText/SpeechText/SettingsView.swift                                   | struct SpokenLanguagesField            | review      | the caption, only if the engine takes a language set
stt      | SpeechText/SpeechTextTests/CatalogueTests.swift                            | func testPickersKeepTheirOrderAndNames | manual      | the new picker's ids and names
stt      | SpeechText/SpeechText/HomeView.swift                                       | private var speechEngine               | compiler    | the engine's line on Home, with its stored model
stt      | SpeechText/SpeechTextTests/HomeSummaryTests.swift                          | final class ListPriceTests             | manual      | each model's list price, as on its descriptor (docs/prices.md)
realtime | Packages/SpeechTextCore/Sources/SpeechTextCore/StreamingTranscribers.swift | protocol StreamingTranscriber          | manual:file | the transcriber class
realtime | Packages/SpeechTextCore/Sources/SpeechTextCore/StreamingTranscribers.swift | func makeStreamingTranscriber          | compiler    | a case returning the realtime transcriber
realtime | Packages/SpeechTextCore/Sources/SpeechTextCore/NetworkFailure.swift        | static func isReconnectable            | review      | its "no session" failure must be TranscriptionError.realtime(_, "no_session", _)
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/ChatClients.swift           | enum LLMProviderType                   | compiler    | case, displayName, needsAPIKey
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/ChatClients.swift           | let chatModelCatalog                   | manual      | the vendor's models with their switches
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/ChatClients.swift           | static func makeChatClient             | compiler    | OpenAICompatibleChatClient(baseURL:dialect:) or a new struct
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/ModelLifecycle.swift        | enum ModelUnavailableReply             | review      | the vendor's "no such model" chat reply, measured, if its shape is new
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/Settings.swift              | enum SettingsKeys                      | manual      | the chat model key, named in the descriptor's chatModel
llm      | Packages/SpeechTextCore/Sources/SpeechTextCore/ModelRowWords.swift         | func onlineAIServiceLine               | review      | Settings › AI Rewrite lists every keyed pick by itself; add its line here, and each model's in chatModelLine
llm      | SpeechText/SpeechTextTests/ChatClientTests.swift                           | final class ChatRequestBodyTests       | manual      | each model's whole request body, written out
llm      | SpeechText/SpeechTextTests/HomeSummaryTests.swift                          | final class ListPriceTests             | manual      | each model's token prices, as on its descriptor (docs/prices.md)
key      | Packages/SpeechTextCore/Sources/SpeechTextCore/Settings.swift              | enum SettingsKeys                      | manual      | <vendor>APIKey
key      | Packages/SpeechTextCore/Sources/SpeechTextCore/ProviderRegistry.swift      | var descriptor: ProviderDescriptor     | compiler    | the Provider case and its ProviderDescriptor: name, roles, and the APIKeyDescriptor (key page, create note, prefix, sample, verification)
key      | Packages/SpeechTextCore/Sources/SpeechTextCore/SetupServices.swift         | enum SetupCards                        | review      | a setup card on the Speech and AI steps, if the maintainer wants one; SetupCardsTests checks what it saves
key      | docs/development.md                                                        | ## API keys                            | manual      | the list of keys
docs     | README.md                                                                  | ## Privacy: where your audio goes      | manual      | the privacy list (and the engine table or AI sentence above it)
docs     | SECURITY.md                                                                | The privacy practices of               | manual:file | add the vendor
docs     | CLAUDE.md                                                                  | ## Settings Keys Reference             | manual      | the new keys, and the provider file's Architecture bullet
docs     | CHANGELOG.md                                                               | ## [Unreleased]                        | manual:file | an Added entry
```
