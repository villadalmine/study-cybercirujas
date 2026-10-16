"""scripts/check_labels.py: the current tree passes, and a label nobody defined fails (issue #75)."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_labels  # noqa: E402


def tree(tmp: Path) -> Path:
    """A copy of the files the check reads, so a test can break it."""
    for rel in (".github/labels.yml", ".github/labeler.yml", ".github/ISSUE_TEMPLATE", ".github/workflows", "scripts/check_pr.py"):
        src, dst = REPO / rel, tmp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst) if src.is_dir() else shutil.copy(src, dst)
    return tmp


class CheckLabelsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = tree(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def problems(self):
        return check_labels.check(self.root)[0]

    def test_current_tree_passes(self):
        self.assertEqual(check_labels.check(REPO)[0], [])
        run = subprocess.run([sys.executable, str(REPO / "scripts/check_labels.py")], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_form_with_unknown_label_fails(self):
        form = self.root / ".github/ISSUE_TEMPLATE/bug.yml"
        text = form.read_text(encoding="utf-8")
        self.assertIn("labels: [", text)
        form.write_text(text.replace("labels: [", "labels: [no-such-label, ", 1), encoding="utf-8")
        found = self.problems()
        self.assertTrue(any("no-such-label" in p and "bug.yml" in p for p in found), found)

    def test_labeler_workflow_and_check_pr_references_fail(self):
        labeler = self.root / ".github/labeler.yml"
        labeler.write_text(labeler.read_text(encoding="utf-8")
                           + '"type:nope":\n  - changed-files:\n      - any-glob-to-any-file: [x]\n', encoding="utf-8")
        wf = self.root / ".github/workflows/labeler.yml"
        wf.write_text(wf.read_text(encoding="utf-8") + "      - run: gh pr edit 1 --add-label ghost-label\n", encoding="utf-8")
        cp = self.root / "scripts/check_pr.py"
        cp.write_text(cp.read_text(encoding="utf-8") + '\nGHOST_LABEL = "scope-ghost"\n', encoding="utf-8")
        found = " ".join(self.problems())
        for name in ("type:nope", "ghost-label", "scope-ghost"):
            self.assertIn(name, found)

    def test_stale_action_inputs_are_read(self):
        (self.root / ".github/workflows/stale.yml").write_text(
            "on: workflow_dispatch\njobs:\n  s:\n    runs-on: ubuntu-latest\n    steps:\n"
            "      - uses: actions/stale@x\n        with:\n          stale-issue-label: lifecycle:stale\n"
            "          exempt-issue-labels: help wanted,missing-one\n", encoding="utf-8")
        found = [p for p in self.problems() if "stale.yml" in p]
        self.assertEqual(len(found), 1, found)
        self.assertIn("missing-one", found[0])

    def test_switches_named_like_labels_are_not_labels(self):
        (self.root / ".github/workflows/sync.yml").write_text(
            "on: workflow_dispatch\njobs:\n  s:\n    runs-on: ubuntu-latest\n    steps:\n"
            "      - uses: x/y@z\n        with:\n          delete-other-labels: 'false'\n          sync-labels: true\n",
            encoding="utf-8")
        self.assertEqual(self.problems(), [])

    def test_label_file_rules(self):
        lab = self.root / ".github/labels.yml"
        lab.write_text('- {name: a, color: zzz, description: ""}\n- {name: a, color: "123456", description: "ok"}\n'
                       '- {name: b, color: "123456", description: "ok", aliases: [a]}\n', encoding="utf-8")
        found = " ".join(self.problems())
        for expect in ("hex color", "no description", "duplicate label 'a'", "alias 'a'"):
            self.assertIn(expect, found)


if __name__ == "__main__":
    unittest.main()
