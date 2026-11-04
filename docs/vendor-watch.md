# Vendor watch

When a vendor switches a model off, our release moves users off it. That only works if we
know weeks in advance, from the vendor rather than from a "Transcription failed" in
someone's History. Two things keep us informed. One is a script that compares the
catalogues with each vendor's own API, looks each model up on the vendor's deprecation
page, and shows what is new on its changelog. The other is a weekly workflow that runs the
script and files an issue when something changed. Neither uses a language model: what the
script finds is decided by code, and what a changelog line means is left to a person.

The catalogues give each model a lifecycle state: `current`, `superseded`, `deprecated` or
`retired`, with the vendor's shutdown date once one is announced. A retired model stays in
the catalogue for History's sake and is removed **six months after its shutdown**. Its name
and price go to the permanent archive. The export reads each descriptor's `ModelLifecycle`
on the day it runs: *retired* is a `deprecated` model past its shutdown date, as the app
shows it, and an archived one is retired with no date.

## The script

```bash
SPEECHTEXT_VENDOR_WATCH=<folder outside the repository> scripts/check-vendor-models.sh --out report.md [--json findings.json]
```

- **The catalogues.** The script builds `SpeechTextEvaluation` and runs
  `--export-catalogue`, which writes `sttModelCatalog` and `chatModelCatalog` as JSON
  (`CatalogueExport`, pinned by `CatalogueExportTests`). The script keeps no model list of
  its own. `--catalogue <file>` reuses an export and skips the build.
- **Keys.** The script reads `~/.config/speech-text/test-keys.env` (`OPENAI_API_KEY`,
  `GROQ_API_KEY`, `ELEVENLABS_API_KEY`, `ANTHROPIC_API_KEY`), or the environment. It makes
  every request from Python's `urllib`, so a key never appears on a command line or in the
  report.
- **Snapshots.** Each run keeps the vendors' lists in `$SPEECHTEXT_VENDOR_WATCH/snapshots/`,
  and the last two copies of each text page in `snapshots/pages/`. The next run uses them
  to tell which IDs and which lines are new. Without the variable, nothing can be called
  new.
- **GitHub.** The releases API allows an address 60 requests an hour without a token; with
  `GITHUB_TOKEN` in the environment, the requests are the token's.
- **Findings.** `--json <file>` writes what the report says needs acting on, one entry per
  model, package or source: a `key` (`groq/qwen/qwen3.8-27b`, `package/FluidInference/FluidAudio`,
  `languages/<source>`, `prices`) to match it with an issue, its `kind`, whether it
  fails the release rule (`gate`), whether it comes from a per-account list and the page that
  confirms it (`per_account`, `confirmed_by`), and a line of Markdown.
- **CI never runs it:** it needs keys and the network. The vendor watch workflow does
  (below).

### Where each list comes from

