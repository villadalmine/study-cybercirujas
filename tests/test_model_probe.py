"""Grading the study bot's models: the judgement, offline.

`scripts/probe_models.py` spends real money against a real API, so the part
worth testing is the part that decides what a response MEANS — and that part is
pure. Every case below is a response shape observed on 2026-09-11 while probing
the eighteen models the bot offers.

The distinctions are the point. "It answered" is not "it works": three models
returned HTTP 200 with no content at all. "It supports reasoning" is not "the
effort selector does something": the catalogue advertises `reasoning` for all
eighteen, and thirteen of them either think when told not to or ignore the
setting entirely. A probe that collapsed those into a boolean would report the
same 'true' the catalogue already reported, which is what shipped a study bot
whose cheapest option was neither.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import probe_models as probe  # noqa: E402

from teach.core import catalog  # noqa: E402


def response(**fields) -> dict:
    """A successful completion, overridden field by field."""
    base = {"status": 200, "content": "Paris", "reasoning_text": False,
            "reasoning_blob": False, "reasoning_tokens": 0, "ms": 10,
            "in": 25, "out": 2, "cost": 0.0001, "finish": "stop"}
    base.update(fields)
    return base


class VerdictTests(unittest.TestCase):
    def test_the_expected_word_is_ok(self):
        self.assertEqual(probe.verdict(response()), "ok")
        self.assertEqual(probe.verdict(response(content="paris.")), "ok")

    def test_a_different_answer_is_alive_but_not_obedient(self):
        # The model works; it just ignored "one word and nothing else". That is
        # worth knowing and is not a reason to drop it from the menu.
        self.assertEqual(
            probe.verdict(response(content="The capital of France is Paris.")),
            "ok")
        self.assertEqual(probe.verdict(response(content="Lyon")), "answers")

    def test_two_hundred_with_no_content_is_empty(self):
        # nemotron-3-ultra, 2026-09-11: HTTP 200, no choices content, no error.
        # A student sees a blank answer and no explanation.
        self.assertEqual(probe.verdict(response(content="")), "empty")

    def test_each_failure_keeps_its_own_name(self):
        self.assertEqual(probe.verdict({"status": 404}), "dead")
        self.assertEqual(probe.verdict({"status": 429}), "rate")
        self.assertEqual(probe.verdict({"status": 401}), "auth")
        self.assertEqual(probe.verdict({"status": 402}), "auth")
        self.assertEqual(probe.verdict({"status": 500}), "error")
        self.assertEqual(probe.verdict({"status": 0, "message": "timeout"}), "error")

    def test_rate_limited_is_not_dead(self):
        # The whole free tier depends on this distinction: a `:free` model
        # saturated for six seconds must not be written off as gone.
        self.assertNotEqual(probe.verdict({"status": 429}),
                            probe.verdict({"status": 404}))


class ThinkingTests(unittest.TestCase):
    def test_thinking_is_visible_in_three_different_shapes(self):
        self.assertFalse(probe.thought(response()))
        self.assertTrue(probe.thought(response(reasoning_tokens=64)))
        self.assertTrue(probe.thought(response(reasoning_text=True)))
        # OpenAI returns encrypted reasoning: no text, no token count in some
        # responses, just an opaque blob. It is billed all the same.
        self.assertTrue(probe.thought(response(reasoning_blob=True)))

    def test_effort_works_when_off_is_really_off(self):
        self.assertEqual(
            probe.thinking_mode(response(), response(reasoning_tokens=64)),
            "effort")

    def test_thinking_with_the_field_omitted_is_always(self):
        # gpt-5-mini, the bot's default model: 64 thinking tokens on a request
        # that never mentioned reasoning.
        self.assertEqual(
            probe.thinking_mode(response(reasoning_tokens=64),
                                response(reasoning_tokens=64)),
            "always")

    def test_accepted_and_never_used_is_ignored(self):
        # claude-sonnet-5: effort low and even high produce zero thinking
        # tokens. The selector spends nothing and changes nothing.
        self.assertEqual(probe.thinking_mode(response(), response()), "ignored")

    def test_a_refused_parameter_is_none(self):
        refused = {"status": 400,
                   "message": "Unsupported parameter: 'reasoning' is not supported"}
        self.assertEqual(probe.thinking_mode(response(), refused), "none")

    def test_an_unreachable_second_probe_decides_nothing(self):
        # Answering "the selector is fine" because the probe was rate-limited
        # would be a guess wearing a verdict's clothes.
        self.assertEqual(probe.thinking_mode(response(), {"status": 429}),
                         "unknown")

    def test_a_generic_error_is_not_read_as_a_refused_parameter(self):
        self.assertFalse(probe.rejects_reasoning(
            {"status": 500, "message": "Internal server error"}))
        self.assertTrue(probe.rejects_reasoning(
            {"status": 400, "message": "Unknown parameter: reasoning.effort"}))


class OffSwitchTests(unittest.TestCase):
    def test_the_switch_that_works(self):
        self.assertEqual(probe.off_switch(response()), "enabled:false")

    def test_accepted_and_ignored(self):
        self.assertEqual(probe.off_switch(response(reasoning_tokens=40)), "none")

    def test_refused_outright(self):
        # gpt-5-mini / gpt-5-nano / gpt-6-astra / minimax-m2.7, 2026-09-11.
        mandatory = {"status": 400, "message":
                     "Reasoning is mandatory for this endpoint and cannot be disabled."}
        self.assertEqual(probe.off_switch(mandatory), "rejected")
        self.assertTrue(probe.reasoning_mandatory(mandatory))

    def test_a_rate_limit_is_not_a_refusal(self):
        self.assertFalse(probe.reasoning_mandatory({"status": 429, "message": ""}))
        self.assertFalse(probe.reasoning_mandatory(
            {"status": 400, "message": "context length exceeded"}))


class LanguageTests(unittest.TestCase):
    """Which language did the model reply in? Fixed lists, fixed rule.

    Coarse on purpose: it exists to catch "asked in Japanese, answered in
    English" — the failure a student sees — not to score fluency. The samples
    are the shape the probe asks for: a path, then one sentence.
    """

    SAMPLES = {
        "en": "/etc/passwd. The file stores the local user accounts and their UID.",
        "es": "/etc/passwd. Ese archivo contiene las cuentas de usuario locales.",
        "pt": "/etc/passwd. Esse arquivo contém as contas de usuário locais.",
        "fr": "/etc/passwd. Ce fichier contient les comptes utilisateurs locaux.",
        "de": "/etc/passwd. Die Datei enthält die lokalen Benutzerkonten.",
        "zh": "/etc/passwd 该文件包含本地用户账户的信息。",
        "ja": "/etc/passwd このファイルにはユーザーアカウントが含まれます。",
    }

    def test_every_language_is_recognised_from_its_own_answer(self):
        for lang, text in self.SAMPLES.items():
            with self.subTest(lang=lang):
                self.assertEqual(probe.detect_language(text), lang)

    def test_kana_separates_japanese_from_chinese(self):
        # Both use Han characters; only Japanese uses kana, so that is the test
        # rather than a guess about which ideographs belong to whom.
        self.assertEqual(probe.detect_language("这个文件包含用户账户"), "zh")
        self.assertEqual(probe.detect_language("このファイルにはアカウント"), "ja")

    def test_an_answer_with_no_prose_is_unclear_not_wrong(self):
        # The caller treats 'unclear' as "not proven wrong" and keeps the model:
        # dropping one from a language's menu on a coin flip is the worse error.
        self.assertEqual(probe.detect_language("/etc/passwd"), "unclear")

    def test_the_failure_it_exists_to_catch(self):
        # Asked in Japanese, answered in English.
        self.assertEqual(probe.detect_language(self.SAMPLES["en"]), "en")


class ComprehensionTests(unittest.TestCase):
    """The probe that sends real material and grades one fact from it."""

    FIXTURE = {"expect": "/etc/passwd"}

    def test_the_fact_is_graded_by_substring_not_by_a_model(self):
        found, _ = probe.graded("It is /etc/passwd.", self.FIXTURE)
        self.assertTrue(found)
        found, _ = probe.graded("/ETC/PASSWD", self.FIXTURE)
        self.assertTrue(found)

    def test_the_wrong_file_is_a_miss(self):
        found, _ = probe.graded("/etc/shadow, it holds the hashes.",
                                self.FIXTURE)
        self.assertFalse(found)

    def test_it_reports_the_language_alongside_the_fact(self):
        found, lang = probe.graded("/etc/passwd. Ese archivo contiene las "
                                   "cuentas de usuario locales.",
                                   self.FIXTURE)
        self.assertTrue(found)
        self.assertEqual(lang, "es")


class FixtureTests(unittest.TestCase):
    """The comprehension fixture has to keep matching the corpus.

    The excerpt is read from the tree at probe time, so regenerating that topic
    can silently make the question unanswerable — and every model would then be
    reported as failing a question the material no longer contains. This test
    costs nothing and catches it in `make verify`.
    """

    def setUp(self):
        import yaml
        self.fixture = yaml.safe_load(probe.MATERIAL.read_text())

    def test_every_language_asked_about_has_material_that_answers_it(self):
        for lang in self.fixture["questions"]:
            with self.subTest(lang=lang):
                excerpt = probe.material(lang, self.fixture)
                self.assertTrue(excerpt, f"no material for {lang}")
                self.assertIn(self.fixture["expect"], excerpt,
                              f"{self.fixture['cert']}/{self.fixture['topic']}/"
                              f"{lang} no longer contains the expected answer — "
                              f"pick another topic or another fact")

    def test_the_excerpt_is_cut_at_a_line_boundary(self):
        excerpt = probe.material("en", self.fixture)
        self.assertLessEqual(len(excerpt), self.fixture["excerpt_chars"])
        self.assertFalse(excerpt.endswith("\n"))

    def test_the_probe_sends_the_pages_own_system_prompt(self):
        # If these drift apart the probe grades a request the page never makes.
        page = (Path(__file__).resolve().parents[1] / "teach" / "web"
                / "index.html").read_text()
        self.assertIn("Use ONLY the material below.", page)
        self.assertIn("Use ONLY the material below.", probe.STUDY_SYSTEM)


class CatalogueWriterTests(unittest.TestCase):
    """models.yaml is rewritten by two scripts; both must leave it readable."""

    SAMPLE = """# why this list is curated
# and what disqualifies a model
checked: '2026-09-10'
tiers:
  low:
    - id: openai/gpt-5-mini
      name: GPT-5 Mini
      in: 0.25
"""

    def test_the_header_and_the_shape_survive_a_rewrite(self):
        path = Path(tempfile.mkdtemp()) / "models.yaml"
        path.write_text(self.SAMPLE)
        data = catalog.load_models(path)
        data["tiers"]["low"][0]["thinking"] = "always"
        catalog.save_models(data, path)
        written = path.read_text()

        # The criteria are the only record of how the list was chosen.
        self.assertIn("# why this list is curated", written)
        # Indented sequences, or every probe produces a whole-file diff.
        self.assertIn("\n    - id: openai/gpt-5-mini", written)
        self.assertEqual(catalog.load_models(path)["tiers"]["low"][0]["thinking"],
                         "always")


if __name__ == "__main__":
    unittest.main()
