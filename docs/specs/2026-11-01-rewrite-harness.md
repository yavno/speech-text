# SPEC: A harness that measures AI Rewrite

- **Status:** Implemented 2026-11-01 (PR #133); baseline measured (see *Baseline*). This spec was written after the code, to record what was decided; the owner answered its questions the same day (see *Decided after the baseline*).
- **Date:** 2026-11-01
- **Issue:** #108, part of #102 *AI Rewrite, routed and measured*
- **Base revision:** `c34e88d`
- **Scope:** `SpeechTextEvaluation` (`RewriteEvaluation.swift`, new `RewriteChecks.swift`), `SpeechTextTests/Rewrite/rewrite-fixtures.json`, `scripts/evaluate-rewrite.sh`; in SpeechTextCore only `LLMConfiguration.makeChatClient(model:apiKey:)`, `ChatModelDescriptor.withReasoningEffort(_:)`, and `ChatRates.cost(_:)` plus `ChatUsage`'s cached and reasoning counts made public
- **Does not touch:** `TextRefinementService`'s prompts and parser, the presets, the app's behaviour, CI (the tool is built there, never run)

## What it is

AI Rewrite sends one large system prompt on every dictation. Two of its rules contradict each other in a code editor, and nothing measured the text that came out: the only earlier check (`--rewrite`, phase 0 of the built-in local LLM) scored which mode was picked, on local models, against one cloud reference.

The harness runs text scenarios through exactly what the app sends, on the cloud and local chat models, and holds every reply to checks. It gives a baseline for today's prompt that the cleaned prompt (#109) and the two-step prompt (#110) are compared with. How to run it is `docs/rewrite-evaluation.md`. This file is why it is built the way it is.

## Decisions

**D1 — The baseline is the app, unchanged.**
`current` sends:
- the built-in presets (never the user's);
- `buildSystemPrompt` / `buildEditSystemPrompt`;
- `userMessage` / `editUserMessage` with the fixture's context and Dictionary.

It reads the reply with `parse` and `polishedReply`, with the fixture's Dictionary. Each model keeps its catalogue switches, so `reasoning_effort: low` stays where the catalogue sends it.

Turning reasoning off is a variable for #110: `--reasoning-effort` exists so it can be measured, and it is never part of the baseline. Otherwise the "before" number would already contain a change.

**D2 — One client, shared with the app.**
The provider switch (endpoint, dialect) moved out of `LLMConfiguration.makeChatClient()` into the pure `makeChatClient(model:apiKey:)`. The app and the harness both call it. The old evaluation hard-coded Groq's URL and dialect; a copy would drift.

Keys come from the environment or `~/.config/speech-text/test-keys.env`, never from `APIKeyStore`: they may be other keys than the app's.

**D3 — Text checks apart from mode expectations.**
A fixture says two kinds of thing about a right reply.
- *Text checks* hold whatever the prompt:
  - the language;
  - whether rich Markdown or a `[placeholder]` may appear;
  - code;
  - what must survive and what must not;
  - length bounds;
  - no preamble, leaked marker, reasoning or wrapping quotes.
- *Mode expectations* name one prompt's presets:
  - `modes` for `current`;
  - `variantModes` for any other.

#104 renames and merges modes, and Translate becomes a modifier. If the two were one list, every mode check would break there, and the comparison across variants would have nothing stable to compare. The summary counts *text ✓* and *routed* in separate columns, and only the first compares variants.

**D4 — A variant is a pipeline, not a prompt pair.**
A variant turns a fixture into one or more requests and the replies into the text the app would paste. It returns:
- the text;
- the mode;
- the marker as written;
- every call it made, with its tokens, seconds and cost.

Two steps means two calls, possibly on two models, and its latency and cost are their sum. Only `current` exists today. #109 and #110 add cases to `RewriteEvaluation.Variant`; the checks do not change.

**D5 — A check must almost never fail a good answer.**
A noisy check makes every comparison meaningless, so:
- the strict checks are opt-in per fixture (`markdown`, `placeholders`, `noCode`, the length bounds, `allowsEmpty`);
- the global ones are narrow:
  - a preamble only when the input did not open with the same word;
  - quotes only when the input was not quoted;
  - Markdown only for headings, bold, tables and fences, never for `- ` or numbered lists or inline code;
  - placeholders only for brackets that are not links and not in the input;
- "nothing invented" is per fixture (`mustNotAppear`). New digits are not flagged, because «дванадцять тисяч» → «12 000» is right;
- anything fuzzy is left to the judge.

**D6 — The checks are checked.**
Fixtures carry `examples`: replies written by hand that the checks must pass or fail. `--self-check` runs them without asking a model, and the script stops on a mismatch before a run spends anything.

`--recheck` judges the stored replies of earlier runs again with today's checks and fixtures. A check corrected after a run, as three were after the first baseline, costs no second run. It also merges runs, a later run replacing the rows of the engines it holds.

**D7 — Where today's prompt contradicts itself, a fixture asserts the specific rule.**
In an editor, a terminal or an AI prompt field, an instruction is written down as the user's request, not carried out. This is the rule CLAUDE.md states, over the context rule's "editor or terminal → code or a command". The fixtures assert it (`ctx-terminal-instruction`, `uk-code-editor-instruction-is-content`), so the baseline shows the contradiction instead of hiding it.

**D8 — Judges are opt-in, any number of them, and declare their family.**
`--judge provider/model,…` names none, one or several judges (the owner's call: the choice of judges is free, 0–N). Each grades every reply from 1 to 5, says whether the reply did what was asked and kept the facts, and gives one sentence on what is wrong. Judging is off by default, as agreed for the Playground (#123).
- A judge tends to favour its own family. The summary gives the mean grade of every judge, and beside it the mean of the judges not of the engine's own family.
- The judges' cost is the run's and is shown in the header, not on the engine.
- `--recheck … --judge …` grades the stored replies of an earlier run, so a judge can be added without asking the engines again.

**D9 — Requests in parallel, judges after the engines.**
Each cloud engine has `--concurrency` requests in flight (4 unless given). A vendor's models run one after another, since its rate limit is per account. The vendors and this Mac run side by side, and a model on this Mac takes one request at a time on its one GPU. The judges grade once every engine is done, side by side, each with `--concurrency` requests in flight.

The first runs did this one row at a time: two judges graded each reply before the next was asked for. A reply took 1.4 s and a row 17 s, so 14 fixtures on six engines took most of an hour. Run as above, the same took four minutes.

A dropped connection, a server error or a 429 is retried after 5, 20, 40 and 60 s. A 429 that says the account has no credit (OpenAI's `insufficient_quota`) is not, since no wait changes it. A refusal or a rejected request is the model's answer. Latency counts only the attempt that was answered, and retries are counted apart. In the first run, a free Groq account's waits made GPT-OSS 20B look 5 s slow.

**D10 — Runs stay private; fixtures may not.**
A run may be made of real dictations (`SPEECHTEXT_REWRITE_FIXTURES`), so runs go to `SPEECHTEXT_RUNS`, outside the repository; the script refuses a folder inside it. The committed fixtures are synthetic.

**D12 — Clean and dirty fixtures, counted apart.**
A fixture marked `noise: dirty` is a transcript written the way a speech engine really writes one, after the owner's own History (2026-11-01). Its texts are written for the fixtures, and none is copied out of History. History showed:
- English terms heard in Cyrillic («сетінгс», «диктейшн», «ховер», «брю інстал»);
- misheard words («привір» for «перевір»);
- run-ons with no punctuation;
- a word cut in two;
- two-word fragments;
- English clauses inside Ukrainian;
- and above all, instructions to coding agents.

About three in four of its dictations went to T3 Code, Claude or a terminal. The summary gives *text ✓* for clean and dirty fixtures apart, since a model that reads typed text well may still fail on speech.

**D11 — The checks stay pure, apart from the tool.**
`RewriteChecks.swift` depends on nothing in `SpeechTextEvaluation`. The Playground (#121) moves it into `SpeechTextPlayground` unchanged; no module is made for it now.

## Fixtures

72 fixtures, 53 clean and 19 dirty; 26 of them English:
- 20 of the phase-0 fixtures;
- 21 clean ones for the contexts and requests #108 lists:
  - Mail, Gmail in a browser, Slack with formatting asked for, an editor on `README.md`, Terminal (a command dictated, an instruction), T3 Code with a Dictionary word that is also the app's name, ChatGPT, Notion in a browser;
  - stacked requests, Polish asked for, mixed Ukrainian and English, English that must stay English, headings asked for, spoken "new line";
  - an instruction quoted inside content, a question that must stay a question, hesitations alone, one word;
  - two more edits;
- 13 dirty Ukrainian ones (D12);
- 18 English ones, 12 clean and 6 dirty. They mirror the Ukrainian ones: an email, Mail, Slack, a commit message, an instruction to a coding agent, a question for Claude, Terminal, a list, a translation into Ukrainian, spoken formatting, two edits; homophones, a run-on, product names misheard, false starts, a cut word, a fragment.

The `uk` language check asks for 30 % Cyrillic letters, not a majority. An instruction to a coding agent keeps Settings, Control and a path in Latin, and still is Ukrainian.

The language check tells Cyrillic from Latin and nothing finer, and no fixture or check holds words of any other language for it (the owner's call, 2026-11-01). Anything finer is the judge's.

## Baseline

Today's prompt, 42 fixtures × 3 runs, M1 Pro, 2026-11-01, graded by two judges: Claude Sonnet 5.5 and GPT-6 Sol. The run is kept outside the repository.

| Engine | text ✓ | routed | marker abbreviated / none | median s | $ per 1k | Sonnet 5.5 | GPT-6 Sol |
|---|---|---|---|---|---|---|---|
| Claude Haiku 5.5 | 123/126 | 118/121 | 5 / 0 | 1.0 | 0.16 | 4.34† | 4.83 |
| Claude Sonnet 5.5 | 116/126 | 126/126 | 0 / 0 | 1.5 | 3.19 | 4.47† | 4.74 |
| GPT-6 Luna | 116/126 | 114/119 | 6 / 1 | 1.1 | 0.11 | 4.41 | 4.91† |
| Gemma 4 12B (this Mac) | 117/126 | 120/123 | 3 / 0 | 2.4 | 0 | 4.23 | 4.63 |
| Groq GPT-OSS 120B | 102/126 | 101/112 | 14 / 0 | 0.3 | 0.14 | 3.85 | 4.51† |
| Groq GPT-OSS 20B | 100/126 | 104/107 | 5 / 7 | 0.4 | 0.07 | 3.81 | 4.34† |

† graded by a judge of its own family.

The judges keep different scales: GPT-6 Sol grades every engine 0.3–0.7 higher, so a mean across judges would rank an engine by who graded it, and the summary gives each judge's mean apart, out of 10 in whole points (the owner's call). A judge's mean moves by a few hundredths from run to run, and a finer figure would rank engines by that noise. Each judge puts a model of its own family first (Sonnet 5.5 itself, GPT-6 Sol GPT-6 Luna), which is the bias D8 expects. They agree on the rest of the order: GPT-OSS last, Gemma in the middle.

### Every fixture

The dirty and English fixtures were added on the same day. Text ✓ for all of them:

| Engine | all | clean | dirty | English | median s | Sonnet 5.5 | GPT-6 Sol |
|---|---|---|---|---|---|---|---|
| Claude Haiku 5.5 | 200/216 | 151/159 | 49/57 | 51/57 | 0.9 | 8† | 10 |
| Gemma 4 12B (this Mac) | 195/216 | 147/159 | 48/57 | 54/57 | 2.3 | 8 | 9 |
| Claude Sonnet 5.5 | 193/216 | 146/159 | 47/57 | 51/57 | 1.6 | 9† | 9 |
| Groq GPT-OSS 120B | 166/216 | 129/159 | 37/57 | 46/57 | 0.4 | 7 | 9† |
| Groq GPT-OSS 20B | 138/197* | 122/158 | 16/39 | 27/38 | 0.4 | 7 | 9† |
| GPT-6 Luna | 136/216* | 115/159 | 21/57 | 3/57 | 1.1 | 9 | 10† |

\* Incomplete, because two accounts ran out mid-run:
- **OpenAI** ran out of credit, so GPT-6 Luna's English rows and some of its dirty ones failed, and GPT-6 Sol graded only the earlier rows.
- **Groq**'s free tier allows GPT-OSS 20B 200,000 tokens a day, which this day's runs spent.

Neither error is retried any more (D9). Both engines need a rerun once the accounts allow it.

Every engine does worse on dirty text, GPT-OSS the most: it answers a Ukrainian instruction to an agent in English. What the dirty fixtures add:
- English terms said in English get translated («outdated» → «застарів»);
- a reply grows an instruction of its own («Знайди причину…»);
- Gemma leaves «привір» unfixed.

On English, Gemma does best. What fails there:
- An English instruction in Terminal comes back as a command, as the Ukrainian one does: 12 of 15 replies.
- "make it more formal" on a chat message comes back as a letter with `Dear [Name]` put in place of the selection.
- GPT-OSS 120B leaves "speech text" unfixed though the Dictionary has SpeechText.

What fails most:
- An instruction dictated into Terminal comes back as a `find` command from every model: 17 of 18 replies.
- An instruction in an editor or an AI prompt field comes back translated into English: 15 and 9 of 18. Nothing is carried out, but the language changes. The judge rates it 4.6, so it does not see the translation as a fault.
- GPT-OSS answers Ukrainian in English and drops words («завтра»).
- GPT-OSS 120B abbreviates preset names in 14 markers.
- GPT-6 Luna translates embedded English terms («demo» → «демо»).

## Decided after the baseline

The owner's answers, 2026-11-01:

1. **An instruction stays in the language it was dictated in**, in an editor and an AI prompt field too. Nothing forces another language; a user who wants English prompts says so in their own prompts. The fixtures already assert it (`language: uk`), and #104 / #109 write the rule so. The translation into English the baseline shows (15 and 9 of 18) is therefore a failure to fix, not a style.
2. **An empty reply to hesitations alone is right.** `allowsEmpty` stays on `too-short-garbage`. The app then pastes the transcript, as for any empty reply.
3. **Groq's free limits are accepted.** Retries are counted apart and do not reach the latency.
4. **A second judge of another family.** GPT-6 Sol grades the baseline beside Claude Sonnet 5.5, added with `--recheck --judge` without asking the engines again, so every engine has a judge outside its family (D8).

## Open questions

1. **Fixtures from real dictations.** Every fixture is synthetic text written by us. Is a private set drawn from History needed?
