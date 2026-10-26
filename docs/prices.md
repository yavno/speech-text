# Updating the list prices

Usage and Home show what dictation cost as an **estimate**: "≈ $1.20 · estimated from known
prices", with the date the prices were checked under How this is counted. The prices are written into the app, checked by hand
against each vendor's page, and refreshed now and then with a release. There is no
price feed and no price history: every History record is priced again at the current
table from the units its ledger keeps (audio seconds, billed seconds, tokens, keyterms),
so a refresh reprices everything without a migration.

## Where the prices are

| What | Where |
|---|---|
| Speech models, a minute of audio and the keyterm surcharge (`SpeechRates`) | `price:` on each entry of `sttModelCatalog`, `Packages/SpeechTextCore/Sources/SpeechTextCore/STTModelCatalog.swift` |
| Chat models, input / cached input / output per token (`ChatRates`, written `.perMillion(…)`) | `price:` on each entry of `chatModelCatalog`, `Packages/SpeechTextCore/Sources/SpeechTextCore/ChatClients.swift` |
| The date the table was checked | `UsagePrices.checked`, `Packages/SpeechTextCore/Sources/SpeechTextCore/HomeSummary.swift` |
| The same table, written out for review | `ListPriceTests`, `SpeechText/SpeechTextTests/HomeSummaryTests.swift` |

A price is one of `ListPrice`'s cases: `.free` (a model on the Mac, Apple),
`.listed(rates)`, or `.notPriced` for a model whose vendor publishes no price. The
field is required, so a new model cannot be added without one. An unpriced model is
named in Usage and Home, never charged at another model's rate.

Between refreshes, `scripts/check-vendor-models.sh` compares the prices with the vendor's own
API where it states them, which means Groq's chat models. It also flags models a vendor
retires or adds ([vendor watch](vendor-watch.md)).

## Where to check

The pay-as-you-go, standard-tier price, in US dollars:

- **Groq:** the models page, console.groq.com/docs/models (speech by the hour, chat per
  million tokens). Cached input: the prompt-caching page lists the models it covers and
  the discount (50 % on gpt-oss as of 14 October 2026). Qwen3.8 27B's cached price
  ($0.40) is stated only by `/v1/models`, which the vendor watch reads. Every other
  model's cached price is its input price.
- **ElevenLabs:** elevenlabs.io/pricing/api. Scribe v2 and Scribe v2 Realtime by the hour,
  and *keyterm prompting* as a separate line per model. Use the pricing page's figure,
  not the API reference's percentage.
- **OpenAI:** developers.openai.com/api/docs/pricing. Chat in the standard tier. For
  transcription, use the *estimated cost* per minute, which is the only figure given for
  every model.
- **Anthropic:** platform.claude.com/docs/en/about-claude/pricing. The cached price is
  *Cache hits and refreshes*. Cache writes are not priced apart, because the app sends no
  `cache_control`.

## Steps

1. Open each page above and compare every model in both catalogues.
2. Change each `price:` that moved. Change `.notPriced` to `.listed(…)` once the vendor
   publishes a price.
3. Set `UsagePrices.checked` to today, even if nothing moved: the date says when the
   table was checked, not when it last changed.
4. Change the same figures in `ListPriceTests`, and the date in
   `testTheTableSaysWhenItWasChecked`.
5. Run the tests. A model added to a catalogue without a row in `ListPriceTests` fails
   there.
6. Add a line to `CHANGELOG.md` under *Changed* if any price moved.

A new model gets its price when it is added (docs/adding-a-provider.md, section 3).

## Deprecations

Read each vendor's deprecations page in the same pass, and compare it with every
catalogue entry's `lifecycle`:

- **OpenAI:** developers.openai.com/api/docs/deprecations ("deprecated", "shutdown date").
- **Groq:** console.groq.com/docs/deprecations.
- **ElevenLabs:** elevenlabs.io/docs/overview/models (a deprecated model is marked there).
- **Anthropic:** platform.claude.com/docs/en/about-claude/model-deprecations ("deprecated",
  "retirement date").

1. A model the vendor deprecated gets `.deprecated(…)` with the announcement date, the
   shutdown date, the replacement and the page (docs/adding-a-provider.md › section 3).
   Never delete it.
2. Set `UsagePrices.deprecationsChecked` to today, and the date in
   `testTheDeprecationCheckHasItsDate`, even if nothing changed.
3. Add a line to `CHANGELOG.md` under *Changed* for each model whose users will be moved.
