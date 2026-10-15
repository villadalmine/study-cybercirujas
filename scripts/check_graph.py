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
    scripts/check_graph.py --regenerate --base origin/main   # CI (docs job)

--regenerate settles "stale" for certain instead of guessing from commit
stamps: it rebuilds the graph with graphify (pinned in the Makefile; free,
tree-sitter only) in a temporary copy of the tracked files and compares it
with the committed graphify-out/graph.json (ignoring `built_at_commit`). The
rebuild is deterministic: same tree, same graph, whatever the directory.
A difference fails only when the change touches teach/ or scripts/ (the
machinery the graph maps); for anything else it is a warning.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REPORT = REPO / "graphify-out" / "GRAPH_REPORT.md"
GRAPH = REPO / "graphify-out" / "graph.json"


GRAPH_SOURCES = ("teach/", "scripts/")


def normalized(graph: dict) -> dict:
    graph = dict(graph)
    graph.pop("built_at_commit", None)
    return graph


def graphify_bin() -> str | None:
    venv = REPO / ".venv" / "bin" / "graphify"
    return str(venv) if venv.exists() else shutil.which("graphify")


def rebuild_in_copy(graphify: str) -> dict:
    """graph.json rebuilt from the tracked files (as they are on disk), in a temp dir."""
    ignored = [line.strip().rstrip("/") for line in
               (REPO / ".graphifyignore").read_text(encoding="utf-8").splitlines()
               if line.strip() and not line.startswith("#")]
    files = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, capture_output=True,
                           text=True, check=True).stdout.split("\0")
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / REPO.name
        for f in files:
            if not f or any(f == p or f.startswith(p + "/") for p in ignored):
                continue
            src = REPO / f
            if src.is_file():
                (dest / f).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest / f)
        res = subprocess.run([graphify, "update", "."], cwd=dest, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"graphify update failed: {(res.stderr or res.stdout).strip()[-400:]}")
        return json.loads((dest / "graphify-out" / "graph.json").read_text(encoding="utf-8"))


def touches_graph_sources(base: str) -> list[str]:
    diff = subprocess.run(["git", "diff", "--name-only", f"{base}...HEAD"], cwd=REPO,
                          capture_output=True, text=True, check=True)
    return [f for f in diff.stdout.splitlines() if f.startswith(GRAPH_SOURCES)]


def regenerate(base: str | None) -> int:
    graphify = graphify_bin()
    if not graphify:
        print("graph: graphify is not installed — `make graph-setup` (free), then rerun.")
        return 1
    if not GRAPH.exists():
        print("graph: MISSING — run `make graph` and commit graphify-out/.")
        return 1
    committed = normalized(json.loads(GRAPH.read_text(encoding="utf-8")))
    rebuilt = normalized(rebuild_in_copy(graphify))
    if committed == rebuilt:
        print(f"graph: OK — the committed graph is what this tree builds "
              f"({len(rebuilt.get('nodes', []))} nodes, {len(rebuilt.get('links', []))} links).")
        return 0
    touched = touches_graph_sources(base) if base else []
    msg = (f"graph: STALE — the committed graph ({len(committed.get('nodes', []))} nodes) is not what this tree "
           f"builds ({len(rebuilt.get('nodes', []))} nodes). Run `make graph` (free, no LLM) and commit graphify-out/.")
    if touched:
        print(f"{msg}\n       This change touches the code the graph maps: {', '.join(touched[:5])}"
              + (" …" if len(touched) > 5 else ""))
        return 1
    print(f"{msg}\n       Warning only: this change does not touch {' or '.join(GRAPH_SOURCES)}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--strict", action="store_true",
                        help="exit non-zero on a missing or stale graph")
    parser.add_argument("--regenerate", action="store_true",
                        help="rebuild the graph in a temp copy and compare (needs graphify)")
    parser.add_argument("--base", help="with --regenerate: fail only if the diff from BASE touches teach/ or scripts/")
    args = parser.parse_args()
    if args.regenerate:
        return regenerate(args.base)
    fail = 1 if args.strict else 0

    if not GRAPH.exists() or not REPORT.exists():
        print("graph: MISSING — build it with `make graph` (AST only, no quota).")
        return fail

    match = re.search(r"Built from commit: `([0-9a-f]+)`", REPORT.read_text(encoding="utf-8"))
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
        scanned = last_scan_file.read_text(encoding="utf-8").strip()
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
               (REPO / ".graphifyignore").read_text(encoding="utf-8").splitlines()
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
