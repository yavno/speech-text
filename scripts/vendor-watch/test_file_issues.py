# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for file_issues.py's decisions: which finding opens an issue, which comments, which
stays quiet. No network and no `gh`: the issues are written here.

    python3 -B -m unittest discover -s scripts/vendor-watch -p 'test_*.py'
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("file_issues", os.path.join(HERE, "file_issues.py"))
fi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fi)


def finding(key="groq/qwen/qwen3.8-27b", kind="price_drift", details="Groq `qwen/qwen3.8-27b`: catalogue $1, API $2.",
            **extra):
    vendor, _, model = key.partition("/")
    entry = {"key": key, "kind": kind, "details": details, "vendor": vendor, "model": model, "gate": False,
             "per_account": False, "confirmed_by": None, "source": None}
    entry.update(extra)
    return entry


def issue(number, entries, state="open", comments=(), labels=()):
    body = fi.text(entries[0]["key"], entries, None, fi.finding_hash(entries))
    return {"number": number, "state": state, "body": body, "comments": list(comments), "labels": list(labels)}


def actions(findings, issues=()):
    return [(a, k, n) for a, k, _, n in fi.plan(findings, list(issues))]


class Plan(unittest.TestCase):
    def test_a_new_finding_opens_an_issue(self):
        self.assertEqual(actions([finding()]), [("open", "groq/qwen/qwen3.8-27b", None)])

    def test_the_same_finding_on_an_open_issue_is_quiet(self):
        f = finding()
        self.assertEqual(actions([f], [issue(40, [f])]), [("same", f["key"], 40)])

    def test_a_changed_finding_comments_on_the_open_issue(self):
        old, new = finding(), finding(details="Groq `qwen/qwen3.8-27b`: catalogue $1, API $3.")
        self.assertEqual(actions([new], [issue(40, [old])]), [("comment", new["key"], 40)])

    def test_once_commented_the_changed_finding_is_quiet(self):
        old, new = finding(), finding(details="changed")
        comment = fi.text(new["key"], [new], None, fi.finding_hash([new]))
        self.assertEqual(actions([new], [issue(40, [old], comments=[comment])]), [("same", new["key"], 40)])

    def test_a_closed_issue_with_the_same_finding_stays_closed(self):
        f = finding(kind="gone", per_account=True)
        self.assertEqual(actions([f], [issue(39, [f], state="closed")]), [("closed", f["key"], 39)])

    def test_a_changed_finding_after_a_closed_issue_opens_one_that_links_it(self):
        old, new = finding(), finding(details="changed")
        self.assertEqual(actions([new], [issue(39, [old], state="closed")]), [("open", new["key"], 39)])
        _, _, entries, previous = fi.plan([new], [issue(39, [old], state="closed")])[0]
        self.assertIn("Previously: #39", fi.text(new["key"], entries, None, "h", previous))

    def test_wontfix_or_ignore_silences_a_key(self):
        old, new = finding(), finding(details="changed")
        self.assertEqual(actions([new], [issue(39, [old], state="closed", labels=["wontfix"])]),
                         [("ignored", new["key"], 39)])
        self.assertEqual(actions([new], [issue(39, [old], state="closed", comments=["vendor-watch:ignore"])]),
                         [("ignored", new["key"], 39)])

    def test_the_watch_s_own_comment_does_not_silence_a_key(self):
        # Every comment the watch writes ends by naming `vendor-watch:ignore`.
        old, middle, new = finding(), finding(details="changed"), finding(details="changed again")
        own = "The vendor watch found something new:\n\n" + fi.text(middle["key"], [middle], None,
                                                                      fi.finding_hash([middle]))
        self.assertIn(fi.IGNORE, own)
        self.assertEqual(actions([new], [issue(39, [old], state="closed", comments=[own])]),
                         [("open", new["key"], 39)])

    def test_findings_with_one_key_are_one_issue(self):
        a = finding("openAI/gpt-6-luna", "deprecation_listed", "listed")
        b = finding("openAI/gpt-6-luna", "page_mention", "named")
        self.assertEqual(actions([a, b]), [("open", "openAI/gpt-6-luna", None)])

    def test_new_repositories_are_only_listed(self):
        self.assertEqual(actions([finding("huggingface/FluidInference/x", "new_repository", "New")]),
                         [("summary", "huggingface/FluidInference/x", None)])

    def test_no_more_than_ten_new_issues_a_run(self):
        out = actions([finding("groq/m%d" % i) for i in range(12)])
        self.assertEqual([a for a, _, _ in out].count("open"), 10)
        self.assertEqual([a for a, _, _ in out].count("over"), 2)

    def test_an_issue_without_a_marker_is_not_matched(self):
        f = finding()
        plain = {"number": 7, "state": "open", "body": "filed by hand", "comments": [], "labels": []}
        self.assertEqual(actions([f], [plain]), [("open", f["key"], None)])


class Words(unittest.TestCase):
    def test_an_unconfirmed_per_account_gone(self):
        f = finding("openAI/gpt-6-luna", "gone", "OpenAI no longer serves `gpt-6-luna`.", per_account=True)
        self.assertEqual(fi.title(f["key"], [f]), "Unconfirmed: OpenAI `gpt-6-luna`: no longer served by the vendor")
        self.assertIn("confirm before acting", fi.text(f["key"], [f], None, "h"))

    def test_a_confirmed_gone_links_the_page(self):
        f = finding("groq/x", "gone", "gone", per_account=True, confirmed_by="https://console.groq.com/docs/deprecations.md")
        self.assertFalse(fi.title(f["key"], [f]).startswith("Unconfirmed"))
        self.assertIn("console.groq.com/docs/deprecations.md", fi.text(f["key"], [f], None, "h"))

    def test_vendor_text_cannot_mention_or_inject_html(self):
        f = finding(kind="page_mention", details="New: ping @someone <img src=x>")
        body = fi.text(f["key"], [f], None, "h")
        self.assertNotIn("@someone", body)
        self.assertNotIn("<img", body)


if __name__ == "__main__":
    unittest.main()
