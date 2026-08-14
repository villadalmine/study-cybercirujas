#!/usr/bin/env python3
"""Do the installed systemd units match the ones in the repository?

`deploy/systemd/*` is the versioned copy; systemd runs whatever is in
~/.config/systemd/user/. They are two files, so they drift — and the drift is
invisible, because the repository looks right.

It happened on 2026-08-13: `TEACH_CLAUDE_MODEL=claude-opus-4-8` was removed from
the repo unit so that pipeline.yaml could decide the model, and the timer kept
generating on opus-4-8 for hours because the installed copy still had it. The
environment beats pipeline.yaml, so a stale unit silently overrides a declared
decision — the same shape as a private list drifting from the pipeline, one file
further out.

    scripts/check_units.py            # report drift
    scripts/check_units.py --install  # copy repo -> installed, then daemon-reload

Exit 1 when they differ, so `make verify` catches it.
"""
from __future__ import annotations

import argparse
import filecmp
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "deploy" / "systemd"
INSTALLED = Path.home() / ".config" / "systemd" / "user"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()

    units = sorted(SOURCE.glob("*.service")) + sorted(SOURCE.glob("*.timer"))
    if not units:
        print(f"No units in {SOURCE}.")
        return 0

    # A unit that sets a generation variable at all is a problem even when the
    # two copies agree: the environment beats pipeline.yaml, so the unit would
    # override the declared decision on every timer firing and the declaration
    # would be decoration. This is the door the 2026-08-13 drift came through.
    forbidden = []
    for unit in units:
        for line in unit.read_text(errors="replace").splitlines():
            if line.startswith("Environment=") and any(
                    v in line for v in ("TEACH_CLAUDE_MODEL", "TEACH_CLAUDE_EFFORT",
                                        "TEACH_BACKEND")):
                forbidden.append((unit.name, line.strip()))

    drifted = []
    for unit in units:
        target = INSTALLED / unit.name
        # Not installed is not drift: a machine that never enabled the timer is
        # a normal state, and reporting it as a problem trains people to ignore
        # this check.
        if not target.exists():
            continue
        if not filecmp.cmp(unit, target, shallow=False):
            drifted.append((unit, target))

    if forbidden:
        print("A unit sets what pipeline.yaml is supposed to decide:\n")
        for name, line in forbidden:
            print(f"  {name}: {line}")
        print("\nThe environment beats pipeline.yaml, so this wins on every "
              "firing and the\ndeclaration becomes decoration. Remove it, or "
              "set it deliberately and say why.")
        return 1

    if not drifted:
        print(f"{len(units)} unit(s) checked: installed copies match the repository, "
              f"and none overrides pipeline.yaml.")
        return 0

    if args.install:
        for unit, target in drifted:
            target.write_bytes(unit.read_bytes())
            print(f"installed {unit.name}")
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
        print("daemon-reload done — systemd now runs what the repository says.")
        return 0

    print(f"{len(drifted)} installed unit(s) differ from the repository:\n")
    for unit, target in drifted:
        print(f"  {target}")
        print(f"    differs from {unit.relative_to(REPO)}")
    print("\nsystemd runs the installed copy, so the repository is not what is "
          "happening.\nFix with: scripts/check_units.py --install")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
