#!/usr/bin/env python3
"""Real metrics for the whole pipeline: per stage, per day, per quota window.

usage_report.py answers "what did it cost, per model/topic"; window_budget.py
answers "can I generate right now". This answers the accounting question the
owner actually asks: for everything from snapshot to translation to video,
how many tokens went where, on which day, and how many quota windows that day
consumed. Everything is read from what was recorded — usage.jsonl (one line
per completion, written by generator._record_usage/_record_plain_usage) and
quota-history.jsonl (exhaustion events) — never estimated. A dash means "not
measured", and that is an answer, not a gap to fill in.

    scripts/metrics_report.py                # stages + backends + daily + windows
    scripts/metrics_report.py --since 2026-08-01
    scripts/metrics_report.py --days 14      # daily table depth (default 14)
    scripts/metrics_report.py --json         # machine-readable dump

Reads only local state, costs no quota.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from teach.core import quota_facts  # noqa: E402

# Stage display order mirrors the pipeline: snapshot -> author -> translate ->
# video. Anything untagged predates the tagging (or bypassed it) and is shown,
# not hidden — untagged spend is the finding, not noise.
STAGE_ORDER = ["snapshot", "catalog-sync", "author", "translate",
               "video-script", "paths", "(untagged)"]


def rows(since: str | None) -> list[dict]:
    out = []
    for row in quota_facts._rows(quota_facts.USAGE):
        if since and str(row.get("at", "")) < since:
            continue
        out.append(row)
    return sorted(out, key=lambda r: str(r.get("at", "")))


def backend_of(row: dict) -> str:
    # Rows written before 2026-08-18 carry no backend field; every one of them
    # came from the claude JSON envelope (the only recording path that existed),
    # so labelling them claude is reading history, not guessing.
    if row.get("backend"):
        return str(row["backend"])
    return "claude" if row.get("models") else "(unknown)"


def in_tokens(row: dict) -> int:
    if row.get("input_tokens") is not None:
        return int(row["input_tokens"] or 0)
    return sum(int((m or {}).get("in") or 0) for m in (row.get("models") or {}).values())


def _fmt(n: int | float | None, money: bool = False) -> str:
    if not n:
        return "—"
    return f"${n:,.2f}" if money else f"{int(n):,}"


def session_windows() -> list[dict]:
    return [b for b in quota_facts.exhaustions() if b["kind"] == "session"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="ISO date, e.g. 2026-08-01")
    parser.add_argument("--days", type=int, default=14,
                        help="how many recent days in the daily table (default 14)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    data = rows(args.since)
    if not data:
        print("Nothing recorded" + (f" since {args.since}." if args.since else " yet."))
        return 0

    # ---- per stage -------------------------------------------------------
    stages: dict[str, dict] = defaultdict(
        lambda: {"calls": 0, "in": 0, "out": 0, "cost": 0.0, "units": set()})
    for row in data:
        op = str(row.get("op") or "(untagged)")
        b = stages[op]
        b["calls"] += 1
        b["in"] += in_tokens(row)
        b["out"] += int(row.get("output_tokens") or 0)
        b["cost"] += row.get("cost_usd") or 0
        if row.get("cert"):
            b["units"].add((row.get("cert"), row.get("topic"), row.get("lang")))

    # ---- per backend -----------------------------------------------------
    backends: dict[str, dict] = defaultdict(lambda: {"calls": 0, "out": 0, "cost": 0.0})
    for row in data:
        b = backends[backend_of(row)]
        b["calls"] += 1
        b["out"] += int(row.get("output_tokens") or 0)
        b["cost"] += row.get("cost_usd") or 0

    # ---- per day, with windows -------------------------------------------
    windows = session_windows()
    win_by_day: dict[str, int] = defaultdict(int)
    for block in windows:
        day = str(block.get("from") or "")[:10]
        if day:
            win_by_day[day] += 1
    daily: dict[str, dict] = defaultdict(
        lambda: {"calls": 0, "in": 0, "out": 0, "cost": 0.0, "ops": defaultdict(int)})
    for row in data:
        day = str(row.get("at", ""))[:10]
        b = daily[day]
        b["calls"] += 1
        b["in"] += in_tokens(row)
        b["out"] += int(row.get("output_tokens") or 0)
        b["cost"] += row.get("cost_usd") or 0
        b["ops"][str(row.get("op") or "?")] += 1

    per_window = quota_facts.tokens_per_window()

    if args.json:
        print(json.dumps({
            "stages": {k: {**v, "units": len(v["units"])} for k, v in stages.items()},
            "backends": dict(backends),
            "daily": {k: {**v, "ops": dict(v["ops"]),
                          "session_windows_exhausted": win_by_day.get(k, 0)}
                      for k, v in daily.items()},
            "session_windows_on_record": len(windows),
            "median_output_tokens_per_window": per_window,
        }, default=str, indent=2))
        return 0

    print(f"{len(data)} completions, {data[0].get('at')} → {data[-1].get('at')}\n")

    print(f"{'stage':14} {'calls':>6} {'units':>6} {'in tokens':>12} {'out tokens':>12} {'cost':>10}")
    print("-" * 66)
    ordered = [s for s in STAGE_ORDER if s in stages]
    ordered += sorted(set(stages) - set(ordered))
    for op in ordered:
        b = stages[op]
        print(f"{op:14} {b['calls']:>6} {len(b['units']) or '—':>6} "
              f"{_fmt(b['in']):>12} {_fmt(b['out']):>12} {_fmt(b['cost'], True):>10}")
    print("  (units = distinct cert/topic/lang the stage touched; cost is the")
    print("   API-equivalent price — on a subscription the real spend is windows)\n")

    print(f"{'backend':14} {'calls':>6} {'out tokens':>12} {'cost':>10}")
    print("-" * 46)
    for name, b in sorted(backends.items(), key=lambda kv: -kv[1]["calls"]):
        print(f"{name:14} {b['calls']:>6} {_fmt(b['out']):>12} {_fmt(b['cost'], True):>10}")
    print()

    days = sorted(daily)[-args.days:]
    print(f"{'day':11} {'calls':>6} {'in tokens':>12} {'out tokens':>12} {'cost':>10} {'windows':>8}  ops")
    print("-" * 96)
    for day in days:
        b = daily[day]
        ops = " ".join(f"{k}:{v}" for k, v in sorted(b["ops"].items()))
        print(f"{day:11} {b['calls']:>6} {_fmt(b['in']):>12} {_fmt(b['out']):>12} "
              f"{_fmt(b['cost'], True):>10} {win_by_day.get(day, 0):>8}  {ops}")
    print("  (windows = session-quota exhaustions that STARTED that day, from")
    print("   quota-history.jsonl; a day with tokens and 0 windows fit inside one)\n")

    if per_window:
        print(f"Session windows on record: {len(windows)} — median "
              f"{per_window:,} output tokens per window (measured, this machine).")
    else:
        print(f"Session windows on record: {len(windows)} — "
              f"fewer than {quota_facts.MIN_WINDOWS}, so tokens-per-window is not measured yet.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
