#!/usr/bin/env python3
"""What one topic costs: tokens, context, model, and how many fit in a window.

`usage_report.py` totals the corpus and `window_budget.py` reports the ceiling.
Neither answers "what did THIS topic cost, and on what" — which is the question
behind every pacing decision: how much is left, what to spend it on, and whether
a model change was worth it.

Every completion through the `claude` backend is recorded, so this is measured,
not estimated. On a subscription the dollar figures are the API-equivalent price
and not a bill; the finite resource is the ~5 h session window, so the column
that matters most is the last one.

    scripts/topic_cost.py                    # every topic, newest first
    scripts/topic_cost.py --cert kca         # one certification
    scripts/topic_cost.py --by-model         # what each model costs per topic
    scripts/topic_cost.py --forecast 135     # what N more topics would take

Costs no API quota: it reads a log.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import quota_facts  # noqa: E402

USAGE = (Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
         / "teach-plat" / "usage.jsonl")

# Derived from this machine's recorded history, never a constant. 800_000 used to
# be written here and in model_comparison.py, and an invented number printed in a
# table is indistinguishable from a measured one. The real median is 725,399 —
# close enough to look right, which is what made it dangerous.


def records() -> list[dict]:
    if not USAGE.exists():
        return []
    out = []
    for line in USAGE.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def by_topic(rows: list[dict]) -> dict[tuple, dict]:
    """Roll completions up per (cert, topic, lang, op).

    A topic is several completions — content, exercises, sometimes a lab — plus a
    small auxiliary haiku call on every one. Reporting per completion answers a
    question nobody asks; the unit of work is the topic.
    """
    topics: dict[tuple, dict] = {}
    for row in rows:
        key = (row.get("cert"), str(row.get("topic")), row.get("lang"),
               row.get("op", "author"))
        entry = topics.setdefault(key, {
            "cost": 0.0, "out": 0, "in": 0, "cache_read": 0, "cache_write": 0,
            "ms": 0, "calls": 0, "models": defaultdict(int), "at": row.get("at", ""),
            "effort": row.get("effort") or "default",
        })
        entry["cost"] += float(row.get("cost_usd") or 0)
        entry["out"] += int(row.get("output_tokens") or 0)
        entry["cache_read"] += int(row.get("cache_read") or 0)
        entry["cache_write"] += int(row.get("cache_write") or 0)
        entry["ms"] += int(row.get("duration_ms") or 0)
        entry["calls"] += 1
        entry["at"] = max(entry["at"], row.get("at", ""))
        for model, stats in (row.get("models") or {}).items():
            entry["in"] += int((stats or {}).get("in") or 0)
            # Attribute the topic to the model that did the writing. A call bills
            # a small haiku alongside the real one, and counting by call count
            # would name haiku as the author of the entire corpus.
            entry["models"][model] += int((stats or {}).get("out") or 0)
    return topics


def dominant(models: dict) -> str:
    return max(models.items(), key=lambda kv: kv[1])[0] if models else "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cert")
    parser.add_argument("--op", choices=["author", "translate"])
    parser.add_argument("--by-model", action="store_true")
    parser.add_argument("--forecast", type=int, metavar="N",
                        help="what N more topics would cost at the measured rate")
    parser.add_argument("--limit", type=int, default=25)
    args = parser.parse_args()

    rows = records()
    if not rows:
        print(f"No usage recorded at {USAGE}.")
        return 0

    topics = by_topic(rows)
    if args.cert:
        topics = {k: v for k, v in topics.items() if k[0] == args.cert}
    if args.op:
        topics = {k: v for k, v in topics.items() if k[3] == args.op}
    if not topics:
        print("Nothing matches those filters.")
        return 0

    if args.by_model:
        per_model: dict[tuple[str, str], list[dict]] = defaultdict(list)
        for (_, _, _, op), entry in topics.items():
            per_model[(dominant(entry["models"]), op)].append(entry)
        print(f"{'model':28} {'op':10} {'topics':>6} {'out/topic':>10} "
              f"{'ctx/call':>9} {'$/topic':>8} {'min':>6}")
        print("-" * 82)
        for (model, op), entries in sorted(per_model.items(),
                                           key=lambda kv: -len(kv[1])):
            n = len(entries)
            out = sum(e["out"] for e in entries) / n
            ctx = sum(e["in"] + e["cache_read"] for e in entries) / max(
                1, sum(e["calls"] for e in entries))
            cost = sum(e["cost"] for e in entries) / n
            mins = sum(e["ms"] for e in entries) / n / 60000
            print(f"{model[:28]:28} {op:10} {n:>6} {out:>10,.0f} "
                  f"{ctx:>9,.0f} {cost:>8.2f} {mins:>6.1f}")
        print("\n`ctx/call` is input plus cache read — what the model actually "
              "loaded per call.\nA context window that is large is billed whether "
              "the work needs it or not.")
        return 0

    if args.forecast:
        authored = [e for (_, _, _, op), e in topics.items() if op == "author"]
        if not authored:
            print("No authoring recorded to forecast from.")
            return 1
        per = sum(e["out"] for e in authored) / len(authored)
        cost = sum(e["cost"] for e in authored) / len(authored)
        hours = sum(e["ms"] for e in authored) / len(authored) / 3_600_000
        total_out = per * args.forecast
        print(f"Measured over {len(authored)} authored topics:")
        print(f"  {per:,.0f} output tokens, ${cost:.2f} and {hours:.2f} h each\n")
        print(f"{args.forecast} more topics would be:")
        print(f"  {total_out:,.0f} output tokens · ${cost * args.forecast:,.2f} "
              f"API-equivalent · {hours * args.forecast:,.1f} h of generation")
        per_window = quota_facts.tokens_per_window()
        if per_window:
            print(f"  about {total_out / per_window:,.1f} quota windows, at "
                  f"{per_window:,} output tokens per window — MEASURED from this "
                  f"machine's\n  own history, not a published figure, and it moves "
                  f"when the model changes.")
        else:
            print("  windows: not measured yet — fewer than three complete windows "
                  "are on record.\n  A number here would be invented, so there "
                  "is none.")
        print("\nThe window is the real constraint, not the dollars: on a "
              "subscription those are\nan API-equivalent price.")
        return 0

    print(f"{'cert':14} {'topic':7} {'lg':3} {'op':10} {'model':22} "
          f"{'out':>9} {'ctx':>9} {'$':>7} {'min':>5}")
    print("-" * 96)
    shown = sorted(topics.items(), key=lambda kv: kv[1]["at"], reverse=True)
    for (cert, topic, lang, op), entry in shown[:args.limit]:
        ctx = (entry["in"] + entry["cache_read"]) / max(1, entry["calls"])
        print(f"{str(cert)[:14]:14} {topic[:7]:7} {str(lang)[:3]:3} {op:10} "
              f"{dominant(entry['models'])[:22]:22} {entry['out']:>9,} "
              f"{ctx:>9,.0f} {entry['cost']:>7.2f} {entry['ms'] / 60000:>5.1f}")

    total_cost = sum(e["cost"] for e in topics.values())
    total_out = sum(e["out"] for e in topics.values())
    print(f"\n{len(topics)} topics · {total_out:,} output tokens · "
          f"${total_cost:,.2f} API-equivalent")
    if len(shown) > args.limit:
        print(f"showing {args.limit} of {len(shown)} — --limit 0 is not a thing, "
              f"pass a bigger number")
    efforts = {e["effort"] for e in topics.values()}
    if efforts == {"default"}:
        print("\nThinking level: never set, so every one of these ran at the CLI "
              "default.\nIt is recorded from now on, so a change stays "
              "comparable against this.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
