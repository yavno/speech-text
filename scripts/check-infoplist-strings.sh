#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails when the permission prompts and the copyright line in Info.plist and their
# String Catalog, InfoPlist.xcstrings, say different things.
#
#   scripts/check-infoplist-strings.sh
#
# Info.plist holds the English; InfoPlist.xcstrings holds the same English as each
# key's source value, the translations, and a comment for the translator. Xcode keeps
# the two in step only while it builds in the IDE (xcodebuild does not), so a prompt
# edited in Info.plist alone would leave its translations saying the old thing. Every
# NS…UsageDescription key and NSHumanReadableCopyright needs an entry with the same
# English and a comment, and the catalog has no entry for a key Info.plist lacks.
# Python's plistlib reads the plist, so it runs alike on macOS and Linux.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 -I - SpeechText/SpeechText/Info.plist SpeechText/SpeechText/InfoPlist.xcstrings <<'PY'
import json
import plistlib
import sys

plist_path, catalog_path = sys.argv[1], sys.argv[2]
with open(plist_path, "rb") as f:
    plist = plistlib.load(f)
with open(catalog_path) as f:
    strings = json.load(f)["strings"]

wanted = sorted(k for k in plist if k.endswith("UsageDescription") or k == "NSHumanReadableCopyright")
problems = []
for key in wanted:
    entry = strings.get(key)
    if entry is None:
        problems.append(f"{key}: in Info.plist, missing from InfoPlist.xcstrings")
        continue
    english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    if english != plist[key]:
        problems.append(f"{key}: Info.plist says {plist[key]!r}, InfoPlist.xcstrings says {english!r}")
    if not entry.get("comment"):
        problems.append(f"{key}: no comment for the translator in InfoPlist.xcstrings")
for key in sorted(set(strings) - set(plist)):
    problems.append(f"{key}: in InfoPlist.xcstrings, not in Info.plist")

if problems:
    print("Info.plist and InfoPlist.xcstrings differ:")
    for problem in problems:
        print(f"  {problem}")
    print()
    print("Change both together: the English in Info.plist and the key's \"en\" value in the catalog.")
    sys.exit(1)
print(f"InfoPlist.xcstrings matches Info.plist ({len(wanted)} keys).")
PY
