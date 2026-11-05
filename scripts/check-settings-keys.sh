#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Every key in `enum SettingsKeys` has a row in docs/settings-keys.md, and every key
# a row names is still in the enum.
#
#   scripts/check-settings-keys.sh
#
# The table is where a contributor looks up what a key holds and its default, so a
# key added without a row, or a row left behind by a key that was renamed or
# retired, fails the pull request instead of misleading the next reader. Only the
# keys are compared: whether a row's purpose and default are still true is review's.
#
# A key is the string value of a `static let NAME = "value"` inside the enum. The
# table is the first one whose header starts with `| Key |`; a row names its keys as the backticked words of its first cell, several joined with " / "
# (`hotkeyKeyCode` / `hotkeyModifierFlags`).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
code=Packages/SpeechTextCore/Sources/SpeechTextCore/Settings.swift
doc=docs/settings-keys.md

in_code=$(
    awk '/^public enum SettingsKeys \{/ { inside = 1; next } inside && /^\}/ { exit } inside' "$code" \
        | sed -nE 's/^[[:space:]]*(public[[:space:]]+)?static let [A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"([^"]+)".*/\2/p' \
        | sort -u
)
in_doc=$(
    awk -F'|' '
        !inside && /^\|[[:space:]]*Key[[:space:]]*\|/ { inside = 1; next }
        inside && !/^\|/ { exit }
        inside && $2 !~ /^[[:space:]-]*$/ { print $2 }
    ' "$doc" \
        | grep -oE '`[^`]+`' | tr -d '`' | sort -u
)

if [ -z "$in_code" ]; then
    echo "FAILED: found no keys in enum SettingsKeys ($code) — has it moved?"
    exit 1
fi

missing=$(comm -23 <(printf '%s\n' "$in_code") <(printf '%s\n' "$in_doc"))
stale=$(comm -13 <(printf '%s\n' "$in_code") <(printf '%s\n' "$in_doc"))

if [ -n "$missing" ] || [ -n "$stale" ]; then
    if [ -n "$missing" ]; then
        echo "In SettingsKeys but without a row in $doc:"
        printf '  %s\n' $missing
    fi
    if [ -n "$stale" ]; then
        echo "In a row of $doc but no longer in SettingsKeys:"
        printf '  %s\n' $stale
    fi
    echo
    echo "Add, rename or remove the row with the key — key, purpose, default (the add-setting skill)."
    exit 1
fi

echo "✓ all $(printf '%s\n' "$in_code" | wc -l | tr -d ' ') keys in SettingsKeys have a row in $doc, and every row's key exists"
