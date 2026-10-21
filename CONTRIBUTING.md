# Contributing to SpeechText

Contributions are welcome. This document exists so you never waste work on something that was never going to be merged.

## Before you write code

**Small fix?** Just open a PR. Typos, crashes, a wrong constant, a broken edge case — no ceremony needed.

**Anything bigger?** Open an issue first and wait for a reply. This includes new features, refactors, new settings, UI changes, and anything touching the recording pipeline. A PR that arrives without a prior issue may be closed even if the code is good, simply because it takes the project somewhere it isn't going.

Issues labelled [`good first issue`](../../labels/good%20first%20issue) and [`help wanted`](../../labels/help%20wanted) are pre-approved — take one and go.

## What is likely to be accepted

- Bug fixes, crash fixes, race conditions
- Accuracy or latency improvements with a measurement behind them
- New speech or LLM providers that fit the provider registry (`ProviderDescriptor`, see `docs/adding-a-provider.md`) — open an issue first (a new provider is a new place user data goes), then follow [docs/adding-a-provider.md](docs/adding-a-provider.md)
- Accessibility and localization work
- Test coverage for code that currently has none
- Documentation that fixes something wrong or missing

## What is unlikely to be accepted

- New third-party dependencies. The app is Apple frameworks plus four packages, each a deliberate decision with its own boundary: WhisperKit and FluidAudio for local speech models (FluidAudio also runs the voice activity detector), Sparkle for updates, and llama.cpp for AI Rewrite on this Mac — the last as a prebuilt binary package (`Packages/LlamaBinary/`) run in the SpeechTextLLM XPC service, which the app never links. Each is imported by one file per use — see the *Not planned* section of ROADMAP.md for the rule a fifth would have to meet.
- Large refactors that arrive unannounced
- Reformatting or restyling existing code
- Features that expand the product's scope without a prior discussion
- Anything that sends user data somewhere new

## Your first pull request

