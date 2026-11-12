"""scripts/fix_citation.py: a moved URL is fixed in every language and the chain stays honest.

A translation that was current before the edit is current after it; one that was stale stays stale.
"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_a_longer_url_with_the_same_prefix_is_refused_and_nothing_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp))
            longer = OLD + "sub/page.html#frag"
            (d / "en" / "exercises.md").write_text(f"# E\nSee {longer}\n", encoding="utf-8")
            before = (d / "en" / "content.md").read_text(encoding="utf-8")
            with self.assertRaises(SystemExit) as raised:
                fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp))
            self.assertIn(longer, str(raised.exception))
            self.assertEqual((d / "en" / "content.md").read_text(encoding="utf-8"), before)

    def test_trailing_punctuation_is_not_part_of_the_url(self):
        text, n, longer = fix_citation.replace_url(f"see {OLD}. And ({OLD}), or <{OLD}>", OLD, NEW)
        self.assertEqual((n, longer), (3, []))
        self.assertEqual(text, f"see {NEW}. And ({NEW}), or <{NEW}>")

    def test_a_repeated_hash_aborts_before_any_file_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp))
            meta = d / "es" / "meta.yaml"
            sha = translation_source_sha256(d, "en")
            meta.write_text(meta.read_text(encoding="utf-8") + f"# was {sha}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp))
            self.assertIn(OLD, (d / "en" / "content.md").read_text(encoding="utf-8"))

    def test_crlf_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp))
            (d / "en" / "content.md").write_bytes(f"# T\r\nSee {OLD}\r\n".encode())
            fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp))
            self.assertEqual((d / "en" / "content.md").read_bytes(), f"# T\r\nSee {NEW}\r\n".encode())

    def test_dry_run_reports_only_real_restamps_and_divergence(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = topic(Path(tmp))
            (d / "en" / "content.md").write_text("# T\nnothing cited\n", encoding="utf-8")
            sha = translation_source_sha256(d, "en")
            (d / "es" / "meta.yaml").write_text(f"translated_from: en\nsource_sha256: {sha}\n", encoding="utf-8")
            report = fix_citation.fix("c", "1.1", OLD, NEW, Path(tmp), dry_run=True)
            self.assertFalse(any(line.startswith("re-stamp") for line in report))  # the source did not change
            self.assertTrue(any("has diverged" in line for line in report))

    def test_a_redirect_is_not_a_200(self):
        response = mock.MagicMock(status=200)
        response.geturl.return_value = NEW + "index.html"
        response.__enter__.return_value = response
        with mock.patch("urllib.request.urlopen", return_value=response):
            self.assertEqual(fix_citation.resolves(NEW), (False, NEW + "index.html"))
            response.geturl.return_value = NEW
            self.assertEqual(fix_citation.resolves(NEW), (True, NEW))

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
