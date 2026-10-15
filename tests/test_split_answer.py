"""An answer the CLI split across turns is rejected, never saved as its tail.

`claude -p --output-format json` puts only the LAST assistant turn in
`result`. When an answer outgrows the per-message output limit the CLI
continues it in another turn, so `result` is the tail of the material. Found
on lpic-2/200.1 (2026-10-15): 13 KB of a 132 KB answer, starting mid-sentence.
"""
import os
import unittest
from unittest import mock

from teach.core import generator


class SplitAnswerTest(unittest.TestCase):
    def test_one_turn_is_the_whole_answer(self):
        self.assertIsNone(generator._split_answer({"num_turns": 1, "result": "# x"}))

    def test_missing_turn_count_is_not_an_error(self):
        # Defensive like the rest of the envelope parsing: an older CLI that
        # does not report turns must not fail generations that succeeded.
        self.assertIsNone(generator._split_answer({"result": "# x"}))

    def test_several_turns_are_rejected(self):
        reason = generator._split_answer({"num_turns": 2, "result": "seconds`)."})
        self.assertIn("split across 2 turns", reason)
        self.assertIn("max_output_tokens", reason)


class CliEnvTest(unittest.TestCase):
    def test_declared_ceiling_reaches_the_claude_cli(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_CODE_MAX_OUTPUT_TOKENS", None)
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"max_output_tokens": 128000}):
                env = generator._cli_env("claude")
        self.assertEqual(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "128000")

    def test_explicit_environment_wins(self):
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000"}):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"max_output_tokens": 128000}):
                env = generator._cli_env("claude")
        self.assertEqual(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "32000")

    def test_other_backends_are_untouched(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_CODE_MAX_OUTPUT_TOKENS", None)
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"max_output_tokens": 128000}):
                env = generator._cli_env("codex")
        self.assertNotIn("CLAUDE_CODE_MAX_OUTPUT_TOKENS", env)


if __name__ == "__main__":
    unittest.main()
