# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Files the vendor watch's findings as `model-lifecycle` issues.

Reads the JSON `check.py --json` writes. One issue per key (a model, a package, a language
source), found again by a marker in its body, so a finding repeated every week does not
open a second issue:

- an open issue for the key gets a comment only when the finding changed (a marker with
  its hash is in the issue or a comment once it has been said);
- a closed one stays closed when the same finding comes back (closing it is the answer),
  or forever with the `wontfix` label or a comment saying `vendor-watch:ignore`; a changed
  finding opens a new issue that links the old one;
- a model gone from a per-account list (OpenAI, Groq) and not on the vendor's deprecation
  page is filed as "Unconfirmed".

New Hugging Face repositories are only listed in the summary: there are several a week.
Nothing is decided by reading text: the findings are the script's, and a line quoted from
a vendor's page is quoted, never followed.

    python3 -I scripts/vendor-watch/file_issues.py --findings findings.json [--run-url URL] [--dry-run]

Needs `gh` with a token that may write issues (GH_TOKEN) and GITHUB_REPOSITORY, or --repo.
Standard library only.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

LABEL = "model-lifecycle"
VENDOR_NAMES = {"openAI": "OpenAI", "groq": "Groq", "anthropic": "Anthropic", "elevenLabs": "ElevenLabs",
                "local": "Local"}
KEY_MARKER = "<!-- vendor-watch:key=%s -->"
HASH_MARKER = "<!-- vendor-watch:hash=%s -->"
KEY_IN_BODY = re.compile(r"<!-- vendor-watch:key=(.+?) -->")
IGNORE = "vendor-watch:ignore"


def silenced(comment):
    """A person's `vendor-watch:ignore`. The watch's own comments name the phrase too, in
    their closing line, and always carry the hash marker: those never count."""
    return IGNORE in comment and "<!-- vendor-watch:hash=" not in comment
# Listed in the summary, never filed.
SUMMARY_ONLY = {"new_repository"}
# A run that would open more than this is wrong somewhere: the rest go to the summary.
MAX_NEW = 10

TITLES = {
    "gone": "no longer served by the vendor",
    "shutdown_announced": "shutdown announced by the vendor's API",
    "past_shutdown": "past its shutdown",
    "price_drift": "price differs from the vendor's API",
    "deprecation_listed": "on the vendor's deprecation page",
    "deprecation_date_changed": "shutdown date changed on the vendor's page",
    "retirement_window_open": "past its earliest retirement date",
    "page_mention": "named on a vendor page with a lifecycle word",
    "new_at_vendor": "new at the vendor",
    "language_list": "language list changed at its source",
    "local_model": "files missing from its repository",
    "package_release": "newer release",
    "price_age": "prices checked by hand are old",
}
TODO = {
    "gone": "Confirm on the vendor's deprecation page, then mark it `deprecated` with its replacement "
            "(`migrateTo`), or `retired`, in the catalogue.",
    "shutdown_announced": "Mark it `deprecated` with the shutdown date and its replacement.",
    "past_shutdown": "Move it to `retired`, or remove it six months after its shutdown.",
    "price_drift": "Update its `price:` and `UsagePrices.checked` (docs/prices.md).",
    "deprecation_listed": "Mark it `deprecated` with the shutdown date and its replacement.",
    "deprecation_date_changed": "Update its `shutdownDate`.",
    "retirement_window_open": "Nothing yet: the vendor may now announce its retirement at any time.",
    "page_mention": "Read the line on the vendor's page and decide.",
    "new_at_vendor": "Decide whether it is a candidate for dictation or AI Rewrite.",
    "language_list": "Update the codes and the date in ModelLanguages.swift (or the model's entry).",
    "local_model": "The model cannot be installed: fix its source or retire it.",
    "package_release": "Read the release notes for new or changed models.",
    "price_age": "Check every price by hand (docs/prices.md) and update `UsagePrices.checked`.",
}


def safe(text):
    """Vendor text and IDs as plain Markdown: no HTML, and no @-mention that notifies anyone."""
    return text.replace("<", "&lt;").replace("@", "@​")


def group(findings):
    """Findings by key, in the order they came."""
    out = {}
    for f in findings:
        out.setdefault(f["key"], []).append(f)
    return out


def finding_hash(entries):
    # The confirming page is part of it: an Unconfirmed issue hears when the page lists the model.
    text = "\n".join(sorted("%s %s %s" % (f["kind"], f["details"], f.get("confirmed_by") or "") for f in entries))
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def unconfirmed(entries):
    return any(f["kind"] == "gone" and f.get("per_account") and not f.get("confirmed_by") for f in entries)


def title(key, entries):
    first = entries[0]
    if first.get("model"):
        subject = "%s `%s`" % (VENDOR_NAMES.get(first.get("vendor"), first.get("vendor")), first["model"])
    else:
        subject = key
    return "%s%s: %s" % ("Unconfirmed: " if unconfirmed(entries) else "", subject,
                         "; ".join(dict.fromkeys(TITLES.get(f["kind"], f["kind"]) for f in entries)))


