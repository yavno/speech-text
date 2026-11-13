#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# What e2e.sh's cleanup would have done, for a run that never reached it:
#
#   reopen-watcher.sh <pid> <marker> <e2e app> [installed app]...
#
# Waits for <pid> to end. If <marker> exists, cleanup finished and this does nothing.
# Otherwise it quits whatever runs from <e2e app> and opens each installed app that is
# not running. e2e.sh starts it in a session of its own, adopted by launchd, because an
# aborted tool call kills the script's whole process group with SIGKILL, which no trap
# catches (seen 2026-11-12, #229): the installed app stayed closed and the build ran on.

set -uo pipefail

PID="$1" MARKER="$2" E2E_APP="$3"
shift 3

# Polled, not `wait`: the script is not this process's parent.
while kill -0 "$PID" 2>/dev/null; do sleep 1; done
if [ -e "$MARKER" ]; then
    rm -f "$MARKER"
    exit 0
fi
echo "$(date '+%H:%M:%S') the run ($PID) ended without its cleanup."

# By path, as stop_installed does: the e2e build and the installed app share the name.
running_from() { pgrep -f "$1/Contents/MacOS/" 2>/dev/null || true; }

left="$(running_from "$E2E_APP")"
if [ -n "$left" ]; then
    echo "Quitting the e2e build ($(echo $left))."
    for pid in $left; do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 20); do [ -z "$(running_from "$E2E_APP")" ] && break; sleep 0.2; done
    for pid in $(running_from "$E2E_APP"); do kill -9 "$pid" 2>/dev/null || true; done
fi

for path in "$@"; do
    if [ -n "$(running_from "$path")" ]; then
        echo "$path is running already."
    else
        open "$path" && echo "Reopened $path."
    fi
done
