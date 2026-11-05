# SPEC: Localization — String Catalogs, AI translations, and the checks around them

- **Status:** Approved by the owner on 2026-11-03, with the answers in *Decided by the owner*. Revised on 2026-11-04 after review. No code yet.
- **Date:** 2026-11-04
- **Issues:** #73 (spec), then #74 (build), #75 (test) and #76 (ship), all part of #72 *Localization*
- **Base revision:** `2a7432c`; the code references were checked again at `ece1ed1`
- **Scope:**
  - **The app:** `Localizable.xcstrings` and `InfoPlist.xcstrings` in `SpeechText/SpeechText/`; every string the user reads, SwiftUI and AppKit, made localizable, with a `comment`; `knownRegions` in `project.pbxproj`.
  - **The package:** `defaultLocalization` and a processed `Localizable.xcstrings` resource in `Packages/SpeechTextCore/Package.swift`, and `String(localized:bundle:comment:)` in the files that hand words to the UI.
  - **CI and release:** checks in `ci.yml`, a completeness check in `release.yml`.
  - **Translations:** a scheduled job that keeps one translations pull request up to date, a glossary (`docs/translation-glossary.md`) and an issue template.
  - **Docs:** CONTRIBUTING.md › Language, once the UI is no longer English-only.
- **Does not touch:**
  - the built-in AI prompts (`PromptPresets`);
  - logs, `dlog` lines and anything else the user does not read;
  - the documentation, which stays in English.

## What it is

The UI is English-only. This spec makes it translatable, starts with two languages, and sets up the work so that contributors never have to translate: a pull request that adds UI text only has to get it into the string catalog, and the translations follow in a pull request of their own.

Most of the work is in the app's own code, not in the catalog. A large share of what the user reads does not reach a catalog today: `Text(someVariable)` (a rough grep finds about 150 such calls), AppKit strings, words the package hands to the UI, and plurals assembled from English fragments. *Build* starts with an inventory of all of it.

## Decided by the owner

| Date | Decision |
|---|---|
| 2026-11-03 | The first languages are Spanish (`es`) and Ukrainian (`uk`). More follow in the order people ask for them. |
| 2026-11-03 | Translations are made by an AI model and ship without a native-speaker review. A language may be turned on with AI translations alone. A wrong translation is reported in an issue and fixed in the next translations pull request. |
| 2026-11-03 | Contributors do not translate. After a merge, a scheduled job translates new and changed strings into every supported language and updates a separate pull request. It is reviewed and merged like any other; nothing merges itself. |
| 2026-11-03 | A release never ships with a missing translation: `release.yml` fails if any key lacks a value in a supported language. |

## How strings are written

### String Catalogs

