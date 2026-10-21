#!/usr/bin/env python3
"""CI gate (#220): the repo must say ONE thing about each cert's curriculum. No model, no network.

For every cert in catalog.yaml:
  (a) every curriculum citation in the material (content.md, exercises.md, lab script headers) names `tracked_version`,
      when that is a dotted number;
  (b) every link to the cert's objectives document, in the material and in the `sources:` of each meta.yaml, is the
      catalog's pinned `sources.objectives` URL, not another spelling or version of the same document.
While an upgrade is open (a valid `upstream:` block in the catalog) the upstream value is accepted instead, one value per
cert, never both. An invalid block, or a cert the control cannot compare, fails loudly: no cert is skipped silently.

What counts as a citation is data: scripts/curriculum_patterns.yaml. The rewrite that fixes a line is
`curriculum_citations.fix_line`, the same one the upgrade script and the guard use.

    scripts/check_curriculum_consistency.py            # exit 1 on a mismatch not in the baseline, or a stale baseline entry
    scripts/check_curriculum_consistency.py --list     # every offender with the line it would become
    scripts/check_curriculum_consistency.py --update   # rewrite the baseline to the current offenders (it may only shrink)

The baseline, tests/fixtures/curriculum_consistency_baseline.txt, lists offenders that existed when the gate was added. A
new mismatch fails; so does a baseline entry that no longer offends (remove it). When the file is empty it is deleted and
the gate is strict.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import curriculum_citations as cc  # noqa: E402

REPO = HERE.parent
BASELINE = REPO / "tests" / "fixtures" / "curriculum_consistency_baseline.txt"


def load_baseline(path: Path = BASELINE) -> set[str]:
    if not path.is_file():
        return set()
    return {ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.startswith("#")}


def check(root: Path = REPO, baseline_path: Path = BASELINE) -> tuple[list[dict], list[str], list[dict]]:
    """(new offenders, stale baseline keys, all offenders)."""
    catalog = yaml.safe_load((root / "catalog.yaml").read_text(encoding="utf-8"))
    found = cc.offenders(root, catalog)
    base = load_baseline(baseline_path)
    ks = cc.keys(found)
    return [o for o, k in zip(found, ks) if k not in base], sorted(base - set(ks)), found


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    new, stale, found = check()
    catalog = yaml.safe_load((REPO / "catalog.yaml").read_text(encoding="utf-8"))
    broken = cc.problems(REPO, catalog)
    if "--list" in args:
        for o in found:
            print(f"{o['file']}:{o['line']}: {o['text'].strip()[:110]}\n    -> {o['fixed'].strip()[:110]}")
        return 0
    if "--update" in args:
        keys = sorted(cc.keys(found))
        if not keys:
            BASELINE.unlink(missing_ok=True)
        else:
            BASELINE.write_text("# Offenders that existed when the gate was added (#220). It may only shrink: "
                                "fix the line, then run --update.\n" + "\n".join(keys) + "\n", encoding="utf-8")
        print(f"baseline: {len(keys)} entr{'y' if len(keys) == 1 else 'ies'}")
        return 0
    for b in broken:
        print(f"CATALOG {b}")
    for o in new:
        print(f"MISMATCH {o['file']}:{o['line']}: {o['text'].strip()[:100]}\n    should read: {o['fixed'].strip()[:100]}")
    for k in stale:
        print(f"STALE baseline entry (no longer an offender, remove it): {k}")
    print(f"curriculum consistency: {len(found)} offender(s), {len(found) - len(new)} in the baseline, {len(new)} new, "
          f"{len(stale)} stale baseline entr{'y' if len(stale) == 1 else 'ies'}")
    return 1 if new or stale or broken else 0


if __name__ == "__main__":
    sys.exit(main())
