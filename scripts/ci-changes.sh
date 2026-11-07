#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Says which of CI's Mac jobs a change needs, as `tests=` and `lint=` lines for
# $GITHUB_OUTPUT. A pull request that only touches the docs, the changelog or an
# agent skill waited ten minutes on a hosted Mac for Tests that cannot fail on it.
#
#   scripts/ci-changes.sh <base>...<head>     what a pull request changed (merge base)
#   scripts/ci-changes.sh <before>..<after>   what a push changed
#   git diff --name-only … | scripts/ci-changes.sh -    a file list on stdin, to try it
#
# The list is of what may be skipped, not of what runs: a file it does not name
# runs the job, so a forgotten path costs a run, never a test. Tests skip only when
# every file is prose nothing builds or reads — no Swift test opens a Markdown
# file, and project.pbxproj bundles none of them (checked 2026-11-07). Checks is
# not gated at all: it is seconds on Linux and its steps read the docs.
#
# An empty list runs everything too, and so does a failure here: ci.yml runs a job
# whenever this job did not succeed.
set -euo pipefail

if [ "${1:-}" = "-" ]; then
  files=$(cat)
else
  files=$(git diff --name-only "${1:?usage: ci-changes.sh <range> | -}")
fi

# Prose: read by people and agents, never by the build or the tests.
docs_only() {
  case $1 in
    *.md | docs/* | .claude/* | .agents/* \
      | .github/ISSUE_TEMPLATE/* | .github/DISCUSSION_TEMPLATE/* \
      | .coderabbit.yaml | speech-text.png) return 0 ;;
    *) return 1 ;;
  esac
}

# What Swift lint reads, and what decides how it reads it.
lint_input() {
  case $1 in
    *.swift | .swift-format | scripts/lint-swift.sh \
      | scripts/ci-changes.sh | .github/workflows/ci.yml) return 0 ;;
    *) return 1 ;;
  esac
}

tests=false
lint=false
if [ -z "$files" ]; then
  tests=true
  lint=true
fi
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if ! docs_only "$file"; then tests=true; fi
  if lint_input "$file"; then lint=true; fi
done <<< "$files"

echo "tests=$tests"
echo "lint=$lint"
