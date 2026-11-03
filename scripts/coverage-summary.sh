#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the line coverage of a test run as Markdown on stdout — CI appends it to the
# job summary. Informational only: nothing here is a threshold.
#
#   scripts/coverage-summary.sh RESULT_BUNDLE
#       RESULT_BUNDLE is the .xcresult `xcodebuild test -enableCodeCoverage YES
#       -resultBundlePath …` wrote.
#
# The test bundle is standalone (AGENTS.md › Tests): it links SpeechTextCore instead of
# hosting the app, so the SpeechText.app row is only what a test happens to reach and
# means little. What the suite covers is the package's sources, which the second table
# counts apart from the test files themselves — whichever target the report files them
# under, each once.
set -euo pipefail

bundle=${1:?usage: coverage-summary.sh RESULT_BUNDLE}

xcrun xccov view --report --json "$bundle" | python3 -I -c '
import json, sys

report = json.load(sys.stdin)

def percent(covered, executable):
    return "%.1f%%" % (100.0 * covered / executable) if executable else "–"

print("## Code coverage")
print()
print("Line coverage, informational only. Third-party packages are not exercised by the unit tests.")
print()
print("| Target | Files | Lines covered | Coverage |")
print("| --- | ---: | ---: | ---: |")
for target in report["targets"]:
    print("| %s | %d | %d / %d | %s |" % (
        target["name"], len(target["files"]), target["coveredLines"],
        target["executableLines"], percent(target["coveredLines"], target["executableLines"])))

sources = {}
for target in report["targets"]:
    for f in target["files"]:
        path = f["path"]
        if "/Packages/SpeechTextCore/Sources/" in path and f["executableLines"] > 0:
            sources.setdefault(path, f)
sources = list(sources.values())
if sources:
    covered = sum(f["coveredLines"] for f in sources)
    executable = sum(f["executableLines"] for f in sources)
    print()
    print("## SpeechTextCore sources")
    print()
    print("%d files, %d / %d lines, %s. The 10 least covered:" % (
        len(sources), covered, executable, percent(covered, executable)))
    print()
    print("| File | Lines covered | Coverage |")
    print("| --- | ---: | ---: |")
    for f in sorted(sources, key=lambda f: (f["lineCoverage"], -f["executableLines"]))[:10]:
        print("| %s | %d / %d | %s |" % (
            f["name"], f["coveredLines"], f["executableLines"],
            percent(f["coveredLines"], f["executableLines"])))
'
