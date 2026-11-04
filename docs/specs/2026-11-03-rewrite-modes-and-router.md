# SPEC: AI Rewrite modes, modifiers and the step that picks them

- **Status:** Approved by the owner on 2026-11-03, with the answers in *Decided by the owner*. The measurement comes first; no prompt code changes before it.
- **Date:** 2026-11-03
- **Issues:** #104 (modes and modifiers), #105 (the step that picks them) and #106 (the Edit prompt), all part of #102 *AI Rewrite, routed and measured*
- **Base revision:** `a460fc6`
- **Scope:**
  - **Prompt and parser:** `PromptPresets.swift` (the built-ins and a one-time migration) and `TextRefinementService.swift` (both system prompts, the context rule, and a step-one request and its reader).
  - **Where the text goes:** `FocusContext.swift` (new kinds of field).
  - **Running it:** `LocalLlamaRuntime.swift` (reading answers from next-token probabilities, ported from the spike) and `LocalChatXPC.swift` / `LocalChatService` (a step-one request).
  - **History and the Prompts page:** `TranscriptionHistory.Refinement` (what step one decided) and the Prompts page's examples.
  - **Measurement:** the harness's fixtures and variants (`RewriteEvaluation.swift`, `rewrite-fixtures.json`).
  - **Tests:** the tests that name today's presets (see *Code the rename touches*).
- **Does not touch:**
  - the Edit shortcut's flow, which keeps one request;
  - the Record Window's ✨, beyond what the preset rename moves;
  - the cloud catalogues. Jev joins as a provider (D6), through `docs/adding-a-provider.md`, in an issue and a pull request of its own.

## What it is

Today AI Rewrite sends six presets in full on every dictation, and the model picks one. The presets mix two kinds of thing:
- **kinds of text:** Clean-up, Email / Message, Notes / Bullets, Technical / Prompt;
- **things done to any text:** Rewrite / Draft (style, length, tone) and Translate (language).

A dictation often asks for both kinds at once, and the measurements show the overlap is where routing goes wrong. In the router spike (2026-11-02/03, 65 dictation fixtures), most of the remaining errors of the best local models were:
- Rewrite / Draft picked against Technical, Message or Clean-up;
- a request read as an instruction to us when it was text for a coding agent.

