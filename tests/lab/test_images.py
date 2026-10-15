"""Static guards on the runner images (no Docker needed)."""
import json
import re
from pathlib import Path

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
