"""Tracker/scraper: nada es estático — todo el catálogo se deriva de fuentes.

- sync_cncf(): determinístico. Lee el repo cncf/curriculum por API de GitHub:
  fecha de último cambio de cada PDF = versión del curriculum. Marca
  new-version-available cuando upstream cambió.
- sync_lpi(): scrapea lpi.org y un modelo AI convierte la página en updates
  estructurados (nivel, validez, prerequisitos) por cert del catálogo.
- snapshot_topics(): baja los objetivos oficiales de una cert (HTML o PDF),
  la AI los convierte en topics YAML y se congelan en el MD (snapshot).
- generate_paths(): la AI propone los paths de carrera a partir del catálogo
  (requires, niveles, CARE). Los paths con edited: true nunca se pisan.

La AI usa los mismos backends del generador (litellm/claude/codex/gemini).
"""

import datetime
import html as html_lib
import io
import re

import httpx
import yaml

from . import catalog, certs
from .generator import make_completer

UA = {"User-Agent": "Mozilla/5.0 (compatible; teach-plat-tracker)"}
CNCF_REPO_API = "https://api.github.com/repos/cncf/curriculum"

YAML_SYSTEM = (
    "Sos un parser de documentación oficial de certificaciones. Respondés "
    "SOLO con YAML válido, sin markdown, sin fences, sin comentarios extra."
)


class TrackerError(Exception):
    pass


def _get(url: str) -> httpx.Response:
    response = httpx.get(url, headers=UA, follow_redirects=True, timeout=60)
    response.raise_for_status()
    return response


def fetch_text(url: str, limit: int = 20000) -> str:
    """Texto plano de una URL: PDF (pypdf) o HTML (tags fuera)."""
    response = _get(url)
    if url.lower().endswith(".pdf") or "pdf" in response.headers.get("content-type", ""):
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(response.content))
        text = "\n".join(page.extract_text() or "" for page in reader.pages)
    else:
        text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", response.text, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html_lib.unescape(text)
    return re.sub(r"\s+", " ", text).strip()[:limit]


def _ai_yaml(backend: str | None, prompt: str) -> dict:
    complete, _ = make_completer(backend)
    raw = complete(YAML_SYSTEM, prompt).strip()
    raw = re.sub(r"^```[a-z]*\n?|\n?```$", "", raw).strip()
    data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise TrackerError(f"La AI no devolvió YAML estructurado:\n{raw[:300]}")
    return data


# ---------------------------------------------------------------- CNCF

def sync_cncf() -> list[str]:
    """Versión de cada curriculum = fecha del último commit que tocó su PDF."""
    data = catalog.load()
    changes = []
    files = _get(f"{CNCF_REPO_API}/contents/").json()
    today = datetime.date.today().isoformat()
    for entry in files:
        name = entry["name"]
        if not name.lower().endswith(".pdf"):
            continue
        cert_id = re.split(r"[_ ]", name)[0].lower()
        if cert_id not in data["certs"]:
            changes.append(f"NUEVA cert upstream sin catalogar: {name}")
            continue
        commits = _get(
            f"{CNCF_REPO_API}/commits?path={httpx.QueryParams({'p': name})['p']}&per_page=1"
        ).json()
        updated = commits[0]["commit"]["committer"]["date"][:10] if commits else None
        cert = data["certs"][cert_id]
        cert["last_checked"] = today
        if updated and cert.get("curriculum_updated") != updated:
            cert["curriculum_updated"] = updated
            cert["upstream_status"] = "new-version-available"
            changes.append(f"{cert_id}: curriculum cambió → {updated}")
        semantic = re.search(r"v(\d+\.\d+)", name)
        if semantic and cert.get("tracked_version") != semantic.group(1):
            cert["tracked_version"] = semantic.group(1)
            changes.append(f"{cert_id}: versión → {semantic.group(1)}")
    catalog.save(data)
    return changes or ["cncf: sin cambios upstream"]


