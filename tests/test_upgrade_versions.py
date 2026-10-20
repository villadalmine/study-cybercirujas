"""scripts/upgrade_versions.py (#51): a version bump that touches only the lines a plan lists, and twice is once."""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import curriculum_diff as cd  # noqa: E402
import upgrade_versions as uv  # noqa: E402

PINS = {"tracked": "1.35", "target": "1.37", "shift": 2, "patch": "1.37.1", "kindest_node": "v1.37.0",
        "date": "2026-10-21", "curriculum_commit": {"CKA": "b3c8508b9f", "CKAD": "f423fa49c0"}}


class Rewrite(unittest.TestCase):
    def test_a_sample_upgrade_keeps_its_distance(self):
        self.assertEqual(uv.rewrite("kube-apiserver   v1.34.1   v1.35.1", PINS), "kube-apiserver   v1.36.1   v1.37.1")
        self.assertEqual(uv.rewrite("(e.g. 1.33 -> 1.34 -> 1.35)", PINS), "(e.g. 1.35 -> 1.36 -> 1.37)")

    def test_a_companion_line_moves_once(self):
        once = uv.rewrite("[upgrade/versions] Cluster version: v1.34.1", PINS)
        self.assertEqual(once, "[upgrade/versions] Cluster version: v1.36.1")
        self.assertEqual(uv.rewrite(once, PINS), once)
        self.assertEqual(uv.rewrite("kubectl run --image=busybox:1.36", PINS), "kubectl run --image=busybox:1.36")

    def test_the_curriculum_link_is_pinned_by_commit(self):
        line = "# https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf"
        out = uv.rewrite(line, PINS)
        self.assertEqual(out, "# https://github.com/cncf/curriculum/raw/f423fa49c0/CKAD_Curriculum_v1.37.pdf")
        self.assertEqual(uv.rewrite(out, PINS), out)

    def test_patch_rules(self):
        self.assertEqual(uv.rewrite("node  Ready  v1.35.0", PINS), "node  Ready  v1.37.0")
        self.assertEqual(uv.rewrite("apt install kubeadm=1.35.1-1.1 1.35.x-00", PINS),
                         "apt install kubeadm=1.37.1-1.1 1.37.x-00")
        self.assertEqual(uv.rewrite("pkgs.k8s.io/core:/stable:/v1.35/deb/", PINS), "pkgs.k8s.io/core:/stable:/v1.37/deb/")

    def test_the_kind_node_takes_the_pinned_tag(self):
        self.assertEqual(uv.rewrite("runner_image: study-lab:k8s (kind v0.33.0, kindest/node v1.35.8)", PINS),
                         "runner_image: study-lab:k8s (kind v0.33.0, kindest/node v1.37.0)")

    def test_what_is_not_a_kubernetes_version_stays(self):
        line = "kubectl run x --image=busybox:1.36 # 1.35"
        self.assertEqual(uv.rewrite(line, PINS), "kubectl run x --image=busybox:1.36 # 1.37")
        self.assertEqual(uv.rewrite("containerd://1.7.13 and 10.1.35.4", PINS), "containerd://1.7.13 and 10.1.35.4")

    def test_already_on_target_is_skipped_and_odd_patch_stops(self):
        self.assertEqual(uv.rewrite("1.35 -> 1.37", PINS), "1.35 -> 1.37")
        with self.assertRaises(SystemExit):
            uv.rewrite("v1.35.7", PINS)


