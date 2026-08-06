#!/usr/bin/env python3
"""Repair `model:` in meta.yaml where usage.jsonl can prove which model answered.

Agent backends used to record the CLI name (`model: claude`) rather than the
model. That is useless for the question it exists to answer — opus-5, opus-4.8
and fable-5 all look identical — so `_dominant_model` now records the real one.
This fixes what was written before that, and ONLY where there is evidence:
usage.jsonl carries cert/topic/lang/kind per completion together with the model
that produced the output.

Topics generated before usage tracking existed (2026-08-05) are left alone. A
guessed provenance is worse than an admitted gap, because it looks like a fact.

    scripts/backfill_model.py --dry-run
    scripts/backfill_model.py
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
USAGE = Path.home() / ".local" / "state" / "teach-plat" / "usage.jsonl"


def evidence() -> dict[tuple[str, str, str], str]:
    """(cert, topic, lang) -> model, from the most recent completion for it."""
    found: dict[tuple[str, str, str], str] = {}
    if not USAGE.exists():
        return found
    for line in USAGE.read_text().splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = (row.get("cert"), row.get("topic"), row.get("lang"))
        if not all(key):
            continue
        models = row.get("models") or {}
        if not models:
            continue
        # Same rule as the generator: the model that produced the output.
        name = max(models.items(), key=lambda kv: (kv[1] or {}).get("out") or 0)[0]
        found[key] = name  # later rows win; the last run is what is on disk
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    known = evidence()
    if not known:
        raise SystemExit(f"No usage evidence in {USAGE}; nothing can be proven.")

    fixed = untouched = 0
    for meta_file in sorted((REPO / "certs").glob("*/*/*/meta.yaml")):
        try:
            meta = yaml.safe_load(meta_file.read_text()) or {}
        except yaml.YAMLError:
            continue
        current = str(meta.get("model") or "")
        # Only placeholders. A real model name is left alone even if usage
        # disagrees — the file is the record of what was actually written.
        if current not in {"claude", "agy", "codex", "gemini", ""}:
            continue
        parts = meta_file.parts
        key = (parts[-4], parts[-3], parts[-2])
        real = known.get(key)
        if not real:
            untouched += 1
            continue
        print(f"  {'/'.join(key):28} {current or '(empty)':10} -> {real}")
        if not args.dry_run:
            meta["model"] = real
            meta_file.write_text(yaml.safe_dump(meta, sort_keys=False))
        fixed += 1

    verb = "would fix" if args.dry_run else "fixed"
    print(f"\n{verb} {fixed}; {untouched} left as-is (generated before usage "
          f"tracking, so the model cannot be proven — guessing would be worse).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
