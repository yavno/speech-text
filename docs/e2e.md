# End-to-end runs (`scripts/e2e.sh`)

The app itself, driven with no person. A debug build records from corpus clips
instead of the microphone, the script posts its global shortcuts as key events with real
timing, and AppleScript reads back the documents the text was pasted into. The corpus
harness (`scripts/evaluate.sh`, docs/audio-corpus.md) measures the engines; this one
checks everything around them: shortcuts, gestures, the stop's paste and where it goes,
cancels, AI Rewrite and the Edit shortcut.

It needs a logged-in session and two Accessibility grants, so it never runs in CI.

## Once

```sh
scripts/e2e.sh --setup
```

This builds the debug app and launches it once. Then:

1. Open System Settings › Privacy & Security › Accessibility and switch on **SpeechText**:
   the entry for `<derived data>/e2e/SpeechText.app`. The installed app has an entry of its
   own; leave it as it is. The build is signed with the Developer ID certificate, so the
   grant survives every rebuild. With no certificate it is signed ad hoc, and the grant has
   to be given again after each build.
2. Switch on Accessibility for the app the script runs in (Terminal, iTerm, T3 Code).
   That grant is what lets it post the shortcuts.
3. During the first run, allow both the script and the e2e build to control TextEdit and
   Script Editor when macOS asks. A prompt left open takes the front, and the paste goes
   with it: the scenario then fails with "pasted into UserNotificationCenter".

Quit the e2e build from its menu-bar icon when done.

System Settings may list the e2e build and the installed app as one "SpeechText" row,
since both carry that name: switching the row (or adding the e2e build with "+") can turn
the installed app's grant off. `/tmp` is cleared on restart, and the rebuilt e2e app needs
the grant again. The grants themselves can be read without opening anything:

```sh
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select client, auth_value from access where service = 'kTCCServiceAccessibility' and client like 'app.speech-text%'"
```

`2` is allowed and `0` is off. Both `app.speech-text.SpeechText` (yours) and
`app.speech-text.SpeechText.e2e` should read `2`.

## A run

```sh
scripts/e2e.sh                                   # every scenario, on Groq's upload
scripts/e2e.sh --engine scribe-realtime          # … or gpt-live, apple
scripts/e2e.sh --engine server                   # your own servers (below)
scripts/e2e.sh --no-build --only hold,edit       # skip the build; some scenarios
scripts/e2e.sh --traces --engine gpt-live        # also record dictation traces
```

A full run takes about five minutes per engine. Results go to `/tmp/speechtext-e2e/<time>/`
(`SPT_E2E_OUT` changes that):

- `summary.md`: one row per scenario.
- For each scenario, the Debug Log (`<scenario>.log`), the document as read back
  (`<scenario>.txt`) and History (`<scenario>.history.json`).
- `Traces/`, when `--traces` is set. Each one is named `<engine>-<scenario>-<date>.json`;
  `scripts/import-trace.sh NAME FILE` copies one into the private traces folder, where
  `scripts/replay-traces.sh` replays it. Traces never go into this repository.

The exit status is non-zero when a scenario failed.

| Variable | Default |
|---|---|
| `SPEECHTEXT_CORPUS` | none — required: the folder of corpus WAVs, outside the repository |
| `SPT_E2E_KEYS` | `~/.config/speech-text/test-keys.env` (`GROQ_API_KEY=…`, `OPENAI_API_KEY=…`, `ELEVENLABS_API_KEY=…`); the server engine runs without it |
| `SPT_E2E_DERIVED_DATA` | `/tmp/st-dd-e2e` |
| `SPT_SIGN_IDENTITY` | the first `Developer ID Application` certificate in the keychain |
| `SPT_E2E_SERVER_SPEECH` | `http://127.0.0.1:9932/v1`: the speech server for `--engine server` |
| `SPT_E2E_SERVER_SPEECH_MODEL` | `whisper`; whisper-server ignores it and lists none |
| `SPT_E2E_SERVER_CHAT` | `http://127.0.0.1:9931/v1`: the chat server, when `ai`, `switch-to-ai`, `switch-to-plain` or `edit` runs |
| `SPT_E2E_SERVER_CHAT_MODEL` | the first model the chat server lists |

## Your own server

`--engine server` points the build at a speech server and a chat server you start
yourself, as a user of *Your server* would: `sttProvider` and, when a scenario rewrites,
`llmProvider` are `server`, with the addresses and models above. The run stops before it
quits your app when a server does not answer, or answers 503 while it loads its model.

Checked on 2026-11-10 with whisper.cpp 1.9.5 and llama.cpp b11960 from Homebrew:

```sh
brew install whisper-cpp llama.cpp
mkdir -p ~/llm-eval-models
curl -L -o ~/llm-eval-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
whisper-server -m ~/llm-eval-models/ggml-large-v3-turbo-q5_0.bin --host 127.0.0.1 --port 9932 \
  --inference-path /v1/audio/transcriptions -l auto
llama-server -m ~/llm-eval-models/gemma-4-12b-it-qat-q4_0.gguf --alias gemma-4-12b \
  --host 127.0.0.1 --port 9931 -c 8192
```

- whisper-server answers at `/inference` unless told otherwise; `--inference-path` gives
  it OpenAI's path. It has no `/v1/models` (404), which the app's test request allows.
- It transcribes in English when a request names no language, and `edit` names none
  (its languages are Ukrainian and English): `-l auto` makes it detect instead. A request
  that names one, as `uk-UA`, is heard in that language.
