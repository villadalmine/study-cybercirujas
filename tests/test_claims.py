"""Per-topic claims: several agents at once, never the same topic twice.

The granularity is the point. A single global lock was safe and wrong: it made
two agents working on unrelated certifications queue behind each other, and an
agent blocked for no visible reason writes its own runner that skips the lock —
which is exactly how an unsynchronised orchestrator appeared on 2026-08-06.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import multiprocessing
import tempfile
import unittest
from pathlib import Path

from teach.core import claims


def _try_claim(directory: str, key: tuple[str, str, str], result) -> None:
    """Claim from a separate PROCESS: flock is per open file description, so a
    second attempt inside the same process can behave differently from a real
    competing agent."""
    claims.CLAIM_DIR = Path(directory)
    with claims.claim(*key) as got:
        result.value = 1 if got else 0


class ClaimTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._original = claims.CLAIM_DIR
        claims.CLAIM_DIR = Path(self._tmp.name)

    def tearDown(self):
        claims.CLAIM_DIR = self._original
        self._tmp.cleanup()

    def test_a_free_topic_is_granted(self):
        with claims.claim("cks", "1.1", "en") as got:
            self.assertTrue(got)

    def test_the_same_topic_is_refused_while_held(self):
        with claims.claim("cks", "1.1", "en") as first:
            self.assertTrue(first)
            with claims.claim("cks", "1.1", "en") as second:
                self.assertFalse(second)

    def test_a_different_topic_is_granted_at_the_same_time(self):
        """The whole reason this is per topic and not global."""
        with claims.claim("cks", "1.1", "en") as first:
            self.assertTrue(first)
            with claims.claim("cks", "1.2", "en") as other_topic:
                self.assertTrue(other_topic)
            with claims.claim("kcna", "1.1", "en") as other_cert:
                self.assertTrue(other_cert)
            with claims.claim("cks", "1.1", "es") as other_lang:
                self.assertTrue(other_lang)

    def test_a_claim_is_released_when_the_block_exits(self):
        with claims.claim("cks", "1.1", "en"):
            pass
        self.assertFalse(claims.is_claimed("cks", "1.1", "en"))
        with claims.claim("cks", "1.1", "en") as again:
            self.assertTrue(again)

    def test_a_claim_does_not_survive_the_process_that_held_it(self):
        """A lock file checked with exists() would strand a topic forever after a
        crash. Holding it on an open descriptor means the kernel releases it."""
        result = multiprocessing.Value("i", -1)
        process = multiprocessing.Process(
            target=_try_claim, args=(self._tmp.name, ("cks", "9.9", "en"), result)
        )
        process.start()
        process.join()
        self.assertEqual(result.value, 1)
        self.assertFalse(claims.is_claimed("cks", "9.9", "en"))

    def test_active_lists_what_is_being_worked_on(self):
        with claims.claim("cks", "3.1", "en"):
            self.assertIn(("cks", "3.1", "en"), claims.active())
        self.assertEqual(claims.active(), [])


if __name__ == "__main__":
    unittest.main()
