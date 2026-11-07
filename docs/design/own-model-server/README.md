# Your own model server

Design only. Nothing here is wired to the app. The behaviour is in
[docs/specs/2026-11-07-own-model-server.md](../../specs/2026-11-07-own-model-server.md); this is how
it looks. [index.html](index.html) is a self-contained mock-up, and its review bar switches:

- the theme;
- the role: Speech to text or AI Rewrite;
- the state the test request ends in;
- what kind of address it is: this Mac, the local network over plain HTTP (with and without a
  key), or the internet over HTTPS;
- *Languages I speak*: one or several;
- whether the other role already has a server.

## Where it lives

A third place card, **Your server**, beside *On this Mac* and *Online service*, on both Settings
pages and on both engine steps of setup (owner, 2026-11-07). It is neither a built-in model nor a
company with an account, and where the words go is the user's to say, so it gets its own card and
its own sentence about privacy. The two alternatives — a row under *On this Mac*, or a service in
the *Online services* list — were turned down: a server in another room is not this Mac, and a
free localhost server is easy to mistake for a cloud account.

## The form

One form, the same in Settings and setup, for each role:

- **Address**, with presets that fill in a server's documented default address (Ollama, LM
  Studio, llama.cpp, Speaches) and do nothing else. A preset is shown only under the role its
  server serves: LM Studio does not transcribe, so it is not under Speech to text.
- Under the address: **where it goes**, read off the address — *This Mac*, *Your network* or *The
  internet*. Plain HTTP anywhere but this Mac warns that anyone on the network can read what is
  sent; a key typed for such an address warns again.
- **Key**, shown only when the server asks for one (401 or 403) or when one is stored.
- **Model**, a picker of what the server's `/v1/models` lists; a text field only when it lists
  nothing.
- **Test**, and its result line: the time on success, otherwise what went wrong and what to do.
  The test sends a fixed sentence or a one-second silent WAV, never the user's words.
- For speech, with more than one of *Languages I speak*: none is sent, as for every engine, and the
  form says that some servers then assume English.

Nothing is used until a test has passed once, so a half-typed address never takes over dictation.
In setup, *Continue* waits for a passed test. When the other role already has a server, an empty
address offers its address once; it is never copied silently.

## Words

Every string in the mock-up is the proposed English text, in American spelling. The failure lines:

| Test ends in | Says |
|---|---|
| no answer | Nothing answered at this address. Is the server running? |
| 404 | The server answered, but not at this path. Most addresses end in /v1. |
| 401 / 403 | The server refused the request without a key. |
| no models | The server lists no models. Load one in it, or type its ID. |
| no transcription | This server doesn't transcribe audio. Use it for AI Rewrite, or pick another server. |
| audio refused | The server refused the test recording. It may not take this model, or WAV. |

## Elsewhere

- **History** names *Your server* and the model; a dictation the server did not answer is *Not
  transcribed* with *Retry*, not queued as offline.
- **Usage**: *Not priced*, never ≈ a price.
- **Privacy & Data › What leaves this Mac**: "Audio goes to ‹address›, and nowhere else."
- **macOS's Local Network prompt**, once, for an address on another machine; the second line is
  `NSLocalNetworkUsageDescription`.

The skins (techno, minimal) are not involved: they draw the overlay and the Record Window, and this
changes neither.
