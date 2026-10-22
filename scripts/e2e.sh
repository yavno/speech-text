#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end runs with no person: a debug build whose microphone is a corpus clip
# (-SPTAudioInput, E2EMode.swift), driven through its real global shortcuts with key
# events this script posts, pasting into real documents that AppleScript reads back.
#
#   scripts/e2e.sh --setup                 build, launch once, say which permissions to give
#   scripts/e2e.sh                         every scenario, on the Groq upload engine
#   scripts/e2e.sh --engine scribe-realtime --only plain,hold
#   scripts/e2e.sh --list                  the scenarios
#
# Options: --engine groq|scribe-realtime|gpt-live|apple  --only a,b  --traces
#          (Debug Log › Record traces on)  --no-build  --keep (leave the
#          documents open)
#
# Environment: SPEECHTEXT_CORPUS (the folder of corpus WAVs, outside the repository;
# required), SPT_E2E_KEYS (default ~/.config/speech-text/test-keys.env),
# SPT_E2E_DERIVED_DATA (default /tmp/st-dd-e2e), SPT_E2E_OUT (default
# /tmp/speechtext-e2e/<time>), SPT_SIGN_IDENTITY (default: the Developer ID certificate).
#
# Isolation, as decided with the harness: the build is stamped app.speech-text.SpeechText.e2e, so
# it has its own preferences domain (reset before every scenario) and its own data folder
# (Application Support/SpeechText-e2e); the API keys come from the key file into memory
# only; the installed SpeechText is quit for the run and reopened afterwards, Ctrl-C
# included. Needs a logged-in session — never CI.
#
# Verdicts are structural (check.py): pasted once, after the stop, into the document the
# script opened; a cancel leaves it empty; an edit replaces the selection. WER is shown,
# never judged.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E_DIR="$REPO_ROOT/scripts/e2e"
DOMAIN="app.speech-text.SpeechText.e2e"
INSTALLED_ID="app.speech-text.SpeechText"
DD="${SPT_E2E_DERIVED_DATA:-/tmp/st-dd-e2e}"
WORK="$DD/e2e"
APP="$WORK/SpeechText.app"
KEYS_FILE="${SPT_E2E_KEYS:-$HOME/.config/speech-text/test-keys.env}"
CORPUS="${SPEECHTEXT_CORPUS:-}"
CLIPS_JSON="$REPO_ROOT/SpeechText/SpeechTextTests/Audio"
DATA="$HOME/Library/Application Support/SpeechText-e2e"
OUT="${SPT_E2E_OUT:-/tmp/speechtext-e2e/$(date +%Y-%m-%d_%H-%M-%S)}"
KEYS="$WORK/keys"

ALL_SCENARIOS="plain hold double-tap tap-cancels ai switch-to-ai switch-to-plain esc-cancel two-in-a-row switch-app stream-drop apple-error edit smoke-plain-text smoke-script-editor"

ENGINE="groq"; ONLY=""; TRACES=0; BUILD=1; SETUP=0; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --traces) TRACES=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --setup) SETUP=1; shift ;;
        --keep) KEEP=1; shift ;;
        --list) echo "$ALL_SCENARIOS" | tr ' ' '\n'; exit 0 ;;
        -h|--help) sed -n '5,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

die() { printf '%s\n' "$*" >&2; exit 1; }

case "$ENGINE" in
    groq|scribe-realtime|gpt-live|apple) ;;
    *) die "unknown engine $ENGINE (groq, scribe-realtime, gpt-live, apple)" ;;
esac
[ -f "$KEYS_FILE" ] || die "no key file at $KEYS_FILE (GROQ_API_KEY=…, OPENAI_API_KEY=…, ELEVENLABS_API_KEY=…)"
[ -n "$CORPUS" ] || die "SPEECHTEXT_CORPUS must name the folder of corpus WAVs"
[ -d "$CORPUS" ] || die "no corpus at $CORPUS — set SPEECHTEXT_CORPUS"

