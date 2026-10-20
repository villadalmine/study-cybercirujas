"""docker.yml publishes amd64 and arm64, pins its actions, and never pushes from a pull request."""
import re
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "docker.yml"


class DockerWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.wf = yaml.safe_load(self.text)
        self.on = self.wf.get("on", self.wf.get(True))   # PyYAML reads `on:` as True
        self.steps = self.wf["jobs"]["build-and-push"]["steps"]

    def step(self, prefix):
        return next(s for s in self.steps if s.get("uses", "").startswith(prefix))

    def test_every_action_is_pinned_by_sha(self):
        uses = re.findall(r"uses:\s*(\S+)", self.text)
        self.assertTrue(uses)
        for ref in uses:
            with self.subTest(ref=ref):
                self.assertRegex(ref, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")

    def test_builds_amd64_and_arm64_with_qemu_and_buildx(self):
        platforms = self.wf["env"]["PLATFORMS"].split(",")
        self.assertEqual(sorted(platforms), ["linux/amd64", "linux/arm64"])
        self.assertEqual(self.step("docker/build-push-action")["with"]["platforms"], "${{ env.PLATFORMS }}")
        names = [s.get("uses", "").split("@")[0] for s in self.steps]
        for needed in ("docker/setup-qemu-action", "docker/setup-buildx-action"):
            with self.subTest(needed=needed):
                self.assertIn(needed, names)
                self.assertLess(names.index(needed), names.index("docker/build-push-action"))

    def test_a_pull_request_builds_but_never_pushes_or_logs_in(self):
        self.assertIn("pull_request", self.on)
        self.assertEqual(self.step("docker/build-push-action")["with"]["push"],
                         "${{ github.event_name != 'pull_request' }}")
        self.assertEqual(self.step("docker/login-action")["if"], "github.event_name != 'pull_request'")

    def test_a_pull_request_touching_deps_or_code_builds_both_platforms(self):
        for path in ("deploy/Dockerfile", "pyproject.toml", "teach/**", ".github/workflows/docker.yml"):
            with self.subTest(path=path):
                self.assertIn(path, self.on["pull_request"]["paths"])

    def test_binfmt_is_pinned_by_digest(self):
        image = self.step("docker/setup-qemu-action")["with"]["image"]
        self.assertRegex(image, r"^docker\.io/tonistiigi/binfmt:[\w.-]+@sha256:[0-9a-f]{64}$")

    def test_main_publishes_in_order(self):
        self.assertIn("concurrency", self.wf)

    def test_the_job_is_time_bounded(self):
        self.assertLessEqual(self.wf["jobs"]["build-and-push"]["timeout-minutes"], 60)

    def test_the_base_image_is_pinned_by_digest(self):
        dockerfile = (REPO / "deploy" / "Dockerfile").read_text(encoding="utf-8")
        self.assertRegex(dockerfile, r"(?m)^FROM \S+@sha256:[0-9a-f]{64}")


if __name__ == "__main__":
    unittest.main()
