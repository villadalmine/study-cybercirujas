"""LPIC-1 is two exams and the official page (.../exam-101-102-objectives/) splits the topics between them: 101-104 are Exam 101,
105-110 are Exam 102 (checked live 2026-10-27). A line of a topic that names exactly one exam must name its own exam
(101 for 101-104; 102 for 105-110, except the 6 explicit "companion exam" references in 105.1, 107.2 and 109.4).
Lines that name both ("Exams 101-500 / 102-500", "LPI Exam 101/102 objectives") say nothing wrong and are left alone."""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CERT = REPO / "certs" / "lpic-1"
EXAM_OF_TOPIC_GROUP = {"101": "101", "102": "101", "103": "101", "104": "101",
                       "105": "102", "106": "102", "107": "102", "108": "102", "109": "102", "110": "102"}
LABEL = re.compile(r"\b(10[12])-500\b|(?:\bexam(?:en|s)?|\bex[aá]menes)\s+(?:lpic-1\s+)?(10[12])(?:/(10[12]))?\b(?![.\d])"
                   r"|\blpic-1\s+(10[12])\b(?![.\d])|\bexam-(10[12])\b|\b(10[12])/(10[12])\b", re.I)
COMPANION = re.compile(r"\b(?:companion|complementario)\b", re.I)


def material() -> list[Path]:
    """Every file of a topic that holds text a learner reads or runs (content, exercises, lab script, lab.yaml); meta.yaml is
    bookkeeping (sources, provenance) and is checked by its own gates."""
    return sorted(p for p in CERT.rglob("*") if p.is_file() and p.name != "meta.yaml" and len(p.relative_to(CERT).parts) > 1)


def exams_named(line: str) -> set[str]:
    line = re.sub(r"https?://\S+", " ", line)       # the URL is the catalog's pin, not a label: it is checked by the consistency gate
    return {g for m in LABEL.finditer(line) for g in m.groups() if g}


class ExamLabel(unittest.TestCase):
    def test_the_label_finder(self):
        self.assertEqual(exams_named("- LPI - Exam 102-500 objectives (topic 102.1 lives here): https://x"), {"102"})
        self.assertEqual(exams_named("**LPIC-1 / 102-500 - Objective 102.3**"), {"102"})
        self.assertEqual(exams_named("Certificacion: LPIC-1 (Examenes 101-500 / 102-500)"), {"101", "102"})
        self.assertEqual(exams_named("# Reference: LPI Exam 101/102 objectives"), {"101", "102"})
        self.assertEqual(exams_named("Objetivos del examen LPIC-1 101 (version 5.0)"), {"101"})
        self.assertEqual(exams_named("see <https://www.lpi.org/our-certifications/exam-101-objectives/>"), set())
        self.assertEqual(exams_named("topic 102.1 and LPIC-1 102.3 and exam 104.5"), set())

    def test_the_scan_covers_the_lab_scripts_and_not_the_bookkeeping(self):
        names = {p.name for p in material()}
        self.assertTrue({"content.md", "exercises.md", "break_fix.sh"} <= names)
        self.assertNotIn("meta.yaml", names)

    def test_every_topic_line_that_names_one_exam_names_its_own(self):
        bad, companion = [], 0
        for md in material():
            want = EXAM_OF_TOPIC_GROUP.get(md.relative_to(CERT).parts[0].split(".")[0])
            self.assertIsNotNone(want, f"{md}: a topic outside 101-110 has no exam; extend the table from the official page")
            for n, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
                named = exams_named(line)
                if len(named) == 1 and named != {want}:
                    if want == "102" and COMPANION.search(line):
                        companion += 1
                    else:
                        bad.append(f"{md.relative_to(REPO).as_posix()}:{n}: names exam {next(iter(named))}, topic is in exam {want}")
        self.assertEqual(companion, 6)
        self.assertEqual(bad, [], "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
