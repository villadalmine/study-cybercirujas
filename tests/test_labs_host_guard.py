"""`teach lab up` never runs a kubectl lab's script on the host unless --host is passed."""
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from typer.testing import CliRunner

from teach import cli
from teach.core import labs


class HostGuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        directory = Path(tmp.name)
        (directory / "break_fix.sh").write_text("#!/bin/bash\nkubectl get nodes\n")
        (directory / "lab.yaml").write_text("provider: local\n")
        self.calls = []
        for target, value in (
            ("lab_dir", lambda c, t: directory),
            ("_load_spec", lambda d: {"provider": "local"}),
            ("_write_status", lambda d, state, msg=None: {"state": state}),
            ("_up_cluster", lambda d, n: self.calls.append(("host", n))),
        ):
            patcher = mock.patch.object(labs, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_kubectl_lab_is_refused_by_default(self):
        with self.assertRaisesRegex(labs.LabError, "study-lab run"):
            labs.up("cka", "1.1")
        self.assertEqual(self.calls, [])

    def test_host_flag_runs_it_with_a_loud_warning(self):
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(labs.up("cka", "1.1", host=True)["state"], "running")
        self.assertEqual(self.calls, [("host", "teach-cka-1-1")])
        self.assertIn("DIRECTLY ON THIS MACHINE", err.getvalue())

    def test_cli_exposes_host_flag(self):
        runner = CliRunner()
        res = runner.invoke(cli.app, ["lab", "up", "cka", "1.1"])
        self.assertEqual(res.exit_code, 1)
        self.assertEqual(self.calls, [])
        res = runner.invoke(cli.app, ["lab", "up", "cka", "1.1", "--host"])
        self.assertEqual(res.exit_code, 0)
        self.assertTrue(self.calls)


if __name__ == "__main__":
    unittest.main()