class Run(unittest.TestCase):
    def tree(self, root: Path):
        topic = root / "certs/cka/4.3"
        (topic / "en").mkdir(parents=True)
        (topic / "lab").mkdir()
        (topic / "en/content.md").write_text("keep v1.35.9-ish\nupgrade apply v1.35.1\nuntouched v1.35.0\n", encoding="utf-8")
        (topic / "en/meta.yaml").write_text("lang: en\nmodel: claude\n", encoding="utf-8")
        (topic / "lab/lab.yaml").write_text("kubernetes: '1.35'\nverified:\n  runner_image: kindest/node v1.35.8\n", encoding="utf-8")
        plan = {"certs": {"cka": {"topics": [{"topic": "4.3", "class": "keep", "version_lines": {"technical": [
            "certs/cka/4.3/en/content.md:2", "certs/cka/4.3/lab/lab.yaml:1",
            "certs/cka/4.3/lab/lab.yaml:3"]}}]}}}
        (root / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        (root / "pins.yaml").write_text("tracked: '1.35'\ntarget: '1.37'\nshift: 2\npatch: '1.37.1'\n"
                                        "kindest_node: v1.37.0\ndate: '2026-10-21'\n"
                                        "curriculum_commit: {CKA: b3c8508b9f, CKAD: f423fa49c0}\n", encoding="utf-8")
        return topic

    def go(self, root, scope, check=False):
        return uv.run(root / "plan.json", root / "pins.yaml", scope, None, check, root=root)

    def test_only_listed_lines_in_scope_move_and_a_second_run_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            topic = self.tree(root)
            self.assertEqual(self.go(root, "material", check=True), 1)
            self.assertIn("v1.35.1", (topic / "en/content.md").read_text(encoding="utf-8"))
            self.go(root, "material")
            self.assertEqual((topic / "en/content.md").read_text(encoding="utf-8"),
                             "keep v1.35.9-ish\nupgrade apply v1.37.1\nuntouched v1.35.0\n")
            self.assertIn("kubernetes: '1.35'", (topic / "lab/lab.yaml").read_text(encoding="utf-8"))
            self.assertIn("tool_edit:", (topic / "en/meta.yaml").read_text(encoding="utf-8"))
            before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
            self.assertEqual(self.go(root, "material", check=True), 0)
            self.go(root, "material")
            self.assertEqual({p: p.read_bytes() for p in root.rglob("*") if p.is_file()}, before)
            self.go(root, "labs")
            self.assertEqual((topic / "lab/lab.yaml").read_text(encoding="utf-8"),
                             "kubernetes: '1.37'\nverified:\n  runner_image: kindest/node v1.35.8\n")


class Evidence(unittest.TestCase):
    def test_the_verified_block_of_a_lab_is_never_rewritten(self):
        text = "kubernetes: '1.35'\nverified:\n  status: true\n  runner_image: kindest/node v1.35.8\nlicense: x\n"
        self.assertEqual(sorted(uv.evidence_lines(text)), [2, 3, 4])


class ToolEditProvenance(unittest.TestCase):
    """curriculum_diff.tool_edit_ok / wrong_rewrites: a scripted edit counts only for the lines the plan lists,
    byte for byte what the script writes, with the tool and sha256 the pins file (on the base) names."""

    D = "certs/cka/4.3/en"
    F = "certs/cka/4.3/en/content.md"
    PINS_PATH = "docs/upgrades/x.pins.yaml"
    OLD = "a\nupgrade apply v1.35.1\nc\n"
    GOOD = "a\nupgrade apply v1.37.1\nc\n"

    def setUp(self):
        def topic(n, cls):
            return {"topic": n, "class": cls, "version_lines": {"technical": [f"certs/cka/{n}/en/content.md:2"]}}
        self.plan = {"spec": "docs/upgrades/x.yaml",
                     "certs": {"cka": {"topics": [topic("4.3", "keep"), topic("4.4", "regenerate")]}}}
        self.sha = hashlib.sha256((REPO / "scripts/upgrade_versions.py").read_bytes()).hexdigest()
        self.pins = dict(PINS, tool="scripts/upgrade_versions.py", tool_sha256=self.sha)

    def base(self, pins=None):
        import yaml
        text = yaml.safe_dump(pins or self.pins)
        return lambda f: text if f == self.PINS_PATH else self.OLD

    def meta(self, sha=None, tool="scripts/upgrade_versions.py"):
        return {"model": "claude", "lang": "en", "tool_edit": {"tool": tool, "script_sha256": sha or self.sha}}

    def ok(self, new, meta=None, directory=None, pins=None):
        d = directory or self.D
        return cd.tool_edit_ok(REPO, self.plan, d, meta or self.meta(), [f"{d}/content.md"],
                               self.base(pins), lambda _: new)

    def test_the_committed_pins_name_this_script(self):
        import yaml
        pins = yaml.safe_load((REPO / "docs/upgrades/cka-ckad-1.37.pins.yaml").read_text(encoding="utf-8"))
        self.assertEqual((pins["tool"], pins["tool_sha256"]), ("scripts/upgrade_versions.py", self.sha),
                         "the script changed: update tool_sha256 in the pins file (and re-run the edits to restamp)")

    def test_accepted_for_the_line_the_script_writes(self):
        self.assertTrue(self.ok(self.GOOD))

    def test_refused_for_other_content_on_a_listed_line(self):
        self.assertFalse(self.ok(self.OLD.replace("upgrade apply v1.35.1", "echo pwned")))
        self.assertFalse(self.ok(self.OLD.replace("v1.35.1", "v1.37.2")))                 # not the pinned patch

    def test_refused_for_an_edit_outside_the_plan(self):
        self.assertFalse(self.ok(self.OLD.replace("a\n", "A\n", 1)))                      # line 1 is not listed
        self.assertFalse(self.ok(self.OLD.replace("c\n", "a new sentence\n")))            # line 3 neither
        self.assertFalse(self.ok(self.GOOD + "extra\n"))                                  # a line was added

    def test_refused_for_another_tool_or_a_sha_the_pins_do_not_name(self):
        self.assertFalse(self.ok(self.GOOD, self.meta("0" * 64)))                         # script differs from the meta
        self.assertFalse(self.ok(self.GOOD, self.meta(tool="scripts/other.py")))          # not in TOOLS
        self.assertFalse(self.ok(self.GOOD, pins=dict(self.pins, tool_sha256="1" * 64)))  # the pins name another sha
        self.assertFalse(self.ok(self.GOOD, pins=dict(self.pins, tool="scripts/other.py")))
        self.assertFalse(self.ok(self.GOOD, {"model": "claude"}))                         # no tool_edit block
        self.assertFalse(self.ok(self.GOOD, directory="certs/cka/4.4/en"))                # regenerated topic
        self.assertFalse(cd.tool_edit_ok(REPO, self.plan, self.D, self.meta(), [self.F],
                                         lambda _: None, lambda _: self.GOOD))             # no pins on the base

    def test_guard_flags_a_wrong_rewrite_of_any_listed_line(self):
        head = lambda _: self.OLD.replace("upgrade apply v1.35.1", "echo pwned")
        self.assertEqual(len(cd.wrong_rewrites(self.plan, [self.F], self.base(), head)), 1)
        self.assertEqual(cd.wrong_rewrites(self.plan, [self.F], self.base(), lambda _: self.GOOD), [])
        self.assertEqual(cd.wrong_rewrites(self.plan, [self.F], lambda _: None, head), [])  # no pins: nothing to compare


if __name__ == "__main__":
    unittest.main()
