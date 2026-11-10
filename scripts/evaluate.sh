#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the audio corpus through every speech engine and writes one run folder,
# $SPEECHTEXT_RUNS/<date>/: summary.md (the engine × clip table), results-*.json and
# the streaming engines' traces. SPEECHTEXT_RUNS must be outside the repository: a run
# holds what the engines heard in someone's voice, so it is never committed.
#
#   SPEECHTEXT_RUNS=<runs-dir> ELEVENLABS_API_KEY=… OPENAI_API_KEY=… GROQ_API_KEY=… \
#     scripts/evaluate.sh <corpus-dir>            every engine, cloud and local
#   scripts/evaluate.sh <corpus-dir> --cloud      cloud engines only
#   scripts/evaluate.sh <corpus-dir> --local      local engines only (no keys needed)
#
# <corpus-dir> holds <clip>.wav for the descriptions in SpeechText/SpeechTextTests/Audio/.
# The audio stays out of the repository: it is someone's voice.
#
# Keys are read from this environment only, never from the app's settings — they may be
# other keys than the app's. An engine without its key is a "no key" row, not a failure.
# Optional: SPEECHTEXT_ENGINES=openAI/gpt-live-transcribe,… and SPEECHTEXT_CLIPS=a,b.
#
# A run of the local engines over the whole corpus also rewrites the committed
# LocalModelMeasurements.swift: WER and latency per model and language, no transcripts.
#
# The cloud half costs cents and takes about as long as the clips; the local half needs
# the models installed (Settings › Local), and a model's first load after a build may
# take minutes — it is reported apart from the stop-to-text time.
set -euo pipefail

if [ $# -lt 1 ]; then
  sed -n '5,27p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

corpus="$(cd "$1" && pwd)"
mode="${2:-all}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
# SPEECHTEXT_RUN_DIR=<an earlier run> adds to it: the clips run now replace their own
# rows, every other row stays — a clip recorded after a run needs no second full run.
if [ -n "${SPEECHTEXT_RUN_DIR:-}" ]; then
  runs="$(dirname "$SPEECHTEXT_RUN_DIR")"
elif [ -n "${SPEECHTEXT_RUNS:-}" ]; then
  runs="$SPEECHTEXT_RUNS"
else
  echo "SPEECHTEXT_RUNS must name the folder runs are kept in, outside the repository" >&2
  exit 64
fi
mkdir -p "$runs"
runs="$(cd "$runs" && pwd)"
case "$runs/" in
  "$repo/"*) echo "SPEECHTEXT_RUNS is inside the repository: a run holds someone's voice as text" >&2; exit 64 ;;
esac
run_dir="${SPEECHTEXT_RUN_DIR:-$runs/$(date +%Y-%m-%d_%H-%M)}"
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
derived=/tmp/st-dd-evaluation
project="$repo/SpeechText/SpeechText.xcodeproj"
mkdir -p "$run_dir"
status=0

# Both halves run through the SpeechTextEvaluation tool: unlike the test bundle it links
# FluidAudio, so it loads the voice activity detector and judges the cloud engines'
# segments as the app does. LiveProviderTests stays for a quick cloud run without it.
echo "▸ Building SpeechTextEvaluation…"
xcodebuild build -project "$project" -scheme SpeechTextEvaluation -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" >"$run_dir/evaluation-build.log" 2>&1 \
  || { echo "build failed — see $run_dir/evaluation-build.log" >&2; exit 1; }
args=(--corpus "$corpus" --runs "$runs" --run-dir "$run_dir")
case "$mode" in
  --cloud) args+=(--cloud --no-local) ;;
  --local) ;;
  *) args+=(--cloud) ;;
esac
[ -n "${SPEECHTEXT_ENGINES:-}" ] && args+=(--engines "$SPEECHTEXT_ENGINES")
[ -n "${SPEECHTEXT_CLIPS:-}" ] && args+=(--clips "$SPEECHTEXT_CLIPS")
echo "▸ Engines…"
"$derived/Build/Products/Release/SpeechTextEvaluation" "${args[@]}" | tee "$run_dir/evaluation.log" || status=1

# Not with SPEECHTEXT_CLIPS: a row's WER is the mean over a language's clips, and a
# narrowed run would replace it with a mean over fewer. A failed check still measured.
if [ "$mode" != "--cloud" ] && [ -z "${SPEECHTEXT_CLIPS:-}" ]; then
  "$derived/Build/Products/Release/SpeechTextEvaluation" --summarize-run "$run_dir" || status=1
fi

echo
echo "Summary: $run_dir/summary.md"
exit $status
