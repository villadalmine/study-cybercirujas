"""The local lab provider must hand the student's stdin to break_fix.sh.

Found by running `teach lab up lpi-010-160 2.1` on a clean clone (2026-10-14):
the script asks for a confirmation, `docker exec` had no `-i`, `read` got EOF,
the script cancelled itself and the lab was reported as running with nothing
broken. 178 of the 548 lab scripts ask for a confirmation this way.
"""
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from teach.core import labs


class ExecScriptCmdTests(unittest.TestCase):
    def test_stdin_is_attached(self):
        cmd = labs._exec_script_cmd("teach-x", interactive=False)
        self.assertIn("-i", cmd)
        self.assertNotIn("-t", cmd)  # docker refuses -t without a terminal

    def test_terminal_gets_a_tty(self):
        cmd = labs._exec_script_cmd("teach-x", interactive=True)
        self.assertEqual(cmd[:4], ["docker", "exec", "-i", "-t"])
        self.assertEqual(cmd[-3:], ["teach-x", "bash", "break_fix.sh"])


class RunAsTests(unittest.TestCase):
    """break_fix.sh runs as the user its own guard asks for."""

    def test_linux_essentials_runs_as_student(self):
        self.assertEqual(labs._script_user(REPO / "certs/lpi-010-160/2.1/lab"), "student")

    def test_lpic_runs_as_root(self):
        self.assertEqual(labs._script_user(REPO / "certs/lpic-1/104.5/lab"), "root")

    def test_lab_yaml_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "break_fix.sh").write_text('[ "$(id -u)" -ne 0 ] && exit 1\n')
            self.assertEqual(labs._script_user(directory), "root")
            (directory / "lab.yaml").write_text("run_as: student\n")
            self.assertEqual(labs._script_user(directory), "student")


class EnterHintTests(unittest.TestCase):
    def test_container_lab_names_the_shell(self):
        hint = labs.enter_hint("lpi-010-160", "2.1")
        self.assertEqual(
            hint, "docker exec -it -u student -w /home/student teach-lpi-010-160-2-1 bash")


REPO = Path(__file__).resolve().parent.parent


class ContractTests(unittest.TestCase):
    """The lab contract (lab.yaml + setup scripts), checked offline."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.old_root = os.environ.get("TEACH_ROOT")
        shutil.copy(REPO / "catalog.yaml", self.root / "catalog.yaml")
        (self.root / "certs").mkdir()
        shutil.copy(REPO / "certs" / "cka.md", self.root / "certs" / "cka.md")
        os.environ["TEACH_ROOT"] = str(self.root)

    def tearDown(self):
        if self.old_root is None:
            os.environ.pop("TEACH_ROOT", None)
        else:
            os.environ["TEACH_ROOT"] = self.old_root
        self.tmp.cleanup()

    def test_every_lab_in_the_repo_honours_the_contract(self):
        os.environ["TEACH_ROOT"] = str(REPO)
        directories = sorted(p.parent for p in (REPO / "certs").glob("*/*/lab/lab.yaml"))
        self.assertGreater(len(directories), 500)
        known = {line.split("#")[0].strip() for line in
                 (REPO / "tests" / "fixtures" / "labs_known_broken.txt").read_text().splitlines()}
        known.discard("")
        for directory in directories:
            relative = directory.relative_to(REPO).as_posix()
            problems = labs.validate_spec(directory)
            with self.subTest(lab=relative):
                if relative in known:
                    self.assertTrue(problems, f"{relative} passes now — remove it from "
                                              "tests/fixtures/labs_known_broken.txt")
                else:
                    self.assertEqual(problems, [])

    def test_new_lab_from_the_template_validates(self):
        directory = labs.scaffold("cka", "1.1")
        self.assertEqual(labs.validate_spec(directory), [])
        self.assertIn("TODO", (directory / "break_fix.sh").read_text())
        with self.assertRaises(labs.LabError):
            labs.scaffold("cka", "1.1")  # never overwrite without --force

    def test_a_broken_lab_is_reported(self):
        directory = labs.scaffold("cka", "1.1")
        (directory / "lab.yaml").write_text("provider: cloud-x\nresources: {}\n")
        problems = "\n".join(labs.validate_spec(directory))
        self.assertIn("missing key 'cert'", problems)
        self.assertIn("provider 'cloud-x'", problems)

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_malformed_nested_fields_are_reported_not_raised(self):
        directory = labs.scaffold("cka", "1.1")
        for body, expected in [
            ("cert: c\ntopic: t\ntitle: x\nprovider: local\nresources: [invalid]\nsetup: [break_fix.sh]\n",
             "resources must be a mapping"),
            ("cert: c\ntopic: t\ntitle: x\nprovider: local\nresources: {vms: [debian]}\nsetup: [break_fix.sh]\n",
             "each resources.vms entry must be a mapping"),
            ("cert: c\ntopic: t\ntitle: x\nprovider: local\nresources: {vms: [{os: debian-12}]}\nsetup: break_fix.sh\n",
             "setup must be a list"),
            ("cert: c\ntopic: t\ntitle: x\nprovider: local\nresources: {vms: [{os: debian-12}]}\nsetup: [{x: 1}]\n",
             "setup must be a list"),
            ("cert: c\ntopic: t\ntitle: x\nprovider: local\nresources: {vms: [{os: debian-12}]}\nsetup: []\n",
             "needs break_fix.sh in setup"),
        ]:
            with self.subTest(expected=expected):
                (directory / "lab.yaml").write_text(body)
                self.assertTrue(any(expected in p for p in labs.validate_spec(directory)),
                                labs.validate_spec(directory))

    def test_unhashable_os_is_reported_not_raised(self):
        directory = labs.scaffold("cka", "1.1")
        for os_value in ("[debian-12]", "{name: debian-12}"):
            with self.subTest(os=os_value):
                (directory / "lab.yaml").write_text(
                    "cert: c\ntopic: t\ntitle: x\nprovider: local\n"
                    f"resources: {{vms: [{{os: {os_value}}}]}}\nsetup: [break_fix.sh]\n")
                self.assertTrue(any("os " in p for p in labs.validate_spec(directory)))

    def test_new_lab_never_overwrites_a_lone_break_fix_script(self):
        directory = labs.lab_dir("cka", "1.1")
        directory.mkdir(parents=True)
        (directory / "break_fix.sh").write_text("# my own work\n")
        with self.assertRaises(labs.LabError):
            labs.scaffold("cka", "1.1")
        self.assertEqual((directory / "break_fix.sh").read_text(), "# my own work\n")
        labs.scaffold("cka", "1.1", force=True)  # explicit overwrite still works
        self.assertIn("TODO", (directory / "break_fix.sh").read_text())

    def test_a_script_that_does_not_parse_is_reported(self):
        directory = labs.scaffold("cka", "1.1")
        (directory / "break_fix.sh").write_text("if then fi (\n")
        self.assertTrue(any("bash -n" in p for p in labs.validate_spec(directory)))


# Hook for the lab runner (branch `labs-runner`, docs/LABS-RUNNER.md): when it
# lands, its run/break/verify/cleanup suite goes in tests/e2e/ and runs under
# `make test-e2e`. Until then this records the gap instead of hiding it.
@unittest.skip("lab runner suite arrives with the labs-runner branch (docs/LABS-RUNNER.md)")
class LabRunnerLifecycleTests(unittest.TestCase):
    def test_run_break_verify_cleanup(self):
        pass


if __name__ == "__main__":
    unittest.main()
