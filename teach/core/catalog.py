"""Global certification catalog (catalog.yaml).

Written by the tracker (and `cert add`); the generator and the web/CLI only
read it.
"""

import datetime
import os
from pathlib import Path

import yaml


def root() -> Path:
    """Root of the data repo. Override with TEACH_ROOT."""
    return Path(os.environ.get("TEACH_ROOT", Path.cwd()))


def catalog_path() -> Path:
    return root() / "catalog.yaml"


def load() -> dict:
    path = catalog_path()
    if not path.exists():
        return {"certs": {}}
    data = yaml.safe_load(path.read_text()) or {}
    data.setdefault("certs", {})
    return data


def save(data: dict) -> None:
    catalog_path().write_text(
        yaml.safe_dump(data, sort_keys=False, allow_unicode=True)
    )


def list_certs() -> dict:
    return load()["certs"]


def get_cert(cert_id: str) -> dict:
    certs = list_certs()
    if cert_id not in certs:
        raise KeyError(f"'{cert_id}' is not in the catalog. See: teach cert list")
    return certs[cert_id]


def add_cert(
    cert_id: str,
    name: str,
    exam: str,
    objectives_url: str = "",
    category: str = "general",
) -> dict:
    data = load()
    if cert_id in data["certs"]:
        raise ValueError(f"'{cert_id}' already exists in the catalog")
    entry = {
        "name": name,
        "exam": exam,
        "category": category,
        "tracked_version": "unknown",
        "upstream_status": "current",
        "last_checked": datetime.date.today().isoformat(),
        "file": f"certs/{cert_id}.md",
        "sources": {"objectives": objectives_url},
    }
    data["certs"][cert_id] = entry
    save(data)
    return entry
