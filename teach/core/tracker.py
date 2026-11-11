"""Tracker/scraper: nothing is static — the whole catalog derives from sources.

- sync_cncf(): deterministic. Reads the cncf/curriculum repo through the GitHub
  API: writes what upstream publishes into each cert's `upstream:` block
  (version, objectives pinned by commit, sha256) and `upstream_status`
  (current | outdated). It never writes `tracked_version` (#63).
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
import hashlib
import html as html_lib
import io
import re
import subprocess
from urllib.parse import quote, urljoin

import httpx
import yaml

from . import catalog, certs
from .generator import _usage_context, make_completer

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
    """Plain text from a URL: PDF (pypdf) or HTML (tags stripped), cut at `limit` characters.

    Fine for a version banner or a summary page. A syllabus snapshot must not be
    cut: it uses `fetch_document`, which refuses instead."""
    body, content_type = _get_bytes(url)
    return document_text(url, body, content_type)[:limit]


def fetch_document(url: str, limit: int = 20000) -> tuple[str, str]:
    """(full text, sha256 of the bytes served) of an objectives document, for a snapshot.

    The snapshot used to read `fetch_text(url)`, cut at 20,000 characters: a longer
    document lost its tail silently and the model was asked for the objectives of a
    fragment. Here a longer text is refused, and the hash of the vendor's bytes is
    returned so the frozen syllabus records exactly which document it came from."""
    body, content_type = _get_bytes(url)
    text = document_text(url, body, content_type)
    if len(text) > limit:
        raise TrackerError(
            f"{url}: the extracted text is {len(text)} characters, over the {limit} a snapshot reads. "
            "Refused rather than truncated: point sources.objectives at the objectives document itself, "
            "or raise the limit deliberately.")
    return text, hashlib.sha256(body).hexdigest()


def document_text(url: str, body: bytes, content_type: str) -> str:
    """The text of a fetched PDF or HTML body, whitespace collapsed, never cut."""
    if url.lower().endswith(".pdf") or "pdf" in content_type:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(body))
        text = "\n".join(page.extract_text() or "" for page in reader.pages)
    else:
        decoded = body.decode("utf-8", "replace")
        text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", decoded, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html_lib.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


# Lines a CLI backend prints about itself, which are not the answer. Seen on a
# CAPA snapshot: "Client.listTools() called but server has no tools" landed in
# the middle of the YAML and the parse died at line 2, throwing away a model call
# for a diagnostic that has nothing to do with the content.
CLI_NOISE = re.compile(
    r"^\s*(Client\.\w+\(\)|\[?(DEBUG|INFO|WARN|WARNING|ERROR)\]?[: ]|"
    r"(MCP|mcp) server |Loaded \d+|Using model )", re.M)


def _ai_yaml(backend: str | None, prompt: str, usage: dict | None = None) -> dict:
    complete, _ = make_completer(backend)
    # Tag the spend before the call: without this, snapshot/catalog completions
    # land in usage.jsonl with no `op` (or worse, with a stale one left over
    # from a previous author/translate call in the same process) and the
    # per-stage report cannot account for them.
    _usage_context.clear()
    _usage_context.update(usage or {"op": "snapshot"})
    raw = complete(YAML_SYSTEM, prompt).strip()
    raw = re.sub(r"^```[a-z]*\n?|\n?```$", "", raw).strip()
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError:
        # Retry without the backend talking about itself. Only on failure: a
        # clean answer is never touched, so this cannot corrupt a good parse.
        cleaned = "\n".join(l for l in raw.splitlines() if not CLI_NOISE.match(l))
        try:
            data = yaml.safe_load(cleaned)
        except yaml.YAMLError as error:
            raise TrackerError(
                f"The backend's answer is not YAML, with or without its own "
                f"diagnostics stripped ({error}). First 300 characters:\n{raw[:300]}"
            ) from error
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
        cert = data["certs"][cert_id]
        # Date the document we ACTUALLY READ last changed, which is not always
        # the PDF. CAPA's PDF was last touched 2024-10-21 and describes four
        # domains with uneven weights; the repository's capa/README.md was
        # rewritten 2025-11-28 with five domains at 20% each, and that is the
        # curriculum in force. Tracking the PDF would have reported CAPA as
        # current while it sat a full revision behind — the same shape of blind
        # spot as a syllabus scraped from the wrong page.
        objectives = (cert.get("sources") or {}).get("objectives") or ""
        tracked_path = name
        if "/curriculum/master/" in objectives:
            tracked_path = objectives.split("/curriculum/master/", 1)[1]
        commits = _get(
            f"{CNCF_REPO_API}/commits?path={httpx.QueryParams({'p': tracked_path})['p']}"
            f"&per_page=1"
        ).json()
        updated = commits[0]["commit"]["committer"]["date"][:10] if commits else None
        cert["last_checked"] = today
        date_moved = bool(updated and cert.get("curriculum_updated") != updated)
        if date_moved:
            cert["curriculum_updated"] = updated
            changes.append(f"{cert_id}: curriculum changed -> {updated}")
        # What upstream publishes goes in `upstream:` (#63), never in `tracked_version`: that one says
        # which curriculum the material was built against, and only the final PR of the cert's upgrade
        # milestone moves it (check_pr enforces it). A sync used to copy the version from the PDF's
        # file name into `tracked_version`, which would have relabelled v1.35 material as v1.37.
        semantic = re.search(r"v(\d+\.\d+)", name)
        if semantic and commits:
            version = semantic.group(1)
            block = cert.get("upstream") or {}
            # `upstream:` says what is ahead of the material. Once tracked_version equals the published
            # version there is nothing ahead, and writing the block again would stamp today's date on it.
            if block.get("version") != version and str(cert.get("tracked_version")) != version:
                url = f"https://github.com/cncf/curriculum/raw/{commits[0]['sha']}/{quote(name)}"
                body, _ = _get_bytes(url)
                cert["upstream"] = {**block, "version": version, "objectives": url,
                                    "sha256": hashlib.sha256(body).hexdigest(), "published": updated,
                                    "detected": today}
                changes.append(f"{cert_id}: upstream publishes {version} (tracked_version stays "
                               f"{cert.get('tracked_version')})")
            status = "current" if str(cert.get("tracked_version")) == version else "outdated"
        else:
            # No version in the file name: the commit date is the only signal (#63's derived status).
            status = "outdated" if date_moved else cert.get("upstream_status") or "current"
        cert["upstream_status"] = status
    catalog.save(data)
    return changes or ["cncf: no upstream changes"]


# ---------------------------------------------------------------- Public clouds

def sync_clouds(backend: str | None = None) -> list[str]:
    """Upstream facts for the vendor-cloud certs (category: cloud).

    AWS, Microsoft and Google publish no machine-readable version feed, so the
    official exam-guide document itself is fetched and the AI extracts only
    what the document states about itself: a printed version string and a
    printed last-updated date. "unknown" is a correct answer — before this
    existed the status table showed the cloud rows as unmeasured forever,
    because no sync path knew these vendors (found 2026-09-04, aws-clf's
    first day on the site). Writes catalog upstream fields only; the frozen
    syllabus is never touched, same separation as every other sync.
    """
    data = catalog.load()
    changes = []
    today = datetime.date.today().isoformat()
    for cert_id, cert in data["certs"].items():
        if cert.get("category") != "cloud":
            continue
        url = (cert.get("sources") or {}).get("objectives") or ""
        if not url:
            continue
        text = fetch_text(url)
        result = _ai_yaml(
            backend,
            usage={"op": "catalog-sync", "kind": "cloud", "cert": cert_id},
            prompt=f"Documento oficial del examen {cert.get('exam')} "
            f"({cert.get('name')}), texto plano:\n{text}\n\n"
            "Devolvé YAML con esta forma exacta:\n"
            "version: <la REVISIÓN que el documento imprime sobre sí mismo "
            "(p.ej. 'Version 1.0' -> '1.0'), NUNCA el código de examen tipo "
            "CLF-C02/AZ-900 que ya conocemos; si no imprime revisión, 'unknown'>\n"
            "updated: <fecha de última actualización SI EL DOCUMENTO LA "
            "IMPRIME, formato YYYY-MM-DD, si no 'unknown'>\n"
            "No inventes nada: 'unknown' es una respuesta correcta.",
        )
        cert["last_checked"] = today
        version = str(result.get("version") or "unknown")
        updated = str(result.get("updated") or "unknown")
        if version != "unknown" and cert.get("tracked_version") != version:
            cert["tracked_version"] = version
            changes.append(f"{cert_id}: upstream version -> {version}")
        if (updated != "unknown" and re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated)
                and cert.get("curriculum_updated") != updated):
            cert["curriculum_updated"] = updated
            changes.append(f"{cert_id}: curriculum updated -> {updated}")
        catalog.save(data)  # incremental: a later fetch failing loses nothing
    return changes or ["clouds: no upstream changes"]


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
        usage={"op": "catalog-sync", "kind": "lpi"},
        prompt=f"Página oficial de LPI (texto plano):\n{page}\n\n"
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


# ---------------------------------------------------------------- AI vendors

# Words a vendor prints for the tier of a certification, mapped to the catalog's
# levels. Read by the model off the page, translated here: the vocabulary of
# catalog.yaml is ours, and a model asked to use it maps "Associate" to whatever
# it guesses we mean (NCA-AIIO had sat at `essentials` since 2026-09-09).
#
# Only tier words. "Beginner", "Intermediate" and "Advanced" describe the
# candidate's expected experience, not the credential: the MCPA page prints
# "Experience Level: Beginner" for a certification named Associate, and the
# first real sync turned it into `essentials` on that word.
AI_LEVELS = {
    "foundational": "essentials", "fundamentals": "essentials", "foundation": "essentials",
    "associate": "associate", "professional": "professional", "expert": "professional",
    "specialty": "specialty",
}

# Where an overview page states its facts. The page is long — NCA-AIIO's is
# 380 KB of HTML — and the facts sit in one block, so the model reads that block.
EXAM_FACTS = re.compile(r"certification\s+level|validity|valid\s+for|number\s+of\s+questions|"
                        r"exam\s+duration|duration", re.I)


def _exam_facts(text: str, width: int = 6000) -> str:
    match = EXAM_FACTS.search(text)
    start = max(0, match.start() - width // 3) if match else 0
    return text[start:start + width]


def _validity(current: str | None, years) -> str | None:
    """The catalog's validity string for a vendor's figure, or None if nothing changes.

    The catalog writes "2 años" for some vendors and "2 years" for others; the
    number is the fact, so a sync that agrees on it leaves the wording alone."""
    if years in (None, "unknown", ""):
        return None
    if str(years).lower() == "lifetime":
        return None if current == "lifetime" else "lifetime"
    try:
        years = int(years)
    except (TypeError, ValueError):
        return None
    numbers = re.findall(r"\d+", str(current or ""))
    if numbers and int(numbers[0]) == years:
        return None
    unit = "years" if "year" in str(current or "") else "años"
    return f"{years} {unit}"


def sync_ai(backend: str | None = None) -> list[str]:
    """Upstream facts for the AI certifications (category: ai).

    No sync knew this category, so six certifications kept the values they were
    catalogued with: NCA-AIIO stayed `essentials` with `tracked_version: unknown`
    while NVIDIA publishes it as Associate (#271). Two kinds of fact, read two ways:

    - **Drift**, deterministic: the sha256 of the objectives document is compared
      with the one the syllabus was frozen from (`source_sha256`). Syllabi frozen
      before the snapshot recorded it have no such hash; for those the first sync
      records a baseline (`objectives_sha256`) and says so, because "the same as
      the day we started looking" is not "the same as what we froze". A change
      goes to `upstream:` and `upstream_status: outdated`; `tracked_version` is
      never written (#63).
    - **Level and validity**, read by the model from the overview page, the way
      sync_lpi reads LPI's. "unknown" is a correct answer and changes nothing.
    """
    data = catalog.load()
    changes = []
    today = datetime.date.today().isoformat()
    for cert_id, cert in data["certs"].items():
        if cert.get("category") != "ai":
            continue
        sources = cert.get("sources") or {}
        objectives = sources.get("objectives")
        if not objectives:
            continue
        body, content_type = _get_bytes(objectives)
        digest = hashlib.sha256(body).hexdigest()
        frozen = certs.load(cert_id).metadata.get("source_sha256") if certs.md_path(cert_id).exists() else None
        baseline = frozen or cert.get("objectives_sha256")
        block = cert.get("upstream") or {}
        if not baseline:
            cert["objectives_sha256"] = digest
            changes.append(f"{cert_id}: objectives baseline recorded ({digest[:12]}); the syllabus "
                           "predates source_sha256, so drift is measured from today")
        elif baseline == digest:
            cert["upstream_status"] = "current"
            cert.pop("upstream", None)
        else:
            cert["upstream_status"] = "outdated"
            if block.get("sha256") != digest:
                cert["upstream"] = {**block, "objectives": objectives, "sha256": digest,
                                    "detected": today}
                changes.append(f"{cert_id}: the objectives document changed upstream "
                               f"(tracked_version stays {cert.get('tracked_version')})")

        overview = sources.get("overview") or objectives
        page = document_text(objectives, body, content_type) if overview == objectives else fetch_text(overview, limit=10**7)
        result = _ai_yaml(
            backend,
            usage={"op": "catalog-sync", "kind": "ai", "cert": cert_id},
            prompt=f"Official page of the {cert.get('exam')} exam ({cert.get('name')}), "
            f"plain text:\n{_exam_facts(page)}\n\n"
            "Return YAML with exactly this shape:\n"
            "level: <the TIER of the certification THE PAGE PRINTS, one word, lower case "
            "(foundational, associate, professional, expert, specialty…). Not the candidate's "
            "experience level ('Experience Level: Beginner' is not a tier); 'unknown' if it prints none>\n"
            "validity_years: <how many years the certification stays valid, as an integer; "
            "'lifetime' if it never expires; 'unknown' if the page does not say>\n"
            "Copy only what the page states. 'unknown' is a correct answer.",
        )
        cert["last_checked"] = today
        level = AI_LEVELS.get(str(result.get("level") or "").strip().lower())
        if level and cert.get("level") != level:
            changes.append(f"{cert_id}: level {cert.get('level')} -> {level}")
            cert["level"] = level
        validity = _validity(cert.get("validity"), result.get("validity_years"))
        if validity:
            changes.append(f"{cert_id}: validity {cert.get('validity')} -> {validity}")
            cert["validity"] = validity
        catalog.save(data)  # incremental: a later fetch failing loses nothing
    return changes or ["ai: no upstream changes"]


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
    revisited — the syllabus-change trigger docs/ORIGINAL_DESIGN.md described did not exist.
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


def _reject_unreadable_syllabus(topics: list[dict], text: str, url: str,
                                weights_unpublished: bool = False) -> None:
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
    #
    # And some vendors publish no weighting at all: HashiCorp lists Terraform
    # objectives with nothing beside them. There an even split is not a guess
    # passed off as data, it is the only honest answer — but only because a
    # person looked and said so in catalog.yaml (`weights: unpublished`). The
    # model saying so would be the same defect this check exists to catch.
    if weights_unpublished:
        return
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

    text, source_sha256 = fetch_document(url)
    result = _ai_yaml(
        backend,
        usage={"op": "snapshot", "cert": cert_id},
        prompt=f"Objetivos oficiales de la certificación {cert['name']} "
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
        "Some syllabi publish only domains, with no numbered objectives beneath "
        "them — CNCF associate-level curricula do. There the domain IS the "
        "deepest level the document has, so one entry per domain is the right "
        "answer, not a collapse. Use the document's own granularity: never "
        "shallower than what it publishes, never deeper than what it publishes.\n"
        "Return an empty topics list only if the document describes the "
        "certification without listing what it covers at all. That means the "
        "wrong page was fetched, and it will be fixed at the source rather than "
        "guessed at here.\n"
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
    weights_unpublished = cert.get("weights") == "unpublished"
    _reject_unreadable_syllabus(topics, text, url, weights_unpublished)

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
    # How many weights the source document printed. The snapshot knows this
    # because it just checked; nothing downstream can find out without
    # re-fetching. Recording it lets the offline checker tell "every weight is
    # 20% because CNCF publishes it that way" from "every weight is 20% because
    # nobody read one" — the same distinction, available for free, forever.
    post.metadata["weights_published"] = len(WEIGHT_TOKEN.findall(text))
    if weights_unpublished:
        # Carried into the syllabus so the offline checker, which never reads
        # the catalog, knows the even split was declared rather than computed.
        post.metadata["weights"] = "unpublished"
    post.metadata["version"] = str(result.get("version") or cert.get("tracked_version"))
    post.metadata["snapshot_date"] = datetime.date.today().isoformat()
    # The bytes the vendor served, so "which document was this frozen from" has an exact answer.
    post.metadata["source_sha256"] = source_sha256
    sources = post.metadata.get("sources") or []
    if url not in sources:
        post.metadata["sources"] = [*sources, url]
    certs.save(cert_id, post)

    cert["upstream_status"] = "current"
    cert["last_checked"] = datetime.date.today().isoformat()
    catalog.save(data)

    # The readings are deterministic and cost no model call, so a snapshot takes
    # them along. They are not worth losing the paid extraction over: a page that
    # fails to load leaves the syllabus saved and says so.
    try:
        readings = attach_readings(cert_id)
    except Exception as error:   # noqa: BLE001 — the snapshot is saved; any failure here is reported, not raised
        readings = {"errors": [str(error)]}
    return {
        "cert": cert_id,
        "topics": len(topics),
        "version": post.metadata["version"],
        "added": added,
        "stale": stale,
        "edited_changed": edited_changed,
        "readings": readings,
    }


# ---------------------------------------------------------------- official readings

# What opens a vendor's list of study material for one domain. NVIDIA prints
# "Recommended Training", "Suggested Readings" and "Suggested Reading List"; those
# are the words any study guide uses, so this is not a rule about one vendor.
# NCA-GENL also files its courses under "NVIDIA Course Objectives" / "Course
# reference:", which is the same kind of list under another name.
READING_HEADING = re.compile(
    r"\b(suggested|recommended|further|additional)\s+"
    r"(reading\s+list|readings?|training|resources)\b|"
    r"(\w+\s+)?course\s+(reference|objectives)\b", re.I)

# Characters of prose between two links that mean the list has ended. A reading
# list is one title after another; what follows it — a copyright notice, a footer,
# the next domain's description — is sentences.
READING_GAP = 300

ANCHOR = re.compile(r"<a\b[^>]*?\bhref\s*=\s*([\"'])(.*?)\1[^>]*>(.*?)</a\s*>", re.S | re.I)


# Calls to action sit next to reading lists and are never a reading: the guide's
# "Questions? Contact us here." footer link landed after the last list otherwise.
CALL_TO_ACTION = re.compile(r"^\W*(click\s+here|here)?\W*$|\bcontact\s+us\b|"
                            r"^\W*(register|schedule)\b.*\bexam\W*$", re.I)

BLOCK_TAG = re.compile(r"<(?:/?(?:p|div|li|ul|ol|h[1-6]|tr|td|th|section|br|dt|dd))\b[^>]*>", re.I)


def _plain(fragment: str, lines: bool = False) -> str:
    """Tags stripped, entities decoded, whitespace collapsed — keeping line breaks
    at block elements when `lines`, so a heading is still at the start of a line."""
    if lines:
        fragment = BLOCK_TAG.sub("\n", fragment)
    text = html_lib.unescape(re.sub(r"<[^>]+>", " ", fragment))
    if not lines:
        return re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"[^\S\n]+", " ", text)
    return re.sub(r"\s*\n\s*", "\n", text).strip()


def _opens_reading_list(text: str) -> bool:
    """A reading heading at the start of a line, the way a heading is laid out.

    In running prose ("…certification exam, recommended training, and suggested
    reading to prepare…") the same words introduce nothing, and the guide's cover
    link to the certification portal was filed as a reading because of them."""
    for line in text.split("\n"):
        line = re.sub(r"^[\s>•·*\-–—]+", "", line).strip()
        # A heading is short and is not a sentence. NCP-AII's cover wraps a
        # sentence so that one line *starts* "recommended training and suggested
        # reading to help prepare for the exam." — prose, ending in a full stop.
        if READING_HEADING.match(line) and len(line) <= 100 and not line.endswith("."):
            return True
    return False


def document_stream(url: str, body: bytes, content_type: str) -> list[tuple[str, str, str]]:
    """The document in reading order, links kept: ('text', text, '') and ('link', href, title).

    `document_text` is what the snapshot model reads, and it drops every link: an
    `<a href>` loses its href to the tag stripper and pypdf's text never includes
    the `/URI` annotations at all. That threw away the one part of a study guide
    that says *where to read* — NVIDIA's per-domain Suggested Readings reached the
    generator as nothing, and every topic cited only the study guide PDF (#271).
    """
    if url.lower().endswith(".pdf") or "pdf" in content_type:
        return _pdf_stream(body)
    return _html_stream(body.decode("utf-8", "replace"), url)


# Hrefs that move around the page or leave the web, never a reading.
NAVIGATION = re.compile(r"^(#|javascript:|mailto:|tel:|$)", re.I)


def _html_stream(page: str, base: str = "") -> list[tuple[str, str, str]]:
    # Navigation, header and footer are page furniture: Microsoft Learn's footer
    # ("Privacy", "Terms of Use", "Trademarks") followed AI-901's last reading list
    # with nothing but short link titles in between, so no prose gap closed it.
    page = re.sub(r"<(script|style|noscript|nav|header|footer)\b[^>]*>.*?</\1\s*>", " ", page,
                  flags=re.S | re.I)
    items: list[tuple[str, str, str]] = []
    last = 0
    for match in ANCHOR.finditer(page):
        text = _plain(page[last:match.start()], lines=True)
        if text:
            items.append(("text", text, ""))
        href, title = html_lib.unescape(match.group(2)).strip(), _plain(match.group(3))
        # Relative links are readings too: Microsoft Learn's "Additional resources"
        # are all `/en-us/azure/...`, so keeping only absolute ones dropped them.
        absolute = "" if NAVIGATION.match(href) else urljoin(base, href)
        if absolute.startswith(("http://", "https://")):
            items.append(("link", absolute, title))
        elif title:
            items.append(("text", title, ""))   # an in-page anchor is navigation, not a source
        last = match.end()
    tail = _plain(page[last:], lines=True)
    if tail:
        items.append(("text", tail, ""))
    return items


BULLET = re.compile(r"^[\s>•·*\-–—]+")


def _pdf_page_items(fragments: list[tuple[float, float, str]],
                    links: list[tuple[float, float, float, float, str]]) -> list[tuple[str, str, str]]:
    """One page in reading order: text fragments (x, y, text) and link rectangles
    (x0, x1, y_low, y_high, uri).

    A PDF link is an annotation drawn over the page, not part of the text, so the
    only thing tying it to its title is position. The title is the list item the
    box sits on: the whole line when the line holds one link, the link's column
    when a two-column guide puts two readings side by side, plus the next line
    when the title wraps (a continuation does not start with the list's bullet).
    The box itself is no guide to the title's extent: NCA-GENL's boxes often
    cover only ", NVIDIA Blog", the publisher after the title."""
    # Lines keep the order the page draws them; a superscript (the ™ in "DGX
    # SuperPOD™ Reference Architecture") sits a few points higher and must stay
    # on its line, or it becomes a "line" of its own that takes the link.
    lines: list[list] = []                         # [y, [[x, text, used], ...]]
    for x, y, text in fragments:
        line = next((l for l in lines if abs(l[0] - y) < 4), None)
        if line:
            line[1].append([x, text, False])
        else:
            lines.append([y, [[x, text, False]]])
    lines.sort(key=lambda l: -l[0])
    for line in lines:
        line[1].sort(key=lambda f: f[0])

    def on(link, line):
        # A baseline sits inside its box, below the top edge: the line above a
        # wrapped title's second box touches that box's top and is not under it.
        return link[2] - 2 <= line[0] <= link[3] - 2

    def clean(text: str) -> str:
        return BULLET.sub("", re.sub(r"\s+([,.;:])", r"\1", re.sub(r"\s+", " ", text))).strip()

    rows: list[tuple[float, tuple[str, str, str]]] = []
    for link in links:
        own = [n for n, line in enumerate(lines) if on(link, line)]
        if not own:                                 # an image or an empty box: keep the order
            rows.append((link[3], ("link", link[4], "")))
            continue
        line = lines[own[0]]
        # The column this link's item occupies. A column starts at its first
        # fragment after the previous box — the bullet sits a few points left of
        # the box (NCA-GENL: text at x=294, box at 303) — and ends where the next
        # column starts. The two columns' baselines can differ by a few points, so
        # "beside" is any box on any line this box covers.
        starts = sorted({l[0] for l in links if any(on(l, lines[n]) for n in own)})
        xs = [f[0] for n in own for f in lines[n][1]]

        def col_start(box: float) -> float:
            previous = [b for b in starts if b < box - 3]
            floor = previous[-1] + 3 if previous else float("-inf")
            return min([x for x in xs if floor < x <= box + 3] or [box])

        later = [b for b in starts if b > link[0] + 3]
        left = col_start(link[0]) if len(starts) > 1 else float("-inf")
        right = col_start(later[0]) if later else float("inf")

        def column(frags):
            return [f for f in frags if left <= f[0] < right]

        pieces = [f for n in own for f in column(lines[n][1])]
        if not pieces:                              # one fragment spans both columns
            pieces = [f for n in own for f in lines[n][1]]
        bulleted = bool(BULLET.match(pieces[0][1])) if pieces else False
        after = own[-1] + 1
        if bulleted and after < len(lines) and lines[own[-1]][0] - lines[after][0] < 16 \
                and not any(on(l, lines[after]) and left <= l[0] < right for l in links):
            more = column(lines[after][1]) or (lines[after][1] if len(starts) == 1 else [])
            if more and not BULLET.match(more[0][1]):
                pieces += more
        for f in pieces:
            f[2] = True
        rows.append((line[0], ("link", link[4], clean(" ".join(f[1].strip() for f in pieces)))))
    for y, frags in lines:
        text = clean("".join(f[1] for f in frags if not f[2]))
        if text:
            rows.append((y, ("text", text, "")))
    rows.sort(key=lambda r: -r[0])
    # One link drawn as two boxes (a title wrapped onto a second line) is one
    # reading. In two columns the other column's row falls between the two boxes,
    # so "the same link" is the same URI a line or so below, not the next row.
    merged: list[tuple[float, tuple[str, str, str]]] = []
    for y, item in rows:
        above = next((n for n in range(len(merged) - 1, -1, -1)
                      if merged[n][1][0] == "link" and item[0] == "link"
                      and merged[n][1][1] == item[1] and merged[n][0] - y < 20), None)
        if above is None:
            merged.append((y, item))
            continue
        previous = merged[above][1]
        title = previous[2] if item[2] in previous[2] else f"{previous[2]} {item[2]}".strip()
        merged[above] = (merged[above][0], ("link", item[1], title))
    return [item for _, item in merged]


def _drop_running_heads(pages: list[list[tuple[str, str, str]]]) -> list[tuple[str, str, str]]:
    """Join the pages, minus the header or footer line every page repeats.

    The NCA-AIIO guide heads each page "AI Infrastructure and Operations Study
    Guide | 3" — which names a domain, and would hand the next page to it."""
    def key(item):
        return re.sub(r"\d+", "#", item[1]) if item[0] == "text" else None

    # A head or foot is found where it usually sits — first or last on a page —
    # and then dropped wherever it is: on NCA-AIIO's last page a copyright block
    # sits under the footer, which survived and named a domain.
    repeated = set()
    for position in (0, -1):
        seen: dict = {}
        for page in pages:
            if page and key(page[position]):
                seen[key(page[position])] = seen.get(key(page[position]), 0) + 1
        repeated |= {k for k, n in seen.items() if n > 1}
    # A reading heading repeated at the top of two pages is a list continuing,
    # not a running head: dropping it would never open the list.
    repeated = {k for k in repeated if not _opens_reading_list(k)}
    return [item for page in pages for item in page if key(item) not in repeated]


def _pdf_stream(body: bytes) -> list[tuple[str, str, str]]:
    from pypdf import PdfReader

    pages = []
    for page in PdfReader(io.BytesIO(body)).pages:
        fragments: list[tuple[float, float, str]] = []

        def visit(text, cm, tm, *_):
            if text.strip():
                fragments.append((tm[4] * cm[0] + tm[5] * cm[2] + cm[4],
                                  tm[4] * cm[1] + tm[5] * cm[3] + cm[5], text))

        page.extract_text(visitor_text=visit)
        links = []
        for annotation in page.get("/Annots") or []:
            annotation = annotation.get_object()
            action = annotation.get("/A")
            uri = action.get_object().get("/URI") if action is not None else None
            rect = annotation.get("/Rect")
            if uri and rect:
                x0, x1 = sorted((float(rect[0]), float(rect[2])))
                low, high = sorted((float(rect[1]), float(rect[3])))
                links.append((x0, x1, low, high, str(uri)))
        pages.append(_pdf_page_items(fragments, links))
    return _drop_running_heads(pages)


def _name_pattern(name: str) -> re.Pattern:
    """A domain name, tolerant of the plural a vendor drops or adds between documents.

    NVIDIA's NCP-AII page heads domain 1 "System and Server Bring-Up" while the
    syllabus and the PDF say "Systems…": matched verbatim, the page's whole
    domain-1 list was filed under whatever domain came before it."""
    words = []
    for word in name.split():
        # Only a letter before the s makes it a plural: "Cloud's" keeps its
        # apostrophe-s, or the name stops matching itself (gcp-gail).
        plural = len(word) > 2 and word[-1] in "sS" and word[-2].isalpha() and word[-2] not in "sS"
        stem = word[:-1] if plural else word
        words.append(re.escape(stem) + ("s?" if stem[-1:].isalpha() else ""))
    return re.compile(r"(?<!\w)" + r"\s+".join(words) + r"(?!\w)", re.I)


def _domain_markers(topics: list[dict]) -> list[tuple[re.Pattern, re.Pattern | None, str]]:
    """(name pattern, objective-id pattern, domain) per syllabus topic.

    The domain is the syllabus `topic` field ('1 - Essential AI Knowledge'), so the
    vocabulary comes from the frozen syllabus, never from a list kept here. Only a
    dotted id ("2.1") is a marker: LFCS numbers its domains 1 to 5, and a bare
    digit is every page number."""
    markers = []
    for topic in topics:
        domain = str(topic.get("topic") or "").strip()
        if not domain:
            continue
        name = re.sub(r"^\s*[\w.]+\s+-\s+", "", domain)
        tid = str(topic.get("id") or "")
        ident = (re.compile(r"^" + re.escape(tid) + r"(?!\.?\d)") if "." in tid else None)
        markers.append((_name_pattern(name), ident, domain))
    return markers


def _heading_like(line: str) -> bool:
    """Short and not a sentence: how a heading, a tab or a domain title is laid out."""
    return 0 < len(line) <= 120 and not line.endswith(".")


def _domain_of(line: str, markers) -> str | None:
    """The domain a line announces, if it is laid out to announce one.

    A domain's name in a sentence ("…virtualization for accelerated AI
    infrastructure.") is not a section starting; neither is an id in the middle
    of a line. A heading-like line naming the domain, or a line opening with one
    of its objective ids, is."""
    hits = []
    for name, ident, domain in markers:
        if ident is not None and ident.match(line):
            hits.append((len(line), domain))
        elif _heading_like(line):
            hits.extend((m.end(), domain) for m in name.finditer(line))
    return max(hits)[1] if hits else None


def readings_by_domain(stream: list[tuple[str, str, str]], topics: list[dict]) -> dict[str, list[dict]]:
    """The links a study guide lists under each domain's reading heading.

    Readings are published per domain, not per objective — NVIDIA prints one
    list after each domain's objectives — so this assigns each link to the domain
    whose section it sits in. A link counts only inside a reading list: one opens
    at a heading (READING_HEADING), and closes when another domain starts or when
    prose runs longer than READING_GAP — which also forgets the domain, so a list
    after an unrecognised heading is dropped rather than filed under the last
    domain seen. Page navigation, the cover's "can be found here" and the
    footer's contact link are outside every list.
    """
    markers = _domain_markers(topics)
    found: dict[str, list[dict]] = {}
    domain, open_, gap = None, False, 0
    for kind, value, title in stream:
        if kind == "link":
            if open_ and domain and not CALL_TO_ACTION.search(title):
                if all(r["url"] != value for r in found.setdefault(domain, [])):
                    found[domain].append({"title": title, "url": value})
                gap = 0
            continue
        for line in value.split("\n"):
            line = re.sub(r"^[\s>•·*\-–—]+", "", line).strip()
            announced = _domain_of(line, markers)
            if announced and announced != domain:
                domain, open_ = announced, False
            if _opens_reading_list(line):
                open_, gap = True, 0
            elif open_:
                gap += len(line)
                if gap > READING_GAP:
                    open_, domain = False, None
    return {d: items for d, items in found.items() if items}


def _same_reading(a: dict, b: dict) -> bool:
    if a["url"] == b["url"]:
        return True
    ta, tb = (re.sub(r"[^a-z0-9]", "", x["title"].lower()) for x in (a, b))
    short, long_ = sorted((ta, tb), key=len)
    return len(short) >= 20 and long_.startswith(short)


def merge_readings(primary: dict, secondary: dict) -> dict:
    """Readings from two documents, the first one winning on the same title.

    The overview page and the study-guide PDF list the same readings, and the
    page is the one the vendor keeps editing: NVIDIA moved three NCA-AIIO links
    on the page that the January PDF still prints. Same title, different URL
    means the URL moved, so the page's is kept."""
    merged = {domain: list(items) for domain, items in primary.items()}
    for domain, items in secondary.items():
        bucket = merged.setdefault(domain, [])
        bucket.extend(item for item in items if not any(_same_reading(item, kept) for kept in bucket))
    return merged


def _host(url: str) -> str:
    return re.sub(r"^https?://", "", url).split("/")[0].split(":")[0].lower()


def official_domains() -> set[str]:
    """Hosts docs/sources.yaml catalogues: every project's domains plus the neutral ones."""
    path = catalog.root() / "docs" / "sources.yaml"
    if not path.exists():
        return set()
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    hosts = {d.lower() for d in data.get("neutral_domains") or []}
    for project in (data.get("projects") or {}).values():
        hosts |= {d.lower() for d in (project or {}).get("domains") or []}
    return hosts


def attach_readings(cert_id: str) -> dict:
    """Put the vendor's per-domain readings into the frozen syllabus. No model involved.

    Every link the overview page and the objectives document list for a domain is
    recorded under the syllabus' `readings:`. The ones on a host docs/sources.yaml
    catalogues also join the `sources` of every topic in that domain — those are
    what `_topic_context` hands the generator as references. The rest (Medium, a
    LinkedIn post, a vendor's marketing page) stay recorded but out of the prompt:
    the corpus cites primary sources, and a blog the model is told to rely on is
    one it will cite. Catalogue a domain in docs/sources.yaml and the next run
    picks it up.

    `sources` is outside a topic's identity, so this never marks content stale.
    Running it again replaces what the previous run added (the catalogued URLs of
    the previous `readings:`) and keeps anything else in `sources`, including a URL
    a person added that the vendor also lists. If either document cannot be read
    or parsed, nothing is written: half the readings would look like the vendor
    removing the other half.
    """
    data = catalog.load()
    cert = data["certs"].get(cert_id)
    if not cert:
        raise TrackerError(f"'{cert_id}' is not in the catalog")
    sources = cert.get("sources") or {}
    post = certs.load(cert_id)
    topics = post.metadata.get("topics") or []
    if not topics:
        raise TrackerError(f"'{cert_id}' has no syllabus yet: snapshot it first")

    found: dict[str, list[dict]] = {}
    for key in ("overview", "objectives"):            # the page first: it is the one kept current
        url = sources.get(key)
        if not url:
            continue
        try:
            body, content_type = _get_bytes(url)
            stream = document_stream(url, body, content_type)
        except Exception as error:   # fetch or parse (pypdf raises its own types): either way, unread
            raise TrackerError(f"{cert_id}: {key} could not be read ({error}); syllabus left as it was") from error
        found = merge_readings(found, readings_by_domain(stream, topics))

    before = yaml.safe_dump(post.metadata, sort_keys=True)
    official = official_domains()
    added_before = {r["url"] for items in (post.metadata.get("readings") or {}).values() for r in items
                    if _host(r["url"]) in official}
    current = {r["url"] for items in found.values() for r in items}
    objectives = sources.get("objectives")
    for topic in topics:
        kept = [s for s in topic.get("sources") or [] if s not in added_before]
        links = [r["url"] for r in found.get(str(topic.get("topic") or "").strip(), [])
                 if _host(r["url"]) in official]
        topic["sources"] = list(dict.fromkeys((kept or ([objectives] if objectives else [])) + links))

    order = list(dict.fromkeys(str(t.get("topic") or "").strip() for t in topics))
    found = {domain: found[domain] for domain in order if domain in found}
    if found:
        post.metadata["readings"] = found
    else:
        post.metadata.pop("readings", None)
    if yaml.safe_dump(post.metadata, sort_keys=True) != before:   # a no-op leaves the file untouched
        certs.save(cert_id, post)
    return {
        "cert": cert_id,
        "domains": {domain: len(items) for domain, items in found.items()},
        "in_prompt": sorted({u for t in topics for u in t["sources"]} & current),
        "uncatalogued": sorted({_host(u) for u in current} - official),
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
            usage={"op": "paths", "kind": "translate", "lang": lang},
            prompt=f"Textos de paths de carrera (en español):\n"
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
        usage={"op": "paths", "kind": "generate"},
        prompt=f"Catálogo de certificaciones:\n{yaml.safe_dump(summary, allow_unicode=True)}\n\n"
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
