"""The chart smoke test (.github/workflows/chart-smoke.yml) stays pinned, bounded and self-contained."""
import re
import shutil
import subprocess
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "chart-smoke.yml"
SMOKE = REPO / "deploy" / "helm-smoke" / "smoke.sh"
VALUES = REPO / "deploy" / "helm-smoke" / "values.yaml"
CHART = REPO / "deploy" / "helm"
HELM = shutil.which("helm")


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.wf = yaml.safe_load(self.text)

    def test_every_action_is_pinned_by_sha(self):
        uses = re.findall(r"uses:\s*(\S+)", self.text)
        self.assertTrue(uses)
        for ref in uses:
            with self.subTest(ref=ref):
                self.assertRegex(ref, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")

    def test_runs_only_for_the_chart_and_the_image_recipe(self):
        on = self.wf[True] if True in self.wf else self.wf["on"]   # PyYAML reads `on:` as True
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                self.assertIn("deploy/**", on[event]["paths"])

    def test_job_and_steps_are_time_bounded(self):
        job = self.wf["jobs"]["install"]
        self.assertLessEqual(job["timeout-minutes"], 30)
        runs = [s for s in job["steps"] if "run" in s]
        for step in runs:
            with self.subTest(step=step["name"]):
                self.assertIn("timeout-minutes", step)

    def test_the_kind_node_image_is_pinned_by_digest(self):
        self.assertRegex(self.wf["env"]["KIND_NODE_IMAGE"], r"^kindest/node:v[\d.]+@sha256:[0-9a-f]{64}$")

    def test_calls_the_smoke_script(self):
        self.assertIn("deploy/helm-smoke/smoke.sh", self.text)


class SmokeScriptTests(unittest.TestCase):
    def test_is_executable_in_git(self):
        out = subprocess.run(["git", "ls-files", "-s", "deploy/helm-smoke/smoke.sh"], cwd=REPO,
                             capture_output=True, text=True, check=True, timeout=30).stdout
        self.assertTrue(out.startswith("100755"), out)

    def test_verifies_and_cleans_up(self):
        text = SMOKE.read_text(encoding="utf-8")
        for needle in ("set -euo pipefail", "openssl rand -hex 32", "--set-string", "helm install",
                       "rollout status", "/healthz", "/api/catalog", "touch /data/", "helm uninstall"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        self.assertNotIn("change-me", text)


@unittest.skipIf(HELM is None, "helm not installed")
class SmokeValuesRenderTests(unittest.TestCase):
    def render(self):
        res = subprocess.run([HELM, "template", "study", str(CHART), "-f", str(VALUES),
                              "--set-string", "env.TEACH_SECRET=" + "ab" * 32],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stderr)
        return [d for d in yaml.safe_load_all(res.stdout) if d]

    def test_renders_only_what_kind_can_run(self):
        kinds = sorted(d["kind"] for d in self.render())
        self.assertEqual(kinds, ["Deployment", "PersistentVolumeClaim", "Secret", "Service"])

    def test_never_pulls_and_uses_the_default_storage_class(self):
        docs = {d["kind"]: d for d in self.render()}
        container = docs["Deployment"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["imagePullPolicy"], "Never")
        self.assertNotIn("storageClassName", docs["PersistentVolumeClaim"]["spec"])


if __name__ == "__main__":
    unittest.main()
