"""The quality score: weights, the arithmetic, and the level (docs/PRINCIPLES.md -> The source chain).

The checks themselves run in scripts/quality_score.py, which writes a
`quality:` block into each meta.yaml. This module is the part the API, the
site and docs/STATUS.md share: the weights file, the formula, and reading a block.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import yaml

WEIGHTS_FILE = Path(__file__).resolve().parents[2] / "quality_weights.yaml"
RESULTS = ("pass", "fail", "not_run")


@lru_cache(maxsize=1)
def load_weights(path: str | None = None) -> dict:
    return yaml.safe_load(Path(path or WEIGHTS_FILE).read_text(encoding="utf-8"))


def earned(check: dict, weights: dict) -> float:
    w = float(check["weight"])
    result = check["result"]
    if result == "pass":
        return w
    if result == "not_run":
        return w * (1 - float(weights["not_run_penalty"]))
    if result == "fail":
        return w * (1 - float(weights["fail_penalty"]))
    raise ValueError(f"unknown result {result!r} (expected one of {RESULTS})")


def score(checks: list[dict], weights: dict) -> float:
    possible = sum(float(c["weight"]) for c in checks)
    if not possible:
        return 0.0
    return round(100 * sum(earned(c, weights) for c in checks) / possible, 1)


def level_for(value: float, checks: list[dict], weights: dict) -> dict:
    passed = {c["name"] for c in checks if c["result"] == "pass"}
    for level in weights["levels"]:
        if value >= level["min_score"] and set(level.get("requires_pass") or []) <= passed:
            return level
    return weights["levels"][-1]


def summary(meta: dict) -> dict | None:
    """What the API and the site show: score, level and the checks, from a meta.yaml mapping."""
    block = meta.get("quality") if isinstance(meta, dict) else None
    if not isinstance(block, dict):
        return None
    labels = {lv["id"]: lv["label"] for lv in load_weights()["levels"]}
    return {"score": block.get("score"), "level": block.get("level"),
            "level_label": labels.get(block.get("level"), block.get("level")),
            "weights_version": block.get("weights_version"),
            "checks": [{k: c.get(k) for k in ("name", "result", "weight", "ran_at", "evidence")}
                       for c in block.get("checks") or []]}
