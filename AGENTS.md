# SpeechText

A macOS menu bar app that turns speech into text where the cursor is. A global shortcut
starts a recording; Apple's on-device recogniser, a model on this Mac or a cloud service
turns it into text; an LLM can rewrite it (AI Rewrite); the result is pasted into the app
in front. Native Swift and SwiftUI, macOS 14 or later, GPL-3.0-or-later, built by one
maintainer with contributors.

This file is the rules and the map. The decisions behind the behaviour, each with the bug
or the measurement that made it, are in [docs/decisions.md](docs/decisions.md); read the
entry for what you are about to change. `CLAUDE.md` only imports this file, so every agent
reads the same text.

## What we never compromise on

Draft for the maintainer to edit.

- **The user's words stay theirs.** No server, no account, no telemetry, no analytics.
  Audio and text go only to the engine the user picked, with the user's own key
  (docs/privacy.md). Anything that sends user data somewhere new starts as an issue. The
  log records lengths and counts, never words, window titles or Dictionary terms
  (`scripts/check-log-privacy.sh`).
- **Nothing reaches another app before the stop.** Live text lives on the overlay. Text
  pasted into someone else's document cannot be taken back, so a dictation makes one
  write, at the stop, built from the whole recording.
- **A dictation is never lost.** The audio file is always written, whatever the engine; a
  stream that fails, drops or cannot be trusted is answered by the upload of that file; a
  dictation that fails or finds no network is kept in History to retry.
- **Every language the user speaks is treated the same.** "Languages I speak" is a list,
  empty until the user fills it; no language is the default.
- **Few dependencies, each behind one file.** Apple frameworks plus WhisperKit, FluidAudio,
  Sparkle and llama.cpp, each imported by one file per use. A new one needs a measurement
  showing it beats what we have, and one file that names it.
- **Measured, not remembered.** A constant, a model default or a vendor fact comes with
  what it was measured or checked against, and when.

## A note from the maintainer

Draft for the maintainer to edit.

SpeechText is one person's project, used every day. Keep it small enough that one person
can hold all of it.

- Solve the problem in front of you. No code for a future nobody asked for; an
  abstraction is earned by its second use.
- Scope grows quietly. A change that brings a new setting, a new surface or a new place
  data goes is a separate conversation, in an issue, before the code.
- The code is full of decisions that look like oversights. Before you "fix" something
  odd, look for its entry in docs/decisions.md or the comment above it.
- These rules are good defaults, not law. When one is wrong for the case in front of
  you, say so and why, in the pull request.

## Glossary

- **Dictation** — one recording from shortcut to paste. *Inline* (⌃⇧Q) shows the
  overlay and pastes at the cursor; *AI* (⌃⇧A) does the same through AI Rewrite.
- **Overlay** — the small floating strip an inline or AI dictation shows; live text is
  drawn there and nowhere else.
- **Record Window** — the ⌃⇧W panel with its own text view; also where a dictation goes
  when it cannot be pasted.
- **Edit selection** — ⌃⇧E: the selected text is rewritten by a spoken instruction and
  replaces the selection.
- **Hold to talk / toggle** — a held shortcut records until it is let go; otherwise a
  press starts and a second press stops.
- **Engine, tier** — what turns audio into text: Apple (on device), *local* (Parakeet or
  Whisper on this Mac), *upload* (a cloud model given the file at the stop) or *realtime*
  (a cloud stream for live text, always backed by an upload).
- **Segment** — the audio between a start or resume and the next pause or stop; each
  gets its own recognition session.
- **Partial, commit, span** — a stream's tentative and final text, and the unit the
  overlay draws them as.
- **Provider** — the company or source that serves models (`ProviderDescriptor` in
  `ProviderRegistry.swift`); the Mac is one.
- **AI Rewrite, preset** — the LLM pass, and the prompt it picks for the text in front of
  it (Clean-up, Email, …).
- **Dictionary** — the user's words: sent to engines that take a word list, and
  corrected in the final text.
- **Skin** — *techno* (the dot-matrix device) or *minimal* (glass); chrome only, never
  the feature set.
- **Setup** — the first-run window.
- **`portable`** — the settings keys carried across a bundle-identifier rename.
- **Trace, corpus** — a recorded dictation's provider events, and the recorded audio
  clips engines are measured on. Both hold someone's voice or words and stay outside the
  repository.