def text(key, entries, run, digest, previous=None):
    lines = [KEY_MARKER % key, HASH_MARKER % digest, ""]
    lines += ["- " + safe(f["details"]) for f in entries]
    sources = list(dict.fromkeys(s for f in entries for s in (f.get("source"), f.get("confirmed_by")) if s))
    if sources:
        lines += ["", "Source: " + ", ".join(sources)]
    if unconfirmed(entries):
        lines += ["", "OpenAI's and Groq's model lists are per account, and the vendor's deprecation page "
                      "does not list this model: confirm before acting."]
    if any(f["kind"] == "page_mention" for f in entries):
        lines += ["", "Quoted from the vendor's page as it stands; verify before acting."]
    todo = list(dict.fromkeys(TODO[f["kind"]] for f in entries if f["kind"] in TODO))
    if todo:
        lines += ["", "**What to do:** " + " ".join(todo)]
    if previous:
        lines += ["", "Previously: #%d" % previous]
    lines += ["", "Found by the vendor watch%s (docs/vendor-watch.md). Comment `%s` to silence this "
                  "finding for good." % (" in [this run](%s)" % run if run else "", IGNORE)]
    return "\n".join(lines)


def plan(findings, issues):
    """What to do with each key: (action, key, entries, issue number or None). `issues` are
    the label's issues, newest first, each with its body, state, labels and comment bodies."""
    by_key = {}
    for issue in issues:
        found = KEY_IN_BODY.search(issue.get("body") or "")
        if found:
            by_key.setdefault(found.group(1), []).append(issue)
    actions, opened = [], 0
    for key, entries in group(findings).items():
        if all(f["kind"] in SUMMARY_ONLY for f in entries):
            actions.append(("summary", key, entries, None))
            continue
        digest = finding_hash(entries)
        said = HASH_MARKER % digest
        known = by_key.get(key, [])
        open_ = [i for i in known if i["state"] == "open"]
        if open_:
            issue = open_[0]
            texts = [issue.get("body") or ""] + issue.get("comments", [])
            actions.append(("same" if any(said in t for t in texts) else "comment", key, entries, issue["number"]))
            continue
        if known:
            issue = known[0]
            texts = [issue.get("body") or ""] + issue.get("comments", [])
            if "wontfix" in issue.get("labels", []) or any(silenced(c) for c in issue.get("comments", [])):
                actions.append(("ignored", key, entries, issue["number"]))
                continue
            if any(said in t for t in texts):
                actions.append(("closed", key, entries, issue["number"]))
                continue
        if opened >= MAX_NEW:
            actions.append(("over", key, entries, None))
            continue
        opened += 1
        actions.append(("open", key, entries, known[0]["number"] if known else None))
    return actions


# MARK: - GitHub

def gh(*args, data=None):
    result = subprocess.run(["gh"] + list(args), input=data, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit("gh %s failed" % args[0])
    return result.stdout


def label_issues(repo):
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          "repos/%s/issues?labels=%s&state=all&per_page=100" % (repo, LABEL)))
    issues = [issue for page in pages for issue in page]
    out = []
    for issue in issues:
        if "pull_request" in issue:
            continue
        body = issue.get("body") or ""
        comments = []
        if KEY_IN_BODY.search(body) and issue.get("comments"):
            pages = json.loads(gh("api", "--paginate", "--slurp",
                                  "repos/%s/issues/%d/comments?per_page=100" % (repo, issue["number"])))
            comments = [c["body"] or "" for page in pages for c in page]
        out.append({"number": issue["number"], "state": issue["state"], "body": body, "comments": comments,
                    "labels": [label["name"] for label in issue.get("labels", [])]})
    return sorted(out, key=lambda i: -i["number"])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--findings", required=True)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--run-url")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.repo:
        raise SystemExit("no --repo and no GITHUB_REPOSITORY")

    report = json.load(open(args.findings))
    actions = plan(report["findings"], label_issues(args.repo))
    rows = []
    for action, key, entries, number in actions:
        digest = finding_hash(entries)
        if action == "open":
            body = text(key, entries, args.run_url, digest, previous=number)
            if not args.dry_run:
                url = gh("issue", "create", "--repo", args.repo, "--label", LABEL,
                         "--title", safe(title(key, entries)), "--body-file", "-", data=body).strip()
                number = int(url.rsplit("/", 1)[1])
        elif action == "comment" and not args.dry_run:
            gh("issue", "comment", str(number), "--repo", args.repo, "--body-file", "-",
               data="The vendor watch found something new:\n\n" + text(key, entries, args.run_url, digest))
        rows.append("| %s | `%s` | %s | %s |" % (
            {"open": "opened", "comment": "commented", "same": "already said", "closed": "closed, same finding",
             "ignored": "ignored", "over": "**not filed: more than %d new in one run**" % MAX_NEW,
             "summary": "listed only"}[action],
            key, safe("; ".join(f["details"] for f in entries))[:300], "#%d" % number if number else ""))
    summary = ["## Issues%s" % (" (dry run)" if args.dry_run else ""), ""]
    if rows:
        summary += ["| Action | Key | Finding | Issue |", "|---|---|---|---|"] + rows
    else:
        summary.append("Nothing to file.")
    out = "\n".join(summary) + "\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(out)
    print(out)


if __name__ == "__main__":
    main()
