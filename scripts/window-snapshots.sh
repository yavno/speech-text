#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Draws the app's windows in every language it has, to look the translations over, or
# only the ones a pull request needs to show.
#
#   scripts/window-snapshots.sh [--no-build] [--languages "en es uk"] [--double-length]
#                               [--only "setup-speech settings-general"] [--defaults f.plist]
#
# Builds Debug, stamps a copy as the end-to-end build (app.speech-text.SpeechText.e2e: its
# own preferences and data folder, never the user's — see E2EMode), and launches it once
# per language with -AppleLanguages and -SPTSnapshots. With --double-length, once more in
# English with every string doubled (-NSDoubleLocalizedStrings), a stress test for room
# that a longer language would need; its windows show each text twice on purpose, so it
# is not part of the usual run. Each launch opens Setup's steps, the main window's pages, Settings'
# categories and the Record Window, and this script captures each window by its number
# (screencapture -l: that window alone, never the rest of the screen), so the terminal
# needs the Screen Recording grant; without it the app draws them itself, and the main
# window's page comes out blank. The windows flash on screen meanwhile. index.html puts
# the languages side by side.
#
# --only takes the names of the pictures a full run writes (setup-speech, main-home,
# settings-general, record-window), separated by spaces or commas; a name ending in "-"
# takes every one that starts with it (setup- for all of Setup's steps). The app then
# opens those windows and no other. A name that matches no window stops the run and lists
# the names there are. For a pull request's screenshot:
#   scripts/window-snapshots.sh --languages en --only settings-speech
#
# Every launch starts from empty settings: the e2e domain is deleted first. --defaults
# imports a property list into it after that (defaults import), so a picture can show a
# stored state, such as a chosen server; write one with
#   defaults export app.speech-text.SpeechText.e2e f.plist
# after setting it up in an e2e build, or by hand (docs/settings-keys.md names the keys).
# The user's own domain is never read or written. API keys are refused: they live in the
# keychain, and an e2e run takes them only from -SPTKeysFile (scripts/e2e.sh).
#
# Output: /tmp/speechtext-snapshots/<time>/ (SPT_SNAPSHOTS_OUT changes it; its language
# folders are replaced). Needs a logged-in session; never CI. Exits 1, after writing
# index.html, when a run was cut short or a window could not be captured; 2 for a wrong
# argument, an --only name that matches no window or a --defaults file it will not take.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="app.speech-text.SpeechText.e2e"
DD="${SPT_SNAPSHOTS_DERIVED_DATA:-/tmp/st-dd-snapshots}"
OUT="${SPT_SNAPSHOTS_OUT:-/tmp/speechtext-snapshots/$(date +%Y-%m-%d_%H-%M-%S)}"
LANGUAGES="en es uk"
BUILD=1
DOUBLE=0
ONLY=""
ONLY_GIVEN=0
DEFAULTS=""

while [ $# -gt 0 ]; do
  case $1 in
    --no-build) BUILD=0 ;;
    --double-length) DOUBLE=1 ;;
    --languages) LANGUAGES=$2; shift ;;
    --only) ONLY=$2; ONLY_GIVEN=1; shift ;;
    --defaults) DEFAULTS=$2; shift ;;
    -h|--help) sed -n '4,41p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ONLY_GIVEN" -eq 1 ] && [ -z "${ONLY//[ ,]/}" ]; then
  echo "--only needs at least one window name (setup-speech, settings-, …)" >&2; exit 2
fi
if [ -n "$DEFAULTS" ]; then
  [ -f "$DEFAULTS" ] || { echo "--defaults: no file at $DEFAULTS" >&2; exit 2; }
  # A dictionary at the top, as defaults import takes: a lone word is a property list too.
  /usr/bin/plutil -convert xml1 -o - "$DEFAULTS" 2>/dev/null | grep -qxE '<dict/?>' \
    || { echo "--defaults: $DEFAULTS is not a property list of settings" >&2; exit 2; }
  # Every key setting's name ends in APIKey (SettingsKeys). A key in the preferences domain
  # would be taken for a newer one than the keychain holds; this run never takes keys.
  if /usr/bin/plutil -p "$DEFAULTS" | grep -qE '"[^"]*APIKey" =>'; then
    echo "--defaults: $DEFAULTS holds an API key; leave keys out (they are never written here)" >&2; exit 2
  fi
fi
ONLY_ARGS=()
if [ "$ONLY_GIVEN" -eq 1 ]; then ONLY_ARGS=(-SPTSnapshotsOnly "$ONLY"); fi

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

PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS$1"$'\n'; echo "  $1" >&2; }

