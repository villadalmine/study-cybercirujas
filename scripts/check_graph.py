#!/usr/bin/env python3
"""Is the code graph present and built from the commit we are standing on?

The graph (graphify-out/graph.json, built by `make graph` and refreshed by the
post-commit hook) is only useful while it is true: an agent that plans work
from a stale map repeats the class of mistake this repo has already paid for —
acting on a cached idea of the code instead of the code. The build is
tree-sitter AST only, so keeping it fresh costs no quota; there is no excuse
for it to be stale except nobody noticing.

Warn-only by default so `make verify` keeps proving content soundness even on
a clone that never built a graph. --strict turns both findings into failures
(for anything that is about to RELY on the graph, e.g. serving it over MCP).

    scripts/check_graph.py             # warn and exit 0
    scripts/check_graph.py --strict    # missing or stale graph exits 1
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REPORT = REPO / "graphify-out" / "GRAPH_REPORT.md"
GRAPH = REPO / "graphify-out" / "graph.json"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true",
                        help="exit non-zero on a missing or stale graph")
    args = parser.parse_args()
    fail = 1 if args.strict else 0

    if not GRAPH.exists() or not REPORT.exists():
        print("graph: MISSING — build it with `make graph` (AST only, no quota).")
        return fail

    match = re.search(r"Built from commit: `([0-9a-f]+)`", REPORT.read_text())
    if not match:
        print("graph: present but GRAPH_REPORT.md records no source commit — rebuild with `make graph`.")
        return fail
    built_from = match.group(1)

    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                          capture_output=True, text=True).stdout.strip()
    if not head:
        print("graph: cannot read git HEAD — not a git checkout?")
        return fail

    if head.startswith(built_from):
        print(f"graph: OK — built from HEAD ({built_from}).")
        return 0

    # The stamp lags legitimately: `graphify update` leaves every output
    # untouched (stamp included) when no topology changed, so a docs-only or
    # body-only commit keeps the old stamp forever. The post-commit hook
    # therefore records how far the scanner actually got (.last-scan); the
    # freshness baseline is that scan when we have one, the stamp when we
    # don't (fresh clone, hook never ran).
    last_scan_file = REPO / "graphify-out" / ".last-scan"
    baseline = built_from
    if last_scan_file.exists():
        scanned = last_scan_file.read_text().strip()
        if re.fullmatch(r"[0-9a-f]{7,40}", scanned):
            if head == scanned:
                print(f"graph: OK — scanned at HEAD ({scanned[:8]}); "
                      "no topology change since the last rebuild.")
                return 0
            baseline = scanned
    diff = subprocess.run(["git", "diff", "--name-only", f"{baseline}..HEAD"],
                          cwd=REPO, capture_output=True, text=True)
    if diff.returncode != 0:
        print(f"graph: baseline {baseline[:8]} is not in this history — "
              "rebuild with `make graph`.")
        return fail
    ignored = [line.strip().rstrip("/") for line in
               (REPO / ".graphifyignore").read_text().splitlines()
               if line.strip() and not line.startswith("#")] if (REPO / ".graphifyignore").exists() else []
    covered = [f for f in diff.stdout.splitlines()
               if f and not any(f == p or f.startswith(p + "/") for p in ignored)
               and not f.startswith(".git")]
    if not covered:
        print(f"graph: OK — nothing it covers changed since {baseline[:8]}.")
        return 0
    print(f"graph: possibly STALE — {len(covered)} covered file(s) changed since "
          f"{baseline[:8]} (e.g. {covered[0]}). Run `make graph` (free) to settle it.")
    return fail


if __name__ == "__main__":
    sys.exit(main())
