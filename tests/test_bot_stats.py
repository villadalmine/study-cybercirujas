"""Anonymous by construction: what the counters can and cannot hold.

The study bot runs in the student's browser, so the only way to know which
models get used is for the page to say so. These tests hold the properties that
make saying so safe — and they are about the SHAPE of the stored data, because
that is what makes the guarantee real rather than a promise in a docstring.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from teach.core import bot_stats, certs

VALID = {"model": "openai/gpt-5-mini", "tier": "low", "intent": "quiz",
         "material": "both", "reasoning": "off", "lang": "es"}


class AcceptanceTests(unittest.TestCase):
    """Every field is a closed set. An unknown value is refused, not cleaned."""

    def test_a_well_formed_event_is_accepted(self):
        self.assertEqual(bot_stats.accepted(VALID), VALID)

    def test_a_model_outside_the_catalogue_is_refused(self):
        # This is what keeps the key space bounded, and what stops the endpoint
        # being used to store arbitrary strings on our disk.
        self.assertIsNone(bot_stats.accepted({**VALID, "model": "evil/anything"}))

    def test_one_bad_field_refuses_the_whole_event(self):
        # Not per-field cleaning: a request with a field we do not recognise is
        # a request we do not understand, and guessing the rest is how a bounded
        # key space stops being bounded.
        for field in ("tier", "intent", "material", "reasoning", "lang"):
            with self.subTest(field=field):
                self.assertIsNone(bot_stats.accepted({**VALID, field: "../etc"}))

    def test_the_languages_are_the_ones_the_site_serves(self):
        for lang in certs.LANGS:
            with self.subTest(lang=lang):
                self.assertIsNotNone(bot_stats.accepted({**VALID, "lang": lang}))

    def test_a_missing_field_is_refused(self):
        for field in VALID:
            with self.subTest(field=field):
                partial = {k: v for k, v in VALID.items() if k != field}
                self.assertIsNone(bot_stats.accepted(partial))


class StoredShapeTests(unittest.TestCase):
    """Counters, never rows — the property the whole design rests on."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        os.environ["TEACH_BOT_STATS"] = str(self.dir / "bot-stats.json")

    def tearDown(self):
        os.environ.pop("TEACH_BOT_STATS", None)

    def _stored(self) -> str:
        return Path(os.environ["TEACH_BOT_STATS"]).read_text()

    def _shape(self, data: dict):
        """The file's structure with every count blanked — what must not grow."""
        return {model: {field: (sorted(value) if isinstance(value, dict) else None)
                        for field, value in entry.items()}
                for model, entry in data["models"].items()}

    def test_the_file_does_not_grow_with_the_number_of_answers(self):
        # The property that makes this counters and not a log: fifty more
        # answers add no key anywhere, only larger integers. A row store would
        # gain fifty entries, and fifty entries are fifty things to correlate.
        bot_stats.record(VALID, "2026-09-14")
        before, size = self._shape(bot_stats.load()), len(self._stored())
        for _ in range(50):
            bot_stats.record(VALID, "2026-09-14")
        self.assertEqual(self._shape(bot_stats.load()), before)
        self.assertEqual(bot_stats.load()["answers"], 51)
        # Only the digits of the counters changed.
        self.assertLess(len(self._stored()) - size, 20)

    def test_no_timestamp_is_written_per_request(self):
        # A per-request time is what would make a rare model correlate with a
        # person. The only date stored is `since`, for the whole file.
        bot_stats.record(VALID, "2026-09-14")
        data = json.loads(self._stored())
        self.assertEqual(data["since"], "2026-09-14")
        entry = data["models"][VALID["model"]]
        self.assertEqual(set(entry) & {"at", "times", "seen", "history"}, set())

    def test_since_is_the_first_day_and_never_moves(self):
        bot_stats.record(VALID, "2026-09-14")
        bot_stats.record(VALID, "2026-12-25")
        self.assertEqual(bot_stats.load()["since"], "2026-09-14")

    def test_a_refused_event_writes_nothing_at_all(self):
        self.assertFalse(bot_stats.record({**VALID, "model": "evil/x"}, "2026-09-14"))
        self.assertFalse(Path(os.environ["TEACH_BOT_STATS"]).exists())

    def test_the_breakdown_counts_each_characteristic_independently(self):
        bot_stats.record({**VALID, "lang": "es", "intent": "quiz"}, "2026-09-14")
        bot_stats.record({**VALID, "lang": "en", "intent": "explain"}, "2026-09-14")
        entry = bot_stats.load()["models"][VALID["model"]]
        self.assertEqual(entry["count"], 2)
        self.assertEqual(entry["lang"], {"es": 1, "en": 1})
        self.assertEqual(entry["intent"], {"quiz": 1, "explain": 1})

    def test_a_corrupt_file_does_not_take_the_endpoint_down(self):
        Path(os.environ["TEACH_BOT_STATS"]).write_text("{ not json")
        self.assertEqual(bot_stats.load()["models"], {})
        self.assertTrue(bot_stats.record(VALID, "2026-09-14"))

    def test_an_unwritable_path_is_swallowed(self):
        # Telemetry that can break an answer is worse than no telemetry.
        os.environ["TEACH_BOT_STATS"] = "/proc/nope/bot-stats.json"
        self.assertFalse(bot_stats.record(VALID, "2026-09-14"))


class EndpointTests(unittest.TestCase):
    """The HTTP surface, including the body it must refuse outright."""

    def setUp(self):
        from fastapi.testclient import TestClient

        from teach.api import app
        self.dir = Path(tempfile.mkdtemp())
        os.environ["TEACH_BOT_STATS"] = str(self.dir / "bot-stats.json")
        self.client = TestClient(app)

    def tearDown(self):
        os.environ.pop("TEACH_BOT_STATS", None)

    def test_a_body_carrying_anything_extra_is_refused(self):
        # The guarantee that matters: even a bug in the page cannot deliver the
        # student's key to this server, because a body with a seventh field is
        # rejected before it is read.
        response = self.client.post("/api/bot/used",
                                    json={**VALID, "key": "sk-or-v1-example"})
        self.assertEqual(response.status_code, 422)
        self.assertFalse(Path(os.environ["TEACH_BOT_STATS"]).exists())

    def test_a_valid_event_is_counted_and_readable(self):
        self.assertTrue(self.client.post("/api/bot/used", json=VALID).json()["counted"])
        stats = self.client.get("/api/bot/stats").json()
        self.assertEqual(stats["answers"], 1)
        self.assertEqual(stats["models"][VALID["model"]]["count"], 1)

    def test_a_rejected_value_answers_200_without_saying_why(self):
        # An endpoint that reports which values it accepts can be probed for
        # them. The page cannot act on the difference either way.
        response = self.client.post("/api/bot/used",
                                    json={**VALID, "model": "evil/x"})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["counted"])


if __name__ == "__main__":
    unittest.main()
