"""The four functions a study agent needs, and the only four it gets.

Phase 2 of the study bot lets the model ask for the topics it needs instead of
being handed one; phase 3 exposes the same ability over MCP so any external
agent can study against this corpus. The design's instruction is to build the
contract ONCE — "the bot's tools and the MCP tools are the same four functions —
design once, ship twice" — so it lives here rather than in either caller.

    list_certs()                        which certifications exist
    get_syllabus(cert)                  its objectives, weights, availability
    get_topic(cert, topic, lang)        the material for one of them
    search_topics(query, cert, limit)   which topics mention something

READ-ONLY, AND NARROW ON PURPOSE. These are handed to a language model that a
student steers, and through MCP to agents nobody here controls. Every one of
them is a pure read of the published corpus: the same material the site already
serves to anyone without a login. Nothing here writes, spends, or reaches a
path that does — which is what makes the MCP half safe to offer at all.

NO EMBEDDINGS, AND NOT FOR LACK OF AMBITION. `search_topics` scans 726 syllabus
entries — titles, domains, ids — which is a few milliseconds and needs no index
to build, no service to run and no similarity threshold to tune. Retrieval here
is over a catalogue already keyed by (cert, topic, lang), and the student
usually names the certification anyway. The design keeps a vector index for the
case that earns it: career-level work across certifications, in phase 3, where
it is one table in a database that does not exist yet rather than four
subsystems that would.
"""
from __future__ import annotations

import re
import unicodedata

from . import catalog, certs

# Enough to answer "which topics mention X" without turning a search into a read
# of the whole corpus.
DEFAULT_LIMIT = 10
MAX_LIMIT = 50


def list_certs() -> list[dict]:
    """Every certification, with enough to choose one and nothing more.

    `topics` and `available` are part of "enough". A certification can be
    catalogued with its syllabus not yet snapshotted — `cba` is, its objectives
    locked in a PDF that needs a human OCR session — and an agent that picks it
    gets an empty list and no idea why. Counting here costs one read and turns a
    dead end into a visible fact.
    """
    out = []
    for cert_id, entry in catalog.list_certs().items():
        if not entry.get("file"):
            continue
        try:
            topics = certs.topics(cert_id)
        except (KeyError, FileNotFoundError):
            topics = []
        out.append({
            "id": cert_id,
            "name": entry.get("name") or cert_id,
            "vendor": entry.get("vendor"),
            "exam": entry.get("exam"),
            "level": entry.get("level"),
            "topics": len(topics),
            "available": sum(1 for t in topics
                             if t.get("status") in ("generated", "edited")),
        })
    return sorted(out, key=lambda c: c["id"])


def get_syllabus(cert: str) -> dict:
    """One certification's objectives: what the model picks from.

    This IS the phase-2 index. For a single certification it is fifteen to forty
    entries — a few hundred tokens — so the model can be shown all of it and
    choose, which beats any retrieval that has to guess what it wanted.
    """
    entry = catalog.get_cert(cert)
    return {
        "cert": cert,
        "name": entry.get("name") or cert,
        "exam": entry.get("exam"),
        "topics": [
            {
                "id": str(t.get("id")),
                "title": t.get("title"),
                "domain": t.get("topic"),
                "weight": t.get("weight"),
                "available": t.get("status") in ("generated", "edited"),
                "langs": certs.topic_langs(cert, str(t.get("id"))),
            }
            for t in certs.topics(cert)
        ],
    }


def get_topic(cert: str, topic: str, lang: str = certs.DEFAULT_LANG) -> dict:
    """The material for one topic: theory, exercises, and where it came from.

    `sources` travels with the content on purpose. An agent that can cite the
    official page the material was written from can be checked; one that cannot
    is asking to be believed.
    """
    content = certs.topic_content(cert, topic, lang)
    meta = content.get("generated_by") or {}
    return {
        "cert": cert,
        "topic": topic,
        "lang": content.get("lang") or lang,
        "lang_fallback": content.get("lang_fallback", False),
        "title": content.get("title"),
        "content": content.get("content") or "",
        "exercises": content.get("exercises") or "",
        "sources": meta.get("sources") or [],
        "generated_by": {"model": meta.get("model"),
                         "generated_at": meta.get("generated_at")},
    }


def _fold(text: str) -> str:
    """Lowercase, accent-stripped, so `Kubernetes` finds `kubernetes` and
    `autenticación` finds `autenticacion` — the corpus is seven languages."""
    stripped = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in stripped if not unicodedata.combining(c)).lower()


def _terms(query: str) -> list[str]:
    return [t for t in re.split(r"[^\w.\-/]+", _fold(query)) if t]


# A term matching more than this share of the searched titles carries no
# information — it is a stopword, whatever language it is in. Measuring that
# beats keeping a stopword list in seven languages, which would be seven lists
# to maintain and would still miss the corpus' own filler ("understand",
# "configure", "manage", which open half the objectives ever written).
STOPWORD_SHARE = 0.2


def _informative(terms: list[str], titles: list[str]) -> list[str]:
    """Drop the terms that match so much of the corpus they cannot rank it.

    All of them are dropped only if that would leave nothing — a search for
    exactly one common word should still answer, just badly, rather than
    silently return empty.
    """
    if not titles:
        return terms
    ceiling = max(1, int(len(titles) * STOPWORD_SHARE))
    kept = [t for t in terms if sum(t in title for title in titles) <= ceiling]
    return kept or terms


def search_topics(query: str, cert: str | None = None,
                  limit: int = DEFAULT_LIMIT) -> list[dict]:
    """Which topics mention this, ranked, with the reason for each hit.

    Scores a term in the title above the same term in the domain name, and an
    exact topic id above both — someone typing "5.2" means the objective, not
    a topic whose title happens to contain that string. `why` travels with every
    hit so the caller can show its work rather than assert relevance.
    """
    terms = _terms(query)
    if not terms:
        return []
    limit = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))

    scanned = []
    for cert_id in ([cert] if cert else [c["id"] for c in list_certs()]):
        try:
            syllabus = get_syllabus(cert_id)
        except (KeyError, FileNotFoundError):
            continue
        for topic in syllabus["topics"]:
            scanned.append((cert_id, syllabus["name"], topic))

    terms = _informative(terms, [_fold(t["title"] or "") for _, _, t in scanned])

    hits = []
    for cert_id, cert_name, topic in scanned:
        title, domain = _fold(topic["title"] or ""), _fold(topic["domain"] or "")
        score, why = 0, []
        for term in terms:
            if term == _fold(topic["id"]):
                score += 10
                why.append(f"id {topic['id']}")
            elif term in title:
                score += 3
                why.append(f"title: {term}")
            elif term in domain:
                score += 1
                why.append(f"domain: {term}")
        if score:
            hits.append({**topic, "cert": cert_id, "cert_name": cert_name,
                         "score": score, "why": ", ".join(why)})

    # Material first among equals: a topic nobody can read is a worse answer
    # than one that exists, however well it matched.
    hits.sort(key=lambda h: (-h["score"], not h["available"], h["cert"], h["id"]))
    return hits[:limit]