## Ways to hurt yourself

- **Tests that touch `UserDefaults` or the keychain** read and overwrite your own
  settings and API keys. Construct values directly.
- **A `DEVELOPMENT_TEAM` written into `project.pbxproj`.** It is refused by the hook and
  by CI. Xcode adds it when a build setting changes; revert that hunk (docs/development.md
  › Code signing).
- **Moving the bundle identifier or the keychain group.** macOS keys every permission
  grant to the bundle identifier and team; a keychain group that moved would hide every
  stored key. Neither follows a rename (docs/decisions.md › The renames).
- **A new protected resource without its entitlement.** The hardened runtime lets it
  work in a debug build and fails it only in signed builds.
- **`scripts/e2e.sh` and `scripts/rebuild.sh` quit the installed app** and reopen or
  replace it. Say so before you run them on someone's Mac.
- **Logic in the app target that a test needs.** The test bundle compiles no app file;
  put it in `Packages/SpeechTextCore`.
- **A closure an API calls off main, without `@Sendable`.** The runtime stops the app
  when it runs there (docs/development.md › Concurrency).
- **A compiler warning.** CI fails on any warning in our code; fix it, do not leave it.

## Hit every surface

A change to what a dictation does is a change to every place it shows. Before you call
it done, go through the ones it touches:

- the inline overlay and the Record Window, which share no view code;
- the **techno** and **minimal** skins, which draw each surface twice;
- Apple, local, upload and realtime engines;
- hold to talk and toggle, and switching between plain and AI mode mid-dictation;
- Edit selection;
- the main window's pages (Home, History, Usage, Prompts, Dictionary), Settings, setup
  and the menu bar menu;
- History and retry, offline included.

## Verifying

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj -scheme SpeechText \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SPT_WARNINGS_AS_ERRORS=YES
scripts/lint-swift.sh
```

The flag makes a warning fail the build, as CI does; the lint reads only the Swift lines
your branch changes. A provider change also runs `scripts/check-provider-guide.sh`.

The test bundle cannot host the app. To check the path from provider events to the paste,
`DictationReplay` drives scripted events through the real sessions into fake apps;
`scripts/e2e.sh` runs the whole app with real shortcuts on your Mac, never in CI
(docs/e2e.md); engine accuracy is measured on the audio corpus (docs/audio-corpus.md).
What none of these can check — a real microphone, a permission prompt, a paste into an
app the e2e run cannot read back — goes under *Needs a real-app run* in the pull request.

## Tests

The test bundle is standalone — no `TEST_HOST`, no `@testable import` of the app: the
app is a menu bar agent that asks for the microphone at launch, so hosting tests in it
would hang a headless run. The logic it tests lives in the local package
`Packages/SpeechTextCore`, which the app, the tests and the `SpeechTextEvaluation` tool
link. **Logic that test code needs goes in the package**, with anything it depends on; a
file there needs no `project.pbxproj` edit, and whatever the app calls is `public`. A
package file never reaches into views, `AppState` or `SpeechEngine`, and cannot import an
engine (the manifest declares no dependency); CI's *Core imports* check refuses
`import SwiftUI` there. Tests never touch `UserDefaults` or a real keychain; construct
values directly. docs/development.md › Tests has the rest, and
[docs/test-coverage.md](docs/test-coverage.md) says which test covers what.

## Adding a provider

Follow `docs/adding-a-provider.md` (the `add-provider` skill walks it). **A PR that changes the provider abstractions updates that guide too.** CI's "Provider guide" check runs `scripts/check-provider-guide.sh`, which fails when the guide names code that no longer exists or misses a capability value the code has.

## Pull requests

- **Small fix:** open a PR. **Anything bigger** — a feature, a refactor, a new setting, a
  UI change, anything in the recording pipeline — starts as an issue and waits for an
  answer (CONTRIBUTING.md).
- One concern per PR, based on `main` (a stacked PR is labelled `stacked`). Merges are
  squashes.
- The description says what changed and why, and under *Needs a real-app run* what only
  a person can check (or "None"). UI changes carry a before/after screenshot; motion or
  timing, a short video.
- A user-facing change gets an entry under `## [Unreleased]` in CHANGELOG.md, written for
  users.
- CI must be green: Tests, Swift lint and Checks (SPDX headers, sign-off, Core imports,
  log privacy, the provider guide, the base branch).
