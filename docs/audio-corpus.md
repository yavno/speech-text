# Audio corpus

Real recordings played through every speech engine, so that a change to recognition,
or a vendor's model update, shows up as numbers rather than as a feeling after a manual
pass. Traces (`$SPEECHTEXT_TRACES`, `scripts/replay-traces.sh`) replay what a provider *said*; the corpus
produces that from audio.

## What is where

| | Where | In git |
|---|---|---|
| Clip descriptions: expected text, language, tags, bounds | `SpeechText/SpeechTextTests/Audio/<clip>.json` | yes |
| The recordings, `<clip>.wav` and `<clip>@<variant>.wav` | a folder of your own, passed as `<corpus-dir>` | **no** — it is someone's voice |
| A run: `summary.md`, `results-*.json`, `traces/`, the `xcodebuild` logs | `$SPEECHTEXT_RUNS/<date>/`, a folder of your own outside the repository | **no** — it holds what the engines heard in someone's voice |
| What the local picks read: WER and latency per model and language, no words | `Packages/SpeechTextCore/Sources/SpeechTextCore/LocalModelMeasurements.swift` | yes |

A description:

```json
{
  "expected": "Завтра ми поїдемо до моря, якщо погода буде теплою і сонячною.",
  "language": "uk",
  "tags": ["pause"],
  "maxWER": 0.15,
  "forcedLanguages": ["uk"],
  "note": "Two seconds of silence after «до моря,»."
}
```

- `expected` is what was said, as it should be written. Empty for a clip that must
  produce nothing (silence, a press shorter than a word).
- `language`: `uk`, `en` or `mixed` — what the output's alphabet is checked against.
- `maxWER` is optional: an absolute bound for a clip that needs one. Without it the
  word error rate is still judged against the previous run (see **Against the previous
  run**).
- Every clip runs with Auto. `forcedLanguages` adds a pass per language, as if the user
  had named exactly that one. A pass forced to another language than the clip's (English
  forced to Ukrainian) is reported only: what comes out (a translation, a transliteration or the English) is the finding.
- `vocabulary` (optional) lists the words a user would put in the Dictionary. A clip
  that has one gets one more pass, `auto + dictionary`, with those words as the
  Dictionary: sent to every engine that takes them, as the app sends them (Groq's
  `prompt`, a term list), and correcting the stop's text — the measurement the Dictionary asked for
  before trusting Groq's `prompt`. The noise and silence clips carry `uk-tech-terms`'
  words too: silence is where a Whisper prompt is said to come back as text.
- `spokenLanguages` (optional) is "Languages I speak" with nothing forced — `["uk",
  "en"]` on every clip, as the owner runs the app. It adds a pass named after them
  (`uk+en`): Auto, with the script rule of `HallucinationFilter` judging against them.

One description may have several recordings. `<clip>@<variant>.wav` is played against
`<clip>.json` and reported as its own row, `<clip>@<variant>`: another microphone
(`@builtin`, the MacBook's own), or another way of saying it (`@english`, `@casual`,
`@drawn`). A description may have no `<clip>.wav` at all, only variants.
`SPEECHTEXT_CLIPS=uk-pause` takes every recording of it; `uk-pause@builtin` takes one.

## Running

```sh
SPEECHTEXT_RUNS=~/path/to/runs ELEVENLABS_API_KEY=… OPENAI_API_KEY=… GROQ_API_KEY=… \
  scripts/evaluate.sh ~/path/to/corpus
```

Keys come from the environment only, never from the app's settings, and may be other
keys than the app's; an engine without its key is a `no key` row. `--cloud` or `--local`
runs one half; `SPEECHTEXT_ENGINES=openAI/gpt-live-transcribe,local/parakeet-tdt-0.6b-v3`
and `SPEECHTEXT_CLIPS=uk-pause,uk-names` narrow it. The cloud half costs cents.
`SPEECHTEXT_RUNS` is required and refused inside the checkout. `SPEECHTEXT_RUN_DIR=<runs>/<date>` adds to an earlier run instead of starting
a new one: the clips run now replace their own rows and every other row stays, so a clip
recorded — or re-recorded — after a run needs no second full run.

Both kinds of engine run through **`SpeechTextEvaluation`** (a command-line target with
its own scheme), which `scripts/evaluate.sh` builds and runs: `--cloud` adds the cloud
engines, `--no-local` leaves the local ones out. Unlike the test bundle it links
FluidAudio, so it loads the voice activity detector and a cloud engine's segment is
judged — sent or not, pasted or not — as the app judges it. Cloud rows go to
`results-cloud.json`, local ones to `results-local.json`. Every local model in the
catalogue is a row; one that is not installed says `not installed`. A model's first load
after a build can take minutes (Core ML specialises it for the Mac) and is reported as
`load`, apart from the stop-to-text time.

**`LiveProviderTests`** (the test bundle) can still run the cloud engines on their own —
`SPEECHTEXT_LIVE=1`, each variable passed as `TEST_RUNNER_<NAME>`, since an unhosted test
bundle does not inherit the shell's environment — but without the voice detector, which
the bundle cannot load: a quick check of an engine, not a run to commit.

Each row also records what the detector made of the clip (`voice: max 0.95, 1 windows
over the threshold` in *Every result*): the margin between noise and speech is read off
every run, not only whether a clip was sent.

Apple's recogniser is not in the matrix: its permission prompt would hang a headless
run. `scripts/e2e.sh --engine apple` runs it in the app (docs/e2e.md).

