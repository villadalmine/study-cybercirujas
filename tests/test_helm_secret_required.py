"""The chart refuses to render without a real TEACH_SECRET."""
import shutil
import subprocess
from pathlib import Path

import pytest

CHART = Path(__file__).resolve().parent.parent / "deploy" / "helm"
HELM = shutil.which("helm")
pytestmark = pytest.mark.skipif(HELM is None, reason="helm not installed")


def render(*sets):
    cmd = [HELM, "template", "study", str(CHART)]
    for s in sets:
        cmd += ["--set", s]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


def test_default_values_do_not_render():
    res = render()
    assert res.returncode != 0 and "TEACH_SECRET" in res.stderr


@pytest.mark.parametrize("value", ["change-me", "short", "PONER-UN-SECRETO-FUERTE-DE-32-BYTES"])
def test_placeholders_and_short_values_do_not_render(value):
    res = render(f"env.TEACH_SECRET={value}")
    assert res.returncode != 0 and "TEACH_SECRET" in res.stderr


def test_a_real_secret_renders():
    res = render("env.TEACH_SECRET=" + "a1" * 20)
    assert res.returncode == 0, res.stderr
    assert "TEACH_SECRET" in res.stdout
