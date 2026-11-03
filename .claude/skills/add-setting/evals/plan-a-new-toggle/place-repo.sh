#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
# Copies this repository's working tree into the run's folder, leaving out the skills,
# so the run without the skill cannot find it on disk.
set -eu
top=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
rsync -a --exclude .git --exclude .claude/skills --exclude .agents --exclude 'evals/results' "$top/" ./
