#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks over the String Catalogs (every tracked *.xcstrings) that xcstringstool does not
make. docs/specs/2026-11-04-localization.md › Checks.

    scripts/strings/check.py comments
        Every entry has a comment for the translator. CI, every pull request.

    scripts/strings/check.py translations
        Every translation keeps its source's format specifiers (%@, %lld, positional
        forms) and its Markdown (emphasis, code, links and where they point). CI, every
        pull request, and the translations job before it pushes.

    scripts/strings/check.py complete
        Every entry has a value in every supported language, and every plural form that
        language has, except entries marked shouldTranslate: false. release.yml.

The supported languages are knownRegions in project.pbxproj other than Base and en. Each
check prints what it found and exits 1 when anything fails.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.path.join(ROOT, "SpeechText", "SpeechText.xcodeproj", "project.pbxproj")
SOURCE = "en"

# The plural forms each language has, from CLDR (cardinal). A language is added here
# when it is added to knownRegions; `complete` refuses a language it has no forms for.
PLURAL_FORMS = {
    "en": {"one", "other"},
    "es": {"one", "many", "other"},
    "uk": {"one", "few", "many", "other"},
}

SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]|#@[A-Za-z0-9_]+@)")
LINK = re.compile(r"\]\(([^)]*)\)")
URL = re.compile(r"https?://\S+")
MARKS = ("**", "__", "`", "~~")
# Single-character emphasis, *like this* or _like this_: a mark that opens before a
# non-space and closes after one, not inside a word (snake_case, 2*3*4) or a double mark.
SINGLE_EMPHASIS = {
    "*": re.compile(r"(?<![*\w])\*(?![\s*])[^*\n]+?(?<![\s*])\*(?![*\w])"),
    "_": re.compile(r"(?<![_\w])_(?![\s_])[^_\n]+?(?<![\s_])_(?![_\w])"),
}
INTEGER = ("d", "D", "i", "u", "U")
# The plural forms that may leave the count out: every CLDR category but "other".
PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many"}


def catalogs():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "*.xcstrings"], check=True,
                         capture_output=True, text=True).stdout.split()
    return [os.path.join(ROOT, p) for p in out]


def load(path):
    with open(path) as f:
        return json.load(f)["strings"]


def languages(project=PROJECT):
    with open(project) as f:
        text = f.read()
    block = re.search(r"knownRegions = \(([^)]*)\)", text)
    regions = [r.strip().strip('"') for r in block.group(1).split(",") if r.strip()] if block else []
    return [r for r in regions if r not in ("Base", SOURCE)]


def specifiers(text):
    """The format specifiers of a value, as a sorted list of "position$conversion": an
    unnumbered specifier takes the next position, as printf gives it. A translation may
    reorder them (with positional forms) but must keep each argument where it was: two
    "%1$@" for the source's "%1$@ … %2$@" would show the first value twice."""
    found = []
    next_position = 0
    for match in SPECIFIER.finditer(text.replace("%%", "")):
        conversion = match.group(2)
        if conversion.startswith("#@"):
            found.append(conversion)
            continue
        if match.group(1):
            position = int(match.group(1))
        else:
            next_position += 1
            position = next_position
        found.append(f"{position}${conversion}")
    return sorted(found)


def count_specifier(specs):
    """The source's plural count: its one integer specifier, or None when it has none or
    several."""
    integers = [s for s in specs if "$" in s and s.split("$", 1)[1].endswith(INTEGER)]
    return integers[0] if len(integers) == 1 else None


def markdown(text):
    """What of a value's Markdown a translation must keep: the count of each emphasis
    mark, and the targets of links and bare URLs."""
    marks = {mark: text.count(mark) for mark in MARKS}
    single = text.replace("**", "").replace("__", "")
    for mark, pattern in SINGLE_EMPHASIS.items():
        marks[mark] = len(pattern.findall(single))
    links = sorted(LINK.findall(text)) + sorted(URL.findall(text))
    return marks, links


def units(localization):
    """Every (form, value) of one language's localization: a plain string unit as form
    None, a plural variation by its form ("one"), any other variation by kind and form
    ("device:mac"), substitutions by name and form ("count:one")."""
    found = []
    if "stringUnit" in localization:
        found.append((None, localization["stringUnit"].get("value", "")))
    for kind, forms in localization.get("variations", {}).items():
        for form, inner in forms.items():
            name = form if kind == "plural" else f"{kind}:{form}"
            for sub_form, value in units(inner):
                found.append((sub_form or name, value))
    for name, sub in localization.get("substitutions", {}).items():
        for form, inner in sub.get("variations", {}).get("plural", {}).items():
            for _, value in units(inner):
                found.append((f"{name}:{form}", value))
    return found