1. Clone the repository and turn on the hooks: `git config core.hooksPath .githooks` (see [Hooks](#hooks)).
2. Open `SpeechText/SpeechText.xcodeproj` in Xcode, or run the tests from a terminal:

   ```bash
   xcodebuild test -project SpeechText/SpeechText.xcodeproj -scheme SpeechText -destination 'platform=macOS'
   ```

   The first build resolves the Swift packages and takes a while; after that the suite (about 710 tests) runs in a few seconds.
3. Pick an issue labelled [`good first issue`](../../labels/good%20first%20issue), say in a comment that you are taking it, and open a pull request when it is ready. A draft pull request is a fine way to ask a question.

## Hooks

One command turns on the repo's git hooks, and the sign-off, the `DEVELOPMENT_TEAM` check and the SPDX header stop being things you have to remember:

```bash
git config core.hooksPath .githooks
```

- `prepare-commit-msg` adds the DCO `Signed-off-by` line to every commit, so `-s` is no longer something to forget.
- `pre-commit` refuses a commit that puts a `DEVELOPMENT_TEAM` back into `project.pbxproj`, adds a source file without the SPDX header, adds an app source file that is in no target, or adds a Swift file to the app or to `Packages/SpeechTextCore` named like one already in the other. It reads the *staged* content and takes a fraction of a second; `--no-verify` bypasses it.

The test suite is deliberately not in a hook — CI runs it on every pull request and on every push to `main`, and a hook slow enough to avoid is a hook that gets bypassed.

## Signing your commits (DCO)

Every commit you author must carry a `Signed-off-by` line. Turn the hooks on (above) and it is added for you; otherwise Git adds it when asked:

```bash
git commit -s -m "Fix hotkey re-registration after sleep"
```

This is the [Developer Certificate of Origin](https://developercertificate.org/) — you are stating that you wrote the code, or otherwise have the right to submit it under the project's license. There is no CLA and you keep the copyright to your contribution.

That is a commitment, not a current convenience: no CLA will be introduced later, and the client will not be relicensed under closed terms. Your contribution stays yours, under GPL-3.0-or-later.

If you forget, `git commit --amend -s` fixes the last commit, and `git rebase --signoff main` fixes every commit on the branch.

Pull requests are merged as squashes — the only merge method the repository allows — so there is no merge commit to sign. The squash commit keeps the `Signed-off-by` trailers of the commits it replaces; when merging, leave them in the message.

## Pull request checklist

Short on purpose. Anything a machine can refuse for you is not on it:

- One concern per PR. Don't mix an unrelated fix into a feature.
- Logic you want tested goes in `Packages/SpeechTextCore/Sources/SpeechTextCore/`, which needs no project edit; views and anything that touches `AppState` or `SpeechEngine` stay in `SpeechText/SpeechText/` (see [docs/development.md](docs/development.md#tests)). A type the app uses is `public` there — the compiler says so, but as `cannot find 'X' in scope` in an app file, which reads like a missing import.
- UI changes include a before/after screenshot. Anything with motion or timing includes a short video.
- The description says what changed and why, and under *Needs a real-app run* what only a person can check in the running app (or "None").

Everything else is checked for you. CI runs the test suite (which compiles the app too, and fails on any compiler warning in our code — see [docs/development.md](docs/development.md#compiler-warnings)), refuses a `DEVELOPMENT_TEAM` written back into `project.pbxproj`, refuses a Swift file without its SPDX header, fails when docs/adding-a-provider.md no longer matches the provider code, refuses `import SwiftUI` (or an engine's import) in `Packages/SpeechTextCore`, and requires a `Signed-off-by` on every commit in the pull request. The hooks above catch the same things before you push, except the provider guide, and add the sign-off itself.

## Review

[`.github/CODEOWNERS`](.github/CODEOWNERS) names who reviews; for now that is the maintainer, who looks at every pull request. Expect a first response within a few days — this is one person's project, so it is not an SLA, and a nudge on the pull request after a week is welcome.

- CI must be green before a merge. While the repository is private GitHub lets a red pull request through — no check is required there — so any red check, *DCO sign-off* included, is "do not merge" by agreement.
- A pull request that lists something under *Needs a real-app run* is not blocked on you: the maintainer checks those items in a real build, with a real microphone and the apps the e2e run cannot read back. Say as precisely as you can what to check.
- Review comments are about the change, not you. If the answer to a comment is "that was on purpose", say so and why; the code is full of decisions that look like oversights.

## Issue and pull request numbers

The history was rewritten before the repository went public ([docs/development.md](docs/development.md) has the story). Issue and pull request numbers from before it were removed from the code, the docs and the commit messages, so a `#N` you find here is this repository's. If a comment refers to an earlier decision you cannot find, ask in an issue.

## Formatting

Match the surrounding code — its layout, its naming, its comment density, its idiom — and leave the lines you did not change alone. The code is wrapped the way Xcode wraps it, which no formatter reproduces, so a formatter is never run over the codebase.

What is checked is a short list of swift-format's rules about constructs to avoid (a `.forEach` where a `for` loop reads better, two enum cases on one line, a block comment). Run `scripts/lint-swift.sh` before you push: it lints the Swift files your branch changes against `origin/main` and ignores every finding about layout. CI runs the same script as *Swift lint*. It reports findings on the lines you changed and nothing else: an old finding elsewhere in a file you touched is not yours to fix here (restyling pull requests are refused above). Its configuration is `.swift-format`.

## Language

Everything in the repository is written in English: code, comments, commit messages, pull requests, issues and documentation — the same language as the app's UI. Words in other languages appear only as data, such as a Ukrainian transcript a test or an explanation quotes.

## Setting up

[docs/architecture.md](docs/architecture.md) is a short overview of how the app is put together — start there. [docs/development.md](docs/development.md) covers building, testing and the project layout. [`CLAUDE.md`](CLAUDE.md) is the exhaustive architecture reference — read the relevant section before changing the recording pipeline.

## License

SpeechText is [GPLv3 or later](LICENSE), copyright (C) 2026 Vladyslav Husakov. By contributing you agree your work is published under it. You keep the copyright to your contribution — there is no CLA.

New source files start with the two-line SPDX header the rest of the codebase carries:

```swift
// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later
```

Substantial contributions may add their own `SPDX-FileCopyrightText` line below it.
