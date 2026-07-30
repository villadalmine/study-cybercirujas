"""Lab execution — v1 using local subprocesses.

Two providers:
  terraform  Lab IaC under certs/<cert>/<topic>/lab/terraform/ (BYO-cloud, see
             the SDD section of PLAN.md) — not used by any generated lab yet,
             it is the roadmap's "step 3" mode.
  local      Docker on the student's machine (free, the roadmap's "step 1") —
             what generate_topic() writes into EVERY lab.yaml today. Two
             variants depending on what break_fix.sh needs:
             - if it uses kubectl (CKA/CKAD/CKS/KCNA): boots a kind cluster
               (Kubernetes-in-Docker) and runs the script against it.
             - if not (LPI Linux Essentials): runs the script inside a plain
               Debian/Ubuntu container as a non-root user (the scripts refuse
               to run as root).

Contract with the future lab-runner (Go):
  certs/<cert>/<topic>/lab/lab.yaml     declarative spec (what the lab needs)
  certs/<cert>/<topic>/lab/terraform/   optional lab IaC
  certs/<cert>/<topic>/lab/status.yaml  status written by whoever executes

Once the runner exists, this module stops executing terraform/docker/kind and
only reads and writes the contract.
"""

import datetime
import shutil
import subprocess
from pathlib import Path

import yaml

from . import certs


class LabError(Exception):
    pass


def lab_dir(cert_id: str, topic_id: str) -> Path:
    return certs.content_dir(cert_id, topic_id) / "lab"


