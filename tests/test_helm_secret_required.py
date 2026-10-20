"""The chart refuses to render without a real TEACH_SECRET."""
import shutil
import subprocess
import unittest
from pathlib import Path

CHART = Path(__file__).resolve().parent.parent / "deploy" / "helm"
HELM = shutil.which("helm")


def render(*sets):
    cmd = [HELM, "template", "study", str(CHART)]
    for s in sets:
        cmd += ["--set", s]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


@unittest.skipIf(HELM is None, "helm not installed")
class HelmSecretTests(unittest.TestCase):
    def test_default_values_do_not_render(self):
        res = render()
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("TEACH_SECRET", res.stderr)

    def test_placeholders_and_short_values_do_not_render(self):
        for value in ("change-me", "short", "PONER-UN-SECRETO-FUERTE-DE-32-BYTES"):
            with self.subTest(value=value):
                res = render(f"env.TEACH_SECRET={value}")
                self.assertNotEqual(res.returncode, 0)
                self.assertIn("TEACH_SECRET", res.stderr)

    def test_digits_only_value_gets_the_intended_message(self):
        res = render("env.TEACH_SECRET=1234567890")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("placeholder or shorter", res.stderr)

    def test_a_real_secret_renders(self):
        res = render("env.TEACH_SECRET=" + "a1" * 20)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("TEACH_SECRET", res.stdout)


if __name__ == "__main__":
    unittest.main()