- Any multilingual ggml model works; the corpus is Ukrainian, so never an `.en` one.
- Gemma 4 thinks before it answers, on llama-server's default `--reasoning auto`. The
  app's 8192 `max_tokens` leaves it room, but each rewrite and edit took 16–24 s on an
  M1 Pro, about 300 tokens of thought each; `ai` and `edit` wait 60 s for it.
- `--alias` gives the model a short ID; without it llama-server lists the file's path.
- Bound to anything but loopback, a `.local` address makes macOS ask the build for Local
  Network access; the prompt takes the front and the scenario fails with "pasted into
  UserNotificationCenter" until it is answered.

Stop both servers when the run is done.

## What it keeps apart from your own app

These decisions were made when the harness was designed.

- **Its own identity.** The build is stamped `app.speech-text.SpeechText.e2e` after it is
  built. That gives it its own preferences domain, which is reset before every scenario,
  and its own data folder, `Application Support/SpeechText-e2e`. Your settings, History and
  traces are never touched, and no rename migration copies anything into its domain.
  `onboardingCompleted` and `hasRegisteredLaunchAtLogin` are preset, so setup never opens
  and the build never makes itself a login item.
- **Keys in memory only.** `-SPTKeysFile` hands the key file to the build, which holds the
  keys for that session and writes them nowhere. A key in a preferences plist would be worse
  than plain text on disk: the installed keychain build treats a key in its own domain as
  newer, and would replace your real one with it.
- **One app on the shortcuts.** The installed SpeechText is quit for the run and reopened at
  the end, after Ctrl-C too.
- **No microphone.** `-SPTAudioInput a.wav,b.wav`: each capture start plays the next clip
  through `FileCapture` in real time, in the clip's own 48 kHz format, followed by silence.
  The microphone is never opened and never asked for.

- **A dropped stream without touching the network.** `-SPTCloseStreamAfter <seconds>`
  (the `stream-drop` scenario): once per launch, that long after the first stream's first
  partial, the socket is closed and the session is told the connection was lost
  (`URLError(.networkConnectionLost)`), so the reconnect and the upload fallback run as
  after a Wi-Fi drop. The socket really closes; the error is made up. The Mac's network,
  which other work on it may be using, is never switched off.
- **A failing Apple recogniser on cue.** `-SPTAppleFailAfter <seconds>` (the `apple-error`
  scenario): once per launch, that long after the first Apple chunk's first words, the
  chunk's recognition task is cancelled and the session is handed the error a real
  failure gives (kAFAssistantErrorDomain 1101). The session then has to start a fresh
  chunk at once, not at its 50 s rotation. The task really stops; the error is made up.

None of this is compiled into a Release build.

## Scenarios

| Scenario | What it does | Passes when |
|---|---|---|
| `plain` | ⌃⇧Q, the clip, ⌃⇧Q, in TextEdit | pasted once |
| `hold` | Hold to talk: ⌃⇧Q held for the clip | pasted once |
| `double-tap` | Hold to talk: two taps lock it on, a press stops it | pasted once; `→ lock` logged |
| `tap-cancels` | Hold to talk: one lone tap | nothing pasted; the tap cancel logged |
| `ai` | ⌃⇧A, the clip, ⌃⇧A | pasted once; History has the AI Rewrite |
| `switch-to-ai` | ⌃⇧Q, then ⌃⇧A halfway through, stopped by ⌃⇧A | pasted once; History has the AI Rewrite |
| `switch-to-plain` | ⌃⇧A, then ⌃⇧Q halfway through, stopped by ⌃⇧Q | pasted once; History has no AI Rewrite |
| `esc-cancel` | Esc cancels on; ⎋ while recording | nothing pasted; the ⎋ cancel logged |
| `two-in-a-row` | two dictations into one document (two clips) | two pastes, each ending in a space |
| `switch-app` | started in TextEdit, stopped in Script Editor | pasted once, into Script Editor; TextEdit empty |
| `stream-drop` | a realtime engine only (skipped on the others): ⌃⇧Q, the 19 s `uk-plain`, the socket closed 4 s after the first partial (`-SPTCloseStreamAfter 4`), ⌃⇧Q | pasted once; the Debug Log has the close, the reconnect and the upload fallback |
| `apple-error` | the Apple engine only (skipped on the others): ⌃⇧Q, the 19 s `uk-plain`, the recognition task failed 4 s after the first words (`-SPTAppleFailAfter 4`), ⌃⇧Q | pasted once; the Debug Log has the failure, the rotation after it and the fresh chunk hearing words. The WER shows whether the speech after the failure was pasted too |
| `edit` | text selected, ⌃⇧E, “Translate this into English.” (made with `say`), ⌃⇧E | the selection replaced; History has the edit |
| `smoke-plain-text` | `plain` into a plain-text TextEdit document | pasted once |
| `smoke-script-editor` | `plain` into Script Editor | pasted once |

Every dictation scenario also fails when a paste came before its stop, and every
scenario fails when the paste went to an app other than the document's, which
means something else took the front, or when the build had no Accessibility.

Verdicts are structural. The owner rejected a WER threshold for the corpus, so WER against the
clip's `expected` is shown in the summary as information only.

## What it cannot see

- The overlay: whether it draws, grows or tints. The Debug Log shows that it was asked to.
- Pasting into apps AppleScript cannot read back: Chromium, Electron and terminals.
- Anything about a real microphone: devices, Bluetooth, level.
- Permission prompts and setup.
