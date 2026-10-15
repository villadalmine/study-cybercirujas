"""End-to-end with Docker (marked slow): run, break, verify FAIL -> fix -> PASS, run x2 idempotent,
--from a git repo, and down without leftovers (containers, volumes, networks).

    make test-e2e                                  linux family (~1 min)
    STUDY_LAB_E2E_K8S=1 make test-e2e              also the kind family (~2 min, ~1 GB RAM)
"""
import os
import subprocess

import pytest

from conftest import git_repo, image_ok, needs_docker, run_cli
from teach.lab import cli, runner

pytestmark = [pytest.mark.slow, needs_docker]


def docker_set(*args):
    out = subprocess.run(["docker", *args], capture_output=True, text=True).stdout
    return set(out.split())


def snapshot():
    return {"containers": docker_set("ps", "-aq", "--filter", "label=study-lab=1"),
            "volumes": docker_set("volume", "ls", "-q"),
            "networks": docker_set("network", "ls", "-q")}


def flow(target, from_repo, fix_cmd):
    lab = cli.resolve(target, from_repo)
    args = lab.cli_args
    name = runner.container_name(lab)
    own_volumes: set = set()
    try:
        assert run_cli("run", *args) == 0                       # run + break
        cid = docker_set("ps", "-q", "--filter", f"name=^{name}$")
        assert len(cid) == 1
        # The lab's own anonymous volumes, by identity: comparing global
        # snapshots failed whenever anything else on the host (another kind
        # cluster, another test) created a volume during the run.
        mounts = subprocess.run(["docker", "inspect", "-f",
                                 '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}', name],
                                capture_output=True, text=True).stdout.split()
        own_volumes = set(mounts) - {runner.CACHE_VOLUME}
        assert run_cli("run", *args) == 0                       # idempotent: same container, still broken
        assert docker_set("ps", "-q", "--filter", f"name=^{name}$") == cid
        assert run_cli("check", *args) == 1                     # broken -> verify fails
        assert run_cli("exec", *args, "--", *fix_cmd) == 0      # the student's fix
        assert run_cli("check", *args) == 0                     # fixed -> verify passes
    finally:
        assert run_cli("down", *args) == 0                      # cleanup + remove
    after = snapshot()
    assert after["containers"] == set()
    leftover = own_volumes & after["volumes"]
    assert leftover == set(), f"leftover volumes of the lab: {leftover}"
    assert not any(name in n for n in docker_set("network", "ls", "--format", "{{.Name}}"))
    assert run_cli("down", *args) == 0                          # down twice: no-op


@pytest.mark.skipif(not image_ok("study-lab:linux"), reason="build it first: study-lab build linux")
def test_linux_lab_from_template(new_lab):
    d = new_lab(requires="linux", name="e2e-linux", cert="e2e", topic="1")
    flow([str(d)], None, ["chmod", "644", "/srv/lab-e2e-1/app.conf"])


@pytest.mark.skipif(not image_ok("study-lab:linux"), reason="build it first: study-lab build linux")
def test_linux_lab_from_git_repo(new_lab, tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "CACHE", tmp_path / "cache")
    new_lab(requires="linux", name="repo/labs/e2e", cert="e2e", topic="2")
    repo = git_repo(tmp_path / "repo")
    flow(["labs/e2e"], f"file://{repo}", ["chmod", "644", "/srv/lab-e2e-2/app.conf"])


@pytest.mark.skipif(os.environ.get("STUDY_LAB_E2E_K8S") != "1" or not image_ok("study-lab:k8s"),
                    reason="set STUDY_LAB_E2E_K8S=1 (and build study-lab:k8s) for the kind e2e")
def test_kind_lab_from_template(new_lab):
    d = new_lab(requires="kind", name="e2e-kind", cert="e2e", topic="3")
    flow([str(d)], None, ["kubectl", "-n", "lab-e2e-3", "set", "image", "deploy/web", "busybox=busybox:1.37"])