run() {  # name, extra arguments…
  local name=$1; shift
  echo "Drawing ${name}…"
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  if [ -n "$DEFAULTS" ]; then defaults import "$DOMAIN" "$DEFAULTS"; fi
  # A picture left by an earlier run would pass for this one's.
  rm -rf "${OUT:?}/$name"
  mkdir -p "$OUT/$name"
  "$APP/Contents/MacOS/SpeechText" "$@" ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} -SPTSnapshots "$OUT/$name" >/dev/null 2>&1 &
  local pid=$! start=$SECONDS request id status=0
  # The app names each window it has open (<snapshot>.window) and waits for its picture:
  # screencapture -l takes that window alone, nothing else on the screen.
  while kill -0 "$pid" 2>/dev/null; do
    for request in "$OUT/$name"/*.window; do
      [ -e "$request" ] || continue
      id=$(cat "$request")
      screencapture -x -o -l "$id" "${request%.window}.png" 2>/dev/null || true
      # The app then draws this one itself, and a main-window page comes out blank.
      [ -e "${request%.window}.png" ] || problem "$name/$(basename "${request%.window}"): not captured, the app drew it (Screen Recording grant?)"
      rm -f "$request"
    done
    sleep 0.2
    if [ $((SECONDS - start)) -ge 180 ]; then kill "$pid" 2>/dev/null || true; problem "$name: timed out, its windows are incomplete"; break; fi
  done
  wait "$pid" 2>/dev/null || status=$?
  # Written in place of any picture when an --only name matches no window.
  if [ -e "$OUT/$name/only.unknown" ]; then
    {
      echo "--only: no window is named $(sed -n 1p "$OUT/$name/only.unknown")"
      echo "The names are: $(sed -n 2p "$OUT/$name/only.unknown")"
      echo "A name ending in - takes every one that starts with it, such as setup-."
    } >&2
    rm -rf "${OUT:?}/$name"
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    exit 2
  fi
  for request in "$OUT/$name"/*.missing; do
    [ -e "$request" ] || continue
    problem "$name/$(basename "${request%.missing}"): its window was not open"
    rm -f "$request"
  done
  # 143 is the timeout's own kill, already reported.
  if [ "$status" -ne 0 ] && [ "$status" -ne 143 ]; then problem "$name: the app exited with $status, its windows are incomplete"; fi
  return 0
}

columns=""
for lang in $LANGUAGES; do
  run "$lang" -AppleLanguages "($lang)"
  columns="$columns $lang"
done
if [ "$DOUBLE" -eq 1 ]; then
  run double-length -AppleLanguages "(en)" -NSDoubleLocalizedStrings YES
  columns="$columns double-length"
fi
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

# One row per window that any language has, one column per language. A long page runs to
# more screens in a longer language, so a missing cell is not by itself a problem.
names=$(for c in $columns; do
  for f in "$OUT/$c"/*.png; do [ -e "$f" ] && basename "$f" .png; done
done | sort -u)
{
  echo '<!doctype html><meta charset="utf-8"><title>SpeechText windows</title>'
  echo '<style>body{font:13px -apple-system,sans-serif;margin:16px;background:#f4f4f4}'
  echo 'table{border-collapse:collapse}td,th{vertical-align:top;padding:6px;text-align:left}'
  echo 'img{width:520px;border:1px solid #ccc;background:#fff}.none{color:#888}'
  echo '.problems{background:#fff3cd;padding:8px 12px;white-space:pre-wrap}</style>'
  if [ -n "$PROBLEMS" ]; then printf '<div class=problems><b>Incomplete run</b>\n%s</div>\n' "$PROBLEMS"; fi
  # What a reader needs to take the same pictures again.
  if [ "$ONLY_GIVEN" -eq 1 ]; then echo "<p>Only the windows <code>--only \"$ONLY\"</code> names.</p>"; fi
  if [ -n "$DEFAULTS" ]; then echo "<p>Settings imported from <code>--defaults $(basename "$DEFAULTS")</code>.</p>"; fi
  echo '<table><tr><th></th>'
  for c in $columns; do echo "<th>$c</th>"; done
  echo '</tr>'
  for name in $names; do
    echo "<tr><th>$name</th>"
    for c in $columns; do
      if [ -e "$OUT/$c/$name.png" ]; then
        echo "<td><a href=\"$c/$name.png\"><img src=\"$c/$name.png\" loading=lazy></a></td>"
      else
        echo '<td class=none>Not in this language</td>'
      fi
    done
    echo '</tr>'
  done
  echo '</table>'
} > "$OUT/index.html"

echo "Wrote $OUT/index.html"
if [ -n "$PROBLEMS" ]; then
  printf 'Incomplete run:\n%s' "$PROBLEMS" >&2
  exit 1
fi