- Everything in the repository is in English. New source files start with the two-line
  SPDX header.

## Commits

Every commit you author is signed off — `git commit -s` (and `git commit --amend -s` for one that was not). The repository allows squash merging only, so there are no merge commits: the squash commit GitHub writes onto `main` keeps the `Signed-off-by:` trailers of the pull request's commits, and whoever merges must leave them in the message, because nothing checks the squash commit itself. CI's `DCO sign-off` check fails a pull request if any commit in its range lacks the trailer; it is a step of the *Checks* job, which the `main` ruleset requires with Tests and Swift lint, so an unsigned commit blocks the merge (see docs/development.md › Sign-off and › CI). `git config core.hooksPath .githooks` turns on the `prepare-commit-msg` hook that adds it automatically, and the `pre-commit` hook that refuses a `DEVELOPMENT_TEAM` written back into `project.pbxproj`, a source file without its SPDX header, one that is in no target, or a new Swift file in the app or in `Packages/SpeechTextCore` named like one already in the other (see CONTRIBUTING.md › Hooks), but a worktree without the hooks enabled commits unsigned, so pass `-s` regardless.

## Documentation

- **No file catalogs.** Do not list files and what they hold; the code and
  docs/architecture.md's short map do that, and a catalog falls behind with every change.
  Explain a decision where it is made — in the comment above the code, or in
  docs/decisions.md when it spans files.
- **No feature lists.** Describe how a thing behaves and why, not an inventory of what
  exists.
- **Rewrite, do not append.** When a decision changes, replace its text; a paragraph
  that grows a "but now…" every release reads as history, and history is in git.
- **The code wins.** Where a doc and the code disagree, fix the doc in the same PR.
- A change to the provider abstractions updates docs/adding-a-provider.md; a settings key
  updates the table below; a user-facing change, CHANGELOG.md.

## Plans and work artifacts

Design documents for larger features are dated: `docs/specs/YYYY-MM-DD-name.md`, written
before the code and left as history once it lands. Notes, traces, corpus runs and
anything holding dictated words stay outside the repository.

## Where code lives

- `SpeechText/SpeechText/` — the app: views, `AppState`, `SpeechEngine`, the capture and
  the Apple recogniser, `PasteService`, the hotkeys, the engine runtimes, the stores.
- `Packages/SpeechTextCore/Sources/SpeechTextCore/` — the logic: settings, catalogues,
  transcribers, the upload and streaming sessions, History, and the pure halves of
  delivery, shortcuts, text and usage. `Sources/ChatTemplates/` is a product of its own.
- `SpeechText/SpeechTextTests/` — the unit tests.
- `SpeechText/SpeechTextLLM/` — the XPC service that runs AI Rewrite on this Mac.
- `Packages/LlamaBinary/` — llama.cpp, prebuilt and pinned.
- `scripts/`, `.githooks/`, `.github/workflows/` — tooling, hooks, CI and the release.

docs/architecture.md is the map: the main flow of a dictation and the files worth knowing
first.

## Naming

When the user names something, the word may be one they coined rather than the accepted one. Before that name goes into the code, the settings keys, the UI or these docs, check whether the thing already has a standard name — in the platform's vocabulary or the field's — and say what it is, so the choice is deliberate. Where no standard name exists, say that too. A competitor's product name is not a standard term and stays out of the repo.

Words the user reads — titles, captions, notices, VoiceOver labels — are spelled in American English ("color", "canceled", "recognize"), as macOS's own windows are, which the app shows beside its own (the color panel, System Settings). Comments, logs and these docs are not held to it.

## Taste

- Match the surrounding code: its layout, naming, comment density and idiom. The code is
  wrapped as Xcode wraps it, so no formatter is run over it; leave lines you did not
  change alone.
- Comments say *why*. A measured constant says what it was measured against; latency and
  quality constants live in `STTTuning`.
- One state, many views: a single stored enum (`RecordingPhase`), with booleans computed
  from it.
- Pure logic in SpeechTextCore, side effects at the edge, so the decision can be tested
  without the app.
- Diagnostics go through `dlog`, at the right level, with no user words.
- Fail toward the user's text: every AI Rewrite failure pastes the transcript as
  dictated, and a failed edit puts the selection back.

## Skills

