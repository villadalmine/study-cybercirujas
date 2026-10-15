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
import os
import re
import shutil
import subprocess
import sys
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
    (directory / "status.yaml").write_text(yaml.safe_dump(status, sort_keys=False), encoding="utf-8")
    return status


def _load_spec(directory: Path) -> dict:
    spec_file = directory / "lab.yaml"
    if not spec_file.exists():
        raise LabError(f"No lab spec in {directory}. Run: teach cert generate")
    return yaml.safe_load(spec_file.read_text(encoding="utf-8")) or {}


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
    return script.exists() and "kubectl" in script.read_text(encoding="utf-8")


def _up_container(directory: Path, spec: dict, name: str) -> None:
    _require("docker", "install Docker to run labs locally (https://docs.docker.com/get-docker/)")
    vm = ((spec.get("resources") or {}).get("vms") or [{}])[0]
    image = OS_IMAGES.get(vm.get("os"), "debian:12")
    cpus = str(vm.get("cpus", 1))
    ram = f"{vm.get('ram_mb', 1024)}m"
    result = _run([
        "docker", "run", "-d", "--name", name,
        "--cpus", cpus, "--memory", ram,
        *_owner_label(),
        image, "sleep", "infinity",
    ])
    if result.returncode != 0:
        raise LabError(f"docker run failed:\n{result.stderr.strip()}")
    # The LPI break_fix.sh scripts refuse to run as root, for the same reason
    # as on a real VM: exercise the scenario as an ordinary user would see it.
    _run(["docker", "exec", name, "useradd", "-m", "student"])
    script = directory / "break_fix.sh"
    _run(["docker", "cp", str(script), f"{name}:/home/student/break_fix.sh"])
    user = _script_user(directory)
    result = subprocess.run(_exec_script_cmd(name, interactive=sys.stdin.isatty(), user=user,
                                             args=_break_args(directory)))
    if result.returncode != 0:
        raise LabError("break_fix.sh failed inside the container (see output above).")


# The guard each script carries at its top, read as code rather than prose:
# `[ "$(id -u)" -ne 0 ] && die` / `[ $EUID -eq 0 ] || die` require root;
# `[ "$(id -u)" -eq 0 ]; then refuse` refuses it.
_UID = r'(\$\{?EUID\}?|\$\(id -u\))"?'
REQUIRES_ROOT = re.compile(_UID + r'\s*(-ne|!=)\s*"?0"?|' + _UID + r'\s*-eq\s*0\s*\]\]?\s*\|\|')
REFUSES_ROOT = re.compile(_UID + r'\s*-eq\s*0\s*\]\]?\s*(;\s*then|&&)|'
                          + _UID + r'\s*(-ne|!=)\s*"?0"?\s*\]\]?\s*\|\|')
RUN_AS = ("root", "student")


def _script_user(directory: Path) -> str:
    """Who runs break_fix.sh inside the container.

    Two families want opposite things: Linux Essentials scripts refuse root
    (the scenario is an ordinary user's shell), LPIC-1/2/3 scripts manage
    accounts and system paths and refuse anything but root. Running all of
    them as `student` made ~140 labs die on their first line (found
    2026-10-15 with lpic-1 104.5). `run_as:` in lab.yaml decides when present;
    otherwise the script's own guard does, and an ambiguous or absent guard
    means `student`, the safer default.
    """
    spec_file = directory / "lab.yaml"
    if spec_file.exists():
        spec = yaml.safe_load(spec_file.read_text(encoding="utf-8")) or {}
        if spec.get("run_as") in RUN_AS:
            return spec["run_as"]
    script = directory / "break_fix.sh"
    text = script.read_text(encoding="utf-8", errors="replace") if script.exists() else ""
    if REQUIRES_ROOT.search(text) and not REFUSES_ROOT.search(text):
        return "root"
    return "student"


BREAK_CASE = re.compile(r'^[ \t]*"?break"?[ \t]*\)', re.MULTILINE)


def _break_args(directory: Path) -> list[str]:
    """The argument that makes break_fix.sh break, for scripts that need one.

    About a third of the scripts are subcommand style (`case "$1" in break) ...
    verify) ... cleanup)`) and, run without an argument, print their usage and
    exit 0 — so `teach lab up` reported a running lab with nothing broken
    (found with kcna 2.2 on 2026-10-15). Scripts that break by default
    (`--break` is optional, or there are no subcommands) get no argument.
    """
    script = directory / "break_fix.sh"
    text = script.read_text(encoding="utf-8", errors="replace") if script.exists() else ""
    return ["break"] if BREAK_CASE.search(text) else []


