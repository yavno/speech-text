# Roadmap

Where SpeechText is going. This is the contract with contributors: work that fits here is likely to be merged, work that doesn't should start as an issue.

Tracked work lives in [issues](../../issues). This file is the direction; issues are the tasks.

## Now

- **AI Rewrite, routed and measured** — a harness that measures what AI Rewrite writes, and a prompt without its contradictions and repeats (both done): modes for the kind of text, modifiers for language, length, tone and format. Then possibly two steps — a fast model picks the mode, the writing model gets only that mode.
- **Your own model server** — use a model you already run, in Ollama, LM Studio or any server that speaks the OpenAI API, for AI Rewrite and, where the server transcribes audio, for dictation: an address, an optional key and a model from the server's list.

## Next

- **Notetaker** — record a conversation you are part of, then review a speaker-attributed transcript, summarise it, ask questions and export it. Microphone and system audio are captured as two separate tracks, so who-said-what is exact for a one-to-one conversation without any speaker model at all.
- **More providers** — behind the provider registry (`ProviderDescriptor`, see `docs/adding-a-provider.md`). New providers are a good contribution.
- **Playground** — try your own dictations from History through other models and prompts, side by side with what came out, how long it took and what it cost.

## Later

- **Automation** — URL scheme, Shortcuts, a CLI, and an MCP server, so other tools can start a dictation or read a transcript.
- **Rich text paste** — formatting AI Rewrite was asked for, pasted as real rich text where the app does not render Markdown.

## Done

Kept short, because a roadmap that never records an arrival stops being believed: continuous integration on every pull request; live transcription shown on the overlay while you speak and pasted once at the stop; local speech and chat models with a hardware-based recommendation; first-run setup; signed, notarized releases that update themselves, the first of them public as 0.10.0 and installable with Homebrew; OpenAI as a speech engine; API keys in the keychain; dictations made offline saved and retried once the network is back; a main window with History, Usage and Prompts; a Dictionary whose words reach the engine, a replacement table and the AI prompt; AI Rewrite built into the app on llama.cpp, with nothing else to install; a voice activity detector that keeps typing and room noise from being sent; the languages each model knows, shown before you download it; a lifecycle for models, so one a vendor retires is moved to its replacement; the app in Spanish and Ukrainian, with its language chosen in Setup or in Settings; a weekly check of the catalogues against the vendors.

## Want to help?

The roadmap, with votes and progress: https://speech-text.app/roadmap

Start with [`good first issue`](../../labels/good%20first%20issue). For anything on this roadmap, comment on the relevant issue first so two people don't build the same thing.
