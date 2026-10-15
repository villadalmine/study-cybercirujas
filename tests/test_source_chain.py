"""The source chain (docs/PRINCIPLES.md): every link declares its origin, and a changed origin shows."""
import io
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))
import check_citations  # noqa: E402
import check_source_chain  # noqa: E402
from teach.core import certs  # noqa: E402
from teach.lab import spec  # noqa: E402

SYLLABUS = textwrap.dedent("""\
    ---
    cert: demo
    exam: DEMO
    version: '1.0'
    snapshot_date: '2026-10-15'
    sources:
    - https://example.org/demo-objectives.pdf
    topics:
    - id: '1.1'
      title: A topic
    ---
    """)
CONTENT = "# A topic\n\nText.\n\n## 9. References\n\n- https://example.org/docs\n"


class Tree:
    """A minimal repository with one certification, one topic, a translation, a lab and a video script."""

    def __init__(self, tmp: Path):
        self.root = tmp
        (tmp / "certs").mkdir()
        (tmp / "certs" / "demo.md").write_text(SYLLABUS, encoding="utf-8")
        self.topic = tmp / "certs" / "demo" / "1.1"
        for lang in ("en", "es"):
            (self.topic / lang).mkdir(parents=True)
            (self.topic / lang / "content.md").write_text(CONTENT, encoding="utf-8")
            (self.topic / lang / "exercises.md").write_text("ex\n", encoding="utf-8")
        self.meta("en", {"backend": "claude", "model": "m", "sources": ["https://example.org/demo-objectives.pdf"]})
        self.meta("es", {"backend": "claude", "model": "m", "sources": ["https://example.org/demo-objectives.pdf"],
                         "translated_from": "en",
                         "source_sha256": certs.translation_source_sha256(self.topic, "en")})
        (self.topic / "lab").mkdir()
        lab = {"schema_version": 2, "cert": "demo", "topic": "1.1",
               "derived_from": {"syllabus": "certs/demo.md#1.1", "content": "certs/demo/1.1/en/content.md",
                                "content_sha256": certs.chain_sha256(self.topic / "en" / "content.md")}}
        (self.topic / "lab" / "lab.yaml").write_text(yaml.safe_dump(lab), encoding="utf-8")
        video = tmp / "media" / "certs" / "demo" / "en"
        video.mkdir(parents=True)
        (video / "script.yaml").write_text(yaml.safe_dump({
            "cert": "demo", "lang": "en",
            "derived_from": {"syllabus": "certs/demo.md",
                             "syllabus_sha256": certs.chain_sha256(tmp / "certs" / "demo.md")}}), encoding="utf-8")

    def meta(self, lang, data):
        (self.topic / lang / "meta.yaml").write_text(yaml.safe_dump(data), encoding="utf-8")


class SourceChainTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tree = Tree(Path(tmp.name))
        for name, value in (("REPO", self.tree.root),
                            ("BASELINE", self.tree.root / "baseline.txt")):
            patcher = mock.patch.object(check_source_chain, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_check(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = check_source_chain.main([])
        return code, out.getvalue()

    def test_a_fully_declared_chain_passes(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("0 stale", out)

    def test_a_translation_without_its_source_hash_fails_unless_in_the_baseline(self):
        self.tree.meta("es", {"backend": "claude", "model": "m", "sources": ["x"], "translated_from": "en"})
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("certs/demo/1.1/es/meta.yaml does not declare its origin: source_sha256", out)
        (self.tree.root / "baseline.txt").write_text("certs/demo/1.1/es/meta.yaml\n", encoding="utf-8")
        self.assertEqual(self.run_check()[0], 0)

    def test_a_changed_source_marks_translation_lab_and_video_stale(self):
        (self.tree.topic / "en" / "content.md").write_text(CONTENT + "More.\n", encoding="utf-8")
        with open(self.tree.root / "certs" / "demo.md", "a", encoding="utf-8") as handle:
            handle.write("edited\n")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)   # stale is a warning: a person decides
        self.assertIn("STALE certs/demo/1.1/es", out)
        self.assertIn("STALE certs/demo/1.1/lab/lab.yaml", out)
        self.assertIn("STALE media/certs/demo/en/script.yaml", out)

    def test_a_v2_lab_must_say_what_it_derives_from(self):
        lab = self.tree.topic / "lab" / "lab.yaml"
        data = yaml.safe_load(lab.read_text(encoding="utf-8"))
        del data["derived_from"]
        lab.write_text(yaml.safe_dump(data), encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("derived_from", out)

    def test_a_lab_must_belong_to_a_syllabus_topic(self):
        lab = self.tree.topic / "lab" / "lab.yaml"
        data = yaml.safe_load(lab.read_text(encoding="utf-8"))
        data["topic"] = "9.9"
        lab.write_text(yaml.safe_dump(data), encoding="utf-8")
        self.assertIn("!= its directory", self.run_check()[1])

    def test_a_stale_baseline_line_must_be_deleted(self):
        (self.tree.root / "baseline.txt").write_text("certs/demo/1.1/es/meta.yaml\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("no longer needs an exception", out)

    def test_the_real_repository_passes(self):
        mock.patch.stopall()
        self.assertEqual(check_source_chain.main([]), 0)


class ChainHashTests(unittest.TestCase):
    def test_the_hash_is_deterministic_and_order_aware(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "content.md", Path(tmp) / "exercises.md"
            a.write_text("x", encoding="utf-8")
            b.write_text("y", encoding="utf-8")
            self.assertEqual(certs.chain_sha256(a, b), certs.chain_sha256(a, b))
            self.assertNotEqual(certs.chain_sha256(a, b), certs.chain_sha256(b, a))
            self.assertRegex(certs.chain_sha256(a), r"^[0-9a-f]{64}$")

    def test_migrating_a_curated_lab_records_its_origin(self):
        derived = spec.derived_from(REPO / "certs" / "cka" / "3.3" / "lab")
        self.assertEqual(derived["syllabus"], "certs/cka.md#3.3")
        self.assertEqual(derived["content"], "certs/cka/3.3/en/content.md")
        self.assertEqual(derived["content_sha256"], certs.chain_sha256(REPO / derived["content"]))
        self.assertIsNone(spec.derived_from(REPO / "teach" / "lab" / "template" / "kind"))


class CitationsHeadingTests(unittest.TestCase):
    """check_citations.py read only unnumbered headings: ~630 topics were skipped (bug from #6)."""

    def test_numbered_suffixed_and_cjk_headings(self):
        for heading in ("## References", "## 14. References", "### 10) Referencias",
                        "## 10. References (official sources)", "## Références", "## 参考文献",
                        "## 参考資料", "## 参考资料 / References"):
            with self.subTest(heading=heading), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "content.md"
                path.write_text(f"# T\n\n{heading}\n\n- https://example.org/a\n", encoding="utf-8")
                self.assertEqual(check_citations.citations(path), {"https://example.org/a"})

    def test_a_heading_that_merely_starts_with_the_word_is_not_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "content.md"
            path.write_text("# T\n\n## Referenceshelf\n\n- https://example.org/a\n", encoding="utf-8")
            self.assertEqual(check_citations.citations(path), set())


if __name__ == "__main__":
    unittest.main()
