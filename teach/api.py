"""Platform API.

Public (no login): catalog, syllabi and paths — the landing page is the
reference for which certifications exist.

Auth is disabled (v1). The login/logout endpoints exist but always deny —
ready for OIDC plus a payment gateway to be plugged in when implemented.
Interactive docs at /docs (OpenAPI).
"""

import os
import secrets
from functools import lru_cache
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict
from starlette.middleware.sessions import SessionMiddleware

from .core import auth, bot_stats, catalog, certs, corpus, labs, models_live

app = FastAPI(title="teach-plat", version="0.1.0")
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ.get("TEACH_SECRET", secrets.token_hex(32)),
)

WEB_DIR = Path(__file__).parent / "web"
MEDIA_DIR = catalog.root() / "media"
if MEDIA_DIR.is_dir():
    app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")


class LoginBody(BaseModel):
    username: str
    password: str


def require_user(request: Request) -> str:
    user = request.session.get("user")
    if not user:
        raise HTTPException(status_code=401, detail="No autenticado")
    return user


def require_subscriber(request: Request) -> str:
    user = require_user(request)
    if not auth.has_subscription(user):
        raise HTTPException(
            status_code=402, detail="Se requiere un plan activo para estudiar"
        )
    return user


@app.post("/api/login")
def login(body: LoginBody, request: Request) -> dict:
    if not auth.authenticate(body.username, body.password):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    request.session["user"] = body.username
    return {"user": body.username, "subscription": auth.has_subscription(body.username)}


@app.post("/api/logout")
def logout(request: Request) -> dict:
    request.session.clear()
    return {"ok": True}


@app.get("/api/me")
def me(user: str = Depends(require_user)) -> dict:
    return {"user": user, "subscription": auth.has_subscription(user)}


# --- public: the certification landscape is the shop window ---

@app.get("/api/catalog")
def get_catalog() -> dict:
    """Every certification: name, exam, vendor, level, validity and official sources."""
    return catalog.list_certs()


@app.get("/api/paths")
def get_paths(lang: str = certs.DEFAULT_LANG) -> dict:
    """Career paths with their steps, in the requested language (falls back to the default)."""
    _valid_lang(lang)
    paths = catalog.load().get("paths", {})
    if lang == certs.DEFAULT_LANG:
        return paths
    merged = {}
    for slug, path in paths.items():
        translated = (path.get("i18n") or {}).get(lang) or {}
        merged[slug] = {
            **{k: v for k, v in path.items() if k != "i18n"},
            **translated,
        }
    return merged


def _video_info(rel_dir: str, lang: str) -> dict:
    """Info about a video (path or cert) if it has been generated: URL of the
    mp4 served from /media. When there is no video in the requested language it
    falls back to the default one (today Piper only has voices for es/en/de/zh)
    rather than hiding a video that does exist in another language."""
    _valid_lang(lang)
    base = MEDIA_DIR / rel_dir / lang
    fallback = lang != certs.DEFAULT_LANG and not (base / "video.mp4").exists()
    if fallback:
        lang = certs.DEFAULT_LANG
        base = MEDIA_DIR / rel_dir / lang
    if not (base / "video.mp4").exists():
        return {"available": False}
    thumbnail = base / "thumbnail.png"
    return {
        "available": True,
        "video_url": f"/media/{rel_dir}/{lang}/video.mp4",
        "thumbnail_url": f"/media/{rel_dir}/{lang}/thumbnail.png" if thumbnail.exists() else None,
        "lang_fallback": fallback,
    }


@app.get("/api/paths/{path_slug}/video")
def get_path_video(path_slug: str, lang: str = certs.DEFAULT_LANG) -> dict:
    """A path's video (if it has been generated)."""
    return _video_info(f"paths/{path_slug}", lang)


@app.get("/api/certs/{cert_id}/video")
def get_cert_video(cert_id: str, lang: str = certs.DEFAULT_LANG) -> dict:
    """A single certification's video (if it has been generated)."""
    return _video_info(f"certs/{cert_id}", lang)


def _valid_lang(lang: str) -> str:
    if lang not in certs.LANGS:
        raise HTTPException(status_code=400, detail=f"Invalid language. Valid: {certs.LANGS}")
    return lang


@app.get("/api/langs")
def get_langs() -> dict:
    """Languages the platform supports, and which one material is authored in."""
    return {"langs": certs.LANGS, "default": certs.DEFAULT_LANG}


# What the last out-of-band check found, and when. Module state on purpose: it
# is a cache of a public fact, cheap to rebuild, and worth nothing after a
# restart — exactly the kind of thing that must not acquire a database.
_LIVE: dict = {"findings": {}, "checked_at": None}
LIVE_MAX_AGE = 6 * 3600