mkdir -p "$WORK" "$OUT"

# MARK: Build

build() {
    echo "Building Debug into ${DD}…"
    xcodebuild build -project "$REPO_ROOT/SpeechText/SpeechText.xcodeproj" -scheme SpeechText \
        -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DD" \
        > "$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log" >&2; die "build failed — $WORK/build.log"; }
    rm -rf "$APP"
    ditto "$DD/Build/Products/Debug/SpeechText.app" "$APP"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$DOMAIN" "$APP/Contents/Info.plist"

    # Signed with a stable identity, so one Accessibility grant survives every rebuild —
    # an ad-hoc signature is a new app to TCC each time. Never with the keychain profile:
    # this build keeps its keys in memory.
    local identity="${SPT_SIGN_IDENTITY:-}"
    if [ -z "$identity" ]; then
        identity="$(security find-identity -v -p codesigning 2>/dev/null |
            sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    fi
    local nested
    if [ -n "$identity" ]; then
        echo "Signing with \"$identity\"."
        while IFS= read -r -d '' nested; do
            codesign --force --options runtime --sign "$identity" "$nested" >> "$WORK/sign.log" 2>&1
        done < <(find "$APP/Contents" -depth -mindepth 2 \
            \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.app' \
               -o -name '*.xpc' -o -name 'Autoupdate' \) -print0)
        codesign --force --options runtime --preserve-metadata=entitlements,flags \
            --sign "$identity" "$APP" >> "$WORK/sign.log" 2>&1 || die "signing failed — $WORK/sign.log"
    else
        echo "No Developer ID certificate: signing ad-hoc. Accessibility has to be given again after every build."
        local entitlements="$WORK/entitlements.plist"
        codesign -d --entitlements - --xml "$APP" > "$entitlements" 2>/dev/null
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements" 2>/dev/null || true
        codesign --force --deep --options runtime --entitlements "$entitlements" --sign - "$APP" >> "$WORK/sign.log" 2>&1 ||
            die "signing failed — $WORK/sign.log"
    fi
}

if [ "$BUILD" -eq 1 ] || [ ! -d "$APP" ]; then build; fi
swiftc -O "$E2E_DIR/keys.swift" -o "$KEYS" 2> "$WORK/keys-build.log" || die "could not build the key helper — $WORK/keys-build.log"

# MARK: The installed app, and cleaning up

e2e_pids() { pgrep -f "$APP/Contents/MacOS/SpeechText" 2>/dev/null || true; }

INSTALLED_PATHS=()
stop_installed() {
    local pid path
    for pid in $(pgrep -x SpeechText 2>/dev/null || true); do
        path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        case "$path" in "$APP"/*|"") continue ;; esac
        INSTALLED_PATHS+=("${path%/Contents/MacOS/*}")
    done
    [ ${#INSTALLED_PATHS[@]} -eq 0 ] && return 0
    echo "Quitting the installed SpeechText for the run (it is reopened at the end)."
    osascript -e "tell application id \"$INSTALLED_ID\" to quit" > /dev/null 2>&1 || true
    for _ in $(seq 20); do
        pgrep -x SpeechText > /dev/null 2>&1 || break
        sleep 0.3
    done
    for pid in $(pgrep -x SpeechText 2>/dev/null || true); do
        path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        case "$path" in "$APP"/*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
    done
}

LOG_PID=""
quit_e2e() {
    [ -n "$LOG_PID" ] && { kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; LOG_PID=""; }
    local pid
    for pid in $(e2e_pids); do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 20); do [ -z "$(e2e_pids)" ] && break; sleep 0.2; done
    for pid in $(e2e_pids); do kill -9 "$pid" 2>/dev/null || true; done
}

OPEN_DOCS=()   # "app|handle" — see new_doc
cleanup() {
    quit_e2e
    if [ "$KEEP" -eq 0 ]; then
        local doc app name
        for doc in "${OPEN_DOCS[@]+"${OPEN_DOCS[@]}"}"; do
            app="${doc%%|*}"; name="${doc#*|}"
            if [ "$app" = "TextEdit" ]; then
                osascript -e 'on run argv' -e 'tell application "TextEdit" to close document of window id ((item 1 of argv) as integer) saving no' \
                    -e 'end run' "$name" > /dev/null 2>> "$OUT/harness.log" || true
            else
                # By name, not `every document whose name is`: Script Editor ignores that
                # form silently, and a document left open can share a later one's name.
                osascript -e 'on run argv' -e 'tell application (item 1 of argv) to close document (item 2 of argv) saving no' \
                    -e 'end run' "$app" "$name" > /dev/null 2>> "$OUT/harness.log" || true
            fi
        done
    fi
    local path
    for path in "${INSTALLED_PATHS[@]+"${INSTALLED_PATHS[@]}"}"; do
        open "$path" && echo "Reopened $path."
    done
}

# MARK: Settings and launch

# The scenario's settings in a domain that starts empty every time. Setup and the login
# item are marked done, or a fresh domain would open setup and register this build.
prepare_domain() {  # prepare_domain [key type value]...
    defaults delete "$DOMAIN" > /dev/null 2>&1 || true
    defaults write "$DOMAIN" onboardingCompleted -bool YES
    defaults write "$DOMAIN" hasRegisteredLaunchAtLogin -bool YES
    defaults write "$DOMAIN" microphoneNoticeShown -bool YES
    defaults write "$DOMAIN" holdTipFollowedCount -int 99
    defaults write "$DOMAIN" homeIntroHidden -bool YES
    defaults write "$DOMAIN" recordDictationTraces -bool "$([ "$TRACES" -eq 1 ] && echo YES || echo NO)"
    case "$ENGINE" in
        groq) defaults write "$DOMAIN" sttProvider -string groq ;;
        apple) defaults write "$DOMAIN" sttProvider -string apple ;;
        scribe-realtime)
            defaults write "$DOMAIN" sttProvider -string elevenlabs
            defaults write "$DOMAIN" elevenLabsModel -string scribe_v2_realtime ;;
        gpt-live)
            defaults write "$DOMAIN" sttProvider -string openai
            defaults write "$DOMAIN" openAISTTModel -string gpt-live-transcribe ;;
    esac
    defaults write "$DOMAIN" llmProvider -string groq
    while [ $# -ge 3 ]; do
        defaults write "$DOMAIN" "$1" "-$2" "$3"
        shift 3
    done
}

clip_path() {  # clip_path <clip> — the corpus WAV, or a file made here
    case "$1" in /*) echo "$1" ;; *) echo "$CORPUS/$1.wav" ;; esac
}

clip_seconds() { afinfo "$(clip_path "$1")" | sed -n 's/estimated duration: \([0-9.]*\).*/\1/p'; }

clip_field() {  # clip_field <clip> <field>
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' \
        "$CLIPS_JSON/$1.json" "$2" 2>/dev/null || true
}

languages_for() {
    case "$(clip_field "$1" language)" in
        en) echo en ;; mixed) echo uk,en ;; *) echo uk ;;
    esac
}

