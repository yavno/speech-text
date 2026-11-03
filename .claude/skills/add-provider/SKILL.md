---
name: add-provider
description: Add or change a speech engine or AI Rewrite (LLM) provider in SpeechText — a new cloud vendor, a realtime WebSocket, an OpenAI-compatible chat endpoint, a new or retired model, or a change to provider capabilities (STTModelDescriptor, Dialect). Use whenever the task touches STTProviderType, Provider, sttModelCatalog, LLMProviderType, ProviderDescriptor or an API key, even for "support Deepgram", "add Mistral", "OpenAI has a new transcribe model".
---

# Add or change a provider

Everything is in `docs/adding-a-provider.md`. Do the steps in order and read each
section of the guide when you reach it.

1. **Agreement.** A new vendor needs an issue first; it is a new place user data goes. A
   model that runs on the Mac is a new dependency. Stop and ask the owner.
2. **Shape.** Pick a row in guide §1.
3. **Measure.** Go through guide §2 against the live API. Anything you could not check
   gets a `// UNVERIFIED:` comment. Never write a date you did not measure.
4. **Enum case, then build.** The compiler lists every `switch` to fill. Then run
   `scripts/check-provider-guide.sh <kinds> <vendor>` and work it down to no `✗`.
   For a new model of an existing vendor, use guide §3 instead; the script cannot help
   there.
5. **Write the code.** Follow the guide section for the shape, and copy the closest
   existing transcriber or chat client.
6. **Tests and docs.** Guide §8. Run the tests (AGENTS.md › Tests).
7. **Keep the guide true.** If you changed what adding a provider involves, update the
   guide in the same change, then run `scripts/check-provider-guide.sh`.

End with a short summary covering:
- the shape chosen;
- the facts measured and still unverified;
- the script and test results;
- the decisions left to the owner.
