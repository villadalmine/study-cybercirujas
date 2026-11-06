"""docs/STATUS.md and docs/MODELS.md are a function of the tree only (#261).

A rendered video (media/ is gitignored) or a recorded completion (usage.jsonl
lives in ~/.local/state) on one machine used to change the committed bytes, so a
refresh on the maintainer's workstation failed CI. These tests put both on disk
and assert the committed renders do not move.
"""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

import model_comparison  # noqa: E402
import status_matrix  # noqa: E402
from teach.core import pipeline  # noqa: E402


def _a_cert_with_video() -> tuple[str, str] | None:
    for cert in pipeline.certs():
        langs = pipeline.video_languages(cert)
        for lang in langs:
            if lang in status_matrix.VIDEO_LANGS:
                return cert, lang
    return None


class TreeOnlyRender(unittest.TestCase):
    def test_untracked_video_does_not_change_status(self):
        pick = _a_cert_with_video()
        if pick is None:
            self.skipTest("no certification declares a video")
        cert, lang = pick
        target = REPO / "media" / "certs" / cert / lang / "video.mp4"
        if target.exists():
            self.skipTest("a real rendered video is already there; not touching it")
        before = status_matrix._render().split(status_matrix.SPEND_MARKER)[0]
        created = []
        path = target
        while not path.parent.exists():
            created.append(path.parent)
            path = path.parent
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"not a video")
        try:
            after = status_matrix._render().split(status_matrix.SPEND_MARKER)[0]
        finally:
            target.unlink()
            for directory in reversed(sorted(created, key=lambda p: len(p.parts))):
                shutil.rmtree(directory, ignore_errors=True)
        self.assertEqual(before, after)

    def test_usage_log_does_not_change_models(self):
        rows = model_comparison.observations(None, local=False)
        if not rows:
            self.skipTest("no generated topics")
        before = model_comparison.render_markdown()
        tmp = Path(tempfile.mkdtemp())
        log = tmp / "usage.jsonl"
        log.write_text("".join(json.dumps({
            "op": "author", "cert": r["cert"], "topic": r["topic"], "lang": r["lang"],
            "output_tokens": 12345, "duration_ms": 60000, "cost_usd": 1.0,
        }) + "\n" for r in rows[:20]))
        saved, model_comparison.USAGE = model_comparison.USAGE, log
        try:
            self.assertEqual(before, model_comparison.render_markdown())
            self.assertNotIn("| 0.0 |", before)
            # the console path still sees the log
            measured = model_comparison.observations(None, local=True)
            self.assertTrue(any(r["tokens"] for r in measured))
        finally:
            model_comparison.USAGE = saved
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
