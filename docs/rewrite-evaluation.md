# Measuring AI Rewrite

AI Rewrite's prompt is changed only against a measurement. `scripts/evaluate-rewrite.sh` runs the rewrite fixtures through the app's own prompt, client and parser on the chat models, holds every reply to a set of text checks, and writes a run folder with a summary table. Every prompt change (#110, #106) is compared with the prompt it replaces.

```bash
SPEECHTEXT_RUNS=<runs-dir> SPEECHTEXT_LLM_MODELS=<folder of GGUF files> \
  scripts/evaluate-rewrite.sh --repeat 3 --judge anthropic/claude-sonnet-5-5,openai/gpt-6-sol
```

- **Runs stay outside the repository** (`SPEECHTEXT_RUNS`; the script refuses a folder inside it): a fixtures file may be made of real dictations (`SPEECHTEXT_REWRITE_FIXTURES`).
- **Keys** come from `GROQ_API_KEY`, `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`, or else from `~/.config/speech-text/test-keys.env`. They are never read from the app's settings. A model without its key gets a `no key` row.
- **Engines** default to the six of #114: Groq GPT-OSS 120B and 20B, Claude Sonnet 5.5 and Haiku 5.5, GPT-6 Luna, and Gemma 4 12B on this Mac. `--engines provider/model,…` picks others: `groq/…`, `anthropic/…`, `openai/…`, `local/<catalogue id>`. Each cloud engine has `--concurrency` requests in flight (4 unless given), a vendor's models one after another, the vendors and this Mac side by side; the judges grade once the engines are done.
- **The run** writes `rewrite-summary.md` (one row per engine, then every reply) and `rewrite-results.json`. It costs a dollar or two with two judges, and takes about ten minutes at `--repeat 3`.

Why it is built this way, and the baseline: `docs/specs/2026-11-01-rewrite-harness.md`. The tool is `SpeechTextEvaluation --rewrite` (SpeechText/SpeechTextEvaluation/RewriteEvaluation.swift). It is built by CI and never run there.

## What is sent

A *variant* turns a fixture into requests, and a reply into the text the app would paste. `2026-11`, the default, is exactly what the app sends (#109, `RewriteModes`):

- the three built-in modes, Clean-up, Message and Structured, never the user's, with the fixture's own `presets` beside them;
- `RewriteModes.request` / `buildEditSystemPrompt` and `userMessage`, with the fixture's context and Dictionary;
- in an editor, a terminal or an AI's field, Clean-up alone, chosen by code and sent with no marker, and in a terminal with the rule its `terminalFocus` picks (a command at a shell prompt; words in a program; words unless a command is named where it is `unknown` or absent); with `presets`, Clean-up and those, picked by the model. The summary counts the rows code decided apart from the routing (`+n by code`);
- the client `LLMConfiguration.makeChatClient(model:apiKey:)` builds for the app, with each model's catalogue switches;
- the reply read as the app reads it, then `polishedReply` with the fixture's Dictionary.

`current` is the baseline it was held to: what the app sent until #109, one routing prompt (`buildSystemPrompt`) over the six built-ins of October 2026 (`PromptPresetStore.october2026`), the edits' prompt over them too. Its name is older than the variant after it and stays, since the fixtures' `modes` and every run kept are keyed to it.

`--reasoning-effort omit|<value>` overrides a model's reasoning switch. It is a measurement for the next prompt, not the baseline. A new way of prompting is a new case of `RewriteEvaluation.Variant`, judged by the same checks.

## Fixtures

`SpeechText/SpeechTextTests/Rewrite/rewrite-fixtures.json`, generated text. Each fixture has:

- **What was said:** `transcript`, or for the Edit shortcut (`"kind": "edit"`) a `selection` and an optional `instruction`.
- **How clean:** `noise` — `dirty` for a transcript written the way a speech engine really writes one (misheard and transliterated words, no punctuation, a word cut in two), `clean` (the default) for text as a person types it. The summary counts the two apart.
- **Where:** `context` (app, bundle ID, window, field, and in a terminal `terminalFocus`) and `vocabulary` (the Dictionary's words).
- **What a right reply looks like**, in two kinds kept apart:
  - **Text checks**, which hold whatever the prompt:
    - `language`: `uk`, `any`, or a language written in Latin script;
    - `mustKeep` / `mustNotAppear`;
    - `markdown` (headings, bold, tables or fences allowed; lists always are);
    - `placeholders` (a `[name]` gap allowed);
    - `noCode`;
    - `minLengthRatio` / `maxLengthRatio`;
    - and, always: no preamble, no leaked marker, no reasoning, not wrapped in quotes.
  - **Modes**: `modes` for the `current` baseline (the first is the expected one), `variantModes` for another set of modes, since a variant may rename or merge them. `variantModes["2026-11"]` holds the three modes the app has (Clean-up, Message, Structured), Clean-up alone in an editor, a terminal or an AI's field, and the fixture's own `presets` by name.
  - **The route**, for the variants that pick a mode and its modifiers first: `askedLanguage`, an ISO 639-1 code (absent when the dictation asks for no language), and `format`, the formats a right answer may pick (`plain`, `list`, `markdown`; absent means plain). An edit is not routed and has neither.
- **The user's own prompts:** `presets` (name, when to use, instructions), for a variant that sends them beside the built-ins. `current` sends its built-ins alone, and an edit is sent the built-ins alone under either variant, where the app's Edit prompt lists the user's prompts too.
- **Examples:** `examples`, replies written by hand that the checks must pass or fail.

`--self-check` runs the checks on every example, holds every routing expectation to what a router can answer, and asks no model. The script runs it first and stops on a mismatch.

A check must almost never fail a good answer, so the strict ones are opt-in per fixture, and anything fuzzy is left to the judge. Where today's prompt contradicts itself, a fixture asserts the behaviour the specific rule asks for. In a program in a terminal, an instruction is written down, not turned into a command; where the focus is `unknown`, the same unless a command is asked for by name; at a shell prompt, it becomes the command.

## The judge

`--judge provider/model,…` asks other models — none, one or several — to grade every reply from 1 to 5, with whether it did what was asked and kept the facts, and one sentence on what is wrong. It is off unless asked for. The summary gives each judge's mean out of 10, in whole points — a judge's mean moves by a few hundredths from run to run, and a finer figure would rank engines by that — and each on its own scale, since judges grade differently; † marks a judge of the engine's own family, which tends to favour it. The judges' cost is the run's, shown in the header, not the engine's. `--recheck <fixtures> --runs <dir> --judge … <results.json>` adds judges to a run already made, asking the engines nothing.

## Reading the summary

| Column | What it counts |
|---|---|
| text ✓ | rows that passed every text check |
| clean / dirty | the same, for clean and for dirty fixtures |
| routed | rows whose mode is one the fixture allows for this variant |
| marker abbreviated / none | a `<<mode:…>>` that named no preset (`Technical` for the baseline's `Technical / Prompt`) / no marker at all |
| failures | the checks that failed, by kind |
| $ per 1k | list-price cost of 1,000 dictations like these |
| judge | each judge's mean grade out of 10, in whole points; † a judge of the engine's own family |
