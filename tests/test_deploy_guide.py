"""docs/DEPLOY.md and its helpers: explicit tags, generic example values, a working `make site-tag`."""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEPLOY = REPO / "docs" / "DEPLOY.md"
EXAMPLE = REPO / "deploy" / "helm" / "values-study.example.yaml"


class DeployDocTests(unittest.TestCase):
    def test_never_deploys_latest(self):
        text = DEPLOY.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"image\.tag[= ]+[\"']?latest")
        self.assertIn("--set image.tag=$TAG", text)

    def test_covers_the_operator_steps(self):
        text = DEPLOY.read_text(encoding="utf-8")
        for needle in ("```mermaid", "helm lint", "helm template", "--dry-run=server",
                       "rollout status", "/healthz", "helm -n $NS rollback", "get values",
                       "make site-tag", "ReadWriteOnce", "## Upgrade notes", "exec format error"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)

    def test_example_values_hold_no_cluster_specific_names(self):
        text = EXAMPLE.read_text(encoding="utf-8")
        for name in ("registry.registry", "cluster-gateway", ".cluster.home", "longhorn"):
            with self.subTest(name=name):
                self.assertNotIn(name, text)
        self.assertNotRegex(text, r"(?m)^\s*tag:\s*[\"']?latest")


@unittest.skipIf(shutil.which("make") is None or shutil.which("git") is None, "make or git missing")
class SiteTagTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q")
        self.git("commit", "-q", "--allow-empty", "-m", "one")
        self.git("tag", "v0.1.0")
        self.git("commit", "-q", "--allow-empty", "-m", "two")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.dir, env=self.env, capture_output=True,
                              text=True, check=True, timeout=30).stdout.strip()

    def make(self, *args):
        return subprocess.run(["make", "--no-print-directory", "-f", str(REPO / "Makefile"), "site-tag", *args],
                              cwd=self.dir, env=self.env, capture_output=True, text=True, timeout=60)

    def today(self):
        return "site-" + datetime.now(timezone.utc).strftime("%Y-%m-%d")

    def test_tags_the_ref_with_release_and_image(self):
        res = self.make("SITE_REF=v0.1.0", "IMAGE_TAG=v0.1.0")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        tag = self.today()
        self.assertIn(f"git push origin {tag}", res.stdout)
        self.assertEqual(self.git("rev-parse", f"{tag}^{{commit}}"), self.git("rev-parse", "v0.1.0^{commit}"))
        msg = self.git("tag", "-l", "--format=%(contents)", tag)
        self.assertIn("release: v0.1.0", msg)
        self.assertIn("image: v0.1.0", msg)

    def test_refuses_a_second_tag_the_same_day_unless_suffixed(self):
        self.assertEqual(self.make().returncode, 0)
        again = self.make()
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("SITE_SUFFIX", again.stdout + again.stderr)
        res = self.make("SITE_SUFFIX=.2")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertTrue(self.git("tag", "-l", self.today() + ".2"))

    def test_rejects_a_ref_that_is_not_a_commit(self):
        res = self.make("SITE_REF=no-such-ref")
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(re.search(r"site-", self.git("tag", "-l", "site-*")))


if __name__ == "__main__":
    unittest.main()
