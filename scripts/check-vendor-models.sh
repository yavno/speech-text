#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compares the app's model catalogues with what each vendor serves now and prints a
# Markdown report: catalogue models a vendor no longer serves, shutdowns a vendor's API
# announces, retired models whose retention is over, prices that differ from an API that
# states them, language lists that changed at their source, new vendor models, newer
# FluidAudio / WhisperKit releases and changed Hugging Face repositories, what each vendor's
# deprecation page says about the catalogue's models, and the new lines on its changelog.
# docs/vendor-watch.md describes it.
#
#   scripts/check-vendor-models.sh [--catalogue <file>] [--out <file>] [--json <file>] [--since yyyy-mm-dd]
#
# --catalogue  a `SpeechTextEvaluation --export-catalogue` file; without it the tool is
#              built (Release, in $SPEECHTEXT_DERIVED_DATA, default /tmp/st-dd-evaluation)
#              and the catalogues of this checkout are exported.
# --json       also write the findings as JSON, for filing issues.
# --since      what counts as new; default: the previous snapshot's day, else a week ago.
#
# Keys come from ~/.config/speech-text/test-keys.env (OPENAI_API_KEY, GROQ_API_KEY,
# ELEVENLABS_API_KEY, ANTHROPIC_API_KEY — $SPEECHTEXT_KEYS names another file) or the
# environment, and never appear on a command line or in the report. A vendor without a
# key is "not checked", never an all-clear.
#
# SPEECHTEXT_VENDOR_WATCH=<dir> keeps each run's vendor lists in <dir>/snapshots/, so the
# next run can tell which models are new, and a copy of each vendor page whose new lines it
# reports. It must be outside the repository.
#
# Exit status: 0 nothing blocks a release, 1 the release rule fails (docs/releasing.md),
# 2 the export could not be built, 3 some vendor (or its deprecation page) was not checked.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
project="$repo/SpeechText/SpeechText.xcodeproj"
resolved="$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
derived="${SPEECHTEXT_DERIVED_DATA:-/tmp/st-dd-evaluation}"
keys="${SPEECHTEXT_KEYS:-$HOME/.config/speech-text/test-keys.env}"

catalogue="" out="" json="" since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --catalogue) catalogue="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --json) json="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    -h|--help) sed -n '5,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 64 ;;
  esac
done

snapshots=()
if [ -n "${SPEECHTEXT_VENDOR_WATCH:-}" ]; then
  mkdir -p "$SPEECHTEXT_VENDOR_WATCH/snapshots"
  watch="$(cd "$SPEECHTEXT_VENDOR_WATCH" && pwd)"
  case "$watch/" in
    "$repo/"*) echo "SPEECHTEXT_VENDOR_WATCH is inside the repository: runs are kept outside it" >&2; exit 64 ;;
  esac
  snapshots=(--snapshots "$watch/snapshots")
fi

commit="$(git -C "$repo" rev-parse --short HEAD)"
git -C "$repo" diff --quiet HEAD -- SpeechText || commit="$commit+uncommitted"

if [ -z "$catalogue" ]; then
  catalogue="$(mktemp -t speechtext-catalogue).json"
  trap 'rm -f "$catalogue"' EXIT
  echo "▸ Building SpeechTextEvaluation to export the catalogues…" >&2
  xcodebuild build -project "$project" -scheme SpeechTextEvaluation -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$derived" >"$catalogue.log" 2>&1 \
    || { echo "build failed — see $catalogue.log" >&2; exit 2; }
  rm -f "$catalogue.log"
  "$derived/Build/Products/Release/SpeechTextEvaluation" --export-catalogue "$catalogue"
fi

args=(--catalogue "$catalogue" --resolved "$resolved" --keys "$keys" --commit "$commit")
[ -n "$out" ] && args+=(--out "$out")
[ -n "$json" ] && args+=(--json "$json")
[ -n "$since" ] && args+=(--since "$since")
# A python.org Python has no CA certificates of its own until its "Install Certificates"
# step runs; the system's bundle serves every vendor here.
if [ -z "${SSL_CERT_FILE:-}" ] && [ -f /etc/ssl/cert.pem ]; then export SSL_CERT_FILE=/etc/ssl/cert.pem; fi
echo "▸ Asking the vendors…" >&2
python3 -I "$repo/scripts/vendor-watch/check.py" "${args[@]}" ${snapshots[@]+"${snapshots[@]}"}
