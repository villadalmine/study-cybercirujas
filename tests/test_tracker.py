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

import sys
import unittest
from pathlib import Path

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

    def test_accepts_a_full_extraction(self):
        topics = [{"id": f"351.{i}", "weight": w} for i, w in
                  enumerate([10, 5, 7, 15, 5, 12, 10, 15, 5, 4, 4, 4, 4], 1)]
        tracker._reject_unreadable_syllabus(topics, self.PAGE, "u")


if __name__ == "__main__":
    unittest.main()
