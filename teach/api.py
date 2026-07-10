"""API de la plataforma.

Público (sin login): catálogo, temarios y paths — la landing es referente
de qué certificaciones existen.
Con login + plan activo: el contenido de estudio (temas, ejercicios, labs).

Login por sesión (cookie firmada). v1: admin/admin + suscripción stub.
Docs interactivas en /docs (OpenAPI).
"""

import os
import secrets
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware

from .core import auth, catalog, certs, labs

app = FastAPI(title="teach-plat", version="0.1.0")
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ.get("TEACH_SECRET", secrets.token_hex(32)),
)

WEB_DIR = Path(__file__).parent / "web"


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
        raise HTTPException(status_code=401, detail="Credenciales inválidas")
    request.session["user"] = body.username
    return {"user": body.username, "subscription": auth.has_subscription(body.username)}


@app.post("/api/logout")
def logout(request: Request) -> dict:
    request.session.clear()
    return {"ok": True}


@app.get("/api/me")
def me(user: str = Depends(require_user)) -> dict:
    return {"user": user, "subscription": auth.has_subscription(user)}


# --- público: el landscape de certificaciones es la carta de presentación ---

@app.get("/api/catalog")
def get_catalog() -> dict:
    return catalog.list_certs()


@app.get("/api/paths")
def get_paths(lang: str = certs.DEFAULT_LANG) -> dict:
    """Paths con textos en el idioma pedido (i18n mergeado; fallback al default)."""
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


def _valid_lang(lang: str) -> str:
    if lang not in certs.LANGS:
        raise HTTPException(status_code=400, detail=f"Idioma inválido. Válidos: {certs.LANGS}")
    return lang


@app.get("/api/langs")
def get_langs() -> dict:
    return {"langs": certs.LANGS, "default": certs.DEFAULT_LANG}


@app.get("/api/certs/{cert_id}")
def get_cert(cert_id: str) -> dict:
    try:
        entry = catalog.get_cert(cert_id)
        topic_list = certs.topics(cert_id)
    except (KeyError, FileNotFoundError) as error:
        raise HTTPException(status_code=404, detail=str(error))
    # el temario es público; el estado interno de generación no se expone,
    # se traduce a disponibilidad (+ en qué idiomas existe el material)
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
    """Teaser público: primeras líneas del material + qué incluye el tema."""
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


@app.get("/healthz")
def healthz() -> dict:
    """Liveness/readiness para Kubernetes."""
    return {"ok": True, "certs": len(catalog.list_certs())}


@app.get("/")
def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html")
