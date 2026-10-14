"""Shared fixtures for the study-lab tests (pytest; unittest discover skips this folder)."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from teach.lab import cli  # noqa: E402


def run_cli(*args: str) -> int:
    return cli.main(list(args))


@pytest.fixture
def new_lab(tmp_path):
    """Factory: scaffold a lab from the template with `study-lab new`."""
    def make(requires="linux", name="mylab", cert="demo", topic="1.1"):
        dest = tmp_path / name
        assert run_cli("new", str(dest), "--cert", cert, "--topic", topic,
                       "--title", "Demo lab", "--requires", requires) == 0
        return dest
    return make


def git_repo(path: Path) -> Path:
    """Turn a folder into a one-commit git repo (the --from fixture)."""
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "lab"], check=True)
    return path


def docker_ok() -> bool:
    if shutil.which("docker") is None:
        return False
    return subprocess.run(["docker", "info"], capture_output=True).returncode == 0


def image_ok(tag: str) -> bool:
    return docker_ok() and subprocess.run(["docker", "image", "inspect", tag], capture_output=True).returncode == 0


needs_docker = pytest.mark.skipif(not docker_ok(), reason="docker not available")
