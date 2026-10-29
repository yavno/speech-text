#!/bin/bash
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Selects the Xcode a GitHub-hosted Mac builds with: exactly the version named
# (CI's XCODE_VERSION), never the newest one installed. The `xcode-27` image also
# carries a release candidate, linked as `Xcode_27.2.app` beside its own name, so
# "newest" would pick it. A missing version fails the job rather than falling back
# to the image's default, which could be an Xcode the project does not build with.
#
# Hosted runners only: the self-hosted Mac uses the Xcode it has and must not be
# asked for a sudo password.
set -euo pipefail

version="${1:?usage: ci-select-xcode.sh <version, e.g. 27.1>}"
app="/Applications/Xcode_${version}.app"

if [ ! -d "$app" ]; then
  echo "::error::$app is not on this runner. Installed:"
  ls -d /Applications/Xcode*.app 2>/dev/null || true
  exit 1
fi

sudo xcode-select -s "$app"
xcodebuild -version
