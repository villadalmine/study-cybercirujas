#!/usr/bin/env python3
"""Compare the outputs of several auditors against docs/audit/rubric.yml.

Prints a table (score per criterion and auditor, average, disagreements), every
proposal side by side, and a ranking computed by a fixed formula:

    priority = sum(weight of each foundation served) x automatable / effort

Deterministic and offline: no network, no model. A criterion whose proposal is
missing is REFUSED: its score does not count and the exit code is 2.

    python3 scripts/audit_compare.py [--date YYYY-MM-DD] [--rubric FILE] [--results DIR]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
AUTOMATABLE = {"yes": 1.0, "partial": 0.6, "no": 0.3}
EFFORT = {"S": 1, "M": 2, "L": 4}
REQUIRED = ("what_to_change", "implies", "how_to_improve")


def criterion_ids(rubric: dict) -> list[str]:
    return [c["id"] for area in rubric["areas"].values() for c in area]


def has_proposal(criterion: dict) -> bool:
    """A proposal counts only if it says what to change, what it implies and how to improve."""
    p = (criterion or {}).get("proposal")
    return isinstance(p, dict) and all(str(p.get(k, "")).strip() for k in REQUIRED)


def load_results(files: list[Path]) -> dict[str, dict]:
    data = {}
    for f in files:
        d = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        data[f"{d.get('auditor', f.stem)}@{str(d.get('commit', ''))[:7]}"] = d.get("criteria", {}) or {}
    return data


def valid_score(criterion: dict):
    """The score of a criterion, or None if it is missing, not 0/1/2, or has no proposal."""
    s = (criterion or {}).get("score")
    ok = isinstance(s, int) and not isinstance(s, bool) and s in (0, 1, 2)
    return s if ok and has_proposal(criterion) else None


def priority(proposal: dict, foundations: dict) -> float:
    fs = proposal.get("foundations") or []
    fs = [fs] if isinstance(fs, str) else fs
    weight = sum(foundations.get(f, {}).get("weight", 0) for f in fs)
    auto = proposal.get("automatable", "no")
    auto = {True: "yes", False: "no"}.get(auto, str(auto))  # YAML 1.1 reads a bare yes/no as a boolean
    auto = AUTOMATABLE.get(auto, 0.3)
    effort = EFFORT.get(str(proposal.get("effort", "L")), 4)
    return round(weight * auto / effort, 2)


def compare(rubric: dict, data: dict[str, dict]) -> tuple[str, list[str], list[str]]:
    """Return (report, disagreements, refused)."""
    ids = criterion_ids(rubric)
    auditors = list(data)
    out = ["| criterion | " + " | ".join(auditors) + " | avg | disagreement |", "|" + "---|" * (len(auditors) + 3)]
    disagreements, refused = [], []
    for i in ids:
        vals = [valid_score(data[a].get(i, {})) for a in auditors]
        nums = [v for v in vals if v is not None]
        avg = f"{sum(nums) / len(nums):.1f}" if nums else "-"
        dis = len(nums) > 1 and max(nums) - min(nums) >= 1
        if dis:
            disagreements.append(i)
        cells = " | ".join("-" if v is None else str(v) for v in vals)
        out.append(f"| {i} | {cells} | {avg} | {'**yes**' if dis else ''} |")
    out.append("\n## Proposals per criterion (all of them, to compare)")
    for i in ids:
        present = [(a, data[a][i]) for a in auditors if i in data[a]]
        if not present:
            continue
        out.append(f"\n### {i}")
        for a, c in present:
            if not has_proposal(c):
                refused.append(f"{i}@{a}")
                out.append(f"- {a}: (no proposal: refused, the score does not count)")
                continue
            p = c["proposal"]
            out.append(f"- {a} [{p.get('priority', '?')}]: {p['what_to_change']} | implies: {p['implies']}"
                       f" | improve: {p['how_to_improve']}")
    if refused:
        out.append("\nwithout proposal (refused): " + ", ".join(refused))
    foundations = rubric.get("foundations", {})
    ranking = []
    for a in auditors:
        for i, c in data[a].items():
            if has_proposal(c):
                p = c["proposal"]
                fs = p.get("foundations") or []
                fs = [fs] if isinstance(fs, str) else fs
                ranking.append((priority(p, foundations), i, a, p["what_to_change"], ",".join(fs)))
    if ranking:
        out.append("\n## Proposal ranking (foundations x automatable / effort)")
        for val, i, a, q, fs in sorted(ranking, key=lambda r: (-r[0], r[1], r[2])):
            out.append(f"- {val:5.2f}  {i} ({a}) [{fs}] {q}")
    scored = [valid_score(data[a].get(i, {})) or 0 for a in auditors for i in ids]
    mean = sum(scored) / (2 * len(scored)) if scored else 0
    out.append(f"\nmean score: {mean:.0%} of the maximum · disagreements: {', '.join(disagreements) or 'none'}")
    return "\n".join(out), disagreements, refused


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--date", default="", help="only results whose file name starts with this date")
    ap.add_argument("--rubric", type=Path, default=REPO / "docs/audit/rubric.yml")
    ap.add_argument("--results", type=Path, default=REPO / "docs/audit/results")
    args = ap.parse_args(argv)
    rubric = yaml.safe_load(args.rubric.read_text(encoding="utf-8"))
    files = sorted(args.results.glob(f"{args.date}*.yml")) if args.results.exists() else []
    if not files:
        print(f"no results in {args.results}")
        return 1
    report, _, refused = compare(rubric, load_results(files))
    print(report)
    return 2 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
