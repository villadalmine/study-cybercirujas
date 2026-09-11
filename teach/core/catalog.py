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


class _BlockDumper(yaml.SafeDumper):
    """PyYAML, but sequences stay indented under their key.

    The default dedents every list item, so a file written by hand and rewritten
    by a script comes back as a whole-file diff over a one-word change. Two
    scripts now rewrite models.yaml — `check_models.py --update` (prices) and
    `probe_models.py --update` (what each model actually did) — and without a
    shared writer they would reformat the file against each other on every run.
    """

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def models_path() -> Path:
    """The study bot's model catalogue."""
    return root() / "models.yaml"


def load_models(path: Path | None = None) -> dict:
    path = path or models_path()
    if not path.exists():
        return {"checked": None, "tiers": {}}
    return yaml.safe_load(path.read_text()) or {"checked": None, "tiers": {}}


def save_models(data: dict, path: Path | None = None) -> None:
    """Rewrite models.yaml, keeping the header comments above it.

    Those comments are the selection criteria — why the list is curated, what
    disqualifies a model — and a rewrite that dropped them would delete the only
    record of how the list was chosen.
    """
    path = path or models_path()
    head = ""
    if path.exists():
        head = "\n".join(line for line in path.read_text().splitlines()
                         if line.startswith("#"))
    body = yaml.dump(data, Dumper=_BlockDumper, sort_keys=False,
                     allow_unicode=True, default_flow_style=False)
    path.write_text((head + "\n\n" if head else "") + body)


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
