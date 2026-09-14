"""Which models the study bot is used with — counters, never events.

The bot runs entirely in the student's browser: the question, the key and the
answer go straight to openrouter.ai and this server never sees them. That is
what makes the bot free to run, and it is also why nothing here can be derived
from traffic — if we want to know which models get used, the page has to say so.

WHAT MAKES THIS SAFE IS THE SHAPE OF THE DATA, NOT A PROMISE ABOUT IT.

Storing rows — `{model, at}` — would be a log, and on a site with this much
traffic a rare model at a known minute correlates with a person. So there are no
rows. Every write is `+= 1` on a counter that already existed, the key space is
fixed by the catalogue, and no timestamp is kept per request. There is no event
to correlate because no event is ever written. "We promise not to look" is a
policy; "there is nothing to look at" is a design.

What the page sends, and nothing else:

    model, tier, intent, material, reasoning, lang

All six are closed sets, validated here against `models.yaml` and the enums the
page itself offers. An unknown value is REJECTED rather than stored: that keeps
the file bounded (18 models × a handful of enums, a few KB forever) and closes
the endpoint as a covert channel — it can hold nothing an attacker chooses.

Never stored, never received: the OpenRouter key, the question, the answer, the
certification or topic being studied, any identifier, any cookie, any IP.

The counts are SOFT and the page that shows them has to say so. The endpoint is
unauthenticated and anonymous by construction, so anyone can post to it and we
cannot deduplicate without the identity we deliberately do not have. It is a
directional signal about which models people reach for; it is not analytics, and
no decision that deserves rigour should rest on it.
"""
from __future__ import annotations

import json
import os
import threading
from pathlib import Path

from . import catalog, certs

# The enums the page offers. Kept here rather than inferred, so an unexpected
# value is a rejected write instead of a new key in the file.
TIERS = {"top", "mid", "low", "free"}
INTENTS = {"explain", "exercise", "quiz", "exam", "free"}
MATERIAL = {"content", "both", "none"}
REASONING = {"off", "low", "medium", "high"}

_LOCK = threading.Lock()


def path() -> Path:
    """Where the counters live. A PVC in the cluster, the repo root locally."""
    return Path(os.environ.get("TEACH_BOT_STATS")
                or catalog.root() / "bot-stats.json")


def _blank() -> dict:
    return {"since": None, "answers": 0, "models": {}}


def load() -> dict:
    try:
        data = json.loads(path().read_text())
    except Exception:                                             # noqa: BLE001
        return _blank()
    return data if isinstance(data, dict) and "models" in data else _blank()


def _known_models() -> set[str]:
    return {m["id"] for tier in (catalog.load_models().get("tiers") or {}).values()
            for m in tier}


def accepted(event: dict) -> dict | None:
    """The event as it will be counted, or None if any field is not ours.

    Whole-event rejection rather than per-field cleaning: a request with one
    field we do not recognise is a request we do not understand, and guessing
    what the other five meant is how a bounded key space stops being bounded.
    """
    model = event.get("model")
    if model not in _known_models():
        return None
    clean = {"model": model}
    for field, allowed in (("tier", TIERS), ("intent", INTENTS),
                           ("material", MATERIAL), ("reasoning", REASONING)):
        value = event.get(field)
        if value not in allowed:
            return None
        clean[field] = value
    lang = event.get("lang")
    if lang not in set(certs.LANGS):
        return None
    clean["lang"] = lang
    return clean


def record(event: dict, today: str) -> bool:
    """Count one answer. Returns whether it was accepted. Never raises.

    `today` is the only date written, and only as `since` on the file as a
    whole — a "counting since" line for the page, not a per-request timestamp.
    """
    clean = accepted(event)
    if clean is None:
        return False
    try:
        with _LOCK:
            data = load()
            data["since"] = data.get("since") or today
            data["answers"] = int(data.get("answers") or 0) + 1
            entry = data["models"].setdefault(
                clean["model"], {"count": 0, "tier": clean["tier"],
                                 "intent": {}, "material": {},
                                 "reasoning": {}, "lang": {}})
            entry["count"] += 1
            entry["tier"] = clean["tier"]
            for field in ("intent", "material", "reasoning", "lang"):
                entry[field][clean[field]] = entry[field].get(clean[field], 0) + 1
            _write(data)
        return True
    except Exception:                                             # noqa: BLE001
        # Telemetry that can break an answer is worse than no telemetry — the
        # same rule usage.jsonl follows in generator.py.
        return False


def _write(data: dict) -> None:
    """Atomic replace, so a crash mid-write cannot leave a truncated file."""
    target = path()
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    tmp.replace(target)
