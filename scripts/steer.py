#!/usr/bin/env python3
"""Change what the pipeline does, from the command line, safely.

Every decision about WHAT gets produced lives in `pipeline.yaml` — which
certifications are active, who owns each one, which languages, which videos, how
much a single run may generate. That file is the interface. This is the way to
edit it without opening it, so a decision made in conversation becomes
configuration in one command instead of prose someone has to remember.

    scripts/steer.py show                             # every knob and its value
    scripts/steer.py own kcsa claude                  # assign an owner
    scripts/steer.py activate lfcs --owner any        # start a certification
    scripts/steer.py deactivate lpi-702               # stop working on one
    scripts/steer.py languages kcsa en es pt          # what it must have
    scripts/steer.py video kcsa en es                 # which videos to render
    scripts/steer.py budget 3                         # topics per run

Idempotent: setting a value it already has changes nothing and says so. It
rewrites only the keys you name, never reformats the rest of the file, and
refuses anything the pipeline could not act on — an unknown language, a video in
a language Piper cannot speak, an owner nobody is.

Nothing here costs API quota.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import certs, pipeline, video  # noqa: E402

PIPELINE = REPO / "pipeline.yaml"
KNOWN_AGENTS = {"claude", "antigravity", "any"}


def _cert_block(text: str, cert: str) -> tuple[int, int]:
    """(start, end) line indices of a certification's block, so edits are surgical.

    Deliberately line-based rather than a YAML round-trip: PyYAML would drop every
    comment in the file, and the comments are where the reasoning lives — half of
    pipeline.yaml is the record of why a number is what it is.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"  {cert}:"):
            start = i
            continue
        if start is not None and line and not line.startswith("    ") and not line.startswith("  #"):
            return start, i
    if start is None:
        raise SystemExit(f"No certification '{cert}' in pipeline.yaml")
    return start, len(lines)


def set_key(cert: str, key: str, value: str) -> bool:
    """Set one key inside one certification. True if the file changed."""
    text = PIPELINE.read_text()
    start, end = _cert_block(text, cert)
    lines = text.splitlines()
    wanted = f"    {key}: {value}"
    for i in range(start + 1, end):
        if lines[i].strip().startswith(f"{key}:"):
            if lines[i].rstrip() == wanted:
                print(f"{cert}.{key} is already {value} — nothing to do.")
                return False
            print(f"{cert}.{key}: {lines[i].split(':', 1)[1].strip()} -> {value}")
            lines[i] = wanted
            break
    else:
        print(f"{cert}.{key}: (unset) -> {value}")
        lines.insert(start + 1, wanted)
    PIPELINE.write_text("\n".join(lines) + "\n")
    return True


def show() -> None:
    config = pipeline.load()
    print(f"budget.topics_per_run: {config['budget']['topics_per_run']}")
    print(f"languages.default:     {config['languages']['default']}")
    print(f"this agent (TEACH_AGENT): {pipeline.me()}\n")
    print(f"{'certification':16} {'active':>7} {'owner':>13}  languages / videos")
    print("-" * 74)
    for cert, entry in (config.get("certs") or {}).items():
        entry = entry or {}
        active = "yes" if entry.get("active") else "no"
        langs = ",".join(pipeline.languages_for(cert)) if entry.get("active") else "-"
        videos = ",".join(entry.get("video") or []) or "-"
        print(f"{cert:16} {active:>7} {str(entry.get('owner') or 'any'):>13}  {langs} / {videos}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("show")
    p = sub.add_parser("own"); p.add_argument("cert"); p.add_argument("agent")
    p = sub.add_parser("activate"); p.add_argument("cert"); p.add_argument("--owner", default=None)
    p = sub.add_parser("deactivate"); p.add_argument("cert")
    p = sub.add_parser("languages"); p.add_argument("cert"); p.add_argument("langs", nargs="+")
    p = sub.add_parser("video"); p.add_argument("cert"); p.add_argument("langs", nargs="*")
    p = sub.add_parser("budget"); p.add_argument("topics", type=int)
    args = parser.parse_args()

    if args.command == "show":
        show()
        return 0

    changed = False
    if args.command == "own":
        if args.agent not in KNOWN_AGENTS:
            raise SystemExit(f"Unknown agent '{args.agent}'. Known: "
                             f"{', '.join(sorted(KNOWN_AGENTS))}")
        changed = set_key(args.cert, "owner", args.agent)

    elif args.command == "activate":
        changed = set_key(args.cert, "active", "true")
        if args.owner:
            changed |= set_key(args.cert, "owner", args.owner)

    elif args.command == "deactivate":
        changed = set_key(args.cert, "active", "false")

    elif args.command == "languages":
        unknown = [l for l in args.langs if l not in certs.LANGS]
        if unknown:
            raise SystemExit(f"Not supported: {', '.join(unknown)}. Valid: {certs.LANGS}")
        if certs.DEFAULT_LANG not in args.langs:
            raise SystemExit(f"The authoring language '{certs.DEFAULT_LANG}' must be in "
                             f"the list — everything else is translated from it.")
        changed = set_key(args.cert, "languages", "[" + ", ".join(args.langs) + "]")

    elif args.command == "video":
        # Piper has no voice for some languages, so a video there cannot be
        # rendered at all — accepting it would queue work that can never finish.
        mute = [l for l in args.langs if l not in video.VOICES]
        if mute:
            raise SystemExit(f"Piper has no voice for: {', '.join(mute)}. "
                             f"Available: {', '.join(sorted(video.VOICES))}")
        changed = set_key(args.cert, "video", "[" + ", ".join(args.langs) + "]")

    elif args.command == "budget":
        if not 1 <= args.topics <= 10:
            raise SystemExit("Between 1 and 10. Raising this does not produce more, "
                             "it fails later and wastes more when it does.")
        text = PIPELINE.read_text()
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.strip().startswith("topics_per_run:"):
                if line.strip() == f"topics_per_run: {args.topics}":
                    print(f"budget.topics_per_run is already {args.topics}.")
                    return 0
                print(f"budget.topics_per_run: {line.split(':')[1].strip()} -> {args.topics}")
                lines[i] = f"  topics_per_run: {args.topics}"
                changed = True
                break
        PIPELINE.write_text("\n".join(lines) + "\n")

    if changed:
        # Prove the file still parses and the pipeline can read it, before anyone
        # relies on it. A broken pipeline.yaml stops every agent at once.
        try:
            pipeline.load.cache_clear()  # type: ignore[attr-defined]
        except AttributeError:
            pass
        try:
            pipeline.targets()
        except Exception as error:
            raise SystemExit(f"pipeline.yaml is now unreadable — revert with "
                             f"`git checkout pipeline.yaml`:\n{error}")
        subprocess.run(["git", "--no-pager", "diff", "--stat", "pipeline.yaml"], cwd=REPO)
        print("\nCommit it so the other agent sees the decision.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