| Vendor | Request | What it gives |
|---|---|---|
| OpenAI | `GET /v1/models` | every model the key can use, each with a **`shutdown_date`** once one is announced |
| Groq | `GET /openai/v1/models` | every model, its `active` flag, and **prices** for chat models (`pricing`, dollars per token) |
| Anthropic | `GET /v1/models` (paged) | every model ID; no dates, no prices |
| ElevenLabs | `POST /v1/speech-to-text` and the realtime WebSocket, both with an unknown `model_id` | the validation error names every model the endpoint accepts ("Available models: …", "Supported models: …"). Nothing is transcribed or billed. `GET /v1/models` needs the `models_read` permission, which a speech key often lacks, and lists the voice models besides |
| FluidAudio, argmax-oss-swift | GitHub's releases API | releases newer than the version `Package.resolved` pins |
| Hugging Face | `/api/models/<repo>`, `/api/models?author=…` | each local model's folder or files still in its repository, the repository's last change, and new repositories by FluidInference and argmaxinc |
| Deprecation pages | the Markdown version (`<page>.md`) of OpenAI's, Groq's and Anthropic's deprecation page | for each catalogue model, whether a table lists it as deprecated or retired, the shutdown date and the replacement; at Anthropic, an Active model's earliest retirement date ("Not sooner than …") |
| Text pages | the Markdown version of OpenAI's changelog and speech-to-text guide, Groq's changelog and models page, ElevenLabs' changelog and models page | the lines not there at the stored copy that name a catalogue model or say deprecated, shutdown, retire, sunset, speech-to-text, transcription, Scribe or Whisper |
| Language lists | the `source` of each published list in the export (`languages`): Whisper's `tokenizer.py` (its `LANGUAGES` table), a Hugging Face model card's `language` metadata (each Parakeet build's FluidInference repository), an ElevenLabs page's Markdown version (`<page>.md`, ISO 639-3 codes mapped to 639-1) | the languages the source lists now, compared with the catalogue's codes |

All of these were checked against real replies on 2026-10-16, the language sources on
2026-10-17, the vendors' pages on 2026-11-03. Anthropic's list may name
an alias such as `claude-haiku-4-5` only by its dated snapshot
(`claude-haiku-4-5-20251001`), so an alias counts as served when its snapshot is.

The OpenAI and Groq lists are **per account**. A model missing from them means it is not
served *to this key*, which is not necessarily a retirement. The vendor's deprecation page
decides: the report says whether the page lists the model, and calls it unconfirmed when it
does not.

A deprecation page is read by its tables: the column names the script knows (*model*,
*shutdown date* or *retirement date*, *replacement*, *current state*), whatever the table's
place on the page. A page where it finds no such table, or such a table with no rows, has
changed shape, and its vendor is **not checked** (exit 3) until the reader follows it;
`scripts/vendor-watch/test_check.py` holds a short copy of each page's tables. A text page
that cannot be read is only noted: it never fails a run.

### The report

1. **Not checked.** A vendor with no key, no network or an error reply, and a deprecation
   page that did not answer or could not be read. Its models get no alarm, and the run is
   not an all-clear.
2. **Gone.** A catalogue model, or a realtime model's upload twin, that the vendor no
   longer serves, with whether its deprecation page lists it. A model already
   `deprecated` or `retired` is listed apart, as expected.
3. **Shutdown announced.** The vendor's API gives a shutdown date (OpenAI) or marks the
   model inactive (Groq) while the catalogue still calls it current.
4. **On the vendor's deprecation page.** A `current` or `superseded` model the page lists
   as deprecated or retired, with its date and replacement; a `deprecated` one whose date
   on the page differs from the catalogue's; an Anthropic model still Active past its
   earliest retirement date. The warning to deprecate it, never part of the release rule.
5. **Past their shutdown.** A `retired` model whose six months are over is moved to the
   archive in the next release (the export calls a deprecated model retired on its own
   once the shutdown date has passed).
6. **Price drift.** Only where the API states prices, which today means Groq's chat
   models. Every other price is checked by hand (docs/prices.md).
7. **Prices checked by hand.** How many days ago, in bold past 60: check them again.
8. **Language lists.** Each published list the catalogue cites, read again from its
   source: languages added or dropped there change the rows' count and their "No …"
   badges, so the codes and the date in ModelLanguages.swift (or the model's entry) are
   updated. A source the script has no reader for is listed to read by hand, in bold once
   its check is older than 180 days. Models whose vendor publishes no list (OpenAI) are
   named; the speech-to-text guide's new lines show whether it now does. Never part of the
   release rule.
9. **New at the vendor.** Relevant IDs that were not served at the previous snapshot.
   Voice, image and embedding models and dated snapshots of an alias are left out. Every
   relevant ID missing from the catalogue is listed below this, folded.
10. **New lines on the vendors' pages.** Per text page, its new lines that name a catalogue
    model (in bold) or say a watched word, under the headings they stand in, 30 at most.
    The first run stores each page as the baseline.
11. **Local models.** Newer package releases, each model's repository and files, and new
   speech repositories.

Exit status: **0** nothing blocks a release, **1** the release rule fails (Gone and Local
models: a model the vendor no longer serves that is not deprecated, or a local model's
files gone from its repository), **2** the export could not be built, **3** some vendor,
or its deprecation page, was not checked.

## The vendors' pages

APIs do not say *when* a model goes or *what replaces it*; the deprecation pages do, and the
script reads them (`DEPRECATION_PAGES` in `check.py`). What a changelog line means is not
decided by the script: it shows the new lines (`TEXT_PAGES`), and a person reads them.

| Vendor | Page | Read as |
|---|---|---|
| OpenAI | https://developers.openai.com/api/docs/deprecations | tables |
| Groq | https://console.groq.com/docs/deprecations | tables |
| Anthropic | https://platform.claude.com/docs/en/about-claude/model-deprecations | tables |
| OpenAI | https://developers.openai.com/api/docs/changelog | new lines |
| OpenAI | https://developers.openai.com/api/docs/guides/speech-to-text (whether it now publishes a language list for its gpt transcription models) | new lines |
| Groq | https://console.groq.com/docs/changelog | new lines |
| Groq | https://console.groq.com/docs/models (preview models can be withdrawn without a deprecation entry) | new lines |
| ElevenLabs | https://elevenlabs.io/docs/changelog | new lines |
| ElevenLabs | https://elevenlabs.io/docs/overview/models | new lines |
| FluidAudio | https://github.com/FluidInference/FluidAudio/releases | releases API |
| WhisperKit | https://github.com/argmaxinc/argmax-oss-swift/releases | releases API |

## The workflow

`.github/workflows/vendor-watch.yml` runs the script on GitHub's machines every Monday
(06:17 UTC), and by hand from `main` (`gh workflow run vendor-watch.yml --ref main`).

- **Check** (a hosted Mac) builds `SpeechTextEvaluation` and exports the catalogues on the
  day, takes the newest `vendor-watch-snapshots` artifact any run on `main` left, runs the
  script, and puts the report in the run's summary. It keeps the report, the findings and
  the export (`vendor-watch-report`) and the snapshots for the next run, 90 days each. The
  job is red when the script exits anything but 0.
- **File issues** (Linux) files the findings with `scripts/vendor-watch/file_issues.py`:
  one `model-lifecycle` issue per model, package or language source, found again by a
  marker in its body. An open issue gets a comment only when its finding changed; a closed
  one stays closed when the same finding comes back, and for good with the `wontfix` label
  or a comment saying `vendor-watch:ignore`. A model gone from a per-account list and not
  on the deprecation page is filed as *Unconfirmed*. New Hugging Face repositories are only
  listed in the summary, and no run opens more than ten issues.
- **Keys.** The secrets `VENDOR_WATCH_OPENAI_API_KEY`, `VENDOR_WATCH_GROQ_API_KEY`,
  `VENDOR_WATCH_ANTHROPIC_API_KEY` and `VENDOR_WATCH_ELEVENLABS_API_KEY` belong to the
  `vendor-watch` environment, which only `main` may use. The script only reads model lists;
  each key is a separate one for this, restricted where the vendor allows it (OpenAI:
  Models read; ElevenLabs: speech-to-text), under a spending limit. Only the Check job
  sees them; File issues holds no key, and Check cannot write to the repository. Nothing
  runs on a pull request or on a self-hosted machine.
- **Releases.** A tag is released only after a green Check in the latest run on `main`,
  at most seven days old (`release.yml`'s *Vendor watch is green*; docs/releasing.md).
  GitHub turns a public repository's schedule off after 60 days with no activity: the
  gate then stops the next tag instead of releasing on old results.
- **Reading a run.** The report is the run's summary; the issues it filed or commented on
  are listed under it. The lines new on the vendors' pages are not filed unless they name
  a catalogue model with a lifecycle word: someone reads them each week.
