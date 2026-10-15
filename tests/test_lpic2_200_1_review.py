"""lpic-2/200.1: what the review of PR #6 found, kept from coming back.

The topic was authored by a model; an independent review (fable, revisor-pr)
found claims that no source backed. Each test pins one fix against the
official source it was checked with, in both languages.
"""
import re
import unittest
from pathlib import Path

TOPIC = Path(__file__).resolve().parent.parent / "certs" / "lpic-2" / "200.1"
LANGS = ("en", "es")

# LPI, Exam Objectives version 4.5.0, 200.1 (weight: 6), "partial list of the
# used files, terms and utilities", verbatim:
# https://www.lpi.org/our-certifications/exam-201-202-objectives/
LPI_LIST = ("`iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, "
            "`ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, "
            "processes blocked on I/O, blocks in, blocks out")


def read(lang: str, name: str) -> str:
    return (TOPIC / lang / name).read_text(encoding="utf-8")


class ObjectiveTest(unittest.TestCase):
    def test_weight_is_lpis(self):
        for lang in LANGS:
            for name in ("content.md", "exercises.md"):
                head = "\n".join(read(lang, name).splitlines()[:8])
                self.assertRegex(head, r"(LPI weight|[Pp]eso LPI):?\*?\*? 6", f"{lang}/{name}")
                self.assertNotRegex(head, r"[Ww]eight:?\*?\*? 5|[Pp]eso:?\*?\*? 5", f"{lang}/{name}")

    def test_utility_list_is_lpis_verbatim(self):
        for lang in LANGS:
            for name in ("content.md", "exercises.md"):
                self.assertIn(LPI_LIST, read(lang, name), f"{lang}/{name}")


class SampleOutputTest(unittest.TestCase):
    def test_no_claim_of_a_capture_that_never_happened(self):
        # The material is model-written; nothing was run on a host. Saying
        # otherwise is the kind of invented provenance the review caught.
        for lang in LANGS:
            text = read(lang, "content.md")
            self.assertNotRegex(text, r"captured on a reference|se captur[óo] en un host")
            self.assertRegex(text, r"\*\*(illustrative|ilustrativa)\*\*")


if __name__ == "__main__":
    unittest.main()