def _refresh_live(force: bool = False) -> None:
    """Compare the catalogue against OpenRouter, at most every few hours.

    Never raises and never blocks a student: if OpenRouter is unreachable the
    previous findings stand, and on a cold start that means none — the
    catalogue is served exactly as it is today, which is the degraded behaviour
    we already live with, never a blank page.
    """
    import time

    age = None if _LIVE["checked_at"] is None else time.time() - _LIVE["checked_at"]
    if not force and age is not None and age < LIVE_MAX_AGE:
        return
    try:
        _LIVE["findings"] = models_live.compare(catalog.load_models(),
                                                models_live.upstream())
        _LIVE["checked_at"] = time.time()
    except Exception:                                             # noqa: BLE001
        pass


@app.get("/api/models")
def get_models(background: BackgroundTasks) -> dict:
    """The study bot's model catalogue, from `models.yaml`, plus what is live.

    Served rather than hardcoded in the page so there is one list, versioned
    with the code, checkable by `scripts/check_models.py` against OpenRouter's
    live API. The first draft of the bot had invented model ids in JavaScript;
    a catalogue nobody can verify is how that happens twice.

    The frozen numbers are what the probe measured against and they stay; the
    live ones arrive beside them as `live_in`/`live_out`/`gone`, so the page can
    say a price moved instead of silently swapping it. The comparison runs in a
    background task — a student's request never waits on openrouter.ai, and a
    slow or unreachable provider costs this endpoint nothing.

    Phase 1.5 of docs/STUDY_BOT_DESIGN.md: automate the guard, never the
    decision. Which model should replace one that vanished is a judgement call
    against the criteria in models.yaml, and nothing here edits that file.
    """
    background.add_task(_refresh_live)
    served = models_live.annotate(catalog.load_models(), _LIVE["findings"])
    served["live_checked"] = bool(_LIVE["checked_at"])
    return served


@app.get("/api/status")
def get_status() -> list:
    """Per-certification overview: exam versions, coverage, videos, freshness.

    The tree is the single source of truth; this endpoint and STATUS.md are
    two projections of the SAME functions, so they cannot disagree on
    definitions — only on timing, which the dates in each row make visible:
    versions come from `check_versions.survey()` (the function that renders
    STATUS.md's "Exam versions" table), and a language counts only when every
    topic's content passes the same quality floor STATUS.md counts with.
    Cached after the first request: the tree inside a deployed image is
    immutable, so recomputing would only re-prove the same answer.
    """
    return _status_snapshot()


@lru_cache(maxsize=1)
def _status_snapshot() -> list:
    import sys
    scripts_dir = str(catalog.root() / "scripts")
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    from check_versions import survey
    from teach.core import quality
    versions = {row["cert"]: row for row in survey()}
    out = []
    for cert_id, cert in catalog.list_certs().items():
        try:
            topic_list = certs.topics(cert_id)
        except Exception:
            topic_list = []
        ids = {str(t["id"]) for t in topic_list}
        cert_dir = catalog.root() / "certs" / cert_id
        langs = []
        if ids:
            for lang in certs.LANGS:
                files = [cert_dir / tid / lang / "content.md" for tid in ids]
                if all(f.exists() and not quality.check_file(f) for f in files):
                    langs.append(lang)
        video_dir = MEDIA_DIR / "certs" / cert_id
        videos = sorted(p.parent.name for p in video_dir.glob("*/video.mp4"))
        v = versions.get(cert_id, {})
        out.append({
            "id": cert_id,
            "name": cert.get("name"),
            "exam": cert.get("exam"),
            "vendor": cert.get("vendor"),
            "level": cert.get("level"),
            "validity": cert.get("validity"),
            "topics": len(ids),
            "generated": sum(1 for t in topic_list if t.get("status") == "generated"),
            "langs": langs,
            "videos": videos,
            "built_on": v.get("version"),
            "snapshot": v.get("snapshot"),
            "upstream": v.get("upstream_version"),
            "upstream_changed": v.get("upstream_changed"),
            "checked": v.get("last_checked"),
            "state": v.get("state"),
        })
    return out


@app.get("/api/certs/{cert_id}")
def get_cert(cert_id: str) -> dict:
    """One certification: catalogue entry, syllabus and which topics have material."""
    try:
        entry = catalog.get_cert(cert_id)
        topic_list = certs.topics(cert_id)
    except (KeyError, FileNotFoundError) as error:
        raise HTTPException(status_code=404, detail=str(error))
    # The syllabus is public; the internal generation status is not exposed,
    # it is translated into availability (+ which languages the material exists in)
    public_topics = [
        {
            "id": t.get("id"),
            "title": t.get("title"),
            "topic": t.get("topic"),
            "weight": t.get("weight"),
            "available": t.get("status") in ("generated", "edited"),
            "langs": certs.topic_langs(cert_id, str(t.get("id"))),
        }
        for t in topic_list
    ]
    return {"cert": entry, "topics": public_topics}


