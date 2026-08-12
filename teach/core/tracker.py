"""Tracker/scraper: nothing is static — the whole catalog derives from sources.

- sync_cncf(): deterministic. Reads the cncf/curriculum repo through the GitHub
  API: each PDF's last-changed date is the curriculum version. Marks
  new-version-available when upstream changed.
- sync_lpi(): scrapes lpi.org and an AI model turns the page into structured
  updates (level, validity, prerequisites) per catalog cert.
- snapshot_topics(): downloads a cert's official objectives (HTML or PDF), the
  AI turns them into YAML topics and they are frozen into the MD (snapshot).
- generate_paths(): the AI proposes career paths from the catalog (requires,
  levels, CARE). Paths with edited: true are never overwritten.

The AI uses the same backends as the generator (litellm/claude/codex/gemini).

NOTE: the prompt strings here are deliberately still in Spanish — see the note
in generator.py. They are model input, not comments.
"""

import datetime
import html as html_lib
import io
import re
import subprocess

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


def _get_bytes(url: str) -> tuple[bytes, str]:
    """(body, content-type), with a fetch that cannot hang the caller.

    httpx hangs indefinitely on the CNCF curriculum PDFs on this machine — its
    own `timeout=60` never fires, so a snapshot blocks forever rather than
    failing — while curl fetches the same URL in half a second. The cause is
    below httpx and not worth chasing; the defect worth fixing is that one
    unreachable file could stall an unattended pass with no error at all.

    So: httpx in a worker thread with a short deadline, then curl. 15s costs
    nothing in the working case — httpx returns HTML in well under a second —
    and bounds the broken one. A fetch that fails loudly is recoverable; one
    that hangs silently is not.
    """
    import concurrent.futures

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(_get, url)
        try:
            response = future.result(timeout=15)
            return response.content, response.headers.get("content-type", "")
        except concurrent.futures.TimeoutError:
            pass                      # the thread is abandoned; curl decides
        except Exception:
            pass

    result = subprocess.run(
        ["curl", "-sL", "--max-time", "60", "-A", UA.get("User-Agent", "teach-plat"),
         "-w", "%{content_type}", "--output", "-", url],
        capture_output=True, timeout=90)
    if result.returncode != 0 or not result.stdout:
        raise TrackerError(f"Could not fetch {url} with either client "
                           f"(curl exit {result.returncode})")
    # `-w` appends the content type after the body, so split it back off.
    body = result.stdout
    marker = body.rfind(b"application/") if b"application/" in body[-120:] else -1
    if marker == -1:
        marker = body.rfind(b"text/") if b"text/" in body[-120:] else -1
    if marker > 0:
        return body[:marker], body[marker:].decode("ascii", "replace")
    return body, ""


def fetch_text(url: str, limit: int = 20000) -> str:
    """Plain text from a URL: PDF (pypdf) or HTML (tags stripped)."""
    body, content_type = _get_bytes(url)
    if url.lower().endswith(".pdf") or "pdf" in content_type:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(body))
        text = "\n".join(page.extract_text() or "" for page in reader.pages)
    else:
        decoded = body.decode("utf-8", "replace")
        text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", decoded, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html_lib.unescape(text)
    return re.sub(r"\s+", " ", text).strip()[:limit]


def _ai_yaml(backend: str | None, prompt: str) -> dict:
    complete, _ = make_completer(backend)
    raw = complete(YAML_SYSTEM, prompt).strip()
    raw = re.sub(r"^```[a-z]*\n?|\n?```$", "", raw).strip()
    data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise TrackerError(f"The AI did not return structured YAML:\n{raw[:300]}")
    return data


# ---------------------------------------------------------------- CNCF

