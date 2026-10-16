"""deploy/killercoda/publish.sh: the failure paths must never wipe or damage the mirror."""
import shutil
import subprocess

import pytest

from conftest import REPO

SCRIPT = REPO / "deploy" / "killercoda" / "publish.sh"
pytestmark = pytest.mark.skipif(shutil.which("rsync") is None or shutil.which("git") is None, reason="needs rsync and git")


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def publish(build, mirror):
    return subprocess.run(["bash", str(SCRIPT), str(build), str(mirror)], capture_output=True, text=True)


def scenario(root, cert, name):
    d = root / cert / name
    d.mkdir(parents=True)
    (d / "index.json").write_text("{}")
    return d


@pytest.fixture
def mirror(tmp_path):
    m = tmp_path / "mirror"
    m.mkdir()
    git(m, "init", "-q", "-b", "main")
    (m / "README.md").write_text("hand written")
    scenario(m, "cka", "old-scenario")
    git(m, "add", "-A")
    git(m, "commit", "-q", "-m", "seed")
    return m


def test_an_export_without_scenarios_does_not_touch_the_mirror(tmp_path, mirror):
    build = tmp_path / "build"
    (build / "probe" / "ubuntu").mkdir(parents=True)
    (build / "probe" / "ubuntu" / "index.json").write_text("{}")   # the probes alone are not scenarios with evidence
    before = git(mirror, "rev-parse", "HEAD")
    r = publish(build, mirror)
    assert r.returncode == 3 and "refusing" in r.stderr
    assert git(mirror, "rev-parse", "HEAD") == before and (mirror / "cka" / "old-scenario" / "index.json").exists()
    assert git(mirror, "status", "--porcelain") == ""


def test_publish_adds_keeps_what_was_not_reproven_and_is_idempotent(tmp_path, mirror):
    build = tmp_path / "build"
    scenario(build, "cka", "new-scenario")
    (build / "README.md").write_text("generated readme must not overwrite the hand-written one")
    assert publish(build, mirror).returncode == 0
    assert (mirror / "cka" / "new-scenario" / "index.json").exists()
    assert (mirror / "cka" / "old-scenario" / "index.json").exists()      # not re-proven this time: kept, never deleted
    assert (mirror / "README.md").read_text() == "hand written"
    head = git(mirror, "rev-parse", "HEAD")
    r = publish(build, mirror)
    assert r.returncode == 0 and "up to date" in r.stdout and git(mirror, "rev-parse", "HEAD") == head   # no diff, no commit
