"""Invalidation cycle triggered by a syllabus change.

Tested because the delicate part is not detecting the change, it is not
declaring it resolved too early: status lives on the topic but content exists
once per language, so clearing the flag when Spanish is rebuilt would leave the
translations describing the old syllabus, silently and permanently. That is the
case covered by `test_regenerating_default_does_not_release_the_rest`.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

CERT_MD = """\
---
cert: testcert
exam: "TEST"
version: '1'
snapshot_date: '2026-07-30'
sources: []
topics:
- id: '1.1'
  title: Changed topic
  topic: 1 - D
  weight: 100
  status: stale
  stale_since: '2026-07-30T03:00:00'
  sources: []
---
# Test
"""

BEFORE_CHANGE = "2026-07-28T10:00:00"
AFTER_CHANGE = "2026-07-30T04:00:00"


class StaleCycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "catalog.yaml").write_text("certs: {}\npaths: {}\n")
        (root / "certs").mkdir()
        (root / "certs" / "testcert.md").write_text(CERT_MD)
        for lang in ("es", "en"):
            directory = root / "certs" / "testcert" / "1.1" / lang
            directory.mkdir(parents=True)
            (directory / "content.md").write_text("# content\n")
            (directory / "meta.yaml").write_text(
                f"generated_at: '{BEFORE_CHANGE}'\nlang: {lang}\n"
            )
        self._prev_root = os.environ.get("TEACH_ROOT")
        os.environ["TEACH_ROOT"] = str(root)

    def tearDown(self) -> None:
        if self._prev_root is None:
            os.environ.pop("TEACH_ROOT", None)
        else:
            os.environ["TEACH_ROOT"] = self._prev_root
        self.tmp.cleanup()

    def _outdated(self) -> list[str]:
        from teach.core import certs

        return certs.topic_outdated_langs("testcert", "1.1")

    def _regenerate(self, lang: str, when: str = AFTER_CHANGE) -> None:
        from teach.core import certs

        meta = certs.content_dir("testcert", "1.1") / lang / "meta.yaml"
        meta.write_text(f"generated_at: '{when}'\nlang: {lang}\n")

    def test_content_older_than_the_change_is_flagged(self) -> None:
        self.assertEqual(self._outdated(), ["es", "en"])

    def test_regenerating_default_does_not_release_the_rest(self) -> None:
        """The case that drove the design: rebuilding Spanish cannot mark the
        topic current while translations are still pending."""
        from teach.core import certs

        self._regenerate("es")
        self.assertEqual(self._outdated(), ["en"])
        self.assertEqual(certs.get_topic("testcert", "1.1")["status"], "stale")

    def test_cycle_closes_when_none_are_left(self) -> None:
        from teach.core import certs

        self._regenerate("es")
        self._regenerate("en")
        self.assertEqual(self._outdated(), [])

        certs.clear_topic_stale("testcert", "1.1")
        topic = certs.get_topic("testcert", "1.1")
        self.assertEqual(topic["status"], "generated")
        self.assertNotIn("stale_since", topic)

    def test_without_a_timestamp_nothing_is_outdated(self) -> None:
        """A topic that never changed reports no outdated languages, however
        old its content is."""
        from teach.core import certs

        certs.clear_topic_stale("testcert", "1.1")
        self.assertEqual(self._outdated(), [])

    def test_unreadable_meta_counts_as_outdated(self) -> None:
        """When in doubt, regenerate: if freshness cannot be proven, it is not
        assumed."""
        from teach.core import certs

        (certs.content_dir("testcert", "1.1") / "es" / "meta.yaml").unlink()
        self._regenerate("en")
        self.assertEqual(self._outdated(), ["es"])


class SnapshotStatusTest(unittest.TestCase):
    """Change detection in the snapshot, touching no disk and spending no budget."""

    def _apply(self, incoming, existing):
        from teach.core import tracker

        return tracker._apply_snapshot_status(
            incoming, existing, "http://source", "2026-07-30T03:00:00"
        )

    def test_classifies_new_changed_and_unchanged(self) -> None:
        existing = {
            "1.1": {"id": "1.1", "title": "Old", "topic": "1 - D", "weight": 10,
                    "status": "generated"},
            "1.2": {"id": "1.2", "title": "Same", "topic": "1 - D", "weight": 10,
                    "status": "generated"},
        }
        incoming = [
            {"id": "1.1", "title": "New", "topic": "1 - D", "weight": 10},
            {"id": "1.2", "title": "Same", "topic": "1 - D", "weight": 10},
            {"id": "1.3", "title": "Fresh", "topic": "1 - D", "weight": 10},
        ]
        added, stale, edited = self._apply(incoming, existing)

        self.assertEqual((added, stale, edited), (["1.3"], ["1.1"], []))
        by_id = {t["id"]: t for t in incoming}
        self.assertEqual(by_id["1.1"]["stale_since"], "2026-07-30T03:00:00")
        self.assertNotIn("stale_since", by_id["1.2"])
        self.assertEqual(by_id["1.2"]["status"], "generated")
        self.assertEqual(by_id["1.3"]["status"], "pending")

    def test_weight_also_invalidates(self) -> None:
        """Weight sets the depth requested from the model, so changing it
        changes the material expected."""
        existing = {"1.1": {"id": "1.1", "title": "T", "topic": "1 - D", "weight": 10,
                            "status": "generated"}}
        incoming = [{"id": "1.1", "title": "T", "topic": "1 - D", "weight": 25}]
        _, stale, _ = self._apply(incoming, existing)
        self.assertEqual(stale, ["1.1"])

    def test_edited_is_never_overwritten(self) -> None:
        """Hand-enriched content is preserved and reported separately so a
        person decides, rather than being discarded automatically."""
        existing = {"1.1": {"id": "1.1", "title": "Old", "topic": "1 - D", "weight": 10,
                            "status": "edited"}}
        incoming = [{"id": "1.1", "title": "New", "topic": "1 - D", "weight": 10}]
        _, stale, edited = self._apply(incoming, existing)

        self.assertEqual(stale, [])
        self.assertEqual(edited, ["1.1"])
        self.assertEqual(incoming[0]["status"], "edited")


if __name__ == "__main__":
    unittest.main()
