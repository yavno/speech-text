# Roadmap

Where SpeechText is going. This is the contract with contributors: work that fits here is likely to be merged, work that doesn't should start as an issue.

Tracked work lives in [issues](../../issues). This file is the direction; issues are the tasks.

## Now

- **Distribution** — the first public release, 0.10.0, is out: a signed, notarized `.dmg` that updates itself. What is left is a Homebrew cask.

## Next

- **Notetaker** — record a conversation you are part of, then review a speaker-attributed transcript, summarise it, ask questions and export it. Microphone and system audio are captured as two separate tracks, so who-said-what is exact for a one-to-one conversation without any speaker model at all.
- **More providers** — behind the provider registry (`ProviderDescriptor`, see `docs/adding-a-provider.md`). New providers are a good contribution.
- **Localization** — the UI is English-only. Translations come in the order people ask for them.

## Later

- **Automation** — URL scheme, Shortcuts, a CLI, and an MCP server, so other tools can start a dictation or read a transcript.

## Done

Kept short, because a roadmap that never records an arrival stops being believed: continuous integration on every pull request; live transcription shown on the overlay while you speak and pasted once at the stop; local speech and chat models with a hardware-based recommendation; first-run setup; signed, notarized releases that update themselves; OpenAI as a speech engine; API keys in the keychain; dictations made offline saved and retried once the network is back; a main window with History, Usage and Prompts; a Dictionary whose words reach the engine, a replacement table and the AI prompt; AI Rewrite built into the app on llama.cpp, with nothing else to install; a voice activity detector that keeps typing and room noise from being sent; the languages each model knows, shown before you download it; a lifecycle for models, so one a vendor retires is moved to its replacement; a weekly check of the catalogues against the vendors.

## Want to help?

The roadmap, with votes and progress: https://speech-text.app/roadmap

Start with [`good first issue`](../../labels/good%20first%20issue). For anything on this roadmap, comment on the relevant issue first so two people don't build the same thing.
