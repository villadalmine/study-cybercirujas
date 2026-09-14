"""The out-of-band guard: what the page is told when the catalogue goes stale.

`models.yaml` is frozen on purpose — it is what the probe measured against — so
it can and does go stale. On 2026-09-14 the page was showing `deepseek-v4-pro`
at $0.9553/$1.9105 while it cost $1.60/$3.20: 67% more than a student choosing
it for the price was told. The weekly CronJob had found it and written it to a
pod log nobody reads.

These tests hold the two halves of the fix: the comparison is right, and it
CANNOT take the page down when the provider it consults is unreachable.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import unittest

from teach.core import models_live


def catalogue(*entries) -> dict:
    return {"tiers": {"low": list(entries)}}


def priced(model_id: str, prompt: float, completion: float) -> dict:
    """One model as OpenRouter publishes it: per-token strings, not per-million."""
    return {model_id: {"pricing": {"prompt": str(prompt / 1e6),
                                   "completion": str(completion / 1e6)}}}


class CompareTests(unittest.TestCase):
    def test_a_catalogue_that_matches_reports_nothing(self):
        # An empty result is the good case, and the page adds nothing to a row
        # it has no finding for.
        frozen = catalogue({"id": "a", "in": 1, "out": 2})
        self.assertEqual(models_live.compare(frozen, priced("a", 1, 2)), {})

    def test_the_real_drift_is_caught(self):
        # The numbers that were live on the site, and wrong.
        frozen = catalogue({"id": "deepseek/deepseek-v4-pro",
                            "in": 0.9553, "out": 1.9105})
        found = models_live.compare(
            frozen, priced("deepseek/deepseek-v4-pro", 1.6, 3.2))
        self.assertEqual(found["deepseek/deepseek-v4-pro"],
                         {"live_in": 1.6, "live_out": 3.2})

    def test_a_model_that_vanished_is_flagged_not_priced(self):
        frozen = catalogue({"id": "gone/model", "in": 1, "out": 2})
        self.assertEqual(models_live.compare(frozen, {}),
                         {"gone/model": {"gone": True}})

    def test_fourth_decimal_wobble_is_not_a_finding(self):
        # Providers move in the noise. Reporting that trains people to ignore
        # the report, which is how the 67% one went unread.
        frozen = catalogue({"id": "a", "in": 1.0, "out": 2.0})
        self.assertEqual(models_live.compare(frozen, priced("a", 1.0001, 2.0001)),
                         {})

    def test_a_free_model_that_starts_charging_is_a_finding(self):
        frozen = catalogue({"id": "x:free", "in": 0, "out": 0})
        found = models_live.compare(frozen, priced("x:free", 0.5, 1.0))
        self.assertEqual(found["x:free"], {"live_in": 0.5, "live_out": 1.0})


class AnnotateTests(unittest.TestCase):
    def test_the_frozen_numbers_are_never_overwritten(self):
        # The frozen price is what the probe measured against. Swapping it would
        # erase the very fact the page needs to show.
        frozen = catalogue({"id": "a", "in": 1, "out": 2})
        served = models_live.annotate(frozen, {"a": {"live_in": 9, "live_out": 9}})
        entry = served["tiers"]["low"][0]
        self.assertEqual((entry["in"], entry["out"]), (1, 2))
        self.assertEqual((entry["live_in"], entry["live_out"]), (9, 9))

    def test_the_catalogue_passed_in_is_not_mutated(self):
        # It is the module-level cache in catalog.load_models' caller; mutating
        # it would make the drift permanent in memory and unexplainable on disk.
        frozen = catalogue({"id": "a", "in": 1, "out": 2})
        models_live.annotate(frozen, {"a": {"gone": True}})
        self.assertNotIn("gone", frozen["tiers"]["low"][0])

    def test_no_findings_serves_the_catalogue_unchanged(self):
        frozen = catalogue({"id": "a", "in": 1, "out": 2})
        self.assertEqual(models_live.annotate(frozen, {}), frozen)


class EndpointTests(unittest.TestCase):
    """The guard must never be able to break the page it protects."""

    def setUp(self):
        from fastapi.testclient import TestClient

        from teach import api
        self.api = api
        api._LIVE.update({"findings": {}, "checked_at": None})
        self.client = TestClient(api.app)

    def tearDown(self):
        self.api._LIVE.update({"findings": {}, "checked_at": None})

    def test_an_unreachable_provider_still_serves_the_catalogue(self):
        # Degraded to exactly today's behaviour — the frozen catalogue — never
        # a blank page and never a 500.
        def explode(*args, **kwargs):
            raise RuntimeError("openrouter is down")

        original = self.api.models_live.upstream
        self.api.models_live.upstream = explode
        try:
            self.api._refresh_live(force=True)
            response = self.client.get("/api/models")
        finally:
            self.api.models_live.upstream = original
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["tiers"])
        self.assertFalse(response.json()["live_checked"])

    def test_findings_reach_the_page(self):
        self.api._LIVE.update({"findings": {"openai/gpt-5-mini":
                                            {"live_in": 9.0, "live_out": 9.0}},
                               "checked_at": 1.0})
        served = self.client.get("/api/models").json()
        entry = [m for tier in served["tiers"].values() for m in tier
                 if m["id"] == "openai/gpt-5-mini"][0]
        self.assertEqual(entry["live_in"], 9.0)
        self.assertTrue(served["live_checked"])

    def test_a_fresh_check_is_not_repeated_on_every_request(self):
        # The check is out of band AND rate-limited; a busy page must not turn
        # into a crawler against openrouter.ai.
        import time

        calls = []
        original = self.api.models_live.upstream
        self.api.models_live.upstream = lambda *a, **k: calls.append(1) or {}
        try:
            self.api._LIVE.update({"findings": {}, "checked_at": time.time()})
            self.api._refresh_live()
            self.assertEqual(calls, [])
            self.api._refresh_live(force=True)
            self.assertEqual(len(calls), 1)
        finally:
            self.api.models_live.upstream = original


if __name__ == "__main__":
    unittest.main()
