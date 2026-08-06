#!/usr/bin/env python3
"""How much quota is left this week, in the unit that actually runs out.

The dollar figures in usage.jsonl are the API-equivalent price. On a Max
subscription they are NOT money — the bill is fixed. What is finite is quota, and
it is finite in two different ways:

  * **The session window.** Roughly 5 hours rolling. Exhausting it stops work for
    ~4-4.5 h and then it refills by itself. Measured: every exhaustion so far has
    been 4.0-4.5 h.
  * **The weekly cap.** A separate, larger ceiling. Hitting it looks completely
    different — the exhaustion lasts far longer than a session reset, until the
    week rolls over. **Any exhaustion over ~8 h is the weekly cap, not a window.**

Telling them apart matters because the response differs: a window is waited out,
a weekly cap means the week is over and nothing but time fixes it.

    scripts/window_budget.py              # this week
    scripts/window_budget.py --weeks 3

Reads local state only, costs nothing.
"""
from __future__ import annotations

import argparse
import datetime
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

STATE = Path.home() / ".local" / "state" / "teach-plat"
QUOTA = STATE / "quota-history.jsonl"
USAGE = STATE / "usage.jsonl"

# An exhaustion longer than this cannot be a session window refilling.
WEEKLY_CAP_HOURS = 8.0


def _load(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        if line.strip():
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def _week(stamp: str) -> str:
    day = datetime.date.fromisoformat(stamp[:10])
    monday = day - datetime.timedelta(days=day.weekday())
    return monday.isoformat()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--weeks", type=int, default=4)
    args = parser.parse_args()

    quota = _load(QUOTA)
    if not quota:
        raise SystemExit(f"No quota history at {QUOTA}. It fills as the timer probes.")

    # Runs of the same status, so an exhaustion can be measured end to end.
    runs, prev, start = [], None, None
    for row in quota:
        if row.get("status") != prev:
            if prev is not None:
                runs.append((prev, start, row["at"]))
            prev, start = row.get("status"), row["at"]
    runs.append((prev, start, quota[-1]["at"]))

    per_week: dict[str, dict] = defaultdict(
        lambda: {"windows": 0, "exhaustions": [], "weekly_caps": [], "tokens": 0, "topics": set()}
    )
    for status, begin, end in runs:
        hours = (datetime.datetime.fromisoformat(end)
                 - datetime.datetime.fromisoformat(begin)).total_seconds() / 3600
        bucket = per_week[_week(begin)]
        if status == "available":
            bucket["windows"] += 1
        elif status == "exhausted":
            (bucket["weekly_caps"] if hours >= WEEKLY_CAP_HOURS
             else bucket["exhaustions"]).append(hours)

    for row in _load(USAGE):
        bucket = per_week[_week(row.get("at", "1970-01-01"))]
        bucket["tokens"] += row.get("output_tokens") or 0
        if row.get("op") == "author" and row.get("topic"):
            bucket["topics"].add((row.get("cert"), row.get("topic"), row.get("lang")))

    weeks = sorted(per_week)[-args.weeks:]
    print(f"{'week of':12} {'windows':>8} {'exhausted':>10} {'weekly cap':>11} "
          f"{'out tokens':>12} {'topics':>7}")
    print("-" * 66)
    for week in weeks:
        b = per_week[week]
        caps = f"{len(b['weekly_caps'])}" if b["weekly_caps"] else "—"
        print(f"{week:12} {b['windows']:8} {len(b['exhaustions']):10} {caps:>11} "
              f"{b['tokens']:12,} {len(b['topics']):7}")

    current = per_week[weeks[-1]] if weeks else None
    if not current:
        return 0

    print()
    if current["weekly_caps"]:
        longest = max(current["weekly_caps"])
        print(f"⚠️  WEEKLY CAP HIT this week: {len(current['weekly_caps'])} exhaustion(s) "
              f"of {longest:.1f} h — far longer than a session reset. Nothing but "
              f"the week rolling over fixes that; the timer will pick up on its own.")
    else:
        print("No weekly cap reached this week — every exhaustion was a session "
              "window refilling on its own.")
        if current["exhaustions"]:
            print(f"  {len(current['exhaustions'])} session exhaustions, "
                  f"median {statistics.median(current['exhaustions']):.1f} h.")

    topics = len(current["topics"])
    if topics:
        per_topic = current["tokens"] / topics
        print(f"\nThis week: {topics} topics authored, {current['tokens']:,} output "
              f"tokens — {per_topic:,.0f} per topic.")
        if current["windows"]:
            print(f"  {topics / current['windows']:.1f} topics per window across "
                  f"{current['windows']} windows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
