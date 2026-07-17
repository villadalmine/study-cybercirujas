"""Ejecución de labs — v1 con subprocess local.

Dos providers:
  terraform  IaC del lab en certs/<cert>/<topic>/lab/terraform/ (BYO-cloud,
             ver PLAN.MD sección SDD) — no usado por ningún lab generado
             todavía, es el modo "paso 3" del roadmap.
  local      Docker en la máquina del estudiante (gratis, "paso 1" del
             roadmap) — el que generate_topic() pone hoy en TODOS los
             lab.yaml. Dos variantes según lo que el break_fix.sh necesite:
             - si usa kubectl (CKA/CKAD/CKS/KCNA): levanta un cluster kind
               (Kubernetes-in-Docker) y corre el script contra él.
             - si no (LPI Linux Essentials): corre el script dentro de un
               container Debian/Ubuntu simple, como usuario no-root (los
               scripts rechazan correr como root).

Contrato con el futuro lab-runner (Go):
  certs/<cert>/<topic>/lab/lab.yaml     spec declarativo (qué necesita el lab)
  certs/<cert>/<topic>/lab/terraform/   IaC opcional del lab
  certs/<cert>/<topic>/lab/status.yaml  estado escrito por quien ejecuta

Cuando exista el runner, este módulo deja de ejecutar terraform/docker/kind
y pasa a solo leer/escribir el contrato.
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
        raise LabError(f"No hay lab spec en {directory}. Correr: teach cert generate")
    return yaml.safe_load(spec_file.read_text()) or {}


# --------------------------------------------------------------- provider terraform

def _terraform(directory: Path, *args: str) -> None:
    tf_dir = directory / "terraform"
    if not tf_dir.is_dir():
        raise LabError(
            f"El lab no tiene terraform todavía ({tf_dir}). "
            "Generar el contenido primero y definir la infra del tema."
        )
    result = subprocess.run(
        ["terraform", *args], cwd=tf_dir, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise LabError(f"terraform {args[0]} falló:\n{result.stderr.strip()}")


# --------------------------------------------------------------- provider local (Docker)

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
        raise LabError(f"'{binary}' no está instalado — {install_hint}")


def _lab_name(cert_id: str, topic_id: str) -> str:
    return f"teach-{cert_id}-{topic_id}".replace(".", "-").replace("_", "-")


def _needs_cluster(directory: Path) -> bool:
    """Los labs de CKA/CKAD/CKS/KCNA corren contra un cluster de Kubernetes
    real (kubectl); los de LPI Linux Essentials no. Se detecta leyendo el
    propio break_fix.sh en vez de un campo separado en lab.yaml, para no
    tener que regenerar los 100+ lab.yaml ya existentes."""
    script = directory / "break_fix.sh"
    return script.exists() and "kubectl" in script.read_text()


def _up_container(directory: Path, spec: dict, name: str) -> None:
    _require("docker", "instalar Docker para correr labs localmente (https://docs.docker.com/get-docker/)")
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
        raise LabError(f"docker run falló:\n{result.stderr.strip()}")
    # los break_fix.sh de LPI rechazan correr como root (misma razón que en
    # una VM real: probar el escenario tal como lo vería un usuario normal)
    _run(["docker", "exec", name, "useradd", "-m", "student"])
    script = directory / "break_fix.sh"
    _run(["docker", "cp", str(script), f"{name}:/home/student/break_fix.sh"])
    result = subprocess.run(
        ["docker", "exec", "-u", "student", "-w", "/home/student", name, "bash", "break_fix.sh"]
    )
    if result.returncode != 0:
        raise LabError("break_fix.sh falló dentro del container (ver salida arriba).")


def _down_container(name: str) -> None:
    _run(["docker", "rm", "-f", name])


def _status_container(name: str) -> dict:
    result = _run(["docker", "inspect", "-f", "{{.State.Status}}", name])
    return {"running": result.returncode == 0 and result.stdout.strip() == "running"}


def _up_cluster(directory: Path, name: str) -> None:
    _require("kind", "instalar kind, Kubernetes-in-Docker (https://kind.sigs.k8s.io/)")
    _require("kubectl", "instalar kubectl")
    result = _run(["kind", "create", "cluster", "--name", name])
    if result.returncode != 0:
        raise LabError(f"kind create cluster falló:\n{result.stderr.strip()}")
    _run(["kubectl", "config", "use-context", f"kind-{name}"])
    script = directory / "break_fix.sh"
    result = subprocess.run(["bash", str(script)], cwd=directory)
    if result.returncode != 0:
        raise LabError("break_fix.sh falló contra el cluster kind (ver salida arriba).")


def _down_cluster(name: str) -> None:
    _run(["kind", "delete", "cluster", "--name", name])


def _status_cluster(name: str) -> dict:
    result = _run(["kind", "get", "clusters"])
    running = result.returncode == 0 and name in result.stdout.split()
    return {"running": running}


# --------------------------------------------------------------- API pública

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
    # para el provider local, chequear el estado real de docker/kind en vez
    # de confiar ciegamente en el último status.yaml escrito (el container/
    # cluster puede haberse caído o borrado a mano desde la última corrida)
    if cached.get("state") == "running" and (directory / "lab.yaml").exists():
        spec = yaml.safe_load((directory / "lab.yaml").read_text()) or {}
        if spec.get("provider") == "local":
            name = _lab_name(cert_id, topic_id)
            live = _status_cluster(name) if _needs_cluster(directory) else _status_container(name)
            if not live["running"]:
                cached = _write_status(directory, "failed", "container/cluster no encontrado (¿se borró a mano?)")
    return cached
