"""Facts about quota, derived from what was recorded — never estimated.

Three scripts needed "how many tokens does a window hold" and two of them
answered it with the same invented constant, 800_000. A number that is guessed
looks exactly like a number that is measured once it is printed in a table, and
a forecast built on it reads as evidence when it is a placeholder.

Everything here is computed from `quota-history.jsonl` and `usage.jsonl`, so the
same tree always gives the same answer, and a claim can be traced to the events
it came from. When there is not enough history, these return None rather than a
default: "not measured" is an answer, and substituting a plausible number for it
is the failure this module exists to remove.
"""
from __future__ import annotations

import datetime
import json
import os
from pathlib import Path

STATE = (Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
         / "teach-plat")
HISTORY = STATE / "quota-history.jsonl"
USAGE = STATE / "usage.jsonl"

# Enough events that the answer is not one lucky window. Below this the caller
# gets None and has to say "not measured" instead of printing a number.
MIN_WINDOWS = 3


def _rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def limit_kind(detail: str) -> str:
    """What the API said the limit was: spend | weekly | session.

    Read from the message, not inferred from how long it lasted. A monthly spend
    ceiling and a session window both present as "exhausted" and behave
    oppositely: one refills in hours by itself, the other does not refill until
    the month rolls over or the ceiling is raised.
    """
    text = (detail or "").lower()
    if "spend limit" in text or "monthly" in text:
        return "spend"
    if "weekly" in text:
        return "weekly"
    return "session"


def exhaustions() -> list[dict]:
    """Every recorded block, with its kind and when it started and ended.

    Deterministic: derived by walking the history in order, so the same file
    always produces the same list.
    """
    rows = sorted(_rows(HISTORY), key=lambda r: str(r.get("at", "")))
    runs, state, start, detail = [], None, None, ""
    for row in rows:
        status = row.get("status")
        if status != state:
            if state == "exhausted" and start:
                runs.append({"kind": limit_kind(detail), "from": start,
                             "to": row.get("at"), "detail": detail})
            state, start, detail = status, row.get("at"), str(row.get("detail") or "")
        elif status == "exhausted" and limit_kind(detail) == "session":
            # Keep the most specific message seen during one block: the first
            # probe of a spend ceiling sometimes reports generically.
            detail = str(row.get("detail") or detail)
    if state == "exhausted" and start:
        runs.append({"kind": limit_kind(detail), "from": start, "to": None,
                     "detail": detail})
    return runs


def tokens_per_window() -> int | None:
    """Output tokens produced between one exhaustion and the next. Median.

    This is what a quota window actually holds ON THIS MACHINE with the models
    it has been using — not a published figure and not a guess. It moves when the
    model changes, which is exactly why it must be measured rather than fixed.

    None when fewer than MIN_WINDOWS windows have been observed.
    """
    blocks = [b for b in exhaustions() if b["kind"] == "session" and b["to"]]
    if len(blocks) < MIN_WINDOWS:
        return None
    usage = sorted(_rows(USAGE), key=lambda r: str(r.get("at", "")))
    if not usage:
        return None

    totals = []
    for previous, following in zip(blocks, blocks[1:]):
        begin, end = previous["to"], following["from"]
        produced = sum(int(r.get("output_tokens") or 0) for r in usage
                       if begin <= str(r.get("at", "")) < end)
        if produced:
            totals.append(produced)
    if len(totals) < MIN_WINDOWS - 1:
        return None
    totals.sort()
    return int(totals[len(totals) // 2])


def cooldown_until() -> datetime.datetime | None:
    """When it is worth attempting generation again, or None to attempt now.

    A spend ceiling does not refill by waiting the way a session window does, so
    retrying every 20 minutes spends a full generation attempt — a quarter hour
    at the current settings — to rediscover the same refusal. The probe cannot
    tell: it is a two-token call and passes while real work is refused.

    The wait is the median observed duration of past spend blocks, so it is
    derived from this machine's history rather than picked. With no history it
    returns None: doing nothing is better than inventing a delay.
    """
    blocks = [b for b in exhaustions() if b["kind"] == "spend"]
    if not blocks:
        return None
    last = blocks[-1]
    if last["to"] is None:
        finished = []
    else:
        finished = blocks[:-1]
    durations = []
    for block in blocks:
        if not block["to"]:
            continue
        try:
            begin = datetime.datetime.fromisoformat(block["from"])
            end = datetime.datetime.fromisoformat(block["to"])
        except (TypeError, ValueError):
            continue
        durations.append((end - begin).total_seconds())
    if not durations:
        return None
    durations.sort()
    median = durations[len(durations) // 2]

    try:
        began = datetime.datetime.fromisoformat(last["from"])
    except (TypeError, ValueError):
        return None
    resume = began + datetime.timedelta(seconds=median)
    return resume if resume > datetime.datetime.now() else None