- `SpeechText/SpeechText/Localizable.xcstrings` holds the app's strings.
- `SpeechText/SpeechText/InfoPlist.xcstrings` holds the permission prompts (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSAppleEventsUsageDescription`) and `NSHumanReadableCopyright`. Their English lives in `Info.plist` only; the duplicate `INFOPLIST_KEY_*` build settings for the first two are gone. The catalog repeats that English as each key's `en` value, beside the translations, and `scripts/check-infoplist-strings.sh` (CI, *Checks*) fails when the two differ or a key has no comment: xcodebuild does not sync this catalog either. Xcode compiles only the translations into `<lang>.lproj/InfoPlist.strings`; English comes from `Info.plist` itself.
- `Packages/SpeechTextCore/Sources/SpeechTextCore/Localizable.xcstrings` holds the package's strings (below).

### The English text is the key

SwiftUI's default, and the one that asks nothing of a contributor:

```swift
Text("Hold to talk", comment: "Settings › Shortcuts: the label of the hold mode")
```

The compiler already extracts these (`SWIFT_EMIT_LOC_STRINGS = YES`). When the English changes, the key changes: the new key has no translations, and the old entry is no longer used by the code. American English stays the source (AGENTS.md › Naming).

Semantic keys (`"settings.shortcuts.holdLabel"`) were considered and not chosen: every string would have to be added to the catalog by hand, and the code would no longer show what the user reads. They pay off with human translators keeping long-lived entries, which this project does not have.

### Every string has a comment

It says where the string appears and how much room it has. It is the only context the translator gets, so "Title" is not enough and "Home: the title of the empty state, one line in a narrow column" is.

### Strings the compiler does not find

Only literals passed to a SwiftUI initializer that takes a `LocalizedStringKey` are extracted. Everything else is written as `String(localized: "…", comment: "…")` (in the package, with `bundle: .module`), or passed as a `LocalizedStringResource`:

- **`Text(someVariable)`** with a `String` shows it verbatim and is never translated, for example `Text(title.uppercased())` in `MainPageKit.swift`. Each call either gets a localized value or, when the text is the user's own (a transcript, a prompt they wrote), stays verbatim on purpose, as `Text(verbatim:)`.
- **AppKit:** `NSAlert` text (`AppInstaller.swift`), menu bar items (`NSMenuItem(title:)` in `App.swift`) and anything else set as a plain `String`.
- **Words from SpeechTextCore:** the row words (`ModelRowWords`), the setup cards (`SetupCards`), Home's and History's summaries (`HomeSummary`, `HistorySummary`), the catalogs' descriptions, the error descriptions a transcriber or a client shows, and more. `Package.swift` gets `defaultLocalization: "en"` and declares the catalog as a resource, `resources: [.process("Localizable.xcstrings")]`, so that `Bundle.module` exists. This is Foundation, not SwiftUI, so the *Core imports* check is unaffected.
- **Case changes** on translated text take the locale: `.textCase(.uppercase)` in SwiftUI, or `uppercased(with: .current)`, never a bare `uppercased()`.

The inventory of these strings, in the app and in the package, is the first step of *build*, and it becomes the file list the CI check reads (see *Checks*).

### Plurals

One string per sentence, with the count interpolated as an `Int`:

```swift
Text("Show \(heavy.count) models too heavy for this Mac", comment: "…")
```

The catalog then holds plural variants of that one key, and each language fills the forms it has. Today several plurals are assembled from English fragments, for example `"\(n == 1 ? "model" : "models")"` in `SettingsEngines.swift` and `OnboardingScreens.swift`, `"\(words.count) \(… ? "word" : "words"), spelled exactly…"` in `PromptsView.swift`, and others in `UsageView.swift` and `SettingsView.swift`. Each fragment would become a key of its own, and no language with more than two forms can be built from them, so these are rewritten.

A count is not pre-formatted into a `String` before it is interpolated: `"Used \(HomeFormat.integer(count)) times"` gives the key a `%@`, which cannot vary by plural. Interpolating the `Int` itself gives `%lld`, which can, and SwiftUI formats it for the locale.

### What is not translated

- The product name, vendor and model names, model IDs and key names: `Text(verbatim:)` in code, or `shouldTranslate: false` in the catalog.
- **The built-in AI prompts (`PromptPresets`).** They are data the user edits and saves, and their text is read by the model, not by a person. Translating them would change how AI Rewrite behaves and leave saved copies in another language. Their names stay as they are for the same reason. This can be revisited as a decision of its own.

### State

A translated entry is marked `translated`. Xcode builds an entry in any state (`new`, `needs_review` and `translated` all compile into the `.strings` output, checked with `xcrun xcstringstool compile` on 2026-11-03), so `needs_review` would change nothing for the user. That an entry was machine-translated is recorded by the pull request that added it.

Entries the code no longer uses (Xcode marks them `extractionState: stale`) are not translated; they are removed in the pull request that stopped using them, which the catalog check below enforces. So a catalog never keeps dead translations.

## Checks

The supported languages are the ones in `knownRegions` other than `Base` and `en`. Every check and the translations job read them from there, so adding a language is one change.

| Where | What | How |
|---|---|---|
| CI, every pull request (*Tests*, which already builds the app) | The catalogs hold exactly the code's keys: nothing the code uses is missing, nothing it no longer uses is left. | `scripts/sync-strings.sh --check`: it syncs the test build's `.stringsdata` (what the compiler extracted from each file) into a copy of the catalog with `xcstringstool sync`, the step the IDE runs, and fails when that changes anything or leaves an entry stale. Settled in *build*: `xcodebuild` does not sync a catalog itself (Xcode 27.2), so the plain build-and-diff does not work, and the sync is more direct than comparing `-exportLocalizations` output. |
| CI, every pull request | Every entry has a `comment`. | A script over the catalogs. |
| CI, every pull request | The files in the inventory hand the UI localized strings. | A script with the list of those files, in the manner of `scripts/check-core-imports.sh`. |
| CI, every pull request, and the job before it pushes | Every translation keeps its source's placeholders (`%lld`, `%@`, positional forms) and its Markdown (links, emphasis) intact. | A script that compares the format specifiers and Markdown of each value with the English source. Valid JSON alone does not catch a dropped `%lld`. |
| CI | The package still builds and tests on its own, with its catalog. | `swift build` already runs in CI; it must compile the `.xcstrings` resource. See *Open* for `SpeechTextEvaluation`. |
| Code review | `Text(someString)` with a `String` variable, and UI text that bypasses the catalog. | Review, which catches what a script cannot. Advice, not a gate. |
| `release.yml` | Every entry has a value in every supported language, including every plural form that language has, except entries marked `shouldTranslate: false`. | A script over the catalogs, before packaging. It names the forms it requires per language, from CLDR: `es` one, many, other; `uk` one, few, many, other. |

A missing translation does not break the app: macOS falls back to the development language, English. The release check only makes sure a release never relies on that.

## The translations pull request

- **When:** on a schedule, at most once a day, and on `workflow_dispatch`, so a release does not have to wait for the schedule. Runs are serialized (`concurrency` with no parallel run).
- **Input:** the catalogs as they are on `main`: entries with no value, or no value for some plural form, in some supported language; and open issues labeled `translation`. The input is the state of the catalogs, not a list of merges, so a failed run needs no checkpoint: the next run sees the same gaps.
- **One pull request at a time:** the job works on one branch, `translations`. If its pull request is still open, the run rebases that branch on `main` and updates it; otherwise it starts the branch again from `main`. Two pull requests never edit the same catalogs.
- **Context:** the English text, its `comment`, and `docs/translation-glossary.md`, which fixes how the app's own terms are translated (dictation, AI Rewrite, Hold to talk, Record Window, …) so they read the same everywhere.
- **Output:** only `*.xcstrings` and the glossary. Before pushing, the job checks that no other file is in the diff, that every catalog is valid JSON, and the placeholder check above. Every commit carries a `Signed-off-by` trailer for the identity that makes it, as *DCO sign-off* requires of any commit.
- **The pull request:** titled *Translations for #N, #M*, listing the pull requests that added the strings, with a table of *key → one column per supported language* for review, closing reported issues with `Fixes #K`. Nothing to translate means no pull request.
- **Model and cost:** the model, where the job runs and the secret that holds its key are chosen in *build*, and the cost of a run is measured on the first `es` and `uk` pass, before the schedule is turned on.
- **Safety:**
  - **Input:** strings and comments come from other people's pull requests, so the job treats them as untrusted text and writes nothing but the catalogs and the glossary. It runs on GitHub-hosted runners only, never on `pull_request_target`, and opens its pull request with a GitHub App token, because a pull request opened with `GITHUB_TOKEN` would not run the required checks.
  - **Output:** a translation can carry injected text too, such as a link or an instruction that is not in the source. The placeholder and Markdown check catches a new link; the review table is read for the rest.

## Reporting a wrong translation

A new issue template, `.github/ISSUE_TEMPLATE/translation_error.yml`, labeled `translation`, asks for the language, where in the app, what it says, and what it should say (optional). A fix to a term also goes into the glossary.

## Stages

1. **Build (#74),** in small pull requests:
   1. the inventory: every string the user reads that does not reach a catalog today, in the app (`Text(someVariable)`, AppKit, case changes, plurals from fragments) and in the package;
   2. the app catalog, with those strings converted and a `comment` on every string;
   3. the package: `defaultLocalization`, the processed catalog resource, `bundle: .module`;
   4. `InfoPlist.xcstrings`;
   5. the CI checks.

   No language is turned on yet. Then the first `es` and `uk` translations, in one pull request made the same way the scheduled job will make them.
2. **Test (#75):** strings run longer in Spanish and Ukrainian than in English. Run the main windows, the overlay, the Record Window, Setup and Settings with the *Double-Length Pseudolanguage* scheme option, and in both languages.
3. **Ship (#76):** `knownRegions` gains `es` and `uk`; the release check, the issue template and the glossary land; the scheduled job is turned on, with its manual run mentioned in `docs/releasing.md`; CONTRIBUTING.md › Language no longer says the repository is written in the UI's language; a `CHANGELOG.md` entry.

## Open

- **`Bundle.module` in `SpeechTextEvaluation`.** `SpeechTextCore` is linked into the app, the tests and the tool. Once the package has resources, `Bundle.module` traps if the resource bundle is not found next to the binary. *Build* step 3 checks that the tool still runs, and copies the bundle or keeps the tool's code paths off localized strings if it does not.
