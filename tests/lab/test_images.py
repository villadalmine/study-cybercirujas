"""Static guards on the runner images and the CI that builds them (no Docker needed)."""
import json
import re
from collections import Counter
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]


def _cmd(dockerfile: Path) -> list[str]:
    cmds = re.findall(r"^CMD\s+(\[.*\])\s*$", dockerfile.read_text(encoding="utf-8"), re.M)
    assert cmds, f"{dockerfile} has no exec-form CMD"
    return json.loads(cmds[-1])


def test_k8s_inner_dockerd_listens_on_the_unix_socket_only():
    # docker:dind's entrypoint adds --host=tcp://0.0.0.0:2375 (no TLS, since
    # DOCKER_TLS_CERTDIR is empty) unless the command is `dockerd` with its own
    # --host. That TCP listener is root on the host for any neighbour container.
    cmd = _cmd(REPO / "deploy" / "study-lab" / "k8s" / "Dockerfile")
    assert cmd[0] == "dockerd"
    hosts = [a.split("=", 1)[1] for a in cmd if a.startswith("--host=")]
    assert hosts == ["unix:///var/run/docker.sock"]
    assert not any("tcp://" in a for a in cmd)


def test_job_ids_are_unique_across_workflows():
    # Check runs are shown and required by job id; two `e2e` jobs (labs.yml and
    # verify.yml) are indistinguishable in the PR and in branch protection.
    ids = Counter()
    for wf in sorted((REPO / ".github" / "workflows").glob("*.y*ml")):
        ids.update(list((yaml.safe_load(wf.read_text(encoding="utf-8")) or {}).get("jobs") or {}))
    assert [j for j, n in ids.items() if n > 1] == []


def test_runner_base_images_are_pinned_by_digest():
    for fam in ("k8s", "linux"):
        text = (REPO / "deploy" / "study-lab" / fam / "Dockerfile").read_text(encoding="utf-8")
        froms = re.findall(r"^FROM\s+(\S+)", text, re.M)
        assert froms and all(re.search(r"@sha256:[0-9a-f]{64}$", f) for f in froms), (fam, froms)


def test_ensure_image_builds_locally_and_never_pulls(monkeypatch):
    from teach.lab import runner

    calls = []

    class R:
        def __init__(self, rc):
            self.returncode = rc

    def fake(*args, **kw):
        calls.append(args)
        return R(1 if args[:2] == ("image", "inspect") else 0)

    monkeypatch.setattr(runner, "_docker", fake)
    monkeypatch.setattr(runner, "build", lambda fam: calls.append(("build", fam)))

    class L:
        spec = {"requires": "linux"}

    runner.ensure_image(L())
    assert ("build", "linux") in calls
    assert not any(c and c[0] == "pull" for c in calls)
