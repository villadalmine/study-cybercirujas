"""scripts/topic_pr.py and status_matrix --keep-spend: one generated topic leaves its checkout alone.

The plan (languages, authoring language first, models from meta.yaml) is tested on a fake topic; the
keep-spend helpers on strings. `build` drives git and the repo's own scripts, so it is exercised by
running it, not here (its every step is a script that has its own tests).
"""
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

import status_matrix  # noqa: E402
import topic_pr  # noqa: E402


def topic(root: Path, langs: dict[str, dict]) -> Path:
    d = root / "certs" / "c" / "1.1"
    for lang, meta in langs.items():
        (d / lang).mkdir(parents=True)
        (d / lang / "meta.yaml").write_text("".join(f"{k}: {v}\n" for k, v in meta.items()), encoding="utf-8")
    return d


class Plan(unittest.TestCase):
    def test_authoring_language_first_and_models_from_meta(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            d = topic(root, {"es": {"model": "m-es", "translated_from": "en"}, "en": {"model": "m-en"},
                             "de": {"model": "m-de", "translated_from": "en"}})
            (d / "lab").mkdir()
            p = topic_pr.plan("c", "1.1", root, "284")
            self.assertEqual(p["langs"], ["en", "de", "es"])
            self.assertEqual(p["models"], {"en": "m-en", "de": "m-de", "es": "m-es"})
            self.assertTrue(p["lab"])
            self.assertEqual(p["branch"], "feat/284-c-1.1")
            self.assertEqual(p["worktree"], str(Path(tmp) / "repo-c-1.1"))

    def test_without_an_issue_the_branch_has_no_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic(Path(tmp), {"en": {"model": "m"}})
            self.assertEqual(topic_pr.plan("c", "1.1", Path(tmp), None)["branch"], "feat/c-1.1")

    def test_refused_without_the_topic_or_without_a_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                topic_pr.plan("c", "9.9", Path(tmp), None)
            topic(Path(tmp), {"en": {"backend": "claude"}})
            with self.assertRaises(SystemExit) as raised:
                topic_pr.plan("c", "1.1", Path(tmp), None)
            self.assertIn("no model", str(raised.exception))

    def test_trailers(self):
        self.assertEqual(topic_pr.trailers("claude-code", "m", "284", ("Co-Authored-By: X <x@y>",)),
                         ["-m", "Part of #284", "-m", "Agent: claude-code\nModel: m\nCo-Authored-By: X <x@y>"])
        self.assertEqual(topic_pr.trailers("a", "m", None), ["-m", "Agent: a\nModel: m"])


class KeepSpend(unittest.TestCase):
    M = status_matrix.SPEND_MARKER

    def test_the_footer_is_replaced_by_the_committed_one(self):
        rendered = f"# Content Status\nnew ledger\n\n{self.M}\n\n- 9 completions (this machine)\n"
        committed = f"{self.M}\n\n- 3 completions (committed)\n"
        self.assertEqual(status_matrix.keep_spend(rendered, committed),
                         f"# Content Status\nnew ledger\n\n{committed}")

    def test_nothing_to_keep_leaves_the_render(self):
        rendered = f"ledger\n{self.M}\nlocal\n"
        self.assertEqual(status_matrix.keep_spend(rendered, None), rendered)

    def test_the_committed_footer_is_read_from_git(self):
        footer = status_matrix.committed_spend("HEAD")
        self.assertTrue(footer is None or footer.startswith(self.M))


if __name__ == "__main__":
    unittest.main()
