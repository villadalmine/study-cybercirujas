"""The legal & trademark disclaimer names every vendor whose exams the repo covers.

README.md (end) carries the full text in Spanish and English; the site's
footer carries a short summary in every UI language and links to it. A new
certification from a vendor the disclaimer does not name fails here.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Certification id -> who owns the exam and its trademarks (checked 2026-10-15:
# each cert's syllabus source in certs/<cert>.md; MCPA is The Linux Foundation's,
# MCP itself is hosted by its Agentic AI Foundation).
LINUX_FOUNDATION = {"cka", "ckad", "cks", "kcna", "kcsa", "ica", "cgoa", "otca", "pca", "cba", "cca",
                    "capa", "cnpa", "cnpe", "lfca", "lfcs", "kca", "ckne", "mcpa"}
PREFIXES = {"lpi-": "Linux Professional Institute", "lpic-": "Linux Professional Institute",
            "aws-": "Amazon Web Services", "az-": "Microsoft", "ai-9": "Microsoft", "gcp-": "Google",
            "terraform-": "HashiCorp", "nca-": "NVIDIA", "ncp-": "NVIDIA"}


def owner(cert: str) -> str | None:
    if cert in LINUX_FOUNDATION:
        return "The Linux Foundation"
    return next((who for prefix, who in PREFIXES.items() if cert.startswith(prefix)), None)


def legal_section() -> str:
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    assert '<a id="legal"></a>' in readme, "README.md: the #legal anchor the site links to is missing"
    return readme.split('<a id="legal"></a>', 1)[1]


class LegalNoticeTests(unittest.TestCase):
    def test_every_certification_has_a_known_owner(self):
        certs = sorted(p.stem for p in (REPO / "certs").glob("*.md"))
        self.assertTrue(certs)
        self.assertEqual([c for c in certs if owner(c) is None], [],
                         "add the new vendor to this test and to the disclaimer in README.md")

    def test_both_languages_name_every_owner(self):
        text = legal_section()
        es, en = text.split("**English.**", 1)
        owners = {owner(p.stem) for p in (REPO / "certs").glob("*.md")} | {"Cloud Native Computing Foundation"}
        for lang, para in (("es", es), ("en", en)):
            flat = re.sub(r"\s+", " ", para)
            for who in sorted(owners):
                with self.subTest(lang=lang, owner=who):
                    self.assertIn(who, flat)
            for must in ("nominative fair use", "content.md", "exercises.md", "break_fix.sh", "NDA", "braindumps"):
                with self.subTest(lang=lang, must=must):
                    self.assertIn(must, flat)

    def test_the_site_footer_summarises_and_links_it_in_every_language(self):
        html = (REPO / "teach" / "web" / "index.html").read_text(encoding="utf-8")
        self.assertEqual(html.count("    foot: '"), html.count("    legal: '"))
        self.assertEqual(html.count("    legal: '"), html.count("legalLink: '"))
        self.assertIn("study-cybercirujas#legal", html)
        self.assertIn("t('legal')", html)


if __name__ == "__main__":
    unittest.main()
