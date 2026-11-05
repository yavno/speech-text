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
would hang a headless run. What a test needs lives in `Packages/SpeechTextCore/Sources/SpeechTextCore/`,
`public` where the app calls it; a file there needs no `project.pbxproj` edit, never reaches into
views, `AppState` or `SpeechEngine`, and imports neither SwiftUI nor an engine (CI's
*Core imports*). docs/development.md › Tests has the rest, and
[docs/test-coverage.md](docs/test-coverage.md) says which test covers what.

## Adding a provider

Follow [docs/adding-a-provider.md](docs/adding-a-provider.md) (the `add-provider` skill
walks it), and update that guide in any PR that changes the provider abstractions; CI's
*Provider guide* check fails when it names code that is gone.

## Pull requests

- **Small fix:** open a PR. **Anything bigger** — a feature, a refactor, a new setting, a
  UI change, anything in the recording pipeline — starts as an issue and waits for an
  answer (CONTRIBUTING.md).
- One concern per PR, based on `main` (a stacked PR is labelled `stacked`).
- Fill the template: what changed and why, under *Users will notice* what changes for
  someone using the app (or "Nothing"), and under *Needs a real-app run* what only a
  person can check (or "None"). A UI change carries a before/after screenshot; motion or
  timing, a short video.
- Leave CHANGELOG.md alone: the maintainer writes the `## [Unreleased]` entry after the
  merge, from *Users will notice*.
- Everything in the repository is in English. A new source file starts with the two-line
  SPDX header.

## Commits

- Sign off every commit: `git commit -s` (`--amend -s` for one that was not). CI's *DCO
  sign-off* blocks the merge otherwise. Pass `-s` even with the hooks on: a worktree
  without `core.hooksPath` set commits unsigned.
- Merges are squashes, and the squash message keeps the commits' `Signed-off-by:` lines.
  CONTRIBUTING.md › Sign-off and › Hooks have the rest.

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
- A change to the provider abstractions updates docs/adding-a-provider.md; a settings-key
  change updates [docs/settings-keys.md](docs/settings-keys.md). CHANGELOG.md is written
  after the merge (Pull requests, above).

## Plans and work artifacts

Design documents for larger features are dated: `docs/specs/YYYY-MM-DD-name.md`, written
before the code and left as history once it lands. Notes, traces, corpus runs and
anything holding dictated words stay outside the repository.

## Where code lives

- `SpeechText/SpeechText/` — the app: views, `AppState`, `SpeechEngine`, capture, the
  hotkeys, the engine runtimes, the stores.
- `Packages/SpeechTextCore/Sources/SpeechTextCore/` — the logic, and everything a test
  needs; `Sources/ChatTemplates/` is a product of its own.
- `SpeechText/SpeechTextLLM/` — the XPC service that runs AI Rewrite on this Mac;
  `Packages/LlamaBinary/` is the llama.cpp it links, prebuilt and pinned.

docs/architecture.md is the map: the main flow of a dictation and the files worth knowing
first.

## Naming

When the user names something, the word may be one they coined rather than the accepted one. Before that name goes into the code, the settings keys, the UI or these docs, check whether the thing already has a standard name — in the platform's vocabulary or the field's — and say what it is, so the choice is deliberate. Where no standard name exists, say that too. A competitor's product name is not a standard term and stays out of the repo.

Words the user reads — titles, captions, notices, VoiceOver labels — are spelled in American English ("color", "canceled", "recognize"), as macOS's own windows are, which the app shows beside its own (the color panel, System Settings). Comments, logs and these docs are not held to it.

Those words live in the String Catalog, `SpeechText/SpeechText/Localizable.xcstrings`, keyed
by the English text:

- After adding or changing a string literal passed to SwiftUI (`Text("…")`, `Button("…")`,
  …), run `scripts/sync-strings.sh` and commit the catalog with the code; CI fails when
  the two are out of step.
- The permission prompts and the copyright line are in `Info.plist` and again, as
  their English source, in `InfoPlist.xcstrings`; change both together
  (`scripts/check-infoplist-strings.sh`).
- The rest — comments, plurals, what stays verbatim — is in
  docs/specs/2026-11-04-localization.md.

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

## Skills and settings

- Task guides for agents are in `.claude/skills/` (also at `.agents/skills/`); an `evals/`
  folder inside one holds test cases for `claude plugin eval`, not tasks.
- Every settings key, its purpose and default is in
  [docs/settings-keys.md](docs/settings-keys.md); read it before touching a setting.
