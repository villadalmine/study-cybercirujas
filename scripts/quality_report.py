#!/usr/bin/env python3
"""Per-certification quality report. Generates nothing and spends no budget.

Answers the question that motivated the floor: which material meets the
standard, and which was marked `generated` without reaching it. Reads the
thresholds from pipeline.yaml — the same ones the generator applies before
writing.

    scripts/quality_report.py            # all active certs
    scripts/quality_report.py cnpe cnpa  # only these
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

from teach.core import pipeline, quality  # noqa: E402


def main() -> int:
    wanted = sys.argv[1:]
    targets = pipeline.targets(active_only=not wanted)
    if wanted:
        targets = [(c, langs) for c, langs in targets if c in wanted]
        for cert in wanted:
            if cert not in {c for c, _ in targets}:
                targets.append((cert, pipeline.languages_for(cert)))

    print(f"{'cert':<14} {'lang':<5} {'ok':>4} {'below floor':>12}   detail")
    print("-" * 78)

    total_ok = total_bad = 0
    for cert, langs in targets:
        for lang in langs:
            ok = 0
            reasons: dict[str, int] = defaultdict(int)
            for kind in ("content.md", "exercises.md"):
                for path in sorted((REPO / "certs" / cert).glob(f"*/{lang}/{kind}")):
                    problems = quality.check_file(path)
                    if problems:
                        for problem in problems:
                            # collapse every "N bytes, below the M minimum" into
                            # one readable category instead of one row per size
                            key = "size" if "below the" in problem else problem
                            reasons[f"{kind}: {key}"] += 1
                    else:
                        ok += 1
            bad = sum(reasons.values())
            if ok == 0 and bad == 0:
                continue
            total_ok += ok
            total_bad += bad
            detail = ", ".join(f"{k} ×{v}" for k, v in sorted(reasons.items())) or "—"
            print(f"{cert:<14} {lang:<5} {ok:>4} {bad:>12}   {detail}")

    print("-" * 78)
    print(f"{'TOTAL':<20} {total_ok:>4} {total_bad:>12}")
    if total_bad:
        print("\nThresholds in pipeline.yaml → quality. Regenerate with:")
        print("  scripts/run_batch.py <cert> --lang <lang>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
