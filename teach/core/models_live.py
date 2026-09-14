"""Is the catalogue still true right now? — checked out of band, never in the request.

`models.yaml` is frozen on purpose: it is what we decided to offer and what the
probe measured, and a catalogue that refreshes itself in place destroys the
comparison it exists to enable. But frozen means it can go stale, and a stale
catalogue misleads the student in the one place it hurts — the price they pick a
model by.

That is not hypothetical. The weekly CronJob found `deepseek-v4-pro` at
$1.60/$3.20 against the $0.9553/$1.9105 the page was showing — 67% more than a
student choosing it for the price was told — and said so to a pod log nobody
reads. The finding existed for days and reached no one.

So the guard moves to where the page is. `refresh()` compares the catalogue
against OpenRouter's public model list and returns what it found; `annotate()`
folds that onto the served catalogue as `live_in` / `live_out` / `gone`. The API
calls it on a timer, never inside a student's request.

WHAT IS AUTOMATED AND WHAT IS NOT. Protecting the student is automatic: do not
present a model that no longer exists, do not show a price that is wrong. What
model should REPLACE a vanished one is a judgement call against the criteria at
the top of `models.yaml` — general purpose over domain-tuned, a known family
over an unknown provider — and getting that wrong is how a finance-tuned model
ends up teaching Kubernetes. This module never edits the catalogue. It annotates
a copy, in memory, and a human still decides.

Free: the models endpoint is public, needs no key and spends no quota, which is
why it can run on a timer at all.
"""
from __future__ import annotations

import copy

import httpx

API = "https://openrouter.ai/api/v1/models"
# Below this relative move a price change is noise (providers wobble in the
# fourth decimal); above it a student would notice the bill. Same threshold the
# CronJob reports on, because they are the same question asked twice.
PRICE_TOLERANCE = 0.01
TIMEOUT = 30


def upstream(url: str = API) -> dict:
    """{id: model} as OpenRouter publishes it right now. Raises on failure."""
    data = httpx.get(url, timeout=TIMEOUT, follow_redirects=True).json()["data"]
    return {m["id"]: m for m in data}


def per_million(model: dict) -> tuple[float, float]:
    pricing = model.get("pricing") or {}
    return (float(pricing.get("prompt") or 0) * 1e6,
            float(pricing.get("completion") or 0) * 1e6)


def moved(was: float, now: float) -> bool:
    return abs(now - was) > max(was * PRICE_TOLERANCE, 1e-6)


def compare(frozen: dict, live: dict) -> dict:
    """{model id: what upstream says that the catalogue does not}.

    An entry appears only when something is actually different, so an empty
    result means the catalogue is true and the page has nothing to add.
    """
    out: dict[str, dict] = {}
    for models in (frozen.get("tiers") or {}).values():
        for entry in models:
            model = live.get(entry["id"])
            if model is None:
                out[entry["id"]] = {"gone": True}
                continue
            now_in, now_out = per_million(model)
            was_in, was_out = float(entry.get("in") or 0), float(entry.get("out") or 0)
            if moved(was_in, now_in) or moved(was_out, now_out):
                out[entry["id"]] = {"live_in": round(now_in, 4),
                                    "live_out": round(now_out, 4)}
    return out


def annotate(frozen: dict, findings: dict) -> dict:
    """The catalogue as the page should see it. Never mutates the input.

    The frozen numbers stay where they are — they are what the probe measured
    against — and the live ones arrive beside them, so the page can show that a
    price moved rather than silently swapping it. A model reported `gone` keeps
    its entry too: the page needs something to explain, not a gap.
    """
    served = copy.deepcopy(frozen)
    for models in (served.get("tiers") or {}).values():
        for entry in models:
            entry.update(findings.get(entry["id"]) or {})
    return served