def sync_cncf() -> list[str]:
    """Each curriculum's version is the date of the last commit touching its PDF."""
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
            changes.append(f"NEW uncatalogued upstream cert: {name}")
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
            changes.append(f"{cert_id}: curriculum changed -> {updated}")
        # `tracked_version` records what UPSTREAM publishes. What our material was
        # built on lives in the syllabus frontmatter (`version` + `snapshot_date`),
        # written by `teach cert snapshot` and never touched here — otherwise a
        # sync would silently rewrite the record of what we froze, and "is our
        # content current?" would become unanswerable by the act of asking.
        # scripts/check_versions.py compares the two.
        semantic = re.search(r"v(\d+\.\d+)", name)
        if semantic and cert.get("tracked_version") != semantic.group(1):
            cert["tracked_version"] = semantic.group(1)
            changes.append(f"{cert_id}: upstream version -> {semantic.group(1)}")
    catalog.save(data)
    return changes or ["cncf: no upstream changes"]


# ---------------------------------------------------------------- LPI

LPI_SUMMARY = "https://www.lpi.org/our-certifications/summary-of-lpi-certifications/"


def sync_lpi(backend: str | None = None) -> list[str]:
    """Scrape the official LPI summary and update level/validity/requires."""
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
                changes.append(f"{cert_id}: {field} {cert.get(field)} -> {update[field]}")
                cert[field] = update[field]
    for new in result.get("new") or []:
        changes.append(f"NEW uncatalogued upstream cert: {new.get('name')} ({new.get('exam')})")
    catalog.save(data)
    return changes or ["lpi: no changes"]


# ---------------------------------------------------------------- syllabus

def _topic_identity(topic: dict) -> tuple:
    """The fields whose change invalidates already generated content.

    The syllabus text is what the generator receives as its prompt, so if the
    title, the domain or the weight (which sets the requested depth) changes,
    the stored content answers a syllabus that no longer exists. `sources` is
    deliberately excluded: the official PDF URL gains version numbers without
    what has to be studied changing, and comparing it would mark everything
    stale on every re-snapshot.
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
    """Assign each incoming topic's status by comparing it against the stored one.

    This used to copy the old status verbatim, so a re-snapshot with a different
    title or weight left the topic at 'generated' and its content was never
    revisited — the syllabus-change trigger PLAN.md described did not exist.
    Returns (added, stale, edited_that_changed).
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

        # 'edited' is hand-enriched content and the project rule is that it is
        # never overwritten. The status is kept and reported separately so a
        # person decides, rather than discarding manual work silently.
        if old_status == "edited":
            topic["status"] = "edited"
            edited_changed.append(tid)
            continue

        # `stale_since` is what makes per-language invalidation possible. Status
        # lives at topic level but content exists once per language: without a
        # timestamp, regenerating Spanish would clear the stale flag and the
        # translations would describe the old syllabus forever. With it, each
        # language is compared against the moment of the change.
        topic["status"] = "stale"
        topic["stale_since"] = stale_at
        stale.append(tid)

    return added, stale, edited_changed


# Exams that number their objectives do it as <area>.<index>, with a three-digit
# area: LPI publishes 351.1, 301.2. Counting the distinct ids IN THE FETCHED TEXT
# is what makes the extraction checkable against its own input — the model cannot
# return four topics from a document that numbers thirteen.
OBJECTIVE_ID = re.compile(r"\b(\d{3})\.([1-9]\d?)\b")

# Syllabi keep retired objectives in the numbering so the ids of the survivors do
# not shift: LPIC-1 prints "104.4 Removed" between 104.3 and 104.5. Counting it
# would demand a topic for something the exam no longer asks about — and did,
# rejecting a correct 42-topic extraction for being one short of a phantom.
WITHDRAWN = re.compile(r"\s*(removed|retired|deleted|withdrawn)\b", re.I)

# A weight the document itself prints, in either form syllabi use: a percentage
# ("20%") or a labelled number ("Weight: 6"). Counting these answers "were the
# weights read or computed?" from the source rather than from their shape.
WEIGHT_TOKEN = re.compile(r"\b\d{1,3}\s?%|[Ww]eight:?\s*\d{1,3}\b")


# The version the objectives document states for ITSELF. The colon is load
# bearing: without it this matches prose like "results from a split of version
# 2.0 of the exam 304", and lpic-3-305 reads as 2.0 when it publishes 3.0.
# Changelog entries further down the page name older versions, so the FIRST
# labelled match is the current one.
PUBLISHED_VERSION = re.compile(r"Version:\s*([0-9]+(?:\.[0-9]+)+)")


