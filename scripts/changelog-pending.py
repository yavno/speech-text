# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Lists the pull requests merged since the last release whose CHANGELOG entry is not settled.

    python3 scripts/changelog-pending.py [--since vX.Y.Z | --since 2026-10-29T20:28:17Z] [--json]

CHANGELOG entries are written after the merge, from each pull request's *Users will
notice* (CONTRIBUTING.md), so before a release, and once a day in between, someone has
to know which merged pull requests still need one. A pull request merged since `--since`
(default: the newest release tag main contains) is settled when any of these holds:

- it changed CHANGELOG.md itself, as pull requests did before entries moved after the merge;
- an open or merged pull request titled `Changelog: …` names it on its `Covers:` line;
- it carries the `no-changelog` label: someone read it and decided users will not notice.

Every other one is printed with its *Users will notice* line and the folders it touched. Pull requests titled `Changelog: …` are never listed themselves. Nothing is
written anywhere: the script only reads, through the GitHub CLI (`gh`), signed in.

Standard library only, Python 3.9. Exit status: 0 the list was made (empty or not),
2 `gh` or `git` failed, 64 bad usage.
"""

import argparse
import json
import os
import re
import subprocess
import sys

REPO = "yavno/speech-text"
CATCH_UP_PREFIX = "Changelog:"
NO_CHANGELOG_LABEL = "no-changelog"
LIMIT = 400


def run(args, env=None):
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True, env=env).stdout
    except FileNotFoundError:
        sys.exit(f"{args[0]} is not installed.")
    except subprocess.CalledProcessError as error:
        print(error.stderr.strip(), file=sys.stderr)
        sys.exit(2)


def utc(ref):
    """The commit date of a tag or commit, as GitHub writes mergedAt. `format-local` prints
    the time in TZ, so TZ is UTC for it: the machine's own zone would shift the cutoff."""
    return run(["git", "-c", "log.showSignature=false", "log", "-1",
                "--date=format-local:%Y-%m-%dT%H:%M:%SZ", "--format=%cd", ref],
               env={**os.environ, "TZ": "UTC"}).strip()


def since_from(value):
    if value is None:
        run(["git", "fetch", "--quiet", "--tags", "origin"])
        tags = run(["git", "tag", "--merged", "origin/main", "--sort=-creatordate"]).split()
        if not tags:
            sys.exit("No release tag on origin/main; pass --since.")
        return tags[0], utc(tags[0])
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        return value, value
    return value, utc(value)


def users_will_notice(body):
    """The text after the template's **Users will notice** label, up to the next section."""
    match = re.search(r"\*\*Users will notice\*\*\s*[—–-]?\s*(.*?)(?:\n\s*\n|\n\*\*|\n#|\Z)",
                      body or "", re.S)
    if not match:
        return None
    text = re.sub(r"<!--.*?-->", "", match.group(1), flags=re.S)
    text = re.sub(r"what changes for someone using the app, in a sentence or two, or \"Nothing\"\.?",
                  "", text)
    return " ".join(text.split()) or None


def area(path):
    """The folder a path is in, deep enough to tell the app from its tests."""
    depth = {"Packages": 3, "SpeechText": 2}.get(path.split("/")[0], 1)
    parts = path.split("/")
    return "/".join(parts[:depth]) if len(parts) > depth else path


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--since", help="a tag, a commit, or a UTC time like 2026-10-29T20:28:17Z")
    parser.add_argument("--json", action="store_true", help="print the pending list as JSON")
    options = parser.parse_args()

    label, since = since_from(options.since)
    pulls = json.loads(run([
        "gh", "pr", "list", "--repo", REPO, "--base", "main", "--state", "all",
        "--limit", str(LIMIT), "--json", "number,title,state,mergedAt,body,labels,files",
    ]))

    covered = set()
    for pull in pulls:
        if pull["title"].startswith(CATCH_UP_PREFIX) and pull["state"] in ("OPEN", "MERGED"):
            for line in (pull["body"] or "").splitlines():
                if line.strip().lower().startswith("covers:"):
                    covered.update(int(n) for n in re.findall(r"#(\d+)", line))

    pending = []
    for pull in sorted(pulls, key=lambda p: p["number"]):
        if pull["state"] != "MERGED" or not pull["mergedAt"] or pull["mergedAt"] <= since:
            continue
        if pull["title"].startswith(CATCH_UP_PREFIX) or pull["number"] in covered:
            continue
        if any(l["name"] == NO_CHANGELOG_LABEL for l in pull["labels"]):
            continue
        paths = [f["path"] for f in pull["files"]]
        if "CHANGELOG.md" in paths:
            continue
        pending.append({
            "number": pull["number"],
            "title": pull["title"],
            "merged": pull["mergedAt"][:10],
            "users_will_notice": users_will_notice(pull["body"]),
            "touches": sorted({area(p) for p in paths}),
        })

    if options.json:
        print(json.dumps({"since": label, "pending": pending}, indent=2))
        return
    if not pending:
        print(f"Nothing pending: every pull request merged since {label} has its CHANGELOG entry settled.")
        return
    print(f"{len(pending)} merged since {label} without a settled CHANGELOG entry:\n")
    for pull in pending:
        print(f"#{pull['number']}  {pull['merged']}  {pull['title']}")
        print(f"    Users will notice: {pull['users_will_notice'] or '(not filled in)'}")
        print(f"    Touches: {', '.join(pull['touches'])}")


if __name__ == "__main__":
    main()
