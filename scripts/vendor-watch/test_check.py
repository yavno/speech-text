# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check.py's reading of the vendors' pages. No network: each page is a short
excerpt in the shape the vendor published it (checked 2026-11-03), so a test fails here
before a changed page fails the weekly run.

    python3 -B -m unittest discover -s scripts/vendor-watch -p 'test_*.py'
"""

import datetime
import importlib.util
import os
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check", os.path.join(HERE, "check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

TODAY = datetime.date(2026, 11, 3)

ANTHROPIC = """# Model deprecations

## Model status

| API model name             | Current state | Deprecated         | Tentative retirement date          |
| :------------------------- | :------------ | :----------------- | :--------------------------------- |
| claude-sonnet-5-5          | Active        | N/A                | Not sooner than September 28, 2027 |
| claude-sonnet-4-5-20250929 | Deprecated    | September 30, 2026 | November 30, 2026                  |
| claude-haiku-4-5-20251001  | Active        | N/A                | Not sooner than October 15, 2026   |

## Deprecation history

### 2026-09-30: Claude Sonnet 4.5 model

| Retirement date   | Deprecated model             | Recommended replacement |
| ----------------- | ---------------------------- | ----------------------- |
| November 30, 2026 | `claude-sonnet-4-5-20250929` | `claude-sonnet-5-5`     |
"""

GROQ = """## [Deprecation History](#deprecation-history)

### [September 14, 2026: qwen/qwen3.6-27b](#september-14-2026-qwenqwen3627b)

| Deprecated Model        | Shutdown Date | Recommended Replacement Model ID        |
| ----------------------- | ------------- | --------------------------------------- |
| qwen/qwen3.6-27b        | 09/14/26      | qwen/qwen3.8-27b                        |
| llama-3.3-70b-versatile | 08/16/26      | openai/gpt-oss-120b or qwen/qwen3.6-27b |
"""

OPENAI = """# Deprecations

### 2026-08-26: Transcription models

| Shutdown date | Model / system                                                  | Recommended replacement                   |
| ------------- | --------------------------------------------------------------- | ----------------------------------------- |
| Feb 26, 2027  | `gpt-4o-mini-transcribe` \\| `gpt-4o-mini-transcribe-2025-12-15` | `gpt-live-transcribe` or `gpt-transcribe` |
| Feb 26, 2027  | `/v1/audio/translations`                                        | `v1/realtime/translations`                |

### 2026-10-14: GPT-4 series model deprecations

