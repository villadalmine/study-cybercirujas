#!/usr/bin/env python3
"""Decide what to work on, then do it. `make next`.

The one command that needs no arguments and no judgement. It exists because
"what should I do now?" is the question that makes agents start reading the repo
and inventing an order — and an invented order skips the claim system, ignores
the budget, and reports work it did not do.

The order is not a preference, it falls out of the pipeline's shape:

  1. A certification already in progress, before starting another. Half-finished
     work is worth more than a new front, and its video and translations are
     blocked until it is done.
  2. The authoring language before any translation. There is nothing to
     translate otherwise.
  3. Content before video. A video narrates material that must already exist.
  4. Translation last: it is ~1000x cheaper than authoring, so it is never the
     thing to spend a quota window on while authoring is outstanding.

Whatever it picks, it goes through run_cert.py, so the claims, the budget and
the ordering apply exactly as they would by hand.

    scripts/next_work.py --dry-run     # what it would pick, and why
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

from teach.core import certs, claims, pipeline  # noqa: E402

import fix_corrupted_content as audit  # noqa: E402


def survey() -> list[dict]:
    """Every active certification with what it still needs, most urgent first."""
    bad = audit.find_bad_combos()
    source = certs.DEFAULT_LANG
    rows = []
    for cert, languages in pipeline.targets():
        pending_source = sorted({t for c, t, l in bad if c == cert and l == source})
        pending_other = sorted({(t, l) for c, t, l in bad if c == cert and l != source})
        videos = [l for l in pipeline.video_languages(cert)
                  if not (REPO / "media" / "certs" / cert / l / "video.mp4").exists()]
        done_source = not pending_source
        rows.append({
            "cert": cert,
            "pending_source": pending_source,
            "pending_other": pending_other,
            "videos": videos,
            # In progress = started but not finished in the authoring language.
            "started": done_source or len(pending_source) < _topic_count(cert),
            "needs_work": bool(pending_source or pending_other or (videos and done_source)),
        })
    # Started-but-unfinished first, then by how little is left.
    rows.sort(key=lambda r: (not r["started"], len(r["pending_source"]) or 999))
    return [r for r in rows if r["needs_work"]]


def _topic_count(cert: str) -> int:
    import yaml
    try:
        front = yaml.safe_load((REPO / "certs" / f"{cert}.md").read_text().split("---")[1])
        return len(front.get("topics") or [])
    except (FileNotFoundError, IndexError, KeyError):
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    work = survey()
    if not work:
        print("Nothing pending. Every active certification is finished in every "
              "declared language, videos included.")
        print("Start another by flipping `active: true` in pipeline.yaml, or "
              "check `make status`.")
        return 0

    busy = {(c, t, l) for c, t, l in claims.active()}
    for row in work:
        cert = row["cert"]
        source = certs.DEFAULT_LANG
        free = [t for t in row["pending_source"] if (cert, t, source) not in busy]
        if row["pending_source"] and not free:
            print(f"{cert}: every pending topic is claimed by another run — skipping")
            continue

        if row["pending_source"]:
            why = (f"{len(row['pending_source'])} topics still to author in "
                   f"{source}; nothing downstream can start until they exist")
        elif row["videos"]:
            why = (f"content is complete, video missing in "
                   f"{', '.join(row['videos'])}")
        else:
            langs = sorted({l for _, l in row["pending_other"]})
            why = f"authoring done; {len(row['pending_other'])} to translate into {', '.join(langs)}"

        # flush: this line explains everything that follows, so it has to appear
        # before the subprocess output rather than after it.
        print(f"Next: {cert} — {why}\n", flush=True)
        command = [sys.executable, str(REPO / "scripts" / "run_cert.py"), cert]
        if args.backend:
            command += ["--backend", args.backend]
        if args.dry_run:
            command.append("--dry-run")
        return subprocess.run(command, cwd=REPO).returncode

    print("Everything pending is already being worked on by someone else.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
