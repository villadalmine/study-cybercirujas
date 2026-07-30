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
