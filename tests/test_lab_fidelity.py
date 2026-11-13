"""scripts/lab_fidelity.py (#303): the verdict rules and the attribution of calls to services.

The data here is synthetic, in the shape of AWS Emulator's `scores.json` (schemaVersion 1) and of its
`issues/things-that-do-not-work/*.md` headers, so the rules are tested without the network.
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import lab_fidelity as lf  # noqa: E402

S3 = "com.amazonaws.s3#AmazonS3"
IAM = "com.amazonaws.iam#AWSIdentityManagementV20100508"
BUDGETS = "com.amazonaws.budgets#AWSBudgetServiceGateway"
PIN = {"repo": "aws/aws-emulator", "release": "v9.9.9", "commit": "a" * 40,
       "scores_url": "https://example.invalid/scores.json.gz", "scores_sha256": "b" * 64, "scored_at": "x"}


def unit(outcome, services, *steps):
    """steps: (operation, step outcome)."""
    return {"kind": "wire", "outcome": outcome, "services": services, "unitId": "u",
            "detail": {"steps": [{"key": f"task#{i}", "operation": op, "outcome": o} for i, (op, o) in enumerate(steps)]}}


def issue(severity, shape, *keys):
    return {"severity": severity, "shape": shape, "keys": list(keys)}


SCORES = {"units": [
    unit("pass", [S3], ("CreateBucket", "pass"), ("PutBucketVersioning", "pass")),
    unit("pass", [S3], ("CreateBucket", "pass")),
    unit("fail", [S3], ("CreateBucket", "pass"), ("PutBucketVersioning", "mismatch")),
    unit("pass", [IAM], ("CreateRole", "pass"), ("GetRole", "pass")),
    unit("pass", [BUDGETS, IAM], ("CreateBudget", "pass"), ("CreateRole", "pass")),
    unit("pass", [BUDGETS], ("CreateBudget", "pass")),
    {"kind": "behavioral", "outcome": "pass", "services": [S3], "unitId": "b", "detail": {"checkId": "b"}},
]}
ISSUES = [
    issue("HIGH", IAM, "iam|GetRole|2xx->2xx|$.Role"),
    issue("CRITICAL", "", "codebuild|StartBuild|Timeout", "iam|GetRole|2xx->4xx|status"),   # a chain, not iam's
    issue("CRITICAL", S3, "s3|PutBucketReplication|2xx->2xx|$"),
    issue("HIGH", IAM, "iam|CreateServiceLinkedRole|NotImplemented"),
]


class Index(unittest.TestCase):
    def setUp(self):
        self.idx = lf.build_index(SCORES, ISSUES)

    def test_passing_and_failing_units_per_operation(self):
        self.assertEqual(self.idx[("s3", "CreateBucket")]["passing_units"], 2)
        self.assertEqual(self.idx[("s3", "PutBucketVersioning")]["passing_units"], 1)
        self.assertEqual(self.idx[("s3", "PutBucketVersioning")]["failing_units"], 1)
        self.assertEqual(self.idx[("s3", "CreateBucket")]["failing_units"], 0, "a passing step in a failing unit")

    def test_a_multi_service_unit_does_not_invent_operations(self):
        self.assertNotIn(("budgets", "CreateRole"), self.idx)
        self.assertNotIn(("iam", "CreateBudget"), self.idx)
        self.assertEqual(self.idx[("iam", "CreateRole")]["passing_units"], 2)
        self.assertEqual(self.idx[("budgets", "CreateBudget")]["passing_units"], 2)

    def test_known_issues_count_files_once(self):
        self.assertEqual(self.idx[("iam", "GetRole")]["known_issues"], 2)

    def test_verdicts(self):
        self.assertEqual(lf.verdict(self.idx.get(("s3", "CreateBucket"))), "ok")
        self.assertEqual(lf.verdict(None), "reject: no-evidence")
        self.assertEqual(lf.verdict(self.idx[("iam", "CreateServiceLinkedRole")]), "reject: no-evidence")
        self.idx[("iam", "CreateServiceLinkedRole")]["passing_units"] = 1
        self.assertEqual(lf.verdict(self.idx[("iam", "CreateServiceLinkedRole")]), "reject: not-implemented")
        self.idx[("s3", "PutBucketReplication")]["passing_units"] = 1
        self.assertEqual(lf.verdict(self.idx[("s3", "PutBucketReplication")]), "reject: critical-issue")

    def test_a_critical_chain_issue_does_not_reject_one_of_its_calls(self):
        self.assertEqual(lf.verdict(self.idx[("iam", "GetRole")]), "ok")

    def test_issue_headers_are_parsed_until_the_first_blank_line(self):
        text = (f"Issue-Severity: HIGH\nIssue-Shape-Id: {S3}\nIssue-Key: s3|GetObject|2xx->2xx|$.x\n"
                "Issue-Key: s3|GetObject|status\n\n# Title\nIssue-Key: s3|Fake|x\n")
        self.assertEqual(lf.parse_issue(text), issue("HIGH", S3, "s3|GetObject|2xx->2xx|$.x", "s3|GetObject|status"))


class Tree(unittest.TestCase):
    def test_the_pin_file_is_well_formed(self):
        pin = lf.load_pins()
        self.assertEqual(set(pin), {"repo", "release", "commit", "scores_url", "scores_sha256", "scored_at"})
        self.assertRegex(pin["commit"], r"^[0-9a-f]{40}$")
        self.assertRegex(pin["scores_sha256"], r"^[0-9a-f]{64}$")
        self.assertIn(pin["release"], pin["scores_url"])

    def test_deterministic_across_hash_seeds(self):
        idx = [subprocess.run([sys.executable, "-c",
                               "import sys,json; sys.path.insert(0,'scripts'); import lab_fidelity as lf;"
                               "from tests.test_lab_fidelity import SCORES, ISSUES;"
                               "i=lf.build_index(SCORES, ISSUES);"
                               "print(json.dumps(sorted((k,[v['passing_units'],v['failing_units'],v['known_issues'],"
                               "lf.verdict(v)]) for k,v in i.items())))"],
                              cwd=REPO, check=True, capture_output=True, text=True,
                              env=dict(os.environ, PYTHONHASHSEED=seed)).stdout for seed in ("1", "2")]
        self.assertEqual(idx[0], idx[1])


if __name__ == "__main__":
    unittest.main()