def source_value(key, entry):
    """The English that a translation is compared with: its 'other' form or plain value,
    else the key itself."""
    en = entry.get("localizations", {}).get(SOURCE)
    if en:
        forms = dict(units(en))
        for form in (None, "other"):
            if form in forms:
                return forms[form]
    return key


def check_comments(paths):
    problems = []
    for path in paths:
        for key, entry in load(path).items():
            if entry.get("shouldTranslate") is False:
                continue
            if not entry.get("comment", "").strip():
                problems.append(f"{rel(path)}: {key!r} has no comment")
    return problems


def check_translations(paths):
    problems = []
    for path in paths:
        for key, entry in load(path).items():
            source = source_value(key, entry)
            want_specs, want_md = specifiers(source), markdown(source)
            for lang, localization in entry.get("localizations", {}).items():
                if lang == SOURCE:
                    continue
                for form, value in units(localization):
                    where = f"{rel(path)}: {key!r} [{lang}{'/' + form if form else ''}]"
                    got = specifiers(value)
                    # A plural form other than 'other' may leave the count out ("once"),
                    # and nothing else.
                    count = count_specifier(want_specs)
                    # Only a plural form: a device variation ("device:mac") keeps every argument.
                    kind, _, category = (form or "").rpartition(":")
                    plural = category in PLURAL_CATEGORIES and kind not in ("device", "width")
                    without_count = [s for s in want_specs if s != count]
                    if got != want_specs and not (plural and count and got == without_count):
                        problems.append(f"{where}: specifiers {got} where the source has {want_specs}")
                    if markdown(value) != want_md:
                        problems.append(f"{where}: Markdown or links differ from the source")
    return problems


def check_complete(paths, langs):
    problems = []
    for lang in langs:
        if lang not in PLURAL_FORMS:
            problems.append(f"{lang}: no plural forms known; add them to PLURAL_FORMS in {rel(__file__)}")
    for path in paths:
        for key, entry in load(path).items():
            if entry.get("shouldTranslate") is False:
                continue
            plural = has_plural(entry.get("localizations", {}).get(SOURCE, {}))
            for lang in langs:
                localization = entry.get("localizations", {}).get(lang)
                where = f"{rel(path)}: {key!r} [{lang}]"
                if not localization:
                    problems.append(f"{where}: no translation")
                    continue
                forms = units(localization)
                if source_value(key, entry).strip():
                    if not forms:
                        problems.append(f"{where}: no value")
                    elif any(not value.strip() for _, value in forms):
                        problems.append(f"{where}: an empty value")
                if plural or has_plural(localization):
                    have = {form for form, _ in forms if form and ":" not in form}
                    missing = sorted(PLURAL_FORMS.get(lang, set()) - have)
                    if missing and "plural" in localization.get("variations", {}):
                        problems.append(f"{where}: plural forms missing: {', '.join(missing)}")
                    elif plural and "plural" not in localization.get("variations", {}) and "substitutions" not in localization:
                        problems.append(f"{where}: the source has plural forms, the translation none")
                for name, sub in localization.get("substitutions", {}).items():
                    have = set(sub.get("variations", {}).get("plural", {}))
                    missing = sorted(PLURAL_FORMS.get(lang, set()) - have)
                    if missing:
                        problems.append(f"{where}: plural forms of {name} missing: {', '.join(missing)}")
    return problems


def has_plural(localization):
    return "plural" in localization.get("variations", {}) or "substitutions" in localization


def is_subset(small, big):
    rest = list(big)
    for item in small:
        if item not in rest:
            return False
        rest.remove(item)
    return True


def rel(path):
    return os.path.relpath(path, ROOT)


def main(argv):
    if len(argv) != 2 or argv[1] not in ("comments", "translations", "complete"):
        print(__doc__.strip().split("\n\n", 1)[1], file=sys.stderr)
        return 2
    paths = catalogs()
    mode = argv[1]
    if mode == "comments":
        problems = check_comments(paths)
    elif mode == "translations":
        problems = check_translations(paths)
    else:
        langs = languages()
        problems = check_complete(paths, langs)
    names = ", ".join(rel(p) for p in paths)
    if problems:
        print(f"{len(problems)} problem(s) in {names}:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    extra = f" ({', '.join(languages()) or 'no language besides English yet'})" if mode == "complete" else ""
    print(f"{mode}: nothing to fix in {names}{extra}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
