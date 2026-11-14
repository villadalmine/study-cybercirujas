"""scripts/lab_fidelity.py (#325): ownership of operations, the verdict rules, the pin, the cache and the `fidelity:` block.

The data is synthetic but has the shape of AWS Emulator v1.0.345 (measured 2026-11-13): every wire unit names ONE
service (the scenario's) while its steps may call others; an Issue-Key's first segment is the CALLED service's SDK
id while Issue-Shape-Id is the scenario's; some keys are `<check-id>|run#N|<Exception>|<assert>`; and the emulator
has one handler file per operation under services/<crate>/src/ops/.
"""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))
import lab_fidelity as lf  # noqa: E402

S3 = "com.amazonaws.s3#AmazonS3"
IAM = "com.amazonaws.iam#AWSIdentityManagementV20100508"
BUDGETS = "com.amazonaws.budgets#AWSBudgetServiceGateway"
APPFLOW = "com.amazonaws.appflow#SandstoneConfigurationServiceLambda"
LOGS = "com.amazonaws.cloudwatchlogs#Logs_20140328"
XRAY = "com.amazonaws.xray#AWSXRay"
CODEBUILD = "com.amazonaws.codebuild#CodeBuild_20161006"
PIN = {"repo": "aws/aws-emulator", "release": "v9.9.9", "commit": "a" * 40,
       "scores_url": "https://example.invalid/scores.json.gz", "scores_sha256": "b" * 64, "scored_at": "x"}

HANDLERS = [f"services/{lf.service_dir(shape)}/src/ops/{op}.rs" for shape, op in [
    (S3, "create_bucket"), (S3, "put_bucket_versioning"), (S3, "get_object"), (S3, "mod"),
    (IAM, "create_role"), (IAM, "get_role"), (IAM, "create_service_linked_role"),
    (BUDGETS, "create_budget"), (CODEBUILD, "start_build"),
    (LOGS, "put_resource_policy"), (XRAY, "put_resource_policy"), (LOGS, "create_log_group"),
]] + ["services/vendor-crate/src/ops/create_role.rs", "issues/things-that-do-not-work/x.md",
      f"services/{lf.service_dir(S3)}/src/ops/types/shared_types.rs"]
OWNERS = lf.ownership(HANDLERS, {S3, IAM, BUDGETS, APPFLOW, LOGS, XRAY, CODEBUILD})


def unit(outcome, service, *steps):
    """steps: (operation, step outcome)."""
    return {"kind": "wire", "outcome": outcome, "services": [service], "unitId": "u",
            "detail": {"steps": [{"key": f"task#{i}", "operation": op, "outcome": o} for i, (op, o) in enumerate(steps)]}}


def issue(severity, shape, *keys):
    return {"severity": severity, "shape": shape, "keys": list(keys)}


SCORES = {"units": [
    unit("pass", S3, ("CreateBucket", "pass"), ("PutBucketVersioning", "pass")),
    unit("pass", S3, ("CreateBucket", "pass")),
    unit("fail", S3, ("CreateBucket", "pass"), ("PutBucketVersioning", "mismatch")),
    unit("pass", IAM, ("CreateRole", "pass"), ("GetRole", "pass")),
    unit("pass", BUDGETS, ("CreateRole", "pass"), ("CreateBudget", "pass")),      # a budgets scenario calls iam
    unit("pass", APPFLOW, ("PutResourcePolicy", "pass")),                          # owned by two others: skipped
    unit("pass", S3, ("GetObject", "pass")),
    {"kind": "behavioral", "outcome": "pass", "services": [S3], "unitId": "b", "detail": {"checkId": "b"}},
]}
ISSUES = [
    issue("HIGH", IAM, "iam|GetRole|2xx->2xx|$.Role"),
    issue("CRITICAL", "", "codebuild|StartBuild|Timeout", "iam|GetRole|2xx->4xx|status"),   # a chain: two services
    issue("HIGH", APPFLOW, "s3|GetObject|2xx->2xx|$.Body"),                                 # filed under appflow
    dict(issue("CRITICAL", S3, "s3|GetObject|NotImplemented", "s3.cond-get|run#9|AssertionError|assert code == 304"),
         file="issues/things-that-do-not-work/s3-getobject-if-match.md"),
    dict(issue("HIGH", IAM, "iam|CreateServiceLinkedRole|NotImplemented"),
         file="issues/things-that-do-not-work/iam-slr-stub.md"),
    issue("HIGH", XRAY, "cloudwatch-logs|PutResourcePolicy|4xx->2xx|$"),
    issue("HIGH", XRAY, "logs|CreateLogGroup|2xx->2xx|$", "logs|PutResourcePolicy|2xx->4xx|status"),
]