def _write_status(directory: Path, state: str, detail: str = "") -> dict:
    status = {
        "state": state,  # running | destroyed | failed
        "detail": detail,
        "updated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    (directory / "status.yaml").write_text(yaml.safe_dump(status, sort_keys=False))
    return status


def _load_spec(directory: Path) -> dict:
    spec_file = directory / "lab.yaml"
    if not spec_file.exists():
        raise LabError(f"No lab spec in {directory}. Run: teach cert generate")
    return yaml.safe_load(spec_file.read_text()) or {}


# ----------------------------------------------------------- terraform provider

def _terraform(directory: Path, *args: str) -> None:
    tf_dir = directory / "terraform"
    if not tf_dir.is_dir():
        raise LabError(
            f"This lab has no terraform yet ({tf_dir}). "
            "Generate the content first and define the topic's infrastructure."
        )
    result = subprocess.run(
        ["terraform", *args], cwd=tf_dir, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise LabError(f"terraform {args[0]} failed:\n{result.stderr.strip()}")


# --------------------------------------------------------- local provider (Docker)

OS_IMAGES = {
    "debian-12": "debian:12",
    "debian-11": "debian:11",
    "ubuntu-22.04": "ubuntu:22.04",
    "ubuntu-24.04": "ubuntu:24.04",
}


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def _require(binary: str, install_hint: str) -> None:
    if shutil.which(binary) is None:
        raise LabError(f"'{binary}' is not installed — {install_hint}")


def _lab_name(cert_id: str, topic_id: str) -> str:
    return f"teach-{cert_id}-{topic_id}".replace(".", "-").replace("_", "-")


def _needs_cluster(directory: Path) -> bool:
    """CKA/CKAD/CKS/KCNA labs run against a real Kubernetes cluster (kubectl);
    LPI Linux Essentials ones do not. This is detected by reading break_fix.sh
    itself rather than a separate field in lab.yaml, so the 100+ existing
    lab.yaml files do not have to be regenerated."""
    script = directory / "break_fix.sh"
    return script.exists() and "kubectl" in script.read_text()


def _up_container(directory: Path, spec: dict, name: str) -> None:
    _require("docker", "install Docker to run labs locally (https://docs.docker.com/get-docker/)")
    vm = ((spec.get("resources") or {}).get("vms") or [{}])[0]
    image = OS_IMAGES.get(vm.get("os"), "debian:12")
    cpus = str(vm.get("cpus", 1))
    ram = f"{vm.get('ram_mb', 1024)}m"
    result = _run([
        "docker", "run", "-d", "--name", name,
        "--cpus", cpus, "--memory", ram,
        image, "sleep", "infinity",
    ])
    if result.returncode != 0:
        raise LabError(f"docker run failed:\n{result.stderr.strip()}")
    # The LPI break_fix.sh scripts refuse to run as root, for the same reason
    # as on a real VM: exercise the scenario as an ordinary user would see it.
    _run(["docker", "exec", name, "useradd", "-m", "student"])
    script = directory / "break_fix.sh"
    _run(["docker", "cp", str(script), f"{name}:/home/student/break_fix.sh"])
    result = subprocess.run(
        ["docker", "exec", "-u", "student", "-w", "/home/student", name, "bash", "break_fix.sh"]
    )
    if result.returncode != 0:
        raise LabError("break_fix.sh failed inside the container (see output above).")


def _down_container(name: str) -> None:
    _run(["docker", "rm", "-f", name])


def _status_container(name: str) -> dict:
    result = _run(["docker", "inspect", "-f", "{{.State.Status}}", name])
    return {"running": result.returncode == 0 and result.stdout.strip() == "running"}


def _up_cluster(directory: Path, name: str) -> None:
    _require("kind", "install kind, Kubernetes-in-Docker (https://kind.sigs.k8s.io/)")
    _require("kubectl", "install kubectl")
    result = _run(["kind", "create", "cluster", "--name", name])
    if result.returncode != 0:
        raise LabError(f"kind create cluster failed:\n{result.stderr.strip()}")
    _run(["kubectl", "config", "use-context", f"kind-{name}"])
    script = directory / "break_fix.sh"
    result = subprocess.run(["bash", str(script)], cwd=directory)
    if result.returncode != 0:
        raise LabError("break_fix.sh failed against the kind cluster (see output above).")


def _down_cluster(name: str) -> None:
    _run(["kind", "delete", "cluster", "--name", name])


def _status_cluster(name: str) -> dict:
    result = _run(["kind", "get", "clusters"])
    running = result.returncode == 0 and name in result.stdout.split()
    return {"running": running}


# ----------------------------------------------------------------- public API

def up(cert_id: str, topic_id: str) -> dict:
    directory = lab_dir(cert_id, topic_id)
    spec = _load_spec(directory)
    provider = spec.get("provider", "terraform")
    try:
        if provider == "local":
            name = _lab_name(cert_id, topic_id)
            if _needs_cluster(directory):
                _up_cluster(directory, name)
            else:
                _up_container(directory, spec, name)
        else:
            _terraform(directory, "init", "-input=false")
            _terraform(directory, "apply", "-auto-approve", "-input=false")
    except LabError as error:
        _write_status(directory, "failed", str(error))
        raise
    return _write_status(directory, "running")


def down(cert_id: str, topic_id: str) -> dict:
    directory = lab_dir(cert_id, topic_id)
    spec = _load_spec(directory)
    provider = spec.get("provider", "terraform")
    try:
        if provider == "local":
            name = _lab_name(cert_id, topic_id)
            if _needs_cluster(directory):
                _down_cluster(name)
            else:
                _down_container(name)
        else:
            _terraform(directory, "destroy", "-auto-approve", "-input=false")
    except LabError as error:
        _write_status(directory, "failed", str(error))
        raise
    return _write_status(directory, "destroyed")


def status(cert_id: str, topic_id: str) -> dict:
    directory = lab_dir(cert_id, topic_id)
    status_file = directory / "status.yaml"
    if not status_file.exists():
        return {"state": "none"}
    cached = yaml.safe_load(status_file.read_text())
    # For the local provider, check the real docker/kind state rather than
    # blindly trusting the last status.yaml written: the container or cluster
    # may have died or been deleted by hand since the last run.
    if cached.get("state") == "running" and (directory / "lab.yaml").exists():
        spec = yaml.safe_load((directory / "lab.yaml").read_text()) or {}
        if spec.get("provider") == "local":
            name = _lab_name(cert_id, topic_id)
            live = _status_cluster(name) if _needs_cluster(directory) else _status_container(name)
            if not live["running"]:
                cached = _write_status(directory, "failed", "container/cluster not found (deleted by hand?)")
    return cached
