"""scripts/topic_pr.py and status_matrix --keep-spend: one generated topic leaves its checkout alone.

The plan (languages, authoring language first, models from meta.yaml) is tested on a fake topic; the
keep-spend helpers on strings. `build` drives git and the repo's own scripts, so it is exercised by
running it, not here (its every step is a script that has its own tests).
"""
import subprocess
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

    def test_a_language_without_meta_is_refused_before_git(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp), {"en": {"model": "m"}})
            (d / "es").mkdir()
            with self.assertRaises(SystemExit) as raised:
                topic_pr.plan("c", "1.1", Path(tmp), None)
            self.assertIn("es without meta.yaml", str(raised.exception))

    def test_the_subject_says_translated_only_when_meta_does(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic(Path(tmp), {"en": {"model": "m-en"}, "es": {"model": "m-es"},
                              "de": {"model": "m-de", "translated_from": "en"}})
            p = topic_pr.plan("c", "1.1", Path(tmp), None)
            self.assertEqual(p["translated_from"], {"de": "en", "en": None, "es": None})
        self.assertEqual(topic_pr.subject("c", "1.1", "es", "m-es", None), "feat(c): 1.1 in es, m-es")
        self.assertEqual(topic_pr.subject("c", "1.1", "de", "m", "en"), "feat(c): 1.1 in de, translated from en")

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

    def test_nothing_to_keep_drops_the_machine_footer(self):
        rendered = f"ledger\n\n{self.M}\nlocal\n"
        self.assertEqual(status_matrix.keep_spend(rendered, None), "ledger\n")

    def test_the_committed_footer_is_read_from_git(self):
        footer = status_matrix.committed_spend("HEAD")
        self.assertIsNotNone(footer, "docs/STATUS.md at HEAD has a spend footer")
        self.assertTrue(footer.startswith(self.M))

    def test_an_unknown_flag_fails_loudly(self):
        done = subprocess.run([sys.executable, str(REPO / "scripts" / "status_matrix.py"), "--keep-spnd"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)


class AgainstBase(unittest.TestCase):
    """differs() and footer_kept() on a throwaway git repository."""

    def repo(self, tmp: str) -> Path:
        root = Path(tmp)
        git = lambda *a: subprocess.run(["git", *a], cwd=root, check=True, capture_output=True)  # noqa: E731
        git("init", "-q")
        (root / "docs").mkdir()
        (root / "docs" / "STATUS.md").write_text(f"ledger\n{KeepSpend.M}\ncommitted\n", encoding="utf-8")
        (root / "certs" / "c" / "1.1" / "en").mkdir(parents=True)
        (root / "certs" / "c" / "1.1" / "en" / "content.md").write_text("en\n", encoding="utf-8")
        git("add", ".")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        return root

    def test_only_what_differs_from_the_base_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo(tmp)
            self.assertFalse(topic_pr.differs(root, "HEAD", "certs/c/1.1/en"))
            (root / "certs" / "c" / "1.1" / "es").mkdir()
            (root / "certs" / "c" / "1.1" / "es" / "content.md").write_text("es\n", encoding="utf-8")
            self.assertTrue(topic_pr.differs(root, "HEAD", "certs/c/1.1/es"))
            (root / "certs" / "c" / "1.1" / "en" / "content.md").write_text("en, edited\n", encoding="utf-8")
            self.assertTrue(topic_pr.differs(root, "HEAD", "certs/c/1.1/en"))

    def test_a_changed_spend_footer_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo(tmp)
            status = root / "docs" / "STATUS.md"
            status.write_text(f"new ledger\n{KeepSpend.M}\ncommitted\n", encoding="utf-8")
            self.assertTrue(topic_pr.footer_kept(root, "HEAD"))
            status.write_text(f"new ledger\n{KeepSpend.M}\nthis machine\n", encoding="utf-8")
            self.assertFalse(topic_pr.footer_kept(root, "HEAD"))


if __name__ == "__main__":
    unittest.main()