class Ownership(unittest.TestCase):
    def test_handler_files_name_the_owner(self):
        self.assertEqual(OWNERS["createrole"], {"iam"}, "a crate no shape names is left out")
        self.assertEqual(OWNERS["putresourcepolicy"], {"cloudwatchlogs", "xray"})
        self.assertNotIn("mod", OWNERS)
        self.assertNotIn("sharedtypes", OWNERS, "src/ops/types/*.rs are not operations")

    def test_service_dir_matches_the_emulator_layout(self):
        self.assertEqual(lf.service_dir(S3), "service-com-amazonaws-s3-amazons3")
        self.assertEqual(lf.service_dir("com.amazonaws.applicationdiscoveryservice#AWSPoseidonService_V2015_11_01"),
                         "service-com-amazonaws-applicationdiscoveryservice-awsposeidonservice-v2015-11-01")

    def test_issue_keys_go_to_the_called_service(self):
        ids = {"logs": "cloudwatchlogs"}
        self.assertEqual(lf.key_services("s3|GetObject|2xx->2xx|$.Body", OWNERS, ids), ("GetObject", {"s3"}))
        self.assertEqual(lf.key_services("cloudwatch-logs|PutResourcePolicy|x", OWNERS, {}),
                         ("PutResourcePolicy", {"cloudwatchlogs"}), "two owners: the one the id names")
        self.assertEqual(lf.key_services("logs|PutResourcePolicy|x", OWNERS, ids)[1], {"cloudwatchlogs"},
                         "two owners: the one the learned SDK id names")
        self.assertEqual(lf.key_services("logs|PutResourcePolicy|x", OWNERS, {})[1], set(),
                         "two owners, none named: skipped, never spread over both")
        self.assertEqual(lf.key_services("s3.cond-get|run#9|AssertionError|assert", OWNERS, ids), ("run#9", set()))

    def test_unattributed_keys_are_counted_per_id(self):
        issues = [issue("HIGH", XRAY, "events|PutResourcePolicy|x", "s3|GetObject|y", "s3.check|run#1|E|a")]
        self.assertEqual(lf.unattributed(issues, OWNERS), {"events": 1})

    def test_sdk_ids_are_learned_from_keys_with_one_owner(self):
        ids = lf.sdk_ids([issue("HIGH", XRAY, "logs|CreateLogGroup|x", "logs|PutResourcePolicy|y"),
                          issue("HIGH", S3, "s3|GetObject|z")], OWNERS)
        self.assertEqual(ids, {"logs": "cloudwatchlogs", "s3": "s3"})


class Index(unittest.TestCase):
    def setUp(self):
        self.idx = lf.build_index(SCORES, ISSUES, OWNERS)

    def test_passing_and_failing_units_per_operation(self):
        self.assertEqual(self.idx[("s3", "CreateBucket")]["passing_units"], 2)
        self.assertEqual(self.idx[("s3", "PutBucketVersioning")]["failing_units"], 1)
        self.assertEqual(self.idx[("s3", "CreateBucket")]["failing_units"], 0, "a passing step in a failing unit")

    def test_a_call_is_credited_to_the_service_that_owns_it(self):
        self.assertNotIn(("budgets", "CreateRole"), self.idx)
        self.assertEqual(self.idx[("iam", "CreateRole")]["passing_units"], 2)
        self.assertNotIn(("appflow", "PutResourcePolicy"), self.idx)
        self.assertEqual(self.idx.get(("xray", "PutResourcePolicy"), {}).get("passing_units", 0), 0)

    def test_an_issue_counts_for_the_called_service_not_the_scenario(self):
        self.assertEqual(self.idx[("s3", "GetObject")]["known_issues"], 2)
        self.assertNotIn(("appflow", "GetObject"), self.idx)
        self.assertNotIn(("xray", "PutResourcePolicy"), {k for k, v in self.idx.items() if v["known_issues"]})
        self.assertEqual(self.idx[("cloudwatchlogs", "PutResourcePolicy")]["known_issues"], 2,
                         "`cloudwatch-logs` by name, `logs` through the learned SDK id")
        self.assertEqual(self.idx[("cloudwatchlogs", "PutResourcePolicy")]["severities"], {"HIGH"},
                         "an issue whose keys all resolve to one service keeps its severity")

    def test_check_id_keys_name_no_operation(self):
        self.assertFalse([k for k in self.idx if k[1].startswith("run#") or "." in k[0]])

    def test_severity_only_from_issues_about_one_service(self):
        self.assertEqual(self.idx[("iam", "GetRole")]["severities"], {"HIGH"}, "the chain's CRITICAL is not iam's")
        self.assertIn("CRITICAL", self.idx[("s3", "GetObject")]["severities"],
                      "a check-id key next to it does not make it a second service")

    def test_verdicts(self):
        self.assertEqual(lf.verdict(self.idx[("s3", "CreateBucket")]), "ok")
        self.assertEqual(lf.verdict(self.idx[("iam", "GetRole")]), "ok")
        self.assertEqual(lf.verdict(None), "reject: no-evidence")
        self.assertEqual(lf.verdict(self.idx[("iam", "CreateServiceLinkedRole")]), "reject: not-implemented")
        self.assertEqual(lf.verdict(self.idx[("s3", "GetObject")]), "warn: critical-issue",
                         "NotImplemented on one path of an operation that passes elsewhere does not reject it")

    def test_issue_headers_are_parsed_until_the_first_blank_line(self):
        text = (f"Issue-Severity: HIGH\nIssue-Shape-Id: {S3}\nIssue-Key: s3|GetObject|2xx->2xx|$.x\n"
                "Issue-Key: s3|GetObject|status\n\n# Title\nIssue-Key: s3|Fake|x\n")
        self.assertEqual(lf.parse_issue(text), issue("HIGH", S3, "s3|GetObject|2xx->2xx|$.x", "s3|GetObject|status"))