Task guides for agents live in `.claude/skills/` (`.agents/skills/` is the same folder,
for agents that read that path): `contribute`, `add-provider`, `add-setting` and
`add-to-a-list`. Each `evals/` folder inside a skill holds test cases for
`claude plugin eval`, not tasks; their results stay out of git.

## Settings Keys Reference

| Key | Purpose | Default |
|-----|---------|---------|
| `sttProvider` | STT backend (`"apple"`, `"groq"`, `"elevenlabs"`, `"openai"`, `"local"` — `local` covers both on-disk engines, chosen by `localSTTModel`) | `"apple"` |
| `groqAPIKey` | Groq API key — like every `…APIKey`, held by `APIKeyStore`: the keychain in a build with the profile, UserDefaults otherwise; never in `portable` | empty |
| `groqModel` | Groq Whisper model ID | `"whisper-large-v3-turbo"` |
| `localSTTModel` | Model ID for the local engine — a WhisperKit variant or a Parakeet build (`parakeet-tdt-0.6b-v3`, `parakeet-ultra`, `parakeet-redux`, `phonon-2`), the catalogue entry's `engine` deciding which runtime gets it (an ID the catalogue does not know is cleared at launch) | `"parakeet-tdt-0.6b-v3"` |
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
| `holdToTalk` | Holding a dictation shortcut records until it is let go (a lone tap cancels, a double tap locks it on hands-free); for the Edit shortcut, a hold is the instruction and a double tap sends none | `false` |
| `escapeCancelsDictation` | ⎋ cancels a dictation or an edit while the overlay is up; global for that time, so ⎋ reaches no other app | `false` |
| `editHotkeyKeyCode` / `editHotkeyModifierFlags` | Edit-selection-with-AI hotkey | `14` (E) / Control+Shift |
| `hotkeyLayoutVersion` | Shortcut-layout migration marker | `0` (unmigrated) |
| `llmProvider` | LLM backend (`"groq"`, `"anthropic"`, `"openai"`, `"local"`); a stored `"ollama"` moves to `"local"` at launch | `"groq"` |
| `groqLLMModel` | Groq chat model ID | `"openai/gpt-oss-120b"` |
| `anthropicAPIKey` / `anthropicModel` | Anthropic key and model | empty / `"claude-sonnet-5-5"` |
| `openAIAPIKey` / `openAIModel` | OpenAI key and chat model. The key is shared with the speech engine, as Groq's is | empty / `"gpt-6-luna"` |
| `localLLMModel` | The chat model AI Rewrite runs on this Mac — a `LocalChatModel` id, normalised against `localChatModels` | `"gemma-4-12b-it-qat-q4_0"` |
| `promptPresets` | JSON-encoded `[PromptPreset]` | built-in defaults |
| `defaultPresetID` | UUID of the fallback preset | Clean-up |
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
| `modelMigrations` | Stored model choices the launch moved to a replacement or cleared (JSON `[ModelMigration]`, newest last, at most 20), for the next dictation's notice. Machine-local, not in `portable` | absent |
| `modelNoticesShown` | Model IDs whose lifecycle notice was shown. Machine-local | absent |
| `microphoneNoticeShown` | The one-time notice that Automatic recorded with the Mac's microphone instead of Bluetooth headphones was shown. Machine-local | `false` |
| `overlayOrigin` | Where the user dragged the inline overlay: the strip's bottom-left corner as `"x,y"` in screen coordinates; empty means the bottom-right corner. Machine-local, not in `portable` | `""` |
| `recordDictationTraces` | Debug Log › Record traces: save each streamed inline dictation to `Traces/` (dictated text in plain text); machine-local, not in `portable` | `false` |
| `hasRegisteredLaunchAtLogin` | One-shot marker: on the launch it is not set, the app registers itself as a login item (default ON) and sets it, so a user who later switches it off is not re-registered. While setup is showing, its Permissions step does this instead | `false` |
| `onboardingCompleted` | Setup was finished, or the install predates it. Absent on a new install until its first launch decides: `false` while setup is unfinished; not in `portable` | absent |
| `onboardingStep` | `OnboardingStep.rawValue` an unfinished setup was left on | absent |
| `didAdoptPreRenameDefaults` | One-shot marker for `adoptPreRenameDefaults()`; stays out of `SettingsKeys.portable`, or the copy would mark itself done | `false` |
