"""Lectura/escritura del MD por certificación (snapshot del temario + estado).

El MD con frontmatter es la fuente de verdad del curso. El contenido generado
de cada tema vive en certs/<cert_id>/<topic_id>/.
"""

from pathlib import Path

import frontmatter

from . import catalog

VALID_STATUS = {"pending", "generated", "edited", "stale"}

# contenido por idioma: certs/<cert>/<topic>/<lang>/{content,exercises}.md
# el lab (spec/terraform/scripts) es compartido entre idiomas
LANGS = ["es", "en", "fr", "de", "zh", "ja", "pt"]
DEFAULT_LANG = "es"

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


def _read(path: Path) -> str | None:
    return path.read_text() if path.exists() else None


def topic_langs(cert_id: str, topic_id: str) -> list[str]:
    """Idiomas en los que existe contenido de un tema."""
    directory = content_dir(cert_id, topic_id)
    return [lang for lang in LANGS if (directory / lang / "content.md").exists()]


def topic_content(cert_id: str, topic_id: str, lang: str = DEFAULT_LANG) -> dict:
    """Contenido generado de un tema en un idioma (fallback al default)."""
    directory = content_dir(cert_id, topic_id)
    content = _read(directory / lang / "content.md")
    exercises = _read(directory / lang / "exercises.md")
    fallback = None
    if content is None and lang != DEFAULT_LANG:
        content = _read(directory / DEFAULT_LANG / "content.md")
        exercises = _read(directory / DEFAULT_LANG / "exercises.md")
        if content is not None:
            fallback = DEFAULT_LANG
    return {
        "content": content,
        "exercises": exercises,
        "break_fix": _read(directory / "lab" / "break_fix.sh"),
        "lab_spec": _read(directory / "lab" / "lab.yaml"),
        "lang": fallback or lang,
        "lang_fallback": fallback,
    }
