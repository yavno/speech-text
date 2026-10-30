# Development

## Build

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Build with `Cmd+B`, run with `Cmd+R`. The first build resolves three Swift packages, all pinned in `Package.resolved`: [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) and [FluidAudio](https://github.com/FluidInference/FluidAudio) for the two local speech engines and the voice activity detector, and [Sparkle](https://sparkle-project.org) for updates. The fourth dependency, [llama.cpp](https://github.com/ggml-org/llama.cpp), is not resolved: it is a local package, `Packages/LlamaBinary/`, a binary target at ggml-org's prebuilt `llama.xcframework` pinned by build and checksum, linked only by the `SpeechTextLLM` XPC service and the `SpeechTextEvaluation` tool — never by the app. Everything else is Apple frameworks. Every target builds in the Swift 6 language mode with Swift 6.4 tools (`swift-tools-version:6.4` in `Packages/SpeechTextCore`), so the project takes Xcode 27.1 or later, which runs on macOS 26.6 or later — the app itself still runs on macOS 14 (see **Concurrency** below).

Their licences — and those of the code each carries inside it — ship in the app as `Resources/ThirdPartyNotices.txt` (Settings › General › Acknowledgements). It is generated: after adding, removing or updating a package, run `scripts/third-party-notices.sh` and commit the result; `ThirdPartyNoticesTests` fails while the file names a version `Package.resolved` no longer pins.

### Code signing

The tracked project has an **empty `DEVELOPMENT_TEAM`** on purpose, so the repo builds for anyone who clones it. Xcode signs it locally ("Sign to Run Locally"), which is all you need for development.

Do **not** commit your team ID back into `project.pbxproj`. If Xcode adds it when you change a build setting, revert that hunk before committing. Release builds pass the team in at build time:

```bash
xcodebuild -project SpeechText/SpeechText.xcodeproj -scheme SpeechText \
  -configuration Release DEVELOPMENT_TEAM=XXXXXXXXXX build
```

### Hardened runtime

The app is built with the **hardened runtime** in both configurations, because notarization requires it, and a runtime restriction that only showed up in the notarized build would first be discovered by users. Everything the runtime would otherwise refuse is declared in `SpeechText/SpeechText.entitlements`:

| Entitlement | Used by |
|---|---|
| `com.apple.security.device.audio-input` | the microphone (`AVAudioEngine`) |
| `com.apple.security.automation.apple-events` | the AppleScript fallback that brings the target app back to the front before a paste (`PasteService.activateApp`) |

Accessibility (the ⌘V paste and reading the focused field) and speech recognition need no entitlement: macOS gates them through its privacy prompts alone. Adding a feature that touches another protected resource — the camera, location, the calendar, JIT-compiled code — means adding its entitlement here, or it fails only in signed builds. See [releasing.md](releasing.md) for how a release is signed and notarized.

## Hooks

```bash
git config core.hooksPath .githooks
```

Adds the DCO sign-off to every commit, and refuses one that carries a `DEVELOPMENT_TEAM`, a new Swift file without the SPDX header, a new Swift file that is in no target, or a new Swift file in the app or in `Packages/SpeechTextCore` named like a file already in the other. See [CONTRIBUTING.md](../CONTRIBUTING.md#hooks).

## Tests

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj \
  -scheme SpeechText -destination 'platform=macOS'
```

The test bundle is **standalone** — no `TEST_HOST`, no `@testable import` of the app. The app is a menu bar agent that asks for microphone access at launch, so hosting tests inside it would hang a headless run. Instead the logic the tests cover lives in a local Swift package, `Packages/SpeechTextCore`, whose module of the same name the app, the tests and the evaluation tool link. The test target compiles no app source.

A file under `Packages/SpeechTextCore/Sources/SpeechTextCore/` needs no `project.pbxproj` edit: the package compiles every file there, once. The app reaches what it uses through `import SpeechTextCore`, so whatever the app or the tool calls is `public`; a test reaches the rest with `@testable import SpeechTextCore`, which imports a module, not the app, so the bundle stays standalone. The three test files the evaluation tool also compiles (`CatalogueExport`, `CorpusEvaluation`, `LiveDictation`) use a plain `import`, since the tool is built in Release, without testing enabled. `ChatTemplates` is a second product of the same package, under `Sources/ChatTemplates/`, linked on its own by the `SpeechTextLLM` service.

**Consequence:** if your test needs new logic, put it in the package, together with anything it depends on. What stays in `SpeechText/SpeechText/` is what the package may not hold: SwiftUI views, `AppState`, `SpeechEngine`, the capture, `PasteService`, the hotkeys, the engine runtimes, the stores, the XPC client and the keychain. A package file must not reach into that graph, and it cannot import an engine at all — the manifest declares no dependency, so `import WhisperKit`, `FluidAudio`, `Sparkle` or `llama` there is a build error. `import SwiftUI` is the one the manifest cannot stop; CI's *Core imports* check does. A new file in the app (a view, say) is still added to the app target in Xcode, and the evaluation tool compiles the engine runtimes it runs directly, so a new runtime file goes in its Sources phase too.

Tests never touch `UserDefaults` or the keychain: your real settings live in that domain, and a build without the profile keeps your API keys there too. Construct values directly instead; `APIKeyStoreTests` gives the store an isolated `suiteName` and a keychain in memory.

## API keys

The API keys — one per provider that has one in `ProviderDescriptor`: Groq, ElevenLabs, OpenAI, Anthropic — are billing credentials, so they are not ordinary settings. `APIKeyStore` holds them in memory, and where they live on disk depends on how the build was signed:

- **Signed with the Developer ID provisioning profile** (releases, and `scripts/rebuild.sh` when the profile is in `~/.config/speech-text/`): the *data-protection keychain*, in the access group `TEAMID.app.speech-text.SpeechText`. Only code signed by this team with a profile that authorises the group can name it, so another process running as the user cannot read an item, with or without a prompt — unlike a plist, which any of them reads silently, and unlike the file-based login keychain, which asks the user and is one click away from saying yes. Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: tied to this Mac, never restored onto another. The group is fixed at `TEAMID.app.speech-text.SpeechText` rather than derived from the bundle identifier, so a future rename still finds the keys.
- **Without it** (Xcode ⌘R, a contributor's clone, a self-signed `SpeechText Dev` build): that keychain answers `errSecMissingEntitlement`, so the keys stay in UserDefaults, as they always did. A plist is not a store for secrets — mode `0600`, but readable by anything running as you and copied by every backup — which is why nothing distributed is built this way.

The mode is fixed at launch from the app's own signature (whether it carries `keychain-access-groups`), never from a failed call, so a passing keychain error cannot send a release's keys back into a plist. In keychain mode the first launch moves every key it finds — in the current domain first, then the pre-rename chain — writes it, reads it back, and only then deletes it from all four domains; a write that fails keeps every copy. A key found in the current domain *after* that is newer than the keychain's (a ⌘R build shares the domain) and replaces it.

The entitlements that name the group are **restricted**: signed without a profile that authorises them for this team, this app and this certificate, the app does not launch. So they are never in the tracked `SpeechText.entitlements`; `scripts/keychain-profile.sh` adds them only after checking all three, and `package-release.sh` refuses to make a distributable image without them. Setting the profile up is in [releasing.md](releasing.md#5-the-provisioning-profile).

Two costs follow. A change of Apple team makes the items unreachable, and every user enters their keys again (releasing.md says why the team is not expected to change). And a ⌘R build cannot see the keys a signed build moved — enter them there too, or sign ⌘R builds with an Apple Development profile of your own.

## Pull requests

**Base every pull request on `main`.** CI refuses any other base, because a pull
request based on a branch merges into *that* branch — and if the branch has
already landed, the merge is green and the work never reaches `main`. It happened
before the history rewrite: a pull request merged into a branch `main` had stopped
following seven minutes earlier.

Stacking is still allowed where it earns its keep. Label the pull request
`stacked` and re-run the *Checks* job; its *Base branch* step then passes and prints
which pull request has to land first, and that this one must be retargeted at `main`
afterwards. The label is read live, so labelling a refused run and re-running the
job is enough — no new push. The step still refuses a stack whose base has already
merged, which is that shape itself.

The audit that catches an evasion after the fact:

```bash
scripts/audit-merged-pull-requests.sh
```

It asks GitHub for every merged pull request and checks that each merge commit is
an ancestor of `origin/main`, exiting non-zero if any is not — or if any could not
be judged, since an unaudited pull request is not a clean one. Worth running
before a release and after any history rewrite.

A miss is permanent, which the script's `accounted_for` list exists for. A merge
commit that never reached `main` cannot be made an ancestor afterwards: the work
comes back as a *different* commit through a fresh pull request. Such an entry
is printed and the run stays green; left out, the audit would fail forever, and a
check that always fails is a check nobody reads. The list is empty: its one entry
from before the history rewrite named a pull request this repository does not have.

## Sign-off

Every commit you author carries a `Signed-off-by` trailer (see
[CONTRIBUTING.md](../CONTRIBUTING.md#signing-your-commits-dco)). The repository
settings take care of the rest:

- **Squash merging only.** Merge commits and rebase merging are off, so the merge
  button makes one commit on `main` per pull request and never a merge commit.
- **The squash message is the pull request's title and description.** GitHub
  appends the trailers of the commits being squashed, so the squash commit carries
  their `Signed-off-by`. Leave those lines in when you merge: the *DCO sign-off* check reads
  the pull request's commits, and nothing checks the squash commit afterwards.
- **Head branches are deleted on merge**, so merged branches do not pile up.

The *DCO sign-off* check fails a pull request with an unsigned commit; the one exemption is
Dependabot's own commits (`.github/dependabot.yml`), and only in a pull request that
Dependabot itself opened. It is a step of the *Checks* job, which the `main`
ruleset requires (see *CI* below), so an unsigned commit blocks the merge.

### Known unsigned history

`main` holds 45 commits with no trailer: 42 from before squash-only, and three
squash commits since. Neither history rewrite (below) signed them, so as not to
change their messages more than it had to. They are:

- **39 merge commits** made by the *Merge pull request* button, the last one
  `e1f7f87` (2026-09-22). GitHub writes those itself and cannot add a
  trailer, and CI never sees them because they are made after the pull request's
  range. Squash-only removes this kind of commit.
- **Three ordinary commits**, all made after the `dco` job (2026-09-13) and the
  sign-off hook (2026-09-15) existed:
  - `0438f92` *Document phase A completion and add offline test runner*
    (2026-09-16). It came in through a pull request that was merged with its
    *DCO sign-off* check failing.
  - `6cccbde` *Add rebuild skill and build identity stamping* (2026-09-16), and
  - `3003a78` *Move rebuild skill into user-run script and docs* (2026-09-17).
    Both were pushed straight to `main` with no pull request, so no check ran.
- **Three squash commits** — `536416d` (2026-09-27), `e9bab16`
  and `fc13b7e` (both 2026-10-01) — merged with the message cut down to the
  title, which dropped the pull requests' `Signed-off-by` lines. This is the gap the
  bullet on the squash message warns about: nothing checks the squash commit itself.

A script that counts unsigned commits on `main` should report exactly these 45.
If it finds any others, that is a new gap.

### History rewrite (2026-10-15)

Before the first public release the history was rewritten with
`git filter-repo` and pushed to a new repository, so that it would not publish what
was never meant to be published: research notes, the manual test log, recorded
dictation traces and corpus runs (people's voices as text), the maintainer's real
dictations quoted in tests and comments (replaced with invented sentences of the same
shape), product names of other apps, and a work address in the authorship. The
code at the tip was the same before and after, apart from those test sentences.

- The repository before the rewrite is kept private, with its issues and pull
  requests. Their numbers were removed from the code, CLAUDE.md and these docs, so
  a bare `#N` in a comment or a doc is an issue or pull request here. The four
  issues still open moved here as #1–#4.
- `main` went from 293 commits to 278: commits that touched only removed files are
  gone. The build number is the commit count (`scripts/rebuild.sh`,
  `scripts/package-release.sh`), so a build made before the rewrite can carry a
  higher number than the next one made after it; only the maintainer's own installs
  were affected, and an update to one is a reinstall, not Sparkle.
- Every commit hash changed. A hash quoted from before the rewrite resolves only in
  the private repository from before it.

### History rewrite (2026-10-20)

Before the repository went public the history was rewritten a second time, the same
way: `git filter-repo` on a fresh clone of `main`, pushed to a new repository.

- **Removed from every commit:** design and marketing material for the website and
  an unbuilt feature's plan.
- **Commit messages** no longer cite issue or pull request numbers, of this
  repository or the one before it; where a number was the subject of a sentence it
  is named in words. Authors, dates and every `Signed-off-by` and `Co-authored-by`
  trailer are unchanged.
- The repository before this rewrite is kept private, with its pull requests,
  branches and issues; its numbers are not cited here. The open issues were opened
  again here as #1–#5.
- `main` went from 343 commits to 341: the two commits that touched only removed
  files are gone. The build number is the commit count, so it went down by two
  again, with the same consequence as above.
- Every commit hash changed again, and the hashes in these docs were translated. A
  hash quoted from before 2026-10-20 resolves only in the private repository.

## CI

`.github/workflows/ci.yml` runs on every pull request and on every push to `main`: the
squash that lands a pull request is a new commit, two green pull requests can combine into
a red `main`, and the README's CI badge reads `main`'s latest run. (*DCO sign-off* and *Base
branch* mean something only for a pull request and are skipped on a push.) **On a public repository
no job may run on the organisation's self-hosted Mac.** A pull request is code,
and anyone can open one; building and running it on someone's own Mac would hand
a stranger that machine's keychain, SSH keys and the app's `app.speech-text.SpeechText`
defaults domain, which is where a build without the profile keeps the API keys.

So every `runs-on` is keyed on the repository's visibility, and the flip is what
moves the work:

| Job | While private | Once public | What it does |
|---|---|---|---|
| Tests | `self-hosted` | `xcode-27` | `xcodebuild test` and the evaluation tool's build, a compiler warning in our code an error — one of the two jobs that need a Mac, with Swift lint |
| Swift lint | `self-hosted` | `xcode-27` | `scripts/lint-swift.sh` — swift-format's semantic rules (not layout) on the lines a pull request adds or changes; needs Xcode's `swift-format` |
| Checks | `self-hosted` | `ubuntu-latest` | the seven checks below, one step each |

The hosted Mac is GitHub's `xcode-27` image (macOS 27, Xcode 27.1 by default;
still a preview, actions/runner-images#14404), not `macos-latest`: on 2026-10-29
`macos-latest` was macOS 26 with Xcode 26.6 at most, and its Swift 6.3.3 refused
the package's `swift-tools-version:6.4` before building anything. Once
`macos-latest` carries Xcode 27 the label can go back. The Xcode is named, not
found: `scripts/ci-select-xcode.sh` selects `Xcode_$XCODE_VERSION.app` (27.1, the
project's floor) and fails when it is missing, because the image also carries a
release candidate linked as `Xcode_27.2.app`, which a "newest installed" rule
took.

| *Checks* step | What it checks |
|---|---|
| No development team | greps `project.pbxproj` for a `DEVELOPMENT_TEAM` |
| SPDX headers | the two-line header on every Swift file |
| Provider guide | `scripts/check-provider-guide.sh` — docs/adding-a-provider.md still names code that exists |
| Log privacy | `scripts/check-log-privacy.sh` — no `dlog` call interpolates dictated, selected or rewritten text |
| Core imports | `scripts/check-core-imports.sh` — no file under `Packages/SpeechTextCore/Sources` imports SwiftUI, WhisperKit, FluidAudio, Sparkle or llama |
| DCO sign-off | a `Signed-off-by` trailer on every commit in the range (pull requests only) |
| Base branch | the base is `main`, or the stack is labelled — see above (pull requests only) |

The seven were seven jobs of ten seconds each until 2026-10-21. On the one
self-hosted runner they queued one after another, around the Tests job, so a
failing grep could report last. As steps of one job each still runs whatever the
one before it did (`if: !cancelled()`), so a run shows every check that fails,
under its own name; re-running the job re-runs all seven.

On a private repository only collaborators can open a pull request, so every job
ran on the self-hosted Mac until the repository went public on 2026-10-29; then
every job moved by itself — nobody had to remember a second pull request, and
there was no window in which the arrangement was wrong. The polarity
is deliberate: an unrecognised visibility falls through to the hosted runner, so
the failure is a job that does not start rather than a stranger's code on
someone's Mac.

**The ruleset on `main` is the gate.** *Safe merge* takes changes only as
squash-merged pull requests, with no approving review required, and refuses a merge while
Tests, Swift lint or Checks is red; it also refuses force-pushes and deleting the
branch. Organization admins can bypass it, which is how the maintainer merges his
own pull requests. *DCO sign-off* and *Base branch* are steps of Checks, so they
block a merge too; a red Package run is "do not merge" by agreement.

Actions minutes are free for a public repository on the standard runners. The
Checks job then runs on Linux, where it is faster and costs a tenth as
much, and stops competing for a runner with the tests.

A hosted runner starts empty, so WhisperKit, FluidAudio and Sparkle would be
cloned on every run. `-clonedSourcePackagesDirPath .swiftpm-cache` puts them
somewhere `actions/cache` can keep, keyed on the hash of `Package.resolved` —
which pins all three, so it is exactly the right key. The step runs on a hosted
runner only: on the self-hosted Mac it downloaded the 614 MB archive on every run
(6.5 of the Tests job's 9 minutes on 2026-10-21) into a folder checkout had just
cleaned, while xcodebuild resolves from SwiftPM's own cache there in seconds.

### Compiler warnings

The app, its tests, the `SpeechTextLLM` service and the `SpeechTextEvaluation`
tool build with no compiler warnings, in the Swift 6 language mode, and CI
keeps it that way: both of the Tests job's builds pass `SPT_WARNINGS_AS_ERRORS=YES`,
so a warning a pull request adds in our code fails the job, named as an `error:`
at its line. A warning is cheap to fix the day it is written and expensive once
forty others hide it.

The project sets `SWIFT_TREAT_WARNINGS_AS_ERRORS` to `$(SPT_WARNINGS_AS_ERRORS)`,
which is `NO` unless a build says otherwise. The indirection is what keeps the
packages out of it: `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` given to `xcodebuild`
directly reaches every target, WhisperKit's and FluidAudio's included, which
Xcode builds with `-suppress-warnings` — and the compiler refuses the two
together. A package's warnings are not ours to fix, and they are never shown. Our own
package, `Packages/SpeechTextCore`, is the exception, and no build setting
reaches it — Xcode passes none of the project's into a package, and an
environment variable read by its manifest is no better, since SwiftPM caches the
evaluated manifest per user without the environment. So the Tests job builds it
first on its own, `swift build --package-path Packages/SpeechTextCore
-Xswiftc -warnings-as-errors` in a fresh scratch folder; in Xcode its warnings
show as warnings, as the app's do.
Warnings from other tools (`appintentsmetadataprocessor`'s "Metadata extraction
skipped", the linker) are left as warnings.

An ordinary build in Xcode, or `xcodebuild` without the flag, still treats a
warning as a warning, so a new Xcode that deprecates something does not stop
anyone working. To see what CI will say before you push:

```bash
xcodebuild test -project SpeechText/SpeechText.xcodeproj \
  -scheme SpeechText -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO SPT_WARNINGS_AS_ERRORS=YES
rm -rf /tmp/speechtextcore-build   # a stale build shows no warning for an unchanged file
swift build --package-path Packages/SpeechTextCore \
  --scratch-path /tmp/speechtextcore-build -Xswiftc -warnings-as-errors
```

(and the same with `build -scheme SpeechTextEvaluation`). A warning your change
causes is yours to fix. One that appears without your change — a newer Xcode on
the runner deprecating an API, or tightening a concurrency check — fails every
pull request at once; fix it in a pull request of its own if it is small, and
otherwise say so in your pull request rather than switching the flag off. Do not
silence a diagnostic by lowering `SWIFT_VERSION` or the package's language mode.

### Concurrency

Every target — the app, the tests, `SpeechTextLLM`, `SpeechTextEvaluation` and
`Packages/SpeechTextCore` — builds in the Swift 6 language mode, so a data race
the compiler can see is an error, not a warning. Isolation is written out on each
type, and none of the later opt-in defaults is turned on: no default main-actor
isolation, which would make the audio and socket types main-actor code, and no
`NonisolatedNonsendingByDefault` (Approachable Concurrency in Xcode's settings),
which would run every session's `finish()` on its caller's actor — the main one —
instead of off it. Xcode's templates switch both on for a new project; leave them off
here.

- **Main-actor types, with doors for other threads.** The engine, the sessions,
  History, the Debug Log's buffer and every window are `@MainActor`. What another
  thread must reach is `nonisolated` and says so: a session's `feed` runs on the
  audio thread and touches only its `let`s and the audio-thread state, its `finish()`
  runs off main and hops there for what it shares, and `dlog` may be called from
  anywhere.
- **A closure an API calls off main is written `@Sendable`.** In the Swift 6 mode a
  closure written inside main-actor code is taken for main-actor code unless its type
  says otherwise, and the runtime checks it: an audio tap, a recogniser's result
  handler, a network monitor's or a download's progress callback that ran on its own
  queue would stop the app there. So such closures are `@Sendable` (`{ @Sendable result,
  error in … }`), and so is every closure parameter of ours that is called off main.
- **A callback that comes on main says so.** A `NotificationCenter` observer on
  `.main`, a timer on the main run loop, an animation's completion, a deinit of a
  window: the closure is `@Sendable` in the SDK, and its body is wrapped in
  `MainActor.assumeIsolated`, which checks the claim.
- **Every `@unchecked Sendable` and `nonisolated(unsafe)` says why it is safe**, in a
  line beside it: the lock that guards each field, the queue that owns it, or that it
  is written once at launch before anything reads it (the registration boxes).
  `StreamingTranscribers.swift` keeps a field-to-guard map for each socket, and its
  lock order — `sendLock` before `lock`, never a send under `lock` — is a rule the
  compiler does not check.

<!-- ci-timings -->
**Run time on a hosted runner:** Tests took 6–14 minutes on `xcode-27` across the
first eight runs after the repository went public (2026-10-29, the package cache
restored), about 10 at the median; Checks and Swift lint take seconds. Do not
anchor on the self-hosted Mac's number: that build is warm and incremental (16 s
on 2026-09-22).

### The first run after going public

The repository went public on 2026-10-29, and the first pull requests after it
were watched rather than trusted. `macos-latest` turned out to carry no Xcode 27,
which is why the Mac jobs run on `xcode-27`. The list, kept for a repository that
moves the same way:

1. Every job's log names a GitHub-hosted runner, never `Vlad-DO-Laptop`, and
   Package's first step (the self-hosted refusal) is skipped, not run.
2. Tests: *Select Xcode 27.1* prints that version, *Cache the resolved
   packages* misses and its post step saves; the next run restores it. Put both
   runs' times under *Run time on a hosted runner* above.
3. Swift lint: `xcrun swift-format` exists in the Xcode that was selected.
4. Checks runs on Ubuntu and *Base branch* reads the labels.
5. A pull request that touches the packaging (`release.yml`'s `paths:`) gets an
   unsigned image from Package on `xcode-27` — the `dmgbuild` venv included.
6. Then the ruleset on `main` (*The ruleset on `main` is the gate* above).

The self-hosted Mac keeps the tag-triggered packaging in
[`release.yml`](../.github/workflows/release.yml), because that is where the
signing certificate lives and only someone who can push a tag can start it. That
workflow's pull-request trigger — the one that checks the packaging script still
works — is keyed on the event *and* the visibility, so on a public repository it
lands on `xcode-27` and never signs; the job's first step refuses outright
should a public repository's pull request reach the self-hosted runner anyway.


## Project layout

```
SpeechText/
  SpeechText/          the app: views, AppState, SpeechEngine, engine runtimes, stores
  SpeechTextTests/     unit tests
  SpeechText.xcodeproj
Packages/
  SpeechTextCore/      the app's logic, as a local Swift package (see Tests)
    Sources/SpeechTextCore/   settings, catalogues, transcribers, sessions, History, …
    Sources/ChatTemplates/    the local chat models' prompt formats
  LlamaBinary/         llama.cpp's prebuilt xcframework, pinned
docs/
  development.md       this file
  specs/               design documents for larger features
scripts/               rebuild, packaging, keychain profile, appcast, trace import
.githooks/             the sign-off and pre-commit hooks (see Hooks)
.github/workflows/     CI and the tag-triggered release
CLAUDE.md              full architecture reference
```

## Architecture

[`CLAUDE.md`](../CLAUDE.md) is the detailed architecture reference — every component, the recognition tiers, the recording phase machine, the settings keys. It is written for AI coding agents but it is the most complete description of the codebase and worth reading before any non-trivial change.

The short version:

- **`SpeechEngine`** owns the microphone and the recording lifecycle. State lives in one `phase` value.
- **`RecognitionSession`** is the tier abstraction — one session per recorded segment. Three implementations: Apple on-device, batch upload, and realtime streaming (which falls back to batch when the stream breaks).
- **`AppState`** orchestrates the overlay, tracks the previously focused app, and pastes the result back.
- **Services** (`PasteService`, `TextRefinementService`) are independent and testable.

## Style

Match the surrounding code. A few conventions the codebase holds to:

- Every source file opens with the two-line SPDX header (`SPDX-FileCopyrightText` / `SPDX-License-Identifier: GPL-3.0-or-later`).
- Comments explain *why*, not *what*. A measured constant gets a comment saying what it was measured against.
- Latency and quality constants live in `STTTuning`, not scattered across files.
- Use `dlog("Category", "message")` for diagnostics — it goes to both the in-app Debug Log window and `os.Logger`, under its own category (`log stream --predicate 'subsystem == "app.speech-text.SpeechText" AND category == "ElevenLabs"'`). Give it a level when the default, `.info`, is wrong: `dlog("Groq", "…", level: .error)`.
  - `.error` — a failure: an HTTP error, a socket that broke, a start that failed, a permission denied, an error caught and handled by falling back.
  - `.fault` — a state the code believes cannot happen. Sparingly.
  - `.notice` (the system log's *Default*) — degraded but carrying on: a slow main thread, a late shortcut, a fallback taken, a value reset. A `⚠` in the message is usually a notice.
  - `.debug` — anything said many times a dictation: every partial, every posted key event. The system log keeps these only for a `log stream --level debug` running at the time, and the Debug Log window keeps them only in a debug build or while its **Debug lines** switch is on (for the session; never stored), so they cannot push the failures out of its last 1000 entries.
  - `.info` — everything else: what the app is doing (phase changes, the paste target, a session started).

  The level never changes what a message may say: every entry is public in the system log, so a message holds counts and lengths, never the user's words (`scripts/check-log-privacy.sh`).
- No new third-party dependencies. The four there are each imported by one file per use — WhisperKit by `LocalWhisperRuntime.swift`, FluidAudio by `LocalParakeetRuntime.swift` and `VoiceActivityRuntime.swift`, Sparkle by `UpdateChecker.swift`, llama.cpp by `LocalLlamaRuntime.swift` (compiled into the service and the evaluation tool, not the app) — keep them there, out of `Packages/SpeechTextCore`, whose manifest declares no dependency and so cannot reach any of them. If you think you need another dependency, open an issue first.
