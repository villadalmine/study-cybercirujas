"""#297: a generated lab honours the study-lab runner's contract or is not written.

nca-aiio 1.2, 1.4 and 1.5 reached review with no verify or cleanup mode, a
confirmation that waited for a terminal, and a lab.yaml sized at a fixed 1 CPU.
These pin the gate (`labs.contract_problems`), the sizing (`# lab-resources:`),
the retry in `generator._write_lab`, and run_batch's lab-only repair.
"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

import run_batch  # noqa: E402
from teach.core import generator, labs  # noqa: E402
from teach.lab import spec  # noqa: E402

PAD = "# " + "x" * 400 + "\n"  # past the recap guard's 400-character floor

GOOD = """#!/usr/bin/env bash
# lab-resources: cpus=2 ram_mb=2048
""" + PAD + """case "${1:-break}" in
  break) echo broken ;;
  verify) test -f /tmp/fixed ;;
  cleanup) rm -f /tmp/fixed ;;
esac
"""
NO_VERIFY = GOOD.replace("  verify) test -f /tmp/fixed ;;\n", "")
ASKS = GOOD.replace('case', 'read -r -p "Type yes: " ans\ncase', 1)


class Contract(unittest.TestCase):
    def test_a_full_contract_passes(self):
        self.assertEqual(labs.contract_problems(GOOD), [])

    def test_a_missing_mode_is_named(self):
        self.assertEqual(labs.contract_problems(NO_VERIFY), ["no verify mode (a `case` arm such as verify)"])

    def test_a_terminal_prompt_needs_the_runner_variables(self):
        self.assertIn("hangs under the runner", labs.contract_problems(ASKS)[0])
        guarded = ASKS.replace("read -r -p", '[ "${STUDY_LAB:-}" = 1 ] || read -r -p')
        self.assertEqual(labs.contract_problems(guarded), [])
        self.assertEqual(labs.contract_problems(GOOD.replace("case", "read -r ans </dev/tty\ncase", 1))[0][-24:],
                         "so it hangs under the runner"[-24:])

    def test_reading_a_file_or_a_comment_is_not_a_prompt(self):
        loops = GOOD + 'while IFS= read -r line; do :; done < f\nIFS=. read -r a b <<<"$v"\n# read -p in a comment\n'
        self.assertEqual(labs.contract_problems(loops), [])

    def test_the_gate_agrees_with_the_runner(self):
        for script in (GOOD, NO_VERIFY):
            c = spec.infer_contract(script)
            runner_ok = all(c[a] is not None for a in ("break", "verify", "cleanup"))
            self.assertEqual(runner_ok, not labs.contract_problems(script))


class Resources(unittest.TestCase):
    def test_the_header_sizes_lab_yaml(self):
        vm = labs.default_spec("c", "1.1", "t", GOOD)["resources"]["vms"][0]
        self.assertEqual((vm["cpus"], vm["ram_mb"]), (2, 2048))

    def test_missing_or_out_of_bounds_falls_back_per_value(self):
        self.assertEqual(labs.script_resources(None), labs.DEFAULT_VM)
        self.assertEqual(labs.script_resources("# lab-resources: cpus=64 ram_mb=512\n"), {"cpus": 1, "ram_mb": 512})
        self.assertEqual(labs.default_spec("c", "1.1", "t")["resources"]["vms"][0]["cpus"], 1)


class WriteLab(unittest.TestCase):
    def run_with(self, answers):
        prompts = []

        def complete(system, prompt):
            prompts.append(prompt)
            return answers.pop(0)

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        lab_dir = Path(tmp.name) / "lab"
        with mock.patch.object(generator.pipeline, "REPO", Path(tmp.name)):
            try:
                generator._write_lab(complete, "sys", "ctx", "c", "1.1", "Title", lab_dir)
                error = None
            except generator.GeneratorConfigError as raised:
                error = str(raised)
        return lab_dir, prompts, error, Path(tmp.name)

    def test_the_prompt_states_the_contract(self):
        for must in ("verify", "cleanup", "STUDY_LAB=1", "LAB_DISPOSABLE=yes", "# lab-resources:"):
            self.assertIn(must, generator.LAB_PROMPT)

    def test_a_rejected_script_is_retried_with_its_problems(self):
        lab_dir, prompts, error, _ = self.run_with([NO_VERIFY, GOOD])
        self.assertIsNone(error)
        self.assertEqual(len(prompts), 2)
        self.assertIn("no verify mode", prompts[1])
        self.assertEqual((lab_dir / "break_fix.sh").read_text(encoding="utf-8").strip(), GOOD.strip())
        self.assertIn("cpus: 2", (lab_dir / "lab.yaml").read_text(encoding="utf-8"))

    def test_after_the_last_attempt_nothing_is_written_and_the_batch_may_retry(self):
        lab_dir, _, error, root = self.run_with([NO_VERIFY, ASKS])
        self.assertFalse(lab_dir.exists())
        self.assertIn("below the quality floor", error)  # pipeline.yaml budget.retry_errors
        self.assertTrue((root / ".rejected" / "c-1.1-lab.sh").exists())


class BatchRepairsOnlyTheLab(unittest.TestCase):
    def topic(self, root: Path, lab: bool) -> None:
        d = root / "certs" / "c" / "1.1"
        (d / "en").mkdir(parents=True)
        for kind in ("content.md", "exercises.md"):
            (d / "en" / kind).write_text("material", encoding="utf-8")
        if lab:
            (d / "lab").mkdir()
            (d / "lab" / "break_fix.sh").write_text("#!/bin/bash\n", encoding="utf-8")

    def test_content_fine_and_lab_missing_runs_teach_cert_lab(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch("teach.core.quality.check_file", return_value=[]):
            self.topic(Path(tmp), lab=False)
            self.assertTrue(run_batch.lab_only("c", "1.1", "en", Path(tmp)))
            self.assertFalse(run_batch.lab_only("c", "1.1", "es", Path(tmp)))
        with mock.patch.object(run_batch, "lab_only", return_value=True):
            self.assertEqual(run_batch.command("c", "1.1", "en", "claude")[1:5], ["cert", "lab", "c", "--topic"])

    def test_bad_content_or_a_present_lab_regenerates_the_topic(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.topic(Path(tmp), lab=True)
            with mock.patch("teach.core.quality.check_file", return_value=[]):
                self.assertFalse(run_batch.lab_only("c", "1.1", "en", Path(tmp)))
        with tempfile.TemporaryDirectory() as tmp:
            self.topic(Path(tmp), lab=False)
            with mock.patch("teach.core.quality.check_file", return_value=["too small"]):
                self.assertFalse(run_batch.lab_only("c", "1.1", "en", Path(tmp)))
        with mock.patch.object(run_batch, "lab_only", return_value=False):
            self.assertIn("--force", run_batch.command("c", "1.1", "en", "claude"))


if __name__ == "__main__":
    unittest.main()