This spec does three things:
1. It splits the presets into **modes**, which are kinds of text, and **modifiers**, which are things done to any text.
2. It moves the decisions that do not need a model into code.
3. It specifies the first step of the two-step variant (#110), from what the spike measured.

The cleaned one-step prompt (#109) uses the same modes and rules. Whether two steps ship is still decided by the measurements (#102).

## Decisions

**D1 — Three built-in modes, each a kind of text.**

| Fixed ID | Mode | When to use | What to do |
|---|---|---|---|
| 01 | **Clean-up** (default) | The user dictated the text itself and asked for no other kind of text. | Write down what was said as finished text: fix recognition errors, punctuation, capitals and paragraphs; drop fillers, false starts and repeats. Keep the user's words and order of thought, and their language unless they asked for another. Add nothing, and add no structure that was not asked for. |
| 03 | **Message** | An email, letter, chat message or reply addressed to someone. | The register asked for, else polite and natural for the app. A greeting and sign-off only where the form calls for them. Invent no names, dates or facts; leave a `[placeholder]`. |
| 05 | **Document** (working name) | The user asked for a text with a form of its own: notes, a summary, a list, a plan or an outline; a commit message, a PR or ticket description, a bug report; or a prompt for an AI written anywhere but that AI's own prompt field. | The usual form of that text: compact `- ` points grouped by topic, in the order said; an imperative commit subject; problem, steps, expected result; a prompt as explicit steps. Headings only when asked for. Keep identifiers, paths and commands exactly. No padding. |

The exact wording is settled in #109 against the budget tests. This table fixes what each mode is for and where its edges are.

Three built-ins leave:
- **02 Rewrite / Draft.** Writing it better, longer, shorter or in another tone can be done to any kind of text, so it becomes a modifier (D2).
- **04 Translate.** A language is a modifier too (D2).
- **06 Technical / Prompt** merges into 05, which becomes Document. Notes and a commit message are both a text with a form of its own, and the router confused the two (the owner's call, 2026-11-03).

The IDs 02, 04 and 06 are never reused. The user's own prompts stay modes, as they are now.

No standard name covers notes, summaries and technical texts at once. The mode is called *Document* for now. Once its prompt is written (#109), a better name is proposed to the owner, and the rename lands before it ships.

This departs from #104, which listed six modes, Rewrite and *AI prompt* among them:
- Rewrite is a modifier for the reason above.
- A prompt for an AI is either text dictated *into* an AI's field, which is Clean-up by D3, or a prompt written elsewhere, which is Document.

Document keeps the word "summary" in its *When to use*. `TextRefinementService.isSummarising` reads it there to let a summary shrink the text, and without it the Record Window's collapse guard would refuse summaries (see *Code the rename touches*). A commit message written from a long dictation may then shrink too, which is right for it.

**D2 — Modifiers are rules of our prompt, applied on top of any mode.**

The modifiers are language, format, length, tone and "write it better".
- They are not prompts the user edits.
- The Prompts page does not list them.
- More than one can apply to the same dictation.

Step one decides only two of them, because only these two were measured:
- **Language:** the language asked for, if any.
- **Format:** plain, list or Markdown.

Step two reads length, tone and "write it better" from the transcript itself, as the one-step prompt does today. None of the three gets a router question (the owner's call, 2026-11-03).

**D3 — In an editor, a terminal or an AI's prompt field, code rules out the built-in modes and every modifier.**

A dictation into such a field is text for that program, even when it reads like a request to us:
- «перепиши цей файл англійською» in Cursor is an instruction for Cursor;
- "list every file bigger than…" in Terminal is a request for Claude Code or the user's shell, not a command for us to write.

The baseline already holds this rule (harness D7, and the owner's decision 1 of 2026-11-01). In such a field:
- of the built-in modes, only Clean-up is offered;
- the user's own modes are still offered (the owner's call, 2026-11-03);
- no modifier applies;
- the format is plain.

A user who has no prompts of their own gets Clean-up without step one. A user who has some gets step one with the options cut to Clean-up and their own modes:
- **Locally,** the answer is read over those letters only. The prompt stays the same prefix.
- **In the cloud,** the JSON schema's list of modes is cut the same way.

The language and format questions are not asked there.

Two things still apply here:
- **Spoken formatting commands** ("new paragraph"). They are rules, not modifiers.
- **Code said aloud is written the way it is typed.** «гіт коміт мінус ем» becomes `git commit -m` (`ctx-terminal-command`). This fixes a recognition error; nothing is carried out. The Clean-up-only prompt says so in one line.

"Plain" here means the model adds no format. Markdown the user dictates into a Markdown file is kept as dictated (`ctx-cursor-readme-content`, which allows it).

The decision moves into code:
- `FocusContext.Kind` gains `.codeEditor` and `.terminal` beside `.aiPrompt`. Each is listed by bundle-identifier prefix, the way the AI apps are:
  - terminals: Terminal, iTerm2, Ghostty, Warp, WezTerm;
  - editors: Xcode, VS Code, Cursor, Zed, the JetBrains IDEs, Sublime Text, Nova.

  #109 completes the list.
- Today Cursor and VS Code are left out of `.aiPrompt` on purpose: their agent pane and their editor are one app. That stops mattering, because both now get the same answer, Clean-up written down. They join the editor list, and the comment that explains the exclusion is rewritten to say this.
- In both variants, with no prompts of the user's own, such a field skips step one and is sent a system prompt with only Clean-up's instructions and the rules. About three in four of the owner's dictations go to such fields (harness D12), so this alone removes most of step one's cost.
- **In the one-step variant,** a user who has prompts of their own is sent a routing prompt that lists Clean-up and those prompts only.

This rule has three consequences:
1. **The system prompt is no longer the same on every dictation.** There are two: the routing prompt, and the Clean-up-only prompt for these fields. The one-step variant has a third, the routing prompt for these fields when the user has prompts of their own. The Clean-up-only prompt is the same text as step two's Clean-up prompt (D7), so it is one prefix.

   On this Mac the service saves two states today (`LlamaModel.savedPrefixes = 2`): the dictation's system prompt and the Edit shortcut's. The limit grows to hold the step-one prompt, the Edit prompt and one prompt per mode.
2. **`contextSection` loses two clauses:** "editor or terminal → code or a command" and "AI prompt → a clear prompt". They are the contradiction the harness spec named.
3. **Document's *When to use* does not mention an instruction meant for an AI coding tool,** as today's Technical / Prompt does.

**D4 — The language: what was asked for, else what was dictated. Code decides when asking means nothing.**
- A language asked for in the dictation wins.
- Otherwise the text stays in the language it was dictated in.
- Terms, names and code are kept as said, so «outdated» is never turned into «застарів».

Step one answers which language was asked for, from these options:
- none;
- each of `spokenLanguages`;
- English, if it is not among them;
- *another*, in which case step two reads which one from the transcript.

Each option is one letter (A, B, C…), so the answer is a single token (D6).

Code then turns an asked language that is the same as the dictated one into *none*. In the spike, a model asked "which language was asked for" often answered with the language that was spoken. With this rule, chained Qwen3.5 9B went from 57 to 58 of 65.
- The dictated language comes from `NLLanguageRecognizer`, limited to `spokenLanguages` plus English.
- The `Core imports` check forbids only SwiftUI and the engines, so NaturalLanguage may be imported in SpeechTextCore.
- Script alone is not enough: it does not tell English from Polish.
- The rule only removes a request, and a request for the language already spoken changes nothing in the text. So where the recogniser is unsure, code leaves the model's answer alone.
  - Between languages written in different scripts, such as Ukrainian and English, the script decides: on every fixture, a single word included, the recogniser was at least 0.9999 sure (router v4, 2026-11-03). A threshold only matters between languages that share a script, such as English and Polish, and is set when a fixture needs one.
  - A Ukrainian dictation that is mostly identifiers reads as English (`uk-ai-coding-prompt`). A request for Ukrainian on it is then kept, which is harmless; a request for English on it would be dropped.

**D5 — The format: plain unless asked; Markdown only when named or rendered.**
- Plain text is the default.
- A `- ` or numbered list when one is asked for. Lists are allowed everywhere.
- Headings, bold and tables only when the user names them, or when the destination renders Markdown. Slack does; #111 keeps the apps that render Markdown as data.

The format question's *list* option says it covers lists only. In the spike every model answered *list* for «план статті з заголовками», and the word «заголовки» has to mean Markdown.

**D6 — Step one: three questions, no reasoning, under one second, with a local and a hosted option.**

Step one answers three questions: the mode, the language asked for, and the format. Each option is one letter.

The 1 s limit is the owner's (2026-11-03). Step one has three options (the owner's calls, 2026-11-03 and 04):
- **Locally, with the model already loaded** for AI Rewrite: Gemma 4 12B or Qwen3.5 9B.
- **Locally, with OneJev 1.6,** a Qwen3.5 fine-tune made for picking between options (Apache 2.0), in two sizes, 0.8B and 4B. It is a download of its own and is held in memory beside the rewrite model, so a Mac whose AI Rewrite runs in the cloud can pick on this Mac (#152).
- **Hosted,** with Jev, which joins as a provider (#143).

As measured in router v4 (2026-11-03/04): the new modes, D3 and D4 applied, 66 dictation fixtures of which 43 are asked and the rest answered by rule; one run each; the fixtures shaped the prompts, so these are upper bounds.

| Step one | Read how | All three right, of 43 | Median |
|---|---|---|---|
| Jev (a provider of its own, any AI pick) | all three questions in one request | 42 | 0.33 s |
| Gemma 4 12B, already loaded | next-token probabilities in our llama.cpp: questions in the cached system turn, the dictation read once, the three answers read in a row in one pass ("chained") | 42 | 0.86 s |
| Qwen3.5 9B, already loaded | the same, chained | 41 | 0.64 s |
| OneJev 1.6 4B Q8_0 (4.5 GB) | next-token probabilities in our llama.cpp, with OneJev's own prompt layout | 38 | 1.10 s |
| OneJev 1.6 0.8B Q8_0 (0.8 GB) | the same | 37 | 0.23 s |

Not offered:
- **GPT-OSS 20B on Groq,** JSON with a strict schema: 34/43, at 0.66 s median but 1.6 s at p90. A Groq user gets the one-step prompt instead (the owner's call, 2026-11-04).
- **OneJev 1.6 9B** (Q4_K_M, 5.6 GB): 39/43 at 2.20 s, over the timeout.
- **Plain small models** read the same way: Qwen3.5 4B 37/43 at 0.37 s chained, 2B 24–32, 0.8B 17. Without the fine-tune, a small model is not usable.
- **Anthropic and OpenAI themselves:** nothing measured under 1 s. Haiku 5.5 took 1.24 s; GPT-6 Luna was not measured.

- **On this Mac,** chained reading is the default. "Shared" reading (the state copied once per question) gave Qwen3.5 9B 42/43 at 0.90 s and Gemma 4 12B 42/43 at 1.31 s in router v4: one more right for Qwen, at a quarter of a second more. The step-one prompt, with the user's own modes in it, is read when the model loads and again after a prompt is edited: read cold, it took 2.6–3.8 s, over the timeout, and 0.6–0.95 s once read (router v4).
- **Which step one runs,** by default, follows from what the user has:
  - with a Jev key, Jev, whatever the AI pick;
  - else, with AI Rewrite on this Mac, the model already loaded;
  - else, with OneJev downloaded, OneJev.
- **Otherwise,** the user gets the cleaned one-step prompt with the code rules of D3–D5.
- **Choosing between them** is #130's settings question, not this spec's.
- **Jev is a new place the user's words go:** the transcript and the `<context>` block, nothing else.
  - It is added like any provider (`docs/adding-a-provider.md`, a key in `APIKeyStore`), in its own issue.
  - Settings › Privacy & Data › *What leaves this Mac* and `docs/privacy.md` say so.
  - Nothing goes to it without a key the user entered.
- **On reasoning:** step one never asks for reasoning. Local reading generates no tokens at all. The cloud answer is one compact JSON object whose default values are left out.
- **When step one fails:** a failure or a reply that is not one of the options means the one-step prompt is sent instead. So does no answer within the timeout.
  - The timeout is 2 s (the owner's call, 2026-11-03), above the 1 s target, because Gemma 4 12B's median sat at the limit (0.96 s in the spike, 0.86 s in router v4) and OneJev 4B's is above it.
  - The worst case is therefore 2 s plus a full one-step request.
  - The dictation never waits on step one twice.
- **The code:** the spike's code (`LlamaModel.chainedProbabilities` and `branchProbabilities`, on the local branch `spike/router-logits`, never pushed) is rewritten for main with tests. It is not merged as it is.

**D7 — Step two is sent one mode and the modifiers, as lines.**

Its system prompt holds:
- the rules;
- the one mode's instructions;
- the line telling it to apply whatever else the transcript asks for: length, tone, a rewrite.

The modifiers step one chose go in the **user message**, as a block before the transcript (`<route>` with `language: English`, `format: list`). They do not go in the system prompt. Each mode's system prompt then stays one prefix this Mac reads once, whatever the modifiers; in the system prompt, every combination would be a new prefix read in full.

Step two writes no `<<mode:…>>` marker, because the mode is already known. The parser still takes one off if a model writes it anyway.

The user's own modes count towards the limit on saved prefixes. Past it, a mode's prompt is read again, as any prompt is today.

**D8 — The cleaned one-step prompt uses the same modes and rules.**

#109 rewrites `buildSystemPrompt`:
- the three modes;
- one paragraph of modifiers, holding the language rule of D4 and the format rule of D5;
- the D3 rules, with the editor rule gone, since code now handles those fields;
- `contextSection` without its two clauses.

The marker stays in the one-step prompt, because the mode is still the model's choice there. #109 sets new budgets for the prompt-length tests.

**D9 — Stored presets move once.**

`load()` returns the stored list as it is. A user who ever saved a prompt therefore keeps the old built-ins, and the new ones would reach only users who never edited anything. A one-time migration runs at launch (`promptPresetsVersion`):

- **A built-in left as it shipped** is replaced by the new text and name: 01 Clean-up, 03 Message, 05 Document.
  - "As it shipped" means equal to *any* text that built-in ever had. The stored copy holds whatever text was current when the user saved. Git history holds four distinct texts of the built-ins, across the file's three paths (`VoicePeter/`, `SpeechText/SpeechText/`, `Packages/SpeechTextCore/`):
    - `71edce8` (2026-08-26), the one v0.9.x shipped from the archived repository;
    - `545f058` (2026-10-01);
    - `1ead0ee` (2026-10-06);
    - `53b1287` (2026-10-18), today's, which v0.10.0 shipped.

    All four are kept in the migration as a table.
  - A built-in that was **edited** stays exactly as the user left it.
- **02 Rewrite / Draft, 04 Translate and 06 Technical / Prompt,** if left as shipped, are removed. If edited, they stay as the user's own prompts.
  - An edited Translate then competes with the language modifier. That is the user's choice, and the Prompts page shows it like any other prompt.
- **The user's own prompts** are untouched.
- **If the default pointed at a removed prompt,** `defaultPreset` already falls back to Clean-up. The migration also removes the stored ID.
- **Restore built-in…** restores the three new ones.
- **`promptPresetsVersion`** is a new key, a one-shot marker like `hotkeyLayoutVersion`. It gets a row in AGENTS.md's settings table.
  - It stays out of `portable`. The migration is idempotent: the new texts match no old one. A rename that carries the list without the marker therefore only runs it again for nothing.

**D10 — History records what step one decided.**
- `Refinement.presetName` stays the mode.
- A new optional field, `Refinement.route`, records the language and format chosen and who chose them: the step-one model, or code (D3, D4). A choice that looks wrong can then be traced, as the focus context can be today. Records from before it decode with nothing there.
- Records named Translate, Rewrite / Draft, Notes / Bullets or Technical / Prompt keep their names. Their rows keep the tag, and the Prompts page, which counts only prompts that exist, no longer shows them.

The Prompts banner's Translate example ("translate to English дякую що прийшли") is changed to show what replaces it. It becomes a Message example with a language asked for, so the banner shows that a request stacks on a mode.

**D11 — The Edit prompt (#106) keeps one request and gets the same rules.**

An edit needs no routing: the selection and the instruction already arrive apart. Its prompt gets the same review:
- **Language:** the selection's language unless the instruction asks for another, with terms kept as written.
- **Markdown:** the D5 rule.
- **Modes:** listed as a vocabulary the instruction may name, the three new ones and the user's own.
- **Repeats:** removed against the budget test.

"Translate this into English" now finds no Translate mode. It is reported as `Instruction`, which is right, and the e2e `edit` scenario does not depend on the name.

The `<<mode:…>>` marker stays. It costs one line and is History's only label for an edit (the owner's call, 2026-11-03).

**D12 — The fixtures measure the router, in the repository.**
- **Mode expectations:** `modes` keeps today's names for `current` (harness D3). The new names go in `variantModes`.
- **Editor fixtures:** a fixture in an editor, terminal or AI field that accepts Technical or Clean-up today accepts only Clean-up under the new modes. Fixtures that accept Notes / Bullets or Technical / Prompt elsewhere accept Document.
- **One fixture with a prompt of the user's own** in an editor field checks that the mode is still offered there (D3). Fixtures may carry `presets` for this.
- **Language and format:** the expectations for the asked language and the format exist so far only in the private spike script. They become fixture fields, `askedLanguage` (default none) and `format` (default plain, or a set). A `route` variant can then score step one alone with the committed harness, with no private script.
- **The language options** depend on `spokenLanguages` (D4), so the `route` variant runs with a stated list, `--spoken-languages uk,en` by default. A fixture may set its own.
  - `askedLanguage` names a language code.
  - An answer of *another* is right only when the code is outside the run's list. For a uk+en run, Polish asked for is *another*.

## What the code rules and the new modes should change

These are the router spike's errors for its two strongest local models: Qwen3.5 9B and Gemma 4 12B, chained and shared, 65 fixtures each. That is 28 wrong rows out of 260.

Fixed by a code rule, so not a prediction:

| Rows | Fixtures | Rule |
|---|---|---|
| 18 | `uk-code-editor-instruction-is-content` (Cursor), `dirty-prompt-to-rewrite-in-claude` (Claude), `ctx-chat-question-not-answered` (ChatGPT), `dirty-mixed-sentence-english`, `dirty-fragment`, `en-dirty-fragment` (T3 Code), `en-terminal-instruction` (Terminal) | D3: Clean-up, no modifiers, plain; step one is not asked, since the fixtures carry no prompts of the user's own. |
| 1 | `ctx-browser-notion` (Notion in Safari: Ukrainian "asked" for a Ukrainian dictation) | D4: same language → none |

Predicted, to be re-measured:

| Rows | Fixtures | Why it should change |
|---|---|---|
| 3 | `dirty-message-english-chrome` ×2, `en-dirty-homophones` (Slack) | Rewrite / Draft was picked, and it no longer exists. The model now has to pick Message or Clean-up. |
| — | every fixture | Three modes to tell apart instead of six. |
| 4 | `format-headings-asked` (headings asked for, answered *list*) | D5's wording: *list* is lists only, and headings mean Markdown. |
| 1 | `ctx-slack-bold-asked` (bold asked for, answered *list*; its language error is fixed by D4) | The same D5 wording. |
| 1 | `en-dirty-false-starts` (Gemma, shared: Message for plain content) | None: a model error the new modes do not explain. |

If the predictions hold, the strongest local models would be left with one or two wrong rows out of 65. That figure is a hypothesis for the rerun, not a result.

## Code the rename touches

- `TextRefinementService.isSummarising` reads "summar" / "підсум" in a preset's name and *When to use*. Document keeps "summary" (D1), and `RefinementTests` checks that Document is the one summarising built-in.
- The budget and rule tests are rewritten in #109:
  - `testTheBuiltInPromptsStayCompact`;
  - `testTheRoutingPromptStaysWithinItsBudget` (1700 / 2100);
  - `testTheRoutingPromptKeepsEveryRuleThatChangesBehaviour`.
- Tests that name today's presets:
  - `DictationReplayTests` (`### Translate`);
  - `RefinementTests` (parse, loose markers, the `(DEFAULT` marker on Translate);
  - `LocalModelsTests` (loose markers);
  - `HomeSummaryTests`, `HistorySummaryTests`, `MainPagesTests` (`Email / Message`, `Notes / Bullets` as stored names).

  Those that test the parser on arbitrary names may keep them, since History holds old names. Those that test the built-ins take the new ones.
- `HomeSummary.swift`'s sample record (`Email / Message`) and the Prompts banner's examples (`builtIn: "04"` and `"06"`, the bug fix, which moves to `"05"`).
- Docs:
  - `docs/decisions.md` › *Preset routing in one call* and › *Small models write the mode marker loosely*;
  - `docs/rewrite-evaluation.md`'s example of an abbreviated marker (`Technical` for `Technical / Prompt`);
  - `docs/architecture.md` › `PromptPresets.swift`.
- `RewriteChecks.swift`'s comment on abbreviated names.

## Measurement before the app changes

1. **Fixtures:** add `variantModes`, `askedLanguage` and `format` (D12). No app code changes in this step.
2. **Router:** rerun on the new modes with the code rules applied. Done as router v4 (2026-11-03/04); the results are in D6. The target was at least 60/65 with all three answers right, at a median under 1 s; Jev, Gemma 4 12B and Qwen3.5 9B reached 41–42 of 43 asked, each at a median under 1 s.
3. **Text:** `current` against the cleaned one-step prompt (#109) and the two-step one (#110), on the six engines of #114, three runs.
   - **The cleaned one-step prompt** may lose no more than noise against the baseline on any engine: two rows of 216.
   - **Two steps** ship for an engine only where they write better text, or write the same text faster than its one-step prompt.
4. **The app:** then the prompt code, the migration (D9) and History's `route` (D10), with the tests above.

## Decided by the owner

On 2026-11-03, the owner gave these answers. Each is written into the decision it changes.
1. **Technical merges with Notes** into one mode, whose name may still change (D1).
2. **Jev joins as a provider** for step one. A local option is needed beside it: the model already loaded, or OneJev 0.8B or 4B (D6).
3. **Step one's timeout is 2 s** (D6).
4. **In an editor, a terminal or an AI field the user's own modes are still offered;** only the built-ins and the modifiers are ruled out (D3).
5. **Clean-up keeps the dictated language unless another was asked for** (D1).
6. **The merged mode is called Document for now;** a new name is proposed once its prompt is written (D1).
7. **Length and tone get no router questions** (D2).
8. **The Edit prompt keeps its `<<mode:…>>` marker** (D11).
9. **OneJev 0.8B and 4B are offered as local step-one models** (2026-11-04, D6, #152).
10. **GPT-OSS 20B on Groq is not a step-one option** (2026-11-04, D6).