# ---------------------------------------------------------------- LPI

LPI_SUMMARY = "https://www.lpi.org/our-certifications/summary-of-lpi-certifications/"


def sync_lpi(backend: str | None = None) -> list[str]:
    """Scrapea el resumen oficial de LPI y actualiza nivel/validez/requires."""
    data = catalog.load()
    known = {
        cert_id: {"name": c["name"], "exam": c.get("exam", "")}
        for cert_id, c in data["certs"].items()
        if c.get("category") == "linux"
    }
    page = fetch_text(LPI_SUMMARY)
    result = _ai_yaml(
        backend,
        f"Página oficial de LPI (texto plano):\n{page}\n\n"
        f"Certs en mi catálogo (id → nombre/examen):\n{yaml.safe_dump(known, allow_unicode=True)}\n"
        "Devolvé YAML con esta forma exacta:\n"
        "updates:\n  <id-del-catalogo>:\n    level: essentials|professional|specialty\n"
        "    validity: lifetime|'5 años'|'2 años'|'3 años'\n"
        "    requires: [ids del catálogo que exige activos, o lista vacía]\n"
        "Mapeo de tracks LPI a level (usar EXACTAMENTE este criterio): "
        "track Essentials → essentials; tracks LPIC-1/LPIC-2/LPIC-3 (incluye "
        "todas las especializaciones LPIC-3) → professional; track Open "
        "Technology (DevOps, BSD) → specialty.\n"
        "new:\n  - name: ...\n    exam: ...\n    level: ...\n    validity: ...\n"
        "Solo certs que aparezcan en la página. 'new' = certs de la página que "
        "no están en mi catálogo.",
    )
    changes = []
    today = datetime.date.today().isoformat()
    for cert_id, update in (result.get("updates") or {}).items():
        if cert_id not in data["certs"]:
            continue
        cert = data["certs"][cert_id]
        cert["last_checked"] = today
        for field in ("level", "validity", "requires"):
            if field in update and cert.get(field) != update[field]:
                changes.append(f"{cert_id}: {field} {cert.get(field)} → {update[field]}")
                cert[field] = update[field]
    for new in result.get("new") or []:
        changes.append(f"NUEVA cert upstream sin catalogar: {new.get('name')} ({new.get('exam')})")
    catalog.save(data)
    return changes or ["lpi: sin cambios"]


# ---------------------------------------------------------------- temario

def _topic_identity(topic: dict) -> tuple:
    """Los campos cuyo cambio invalida el contenido ya generado.

    El texto del temario es lo que el generador recibe como prompt, así que si
    cambia el título, el dominio o el peso (que fija la profundidad pedida), el
    contenido guardado responde a un temario que ya no existe. `sources` queda
    afuera a propósito: la URL del PDF oficial cambia de versión sin que cambie
    lo que hay que estudiar, y compararla marcaría todo como stale en cada
    re-snapshot.
    """
    weight = topic.get("weight")
    return (
        (topic.get("title") or "").strip(),
        (topic.get("topic") or "").strip(),
        round(float(weight), 2) if weight is not None else None,
    )


