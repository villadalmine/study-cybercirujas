#!/usr/bin/env python3
"""Is the pipeline running on what it says it runs on?

`pipeline.yaml` declares the model and the thinking level. Several things can
override that, and every one of them does it silently:

  TEACH_CLAUDE_MODEL / TEACH_CLAUDE_EFFORT   in whatever shell started the run
  Environment= in an installed systemd unit  which is a COPY of deploy/systemd
  the CLI's own default                      when nothing is pinned at all

On 2026-08-13 the installed unit still carried `TEACH_CLAUDE_MODEL=opus-4-8`
after the repository had dropped it so pipeline.yaml could decide. The timer
generated on the old model for hours while every file in the repository said
otherwise. The usage log showed the tell: `effort: xhigh` from pipeline.yaml
sitting next to `claude-opus-4-8` from the stale environment — half the new
configuration live, half not.

Comparing files could not have caught that on its own, because the override does
not have to come from a file. So this checks two different things:

  1. **Declared vs effective.** What would a generation started right now use?
     Resolved through the same code the generator uses, not re-implemented.
  2. **Declared vs what actually happened.** What did recent completions really
     run on? That is the only check that catches an override path nobody
     thought of, because it reads the outcome instead of the configuration.

    scripts/check_config.py              # both checks
    scripts/check_config.py --since 20   # widen the window of recent completions

Exit 1 on a mismatch. Costs no API quota.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import pipeline  # noqa: E402

USAGE = (Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
         / "teach-plat" / "usage.jsonl")

OVERRIDES = ("TEACH_CLAUDE_MODEL", "TEACH_CLAUDE_EFFORT", "TEACH_BACKEND")


def effective() -> tuple[str, str, list[str]]:
    """(model, effort, notes) as the generator would resolve them right now.

    Resolved by asking the generator, not by re-reading the YAML: a check that
    re-implements the resolution can agree with the declaration while disagreeing
    with the code, which is the failure it exists to detect.
    """
    from teach.core.generator import _agent_completer

    notes = []
    for name in OVERRIDES:
        if os.environ.get(name):
            notes.append(f"{name} is set in this environment and beats pipeline.yaml")
    try:
        _, meta = _agent_completer("claude")
        model = str(meta.get("model"))
    except Exception as error:  # a missing CLI is not a config mismatch
        return "unknown", "unknown", [f"could not resolve: {error}"]
    effort = (os.environ.get("TEACH_CLAUDE_EFFORT")
              or pipeline.generation().get("effort") or "default")
    return model, str(effort), notes


def recent(limit: int) -> list[dict]:
    if not USAGE.exists():
        return []
    rows = []
    for line in USAGE.read_text(errors="replace").splitlines()[-limit * 4:]:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("op") in ("author", "translate"):
            rows.append(row)
    return rows[-limit:]


def dominant(row: dict) -> str | None:
    models = row.get("models") or {}
    if not models:
        return None
    return max(models.items(), key=lambda kv: (kv[1] or {}).get("out") or 0)[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", type=int, default=10,
                        help="how many recent completions to check (default 10)")
    args = parser.parse_args()

    declared = pipeline.generation()
    want_model = str(declared.get("model") or "(none declared)")
    want_effort = str(declared.get("effort") or "default")
    model, effort, notes = effective()

    print(f"{'':10} {'declared':26} {'effective':26}")
    print(f"{'model':10} {want_model:26} {model:26}")
    print(f"{'effort':10} {want_effort:26} {effort:26}")

    problems = []
    if model != "unknown" and want_model != "(none declared)" and model != want_model:
        problems.append(
            f"a run started now would use {model}, not the declared {want_model}")
    if effort != "unknown" and effort != want_effort:
        problems.append(
            f"a run started now would think at {effort}, not the declared {want_effort}")
    for note in notes:
        print(f"  note: {note}")

    rows = recent(args.since)
    if rows:
        models = Counter(m for m in (dominant(r) for r in rows) if m)
        efforts = Counter(str(r.get("effort") or "default") for r in rows)
        print(f"\nWhat the last {len(rows)} completions actually ran on:")
        for name, count in models.most_common():
            mark = "  " if name == want_model else "!!"
            print(f"  {mark} {name:26} {count:>3}")
        for name, count in efforts.most_common():
            mark = "  " if name == want_effort else "!!"
            print(f"  {mark} effort={name:20} {count:>3}")
        stray_models = {m for m in models if m != want_model}
        stray_efforts = {e for e in efforts if e != want_effort}
        if stray_models:
            problems.append(
                f"recent content was generated on {', '.join(sorted(stray_models))} "
                f"while {want_model} is declared")
        if stray_efforts:
            problems.append(
                f"recent content was generated at effort "
                f"{', '.join(sorted(stray_efforts))} while {want_effort} is declared")

    if not problems:
        print("\nDeclared, effective and actual all agree.")
        return 0

    print(f"\n{len(problems)} mismatch(es):")
    for problem in problems:
        print(f"  - {problem}")
    print("\nSomething is overriding pipeline.yaml. In order of likelihood:\n"
          "  scripts/check_units.py            an installed unit still sets it\n"
          "  env | grep TEACH_                 the shell that started the run\n"
          "  .env                              translation-only, but check anyway\n"
          "\nOlder completions predating a deliberate change are expected — "
          "widen or narrow\nthe window with --since to tell a change from a drift.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