def published_version(text: str) -> str | None:
    """The version an objectives page states, or None if it states none.

    None means unmeasured, not current — a page that does not say which version
    it is cannot be compared against what we froze, and pretending otherwise is
    how "unknown" quietly becomes "fine".
    """
    match = PUBLISHED_VERSION.search(text)
    return match.group(1) if match else None


def objective_ids(text: str) -> set[str]:
    """Numbered objectives present in a syllabus document.

    Empty when the document does not number its objectives — CNCF curricula and
    the Essentials-level LPI exams do not — and an empty set means "this check
    does not apply here", never "the document is fine". A check that cannot see
    something must say so rather than pass.

    Ids come in runs starting at 1, so an area with no `.1` is page furniture: a
    price ("160.5") and a percentage ("100.00") both match the shape otherwise.
    That rule is a property of the numbering, not a list of strings to maintain.
    """
    areas: dict[str, set[int]] = {}
    for match in OBJECTIVE_ID.finditer(text):
        if WITHDRAWN.match(text, match.end()):
            continue
        area, index = match.group(1), int(match.group(2))
        areas.setdefault(area, set()).add(index)
    return {f"{area}.{i}" for area, indexes in areas.items()
            if 1 in indexes for i in indexes}


def normalise_weights(topics: list[dict]) -> None:
    """Scale the published weights to percentages summing to exactly 100.

    Syllabi publish on their own scale — LPI's 305 objectives total 57, CNCF gives
    one percentage per domain — and the schema wants percentages. Asking the model
    to convert made it do arithmetic, and it came back 5% over on the first real
    document: correct extraction, thrown away for a rounding error.

    So the model copies the printed number and this does the sum. Largest
    remainder, so the parts are as close to proportional as two decimals allow and
    the total is exactly 100 rather than 99.99 — which matters only because the
    total is checked, and a check that fails on rounding gets deleted eventually.
    """
    raw = [float(t.get("weight") or 0) for t in topics]
    total = sum(raw)
    if total <= 0:
        raise TrackerError("Every extracted topic has weight 0 — nothing was read.")

    scaled = [w * 100 / total for w in raw]
    floors = [int(w * 100) for w in scaled]          # hundredths, rounded down
    short = 10000 - sum(floors)
    order = sorted(range(len(scaled)), key=lambda i: scaled[i] * 100 - floors[i],
                   reverse=True)
    for i in order[:short]:
        floors[i] += 1
    for topic, hundredths in zip(topics, floors):
        topic["weight"] = round(hundredths / 100, 2)


def _reject_unreadable_syllabus(topics: list[dict], text: str, url: str) -> None:
    """Refuse a topic list that the source document does not support.

    Both checks exist because of the same incident: seven LPI certifications were
    snapshotted from their *overview* page — which lists chapter titles and no
    objectives — and the extraction dutifully returned the chapter titles. The
    material generated from them is well written and covers about a quarter of
    each exam. Every per-file check passed, because every file was fine; the list
    of files was the defect.

    Nothing here is specific to a vendor or an exam. Both facts are derived from
    the document that was actually fetched, so they hold for any syllabus.
    """
    upstream = objective_ids(text)
    if upstream and len(topics) < len(upstream):
        # When the extraction adopted the document's own numbering, the set
        # difference names the objectives that would be missing — which turns
        # "one short" from something to argue about into something to look up.
        got = {str(t.get("id")) for t in topics}
        missing = sorted(upstream - got,
                         key=lambda s: tuple(int(p) for p in s.split(".")))
        detail = (f" Missing: {', '.join(missing)}." if missing and got & upstream
                  else "")
        raise TrackerError(
            f"{url} numbers {len(upstream)} objectives and the extraction returned "
            f"{len(topics)} topics — {len(upstream) - len(topics)} would never be "
            f"written.{detail} Either the URL points at an overview page instead of "
            f"the objectives, or the extraction collapsed objectives into their "
            f"chapter headings. Snapshot not saved."
        )

    # A weighting nobody read. `sum == 100` was the only rule this ever had, and
    # dividing 100 by the topic count satisfies it exactly — so the guardrail was
    # passed most easily by the worst available answer.
    #
    # But equal weights are sometimes the truth: CNCF publishes CAPA as five
    # domains at 20% each, and rejecting that would block a correct syllabus for
    # having the shape of a wrong one. The distinction is in the document, not in
    # the numbers — if it prints a weight per topic, the weights were read.
    weights = [round(float(t.get("weight") or 0), 2) for t in topics]
    published = WEIGHT_TOKEN.findall(text)
    if (len(topics) > 2 and max(weights) - min(weights) < 0.02
            and len(published) < len(topics)):
        raise TrackerError(
            f"all {len(topics)} weights came back as {weights[0]:g}, and {url} prints "
            f"only {len(published)} weights for {len(topics)} topics — so this is 100 "
            f"divided by the topic count rather than anything the exam publishes. "
            f"Snapshot not saved."
        )


