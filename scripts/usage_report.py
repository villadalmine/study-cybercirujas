#!/usr/bin/env python3
"""What the pipeline actually spent, per model and per topic.

The quota is the real constraint, and until now nothing measured it: the only
evidence was "the window emptied within an hour" plus guesswork over resume.log
timestamps. Every completion through the `claude` backend now writes one line to
usage.jsonl (see generator._record_usage), and this aggregates them.

    scripts/usage_report.py                 # everything recorded
    scripts/usage_report.py --since 2026-08-04
    scripts/usage_report.py --by topic      # or: model, cert, op, kind

Reads only local state, costs no quota.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

LOG = Path.home() / ".local" / "state" / "teach-plat" / "usage.jsonl"


def rows(since: str | None) -> list[dict]:
    if not LOG.exists():
        raise SystemExit(
            f"No usage recorded yet at {LOG}.\n"
            "It fills up as the `claude` backend generates; nothing before "
            "instrumentation was added on 2026-08-05 is in there."
        )
    out = []
    for line in LOG.read_text().splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if since and row.get("at", "") < since:
            continue
        out.append(row)
    return out


def _money(value: float | None) -> str:
    return f"${value:,.4f}" if value else "—"


def _tokens(value: int | None) -> str:
    return f"{value:,}" if value else "—"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="ISO date, e.g. 2026-08-04")
    parser.add_argument("--by", default="model",
                        choices=["model", "cert", "topic", "op", "kind"])
    args = parser.parse_args()

    data = rows(args.since)
    if not data:
        print("Nothing recorded in that range.")
        return 0

    total_cost = sum(r.get("cost_usd") or 0 for r in data)
    total_out = sum(r.get("output_tokens") or 0 for r in data)
    total_read = sum(r.get("cache_read") or 0 for r in data)
    total_write = sum(r.get("cache_write") or 0 for r in data)

    print(f"{len(data)} completions from {data[0].get('at')} to {data[-1].get('at')}")
    print(f"  cost         {_money(total_cost)}")
    print(f"  output       {_tokens(total_out)} tokens")
    print(f"  cache read   {_tokens(total_read)} · written {_tokens(total_write)}")
    print()

    # Per model: the answer to "which Claude is actually doing the work".
    per_model: dict[str, dict] = defaultdict(lambda: {"cost": 0.0, "in": 0, "out": 0, "calls": 0})
    for row in data:
        for name, info in (row.get("models") or {}).items():
            bucket = per_model[name]
            bucket["cost"] += info.get("cost_usd") or 0
            bucket["in"] += info.get("in") or 0
            bucket["out"] += info.get("out") or 0
            bucket["calls"] += 1
    if per_model:
        print(f"{'model':34} {'calls':>6} {'in':>12} {'out':>10} {'cost':>12}")
        print("-" * 78)
        for name, b in sorted(per_model.items(), key=lambda kv: -kv[1]["cost"]):
            print(f"{name:34} {b['calls']:6} {b['in']:12,} {b['out']:10,} {_money(b['cost']):>12}")
        print()

    if args.by != "model":
        key = args.by
        grouped: dict[str, dict] = defaultdict(lambda: {"cost": 0.0, "out": 0, "calls": 0})
        for row in data:
            label = str(row.get(key, "?"))
            if key == "topic":
                label = f"{row.get('cert', '?')}/{row.get('topic', '?')} ({row.get('lang', '?')})"
            bucket = grouped[label]
            bucket["cost"] += row.get("cost_usd") or 0
            bucket["out"] += row.get("output_tokens") or 0
            bucket["calls"] += 1
        print(f"{key:34} {'calls':>6} {'out tokens':>12} {'cost':>12}")
        print("-" * 68)
        for label, b in sorted(grouped.items(), key=lambda kv: -kv[1]["cost"]):
            print(f"{label:34} {b['calls']:6} {b['out']:12,} {_money(b['cost']):>12}")
        print()

    # The number that matters for pacing: cost of one finished topic.
    authored = [r for r in data if r.get("op") == "author"]
    if authored:
        topics = {(r.get("cert"), r.get("topic"), r.get("lang")) for r in authored}
        cost = sum(r.get("cost_usd") or 0 for r in authored)
        print(f"Authoring: {len(topics)} topics over {len(authored)} completions, "
              f"{_money(cost)} — {_money(cost / max(len(topics), 1))} per topic.")
    translated = [r for r in data if r.get("op") == "translate"]
    if translated:
        topics = {(r.get("cert"), r.get("topic"), r.get("lang")) for r in translated}
        cost = sum(r.get("cost_usd") or 0 for r in translated)
        print(f"Translating: {len(topics)} topics over {len(translated)} completions, "
              f"{_money(cost)} — {_money(cost / max(len(topics), 1))} per topic.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