def _apply_snapshot_status(
    topics: list[dict], existing: dict[str, dict], url: str, stale_at: str
) -> tuple[list[str], list[str], list[str]]:
    """Asigna el status de cada topic entrante comparándolo con el guardado.

    Antes esto copiaba el status viejo tal cual, así que un re-snapshot con un
    título o un peso distinto dejaba el topic en 'generated' y su contenido no
    se volvía a mirar nunca — el disparador por cambio de temario que PLAN.md
    describía no existía. Devuelve (nuevos, stale, editados_que_cambiaron).
    """
    added: list[str] = []
    stale: list[str] = []
    edited_changed: list[str] = []

    for topic in topics:
        tid = str(topic.get("id"))
        old = existing.get(tid)
        topic.setdefault("sources", (old or {}).get("sources") or [url])

        if not old:
            topic["status"] = "pending"
            added.append(tid)
            continue

        old_status = old.get("status", "pending")
        if _topic_identity(topic) == _topic_identity(old):
            topic["status"] = old_status
            continue

        # 'edited' es contenido enriquecido a mano: la regla del proyecto es que
        # no se pisa. Se conserva el status y se reporta aparte para que una
        # persona decida, en vez de descartar el trabajo manual en silencio.
        if old_status == "edited":
            topic["status"] = "edited"
            edited_changed.append(tid)
            continue

        # `stale_since` es lo que permite invalidar por idioma. El status vive a
        # nivel de topic, pero el contenido existe una vez por idioma: sin una
        # marca temporal, regenerar el español limpiaría el stale y las
        # traducciones quedarían describiendo el temario viejo para siempre.
        # Con esto, cada idioma se compara contra el momento del cambio.
        topic["status"] = "stale"
        topic["stale_since"] = stale_at
        stale.append(tid)

    return added, stale, edited_changed


def snapshot_topics(cert_id: str, backend: str | None = None, force: bool = False) -> dict:
    """Congela el temario oficial en el MD: fetch objetivos (HTML/PDF) → AI → topics."""
    data = catalog.load()
    cert = data["certs"].get(cert_id)
    if not cert:
        raise TrackerError(f"'{cert_id}' no está en el catálogo")
    url = (cert.get("sources") or {}).get("objectives")
    if not url:
        raise TrackerError(f"'{cert_id}' no tiene sources.objectives en el catálogo")

    post = certs.load(cert_id)
    existing = {str(t.get("id")): t for t in post.metadata.get("topics", [])}
    if existing and not force:
        raise TrackerError(
            f"'{cert_id}' ya tiene temario ({len(existing)} topics). Usar --force para re-snapshotear."
        )

    text = fetch_text(url)
    result = _ai_yaml(
        backend,
        f"Objetivos oficiales de la certificación {cert['name']} "
        f"(examen {cert.get('exam')}), texto extraído de {url}:\n{text}\n\n"
        "Devolvé YAML con esta forma exacta:\n"
        "version: <versión del temario si aparece, si no 'unknown'>\n"
        "topics:\n  - id: '1.1'\n    title: ...\n    topic: '1 - <nombre del dominio>'\n"
        "    weight: <número, el % que ESE SUB-TEMA vale del examen total>\n"
        "Cubrí TODOS los dominios/temas del documento, en orden. Si el documento "
        "solo tiene dominios (sin subtemas numerados), usá el dominio como topic y "
        "sus bullets principales como topics con ids '1.1', '1.2', etc.\n"
        "IMPORTANTE sobre 'weight': muchos temarios de CNCF dan el porcentaje "
        "SOLO a nivel de dominio completo (ej. 'Domain 1: 20%' con 4 sub-temas "
        "adentro). En ese caso NO copies ese 20% en cada sub-tema — repartilo "
        "entre ellos (20/4 = 5 cada uno). La suma de los weight de TODOS los "
        "topics del YAML debe dar exactamente 100.",
    )
    topics = result.get("topics") or []
    if not topics:
        raise TrackerError("La AI no extrajo topics del documento")
    stale_at = datetime.datetime.now().isoformat(timespec="seconds")
    added, stale, edited_changed = _apply_snapshot_status(topics, existing, url, stale_at)

    total_weight = sum(float(t.get("weight") or 0) for t in topics)
    if abs(total_weight - 100) > 2:
        raise TrackerError(
            f"Los weight de los {len(topics)} topics suman {total_weight}, no 100 — "
            "probablemente el bug de peso-por-dominio (el PDF da % solo por "
            "dominio y se copió sin repartir entre sub-temas). Revisar el YAML "
            "a mano antes de guardar; no se persiste el snapshot."
        )

    post.metadata["topics"] = topics
    post.metadata["version"] = str(result.get("version") or cert.get("tracked_version"))
    post.metadata["snapshot_date"] = datetime.date.today().isoformat()
    sources = post.metadata.get("sources") or []
    if url not in sources:
        post.metadata["sources"] = [*sources, url]
    certs.save(cert_id, post)

    cert["upstream_status"] = "current"
    cert["last_checked"] = datetime.date.today().isoformat()
    catalog.save(data)
    return {
        "cert": cert_id,
        "topics": len(topics),
        "version": post.metadata["version"],
        "added": added,
        "stale": stale,
        "edited_changed": edited_changed,
    }


