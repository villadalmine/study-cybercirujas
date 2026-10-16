"""aws-clf 2.3 grader: a correct repair passes, and the cheats found in review of
PR #107 (fable) do not. Each case runs the real break_fix.sh against a scratch
sandbox, offline, in about a second."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "certs" / "aws-clf" / "2.3" / "lab" / "break_fix.sh"
ACC = "123456789012"
CI = f"arn:aws:iam::{ACC}:user/ci"


@unittest.skipUnless(shutil.which("bash") and shutil.which("python3"), "needs bash and python3")
class Aws23GraderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "aws-clf-lab-2.3"
        self.env = dict(os.environ, LAB_ROOT=str(self.root), LAB_ASSUME_YES="1")
        self.env.pop("AWS_LAB_MFA_CODE", None)
        self.run_lab("start")

    def tearDown(self):
        self.tmp.cleanup()

    def run_lab(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, text=True,
                              capture_output=True, timeout=120)

    def verify(self):
        proc = self.run_lab("verify")
        return proc.returncode, proc.stdout

    def edit(self, rel, fn):
        path = self.root / rel
        path.write_text(fn(path.read_text()))

    def trust(self, fn):
        path = self.root / "iam/trust/LabDeployRole.json"
        doc = json.loads(path.read_text())
        fn(doc)
        path.write_text(json.dumps(doc, indent=2))

    def reference_fix(self, source_line="source_profile = ci"):
        self.edit("aws/config", lambda t: t.replace(
            "source_profile = ci-runner",
            f"{source_line}\nmfa_serial = arn:aws:iam::{ACC}:mfa/ci"))
        self.edit("iam/trust/LabDeployRole.json",
                  lambda t: t.replace("user/ci-runner-legacy", "user/ci"))
        path = self.root / "iam/boundaries/DeployBoundary.json"
        doc = json.loads(path.read_text())
        doc["Statement"][1]["Resource"] = doc["Statement"][1]["Resource"].replace("/*", "/releases/*")
        path.write_text(json.dumps(doc, indent=2))
        self.edit("aws/credentials", lambda t: re.sub(r"\[root\][^\[]*", "", t))

    def assert_passes(self):
        rc, out = self.verify()
        self.assertEqual(rc, 0, out)
        self.assertIn("ALL 11 CHECKS PASSED", out)

    def assert_fails(self):
        rc, out = self.verify()
        self.assertNotEqual(rc, 0, out)
        self.assertNotIn("CHECKS PASSED", out)

    def test_broken_lab_fails(self):
        self.assert_fails()

    def test_reference_fix_passes(self):
        self.reference_fix()
        self.assert_passes()

    def test_source_profile_without_spaces(self):
        """PR #107 finding 1: `source_profile=ci` is valid INI for the CLI and the shim."""
        self.reference_fix(source_line="source_profile=ci")
        self.assert_passes()

    def test_wildcard_next_to_ci_in_principal_list(self):
        """PR #107 finding 2: {"AWS": [ci, "*"]} makes the role assumable by anyone."""
        self.reference_fix()
        self.trust(lambda d: d["Statement"][0].update(Principal={"AWS": [CI, "*"]}))
        self.assert_fails()

    def test_wildcard_variants_in_principal(self):
        for principal in ("*", {"AWS": "*"}, {"AWS": [CI, "arn:aws:iam::*:root"]},
                          {"AWS": CI, "Service": "*"}, {"AWS": CI, "Federated": ["*"]}):
            with self.subTest(principal=principal):
                self.reference_fix() if not hasattr(self, "_fixed") else None
                self._fixed = True
                self.trust(lambda d: d["Statement"][0].update(Principal=principal))
                self.assert_fails()
        self.trust(lambda d: d["Statement"][0].update(Principal={"AWS": CI}))
        self.assert_passes()
