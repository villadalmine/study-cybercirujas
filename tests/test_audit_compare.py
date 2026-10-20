"""scripts/audit_compare.py: the table, the disagreements, refusing "no proposal" and the ranking formula (fixtures in tests/fixtures/audit/)."""
import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import audit_compare  # noqa: E402

FIX = REPO / "tests" / "fixtures" / "audit"


def load(*names):
    return audit_compare.load_results([FIX / n for n in names])


def run_main(*names):
    """Run main() on a temporary results dir holding the named fixtures; return (exit code, stdout)."""
    with tempfile.TemporaryDirectory() as tmp:
        for n in names:
            shutil.copy(FIX / n, tmp)
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = audit_compare.main(["--rubric", str(FIX / "rubric.yml"), "--results", tmp])
    return code, buf.getvalue()


class AuditCompareTests(unittest.TestCase):
    def setUp(self):
        self.rubric = yaml.safe_load((FIX / "rubric.yml").read_text(encoding="utf-8"))

    def test_the_real_rubric_keeps_its_ids_and_foundations(self):
        real = yaml.safe_load((REPO / "docs/audit/rubric.yml").read_text(encoding="utf-8"))
        ids = audit_compare.criterion_ids(real)
        self.assertEqual(ids, ["P1", "D1", "D2", "D3", "C1", "C2", "C3", "L1", "L2", "L3", "L4",
                               "K1", "X1", "X2", "X3", "G1", "G2", "S1"])
        self.assertEqual(list(real["foundations"]), [f"F{n}" for n in range(1, 9)])
        self.assertEqual([f["weight"] for f in real["foundations"].values()], [5, 5, 4, 4, 3, 3, 2, 2])

    def test_table_has_one_row_per_criterion_and_one_column_per_auditor(self):
        report, _, _ = audit_compare.compare(self.rubric, load("a.yml", "b.yml"))
        lines = report.splitlines()
        self.assertEqual(lines[0], "| criterion | alice@aaaaaaa | bob@bbbbbbb | avg | disagreement |")
        self.assertIn("| D1 | 2 | 1 | 1.5 | **yes** |", lines)
        self.assertIn("| D2 | 1 | 1 | 1.0 |  |", lines)

    def test_disagreements_are_a_difference_of_at_least_one(self):
        _, dis, _ = audit_compare.compare(self.rubric, load("a.yml", "b.yml"))
        self.assertEqual(dis, ["D1"])

    def test_no_proposal_is_refused_and_its_score_does_not_count(self):
        report, dis, refused = audit_compare.compare(self.rubric, load("a.yml", "c.yml"))
        self.assertEqual(refused, ["D1@carol@ccccccc", "D2@carol@ccccccc"])
        self.assertIn("| D1 | 2 | - | 2.0 |  |", report.splitlines())
        self.assertEqual(dis, [])  # carol's 0 on D2 is ignored, so no disagreement
        self.assertIn("(no proposal: refused", report)

    def test_main_exits_2_when_a_proposal_is_missing(self):
        code, out = run_main("a.yml", "c.yml")
        self.assertEqual(code, 2)
        self.assertIn("without proposal (refused): D1@carol@ccccccc, D2@carol@ccccccc", out)

    def test_main_exits_0_when_everything_has_a_proposal(self):
        code, out = run_main("a.yml", "b.yml")
        self.assertEqual(code, 0)
        self.assertIn("## Proposal ranking", out)

    def test_main_exits_1_without_results(self):
        code, _ = run_main()
        self.assertEqual(code, 1)

    def test_ranking_formula(self):
        f = self.rubric["foundations"]  # F1 weight 5, F3 weight 4
        pr = audit_compare.priority
        self.assertEqual(pr({"foundations": ["F1", "F3"], "automatable": "yes", "effort": "S"}, f), 9.0)
        self.assertEqual(pr({"foundations": ["F1", "F3"], "automatable": "partial", "effort": "M"}, f), 2.7)
        self.assertEqual(pr({"foundations": ["F1"], "automatable": "no", "effort": "L"}, f), 0.38)
        self.assertEqual(pr({"foundations": ["F1"], "automatable": True, "effort": "S"}, f), 5.0)  # bare `yes` in YAML
        self.assertEqual(pr({"foundations": ["F1"], "automatable": False, "effort": "S"}, f), 1.5)  # bare `no` in YAML
        self.assertEqual(pr({"foundations": "F3", "automatable": "yes", "effort": "M"}, f), 2.0)
        self.assertEqual(pr({"foundations": ["F9"], "automatable": "yes", "effort": "S"}, f), 0.0)  # unknown weighs nothing

    def test_ranking_is_sorted_by_priority_then_id(self):
        report, _, _ = audit_compare.compare(self.rubric, load("a.yml", "b.yml"))
        rank = [r for r in report.split("## Proposal ranking")[1].splitlines() if r.startswith("- ")]
        self.assertTrue(rank[0].startswith("-  9.00  D1 (alice@aaaaaaa)"), rank[0])
        values = [float(r[2:8]) for r in rank]
        self.assertEqual(values, sorted(values, reverse=True))
        self.assertTrue(rank[1].startswith("-  1.20  D1 (bob@bbbbbbb)"), rank[1])  # tie: by id, then auditor

    def test_the_output_is_the_same_twice(self):
        one = audit_compare.compare(self.rubric, load("a.yml", "b.yml"))[0]
        two = audit_compare.compare(self.rubric, load("a.yml", "b.yml"))[0]
        self.assertEqual(one, two)


if __name__ == "__main__":
    unittest.main()
