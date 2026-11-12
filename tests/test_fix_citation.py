"""scripts/fix_citation.py: a moved URL is fixed in every language and the chain stays honest.

A translation that was current before the edit is current after it; one that was stale stays stale.
"""
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

import fix_citation  # noqa: E402
from teach.core.certs import chain_sha256, translation_source_sha256  # noqa: E402

OLD = "https://docs.example.com/old-guide/"
NEW = "https://docs.example.com/guide/"


def topic(root: Path, es_current: bool = True) -> Path:
    d = root / "certs" / "c" / "1.1"
    for lang in ("en", "es"):
        (d / lang).mkdir(parents=True)
        (d / lang / "content.md").write_text(f"# T\nSee {OLD} and {OLD}.\n", encoding="utf-8")
        (d / lang / "exercises.md").write_text("# E\n", encoding="utf-8")
    (d / "en" / "meta.yaml").write_text("model: m\n", encoding="utf-8")
    sha = translation_source_sha256(d, "en") if es_current else "0" * 64
    (d / "es" / "meta.yaml").write_text(f"model: m\ntranslated_from: en\n# kept\nsource_sha256: {sha}\n", encoding="utf-8")
    (d / "lab").mkdir()
    lab_sha = chain_sha256(d / "en" / "content.md")
    (d / "lab" / "lab.yaml").write_text(
        f"schema_version: 2\nderived_from:\n  content: certs/c/1.1/en/content.md\n  content_sha256: {lab_sha}\n",
        encoding="utf-8")
    return d


class Fix(unittest.TestCase):
    def test_every_language_is_fixed_and_current_links_are_restamped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = topic(root)
            report = fix_citation.fix("c", "1.1", OLD, NEW, root)
            for lang in ("en", "es"):
                text = (d / lang / "content.md").read_text(encoding="utf-8")
                self.assertNotIn(OLD, text)
                self.assertEqual(text.count(NEW), 2)
            es = (d / "es" / "meta.yaml").read_text(encoding="utf-8")
            self.assertIn(f"source_sha256: {translation_source_sha256(d, 'en')}", es)
            self.assertIn("# kept", es)
            self.assertIn(chain_sha256(d / "en" / "content.md"), (d / "lab" / "lab.yaml").read_text(encoding="utf-8"))
            self.assertTrue(any("re-stamp" in line for line in report))

    def test_a_stale_translation_stays_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp), es_current=False)
            fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp))
            self.assertIn("source_sha256: " + "0" * 64, (d / "es" / "meta.yaml").read_text(encoding="utf-8"))

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp))
            before = (d / "es" / "meta.yaml").read_text(encoding="utf-8")
            report = fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp), dry_run=True)
            self.assertIn(OLD, (d / "en" / "content.md").read_text(encoding="utf-8"))
            self.assertEqual((d / "es" / "meta.yaml").read_text(encoding="utf-8"), before)
            self.assertEqual(len([line for line in report if line.startswith("replace")]), 2)

    def test_refusals(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic(Path(tmp))
            for old, new in ((OLD, "ftp://x"), (OLD, OLD), ("https://not.cited/", NEW)):
                with self.assertRaises(SystemExit):
                    fix_citation.fix("c", "1.1", old, new, Path(tmp))
            with self.assertRaises(SystemExit):
                fix_citation.fix("c", "9.9", OLD, NEW, Path(tmp))


if __name__ == "__main__":
    unittest.main()
