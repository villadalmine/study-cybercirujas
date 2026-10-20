"""lab.yaml `safety`: risky labs say so in lab.yaml, and every place a student meets them repeats it.

az-900 2.4 edits the host (~/.azure, /etc/hosts, a route); 2.2 and 2.3 create billable Azure
resources, 2.2 with a public IP. Found by an external security review.
"""
import io
import os
import unittest
from pathlib import Path
from unittest import mock

import yaml
from typer.testing import CliRunner

from teach import cli
from teach.lab import export_killercoda, safety, spec

REPO = Path(__file__).resolve().parent.parent
RISKY = {
    "2.2": {"billable-cloud", "public-exposure"},
    "2.3": {"billable-cloud"},
    "2.4": {"modifies-host"},
}


def lab_dirs_with_safety():
    for f in sorted(REPO.glob("certs/*/*/lab/lab.yaml")):
        if "safety" in (yaml.safe_load(f.read_text(encoding="utf-8")) or {}):
            yield f.parent


class Tty(io.StringIO):
    def isatty(self):
        return True


class SchemaTests(unittest.TestCase):
    def test_the_az900_labs_declare_their_risks(self):
        for topic, risks in RISKY.items():
            lab = spec.load(REPO / f"certs/az-900/{topic}/lab")
            self.assertEqual(lab.errors, [], topic)
            self.assertEqual(set(lab.spec["safety"]["risks"]), risks, topic)

    def test_schema_rejects_unknown_risk_and_missing_warning(self):
        base = {"cert": "x", "topic": "1.1", "title": "t"}
        self.assertTrue(spec.schema_errors({**base, "safety": {"risks": ["nuke"], "warning": "w" * 50}}))
        self.assertTrue(spec.schema_errors({**base, "safety": {"risks": ["modifies-host"]}}))
        self.assertTrue(spec.schema_errors({**base, "safety": {"risks": [], "warning": "w" * 50}}))
        self.assertEqual(spec.schema_errors({**base, "safety": {"risks": ["modifies-host"], "warning": "w" * 50}}), [])


class VisibleWhereStudentsLookTests(unittest.TestCase):
    def test_readme_and_script_header_carry_the_warning(self):
        dirs = list(lab_dirs_with_safety())
        self.assertGreaterEqual(len(dirs), 3)
        for d in dirs:
            s = yaml.safe_load((d / "lab.yaml").read_text(encoding="utf-8"))
            words = " ".join(s["safety"]["warning"].split())
            readme = (d / "README.md").read_text(encoding="utf-8")
            self.assertIn(words, " ".join(readme.replace(">", " ").split()), d)
            head = "\n".join((d / "break_fix.sh").read_text(encoding="utf-8").splitlines()[:12])
            self.assertIn("WARNING: this lab does more than break a throwaway container.", head, d)
            self.assertIn(" ".join(words.split()[:6]), " ".join(head.replace("#", " ").split()), d)

    def test_killercoda_intro_carries_the_warning(self):
        lab = spec.load(REPO / "certs/az-900/2.4/lab")
        intro = export_killercoda.scenario(lab, allow_unverified=True)["intro.md"]
        self.assertIn("Warning: this lab does more than break a throwaway container.", intro)
        self.assertIn("/etc/hosts", intro)

    def test_a_lab_without_safety_exports_as_before(self):
        lab = spec.load(REPO / "certs/cka/1.1/lab")
        self.assertNotIn("Warning:", export_killercoda.scenario(lab, allow_unverified=True)["intro.md"])


class ConfirmTests(unittest.TestCase):
    SPEC = {"safety": {"risks": ["modifies-host"], "warning": "Edits /etc/hosts on this machine; use a VM."}}

    def run_confirm(self, spec_, stdin, env=None, answer="yes"):
        out = []
        ok = safety.confirm(spec_, "Lab x/1", echo=out.append, ask=lambda _p: answer, stdin=stdin, env=env or {})
        return ok, "\n".join(out)

    def test_no_safety_block_starts_silently(self):
        self.assertEqual(self.run_confirm({}, io.StringIO()), (True, ""))

    def test_not_a_terminal_refuses_after_printing(self):
        ok, out = self.run_confirm(self.SPEC, io.StringIO())
        self.assertFalse(ok)
        self.assertIn("/etc/hosts", out)
        self.assertIn(safety.ACCEPT_ENV, out)

    def test_env_accepts_after_printing(self):
        ok, out = self.run_confirm(self.SPEC, io.StringIO(), env={safety.ACCEPT_ENV: "yes"})
        self.assertTrue(ok)
        self.assertIn("/etc/hosts", out)

    def test_terminal_needs_an_explicit_yes(self):
        self.assertTrue(self.run_confirm(self.SPEC, Tty(), answer="yes")[0])
        self.assertFalse(self.run_confirm(self.SPEC, Tty(), answer="y")[0])
        self.assertFalse(self.run_confirm(self.SPEC, Tty(), answer="")[0])


class LabUpTests(unittest.TestCase):
    def invoke(self, env):
        clean = {k: v for k, v in os.environ.items() if k != safety.ACCEPT_ENV}
        with mock.patch.object(cli.labs, "up", return_value={"state": "running"}) as up, \
             mock.patch.object(cli.labs, "enter_hint", return_value=None), \
             mock.patch.dict(os.environ, {**clean, **env}, clear=True):
            result = CliRunner().invoke(cli.app, ["lab", "up", "az-900", "2.4"])
        return result, up

    def test_lab_up_prints_the_warning_and_does_not_start_without_consent(self):
        result, up = self.invoke({})
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertIn("/etc/hosts", result.output)
        up.assert_not_called()

    def test_lab_up_starts_with_explicit_consent(self):
        result, up = self.invoke({safety.ACCEPT_ENV: "yes"})
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("/etc/hosts", result.output)
        up.assert_called_once()


if __name__ == "__main__":
    unittest.main()
