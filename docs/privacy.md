# Where your audio goes

SpeechText has no server, no account, no telemetry and no analytics. Where your audio and text go depends only on the engine you pick in Settings.

## What is sent where

- **Apple engine**: audio never leaves your Mac while you dictate. The one exception: Apple's recogniser cannot read a saved recording, so a retry from History is uploaded to Groq, and only if you have stored a Groq key. Settings › Privacy & Data says when that applies.
- **Local model** (Parakeet or Whisper): audio never leaves your Mac either; the model runs on it, and no key is involved. The same goes for AI Rewrite on a built-in model: the text stays on your Mac too.
- **Groq / ElevenLabs / OpenAI**: audio is uploaded to that provider, using *your* API key, under *their* privacy policy. SpeechText never sees your audio or your keys.
- **AI Rewrite and Edit with AI**: text, never the audio, is sent to the LLM provider you selected, with your key: the transcript (or the selected text and your instruction), your Dictionary's words, and the app, window title and field the text is for. Nothing is read from a password manager, and only the app's name from a password field.
- **History**: transcripts are stored locally in `~/Library/Application Support/SpeechText/`. How long History keeps dictations is your choice (Settings › Privacy & Data: forever by default, or this session only, 7 or 30 days, 3 or 6 months, a year). A failed recording keeps its audio so you can retry: 7 days by default, on the same scale and never longer than its record, then it is deleted.
- **API keys**: a release keeps them in the macOS keychain, where no other app can read them; a build you make yourself keeps them in its preferences file (see [SECURITY.md](../SECURITY.md)). They are never sent anywhere except to the provider they belong to.

## Speech engines

| Engine | Cost | Notes |
|---|---|---|
| **Apple** (on-device) | free | Recognition stays on your Mac; a History retry of a saved recording goes to Groq if you have a Groq key |
| **Groq** (Whisper) | ~$0.04/hour | Fast, accurate, needs an API key |
| **ElevenLabs** (Scribe v2) | pay-as-you-go | Upload, or realtime streaming with live partial text; needs an API key |
| **OpenAI** | pay-as-you-go | Upload or realtime streaming, needs an API key; the newest engine, and the least exercised |
| **Local model** | free | Parakeet or Whisper, downloaded to your Mac in one click; no key, works offline |

For local models, Settings reads your Mac's chip, memory and free disk, places it in a memory class from 8 GB to 256 GB and up, and marks two models for it: a **recommended** one (the fastest of good quality) and a **best quality** one. Heavier models stay available, labelled. The picks also follow the languages you speak and your macOS: on Apple Silicon both are usually **Parakeet v3**, NVIDIA's multilingual model (25 European languages, 483 MB), which in our tests matched the best cloud engine in under a second. If you speak English alone it recommends the smaller English-only Phonon-2 (macOS 15 or later), and for a language Parakeet does not know, Whisper Large v3 Turbo. Each model's row says how many languages it knows and warns about one of yours it lacks. Intel Macs have no Neural Engine and are pointed at the small Whisper models instead.

## AI Rewrite

For the AI pass you can use **Groq**, **Anthropic** or **OpenAI** with your own key, or run it on your Mac with nothing else installed: AI Rewrite is built on [llama.cpp](https://github.com/ggml-org/llama.cpp), and Settings offers Qwen3.8 27B, gpt-oss 20B, Gemma 4 12B, Qwen3.5 9B and Qwen3.5 4B, from 2.7 GB to 19 GB, recommends a pair for your Mac, and downloads them in one click. A model that is in use is read once and kept ready, so a local rewrite takes a second or two.

If the AI provider fails or refuses, you still get your transcript as you said it. A dictation is never lost.
