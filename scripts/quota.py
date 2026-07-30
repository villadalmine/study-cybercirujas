#!/usr/bin/env python3
"""Detect whether the AI backend currently has quota, and record the history.

There is no API that says when a spend window renews, and it cannot be computed
either: the limit that stopped generation on 2026-07-29/30 came back partway
through the day and then ran out again, so it is not a simple monthly reset.
The only reliable answer is to ask, cheaply.

This sends a minimal prompt — a few output tokens — and classifies the result
using the same `fatal_errors` list from pipeline.yaml that the batch runner
uses, so "out of quota" means one thing across the whole project.

Every probe is appended to a JSONL history. That file is the actual answer to
"when does the window renew": after a few days it shows empirically when quota
came back, instead of anyone having to guess.

    scripts/quota.py                 # probe, print, exit 0 if available
    scripts/quota.py --quiet         # exit code only, for use as a gate
    scripts/quota.py --history 20    # last 20 probes
    scripts/quota.py --wait 7200     # block until quota returns, up to N seconds
"""
from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from teach.core import generator, pipeline  # noqa: E402

STATE_DIR = Path.home() / ".local" / "state" / "teach-plat"
HISTORY = STATE_DIR / "quota-history.jsonl"

PROBE_PROMPT = "Reply with exactly: OK"
AVAILABLE, EXHAUSTED, BROKEN = 0, 1, 2


def probe(backend: str = "claude") -> tuple[int, str]:
    """Returns (exit-style status, detail). Cheap by construction: the prompt
    asks for two characters."""
    try:
        command = generator.AGENT_COMMANDS[backend]
    except KeyError:
        return BROKEN, f"unknown backend {backend!r}"

    result = subprocess.run(
        [*command, PROBE_PROMPT],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120,
    )
    output = (result.stdout + result.stderr).strip()
    if result.returncode == 0:
        return AVAILABLE, output.splitlines()[0][:80] if output else "ok"
    if pipeline.is_fatal(output):
        return EXHAUSTED, output.splitlines()[-1][:200]
    return BROKEN, output.splitlines()[-1][:200] if output else "no output"


def record(status: int, detail: str, backend: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    entry = {
        "at": datetime.datetime.now().isoformat(timespec="seconds"),
        "backend": backend,
        "status": {AVAILABLE: "available", EXHAUSTED: "exhausted", BROKEN: "error"}[status],
        "detail": detail,
    }
    with HISTORY.open("a") as handle:
        handle.write(json.dumps(entry) + "\n")


def show_history(count: int) -> None:
    if not HISTORY.exists():
        print("No probes recorded yet.")
        return
    lines = HISTORY.read_text().splitlines()[-count:]
    previous = None
    for line in lines:
        entry = json.loads(line)
        # Mark the transitions: those are the moments a window actually opened
        # or closed, which is the whole point of keeping this history.
        marker = ""
        if previous and previous != entry["status"]:
            marker = "  <-- CHANGED"
        previous = entry["status"]
        print(f"{entry['at']}  {entry['status']:<10} {entry['detail'][:60]}{marker}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", default="claude")
    parser.add_argument("--quiet", action="store_true", help="exit code only")
    parser.add_argument("--history", type=int, metavar="N", help="show the last N probes")
    parser.add_argument("--wait", type=int, metavar="SECONDS",
                        help="block until quota returns, giving up after SECONDS")
    parser.add_argument("--interval", type=int, default=900,
                        help="seconds between probes while waiting (default 900)")
    args = parser.parse_args()

    if args.history:
        show_history(args.history)
        return 0

    deadline = time.monotonic() + args.wait if args.wait else None
    while True:
        status, detail = probe(args.backend)
        record(status, detail, args.backend)
        if not args.quiet:
            label = {AVAILABLE: "available", EXHAUSTED: "exhausted", BROKEN: "error"}[status]
            print(f"{args.backend}: {label} — {detail}")
        if status == AVAILABLE or deadline is None:
            return status
        if status == BROKEN:
            # Not a quota problem; waiting will not fix a broken CLI.
            return status
        if time.monotonic() + args.interval > deadline:
            if not args.quiet:
                print(f"still exhausted after waiting {args.wait}s")
            return status
        if not args.quiet:
            print(f"waiting {args.interval}s before probing again", flush=True)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