def _exec_script_cmd(name: str, interactive: bool, user: str = "student",
                     args: list[str] | None = None) -> list[str]:
    """`docker exec` for break_fix.sh, with the student's stdin attached.

    Most scripts ask for a confirmation first (`read -r -p "... (type SI)"`),
    and without `-i` the `read` hits EOF, the script prints "Cancelled" and
    exits 0 — so `teach lab up` reported a running lab in which nothing had
    been broken. `-t` only when there is a terminal: docker refuses `-t` with a
    piped stdin ("the input device is not a TTY").
    """
    flags = ["-i", "-t"] if interactive else ["-i"]
    return ["docker", "exec", *flags, "-u", user, "-w", "/home/student",
            name, "bash", "break_fix.sh", *(args or [])]


OWNER_LABEL = "org.cybercirujas.study.owner"


def _owner_label() -> list[str]:
    """`--label` that stamps who created the container, when that is known.

    TEACH_LAB_OWNER is an ownership token: a container is created carrying it
    (atomically, by `docker run`), and `lab down` with the same token removes
    only containers that carry it. Lab names are fixed (teach-<cert>-<topic>),
    so without a token a test or script could delete someone else's lab that
    happens to hold the name. Unset, nothing changes for a student.
    """
    owner = os.environ.get("TEACH_LAB_OWNER")
    return ["--label", f"{OWNER_LABEL}={owner}"] if owner else []


def _down_container(name: str) -> None:
    owner = os.environ.get("TEACH_LAB_OWNER")
    if not owner:
        _run(["docker", "rm", "-f", name])
        return
    # Resolve the name to IDs that carry this owner's label, and remove by ID:
    # a container with the same name but another owner (or none) is left alone.
    found = _run(["docker", "ps", "-aq", "--no-trunc",
                  "--filter", f"name=^/{name}$",
                  "--filter", f"label={OWNER_LABEL}={owner}"])
    for container_id in found.stdout.split():
        _run(["docker", "rm", "-f", container_id])


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
    result = subprocess.run(["bash", str(script), *_break_args(directory)], cwd=directory)
    if result.returncode != 0:
        raise LabError("break_fix.sh failed against the kind cluster (see output above).")


def _down_cluster(name: str) -> None:
    _run(["kind", "delete", "cluster", "--name", name])


def _status_cluster(name: str) -> dict:
    result = _run(["kind", "get", "clusters"])
    running = result.returncode == 0 and name in result.stdout.split()
    return {"running": running}


# ------------------------------------------------- the lab contract, checkable

REQUIRED_KEYS = ("cert", "topic", "title", "provider", "resources", "setup")
PROVIDERS = ("local", "terraform")


def default_spec(cert_id: str, topic_id: str, title: str) -> dict:
    """The lab.yaml every topic starts from — one definition, used by the AI
    generator and by `teach lab new`, so a lab written by hand and one written
    by a model are held to the same contract."""
    return {
        "cert": cert_id,
        "topic": topic_id,
        "title": title,
        "provider": "local",
        "resources": {"vms": [{"name": "lab", "os": "debian-12", "cpus": 1, "ram_mb": 1024}]},
        "setup": ["break_fix.sh"],
    }


BREAK_FIX_TEMPLATE = """#!/usr/bin/env bash
# {cert} {topic} — {title}
# BREAK & FIX lab. Runs inside a throwaway container (`teach lab up {cert} {topic}`),
# never on your own machine.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as an ordinary user inside the lab container, not as root." >&2
    exit 1
fi

echo "This lab breaks something on purpose. Only in a disposable lab."
read -r -p "Type LAB to continue: " answer
[ "$answer" = "LAB" ] || {{ echo "Cancelled. Nothing changed."; exit 0; }}

# --- BREAK -------------------------------------------------------------------
# TODO: break one thing, reversibly, that the topic teaches how to diagnose.

# --- SYMPTOM -----------------------------------------------------------------
echo "Symptom: TODO — what the student will see, and what 'fixed' looks like."

# --- SOLUTION (commented) ----------------------------------------------------
# TODO: the fix, step by step.
"""


