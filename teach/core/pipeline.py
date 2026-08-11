"""Reader for pipeline.yaml — the declarative definition of what the content
pipeline should produce.

Exists so that no script keeps its own copy of "which certs in which
languages". Two scripts used to, and both drifted out of sync with reality
without anything failing: the audit reported "0 corrupt" for combos it had
simply never been told about. One list, one place.
"""
from __future__ import annotations

import functools
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
PIPELINE_FILE = REPO / "pipeline.yaml"


class PipelineError(RuntimeError):
    pass


@functools.cache
def load(path: Path | None = None) -> dict:
    file = path or PIPELINE_FILE
    try:
        data = yaml.safe_load(file.read_text())
    except FileNotFoundError as error:
        raise PipelineError(f"No pipeline definition at {file}") from error
    if not isinstance(data, dict):
        raise PipelineError(f"{file} must contain a mapping")
    return data


def default_languages() -> list[str]:
    return list(load().get("languages", {}).get("default") or [])


def on_demand_languages() -> list[str]:
    return list(load().get("languages", {}).get("on_demand") or [])


def budget() -> dict:
    return dict(load().get("budget") or {})


def topics_per_run() -> int:
    """Maximum topics one invocation may generate. 0 means unbounded, which is
    deliberately not the default — an unbounded run can exhaust a monthly quota
    part-way through a certification."""
    return int(budget().get("topics_per_run") or 0)


def is_fatal(message: str) -> bool:
    """True for errors where retrying cannot help (quota exhausted), as opposed
    to transient ones (529 Overloaded) that are worth another attempt."""
    text = (message or "").lower()
    return any(marker.lower() in text for marker in budget().get("fatal_errors") or [])


def is_retryable(message: str) -> bool:
    text = (message or "").lower()
    return any(marker.lower() in text for marker in budget().get("retry_errors") or [])


def milestone() -> dict:
    """The bounded goal the unattended timer is working toward, or {}.

    The timer used to derive its queue from every active certification, which
    means it works until nothing is pending — and "nothing is pending" is not a
    state this repository reaches: re-snapshotting seven syllabi put 162 topics
    back in the queue in one commit, and the timer would have started on all of
    them overnight without anyone choosing that.

    A milestone is the opposite shape: a named, finite thing to finish. The timer
    works only inside it and stops when it is met, so leaving the machine running
    has a defined end instead of an open-ended spend.

    Empty is the safe default and means the timer generates nothing at all — an
    unset goal must not read as "everything".
    """
    return dict(load().get("milestone") or {})


def milestone_targets() -> list[tuple[str, list[str]]] | None:
    """[(cert, [langs])] for the milestone, or None when none is declared.

    None and [] mean different things and both matter: None is "no goal set, do
    nothing", [] would be "a goal that names no work", and returning the full
    target list for either is how an unattended process quietly becomes unbounded.
    """
    goal = milestone()
    declared = goal.get("targets")
    if not declared:
        return None
    return [(cert, list(langs) if langs else languages_for(cert))
            for cert, langs in declared.items()]


def in_milestone(cert_id: str, lang: str) -> bool:
    """Is this cert/language part of the declared goal?"""
    targets_ = milestone_targets()
    if targets_ is None:
        return False
    return any(cert == cert_id and lang in langs for cert, langs in targets_)


def certs(active_only: bool = True) -> dict[str, dict]:
    """Certifications declared in the pipeline, as {cert_id: config}."""
    declared = load().get("certs") or {}
    out = {}
    for cert_id, config in declared.items():
        config = config or {}
        if active_only and not config.get("active"):
            continue
        out[cert_id] = config
    return out


def languages_for(cert_id: str) -> list[str]:
    """Languages a certification is expected to have. A per-cert `languages`
    key replaces the default tier entirely rather than extending it, so the
    intent for any one cert is readable in one place."""
    config = (load().get("certs") or {}).get(cert_id) or {}
    return list(config.get("languages") or default_languages())


def targets(active_only: bool = True) -> list[tuple[str, list[str]]]:
    """[(cert_id, [langs]), ...] — what the audit and the unattended resume
    script both work from."""
    return [(cert_id, languages_for(cert_id)) for cert_id in certs(active_only)]


def video_languages(cert_id: str) -> list[str]:
    config = (load().get("certs") or {}).get(cert_id) or {}
    return list(config.get("video") or [])


def path_video_languages() -> list[str]:
    return list((load().get("paths") or {}).get("video_languages") or [])


def owner(cert_id: str) -> str:
    """Which agent takes this certification by default; 'any' if unassigned.

    NOT a lock — teach/core/claims.py is what prevents two runs colliding on a
    topic. This exists so two agents do not spend two quota windows producing the
    same certification, and it is in YAML rather than prose because prose did not
    hold: a stale line in AGENTS_SYNC.md outlived the split that replaced it, and
    the other agent correctly followed what was written.
    """
    config = (load().get("certs") or {}).get(cert_id) or {}
    return str(config.get("owner") or "any")


def me() -> str:
    """This agent's name, from TEACH_AGENT. Unset means 'claude' — the historical
    default, so nothing changes for a plain checkout."""
    import os
    return os.environ.get("TEACH_AGENT", "claude")


def mine(cert_id: str) -> bool:
    who = owner(cert_id)
    return who in ("any", me())
