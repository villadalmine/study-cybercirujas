#!/usr/bin/env python3
"""Unstage topics another run is generating right now.

The generator writes content.md as soon as it passes, before asking for the
exercises — deliberately, so a failure in the second call does not throw away the
first. The syllabus status is only set once the whole topic lands. Between those
two moments the topic looks, to `git add`, like finished work with a `pending`
status, and the pre-commit hook refuses the commit. Correctly: that state IS
inconsistent, it is just temporary.

So the answer is not to weaken the hook. It is to not stage work that is still
being done — which the claim system already knows about.

Idempotent and silent when there is nothing in flight.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import claims  # noqa: E402


def main() -> int:
    active = claims.active()
    if not active:
        return 0
    removed = []
    for cert, topic, lang in active:
        target = f"certs/{cert}/{topic}"
        result = subprocess.run(["git", "reset", "-q", "HEAD", "--", target],
                                cwd=REPO, capture_output=True, text=True)
        if result.returncode == 0:
            removed.append(f"{cert}/{topic} ({lang})")
    if removed:
        print(f"  left out, still being generated: {', '.join(removed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