def validate_spec(directory: Path) -> list[str]:
    """Problems with a lab directory, [] when it honours the contract.

    Deterministic and offline: reads files, and syntax-checks break_fix.sh with
    `bash -n` (parses, never executes) when bash is available.
    """
    problems: list[str] = []
    spec_file = directory / "lab.yaml"
    if not spec_file.exists():
        return [f"{spec_file}: missing"]
    try:
        spec = yaml.safe_load(spec_file.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as error:
        return [f"{spec_file}: not valid YAML ({error})"]
    if not isinstance(spec, dict):
        return [f"{spec_file}: not a mapping"]
    # Every nested value is type-checked before it is used, so a malformed lab
    # is reported rather than aborting `lab validate --all` with a traceback.
    # Extra keys are allowed on purpose: the lab.yaml v2 of the study-lab
    # runner (schema_version, modes, hints, ...) is a superset of this one.
    problems += [f"{spec_file}: missing key '{k}'" for k in REQUIRED_KEYS if k not in spec]
    if "run_as" in spec and spec["run_as"] not in RUN_AS:
        problems.append(f"{spec_file}: run_as {spec['run_as']!r} not in {RUN_AS}")
    provider = spec.get("provider")
    if provider not in PROVIDERS:
        problems.append(f"{spec_file}: provider {provider!r} not in {PROVIDERS}")
    resources = spec.get("resources")
    if "resources" in spec and not isinstance(resources, dict):
        problems.append(f"{spec_file}: resources must be a mapping")
        resources = {}
    setup = spec.get("setup")
    if "setup" in spec and not (isinstance(setup, list) and all(isinstance(s, str) for s in setup)):
        problems.append(f"{spec_file}: setup must be a list of file names")
        setup = []
    setup = setup or []
    if provider == "local":
        vms = (resources or {}).get("vms")
        if not isinstance(vms, list) or not vms:
            problems.append(f"{spec_file}: local provider needs a non-empty resources.vms list")
            vms = []
        for vm in vms:
            if not isinstance(vm, dict):
                problems.append(f"{spec_file}: each resources.vms entry must be a mapping")
            elif not isinstance(vm.get("os"), str) or vm["os"] not in OS_IMAGES:
                # isinstance first: a list or mapping is unhashable and the
                # membership test would raise instead of reporting.
                problems.append(f"{spec_file}: os {vm.get('os')!r} not in {sorted(OS_IMAGES)}")
        # The local provider always runs break_fix.sh (_up_container,
        # _up_cluster); a lab that does not declare it cannot be run.
        if "break_fix.sh" not in setup:
            problems.append(f"{spec_file}: local provider needs break_fix.sh in setup")
    for step in setup:
        script = directory / step
        if not script.exists():
            problems.append(f"{spec_file}: setup step {step} does not exist")
        elif script.suffix == ".sh" and shutil.which("bash"):
            result = _run(["bash", "-n", str(script)])
            if result.returncode != 0:
                problems.append(f"{script}: bash -n failed: {result.stderr.strip()}")
    return problems


def scaffold(cert_id: str, topic_id: str, force: bool = False) -> Path:
    """Write a lab from the template, no model involved. Returns its directory."""
    topic = certs.get_topic(cert_id, topic_id)
    directory = lab_dir(cert_id, topic_id)
    # Either file is someone's work: a hand-written break_fix.sh, or one left
    # by an interrupted generation (generator.py writes the script before
    # lab.yaml). Neither is replaced by the TODO template without --force.
    existing = [name for name in ("lab.yaml", "break_fix.sh") if (directory / name).exists()]
    if existing and not force:
        raise LabError(f"{directory} already has {', '.join(existing)} (use --force to overwrite)")
    directory.mkdir(parents=True, exist_ok=True)
    spec = default_spec(cert_id, str(topic_id), topic["title"])
    (directory / "lab.yaml").write_text(
        yaml.safe_dump(spec, sort_keys=False, allow_unicode=True), encoding="utf-8")
    (directory / "break_fix.sh").write_text(
        BREAK_FIX_TEMPLATE.format(cert=cert_id, topic=topic_id, title=topic["title"]),
        encoding="utf-8")
    return directory


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


def enter_hint(cert_id: str, topic_id: str) -> str | None:
    """The command that opens a shell in a running local lab, or None.

    `lab up` used to stop at "running" and leave the student to guess the
    container name and that the scenario lives in the `student` account.
    """
    directory = lab_dir(cert_id, topic_id)
    spec = _load_spec(directory)
    if spec.get("provider", "terraform") != "local":
        return None
    name = _lab_name(cert_id, topic_id)
    if _needs_cluster(directory):
        return f"kubectl config use-context kind-{name}"
    user = _script_user(directory)
    return f"docker exec -it -u {user} -w /home/student {name} bash"


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
    cached = yaml.safe_load(status_file.read_text(encoding="utf-8"))
    # For the local provider, check the real docker/kind state rather than
    # blindly trusting the last status.yaml written: the container or cluster
    # may have died or been deleted by hand since the last run.
    if cached.get("state") == "running" and (directory / "lab.yaml").exists():
        spec = yaml.safe_load((directory / "lab.yaml").read_text(encoding="utf-8")) or {}
        if spec.get("provider") == "local":
            name = _lab_name(cert_id, topic_id)
            live = _status_cluster(name) if _needs_cluster(directory) else _status_container(name)
            if not live["running"]:
                cached = _write_status(directory, "failed", "container/cluster not found (deleted by hand?)")
    return cached