# ---------------------------------------------------------------- paths

TRANSLATABLE_PATH_FIELDS = ("name", "description", "how_to_obtain", "rules")


def translate_paths(backend: str | None = None, langs: list[str] | None = None) -> list[str]:
    """Traduce los textos de los paths a los idiomas soportados.

    Guarda las traducciones en paths.<slug>.i18n.<lang> (el texto base queda en
    el idioma default); la API las mergea según ?lang=.
    """
    data = catalog.load()
    paths = data.get("paths") or {}
    base = {
        slug: {k: v for k, v in p.items() if k in TRANSLATABLE_PATH_FIELDS}
        for slug, p in paths.items()
    }
    langs = langs or [l for l in certs.LANGS if l != certs.DEFAULT_LANG]
    changes = []
    for lang in langs:
        result = _ai_yaml(
            backend,
            f"Textos de paths de carrera (en español):\n"
            f"{yaml.safe_dump(base, allow_unicode=True)}\n"
            f"Traducilos al idioma con código '{lang}'. Mantené los términos "
            "técnicos y nombres de certificaciones en inglés (CKA, LPIC-1, "
            "Kubestronaut, etc). Devolvé YAML con exactamente la misma "
            "estructura (mismos slugs y campos, incluyendo 'rules' como lista "
            "si existe).",
        )
        for slug, translated in result.items():
            if slug not in paths or not isinstance(translated, dict):
                continue
            paths[slug].setdefault("i18n", {})[lang] = {
                k: v for k, v in translated.items() if k in TRANSLATABLE_PATH_FIELDS
            }
        changes.append(f"{lang}: {len(result)} paths traducidos")
        catalog.save(data)  # guardado incremental por idioma
    return changes


def generate_paths(backend: str | None = None) -> list[str]:
    """La AI propone paths de carrera desde el catálogo. edited: true no se pisa."""
    data = catalog.load()
    summary = {
        cert_id: {
            k: v
            for k, v in c.items()
            if k in ("name", "exam", "category", "level", "validity", "requires", "renewed_by")
        }
        for cert_id, c in data["certs"].items()
    }
    result = _ai_yaml(
        backend,
        f"Catálogo de certificaciones:\n{yaml.safe_dump(summary, allow_unicode=True)}\n\n"
        "Armá paths de carrera. Devolvé YAML:\n"
        "paths:\n  <slug>:\n    name: ...\n    description: <1-2 frases, en español>\n"
        "    steps: [[ids en paralelo], [siguiente paso], ...]\n"
        "Reglas: respetar 'requires' (nunca poner una cert antes que su "
        "prerequisito), ordenar de menor a mayor nivel, usar solo ids del "
        "catálogo. Un path por categoría/rol razonable (admin linux, kubernetes, "
        "observabilidad/service mesh si da el catálogo).",
    )
    changes = []
    existing = data.get("paths") or {}
    for slug, path in (result.get("paths") or {}).items():
        if existing.get(slug, {}).get("edited"):
            changes.append(f"{slug}: salteado (edited)")
            continue
        existing[slug] = path
        changes.append(f"{slug}: {'actualizado' if slug in existing else 'nuevo'}")
    data["paths"] = existing
    catalog.save(data)
    return changes