LAUNCH_ARGS=()   # extra launch arguments for the next launch only
launch() {  # launch <scenario> <clip>[,<clip>…]
    local name="$1" inputs="" clip
    for clip in ${2//,/ }; do inputs="${inputs:+$inputs,}$(clip_path "$clip")"; done
    # Every dlog category is its own os.Logger category, so the whole subsystem is
    # streamed; --info leaves out the .debug lines, which no verdict reads.
    log stream --info --style compact \
        --predicate "subsystem == \"$DOMAIN\"" > "$OUT/$name.log" 2>&1 &
    LOG_PID=$!
    sleep 1
    # Through `open`, so launchd starts it and TCC asks about the app, not this shell.
    open -n "$APP" --args -SPTAudioInput "$inputs" -SPTKeysFile "$KEYS_FILE" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
    LAUNCH_ARGS=()
    for _ in $(seq 30); do [ -n "$(e2e_pids)" ] && break; sleep 0.2; done
    [ -n "$(e2e_pids)" ] || die "the e2e build did not start"
    # The hotkeys are registered during launch; the Debug Log says when it finished.
    sleep 2.5
}

# MARK: Documents

# A TextEdit document is known by its window's id, not its name. TextEdit reuses an
# untitled number as soon as it is free — three documents in a row can all be "Untitled 342"
# — and its `documents` list can lag behind its windows (an autosaved plain-text document
# stayed under another's name), so `document "Untitled N"` found nothing, or another
# document: the paste landed and the run read an empty one, and never closed it.
new_doc() {  # new_doc textedit|textedit-plain|script-editor [text] — prints "app|handle":
             # a window id for TextEdit, a document name for Script Editor
    local kind="$1" text="${2:-}" app name
    case "$kind" in
        textedit|textedit-plain) app="TextEdit" ;;
        script-editor) app="Script Editor" ;;
    esac
    if [ "$app" = "TextEdit" ]; then
        name="$(osascript -e 'on run argv' -e 'tell application "TextEdit"' -e 'activate' \
            -e 'set d to make new document with properties {text:(item 1 of argv)}' \
            -e 'set n to name of d' \
            -e 'return id of first window whose name is n and visible is true' \
            -e 'end tell' -e 'end run' "$text")"
    else
        name="$(osascript -e 'on run argv' -e 'tell application "Script Editor"' -e 'activate' \
            -e 'set d to make new document with properties {contents:(item 1 of argv)}' \
            -e 'return name of d' -e 'end tell' -e 'end run' "$text")"
    fi
    sleep 0.8
    [ "$kind" = "textedit-plain" ] && { "$KEYS" tap:cmd+shift+t sleep:0.5 > /dev/null; }
    echo "$app|$name"
}

