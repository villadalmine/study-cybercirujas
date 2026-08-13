#!/usr/bin/env python3
"""Is one model better than another, and what does it cost to find out?

Comparing models across different certifications is confounded: a topic about
etcd backups is not the same work as one about pod security, so a difference in
output size may be the syllabus rather than the model. Comparing WITHIN one
certification controls for that — same syllabus, same prompts, same quality
floor, one variable changed.

    scripts/model_comparison.py --cert kca      # the clean comparison
    scripts/model_comparison.py                 # whole corpus, confounded

What it measures, all of it free and already on disk:

  material     KB written per topic — more is not automatically better
  tokens       output tokens per topic — the resource actually consumed
  KB/1k tok    how much material a thousand tokens buys. THIS is the number
               that decides how much a quota window produces
  floor        share of files meeting the quality floor
  code, refs   code blocks and citations per topic, as a proxy for density
  minutes      wall clock, which matters for how long a window stays open

What it cannot measure is whether the explanations are TRUE. Nothing here can —
see docs/AUDITOR_DESIGN.md. A model that writes confident, well-cited, wrong
material scores well on every column below, so treat this as a consumption
comparison with quality guardrails, not as a quality verdict.

Sample sizes are printed because they are usually the reason two runs disagree.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

import yaml  # noqa: E402

from teach.core import claims, quality  # noqa: E402

USAGE = (Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
         / "teach-plat" / "usage.jsonl")

CODE_BLOCK = re.compile(r"^```", re.M)
CITATION = re.compile(r"https?://")

# Measured on this machine; window_budget.py derives it from real exhaustions.
# Only used to turn tokens into windows, and printed so it is never mistaken for
# a fact about the model.
TOKENS_PER_WINDOW = 800_000


def usage_by_topic() -> dict[tuple, dict]:
    """(cert, topic, lang) -> tokens and minutes, from the recorded completions."""
    out: dict[tuple, dict] = defaultdict(lambda: {"out": 0, "ms": 0, "cost": 0.0})
    if not USAGE.exists():
        return out
    for line in USAGE.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("op") not in ("author", "translate"):
            continue
        key = (row.get("cert"), str(row.get("topic")), row.get("lang"))
        out[key]["out"] += int(row.get("output_tokens") or 0)
        out[key]["ms"] += int(row.get("duration_ms") or 0)
        out[key]["cost"] += float(row.get("cost_usd") or 0)
    return out


def observations(cert_filter: str | None) -> list[dict]:
    """One row per generated topic/language, attributed to the model in meta.yaml.

    meta.yaml is the attribution of record — it holds the model that actually
    answered, resolved from the CLI envelope — rather than whatever was pinned
    when the run started. Those differ, and the difference is the whole reason
    provenance is written per topic.
    """
    tokens = usage_by_topic()
    # A topic being generated RIGHT NOW has some of its files and some of its
    # token records, and the ratio between them is meaningless until both are
    # settled. Measured mid-flight, opus-5 read 1.76 KB/1k tokens; the same five
    # topics finished read 0.99 — a reversal produced entirely by timing. The
    # claim system already knows which topics those are, so ask it.
    in_flight = {(c, t) for c, t, _ in claims.active()}
    rows = []
    for syllabus in sorted((REPO / "certs").glob("*.md")):
        cert = syllabus.stem
        if cert_filter and cert != cert_filter:
            continue
        try:
            front = yaml.safe_load(syllabus.read_text().split("---")[1]) or {}
        except (IndexError, yaml.YAMLError):
            continue
        for topic in front.get("topics") or []:
            topic_id = str(topic["id"])
            if (cert, topic_id) in in_flight:
                continue
            for lang_dir in sorted((REPO / "certs" / cert / topic_id).glob("*")):
                meta_file = lang_dir / "meta.yaml"
                content = lang_dir / "content.md"
                if not meta_file.exists() or not content.exists():
                    continue
                try:
                    meta = yaml.safe_load(meta_file.read_text()) or {}
                except yaml.YAMLError:
                    continue
                model = str(meta.get("model") or "unknown")
                # `claude`, `agy`, `cheap` are BINARY NAMES, not models: content
                # written before the CLI's JSON envelope was parsed for the model
                # that actually answered. Comparing them as if they were models
                # would attribute a real difference to a label — and their token
                # counts belong to whichever model was default that day.
                if model in {"claude", "agy", "cheap", "codex", "gemini"}:
                    model = f"{model} (unresolved)"
                text = content.read_text(errors="replace")
                exercises = lang_dir / "exercises.md"
                size = len(text) + (exercises.stat().st_size
                                    if exercises.exists() else 0)
                measured = tokens.get((cert, topic_id, lang_dir.name), {})
                rows.append({
                    "cert": cert, "topic": topic_id, "lang": lang_dir.name,
                    "model": model,
                    "bytes": size,
                    "tokens": measured.get("out") or 0,
                    "minutes": (measured.get("ms") or 0) / 60000,
                    "cost": measured.get("cost") or 0.0,
                    "code": len(CODE_BLOCK.findall(text)) // 2,
                    "refs": len(set(CITATION.findall(text))),
                    "floor_ok": not quality.check_file(content) and (
                        exercises.exists() and not quality.check_file(exercises)),
                })
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cert", help="compare within one certification (recommended)")
    parser.add_argument("--min-samples", type=int, default=1,
                        help="hide models with fewer topics than this")
    args = parser.parse_args()

    rows = observations(args.cert)
    if not rows:
        print("Nothing generated matches that." if args.cert else "Nothing generated yet.")
        return 0

    per_model: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        per_model[row["model"]].append(row)

    scope = f"within {args.cert}" if args.cert else "across the whole corpus"
    print(f"Comparing {scope} — {len(rows)} generated topic/languages\n")
    print(f"{'model':26} {'n':>4} {'KB':>7} {'ktok':>7} {'KB/1k':>7} "
          f"{'floor':>6} {'code':>5} {'refs':>5} {'min':>6}")
    print("-" * 84)

    summary = {}
    for model, entries in sorted(per_model.items(), key=lambda kv: -len(kv[1])):
        if len(entries) < args.min_samples:
            continue
        n = len(entries)
        kb = statistics.median(e["bytes"] for e in entries) / 1024
        measured = [e for e in entries if e["tokens"]]
        ktok = (statistics.median(e["tokens"] for e in measured) / 1000
                if measured else 0)
        efficiency = (kb / ktok) if ktok else 0
        floor = sum(1 for e in entries if e["floor_ok"]) / n * 100
        code = statistics.median(e["code"] for e in entries)
        refs = statistics.median(e["refs"] for e in entries)
        mins = (statistics.median(e["minutes"] for e in measured) if measured else 0)
        summary[model] = {"n": n, "kb": kb, "ktok": ktok, "eff": efficiency}
        print(f"{model[:26]:26} {n:>4} {kb:>7.1f} {ktok:>7.1f} {efficiency:>7.2f} "
              f"{floor:>5.0f}% {code:>5.0f} {refs:>5.0f} {mins:>6.1f}")

    measurable = {m: s for m, s in summary.items() if s["ktok"]}
    if len(measurable) >= 2:
        print("\nWhat a quota window buys, at "
              f"{TOKENS_PER_WINDOW:,} output tokens per window:\n")
        for model, s in sorted(measurable.items(), key=lambda kv: -kv[1]["eff"]):
            topics = TOKENS_PER_WINDOW / (s["ktok"] * 1000)
            print(f"  {model[:26]:26} {topics:>5.1f} topics/window · "
                  f"{topics * s['kb']:>6.0f} KB/window   (n={s['n']})")
        thin = [m for m, s in measurable.items() if s["n"] < 10]
        if thin:
            print(f"\n  Thin evidence: {', '.join(thin)} — fewer than 10 topics. "
                  f"Two runs\n  disagreeing is usually this, not the model.")

    unresolved = [m for m in per_model if "(unresolved)" in m]
    if unresolved:
        print(f"\n{', '.join(unresolved)}: a binary name, not a model — written "
              f"before the CLI\nenvelope was parsed for what actually answered. "
              f"Not comparable; excluded from the\nwindow figures above would be "
              f"wrong too, so read those rows as 'unknown model'.")

    print("\nNone of these columns says the material is CORRECT. A model that "
          "writes confident,\nwell-cited, wrong explanations scores well on all "
          "of them — see docs/AUDITOR_DESIGN.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
