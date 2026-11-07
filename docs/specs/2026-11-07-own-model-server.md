# SPEC: Your own model server

- **Status:** The owner answered the four questions on 2026-11-07 (*Decided by the owner*). Design (#189): `docs/design/own-model-server/`.
- **Date:** 2026-11-07
- **Issues:** #188 (this spec), part of #185 *Your own model server*; design #189, build #190, test #191, ship #192
- **Base revision:** `8288ec5`
- **Scope:**
  - **The provider:** `ProviderRegistry.swift` (a new `Provider` case), `ChatClients.swift` (`LLMProviderType`, `makeChatClient`, `chatModel(provider:id:)`), `Transcribers.swift` (`STTProviderType`, `makeBatchTranscriber`, `OpenAICompatibleUpload`), `STTModelCatalog.swift` (a descriptor for a model nobody listed).
  - **Settings:** new keys in `SettingsKeys` and `docs/settings-keys.md`; the key in `APIKeyStore`; a Settings row for each role; the setup cards.
  - **Where it shows:** Usage, Home's Engines, History's provider name, Privacy & Data › What leaves this Mac, `docs/privacy.md`.
  - **The app bundle:** `NSLocalNetworkUsageDescription` in `Info.plist` and `InfoPlist.xcstrings`.
- **Does not touch:** the built-in path ("On this Mac", llama.cpp, Parakeet, Whisper), the realtime tier, the rewrite prompt and its parser, `InlineDelivery`, `PasteService`.

## What it is

Someone who already runs a model — in Ollama, LM Studio, llama.cpp's server, vLLM, a transcription server — points SpeechText at it and uses it for AI Rewrite, for dictation, or both. Settings gets one more choice beside Groq, OpenAI and "On this Mac": an address, an optional key, and a model picked from the list the server gives.

The standard name for what it connects to is an *OpenAI-compatible server* (or *endpoint*): a server that answers OpenAI's request shapes at its own address. The feature is named for what the user does with it, and the UI says "OpenAI-compatible" in its caption, because that is the word the servers' own documentation uses.

## Why it is small

The clients exist, and the address is already data:

- `OpenAICompatibleChatClient` takes a `baseURL` and a `Dialect`. Groq and OpenAI differ only in those two and the key.
- `OpenAICompatibleTranscriber` reads its URL, its fixed fields and how the Dictionary goes out from an `OpenAICompatibleUpload`, held on the provider's descriptor.
- `chatModel(provider:id:)` already builds a descriptor for an ID the catalogue does not list: no switches sent, not priced. A server's model is exactly that case.
- `strippingReasoning` already takes inline `<think>` out of a reply, so a reasoning model behind a server reaches the parser clean.

What is new is that the address comes from the user, not from the descriptor. No new dependency.

## What the servers serve

Checked against each project's own documentation or source on 2026-11-07 (links in *Sources*). "—" means the project does not serve it; *unverified* means its own docs did not settle it.

| Server | Chat | `/v1/models` | Transcription (`/v1/audio/transcriptions`) | Key by default |
|---|---|---|---|---|
| Ollama | yes, `127.0.0.1:11434/v1` | installed models | yes, **WAV only**; `language`, `prompt` (only for models without speech instructions), `json` default | none (a key is "required but ignored") |
| LM Studio | yes, `:1234/v1` | models the server sees; all downloaded ones with JIT loading on | not documented | none |
| llama.cpp `llama-server` | yes, `127.0.0.1:9931/v1` (its README; Docker examples use 8080) | one entry, the loaded model | yes, for audio models, `json` only; `prompt` *replaces* the model's instruction | none; with `--api-key`, 401 on a wrong one |
| vLLM | yes, `:8000/v1` | *unverified* | yes (`vllm[audio]`), FLAC and WAV among others, 25 MB; `language`, `prompt` | none |
| LocalAI | yes, `:8080` | installed models | yes, anything ffmpeg reads; `language`, `prompt` | none until keys are set |
| Speaches | proxied to Ollama | downloaded models, `?task=` filter | yes, decoded by PyAV (FLAC fine); `language`, `prompt`, `hotwords` | none; with one set, 403 on a wrong one |
| whisper.cpp `whisper-server` | — | — | at `/inference`; `--inference-path /v1/audio/transcriptions` gives the OpenAI path. WAV, MP3, FLAC built in. **English when `language` is missing** | no option |
| Jan | yes, `127.0.0.1:1337/v1` | *unverified* | *unverified* | none |
| mlx-audio | — | loaded models | yes; **NDJSON unless `json` is asked for**; formats *unverified* | none |
| mlx-omni-server | yes, `:10240/v1` | models in the Hugging Face cache | yes; formats *unverified* | not documented |

Reasoning, where a server separates it, comes back in `reasoning` (Ollama, vLLM, LocalAI, LM Studio's gpt-oss) or `reasoning_content` (LM Studio, llama.cpp with `--reasoning-format deepseek`); otherwise `<think>` stays in the content. The reply's `content` is what the app reads, so a separate field is ignored and inline thinking is stripped. Every chat server listed accepts `max_tokens`; Ollama and llama.cpp ignore `max_completion_tokens`, so the `classic` dialect is the one that works everywhere. Several also serve a realtime WebSocket (llama.cpp, vLLM, Speaches, mlx-audio), each in its own variant of OpenAI's events; that is not part of this feature.

Three things follow from it:

1. **AI Rewrite works with nearly any of them**; dictation with a few. The Settings row for speech says so, and the test request (below) tells the user before a dictation does.
2. **Dictation through a server is an upload tier.** The servers that stream (llama.cpp, vLLM, Speaches, mlx-audio) each speak their own variant of OpenAI's realtime events, and the realtime tier is out of scope here, so there is no live text on the overlay. The audio file is written as for every engine; a failed request goes to History to retry, like any upload.
3. **Ollama takes only WAV**, and uploads are FLAC (`AudioBufferWriter`). So this provider sends WAV (P8). Everything above that transcribes reads WAV.
4. **`language` matters more than in the cloud.** whisper.cpp transcribes in English when none is sent. With two or more "Languages I speak", the app sends none (docs/decisions.md › A language is forced only when the user names exactly one), so the model detects — or, on whisper.cpp, does not. The Settings row says so for a user with more than one language; the app does not start guessing.
5. **`response_format: json` is always sent**: mlx-audio answers NDJSON without it, llama.cpp answers only JSON.

## Decisions proposed

- **P1 — One provider, both roles, an address for each.** `Provider.server`, `STTProviderType.server`, `LLMProviderType.server`, raw value `"server"` (stored in `sttProvider`, `llmProvider` and History's ledger, so it is a name we keep). Display name "Your server". Speech and AI Rewrite each have their own address, key and model (D1), because chat and transcription often run in different servers or on different ports; the speech address starts as a copy of the chat one, and the other way round, whichever is set first.
- **P2 — The address is the base, as the servers document it** (`http://localhost:11434/v1`). The app appends `/chat/completions`, `/audio/transcriptions` and `/models`. A trailing slash and a missing `/v1` are not guessed at: the test request says what went wrong.
- **P3 — The model comes from `GET /v1/models`**, refreshed when the Settings row opens and by the test button; a text field takes an ID when the server lists none. Nothing is pinned: there is no default (`ModelSetting.normalized = false`, as Ollama had), and an empty choice is the "must pick" notice that exists already.
- **P4 — The most cautious request.** Chat: the `classic` dialect (`max_tokens`, `temperature`), which every server in the table accepts — *to confirm in the test stage on each*; no `reasoning_effort`, no reasoning switch. Speech: `model`, `file`, `language` when one language is named, `response_format: json`, and the Dictionary as Whisper's free-text `prompt` (`VocabularyField.prompt`, `RecordingConfiguration.whisperPrompt`, as Groq has it; D3). Two servers treat `prompt` differently, and the test stage measures both: llama.cpp puts it *in place of* the model's own instruction, and Ollama uses it only for models without speech instructions. A server where the corpus shows it hurting (an instruction lost, the prompt echoed on silence) gets it left out, written down in the table with the measurement. The Dictionary also corrects the final text, as for every engine.
- **P5 — Each key is optional** and kept in the keychain like the others (`APIKeyStore`), one per role. With no key, no `Authorization` header is sent.
- **P6 — Usage shows it as "Your server", not priced** (`.notPriced`), never ≈ a list price. It may be free on this Mac or a paid GPU elsewhere; we cannot know.
- **P7 — A test request in Settings.** One chat request with a fixed short text, and one transcription of a bundled one-second WAV of silence. It reports, in words: cannot connect, the path answered 404 (the address probably lacks `/v1`), the key was refused (401 or 403), the model is not loaded, the audio was refused, or the time it took. It sends nothing of the user's.
- **P8 — WAV, 16 kHz mono, for this provider.** The FLAC that cloud uploads use was chosen to halve the bytes against a 25 MB ceiling; a server on this Mac or the local network has no such ceiling, and Ollama refuses FLAC. A FLAC archived in History is converted before a retry to this provider. One limit does apply: vLLM refuses audio over 25 MB by default (`VLLM_MAX_AUDIO_CLIP_FILESIZE_MB`), which 16 kHz mono WAV reaches at about 13 minutes; its error says so and names the setting.
- **P9 — Nothing else changes for a dictation.** It goes through `BatchRecognitionSession` like Groq, so the engine, History, retry and offline handling need no new branch beyond P8's format and one in how a failure is read: `NetworkFailure.isOffline` counts `cannotConnectToHost` (and a refused connection) as no network, which for a cloud vendor it is. For this provider it is the server not running, so such a failure is "Your server didn't answer" and goes to History for a retry by hand, while a real outage (`notConnectedToInternet`, a lost connection) stays offline and queued as now. `batchUnavailableReason` gains "Set your server's address in Settings."

## Privacy

This is the first provider whose destination the user writes. Text and audio go wherever the address points, which can be off this Mac, and over plain `http://`. So:

- `docs/privacy.md` and Privacy & Data › What leaves this Mac say: "Your server: audio and text go to the address you entered, and nowhere else."
- Settings shows, under the address, whether it is this Mac (loopback), your local network (a private range or `.local`) or the internet, read off the address. Plain `http://` to anything but this Mac gets a warning — anyone on the same network can read what is sent, the key included — and a key typed for such an address says so beside the field. It is not refused: a home server without TLS is the common case, and the choice is the user's.
- The log records the address's kind (loopback, network, internet), never the address itself: a host name can name a person's machine.

## Networking

- **App Transport Security.** Plain `http://localhost` worked in this app without an exception while it talked to Ollama (`Info.plist` has never had one). Plain `http://` to a full domain name is blocked; such a server needs `https://`, and the test request says so. Whether ATS lets plain `http://` through to an IP address (`127.0.0.1`, `192.168.…`) or a `.local` name on macOS 14 and later is *not verified*: Apple's pages disagree across versions. The build stage tries each from the signed app (the hardened runtime, as `scripts/rebuild.sh` signs it); if any is blocked, `NSAllowsLocalNetworking` is the narrow exception for exactly these, and nothing wider is added.
- **Local Network privacy.** A server elsewhere on the local network makes macOS ask once for Local Network access, and the prompt needs `NSLocalNetworkUsageDescription` (in `Info.plist` and, as its English source, `InfoPlist.xcstrings`; `scripts/check-infoplist-strings.sh`). Loopback does not ask. Wording proposed: "SpeechText connects to the model server you entered in Settings."
- **Timeouts.** A local server loads its model on the first request; Ollama's first request after its idle unload can take tens of seconds. The chat session's request timeout is 90 s and the upload's is `STTTuning.batchRequestTimeoutSeconds`; the test stage measures a cold first request on each server before deciding whether that is enough.

## Surfaces

- **Settings › AI Rewrite and › Speech:** "Your server" as a third place card beside *On this Mac* and *Online service* (owner, 2026-11-07; drawn in `docs/design/own-model-server/`); under it the address, the key, the model and the test button, each role its own (P1).
- **Setup:** a "Your server" card on the speech step and on the AI step (D4), beside the others: the address, the model once the server answers, and the test request; the key only when the server asks for one (401 or 403). The AI step's card offers the speech step's address, and the other way round.
- **Edit selection** goes through the same chat client and gets the server for free.
- **Usage and Home's Engines:** "Your server", the model ID as the server named it.
- **History:** the provider name; retry works as for any upload.
- **Vendor watch** cannot check a catalogue that is the user's, and skips the provider.
- **Docs:** `docs/adding-a-provider.md` (a provider whose address is a setting), `docs/settings-keys.md`, `docs/privacy.md`.

## The test stage (#191)

- Each server in the table that serves the role, run on this Mac: one AI dictation and one Edit selection through the app, one plain dictation where speech is served.
- A cold first request and a warm one, timed, beside the built-in path.
- A WAV upload to each speech server, and a retry from History of a dictation archived as FLAC.
- An upload over 25 MB to vLLM: the error names its limit.
- The Dictionary as `prompt` on each speech server, with and without, on the audio corpus (docs/audio-corpus.md), silence clips included: the word error rate, the Dictionary's terms spelled right, and whether the prompt comes back on silence (D3).
- A server on another machine on the local network: the Local Network prompt, then a dictation.
- A stopped server: the dictation goes to History as failed, "Your server didn't answer", and is retried by hand. It is not queued as offline: `OfflineRetry` waits for the Mac's network to come back, and a server restarting is not a network change.

## Decided by the owner (2026-11-07)

- **D1 — An address for each role.** Speech and AI Rewrite each have their own address, key and model (P1).
- **D2 — WAV for this provider** (P8).
- **D3 — The Dictionary goes to the server**, as `prompt`, unless the test stage measures it hurting on a server (P4).
- **D4 — Setup has a card** for it, on the speech step and the AI step (Surfaces).

## Sources

Checked on 2026-11-07, on each project's `main` or `master`:

- Ollama: [OpenAI compatibility](https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx), [`openai/openai.go`](https://github.com/ollama/ollama/blob/main/openai/openai.go), [FAQ](https://github.com/ollama/ollama/blob/main/docs/faq.mdx)
- LM Studio: [OpenAI compatibility](https://lmstudio.ai/docs/developer/openai-compat), [chat completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions), [models](https://lmstudio.ai/docs/developer/openai-compat/models), [authentication](https://lmstudio.ai/docs/developer/core/authentication), [0.4.7 changelog](https://lmstudio.ai/changelog/lmstudio-v0.4.7)
- llama.cpp: [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), `tools/server/server.cpp`, `server-chat.cpp`, `server-http.cpp`, `server-common.cpp`
- vLLM: [OpenAI-compatible server](https://github.com/vllm-project/vllm/blob/main/docs/serving/online_serving/openai_compatible_server.md), [speech to text](https://github.com/vllm-project/vllm/blob/main/docs/serving/online_serving/speech_to_text.md), [reasoning outputs](https://github.com/vllm-project/vllm/blob/main/docs/features/reasoning_outputs.md)
- LocalAI: [audio to text](https://localai.io/docs/features/audio-to-text/), [authentication](https://github.com/mudler/LocalAI/blob/master/docs/content/features/authentication.md), `core/schema/prediction.go`
- Speaches: [speech to text](https://speaches.ai/usage/speech-to-text/), [configuration](https://speaches.ai/configuration/), `src/speaches/routers/stt.py`, `dependencies.py`
- whisper.cpp: [server README](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/README.md), `examples/server/server.cpp`, `examples/common-whisper.cpp`
- Jan: [API server](https://docs.jan.ai/desktop/api-server)
- mlx-audio: [README](https://github.com/Blaizzy/mlx-audio/blob/main/README.md), `mlx_audio/server.py`
- mlx-omni-server: [README](https://github.com/madroidmaq/mlx-omni-server/blob/main/README.md), `src/mlx_omni_server/stt/`, `chat/openai/schema.py`
