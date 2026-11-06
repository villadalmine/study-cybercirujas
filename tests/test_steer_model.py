"""`scripts/steer.py model`: the authoring model is set by command, never by hand."""
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

import steer  # noqa: E402

SAMPLE = """languages:
  default: [en, es]
generation:
  model: claude-opus-5
  # why xhigh: a comment that must survive
  effort: xhigh
  max_output_tokens: 128000

budget:
  topics_per_run: 2
"""


class SteerModel(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.file = self.dir / "pipeline.yaml"
        self.file.write_text(SAMPLE)
        self.saved, steer.PIPELINE = steer.PIPELINE, self.file

    def tearDown(self):
        steer.PIPELINE = self.saved
        shutil.rmtree(self.dir)

    def test_sets_model_and_effort_keeping_comments(self):
        self.assertTrue(steer.set_generation("claude-opus-5-5", "default"))
        text = self.file.read_text()
        self.assertIn("  model: claude-opus-5-5\n", text)
        self.assertIn("  effort: default\n", text)
        self.assertIn("# why xhigh: a comment that must survive", text)
        self.assertIn("  max_output_tokens: 128000\n", text)
        self.assertIn("  topics_per_run: 2\n", text)

    def test_idempotent(self):
        steer.set_generation("claude-opus-5-5", "default")
        before = self.file.read_text()
        self.assertFalse(steer.set_generation("claude-opus-5-5", "default"))
        self.assertEqual(before, self.file.read_text())

    def test_model_only_leaves_effort(self):
        steer.set_generation("claude-opus-5-5", None)
        self.assertIn("  effort: xhigh\n", self.file.read_text())

    def test_refuses_aliases_and_1m_variants(self):
        for bad in ("opus", "claude-opus-5[1m]", "claude-opus"):
            with self.assertRaises(SystemExit):
                steer.set_generation(bad, None)
        self.assertEqual(SAMPLE, self.file.read_text())

    def test_refuses_unknown_effort(self):
        with self.assertRaises(SystemExit):
            steer.set_generation("claude-opus-5-5", "extreme")


if __name__ == "__main__":
    unittest.main()
