"""A snapshot must be refused when the source document does not support it.

Seven certifications were frozen from their *overview* page, which lists chapter
titles and no objectives. The extraction returned the chapter titles, the weights
came back as 100 divided by their count, and every downstream check passed —
because every file it produced was genuinely good. The defect was the list of
topics, and nothing looked at that.

Both checks derive from the fetched document itself, so neither is specific to a
vendor, an exam or a page layout.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from teach.core import tracker  # noqa: E402

class SyllabusCoverageTests(unittest.TestCase):
    """A snapshot must be refused when the document does not support it.

    Seven certifications were frozen from their overview page, which lists
    chapter titles and no objectives. The extraction returned the chapter
    titles, the weights were 100 divided by their count, and every downstream
    check passed because every file it produced was genuinely good.
    """

    PAGE = ("351.1 Virtualization Concepts 351.2 Xen 351.3 QEMU 351.4 Libvirt "
            "351.5 Disk Images 352.1 Container Concepts 352.2 LXC 352.3 Docker "
            "352.4 Orchestration 353.1 Cloud Tools 353.2 Packer 353.3 cloud-init "
            "353.4 Vagrant")

    def test_counts_objectives_and_ignores_page_furniture(self):
        # "160.5" is a price and "100.00" a percentage; both match the shape.
        ids = tracker.objective_ids(self.PAGE + " 160.5 100.00")
        self.assertEqual(len(ids), 13)

    def test_does_not_count_an_objective_the_exam_withdrew(self):
        # LPIC-1 prints "104.4 Removed" so the surviving ids keep their numbers.
        # Counting it demanded a topic for something the exam no longer asks,
        # and rejected a correct 42-topic extraction for missing a phantom.
        page = "104.1 Partitions 104.2 Integrity 104.3 Mounting 104.4 Removed 104.5 Permissions"
        self.assertEqual(tracker.objective_ids(page), {"104.1", "104.2", "104.3", "104.5"})

    def test_unnumbered_document_yields_nothing_rather_than_a_pass(self):
        self.assertEqual(tracker.objective_ids("Domain 1: Full Virtualization"), set())

    def test_rejects_chapter_headings_extracted_from_a_numbered_document(self):
        topics = [{"id": "1.1", "weight": 33.33}, {"id": "1.2", "weight": 33.33},
                  {"id": "1.3", "weight": 33.34}]
        with self.assertRaises(tracker.TrackerError) as caught:
            tracker._reject_unreadable_syllabus(topics, self.PAGE, "u")
        self.assertIn("13 objectives", str(caught.exception))

    def test_rejects_weights_computed_from_the_topic_count(self):
        # Sum is exactly 100, which was the only rule the snapshot ever had.
        topics = [{"id": f"1.{i}", "weight": 25} for i in range(1, 5)]
        with self.assertRaises(tracker.TrackerError) as caught:
            tracker._reject_unreadable_syllabus(topics, "no numbering here", "u")
        self.assertIn("divided", str(caught.exception))

    def test_normalises_a_published_scale_to_exactly_one_hundred(self):
        # LPIC-3 305 prints weights totalling 57. The first real extraction was
        # correct and was thrown away because the model rescaled them to 105.26.
        topics = [{"id": f"351.{i}", "weight": w} for i, w in
                  enumerate([6, 3, 4, 9, 3, 7, 6, 9, 3, 2, 2, 3, 3], 1)]
        tracker.normalise_weights(topics)
        self.assertEqual(round(sum(t["weight"] for t in topics), 2), 100.0)
        # Proportions survive: Libvirt (9) stays three times Xen (3).
        self.assertAlmostEqual(topics[3]["weight"] / topics[1]["weight"], 3.0, places=1)

    def test_normalising_does_not_disguise_weights_taken_from_the_count(self):
        topics = [{"id": f"1.{i}", "weight": 5} for i in range(1, 5)]
        tracker.normalise_weights(topics)
        with self.assertRaises(tracker.TrackerError):
            tracker._reject_unreadable_syllabus(topics, "no numbering", "u")

    def test_accepts_equal_weights_the_document_actually_publishes(self):
        # CNCF publishes CAPA as five domains at 20% each. Rejecting that would
        # block a correct syllabus for having the shape of a wrong one, so the
        # distinction is whether the DOCUMENT prints a weight per topic.
        page = ("| Argo Project Fundamentals | 20% | | Argo Workflows | 20% | "
                "| Argo CD | 20% | | Argo Rollouts | 20% | | Argo Events | 20% |")
        topics = [{"id": f"{i}.1", "weight": 20} for i in range(1, 6)]
        tracker._reject_unreadable_syllabus(topics, page, "u")

    def test_accepts_an_even_split_when_the_vendor_publishes_no_weights(self):
        # HashiCorp lists Terraform objectives with no weighting at all. Declared
        # by a person in catalog.yaml, the even split is the honest answer.
        topics = [{"id": f"1.{i}", "weight": 25} for i in range(1, 5)]
        tracker._reject_unreadable_syllabus(topics, "no numbering", "u",
                                            weights_unpublished=True)

    def test_declaring_no_weights_does_not_excuse_missing_objectives(self):
        topics = [{"id": "1.1", "weight": 50}, {"id": "1.2", "weight": 50}]
        with self.assertRaises(tracker.TrackerError):
            tracker._reject_unreadable_syllabus(topics, self.PAGE, "u",
                                                weights_unpublished=True)

    def test_strips_backend_diagnostics_that_are_not_the_answer(self):
        # A CAPA snapshot died at line 2 on "Client.listTools() called but
        # server has no tools" — a model call thrown away for a diagnostic that
        # has nothing to do with the content.
        noisy = "version: '1.0'\nClient.listTools() called but server has no tools\ntopics: []"
        cleaned = "\n".join(l for l in noisy.splitlines()
                            if not tracker.CLI_NOISE.match(l))
        self.assertNotIn("listTools", cleaned)
        self.assertIn("version", cleaned)

    def test_accepts_a_full_extraction(self):
        topics = [{"id": f"351.{i}", "weight": w} for i, w in
                  enumerate([10, 5, 7, 15, 5, 12, 10, 15, 5, 4, 4, 4, 4], 1)]
        tracker._reject_unreadable_syllabus(topics, self.PAGE, "u")


class SnapshotDocumentTests(unittest.TestCase):
    """The snapshot reads the whole objectives document and records its hash (#63; audit 2026-10-20, item 5)."""

    def fetch(self, body: bytes, limit: int = 20000):
        with mock.patch.object(tracker, "_get_bytes", return_value=(body, "text/html")):
            return tracker.fetch_document("https://example.org/objectives", limit=limit)

    def test_returns_the_full_text_and_the_sha256_of_the_bytes(self):
        body = b"<html><body><h1>Objectives</h1><p>1.1 Install</p></body></html>"
        text, digest = self.fetch(body)
        self.assertEqual(text, "Objectives 1.1 Install")
        self.assertEqual(digest, hashlib.sha256(body).hexdigest())

    def test_refuses_a_document_longer_than_the_limit_instead_of_truncating(self):
        with self.assertRaises(tracker.TrackerError) as raised:
            self.fetch(b"<p>" + b"objective " * 50 + b"</p>", limit=100)
        self.assertIn("refused rather than truncated", str(raised.exception).lower())

    def test_fetch_text_still_cuts_for_its_other_callers(self):
        with mock.patch.object(tracker, "_get_bytes", return_value=(b"<p>abcdef</p>", "text/html")):
            self.assertEqual(tracker.fetch_text("https://example.org/x", limit=3), "abc")


class SyncCncfTests(unittest.TestCase):
    """`teach tracker sync` fills `upstream:` and never moves `tracked_version` (#63)."""

    def run_sync(self, cert: dict):
        data = {"certs": {"cka": cert}}
        responses = {
            "contents": [{"name": "CKA_Curriculum_v1.37.pdf"}],
            "commits": [{"sha": "b3c8508", "commit": {"committer": {"date": "2026-10-15T15:49:08Z"}}}],
        }

        class Response:
            def __init__(self, payload):
                self.payload = payload

            def json(self):
                return self.payload

        def fake_get(url):
            return Response(responses["contents" if url.endswith("/contents/") else "commits"])

        with mock.patch.object(tracker, "_get", side_effect=fake_get), \
                mock.patch.object(tracker, "_get_bytes", return_value=(b"%PDF", "application/pdf")), \
                mock.patch.object(tracker.catalog, "load", return_value=data), \
                mock.patch.object(tracker.catalog, "save"):
            changes = tracker.sync_cncf()
        return data["certs"]["cka"], changes

    def test_a_new_upstream_version_goes_to_upstream_not_tracked_version(self):
        cert, changes = self.run_sync({"tracked_version": "1.35", "sources": {}})
        self.assertEqual(cert["tracked_version"], "1.35")
        self.assertEqual(cert["upstream_status"], "outdated")
        self.assertEqual(cert["upstream"]["version"], "1.37")
        self.assertEqual(cert["upstream"]["objectives"],
                         "https://github.com/cncf/curriculum/raw/b3c8508/CKA_Curriculum_v1.37.pdf")
        self.assertEqual(cert["upstream"]["sha256"], hashlib.sha256(b"%PDF").hexdigest())
        self.assertIn("tracked_version stays 1.35", " ".join(changes))

    def test_after_the_switch_the_status_is_current(self):
        cert, _ = self.run_sync({"tracked_version": "1.37", "sources": {},
                                 "upstream": {"version": "1.37", "milestone": "CKA & CKAD v1.37 upgrade"}})
        self.assertEqual((cert["tracked_version"], cert["upstream_status"]), ("1.37", "current"))
        self.assertEqual(cert["upstream"]["milestone"], "CKA & CKAD v1.37 upgrade")


if __name__ == "__main__":
    unittest.main()
