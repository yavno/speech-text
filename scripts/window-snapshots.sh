#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Draws the app's windows in every language it has, to look the translations over.
#
#   scripts/window-snapshots.sh [--no-build] [--languages "en es uk"]
#
# Builds Debug, stamps a copy as the end-to-end build (app.speech-text.SpeechText.e2e: its
# own preferences and data folder, never the user's — see E2EMode), and launches it once
# per language with -AppleLanguages and -SPTSnapshots, plus once in the double-length
# pseudolanguage (-NSDoubleLocalizedStrings), which shows where English longer by half
# would not fit. Each launch opens Setup's steps, the main window's pages, Settings'
# categories and the Record Window, and this script captures each window by its number
# (screencapture -l: that window alone, never the rest of the screen), so the terminal
# needs the Screen Recording grant; without it the app draws them itself, and the main
# window's page comes out blank. The windows flash on screen meanwhile. index.html puts
# the languages side by side.
#
# Output: /tmp/speechtext-snapshots/<time>/ (SPT_SNAPSHOTS_OUT changes it). Needs a
# logged-in session; never CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="app.speech-text.SpeechText.e2e"
DD="${SPT_SNAPSHOTS_DERIVED_DATA:-/tmp/st-dd-snapshots}"
OUT="${SPT_SNAPSHOTS_OUT:-/tmp/speechtext-snapshots/$(date +%Y-%m-%d_%H-%M-%S)}"
LANGUAGES="en es uk"
BUILD=1

while [ $# -gt 0 ]; do
  case $1 in
    --no-build) BUILD=0 ;;
    --languages) LANGUAGES=$2; shift ;;
    -h|--help) sed -n '4,19p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

APP="$DD/snapshots/SpeechText.app"
mkdir -p "$OUT" "$DD/snapshots"

if [ "$BUILD" -eq 1 ]; then
  echo "Building Debug into ${DD}…"
  xcodebuild build -project "$REPO_ROOT/SpeechText/SpeechText.xcodeproj" -scheme SpeechText \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO -quiet > "$DD/build.log" 2>&1 || { tail -30 "$DD/build.log" >&2; exit 1; }
fi
rm -rf "$APP"
ditto "$DD/Build/Products/Debug/SpeechText.app" "$APP"
/usr/bin/plutil -replace CFBundleIdentifier -string "$DOMAIN" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null

run() {  # name, extra arguments…
  local name=$1; shift
  echo "Drawing ${name}…"
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  mkdir -p "$OUT/$name"
  "$APP/Contents/MacOS/SpeechText" "$@" -SPTSnapshots "$OUT/$name" >/dev/null 2>&1 &
  local pid=$! start=$SECONDS request id
  # The app names each window it has open (<snapshot>.window) and waits for its picture:
  # screencapture -l takes that window alone, nothing else on the screen.
  while kill -0 "$pid" 2>/dev/null; do
    for request in "$OUT/$name"/*.window; do
      [ -e "$request" ] || continue
      id=$(cat "$request")
      screencapture -x -o -l "$id" "${request%.window}.png" 2>/dev/null || true
      rm -f "$request"
    done
    sleep 0.2
    if [ $((SECONDS - start)) -ge 180 ]; then kill "$pid" 2>/dev/null || true; echo "  $name timed out" >&2; break; fi
  done
}

columns=""
for lang in $LANGUAGES; do
  run "$lang" -AppleLanguages "($lang)"
  columns="$columns $lang"
done
run double-length -AppleLanguages "(en)" -NSDoubleLocalizedStrings YES
columns="$columns double-length"
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

# One row per window, one column per language.
{
  echo '<!doctype html><meta charset="utf-8"><title>SpeechText windows</title>'
  echo '<style>body{font:13px -apple-system,sans-serif;margin:16px;background:#f4f4f4}'
  echo 'table{border-collapse:collapse}td,th{vertical-align:top;padding:6px;text-align:left}'
  echo 'img{width:520px;border:1px solid #ccc;background:#fff}</style><table><tr><th></th>'
  for c in $columns; do echo "<th>$c</th>"; done
  echo '</tr>'
  first=${columns%% *}; first=${first:-en}
  for f in "$OUT/$(echo $columns | cut -d' ' -f1)"/*.png; do
    name=$(basename "$f" .png)
    echo "<tr><th>$name</th>"
    for c in $columns; do echo "<td><a href=\"$c/$name.png\"><img src=\"$c/$name.png\" loading=lazy></a></td>"; done
    echo '</tr>'
  done
  echo '</table>'
} > "$OUT/index.html"

echo "Wrote $OUT/index.html"
