"""Static guards on the app image: pinned base, non-root user, no .env in the build context."""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOCKERFILE = REPO / "deploy" / "Dockerfile"


class ImageHardeningTests(unittest.TestCase):
    def test_app_image_base_is_pinned_by_digest(self):
        froms = re.findall(r"^FROM\s+(\S+)", DOCKERFILE.read_text(encoding="utf-8"), re.M)
        self.assertTrue(froms)
        for ref in froms:
            self.assertRegex(ref, r"@sha256:[0-9a-f]{64}$")

    def test_app_image_does_not_run_as_root(self):
        users = [l.split()[1] for l in DOCKERFILE.read_text(encoding="utf-8").splitlines() if l.startswith("USER ")]
        self.assertTrue(users)
        self.assertNotIn(users[-1], ("root", "0"))

    def test_dockerignore_keeps_env_files_out_of_the_context(self):
        entries = (REPO / ".dockerignore").read_text(encoding="utf-8").split()
        self.assertLessEqual({".env", ".env.*", "*.env"}, set(entries))


if __name__ == "__main__":
    unittest.main()