doc_text() {  # doc_text "app|handle"
    local app="${1%%|*}" name="${1#*|}"
    # A lookup that fails reads as empty; its error goes to harness.log, so a scenario
    # that finds "nothing was pasted" says whether the document could be read at all.
    if [ "$app" = "TextEdit" ]; then
        osascript -e 'on run argv' -e 'tell application "TextEdit" to return text of document of window id ((item 1 of argv) as integer)' \
            -e 'end run' "$name" 2>> "$OUT/harness.log" || true
    else
        osascript -e 'on run argv' -e 'tell application "Script Editor" to return contents of document (item 1 of argv)' \
            -e 'end run' "$name" 2>> "$OUT/harness.log" || true
    fi
}

# Waits for the document to differ from what it held and then stay put for two seconds.
wait_for_change() {  # wait_for_change <doc> <initial> <timeout>
    local doc="$1" initial="$2" deadline=$((SECONDS + $3)) last="" stable=0 now
    while [ $SECONDS -lt $deadline ]; do
        now="$(doc_text "$doc")"
        if [ "$now" != "$initial" ]; then
            if [ "$now" = "$last" ]; then
                stable=$((stable + 1))
                [ $stable -ge 4 ] && return 0
            else
                stable=0
            fi
        fi
        last="$now"
        sleep 0.5
    done
    return 0
}

# MARK: Scenarios

RESULTS=()
FAILED=0

