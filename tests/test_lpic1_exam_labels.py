"""LPIC-1 is two exams and the official page (.../exam-101-102-objectives/) splits the topics between them: 101-104 are Exam 101,
105-110 are Exam 102 (checked live 2026-10-27). A line of a topic of Exam 101 that names exactly one exam must not name Exam 102.
Lines that name both ("Exams 101-500 / 102-500") say nothing wrong and are left alone. Found in #257's review: 16 citation lines
and 10 header lines of topics 102.x, 103.1 and 104.5 called the page "Exam 102".

Only that direction is checked. The reverse (topics 105-110 whose reference says "Exam 101 objectives", 79 lines, all labels of the
catalog's pin `exam-101-objectives`, which is an alias of the page of both exams) is left for the catalog re-pin to the canonical
page, tracked in #235; checking it now would need either a baseline or a rewrite of the labels, which is not this PR's change."""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CERT = REPO / "certs" / "lpic-1"
EXAM_OF_TOPIC_GROUP = {"101": "101", "102": "101", "103": "101", "104": "101",
                       "105": "102", "106": "102", "107": "102", "108": "102", "109": "102", "110": "102"}
LABEL = re.compile(r"\b(10[12])-500\b|(?:\bexam(?:en|s)?|\bex[aá]menes)\s+(?:lpic-1\s+)?(10[12])\b(?![.\d])"
                   r"|\blpic-1\s+(10[12])\b(?![.\d])|\bexam-(10[12])\b", re.I)



def exams_named(line: str) -> set[str]:
    line = re.sub(r"https?://\S+", " ", line)       # the URL is the catalog's pin, not a label: it is checked by the consistency gate
    return {next(g for g in m.groups() if g) for m in LABEL.finditer(line)}


class ExamLabel(unittest.TestCase):
    def test_the_label_finder(self):
        self.assertEqual(exams_named("- LPI - Exam 102-500 objectives (topic 102.1 lives here): https://x"), {"102"})
        self.assertEqual(exams_named("**LPIC-1 / 102-500 - Objective 102.3**"), {"102"})
        self.assertEqual(exams_named("Certificacion: LPIC-1 (Examenes 101-500 / 102-500)"), {"101", "102"})
        self.assertEqual(exams_named("Objetivos del examen LPIC-1 101 (version 5.0)"), {"101"})
        self.assertEqual(exams_named("see <https://www.lpi.org/our-certifications/exam-101-objectives/>"), set())
        self.assertEqual(exams_named("topic 102.1 and LPIC-1 102.3 and exam 104.5"), set())

    def test_every_topic_line_that_names_one_exam_names_its_own(self):
        bad = []
        for md in sorted(CERT.glob("*/*/content.md")) + sorted(CERT.glob("*/*/exercises.md")):
            want = EXAM_OF_TOPIC_GROUP.get(md.parts[-3].split(".")[0])
            self.assertIsNotNone(want, f"{md}: a topic outside 101-110 has no exam; extend the table from the official page")
            for n, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
                named = exams_named(line)
                if len(named) == 1 and named == {"102"} and want == "101":
                    bad.append(f"{md.relative_to(REPO).as_posix()}:{n}: names exam {next(iter(named))}, topic is in exam {want}")
        self.assertEqual(bad, [], "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
