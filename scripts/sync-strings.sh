#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Keeps the String Catalogs in step with the code: the app's, and SpeechTextCore's for
# the words the package hands to the interface.
#
#   scripts/sync-strings.sh
#       Builds the app and writes every string the compiler extracted into
#       SpeechText/SpeechText/Localizable.xcstrings and
#       Packages/SpeechTextCore/Sources/SpeechTextCore/Localizable.xcstrings. Run it
#       after adding or changing UI text, and commit the catalogs with the code.
#
#   scripts/sync-strings.sh --check [--derived-data DIR]
#       Fails when a committed catalog is not what a sync would write: a string the
#       code uses is missing, or an entry the code no longer uses is still there.
#       With --derived-data it reads a build that already ran there (CI passes the
#       Tests job's) instead of building again.
#
# Why a script: Xcode syncs a catalog while it builds in the IDE, xcodebuild does
# not (checked with Xcode 27.2). Both build the same .stringsdata files, though —
# what the compiler extracted from each source file (SWIFT_EMIT_LOC_STRINGS) — and
# `xcstringstool sync` merges them into the catalog the way the IDE does. A sync
# drops an entry the code no longer uses, or marks it stale when it has
# translations; --check fails on both, so a pull request removes what it stopped
# using (docs/specs/2026-11-04-localization.md › State).

set -euo pipefail

cd "$(dirname "$0")/.."

CHECK=0
DERIVED_DATA=""

while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --derived-data) DERIVED_DATA=$2; shift ;;
    -h|--help) sed -n '4,18p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$DERIVED_DATA" ]; then
  DERIVED_DATA=build/strings-derived-data
  echo "Building the app to extract its strings…"
  xcodebuild build \
    -project SpeechText/SpeechText.xcodeproj \
    -scheme SpeechText \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
fi

INTERMEDIATES="$DERIVED_DATA/Build/Intermediates.noindex"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# What a sync changed, and any entry left stale: committed catalog, synced copy.
report() {
  python3 -I - "$1" "$2" <<'PY'
import json
import sys

committed = json.load(open(sys.argv[1]))["strings"]
synced = json.load(open(sys.argv[2]))["strings"]
added = sorted(set(synced) - set(committed))
removed = sorted(set(committed) - set(synced))
stale = sorted(k for k, v in synced.items() if v.get("extractionState") == "stale")
for key in added:
    print(f"  missing from the catalog: {key!r}")
for key in removed:
    print(f"  no longer in the code: {key!r}")
for key in stale:
    print(f"  stale (no longer in the code, has translations): {key!r}")
PY
}

# A stale entry kept its translations; the code no longer uses it, so it goes. The
# file is written back in the layout xcstringstool and Xcode use, so the diff shows
# only the entries removed.
drop_stale() {
  python3 -I - "$1" <<'PY'
import json
import sys

def dump(value, indent=0):
    pad = "  " * indent
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        items = [f'{pad}  {json.dumps(k, ensure_ascii=False)} : {dump(v, indent + 1)}' for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + pad + "]"
        items = [f"{pad}  {dump(v, indent + 1)}" for v in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)

path = sys.argv[1]
catalog = json.loads(open(path).read())
strings = catalog["strings"]
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
if stale:
    for key in stale:
        del strings[key]
    with open(path, "w") as f:
        f.write(dump(catalog))  # no final newline, as Xcode writes it
PY
}

# sync CATALOG DIR: DIR (under Intermediates.noindex, a glob) holds one target's
# .stringsdata, one per source file. Each catalog takes its own target's only — the
# app's strings are not the package's, and the other packages the app links emit
# theirs too.
sync() {
  local catalog=$1 dir=$2
  shopt -s nullglob
  # shellcheck disable=SC2206 # the glob in $dir is meant to expand
  local stringsdata=("$INTERMEDIATES"/$dir/*.stringsdata)
  shopt -u nullglob
  if [ ${#stringsdata[@]} -eq 0 ]; then
    echo "No .stringsdata under $INTERMEDIATES/$dir (a Debug build of the SpeechText scheme)." >&2
    exit 2
  fi

  # xcstringstool matches a catalog to the strings' table by its file name.
  local copy
  copy="$work/$(echo "$catalog" | tr / _)/Localizable.xcstrings"
  mkdir -p "$(dirname "$copy")"
  cp "$catalog" "$copy"
  xcrun xcstringstool sync "$copy" --stringsdata "${stringsdata[@]}"

  local changes
  changes=$(report "$catalog" "$copy")

  if [ "$CHECK" -eq 1 ]; then
    if [ -n "$changes" ] || ! cmp -s "$catalog" "$copy"; then
      echo "$catalog does not match the code:"
      if [ -n "$changes" ]; then echo "$changes"; fi
      failed=1
    else
      echo "$catalog matches the code."
    fi
    return
  fi

  drop_stale "$copy"
  cp "$copy" "$catalog"
  if [ -n "$changes" ]; then echo "$changes"; fi
  echo "Wrote $catalog."
}

sync SpeechText/SpeechText/Localizable.xcstrings \
  "SpeechText.build/Debug/SpeechText.build/Objects-normal/*"
sync Packages/SpeechTextCore/Sources/SpeechTextCore/Localizable.xcstrings \
  "SpeechTextCore.build/Debug/SpeechTextCore-t.build/Objects-normal/*"

if [ "$failed" -eq 1 ]; then
  echo
  echo "Run scripts/sync-strings.sh and commit the catalogs."
  exit 1
fi
