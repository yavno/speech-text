# SPEC: Localization — String Catalogs, AI translations, and the checks around them

- **Status:** Approved by the owner on 2026-11-03, with the answers in *Decided by the owner*. No code yet.
- **Date:** 2026-11-04
- **Issues:** #73 (spec), then #74 (build), #75 (test) and #76 (ship), all part of #72 *Localization*
- **Base revision:** `2a7432c`
- **Scope:**
  - **The app:** `Localizable.xcstrings` and `InfoPlist.xcstrings` in `SpeechText/SpeechText/`, a `comment` on every UI string, `knownRegions` in `project.pbxproj`.
  - **The package:** `defaultLocalization` in `Packages/SpeechTextCore/Package.swift`, a catalog of its own, and `String(localized:bundle:comment:)` in the files that hand words to the UI.
  - **CI and release:** checks in `ci.yml`, a completeness check in `release.yml`.
  - **Translations:** a scheduled job that opens a translations pull request, a glossary (`docs/translation-glossary.md`) and an issue template.
- **Does not touch:**
  - the built-in AI prompts (`PromptPresets`);
  - logs, `dlog` lines and anything else the user does not read;
  - the documentation, which stays in English (CONTRIBUTING.md › Language).

## What it is

The UI is English-only. This spec makes it translatable, starts with two languages, and sets up the work so that contributors never have to translate: a pull request that adds UI text only has to get it into the string catalog, and the translations follow in a pull request of their own.

## Decided by the owner

| Date | Decision |
|---|---|
| 2026-11-03 | The first languages are Spanish (`es`) and Ukrainian (`uk`). More follow in the order people ask for them. |
| 2026-11-03 | Translations are made by an AI model and ship without a native-speaker review. A language may be turned on with AI translations alone. A wrong translation is reported in an issue and fixed in the next translations pull request. |
| 2026-11-03 | Contributors do not translate. After a merge, a scheduled job translates new and changed strings into every supported language and opens a separate pull request. It is reviewed and merged like any other; nothing merges itself. |
| 2026-11-03 | A release never ships with a missing translation: `release.yml` fails if any key lacks a value in a supported language. |

## How strings are written

### String Catalogs