def snapshot_topics(cert_id: str, backend: str | None = None, force: bool = False) -> dict:
    """Freeze the official syllabus into the MD: fetch objectives (HTML/PDF) -> AI -> topics."""
    data = catalog.load()
    cert = data["certs"].get(cert_id)
    if not cert:
        raise TrackerError(f"'{cert_id}' is not in the catalog")
    url = (cert.get("sources") or {}).get("objectives")
    if not url:
        raise TrackerError(f"'{cert_id}' has no sources.objectives in the catalog")

    post = certs.load(cert_id)
    existing = {str(t.get("id")): t for t in post.metadata.get("topics", [])}
    if existing and not force:
        raise TrackerError(
            f"'{cert_id}' already has a syllabus ({len(existing)} topics). Use --force to re-snapshot."
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
        "One entry per NUMBERED OBJECTIVE — the deepest numbered level the document "
        "has. If it numbers 351.1, 351.2 … 353.4, that is 13 entries and 13 is the "
        "answer; the chapter headings ('351 Full Virtualization') go in 'topic', "
        "never in place of the objectives underneath them. Returning the headings "
        "loses most of the exam.\n"
        "If the document has no numbered objectives at all, say so by returning an "
        "empty topics list rather than inventing a level of detail it does not "
        "have — that means the wrong page was fetched, and it will be fixed at the "
        "source instead of guessed at here.\n"
        "'weight': copy the number the document prints for that objective, on "
        "whatever scale it uses — LPI prints per-objective weights totalling about "
        "57, and that is the right answer, not 100. Do NOT rescale: the totals are "
        "normalised in code afterwards, and arithmetic done here is arithmetic that "
        "can be wrong. The only case that needs judgement is a document that weights "
        "whole domains and not the objectives inside them (CNCF does this): split "
        "the domain's percentage evenly among its objectives, and say so by using "
        "the same value for those siblings only.",
    )
    topics = result.get("topics") or []
    if not topics:
        raise TrackerError(
            f"No topics could be extracted from {url}. If the page loads, it is the "
            f"wrong page: an overview page describes a certification and does not list "
            f"its objectives. Point catalog.yaml at the objectives document."
        )

    # Published scale -> percentages, in code. Scaling stays proportional, so the
    # uniformity check below still sees weights computed from a count as uniform.
    normalise_weights(topics)

    # Check the answer against the document it came from, before anything is
    # written. Both facts are derived from the fetched text, so this is not
    # specific to a vendor, an exam, or a page layout.
    _reject_unreadable_syllabus(topics, text, url)

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
    """Translate path texts into the supported languages.

    Translations are stored under paths.<slug>.i18n.<lang> (the base text stays
    in the default language); the API merges them according to ?lang=.
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
    """The AI proposes career paths from the catalog. edited: true is never overwritten."""
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
            changes.append(f"{slug}: skipped (edited)")
            continue
        existing[slug] = path
        changes.append(f"{slug}: {'actualizado' if slug in existing else 'nuevo'}")
    data["paths"] = existing
    catalog.save(data)
    return changes
