"""Lectura/escritura del MD por certificación (snapshot del temario + estado).

El MD con frontmatter es la fuente de verdad del curso. El contenido generado
de cada tema vive en certs/<cert_id>/<topic_id>/.
"""

from pathlib import Path

import frontmatter

from . import catalog

VALID_STATUS = {"pending", "generated", "edited", "stale"}

TEMPLATE = """\
---
cert: {cert_id}
exam: "{exam}"
version: unknown
snapshot_date: null
sources: []
topics: []
---

# {name}

Snapshot del temario. Completar `topics` con id, title, weight, status y sources
(ver certs/lpi-010-160.md como referencia) y correr `teach cert generate {cert_id}`.
"""


def md_path(cert_id: str) -> Path:
    return catalog.root() / "certs" / f"{cert_id}.md"


def content_dir(cert_id: str, topic_id: str) -> Path:
    return catalog.root() / "certs" / cert_id / topic_id


def load(cert_id: str) -> frontmatter.Post:
    path = md_path(cert_id)
    if not path.exists():
        raise FileNotFoundError(f"No existe {path}. Crear con: teach cert add {cert_id}")
    return frontmatter.load(path)


def save(cert_id: str, post: frontmatter.Post) -> None:
    md_path(cert_id).write_text(frontmatter.dumps(post) + "\n")


def topics(cert_id: str) -> list[dict]:
    return load(cert_id).metadata.get("topics", [])


def get_topic(cert_id: str, topic_id: str) -> dict:
    for topic in topics(cert_id):
        if str(topic.get("id")) == topic_id:
            return topic
    raise KeyError(f"Tema '{topic_id}' no existe en {cert_id}")


def set_topic_status(cert_id: str, topic_id: str, status: str) -> None:
    if status not in VALID_STATUS:
        raise ValueError(f"Status inválido: {status}. Válidos: {VALID_STATUS}")
    post = load(cert_id)
    for topic in post.metadata.get("topics", []):
        if str(topic.get("id")) == topic_id:
            topic["status"] = status
            save(cert_id, post)
            return
    raise KeyError(f"Tema '{topic_id}' no existe en {cert_id}")


def scaffold(cert_id: str, name: str, exam: str) -> Path:
    """Crea el MD template de una cert nueva. El temario se completa a mano
    (TODO: auto-scrape de objetivos por proveedor, ej. patrón de URLs de LPI)."""
    path = md_path(cert_id)
    if path.exists():
        raise FileExistsError(f"{path} ya existe")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(TEMPLATE.format(cert_id=cert_id, exam=exam, name=name))
    return path


def topic_content(cert_id: str, topic_id: str) -> dict:
    """Contenido generado de un tema (None donde falta)."""
    directory = content_dir(cert_id, topic_id)

    def read(name: str) -> str | None:
        f = directory / name
        return f.read_text() if f.exists() else None

    return {
        "content": read("content.md"),
        "exercises": read("exercises.md"),
        "break_fix": read("lab/break_fix.sh"),
        "lab_spec": read("lab/lab.yaml"),
    }
