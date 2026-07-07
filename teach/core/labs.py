"""Ejecución de labs — v1 con subprocess local.

Contrato con el futuro lab-runner (Go):
  certs/<cert>/<topic>/lab/lab.yaml     spec declarativo (qué necesita el lab)
  certs/<cert>/<topic>/lab/terraform/   IaC opcional del lab
  certs/<cert>/<topic>/lab/status.yaml  estado escrito por quien ejecuta

Cuando exista el runner, este módulo deja de ejecutar terraform y pasa a
solo leer/escribir el contrato.
"""

import datetime
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


def up(cert_id: str, topic_id: str) -> dict:
    directory = lab_dir(cert_id, topic_id)
    if not (directory / "lab.yaml").exists():
        raise LabError(f"No hay lab spec en {directory}. Correr: teach cert generate")
    try:
        _terraform(directory, "init", "-input=false")
        _terraform(directory, "apply", "-auto-approve", "-input=false")
    except LabError as error:
        _write_status(directory, "failed", str(error))
        raise
    return _write_status(directory, "running")


def down(cert_id: str, topic_id: str) -> dict:
    directory = lab_dir(cert_id, topic_id)
    try:
        _terraform(directory, "destroy", "-auto-approve", "-input=false")
    except LabError as error:
        _write_status(directory, "failed", str(error))
        raise
    return _write_status(directory, "destroyed")


def status(cert_id: str, topic_id: str) -> dict:
    status_file = lab_dir(cert_id, topic_id) / "status.yaml"
    if not status_file.exists():
        return {"state": "none"}
    return yaml.safe_load(status_file.read_text())