verdict() {  # verdict <scenario> <doc> [check.py options]
    local name="$1" doc="$2"; shift 2
    sleep 1
    doc_text "$doc" > "$OUT/$name.txt"
    quit_e2e
    cp "$DATA/history.json" "$OUT/$name.history.json" 2>/dev/null || echo "[]" > "$OUT/$name.history.json"
    local trace
    for trace in "$DATA"/Traces/*.json; do
        [ -f "$trace" ] || continue
        mkdir -p "$OUT/Traces"
        cp "$trace" "$OUT/Traces/$ENGINE-$name-$(basename "$trace")"
    done
    local row
    if row="$(python3 "$E2E_DIR/check.py" --name "$name" --doc "$OUT/$name.txt" --log "$OUT/$name.log" \
        --history "$OUT/$name.history.json" --app "${doc%%|*}" "$@")"; then :; else FAILED=$((FAILED + 1)); fi
    echo "$row"
    RESULTS+=("$row")
}

begin() {  # begin <scenario> <clips> [settings…]
    local name="$1" clips="$2"; shift 2
    echo
    echo "▶ $name ($ENGINE · ${clips//,/, })"
    rm -rf "$DATA"
    prepare_domain spokenLanguages string "$(languages_for "${clips%%,*}")" "$@"
    launch "$name" "$clips"
}

# Plain dictation with the toggle: press, the clip, press.
scenario_plain() {
    local clip=uk-pause dur doc
    dur="$(clip_seconds $clip)"
    begin plain $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict plain "$doc" --expected "$(clip_field $clip expected)" --pastes 1
}

# Hold to talk: the shortcut held for the clip, the stop on its release.
scenario_hold() {
    local clip=uk-pause dur doc
    dur="$(clip_seconds $clip)"
    begin hold $clip holdToTalk bool YES
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" down:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" up:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict hold "$doc" --expected "$(clip_field $clip expected)" --pastes 1
}

# Hold to talk, double tap: locks the dictation on hands-free until the next press.
scenario_double_tap() {
    local clip=uk-names dur doc
    dur="$(clip_seconds $clip)"
    begin double-tap $clip holdToTalk bool YES
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q sleep:0.12 tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict double-tap "$doc" --expected "$(clip_field $clip expected)" --pastes 1 --logged "→ lock"
}

# Hold to talk, a lone tap: cancelled once the double-tap window runs out.
scenario_tap_cancels() {
    local clip=uk-pause doc
    begin tap-cancels $clip holdToTalk bool YES
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q
    sleep 6
    verdict tap-cancels "$doc" --empty --pastes 0 --logged "cancelling mid-flight (tap)"
}

# Two dictations one after the other into the same document: the second is not glued
# onto the first (the trailing space AppState.deliver adds). Two clips, one per start.
scenario_two_in_a_row() {
    local first=uk-short second=uk-pause doc
    begin two-in-a-row "$first,$second"
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$(clip_seconds $first) + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    local between; between="$(doc_text "$doc")"
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$(clip_seconds $second) + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "$between" 40
    verdict two-in-a-row "$doc" --expected "$(clip_field $first expected) $(clip_field $second expected)" \
        --pastes 2 --spaced
}

# Started in one app, stopped in another: the text goes where the dictation ended.
scenario_switch_app() {
    local clip=uk-pause dur origin doc
    dur="$(clip_seconds $clip)"
    begin switch-app $clip
    doc="$(new_doc script-editor)"; OPEN_DOCS+=("$doc")
    origin="$(new_doc textedit)"; OPEN_DOCS+=("$origin")
    "$KEYS" tap:ctrl+shift+q sleep:2
    osascript -e 'tell application "Script Editor" to activate'
    "$KEYS" "sleep:$(echo "$dur - 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    doc_text "$origin" > "$OUT/switch-app.origin.txt"
    verdict switch-app "$doc" --expected "$(clip_field $clip expected)" --pastes 1 \
        --untouched "$OUT/switch-app.origin.txt" --logged "paste target: Script Editor (started in TextEdit)"
}

# AI Rewrite from the start: ⌃⇧A, the clip, ⌃⇧A — the rewrite is the one paste.
scenario_ai() {
    local clip=uk-pause dur doc
    dur="$(clip_seconds $clip)"
    begin ai $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+a "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+a
    wait_for_change "$doc" "" 60
    verdict ai "$doc" --expected "$(clip_field $clip expected)" --pastes 1 --refined
}

# Started in AI Rewrite, switched back to plain half-way, stopped by the plain shortcut:
# the dictation is pasted as said, with no rewrite.
scenario_switch_to_plain() {
    local clip=uk-pause dur half doc
    dur="$(clip_seconds $clip)"; half="$(echo "$dur / 2" | bc -l)"
    begin switch-to-plain $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+a "sleep:$half" tap:ctrl+shift+q "sleep:$(echo "$dur - $half + 1" | bc -l)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict switch-to-plain "$doc" --expected "$(clip_field $clip expected)" --pastes 1 --not-refined \
        --logged "switchTo(ai: false)"
}

# The stream's socket closed 4 s into the speech (-SPTCloseStreamAfter, debug builds
# only) and reopened by StreamReconnectPolicy; the segment that had the outage is
# pasted from the upload. A realtime engine only: the others have no stream to close.
scenario_stream_drop() {
    local clip=uk-plain dur doc
    case "$ENGINE" in
        scribe-realtime|gpt-live) ;;
        *) local row="| stream-drop | skipped | | | no stream on $ENGINE | |"
           echo "$row"; RESULTS+=("$row"); return 0 ;;
    esac
    dur="$(clip_seconds $clip)"
    LAUNCH_ARGS=(-SPTCloseStreamAfter 4)
    begin stream-drop $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 60
    verdict stream-drop "$doc" --expected "$(clip_field $clip expected)" --pastes 1 \
        --logged "closing the stream's socket now" --logged "reconnecting in" \
        --logged "stream dropped during the segment"
}

# Apple's recognition task failing 4 s after the first words (-SPTAppleFailAfter, debug
# builds only): the session starts a fresh chunk at once instead of at its 50 s rotation,
# so the 10 s of speech after the error is heard and pasted with the rest. The Debug Log
# must show the fresh chunk hearing words; without the rotation the paste would hold only
# what came before the error. The Apple engine only: the others have no chunks.
scenario_apple_error() {
    local clip=uk-plain dur doc
    case "$ENGINE" in
        apple) ;;
        *) local row="| apple-error | skipped | | | no Apple chunks on $ENGINE | |"
           echo "$row"; RESULTS+=("$row"); return 0 ;;
    esac
    dur="$(clip_seconds $clip)"
    LAUNCH_ARGS=(-SPTAppleFailAfter 4)
    begin apple-error $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict apple-error "$doc" --expected "$(clip_field $clip expected)" --pastes 1 \
        --logged "failing the Apple chunk now" --logged "chunk failed after text, rotating" \
        --logged "the chunk after an error rotation hears words"
}

# Started plain, switched to AI Rewrite half-way by the other shortcut, stopped by it.
scenario_switch_to_ai() {
    local clip=uk-pause dur half doc
    dur="$(clip_seconds $clip)"; half="$(echo "$dur / 2" | bc -l)"
    begin switch-to-ai $clip
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$half" tap:ctrl+shift+a "sleep:$(echo "$dur - $half + 1" | bc -l)" tap:ctrl+shift+a
    wait_for_change "$doc" "" 60
    verdict switch-to-ai "$doc" --expected "$(clip_field $clip expected)" --pastes 1 --refined --logged "switchTo(ai: true)"
}

# ⎋ while recording: nothing pasted.
scenario_esc_cancel() {
    local clip=uk-pause doc
    begin esc-cancel $clip escapeCancelsDictation bool YES
    doc="$(new_doc textedit)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q sleep:3 tap:escape
    sleep 6
    verdict esc-cancel "$doc" --empty --pastes 0 --logged "cancelling mid-flight (escape)"
}

# The Edit shortcut: the document's text selected, a spoken instruction, the rewrite in
# its place. The instruction is made with `say`, since the corpus holds dictations only.
scenario_edit() {
    local instruction="$WORK/instruction-translate-en.wav" dur doc original
    if [ ! -f "$instruction" ]; then
        say -v Samantha -o "$WORK/instruction.aiff" "Translate this into English." 2>/dev/null ||
            say -o "$WORK/instruction.aiff" "Translate this into English."
        afconvert -f WAVE -d LEF32@48000 -c 1 "$WORK/instruction.aiff" "$instruction"
    fi
    dur="$(clip_seconds "$instruction")"
    original="$(clip_field uk-pause expected)"
    begin edit "$instruction" spokenLanguages string uk,en
    doc="$(new_doc textedit "$original")"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:cmd+a sleep:0.4 tap:ctrl+shift+e "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+e
    wait_for_change "$doc" "$original" 60
    verdict edit "$doc" --edit --original "$original"
}

# The paste smoke matrix, for the apps AppleScript can read back.
scenario_smoke_plain_text() {
    local clip=uk-short dur doc
    dur="$(clip_seconds $clip)"
    begin smoke-plain-text $clip
    doc="$(new_doc textedit-plain)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict smoke-plain-text "$doc" --expected "$(clip_field $clip expected)" --pastes 1
}

scenario_smoke_script_editor() {
    local clip=uk-short dur doc
    dur="$(clip_seconds $clip)"
    begin smoke-script-editor $clip
    doc="$(new_doc script-editor)"; OPEN_DOCS+=("$doc")
    "$KEYS" tap:ctrl+shift+q "sleep:$(echo "$dur + 1" | bc)" tap:ctrl+shift+q
    wait_for_change "$doc" "" 40
    verdict smoke-script-editor "$doc" --expected "$(clip_field $clip expected)" --pastes 1
}

# MARK: Run

# Setup only launches the build, so macOS lists it under Accessibility; the installed
# app keeps running, and so does this one, until it is quit from its menu.
if [ "$SETUP" -eq 1 ]; then
    prepare_domain
    rm -rf "$DATA"
    open -n "$APP" --args -SPTAudioInput "$(clip_path uk-short)" -SPTKeysFile "$KEYS_FILE"
    cat <<EOF

The e2e build is running ($APP).
Once, by hand:
  1. System Settings › Privacy & Security › Accessibility: switch on SpeechText — the
     entry for $APP (the installed app has its own entry; leave it as it is). It stays
     on across rebuilds while the build is signed with the same certificate.
  2. The app this script runs in (Terminal, iTerm, T3 Code) needs Accessibility too,
     to post the shortcuts.
  3. On the first run, allow it and the e2e build to control TextEdit and Script
     Editor when macOS asks — a prompt left open takes the front, and the paste with it.
Then quit the e2e build from its menu-bar icon and run: scripts/e2e.sh --no-build
EOF
    exit 0
fi

"$KEYS" check > /dev/null 2>&1 || die "The app running this script may not post key events.
Allow it in System Settings › Privacy & Security › Accessibility, then run again."
trap cleanup EXIT
trap 'exit 130' INT TERM
stop_installed


{
    echo "# E2E run $(date '+%Y-%m-%d %H:%M') · $ENGINE · $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    echo
    echo "| Scenario | Verdict | Pastes | WER (info) | Problems | Document |"
    echo "|---|---|---|---|---|---|"
} > "$OUT/summary.md"

SELECTED="${ONLY:-$ALL_SCENARIOS}"
for name in ${SELECTED//,/ }; do
    case " $ALL_SCENARIOS " in *" $name "*) ;; *) die "unknown scenario $name (--list)" ;; esac
    "scenario_${name//-/_}"
    echo "${RESULTS[${#RESULTS[@]}-1]}" >> "$OUT/summary.md"
done

echo
echo "Results: $OUT/summary.md (Debug Log, document and History beside it)."
[ "$FAILED" -eq 0 ] || { echo "$FAILED scenario(s) failed."; exit 1; }
