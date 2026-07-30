#!/usr/bin/env python3
"""Chain bounded batches until a cert/language is complete.

`run_batch.py` deliberately generates only `budget.topics_per_run` topics per
invocation. This loops that call so a certification can be finished unattended
without ever raising the batch size — the pacing stays two at a time, the
supervision is what gets automated.

Stops on:
  - nothing left pending (success)
  - a fatal error such as an exhausted quota, where every further call fails
  - `--max-passes` reached, so a stubborn topic cannot loop forever

    scripts/run_until_complete.py cks --lang en
    scripts/run_until_complete.py kcna --lang en --max-passes 10
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from teach.core import pipeline  # noqa: E402

import fix_corrupted_content as audit  # noqa: E402

FATAL_EXIT = 2


def pending(cert: str, lang: str) -> int:
    return sum(1 for c, _, l in audit.find_bad_combos() if c == cert and l == lang)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cert")
    parser.add_argument("--lang", default="es")
    parser.add_argument("--backend", default="claude")
    parser.add_argument(
        "--max-passes", type=int, default=40,
        help="safety stop so one unsatisfiable topic cannot loop forever",
    )
    args = parser.parse_args()

    size = pipeline.topics_per_run()
    start = pending(args.cert, args.lang)
    print(f"{args.cert} ({args.lang}): {start} pending, {size} per pass", flush=True)

    for pass_number in range(1, args.max_passes + 1):
        left = pending(args.cert, args.lang)
        if left == 0:
            print(f"\n{args.cert} ({args.lang}) COMPLETE after {pass_number - 1} passes")
            return 0

        print(f"\n=== pass {pass_number} — {left} pending ===", flush=True)
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts" / "run_batch.py"), args.cert,
             "--lang", args.lang, "--backend", args.backend],
            cwd=REPO,
        )
        if result.returncode == FATAL_EXIT:
            print(f"\nStopped on a fatal error with {left} still pending.")
            return FATAL_EXIT
        if result.returncode != 0 and pending(args.cert, args.lang) == left:
            # A pass that generated nothing and left the count unchanged means
            # the same topics are failing repeatedly; looping would just burn
            # quota on them.
            print(f"\nNo progress this pass, stopping with {left} pending.")
            return 1
        time.sleep(2)

    print(f"\nReached --max-passes with {pending(args.cert, args.lang)} pending.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