## What a run does with a clip

The WAV is converted once to what the microphone tap delivers — Float32 mono at 48 kHz,
in ~20 ms buffers — and fed to the real `AudioBufferWriter` and the session the app
would build (`StreamingRecognitionSession` wrapping `BatchRecognitionSession`, or the
upload alone). A streaming engine gets the buffers at the tap's pace; an upload or local
engine gets them at once, since its answer does not depend on it. The stop goes through
`InlineDictationFlow`, the same span layer and `InlineDelivery.stopResult` the app and
`DictationReplay` use, and what would have been pasted is judged:

- nothing pasted for a clip that should produce nothing, or is shorter than 0.3 s;
- something pasted for speech;
- no run of four words appearing more often than it was said (a restatement joined on as new speech);
- the word error rate within `maxWER`, when set;
- Ukrainian without Russian letters, English without Cyrillic. This catches an answer
  written in the wrong alphabet, not one Russian-spelled word inside Ukrainian — which
  is why each result also lists what it *misheard* (`привіт → привет`), for a reader;
- no two sentences glued at a segment boundary (`перевірка.Закінчую` — a letter straight
  after `.!?,` that `expected` does not hold that way);
- no known hallucination (`HallucinationFilter`) anywhere in the text that `expected`
  does not hold (`Перевірка. Дякую за перегляд.`): the filter drops only a short segment
  that is nothing but one.

Both runners register the spell-checked segment joins the app registers at launch
(`registerSpellCheckedJoins`), without which no word cut in two is ever glued and
`uk-cut-word` measures nothing.

Each cell of `summary.md` is `WER · first text on the overlay · stop to text`; ↩ marks a
streaming engine whose upload answered instead (the stream broke or came back empty),
❌ a failed check.

## Against the previous run

`maxWER` is one bound for every engine, so it is either loose for the strong ones or
red forever for the weak ones; a run is instead judged against the one before it. The
previous run is the latest one under `SPEECHTEXT_RUNS` (a folder with a
`results-*.json`) other than the run being written — and, when that run
is itself one of them (`SPEECHTEXT_RUN_DIR` adding to an earlier run), the last one
named before it. `summary.md` then opens with **Since `<that run>`**: each cell (clip ×
engine × pass) against the same cell there, listed per engine —

- **worse** (▼ in the tables): its word error rate rose by more than 0.10, as the table
  shows it, or it fails a check it passed (a check, not a message: `repeated` with other
  words is the same failure);
- **better** (▲): the reverse;
- **new**: a cell the previous run did not have. Never a regression;
- **not compared**: the clip itself changed — its `expected` text, or its recording (each
  result keeps both: the text and `audioDigest`, the first 16 hex digits of the WAV's
  SHA-256). A run from before they were kept still shows a changed text, by measuring its
  answer against today's; a re-recording with the same text it cannot see.

Nothing here fails the test: a cloud answer varies from run to run, so the list is for
the reader of the run, as the rest of the summary is. `maxWER` stays the one bound that
fails, for a clip that needs an absolute one.

A streaming run also writes its `DictationTrace` to `traces/`: a
regression found live becomes an offline test by copying that file into the
private traces folder (`scripts/import-trace.sh NAME FILE`) and setting
`expectedDocument`.

## The local model picks

A run of the local engines over the whole corpus rewrites `LocalModelMeasurements.swift`
(`CorpusMeasurementSummary`): for each model and clip language, the mean word error rate
of the speech clips' Auto pass and the median stop-to-text seconds of the warm pass after
it, on the same clips, with the run's date and the Mac. Auto is the first pass after the
runner swaps models, and that cost is not one a person with one model loaded pays. Summarize
on the Mac that ran it: the chip is read then, and rows from different Macs are not compared.
A narrowed run (`SPEECHTEXT_CLIPS`) leaves it alone, since its means would
cover fewer clips; a model the run did not have keeps its rows, under their own date.
`SpeechTextEvaluation --summarize-run <run-dir>` writes the same file from a finished run.
The diff is reviewed like any other: what it changes is in `LocalModelPickMatrixTests`.

`localSTTPick` chooses from those rows (docs/decisions.md › Tiers pick two models, and
candidates step down). `mixed` clips are in the file for a reader and in no pick, because
nobody states "mixed" as a language they speak.

## Recording a clip

- A quiet room, the microphone you dictate with, your normal voice.
- One file per clip, named after its description (`uk-pause.wav`; another recording of
  it `uk-pause@builtin.wav`). Start about half a
  second before speaking and stop half a second after — except the `uk-stop-on-…` clips,
  which stop *on* the last word, with no breath after it: that is what they test.
- A pause the `note` asks for lasts **2 s**. Scribe closes a segment only after 1.5 s of
  silence (`STTTuning.vadSilenceThresholdSeconds`), so a shorter pause tests nothing a
  segment boundary would.
- Noise clips (`noise-…`) hold no speech at all: no voices, no TV, no singing.
- Plus `room-tone.wav`: about three seconds of the room with nobody speaking. The
  silence clips name it as their `source` and take their `seconds` from its start, so
  none of them is a fraction of a second recorded by hand, which would hold nothing but
  the click of stopping.
- Say exactly the description's text; the `note` says where to pause, stumble or hurry.
- 16 kHz mono WAV. Anything else converts with
  `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a uk-pause.wav` (QuickTime Player's
  File › New Audio Recording saves `.m4a`).
- A new clip is a description plus a recording; the tables grow a row.
