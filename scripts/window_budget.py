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


def _kind(detail: str) -> str:
    """What the API actually said the limit was: spend | weekly | "".

    Read from the message rather than guessed from duration. A monthly spend
    ceiling and a session window both present as "exhausted" and behave
    completely differently: one refills in hours on its own, the other does not
    refill at all until the month rolls over or the ceiling is raised.
    """
    text = (detail or "").lower()
    if "spend limit" in text or "monthly" in text:
        return "spend"
    if "weekly" in text:
        return "weekly"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--weeks", type=int, default=4)
    args = parser.parse_args()

    quota = _load(QUOTA)
    if not quota:
        raise SystemExit(f"No quota history at {QUOTA}. It fills as the timer probes.")

    # Runs of the same status, so an exhaustion can be measured end to end.
    # Carry the API's own words through, not just the status. The kind of limit
    # was being inferred from how long the exhaustion lasted, while the response
    # states it outright — and 153 of 456 recorded exhaustions say "monthly
    # spend limit", which no duration threshold would have separated from a
    # session window. A report that says "every exhaustion refilled on its own"
    # when a third of them were a spend ceiling is worse than no report.
    runs, prev, start, detail = [], None, None, ""
    for row in quota:
        if row.get("status") != prev:
            if prev is not None:
                runs.append((prev, start, row["at"], detail))
            prev, start, detail = row.get("status"), row["at"], str(row.get("detail") or "")
        elif row.get("status") == "exhausted" and not _kind(detail):
            detail = str(row.get("detail") or "")
    runs.append((prev, start, quota[-1]["at"], detail))

    per_week: dict[str, dict] = defaultdict(
        lambda: {"windows": 0, "exhaustions": [], "weekly_caps": [],
                 "spend_limits": [], "tokens": 0, "topics": set()}
    )
    for status, begin, end, detail in runs:
        hours = (datetime.datetime.fromisoformat(end)
                 - datetime.datetime.fromisoformat(begin)).total_seconds() / 3600
        bucket = per_week[_week(begin)]
        if status == "available":
            bucket["windows"] += 1
        elif status == "exhausted":
            kind = _kind(detail)
            if kind == "spend":
                bucket["spend_limits"].append(hours)
            elif kind == "weekly" or hours >= WEEKLY_CAP_HOURS:
                bucket["weekly_caps"].append(hours)
            else:
                bucket["exhaustions"].append(hours)

    for row in _load(USAGE):
        bucket = per_week[_week(row.get("at", "1970-01-01"))]
        bucket["tokens"] += row.get("output_tokens") or 0
        if row.get("op") == "author" and row.get("topic"):
            bucket["topics"].add((row.get("cert"), row.get("topic"), row.get("lang")))

    weeks = sorted(per_week)[-args.weeks:]
    print(f"{'week of':12} {'windows':>8} {'session':>8} {'weekly':>7} {'spend':>7} "
          f"{'out tokens':>12} {'topics':>7}")
    print("-" * 70)
    for week in weeks:
        b = per_week[week]
        caps = f"{len(b['weekly_caps'])}" if b["weekly_caps"] else "—"
        spend = f"{len(b['spend_limits'])}" if b["spend_limits"] else "—"
        print(f"{week:12} {b['windows']:8} {len(b['exhaustions']):8} {caps:>7} "
              f"{spend:>7} {b['tokens']:12,} {len(b['topics']):7}")

    current = per_week[weeks[-1]] if weeks else None
    if not current:
        return 0

    print()
    if current["spend_limits"]:
        longest = max(current["spend_limits"])
        print(f"⚠️  SPEND LIMIT hit this week: {len(current['spend_limits'])} "
              f"exhaustion(s), longest {longest:.1f} h. This is NOT a session "
              f"window:\n    the API said so outright, and nothing but the month "
              f"rolling over or the\n    ceiling being raised at "
              f"claude.ai/settings/usage will clear it. Waiting does\n    not help "
              f"the way it does with a window.")
    if current["weekly_caps"]:
        longest = max(current["weekly_caps"])
        print(f"⚠️  WEEKLY CAP HIT this week: {len(current['weekly_caps'])} exhaustion(s) "
              f"of {longest:.1f} h — far longer than a session reset. Nothing but "
              f"the week rolling over fixes that; the timer will pick up on its own.")
    elif not current["spend_limits"]:
        print("No weekly cap or spend limit this week — every exhaustion was a "
              "session window refilling on its own.")
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
