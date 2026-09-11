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
