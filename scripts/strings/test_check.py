# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check.py, on small catalogs written to a temporary directory.

    python3 -B -m unittest discover -s scripts/strings -p 'test_*.py'
"""

import importlib.util
import json
import os
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check", os.path.join(HERE, "check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    return {"variations": {"plural": {form: unit(value) for form, value in forms.items()}}}


class CatalogTest(unittest.TestCase):
    def catalog(self, strings):
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, "Localizable.xcstrings")
        with open(path, "w") as f:
            json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, f)
        return [path]


class CommentsTest(CatalogTest):
    def test_missing_comment_fails(self):
        paths = self.catalog({"Save": {}, "Open": {"comment": "A button."}})
        problems = check.check_comments(paths)
        self.assertEqual(len(problems), 1)
        self.assertIn("'Save'", problems[0])

    def test_untranslated_entry_needs_no_comment(self):
        self.assertEqual(check.check_comments(self.catalog({"SpeechText": {"shouldTranslate": False}})), [])


class TranslationsTest(CatalogTest):
    def test_kept_specifiers_pass_in_any_order(self):
        paths = self.catalog({"Add “%@” — used in %lld dictations": {"localizations": {
            "es": unit("Usado en %2$lld dictados: añadir «%1$@»")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_dropped_specifier_fails(self):
        paths = self.catalog({"%lld words": {"localizations": {"uk": unit("слова")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_changed_conversion_fails(self):
        paths = self.catalog({"%lld words": {"localizations": {"uk": unit("%@ слів")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_plural_form_may_leave_the_count_out(self):
        paths = self.catalog({"Used %lld times": {"localizations": {
            "en": plural(one="Used once", other="Used %lld times"),
            "uk": plural(one="Використано %lld раз", few="Використано %lld рази",
                         many="Використано %lld разів", other="Використано %lld раз"),
            "es": plural(one="Usado una vez", many="Usado %lld de veces", other="Usado %lld veces")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_plural_other_must_keep_the_count(self):
        paths = self.catalog({"Used %lld times": {"localizations": {
            "es": plural(one="Usado una vez", other="Usado muchas veces")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_an_argument_shown_twice_fails(self):
        paths = self.catalog({"%@ to %@": {"localizations": {"es": unit("%1$@ a %1$@")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_unnumbered_arguments_keep_their_order(self):
        paths = self.catalog({"%@ of %lld": {"localizations": {"uk": unit("%lld з %@")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)
        paths = self.catalog({"%@ of %lld": {"localizations": {"uk": unit("%2$lld з %1$@")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_a_plural_form_may_leave_out_only_the_count(self):
        source = "%lld dictations · %@"
        paths = self.catalog({source: {"localizations": {
            "es": plural(one="Un dictado · %2$@", many="%1$lld dictados · %2$@", other="%1$lld dictados · %2$@")}}})
        self.assertEqual(check.check_translations(paths), [])
        paths = self.catalog({source: {"localizations": {
            "es": plural(one="%lld dictado", many="%lld dictados · %@", other="%lld dictados · %@")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_lost_single_emphasis_fails(self):
        paths = self.catalog({"Read *this* first": {"localizations": {"es": unit("Lee esto primero")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)
        paths = self.catalog({"Read *this* first": {"localizations": {"es": unit("Lee *esto* primero")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_an_underscore_inside_a_word_is_not_emphasis(self):
        paths = self.catalog({"Set speech_text_debug": {"localizations": {"uk": unit("Увімкніть speech_text_debug")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_new_link_fails(self):
        paths = self.catalog({"Read the guide": {"localizations": {
            "es": unit("Lee la [guía](https://example.com)")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_link_target_must_stay(self):
        source = "See [the docs](https://speech-text.app/docs)"
        paths = self.catalog({source: {"localizations": {
            "uk": unit("Дивіться [документацію](https://speech-text.app/docs)")}}})
        self.assertEqual(check.check_translations(paths), [])
        paths = self.catalog({source: {"localizations": {
            "uk": unit("Дивіться [документацію](https://elsewhere.example)")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_lost_emphasis_fails(self):
        paths = self.catalog({"Press **Return**": {"localizations": {"es": unit("Pulsa Return")}}})
        self.assertEqual(len(check.check_translations(paths)), 1)

    def test_a_percentage_before_a_word_is_not_a_specifier(self):
        # "30% slower" is not "% s": the space flag is left out of the pattern on purpose.
        paths = self.catalog({"About 30% slower.": {"localizations": {"uk": unit("Приблизно на 30% повільніша.")}}})
        self.assertEqual(check.check_translations(paths), [])

    def test_percent_sign_is_not_a_specifier(self):
        paths = self.catalog({"100%% local": {"localizations": {"uk": unit("100%% локально")}}})
        self.assertEqual(check.check_translations(paths), [])


class CompleteTest(CatalogTest):
    def test_missing_language_fails(self):
        paths = self.catalog({"Save": {"localizations": {"es": unit("Guardar")}}})
        problems = check.check_complete(paths, ["es", "uk"])
        self.assertEqual(problems, [f"{check.rel(paths[0])}: 'Save' [uk]: no translation"])

    def test_untranslated_entry_is_skipped(self):
        paths = self.catalog({"SpeechText": {"shouldTranslate": False}})
        self.assertEqual(check.check_complete(paths, ["es", "uk"]), [])

    def test_every_plural_form_is_required(self):
        paths = self.catalog({"%lld words": {"localizations": {
            "en": plural(one="%lld word", other="%lld words"),
            "uk": plural(one="%lld слово", few="%lld слова", other="%lld слова")}}})
        problems = check.check_complete(paths, ["uk"])
        self.assertEqual(len(problems), 1)
        self.assertIn("many", problems[0])

    def test_plural_source_needs_a_plural_translation(self):
        paths = self.catalog({"%lld words": {"localizations": {
            "en": plural(one="%lld word", other="%lld words"), "es": unit("%lld palabras")}}})
        self.assertEqual(len(check.check_complete(paths, ["es"])), 1)

    def test_a_localization_with_no_value_fails(self):
        paths = self.catalog({"Save": {"localizations": {"es": {"variations": {"device": {}}}}}})
        self.assertEqual(len(check.check_complete(paths, ["es"])), 1)

    def test_empty_value_fails(self):
        paths = self.catalog({"Save": {"localizations": {"es": unit("")}}})
        self.assertEqual(len(check.check_complete(paths, ["es"])), 1)

    def test_unknown_language_fails(self):
        self.assertEqual(len(check.check_complete(self.catalog({}), ["fr"])), 1)


class LanguagesTest(unittest.TestCase):
    def test_reads_known_regions_without_base_and_english(self):
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, "project.pbxproj")
        with open(path, "w") as f:
            f.write("knownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\tes,\n\t\t\t\tuk,\n\t\t\t);")
        self.assertEqual(check.languages(path), ["es", "uk"])


if __name__ == "__main__":
    unittest.main()