@app.get("/api/certs/{cert_id}/topics/{topic_id}/preview")
def get_topic_preview(cert_id: str, topic_id: str, lang: str = certs.DEFAULT_LANG) -> dict:
    """Public teaser: first lines of the material + what the topic includes."""
    _valid_lang(lang)
    try:
        topic = certs.get_topic(cert_id, topic_id)
    except (KeyError, FileNotFoundError) as error:
        raise HTTPException(status_code=404, detail=str(error))
    content = certs.topic_content(cert_id, topic_id, lang=lang)
    text = content["content"] or ""
    return {
        "topic": {
            "id": topic.get("id"),
            "title": topic.get("title"),
            "weight": topic.get("weight"),
        },
        "preview": text[:1200],
        "lang": content["lang"],
        "lang_fallback": content["lang_fallback"],
        "includes": {
            "content_lines": len(text.splitlines()),
            "has_exercises": bool(content["exercises"]),
            "has_lab": bool(content["break_fix"]),
        },
    }


# --- zona de estudio: login + plan activo ---

@app.get("/api/certs/{cert_id}/topics/{topic_id}")
def get_topic(
    cert_id: str,
    topic_id: str,
    lang: str = certs.DEFAULT_LANG,
) -> dict:
    """A topic's material: content, exercises, lab, and the provenance of what is served."""
    _valid_lang(lang)
    try:
        topic = certs.get_topic(cert_id, topic_id)
    except (KeyError, FileNotFoundError) as error:
        raise HTTPException(status_code=404, detail=str(error))
    return {
        "topic": topic,
        **certs.topic_content(cert_id, topic_id, lang=lang),
        "lab_status": labs.status(cert_id, topic_id),
    }


@app.get("/api/search")
def get_search(q: str, cert: str | None = None,
               limit: int = corpus.DEFAULT_LIMIT) -> dict:
    """Which topics mention this — the fourth function of the study contract.

    The other three already had endpoints (`/api/catalog`, `/api/certs/{id}`,
    `/api/certs/{id}/topics/{tid}`); this is the one that was missing, and phase
    2 of the bot plus the MCP server of phase 3 both call it.

    Keyword search over 726 syllabus entries: no embeddings, no index to build,
    no service to run. Retrieval here is over a catalogue already keyed by
    (cert, topic, lang), and every hit carries `why` it matched so a caller can
    show its work instead of asserting relevance.
    """
    return {"query": q, "cert": cert, "hits": corpus.search_topics(q, cert, limit)}


class BotUsage(BaseModel):
    """What the page reports after an answer. Six closed-set fields, no more.

    Pydantic is the first gate and `bot_stats.accepted` the second: this one
    rejects a malformed body, that one rejects a value outside the catalogue.

    `extra="forbid"` is the point of the first gate. Without it an unknown field
    is dropped silently, which is safe but only by accident — a future bug in
    the page could put the student's key in the body and the server would accept
    the request, and whatever logs requests would see it. Forbidding extras
    means a body carrying anything beyond these six is refused outright.
    """

    model_config = ConfigDict(extra="forbid")

    model: str
    tier: str
    intent: str
    material: str
    reasoning: str
    lang: str


@app.post("/api/bot/used")
def post_bot_used(usage: BotUsage) -> dict:
    """Count one bot answer, anonymously and only if the student left it on.

    The page sends this AFTER an answer arrives, fire-and-forget, and only while
    the "share which models I used" box is ticked. It carries no key, no
    question, no answer, no topic, no identifier and no cookie — see the module
    docstring in `teach/core/bot_stats.py` for why the data is shaped as
    counters rather than rows, which is the part that makes it anonymous by
    construction rather than by promise.

    Deliberately not a 4xx when the body is rejected: the caller is a page that
    cannot act on the difference, and an endpoint that reports which values it
    accepts is an endpoint that can be probed for them.
    """
    import datetime

    counted = bot_stats.record(usage.model_dump(),
                               datetime.date.today().isoformat())
    return {"counted": counted}


@app.get("/api/bot/stats")
def get_bot_stats() -> dict:
    """The counters, as they are. Public, because the page that shows them is.

    Soft numbers on purpose: the endpoint above is unauthenticated and
    anonymous, so anyone can post to it and we cannot deduplicate without the
    identity we chose not to have. Whatever renders this has to say so.
    """
    return bot_stats.load()


@app.get("/healthz")
def healthz() -> dict:
    """Liveness/readiness para Kubernetes."""
    return {"ok": True, "certs": len(catalog.list_certs())}


@app.get("/")
def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html")