class Data(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        p = mock.patch.object(lf, "CACHE", Path(tmp.name))
        p.start()
        self.addCleanup(p.stop)
        self.root = Path(tmp.name) / lf.EMULATOR / PIN["release"]

    def test_a_bad_download_never_replaces_the_cache(self):
        self.root.mkdir(parents=True)
        (self.root / "scores.json.gz").write_bytes(b"truncated")
        with mock.patch.object(lf, "fetch", return_value=b"tampered"):
            with self.assertRaisesRegex(SystemExit, "sha256 differs"):
                lf.ensure_data(PIN)
        self.assertEqual((self.root / "scores.json.gz").read_bytes(), b"truncated")

    def test_an_interrupted_clone_is_cleared_not_trusted(self):
        good = b"scores"
        pin = dict(PIN, scores_sha256=lf.sha256(good))
        (self.root / "repo").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.root / "repo")], check=True)        # wedged: no HEAD
        calls = []

        def fake_git(repo, *args, check=True):
            calls.append(args[0])
            if args[0] == "fetch":
                raise SystemExit("offline")
            return ""
        with mock.patch.object(lf, "fetch", return_value=good), mock.patch.object(lf, "git", fake_git):
            with self.assertRaisesRegex(SystemExit, "offline"):
                lf.ensure_data(pin)
        self.assertFalse((self.root / "repo").exists(), "the wedged clone was removed")
        self.assertIn("fetch", calls)
        self.assertEqual((self.root / "scores.json.gz").read_bytes(), good, "a verified download is kept")

    def test_only_https_is_fetched(self):
        with self.assertRaisesRegex(SystemExit, "only https"):
            lf.fetch("file:///etc/passwd")


