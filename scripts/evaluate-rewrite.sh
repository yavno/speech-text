#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Measures AI Rewrite: the rewrite fixtures through the app's own prompt, client and
# parser on cloud and local chat models, judged by the text checks — the baseline every
# prompt change is compared with (RewriteEvaluation.swift). Writes one run folder under
# $SPEECHTEXT_RUNS with rewrite-summary.md and rewrite-results.json; SPEECHTEXT_RUNS
# must be outside the repository, since fixtures may be taken from real dictations.
#
#   SPEECHTEXT_RUNS=<runs-dir> scripts/evaluate-rewrite.sh [extra flags…]
#
#   --engines groq/openai/gpt-oss-120b,anthropic/claude-haiku-5-5,…   (default: the six of #114)
#   --fixtures id,…        --repeat n        --judge provider/model,…
#   --reasoning-effort default|omit|<value>  --variant 2026-11|current  --concurrency n
#
# Keys: GROQ_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY from the environment, or else from
# ~/.config/speech-text/test-keys.env. A model on this Mac needs SPEECHTEXT_LLM_MODELS, the
# folder of its GGUF file (or the app's Models folder). Optional: SPEECHTEXT_REWRITE_FIXTURES
# for another fixtures file — a private one of real dictations, say.
#
# The checks are held to the fixtures' examples first (--self-check); a check that
# misjudges one stops the run.
set -euo pipefail

if [ -z "${SPEECHTEXT_RUNS:-}" ]; then
  sed -n '5,21p' "$0" | sed 's/^# \{0,1\}//'
  echo "SPEECHTEXT_RUNS must name the folder runs are kept in, outside the repository" >&2
  exit 64
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$SPEECHTEXT_RUNS"
runs="$(cd "$SPEECHTEXT_RUNS" && pwd)"
case "$runs/" in
  "$repo/"*) echo "SPEECHTEXT_RUNS is inside the repository" >&2; exit 64 ;;
esac
fixtures="${SPEECHTEXT_REWRITE_FIXTURES:-$repo/SpeechText/SpeechTextTests/Rewrite/rewrite-fixtures.json}"

keys="$HOME/.config/speech-text/test-keys.env"
if [ -f "$keys" ]; then
  while IFS='=' read -r name value; do
    case "$name" in
      GROQ_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)
        [ -z "${!name:-}" ] && export "$name=$value" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$keys")
fi

derived=/tmp/st-dd-evaluation
echo "▸ Building SpeechTextEvaluation…"
xcodebuild build -project "$repo/SpeechText/SpeechText.xcodeproj" -scheme SpeechTextEvaluation -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" >"$runs/evaluation-build.log" 2>&1 \
  || { echo "build failed — see $runs/evaluation-build.log" >&2; exit 1; }
tool="$derived/Build/Products/Release/SpeechTextEvaluation"

echo "▸ Checking the checks…"
"$tool" --self-check "$fixtures"

args=(--rewrite "$fixtures" --runs "$runs")
[ -n "${SPEECHTEXT_LLM_MODELS:-}" ] && args+=(--models "$SPEECHTEXT_LLM_MODELS")
echo "▸ Rewriting…"
"$tool" "${args[@]}" "$@"
