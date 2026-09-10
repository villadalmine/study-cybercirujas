#!/usr/bin/env python3
"""Broken-manifest rate per topic, split by when the topic was generated.

The prompt in `generator.py` gained code-block conventions on 2026-09-11 —
quote values containing `: `, quote a leading `*`, keep block-scalar indent,
one JSON document per ```json fence. That change applies to every future topic
and its effect cannot be seen in one file, so it needs measuring over time.

**The honest limitation, stated because it decides how to read the output**:
the pre-change corpus was repaired the same day, so its rate now reads 0% and
a before/after comparison would be meaningless. The number to compare against
is the one recorded at repair time:

    1,225 topic/languages · 28 genuine defects across 14 topics · **1.1%**
    (a further 116 findings were checker false positives, not content)

So what this script actually answers is: **do NEW topics arrive broken?** Any
rate above zero on the "after" side means the conventions did not take.

    scripts/manifest_rate.py                    # before/after the prompt change
    scripts/manifest_rate.py --since 2026-09-11 # pick a different boundary

Until enough topics exist on the new side, it says so instead of reporting a
number: two topics is not a rate. Free — no model, no network.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

# The day the code-block conventions entered the system prompt.
PROMPT_CHANGE = "2026-09-11"
# Below this a percentage is noise dressed as evidence.
MIN_SAMPLE = 10


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", default=PROMPT_CHANGE,
                        help=f"boundary date (default {PROMPT_CHANGE}, the prompt change)")
    args = parser.parse_args()

    from check_manifests import problems

    buckets = {"before": {"topics": 0, "broken": 0}, "after": {"topics": 0, "broken": 0}}
    undated = 0
    for meta_path in sorted(REPO.glob("certs/*/*/*/meta.yaml")):
        lang_dir = meta_path.parent
        try:
            meta = yaml.safe_load(meta_path.read_text()) or {}
        except yaml.YAMLError:
            continue
        when = str(meta.get("generated_at") or "")[:10]
        if not when:
            undated += 1
            continue
        bucket = buckets["after" if when >= args.since else "before"]
        bucket["topics"] += 1
        if any(problems(f) for f in lang_dir.glob("*.md")):
            bucket["broken"] += 1

    print(f"Boundary: {args.since} (the prompt gained code-block conventions)\n")
    print(f"{'':8} {'topics':>8} {'broken':>8} {'rate':>8}")
    for name in ("before", "after"):
        b = buckets[name]
        rate = f"{100 * b['broken'] / b['topics']:.1f}%" if b["topics"] else "—"
        print(f"{name:8} {b['topics']:>8} {b['broken']:>8} {rate:>8}")
    if undated:
        print(f"\n{undated} topic(s) with no generated_at — not counted either way.")

    after = buckets["after"]["topics"]
    if after < MIN_SAMPLE:
        print(f"\nOnly {after} topic(s) generated since the change: too few to call a "
              f"rate. Re-run after {MIN_SAMPLE}+ exist — the next certification "
              f"produces them at no extra cost.")
        return 0
    after_rate = buckets["after"]["broken"] / after
    # The pre-change side was repaired, so it is not a baseline. Compare against
    # the rate recorded at repair time instead: 14 of 1,225 topics, 1.1%.
    baseline = 1.1
    print(f"\nRecorded rate before the repair pass (2026-09-11): {baseline}% of topics.")
    if after_rate == 0:
        print(f"No new topic has arrived broken in {after} generated since. That is "
              f"consistent with the conventions holding — subject matter is still a "
              f"confound, so it is evidence, not proof.")
    elif after_rate * 100 < baseline:
        print(f"New topics break at {after_rate*100:.1f}%, below the {baseline}% "
              f"recorded before. Lower, not zero: read the failures.")
    else:
        print(f"New topics break at {after_rate*100:.1f}%, at or above the {baseline}% "
              f"recorded before. The conventions did NOT take — read the failing "
              f"blocks before defending the prompt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