- `SpeechText/SpeechText/Localizable.xcstrings` holds the app's strings.
- `SpeechText/SpeechText/InfoPlist.xcstrings` holds the permission prompts: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` and `NSAppleEventsUsageDescription`. Today the last two are set both in `Info.plist` and as `INFOPLIST_KEY_*` build settings; *build* keeps one of them.
- `Packages/SpeechTextCore/Sources/SpeechTextCore/Localizable.xcstrings` holds the package's strings (below).

### The English text is the key

SwiftUI's default, and the one that asks nothing of a contributor:

```swift
Text("Hold to talk", comment: "Settings › Shortcuts: the label of the hold mode")
```

The compiler already extracts these (`SWIFT_EMIT_LOC_STRINGS = YES`). When the English changes, the key changes: the old entry goes *stale* and the next translations pull request translates the new one. American English stays the source (AGENTS.md › Naming).

Semantic keys (`"settings.shortcuts.holdLabel"`) were considered and not chosen: every string would have to be added to the catalog by hand, and the code would no longer show what the user reads. They pay off with human translators keeping long-lived entries, which this project does not have.

### Every string has a comment

It says where the string appears and how much room it has. It is the only context the translator gets, so "Title" is not enough and "Home: the title of the empty state, one line in a narrow column" is.

### Words from SpeechTextCore

The package hands words to the UI as plain `String`s, which the compiler does not extract: the row words (`ModelRowWords`), the setup cards (`SetupCards`), Home's and History's summaries (`HomeSummary`, `HistorySummary`), the catalogs' descriptions, error descriptions a transcriber or a client shows, and more. *Build* starts with an inventory of every package string that reaches the UI, and those strings are written as:

```swift
String(localized: "Not pasted", bundle: .module, comment: "History: a record whose text was not pasted")
```

with `defaultLocalization: "en"` in `Package.swift`. This is Foundation, not SwiftUI, so the *Core imports* check is unaffected. The inventory also becomes the list the CI check reads (see *Checks*).

### Plurals

A string with a count is written with interpolation (`"\(count) words"`), so the catalog can hold its plural variants. Each language has its own set of forms: Ukrainian has four (one, few, many, other), Spanish fewer. The translations fill every form the language has.

### What is not translated

- The product name, vendor and model names, model IDs and key names: `Text(verbatim:)` in code, or `shouldTranslate: false` in the catalog.
- **The built-in AI prompts (`PromptPresets`).** They are data the user edits and saves, and their text is read by the model, not by a person. Translating them would change how AI Rewrite behaves and leave saved copies in another language. Their names stay as they are for the same reason. This can be revisited as a decision of its own.

### State

A translated entry is marked `translated`. Xcode builds an entry in any state (`new`, `needs_review` and `translated` all compile into the `.strings` output, checked with `xcrun xcstringstool compile` on 2026-11-03), so `needs_review` would change nothing for the user. That an entry was machine-translated is recorded by the pull request that added it.

## Checks

| Where | What | How |
|---|---|---|
| CI, every pull request | The catalogs match the code: a string the code uses is in its catalog. | Build, then `git diff --exit-code -- '*.xcstrings'`: a build that changes a catalog means the catalog was not committed. If `xcodebuild` does not sync catalogs the way Xcode does, compare the keys from `xcodebuild -exportLocalizations` with the catalogs instead. To be found out during *build*. |
| CI, every pull request | Every new entry has a `comment`. | A script over the catalogs. |
| CI, every pull request | The package files in the inventory hand the UI localized strings. | A script with the list of those files, in the manner of `scripts/check-core-imports.sh`. |
| Code review | `Text(someString)` with a `String` variable (shown verbatim, never translated), and UI text that bypasses the catalog. | Review, which catches what a script cannot. Advice, not a gate. |
| `release.yml` | Every entry has a value in every language in `knownRegions`, including every plural form, except entries marked `shouldTranslate: false`. | A script over the catalogs, before packaging. |

A missing translation does not break the app: macOS falls back to the development language, English. The release check only makes sure a release never relies on that.

## The translations pull request

- **When:** on a schedule, at most once a day, covering the pull requests merged since the last run.
- **Input:** catalog entries that have no value or a `stale` value in some language, and open issues labeled `translation`.
- **Context:** the English text, its `comment`, and `docs/translation-glossary.md`, which fixes how the app's own terms are translated (dictation, AI Rewrite, Hold to talk, Record Window, …) so they read the same everywhere.
- **Output:** only `*.xcstrings` and the glossary. Before pushing, the job checks that no other file is in the diff and that every catalog is valid JSON.
- **The pull request:** titled *Translations for #N, #M*, listing the source pull requests, with a table of *key → es → uk* for review, closing reported issues with `Fixes #K`. Nothing to translate means no pull request.
- **Safety:** strings and comments come from other people's pull requests, so the job treats them as untrusted text and writes nothing but the catalogs and the glossary. It runs on GitHub-hosted runners only, never on `pull_request_target`, and opens its pull request with a GitHub App token, because a pull request opened with `GITHUB_TOKEN` would not run the required checks.

## Reporting a wrong translation

A new issue template, `.github/ISSUE_TEMPLATE/translation_error.yml`, labeled `translation`, asks for the language, where in the app, what it says, and what it should say (optional). A fix to a term also goes into the glossary.

## Stages

1. **Build (#74),** in small pull requests:
   1. the app catalog, with a `comment` on every existing string;
   2. the package: the inventory, `defaultLocalization`, `bundle: .module`;
   3. `InfoPlist.xcstrings`;
   4. the CI checks.

   No language is turned on yet. Then the first `es` and `uk` translations, in one pull request made the same way the scheduled job will make them.
2. **Test (#75):** strings run longer in Spanish and Ukrainian than in English. Run the main windows, the overlay, the Record Window, Setup and Settings with the *Double-Length Pseudolanguage* scheme option, and in both languages.
3. **Ship (#76):** `knownRegions` gains `es` and `uk`; the release check, the issue template and the glossary land; the scheduled job is turned on; a `CHANGELOG.md` entry.

## Open

- Whether `xcodebuild` on CI syncs String Catalogs the way Xcode does. It decides how the first CI check is written; to be found out during *build*.
