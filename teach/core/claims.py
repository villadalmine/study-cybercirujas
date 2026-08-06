"""Per-topic claims, so several agents can work at once without colliding.

The first version of this was a single global lock: one generation at a time,
full stop. That was right about the danger and wrong about the granularity. Two
runs must never produce the SAME topic — they would overwrite each other and both
pay for it — but two runs on different topics, or different certifications, or
different providers, are simply two agents working. Blocking those wastes
everybody's time and, worse, invites the workaround: an agent that finds the lock
held writes its own orchestrator that does not take it. That happened.

So the unit of exclusion is the topic, not the pipeline:

    with claim("cks", "3.1", "en") as got:
        if not got:
            ...          # someone else has it; take the next one
        ...              # it is yours until the block exits

The lock is advisory and held by an open file descriptor, so it dies with the
process. A crashed run does not leave a topic claimed forever — which a lock file
tested with `exists()` would.
"""
from __future__ import annotations

import contextlib
import fcntl
import os
from collections.abc import Iterator
from pathlib import Path

CLAIM_DIR = Path.home() / ".local" / "state" / "teach-plat" / "claims"


def _path(cert: str, topic: str, lang: str) -> Path:
    safe = f"{cert}--{topic}--{lang}".replace("/", "_")
    return CLAIM_DIR / f"{safe}.lock"


@contextlib.contextmanager
def claim(cert: str, topic: str, lang: str) -> Iterator[bool]:
    """Claim one (cert, topic, lang). Yields False if someone else holds it.

    Never raises on contention: the caller is expected to move on to the next
    topic, not to fail. That is the whole point — parallel agents should drift
    apart naturally rather than queue behind each other.
    """
    CLAIM_DIR.mkdir(parents=True, exist_ok=True)
    handle = _path(cert, topic, lang).open("w")
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        handle.write(f"{os.getpid()}\n")
        handle.flush()
        yield True
    finally:
        handle.close()


def is_claimed(cert: str, topic: str, lang: str) -> bool:
    """Whether someone is working on it right now. Advisory: a topic can be
    claimed between this call and your own claim, which is why the claim itself
    is what decides, not this."""
    path = _path(cert, topic, lang)
    if not path.exists():
        return False
    try:
        with path.open("r+") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        return False
    return False


def active() -> list[tuple[str, str, str]]:
    """What is being worked on right now, across every agent on this machine."""
    if not CLAIM_DIR.exists():
        return []
    found = []
    for path in sorted(CLAIM_DIR.glob("*.lock")):
        parts = path.stem.split("--")
        if len(parts) == 3 and is_claimed(*parts):
            found.append(tuple(parts))  # type: ignore[arg-type]
    return found