class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lab = Path(self.tmp.name) / "lab.yaml"
        self.idx = lf.build_index(SCORES, ISSUES, OWNERS)
        patches = [mock.patch.object(lf, "load_pins", return_value=PIN),
                   mock.patch.object(lf, "load_index", return_value=self.idx)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def write(self, uses, extra=""):
        self.lab.write_text("cert: aws-clf\ntopic: '1.1'\ntitle: t\n" + extra
                            + "uses:\n" + "".join(f"- {u}\n" for u in uses), encoding="utf-8")

    def run_check(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = lf.main(["check", *args, str(self.lab)])
        return code, out.getvalue()

    def test_missing_block_fails_then_write_then_passes(self):
        self.write(["s3:CreateBucket", "iam:CreateRole"])
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("`fidelity:` is missing", out)
        self.assertEqual(self.run_check("--write", "--date", "2026-11-13")[0], 0)
        self.assertEqual(self.run_check()[0], 0, "date is not compared")
        data = yaml.safe_load(self.lab.read_text())
        block = data["fidelity"]
        self.assertEqual((block["release"], block["commit"], block["uses_from"]), ("v9.9.9", "a" * 40, "declared"))
        self.assertEqual(block["tool_sha256"], lf.sha256((REPO / lf.TOOL).read_bytes()))
        self.assertEqual(block["operations"]["s3:CreateBucket"],
                         {"verdict": "ok", "passing_units": 2, "failing_units": 0, "known_issues": 0})
        from teach.lab import spec
        self.assertEqual(spec.schema_errors(data), [])

    def test_a_hand_edit_is_stale(self):
        self.write(["s3:CreateBucket"])
        self.run_check("--write")
        self.lab.write_text(self.lab.read_text().replace("passing_units: 2", "passing_units: 9"))
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("`fidelity:` is stale", out)

    def test_a_new_pin_makes_the_block_stale(self):
        self.write(["s3:CreateBucket"])
        self.run_check("--write")
        with mock.patch.object(lf, "load_pins", return_value=dict(PIN, release="v9.9.10")):
            self.assertEqual(self.run_check()[0], 1)

    def test_a_rejected_operation_fails_even_when_recorded(self):
        self.write(["s3:CreateBucket", "iam:CreateServiceLinkedRole"])
        self.run_check("--write")
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("iam:CreateServiceLinkedRole (reject: not-implemented)", out)

    def test_a_warning_is_recorded_and_printed_but_does_not_fail(self):
        self.write(["s3:GetObject"])
        self.run_check("--write")
        code, out = self.run_check()
        self.assertEqual(code, 0)
        self.assertIn("warn: critical-issue", out)
        op = yaml.safe_load(self.lab.read_text())["fidelity"]["operations"]["s3:GetObject"]
        self.assertEqual(op["verdict"], "warn: critical-issue")
        self.assertEqual(op["issues"], ["issues/things-that-do-not-work/s3-getobject-if-match.md"],
                         "the block names the CRITICAL issue the warning comes from")
        self.assertIn("issues/things-that-do-not-work/s3-getobject-if-match.md", out)

    def test_a_stub_names_its_issue_and_ok_has_no_issue_list(self):
        self.write(["s3:CreateBucket", "iam:CreateServiceLinkedRole"])
        self.run_check("--write")
        ops = yaml.safe_load(self.lab.read_text())["fidelity"]["operations"]
        self.assertEqual(ops["iam:CreateServiceLinkedRole"]["issues"], ["issues/things-that-do-not-work/iam-slr-stub.md"])
        self.assertNotIn("issues", ops["s3:CreateBucket"])

    def test_write_replaces_the_block_and_keeps_the_rest(self):
        self.write(["s3:CreateBucket"], extra="requires: linux\n")
        self.run_check("--write")
        self.write(["s3:CreateBucket", "iam:CreateRole"], extra="requires: linux\n")
        self.lab.write_text(self.lab.read_text() + yaml.safe_dump({"fidelity": {"old": 1}}))
        self.run_check("--write")
        text = self.lab.read_text()
        self.assertEqual(text.count("fidelity:"), 1)
        self.assertIn("requires: linux", text)
        self.assertIn("iam:CreateRole:", text)

    def test_malformed_uses_fail(self):
        self.write(["s3 CreateBucket"])
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("<service>:<Operation>", out)


class Pin(unittest.TestCase):
    def test_without_cloud_labs_it_needs_no_pin_and_no_network(self):
        with mock.patch.object(lf, "load_pins", side_effect=AssertionError("read the pin")), \
                mock.patch.object(lf, "fetch", side_effect=AssertionError("network")):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = lf.main(["check"])
        if "cloud lab(s)" in out.getvalue():
            self.skipTest("the tree has cloud labs now; the CI step covers them")
        self.assertEqual(code, 0)
        self.assertIn("no lab declares `uses:`", out.getvalue())

    def test_check_compares_with_the_pinned_release_not_the_latest(self):
        have = lf.load_pins()
        with mock.patch.object(lf, "live_pin", return_value=have) as live, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lf.main(["pin", "--check"]), 0)
        live.assert_called_once_with(have["release"])

    def test_the_pin_file_is_well_formed(self):
        pin = lf.load_pins()
        self.assertEqual(set(pin), {"repo", "release", "commit", "scores_url", "scores_sha256", "scored_at"})
        self.assertRegex(pin["commit"], r"^[0-9a-f]{40}$")
        self.assertRegex(pin["scores_sha256"], r"^[0-9a-f]{64}$")
        self.assertIn(pin["release"], pin["scores_url"])

    def test_deterministic_across_hash_seeds(self):
        code = ("import sys,json; sys.path.insert(0,'scripts'); import lab_fidelity as lf;"
                "from tests.test_lab_fidelity import SCORES, ISSUES, OWNERS;"
                "i=lf.build_index(SCORES, ISSUES, OWNERS);"
                "print(json.dumps(sorted((k,[v['passing_units'],v['failing_units'],v['known_issues'],"
                "lf.verdict(v)]) for k,v in i.items())))")
        out = [subprocess.run([sys.executable, "-c", code], cwd=REPO, check=True, capture_output=True, text=True,
                              env=dict(os.environ, PYTHONHASHSEED=seed)).stdout for seed in ("1", "2")]
        self.assertEqual(out[0], out[1])


if __name__ == "__main__":
    unittest.main()
