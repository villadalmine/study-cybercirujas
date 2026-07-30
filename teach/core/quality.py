"""Quality floor for generated material, identical for every backend.

A different backend must not mean a different standard. This used to be split
and uncoordinated: the generator accepted any response over 400 bytes while the
audit rejected anything under 1500. A 500-byte topic passed the generator, was
written to disk, got marked `generated`, and only afterwards did the audit call
it corrupt. Two standards in two places — the same class of problem as the two
target lists.

The thresholds now live in pipeline.yaml and both read them.
"""
from __future__ import annotations

import re

from . import pipeline

# Filename -> key in pipeline.yaml. Material is validated for what it is, not
# for its language: a thin topic in Japanese is as thin as one in Spanish.
KINDS = {"content.md": "content", "exercises.md": "exercises"}


def rules(kind: str) -> dict:
    """Rules for 'content' or 'exercises'. With no `quality` block in the YAML
    there are no rules and everything passes — the floor is optional, not a
    prerequisite for the pipeline to run."""
    return dict((pipeline.load().get("quality") or {}).get(kind) or {})


def check(kind: str, text: str) -> list[str]:
    """Return the problems found. An empty list means the floor is met.

    `kind` is 'content' or 'exercises'. This does not measure whether material
    is *good* — that does not automate — but whether it has the minimum size
    and the structure the prompt itself asked for. A floor, not a grade.
    """
    spec = rules(kind)
    if not spec:
        return []

    problems: list[str] = []
    stripped = (text or "").strip()

    min_bytes = spec.get("min_bytes")
    if min_bytes and len(stripped.encode("utf-8")) < int(min_bytes):
        problems.append(
            f"{len(stripped.encode('utf-8'))} bytes, below the {min_bytes} minimum"
        )

    prefix = spec.get("starts_with")
    if prefix and not stripped.startswith(str(prefix)):
        problems.append(f"does not start with {prefix!r}")

    for requirement in spec.get("requires") or []:
        pattern = requirement.get("pattern")
        if not pattern:
            continue
        if not re.search(pattern, stripped, re.IGNORECASE | re.MULTILINE):
            problems.append(f"missing {requirement.get('description') or pattern}")

    return problems


def check_file(path) -> list[str]:
    """Same as `check`, resolving the kind from the filename. A file that
    cannot be read is reported as a problem rather than assumed healthy: if
    compliance cannot be proven, it is not met."""
    kind = KINDS.get(getattr(path, "name", ""))
    if kind is None:
        return []
    try:
        return check(kind, path.read_text(errors="replace"))
    except OSError as error:
        return [f"unreadable: {error}"]