| Shutdown date    | Model / system                                    | Recommended replacement |
| ---------------- | ------------------------------------------------- | ----------------------- |
| January 14, 2027 | GPT-4o (`gpt-4o-2024-08-06`, `gpt-4o-2024-11-20`) | `gpt-6-luna`            |
"""

PAGES = {check.DEPRECATION_PAGES["anthropic"]: ANTHROPIC, check.DEPRECATION_PAGES["groq"]: GROQ,
         check.DEPRECATION_PAGES["openAI"]: OPENAI}


def model(vendor, model_id, state="current", shutdown=None, kind="chat"):
    lifecycle = {"state": state}
    if shutdown:
        lifecycle["shutdownDate"] = shutdown
    entry = {"vendor": vendor, "id": model_id, "lifecycle": lifecycle}
    if kind == "speech":
        entry["delivery"] = "upload"
    return entry


def catalogue(speech=(), chat=()):
    return {"speech": list(speech), "chat": list(chat), "pricesChecked": "2026-10-26"}


def run(cat, gone=(), pages=PAGES):
    return check.deprecation_pages(cat, set(gone), TODAY, reader=lambda url: pages[url])


class DeprecationTables(unittest.TestCase):
    def test_cells_keep_an_escaped_bar(self):
        self.assertEqual(check.table_cells("| a \\| b | c |"), ["a | b", "c"])

    def test_dates(self):
        self.assertEqual(check.page_date("Feb 26, 2027"), (datetime.date(2027, 2, 26), False))
        self.assertEqual(check.page_date("January 14, 2027"), (datetime.date(2027, 1, 14), False))
        self.assertEqual(check.page_date("09/14/26"), (datetime.date(2026, 9, 14), False))
        self.assertEqual(check.page_date("Not sooner than October 15, 2026"), (datetime.date(2026, 10, 15), True))
        self.assertEqual(check.page_date("To be announced"), (None, False))

    def test_ids_in_backticks_or_words(self):
        self.assertEqual(check.cell_ids("GPT-4o (`gpt-4o-2024-08-06`, `gpt-4o-2024-11-20`)"),
                         ["gpt-4o-2024-08-06", "gpt-4o-2024-11-20"])
        self.assertEqual(check.cell_ids("openai/gpt-oss-120b or qwen/qwen3.6-27b"),
                         ["openai/gpt-oss-120b", "qwen/qwen3.6-27b"])
        self.assertEqual(check.cell_ids("`/v1/audio/translations`"), [])
        self.assertEqual(check.cell_ids("—"), [])

    def test_a_current_model_on_the_page(self):
        cat = catalogue(speech=[model("openAI", "gpt-4o-mini-transcribe", kind="speech")],
                        chat=[model("groq", "qwen/qwen3.6-27b")])
        findings, _, problems = run(cat)
        self.assertEqual(problems, {})
        by_id = {f["id"]: f for f in findings}
        self.assertEqual(by_id["gpt-4o-mini-transcribe"]["type"], "deprecation_listed")
        self.assertEqual(by_id["gpt-4o-mini-transcribe"]["date"], datetime.date(2027, 2, 26))
        self.assertEqual(by_id["gpt-4o-mini-transcribe"]["replacement"], ["gpt-live-transcribe", "gpt-transcribe"])
        self.assertEqual(by_id["qwen/qwen3.6-27b"]["replacement"], ["qwen/qwen3.8-27b"])

    def test_a_deprecated_model_with_the_same_date_is_quiet(self):
        cat = catalogue(speech=[model("openAI", "gpt-4o-mini-transcribe", "deprecated", "2027-02-26", "speech")])
        self.assertEqual(run(cat)[0], [])

    def test_a_deprecated_model_whose_date_moved(self):
        cat = catalogue(speech=[model("openAI", "gpt-4o-mini-transcribe", "deprecated", "2027-01-31", "speech")])
        (finding,), _, _ = run(cat)
        self.assertEqual(finding["type"], "deprecation_date_changed")
        self.assertEqual(finding["catalogue"], "2027-01-31")

    def test_an_anthropic_alias_matches_its_snapshot(self):
        cat = catalogue(chat=[model("anthropic", "claude-sonnet-4-5")])
        (finding,), _, _ = run(cat)
        self.assertEqual((finding["type"], finding["date"], finding["replacement"]),
                         ("deprecation_listed", datetime.date(2026, 11, 30), ["claude-sonnet-5-5"]))

    def test_active_past_its_earliest_retirement(self):
        cat = catalogue(chat=[model("anthropic", "claude-haiku-4-5", "superseded"),
                              model("anthropic", "claude-sonnet-5-5")])
        (finding,), _, _ = run(cat)
        self.assertEqual((finding["id"], finding["type"]), ("claude-haiku-4-5", "retirement_window_open"))

    def test_the_page_confirms_a_model_gone_from_the_account(self):
        cat = catalogue(chat=[model("groq", "qwen/qwen3.6-27b"), model("groq", "openai/gpt-oss-20b")])
        _, confirmed, _ = run(cat, gone={("groq", "qwen/qwen3.6-27b"), ("groq", "openai/gpt-oss-20b")})
        self.assertEqual(confirmed, {("groq", "qwen/qwen3.6-27b"): check.DEPRECATION_PAGES["groq"]})

    def test_a_page_that_changed_shape_is_not_checked(self):
        pages = dict(PAGES)
        pages[check.DEPRECATION_PAGES["groq"]] = "# Deprecations\n\nSee the table below.\n\n| Model | When |\n|---|---|\n| x | y |\n"
        _, _, problems = run(catalogue(), pages=pages)
        self.assertEqual(list(problems), ["groq"])

    def test_a_known_table_with_no_rows_is_not_checked(self):
        pages = dict(PAGES)
        pages[check.DEPRECATION_PAGES["groq"]] = ("| Deprecated Model | Shutdown Date | Recommended Replacement Model ID |\n"
                                                  "| --- | --- | --- |\n")
        _, _, problems = run(catalogue(), pages=pages)
        self.assertIn("no rows", problems["groq"])


class TextPages(unittest.TestCase):
    BEFORE = "# Changelog\n\n## October 2026\n\n### Oct 20\n\nOld line about whisper.\n"
    AFTER = ("# Changelog\n\n## October 2026\n\n### Oct 30\n\nReleased gpt-6-rosalind.\n\n"
             "We will deprecate `gpt-6-luna` next year.\n\nA new voice.\n\n### Oct 20\n\nOld line about whisper.\n")

    def test_new_lines_that_name_a_model_or_a_word(self):
        lines = check.new_page_lines(self.BEFORE, self.AFTER, ["gpt-6-luna"])
        self.assertEqual([l["line"] for l in lines], ["We will deprecate `gpt-6-luna` next year."])
        self.assertEqual(lines[0]["models"], ["gpt-6-luna"])
        self.assertEqual(lines[0]["section"], "Changelog › October 2026 › Oct 30")

    def test_an_id_inside_a_longer_one_is_not_named(self):
        lines = check.new_page_lines("", "Released gpt-6-luna-mini for transcription.\n", ["gpt-6-luna"])
        self.assertEqual(lines[0]["models"], [])

    def test_headings_and_code_are_context(self):
        current = "## Speech to text\n\n```python\nmodel = \"gpt-6-luna\"\n```\n\nWhisper is gone.\n"
        lines = check.new_page_lines("", current, ["gpt-6-luna"])
        self.assertEqual([(l["line"], l["section"]) for l in lines], [("Whisper is gone.", "Speech to text")])

    def test_a_model_is_a_finding_only_with_a_lifecycle_word(self):
        page = {"vendor": "openAI", "slug": "openai-changelog", "url": "u", "since": "2026-10-27",
                "lines": check.new_page_lines("", "Released Decisions with gpt-6-luna.\n"
                                                  "We will deprecate gpt-6-luna.\n", ["gpt-6-luna"])}
        pages = {"findings": [], "confirmed": {}, "problems": {}, "text": [page]}
        result = {"gone": [], "going": [], "expired": [], "drift": []}
        out = check.findings(catalogue(), result, pages, {}, [], [], [], ([], []), TODAY)
        self.assertEqual([(f["kind"], f["key"]) for f in out], [("page_mention", "openAI/gpt-6-luna")])
        self.assertIn("deprecate", out[0]["details"])

    def test_moved_lines_are_not_new(self):
        self.assertEqual(check.new_page_lines("a whisper\nb whisper\n", "b whisper\na whisper\n", []), [])

    def test_baseline_then_new_lines(self):
        cat = catalogue(chat=[model("openAI", "gpt-6-luna")])
        with tempfile.TemporaryDirectory() as folder:
            pages = {url: self.BEFORE for _, _, url in check.TEXT_PAGES}
            first = check.text_pages(cat, folder, TODAY - datetime.timedelta(days=7), reader=lambda u: pages[u])
            self.assertTrue(all(p.get("baseline") for p in first))
            pages = {url: self.AFTER for _, _, url in check.TEXT_PAGES}
            second = check.text_pages(cat, folder, TODAY, reader=lambda u: pages[u])
            openai = second[0]
            self.assertEqual(openai["since"], "2026-10-27")
            self.assertEqual(openai["lines"][0]["models"], ["gpt-6-luna"])
            # Groq's pages do not name an OpenAI model of the catalogue.
            self.assertEqual(second[2]["lines"][0]["models"], [])

    def test_two_copies_are_kept(self):
        with tempfile.TemporaryDirectory() as folder:
            for days in (14, 7, 0):
                day = TODAY - datetime.timedelta(days=days)
                _, _, path = check.page_snapshot(folder, "p", day)
                with open(path, "w") as f:
                    f.write(day.isoformat())
            self.assertEqual(sorted(os.listdir(os.path.join(folder, "pages", "p"))),
                             ["2026-10-27.md", "2026-11-03.md"])


class Findings(unittest.TestCase):
    def test_an_unconfirmed_gone_and_the_price_age(self):
        cat = catalogue(chat=[model("openAI", "gpt-6-luna")])
        cat["pricesChecked"] = "2026-08-01"
        result = {"gone": [("openAI", "gpt-6-luna", "chat", "current")], "going": [], "expired": [], "drift": []}
        pages = {"findings": [], "confirmed": {}, "problems": {}, "text": []}
        out = check.findings(cat, result, pages, {}, [], [], [], ([], []), TODAY)
        gone, age = out
        self.assertEqual((gone["key"], gone["kind"], gone["gate"], gone["per_account"], gone["confirmed_by"]),
                         ("openAI/gpt-6-luna", "gone", True, True, None))
        self.assertEqual((age["key"], age["kind"]), ("prices", "price_age"))

    def test_the_price_age_finding_is_the_same_a_week_later(self):
        cat = catalogue()
        cat["pricesChecked"] = "2026-08-01"
        empty = {"gone": [], "going": [], "expired": [], "drift": []}
        pages = {"findings": [], "confirmed": {}, "problems": {}, "text": []}
        week = [check.findings(cat, empty, pages, {}, [], [], [], ([], []), TODAY + datetime.timedelta(days=d))
                for d in (0, 7)]
        self.assertEqual(week[0], week[1])


if __name__ == "__main__":
    unittest.main()
